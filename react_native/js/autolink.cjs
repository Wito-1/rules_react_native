// Generates react_native_codegen + react_native_npm_library targets for an app's npm dependencies
// that ship Android code: what @react-native/gradle-plugin's autolinking learns from
// `react-native config`, read from each package's package.json (codegenConfig),
// react-native.config.js and android/build.gradle.
//
//   bazel run //app:autolink           writes <app>/react_native_libraries.bzl
//   bazel test //app:autolink_test     fails when that file is out of date
"use strict";

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const { createRequire } = require("node:module");
const path = require("node:path");
const { parseArgs } = require("node:util");

const { values: args } = parseArgs({
  options: {
    "package-json": { type: "string" },
    maven: { type: "string", default: "@rn_maven" },
    out: { type: "string" },
    label: { type: "string" },
    check: { type: "string" },
  },
});

function fail(message) {
  console.error(`react_native_autolink: ${message}`);
  process.exit(1);
}

const JAVA_DIRS = [
  "src/main/java",
  "src/main/kotlin",
  // New-architecture source sets libraries add with sourceSets when newArchEnabled.
  "src/fabric/java",
  "src/fabric/kotlin",
  "src/newarch",
  "src/newarch/java",
  "src/newarch/kotlin",
  "src/new_arch",
  "src/turbo/java",
];

const PACKAGE_CLASS = /class\s+(\w+)[^{]*?\b(?:ReactPackage|TurboReactPackage|BaseReactPackage)\b/;

function exists(...parts) {
  return fs.existsSync(path.join(...parts));
}

function walk(dir, exts, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walk(p, exts, out);
    } else if (exts.some((e) => entry.name.endsWith(e))) {
      out.push(p);
    }
  }
  return out.sort();
}

function loadConfig(pkgDir) {
  const file = path.join(pkgDir, "react-native.config.js");
  if (!fs.existsSync(file)) {
    return {};
  }
  try {
    return require(file)?.dependency?.platforms ?? {};
  } catch (err) {
    fail(`could not load ${file}: ${err.message}`);
  }
}

function namespaceOf(androidDir) {
  const gradle = ["build.gradle", "build.gradle.kts"].map((f) => path.join(androidDir, f)).find(fs.existsSync);
  if (gradle) {
    const m = fs.readFileSync(gradle, "utf8").match(/^\s*namespace\s*=?\s*["']([\w.]+)["']/m);
    if (m) return m[1];
  }
  const manifest = path.join(androidDir, "src/main/AndroidManifest.xml");
  if (fs.existsSync(manifest)) {
    const m = fs.readFileSync(manifest, "utf8").match(/package\s*=\s*"([\w.]+)"/);
    if (m) return m[1];
  }
  return null;
}

function packageClasses(androidDir, javaDirs, android) {
  if (android.packageImportPath) {
    const m = android.packageImportPath.match(/import\s+([\w.]+)\s*;?/);
    if (m) return [m[1]];
  }
  for (const dir of javaDirs) {
    for (const file of walk(path.join(androidDir, dir), [".java", ".kt"])) {
      const src = fs.readFileSync(file, "utf8");
      const cls = src.match(PACKAGE_CLASS);
      const pkg = src.match(/^\s*package\s+([\w.]+)/m);
      if (cls && pkg) return [`${pkg[1]}.${cls[1]}`];
    }
  }
  return [];
}


// Just enough CMake to list what a library's CMakeLists.txt compiles: set(), include(),
// file(GLOB[_RECURSE]), add_library()/target_sources(), include directories, definitions, links,
// and if()/elseif()/else() over variables (undefined ones are false; ReactAndroid_VERSION_MINOR is
// the app's React Native minor version). Sources under build/generated (codegen, which Bazel
// generates itself) and anything under React Native's own tree (prefab headers stand in for it)
// are dropped.
function cmakeCommands(text) {
  const commands = [];
  const re = /([A-Za-z_]\w*)\s*\(((?:[^()"]|"[^"]*"|\((?:[^()"]|"[^"]*")*\))*)\)/g;
  const stripped = text.replace(/#[^\n]*/g, "");
  for (const m of stripped.matchAll(re)) {
    const argv = [...m[2].matchAll(/"([^"]*)"|([^\s"]+)/g)].map((a) => a[1] ?? a[2]);
    commands.push({ name: m[1].toLowerCase(), argv });
  }
  return commands;
}

function globToRegExp(pattern) {
  return new RegExp(`^${pattern.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, "[^/]*")}$`);
}

function expandGlob(pattern, recursive) {
  const dir = path.dirname(pattern);
  const base = globToRegExp(path.basename(pattern));
  if (!fs.existsSync(dir)) return [];
  const out = [];
  const visit = (d) => {
    for (const entry of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, entry.name);
      if (entry.isDirectory()) {
        if (recursive) visit(p);
      } else if (base.test(entry.name)) {
        out.push(p);
      }
    }
  };
  visit(dir);
  return out.sort();
}

const CMAKE_KEYWORDS = new Set(["SHARED", "STATIC", "MODULE", "PUBLIC", "PRIVATE", "INTERFACE", "CONFIGURE_DEPENDS", "SYSTEM", "BEFORE", "AFTER"]);

const FALSY = /^(0|OFF|NO|FALSE|N|IGNORE|NOTFOUND|.*-NOTFOUND)?$/i;
const TRUTHY = /^(1|ON|YES|TRUE|Y)$/i;

function cmakeCondition(argv, vars) {
  const value = (t) => (t in vars ? vars[t] : t);
  const truthy = (t) => {
    if (TRUTHY.test(t)) return true;
    if (t in vars) return !FALSY.test(vars[t]);
    return false;
  };
  const evalAt = (tokens) => {
    if (tokens.length === 0) return true;
    const or = tokens.indexOf("OR");
    if (or > 0) return evalAt(tokens.slice(0, or)) || evalAt(tokens.slice(or + 1));
    const and = tokens.indexOf("AND");
    if (and > 0) return evalAt(tokens.slice(0, and)) && evalAt(tokens.slice(and + 1));
    if (tokens[0] === "NOT") return !evalAt(tokens.slice(1));
    if (tokens[0] === "DEFINED") return tokens[1] in vars;
    if (tokens.length === 3) {
      const [a, op, b] = tokens;
      const [x, y] = [value(a), value(b)];
      const nums = [Number(x), Number(y)];
      switch (op) {
        case "STREQUAL": return x === y;
        case "EQUAL": return nums[0] === nums[1];
        case "GREATER": return nums[0] > nums[1];
        case "GREATER_EQUAL": return nums[0] >= nums[1];
        case "LESS": return nums[0] < nums[1];
        case "LESS_EQUAL": return nums[0] <= nums[1];
        case "VERSION_GREATER_EQUAL": return nums[0] >= nums[1];
        default: return true;
      }
    }
    if (tokens.length === 1) return truthy(tokens[0]);
    return true;
  };
  return evalAt(argv);
}

function readCMake(file, reactNativeMinor) {
  const dir = path.dirname(file);
  const vars = {
    CMAKE_CURRENT_SOURCE_DIR: dir,
    CMAKE_SOURCE_DIR: dir,
    PROJECT_SOURCE_DIR: dir,
    ANDROID: "1",
    ReactAndroid_VERSION_MINOR: String(reactNativeMinor),
  };
  const subst = (s) => s.replace(/\$\{(\w+)\}/g, (_, v) => vars[v] ?? `\u0000${v}`);
  const values = (argv) =>
    argv.flatMap((a) => subst(a).split(";")).filter((a) => a !== "" && !CMAKE_KEYWORDS.has(a));
  const known = (list) => list.filter((p) => !p.includes("\u0000"));
  const resolve = (p) => (path.isAbsolute(p) ? path.normalize(p) : path.join(dir, p));
  const libraries = {};
  const library = (name) => (libraries[name] ??= { sources: [], includes: [], defines: [], links: [] });
  const globalIncludes = [];
  const globalDefines = [];
  const codegenDirs = new Set();
  const seen = new Set();

  const run = (cmakeFile) => {
    if (seen.has(cmakeFile) || !fs.existsSync(cmakeFile)) return;
    seen.add(cmakeFile);
    // [taking this branch, some branch already taken]
    const branches = [];
    const active = () => branches.every(([taking]) => taking);
    for (const { name, argv } of cmakeCommands(fs.readFileSync(cmakeFile, "utf8"))) {
      if (name === "if") {
        const taking = active() && cmakeCondition(argv.map((a) => a.replace(/\$\{(\w+)\}/g, (_, v) => vars[v] ?? "")), vars);
        branches.push([taking, taking]);
        continue;
      }
      if (name === "elseif" || name === "else") {
        const top = branches.pop() ?? [false, false];
        const parentActive = active();
        const taking = parentActive && !top[1] && (name === "else" || cmakeCondition(argv, vars));
        branches.push([taking, top[1] || taking]);
        continue;
      }
      if (name === "endif") {
        branches.pop();
        continue;
      }
      if (!active()) continue;
      if (name === "project" && argv[0]) {
        vars.PROJECT_NAME = argv[0];
      } else if (name === "set" && argv.length) {
        vars[argv[0]] = values(argv.slice(1)).join(";");
      } else if (name === "include" && argv.length) {
        // Relative paths in an included file still resolve against this directory.
        run(resolve(subst(argv[0])));
      } else if (name === "file" && /^GLOB(_RECURSE)?$/.test(argv[0])) {
        const recursive = argv[0] === "GLOB_RECURSE";
        let rest = argv.slice(2);
        const relative = rest.indexOf("RELATIVE");
        if (relative >= 0) rest = [...rest.slice(0, relative), ...rest.slice(relative + 2)];
        const patterns = known(values(rest));
        for (const p of patterns) {
          const m = resolve(p).split(path.sep).join("/").match(/build\/generated\/source\/codegen\/jni\/?(.*)$/);
          if (m) {
            // Codegen output the library compiles; recursive globs take all of it.
            codegenDirs.add(recursive ? "**" : path.posix.dirname(m[1] || "x") || ".");
          }
        }
        vars[argv[1]] = patterns.flatMap((p) => expandGlob(resolve(p), recursive || p.includes("**"))).join(";");
      } else if ((name === "add_library" || name === "target_sources") && argv.length) {
        library(subst(argv[0])).sources.push(...known(values(argv.slice(1))).map(resolve));
      } else if (name === "target_include_directories" && argv.length) {
        library(subst(argv[0])).includes.push(...known(values(argv.slice(1))).map(resolve));
      } else if (name === "include_directories") {
        globalIncludes.push(...known(values(argv)).map(resolve));
      } else if (name === "add_definitions" || name === "add_compile_definitions") {
        globalDefines.push(...known(values(argv)));
      } else if (name === "target_compile_definitions" && argv.length) {
        library(subst(argv[0])).defines.push(...known(values(argv.slice(1))));
      } else if (name === "target_link_libraries" && argv.length) {
        library(subst(argv[0])).links.push(...known(values(argv.slice(1))));
      }
    }
  };
  run(file);

  const keep = (p) => !p.includes(`${path.sep}build${path.sep}generated`) && fs.existsSync(p);
  return Object.entries(libraries).map(([name, lib]) => ({
    name,
    sources: [...new Set(lib.sources)].filter(keep).filter((p) => /\.(c|cc|cpp)$/.test(p)),
    includes: [...new Set([...lib.includes, ...globalIncludes])].filter(keep),
    defines: [...new Set([...globalDefines, ...lib.defines].map((d) => d.replace(/^-D/, "")))],
    links: [...new Set(lib.links)],
    codegenDirs: codegenDirs.has("**") ? null : [...codegenDirs].sort(),
  }));
}

// Gradle source sets the new architecture compiles: directories named in build.gradle's
// sourceSets (srcDirs/directories.add), minus old-architecture ones. Pairs like svg/ and nosvg/
// (optional integrations) follow whether the app depends on the matching react-native-* package.
function sourceSetDirs(gradle, androidDir, appDeps) {
  const named = [
    ...[...gradle.matchAll(/["']((?:src\/|[\w-]+\/src\/)[\w/.-]+)["']/g)].map((m) => m[1]),
    // Generated sources outside android/, e.g. Nitro's "${project.projectDir}/../nitrogen/...".
    ...[...gradle.matchAll(/["']\$\{(?:project\.)?projectDir\}\/([\w/.-]+)["']/g)]
      .map((m) => path.posix.normalize(m[1]))
      .filter((d) => /(^|\/)(java|kotlin)$/.test(d)),
  ];
  let dirs = [...new Set([...JAVA_DIRS, ...named])].filter(
    (d) => !/paper|oldarch|old_arch|\/res\b|\/assets\b|jni|cpp|AndroidManifest/.test(d) && fs.existsSync(path.join(androidDir, d)),
  );
  const tops = new Set(dirs.map((d) => d.split("/")[0]));
  dirs = dirs.filter((d) => {
    const top = d.split("/")[0];
    if (top.startsWith("no") && tops.has(top.slice(2))) {
      return !appDeps.has(`react-native-${top.slice(2)}`);
    }
    if (tops.has(`no${top}`)) {
      return appDeps.has(`react-native-${top}`);
    }
    return true;
  });
  return dirs;
}

// buildConfigField(type, name, value), minus the flags the library's own BuildConfig always
// declares. A value build.gradle computes (`isFooEnabled().toString()`) can't be evaluated here; it
// takes the type's zero value, i.e. the feature flag is off.
const ALWAYS_DECLARED = new Set(["IS_NEW_ARCHITECTURE_ENABLED", "IS_HERMES_ENABLED"]);
const ZERO = { boolean: "false", int: "0", long: "0L", float: "0f", double: "0d", String: "null" };

// String values build.gradle assigns once at top level: `def x = "1.0"`, `ext.x = "1.0"`,
// `versionName "1.0"`, `version = '1.0'`. Enough to resolve `${x}` in coordinates and BuildConfig.
function gradleVariables(gradle) {
  const vars = {};
  for (const m of gradle.matchAll(/^\s*(?:def\s+|ext\.)?(\w+)\s*=?\s*["']([^"'$\n]*)["']\s*$/gm)) {
    if (!(m[1] in vars)) vars[m[1]] = m[2];
  }
  return vars;
}

function substGradle(text, vars) {
  return text.replace(/\$\{(\w+)\}|\$(\w+)/g, (all, a, b) => vars[a ?? b] ?? all);
}

function buildConfigConstants(gradle) {
  const vars = gradleVariables(gradle);
  const constants = {};
  for (const m of gradle.matchAll(/buildConfigField\s*\(?\s*["'](\w+)["']\s*,\s*["'](\w+)["']\s*,\s*([^\n)]*)/g)) {
    const [, type, name, raw] = m;
    if (ALWAYS_DECLARED.has(name)) continue;
    // A Groovy string holding a Java expression: "true", or "\"1.0\"" for a Java string.
    const literal = substGradle(raw.trim(), vars).match(/^(["'])((?:\\.|(?!\1)[^\\$])*)\1$/);
    constants[name] = `${type} ${literal ? literal[2].replace(/\\(["'\\])/g, "$1") : ZERO[type] ?? "null"}`;
  }
  return constants;
}

// Gradle `implementation`/`api` Maven coordinates. React Native itself and the Kotlin stdlib come
// with react-android.
function mavenDeps(gradle) {
  const vars = gradleVariables(gradle);
  const deps = new Map();
  for (const m of gradle.matchAll(/^\s*(implementation|api)\s*\(?\s*["']([\w.-]+):([\w.-]+)(?::([^"']*))?["']/gm)) {
    const [, configuration, group, artifact, raw] = m;
    if (group === "com.facebook.react" || (group === "org.jetbrains.kotlin" && artifact.startsWith("kotlin-stdlib"))) {
      continue;
    }
    // A classifier/type (`:cpp@zip`) is a build input of the library's own, not a dependency.
    if (raw?.includes("@")) continue;
    const version = raw && substGradle(raw, vars);
    deps.set(`${group}:${artifact}`, {
      version: version && !version.includes("$") && version !== "+" ? version : null,
      api: configuration === "api",
    });
  }
  return [...deps].sort().map(([coordinate, d]) => ({ coordinate, ...d }));
}

const RES_TYPES = /^(values|drawable|layout|mipmap|anim|animator|color|font|menu|raw|xml|interpolator|transition|navigation)(-|$)/;

// res/ itself, or its subdirectories when the library splits resources into several res.srcDirs.
function resDirs(androidDir) {
  const res = path.join(androidDir, "src/main/res");
  if (!fs.existsSync(res)) return [];
  const children = fs.readdirSync(res, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name);
  if (children.some((c) => RES_TYPES.test(c))) return ["src/main/res"];
  return children
    .filter((c) => fs.readdirSync(path.join(res, c)).some((g) => RES_TYPES.test(g)))
    .sort()
    .map((c) => `src/main/res/${c}`);
}

// build.gradle plus the scripts it applies (`apply from: "..."`), e.g. Nitro's generated
// <Lib>+autolinking.gradle, which adds source sets.
function readGradle(file, seen = new Set()) {
  if (seen.has(file) || !fs.existsSync(file)) return "";
  seen.add(file);
  const text = fs.readFileSync(file, "utf8");
  const applied = [...text.matchAll(/apply\s+from\s*:\s*["']([^"']+)["']/g)]
    .map((m) => path.resolve(path.dirname(file), m[1].replace(/\$\{(?:project\.)?projectDir\}/, path.dirname(file))))
    .map((f) => readGradle(f, seen));
  return [text, ...applied].join("\n");
}

// Headers a library publishes through prefab for other libraries' native code: the Copy task that
// fills a `prefab { X { headers "<buildDir>/headers/..." } }` directory, e.g. Nitro's
// `from fileTree('../cpp/') ... into "${project.buildDir}/headers/nitromodules/NitroModules/"`.
// Returns {prefix: [source directories, absolute]}.
function prefabHeaders(gradle, androidDir) {
  if (!/prefab\s*\{[\s\S]*?headers\s/.test(gradle)) return {};
  const out = {};
  for (const task of gradle.matchAll(/tasks\.register\(\s*["']\w+["']\s*,\s*Copy\s*\)\s*\{([\s\S]*?)\n\}/g)) {
    const into = task[1].match(/into\s*\(?\s*["'][^"']*\/headers\/[^"']*?\/([\w.-]+)\/?["']/);
    if (!into) continue;
    const dirs = [...task[1].matchAll(/from\s*\(?\s*fileTree\s*\(\s*["']([^"']+)["']/g)]
      .map((m) => path.resolve(androidDir, m[1]))
      .filter((d) => fs.existsSync(d));
    if (dirs.length) out[into[1]] = [...new Set([...(out[into[1]] ?? []), ...dirs])];
  }
  return out;
}

// kotlinc's version in react_native/android/maven_kotlin_spec.json: Kotlin compiler plugins are
// built per compiler version.
const KOTLINC_VERSION = "2.2.10";
const EXPO_V2_COMPILER_PLUGIN = "io.github.expo:expo-modules-v2-compiler-plugin";

// What `expo-modules-autolinking resolve -p android` reports for the app: the Expo modules its
// dependencies (transitively) contain. Null when the app doesn't depend on expo.
function resolveExpoModules(packageJson, appRequire) {
  let expoPackageJson;
  try {
    expoPackageJson = appRequire.resolve("expo/package.json");
  } catch {
    return null;
  }
  const autolinking = path.join(
    path.dirname(createRequire(expoPackageJson).resolve("expo-modules-autolinking/package.json")),
    "bin/expo-modules-autolinking.js",
  );
  const result = spawnSync(process.execPath, [autolinking, "resolve", "--platform", "android", "--json"], {
    cwd: path.dirname(packageJson),
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.status !== 0) {
    fail(`expo-modules-autolinking resolve failed:\n${result.stderr}`);
  }
  return JSON.parse(result.stdout).modules;
}

function packageRoot(dir, name) {
  for (let d = dir; d !== path.dirname(d); d = path.dirname(d)) {
    const file = path.join(d, "package.json");
    if (fs.existsSync(file) && JSON.parse(fs.readFileSync(file, "utf8")).name === name) return d;
  }
  fail(`no package.json named ${name} above ${dir}`);
}

// One react_native_npm_library per Expo module project, built as expo-module-gradle-plugin
// configures it: compiled against expo-modules-core (and the Maven artifacts it exposes) with the
// Expo Modules v2 compiler plugin. expo-modules-core packages its prebuilt native libraries.
// `expo` depends on every other module, as Expo's autolinking arranges, because its
// ExpoModulesV2ModuleList is filled in by the compiler plugin from its classpath.
function describeExpo(modules, appDeps, reactNativeVersion, reactNativeMinor) {
  // Optional parts of modules (expo-modules-core's Compose support) sit in Gradle conditionals on
  // these; build.gradle isn't evaluated, so their dependencies are dropped here.
  const coreFeatures = new Set(modules.flatMap((m) => m.coreFeatures ?? []));
  const libs = [];
  for (const m of modules) {
    for (const project of m.projects ?? []) {
      const androidDir = fs.realpathSync(project.sourceDir);
      const pkgDir = packageRoot(androidDir, m.packageName);
      const lib = describe(m.packageName, pkgDir, appDeps, reactNativeMinor, androidDir);
      if (!lib) fail(`${m.packageName}: no Android project in ${androidDir}`);
      if (m.projects.length > 1) lib.target = targetName(`${m.packageName}-${project.name}`);
      lib.expo = { project, viaExpo: !appDeps.has(m.packageName) };
      lib.reactPackages = m.packageName === "expo" ? ["expo.modules.ExpoModulesPackage"] : [];
      lib.libraryDeps = [];
      lib.javaDirs = lib.javaDirs.filter((d) => !/\/src\/compose$/.test(d));
      const prebuilt = path.join(androidDir, "prebuilt/metadata.json");
      if (fs.existsSync(prebuilt)) {
        const metadata = JSON.parse(fs.readFileSync(prebuilt, "utf8"));
        if (metadata.reactNativeVersion !== reactNativeVersion) {
          fail(
            `${m.packageName}'s prebuilt native libraries are for React Native ${metadata.reactNativeVersion}, ` +
              `the app has ${reactNativeVersion}; building them from source is not supported`,
          );
        }
        const rel = path.relative(pkgDir, path.join(androidDir, "prebuilt/native-libs.tar.xz")).split(path.sep).join("/");
        lib.prebuiltNativeLibs = { [rel]: metadata.soFiles };
        lib.sharedLibraries = {};
        lib.ccSrcs = [];
      }
      if (!coreFeatures.has("compose")) lib.maven = lib.maven.filter((d) => !d.coordinate.startsWith("androidx.compose."));
      lib.maven.push({ coordinate: "org.jetbrains:annotations", version: "23.0.0", api: false });
      libs.push(lib);
    }
  }
  const core = libs.find((l) => l.npmPackage === "expo-modules-core");
  if (!core) fail("expo-modules-autolinking found no expo-modules-core");
  const coreGradle = readGradle(path.join(fs.realpathSync(core.expo.project.sourceDir), "build.gradle"));
  const v2 = gradleVariables(coreGradle).expoModulesV2Version;
  if (!v2) fail("no expoModulesV2Version in expo-modules-core's build.gradle");
  for (const lib of libs) {
    if (lib !== core) {
      lib.libraryDeps = ["expo-modules-core"];
      // compileOnly(project(":expo-modules-core")) puts its `api` artifacts on the classpath.
      for (const d of core.maven) {
        if (d.api && !lib.maven.some((x) => x.coordinate === d.coordinate)) lib.maven.push(d);
      }
    }
    if (lib.npmPackage === "expo") {
      lib.libraryDeps = libs.filter((l) => l !== lib).map((l) => l.npmPackage);
    }
    lib.maven.sort((a, b) => a.coordinate.localeCompare(b.coordinate));
    lib.kotlinPlugins = [{ coordinate: EXPO_V2_COMPILER_PLUGIN, version: `${v2}-${KOTLINC_VERSION}` }];
  }
  const packageList = {
    packages: [],
    modules: {},
    services: [],
  };
  for (const m of modules) {
    for (const project of m.projects ?? []) {
      if (m.packageName !== "expo") packageList.packages.push(...project.packages);
      for (const { classifier, name } of project.modules ?? []) packageList.modules[classifier] = name ?? "";
      packageList.services.push(...(project.services ?? []));
    }
  }
  return { libs, packageList };
}

function targetName(npmPackage) {
  return "npm_" + npmPackage.replace(/^@/, "").replace(/[^A-Za-z0-9]+/g, "_");
}

function describe(name, pkgDir, appDeps, reactNativeMinor, expoAndroidDir = null) {
  const pkg = JSON.parse(fs.readFileSync(path.join(pkgDir, "package.json"), "utf8"));
  // Expo modules are linked by Expo's autolinking, from the directory it resolved; their
  // react-native.config.js (expo's own) is for React Native's.
  const platforms = expoAndroidDir ? {} : loadConfig(pkgDir);
  if (platforms.android === null) {
    return null;
  }
  const android = platforms.android ?? {};
  const androidRel = expoAndroidDir
    ? path.relative(pkgDir, expoAndroidDir).split(path.sep).join("/")
    : (android.sourceDir ?? "android");
  const androidDir = path.join(pkgDir, androidRel);
  if (!exists(androidDir, "build.gradle") && !exists(androidDir, "build.gradle.kts")) {
    return null;
  }
  const gradle = readGradle(
    [path.join(androidDir, "build.gradle"), path.join(androidDir, "build.gradle.kts")].find(fs.existsSync),
  );

  const javaDirs = sourceSetDirs(gradle, androidDir, appDeps);
  const namespace = namespaceOf(androidDir);
  if (!namespace) {
    fail(`${name}: no namespace in android/build.gradle and no package in its AndroidManifest.xml`);
  }
  const codegen = pkg.codegenConfig;
  const libraryName = android.libraryName ?? codegen?.name ?? null;

  const lib = {
    npmPackage: name,
    target: targetName(name),
    package: namespace,
    javaDirs: javaDirs.map((d) => path.posix.normalize(`${androidRel}/${d}`)),
    manifest: exists(androidDir, "src/main/AndroidManifest.xml") ? `${androidRel}/src/main/AndroidManifest.xml` : "",
    resDirs: resDirs(androidDir).map((d) => `${androidRel}/${d}`),
    buildConfig: /buildConfigField|buildConfig\s*(=\s*)?true/.test(gradle),
    buildConfigConstants: buildConfigConstants(gradle),
    reactPackages: packageClasses(androidDir, javaDirs, android),
    proguard: [...gradle.matchAll(/consumerProguardFiles\s*\(?\s*["']([^"']+)["']/g)].map((m) => `${androidRel}/${m[1]}`),
    componentDescriptors: android.componentDescriptors ?? null,
    codegen: null,
    codegenCcDirs: null,
    ccSrcs: [],
    ccIncludes: [],
    sharedLibraries: {},
    sharedLibraryIncludes: {},
    sharedLibraryDefines: {},
    sharedLibraryLinks: {},
    prefabHeaders: {},
    cxxModules: {},
    maven: mavenDeps(gradle),
    libraryDeps: [
      ...new Set(
        [
          ...gradle.matchAll(/it\.name\s*==\s*["']([\w@/.-]+)["']/g),
          ...gradle.matchAll(/project\s*\(\s*["']:([\w@/.-]+)["']\s*\)/g),
        ].map((m) => m[1]),
      ),
    ]
      .filter((d) => appDeps.has(d) && d !== name)
      .sort(),
  };

  if (codegen && libraryName) {
    lib.codegen = {
      libraryName: codegen.name,
      javaPackage: codegen.android?.javaPackageName ?? "com.facebook.fbreact.specs",
      jsSrcsDir: path.posix.normalize(codegen.jsSrcsDir ?? "."),
    };
  }

  const rel = (p) => path.relative(pkgDir, p).split(path.sep).join("/");

  // The CMakeLists.txt react-native.config.js names is linked into the app's native library by
  // Gradle's autolinking (here: compiled into libappmodules.so).
  const autolinked = path.join(androidDir, android.cmakeListsPath ?? "src/main/jni/CMakeLists.txt");
  if (fs.existsSync(autolinked)) {
    for (const l of readCMake(autolinked, reactNativeMinor)) {
      lib.ccSrcs.push(...l.sources.map(rel));
      lib.ccIncludes.push(...l.includes.map(rel));
      if (l.codegenDirs) lib.codegenCcDirs = l.codegenDirs;
    }
  }
  // The library's own externalNativeBuild builds .so files its Java loads by name.
  const own = gradle.match(
    /externalNativeBuild\s*\{\s*cmake\s*\{[^}]*?path\s*=?\s*\(?\s*(?:file\s*\(\s*)?["']([^"']+)["']/,
  );
  if (own) {
    const file = path.join(androidDir, own[1]);
    if (path.resolve(file) !== path.resolve(autolinked) && fs.existsSync(file)) {
      for (const l of readCMake(file, reactNativeMinor)) {
        if (l.sources.length === 0) continue;
        lib.sharedLibraries[l.name] = l.sources.map(rel);
        lib.sharedLibraryIncludes[l.name] = l.includes.map(rel);
        const defines = l.defines.filter((d) => !d.startsWith("FOLLY_"));
        if (defines.length) lib.sharedLibraryDefines[l.name] = defines;
        // Other native libraries it links: another npm library's (`pkg::Name`) or a prefab from a
        // Maven AAR (`mmkv::mmkv`). React Native's, fbjni, log and android are always linked.
        const links = l.links
          .filter((x) => !/^(ReactAndroid|fbjni)::/.test(x) && !/^(android|log|\$\{.*\})$/.test(x) && !x.startsWith("-"))
          .map((x) => x.split("::").pop())
          .filter((x) => !/^(LOG_LIB|jsi|reactnative|fbjni|c\+\+_shared)$/.test(x));
        if (links.length) lib.sharedLibraryLinks[l.name] = links;
      }
      if (Object.keys(lib.sharedLibraries).length) {
        for (const [prefix, dirs] of Object.entries(prefabHeaders(gradle, androidDir))) {
          lib.prefabHeaders[prefix] = dirs.map(rel).sort();
        }
      }
    }
  }
  if (android.cxxModuleHeaderName) {
    lib.cxxModules[android.cxxModuleHeaderName] = `${android.cxxModuleHeaderName}.h`;
  }
  return lib;
}

function starlarkList(items, indent) {
  if (items.length === 0) return "[]";
  const pad = " ".repeat(indent + 4);
  return `[\n${items.map((i) => `${pad}${JSON.stringify(i)},`).join("\n")}\n${" ".repeat(indent)}]`;
}

function starlarkDict(obj, indent) {
  const keys = Object.keys(obj).sort();
  if (keys.length === 0) return "{}";
  const pad = " ".repeat(indent + 4);
  const value = (v) => (Array.isArray(v) ? starlarkList(v, indent + 4) : JSON.stringify(v));
  return `{\n${keys.map((k) => `${pad}${JSON.stringify(k)}: ${value(obj[k])},`).join("\n")}\n${" ".repeat(indent)}}`;
}

function mavenLabel(coordinate) {
  return `maven + "//:${coordinate.replace(/[^A-Za-z0-9_]/g, "_")}"`;
}

function render(libs, label, maven, expoPackageList) {
  const lines = [
    `"""React Native libraries from npm, generated by \`bazel run ${label}\`. Do not edit.`,
    "",
    "Re-run it after adding, removing or upgrading a native npm dependency; the generated",
    `\`${label}_test\` fails while this file is stale.`,
    '"""',
    "",
    expoPackageList
      ? 'load("@rules_react_native//react_native:defs.bzl", "react_native_codegen", "react_native_expo_package_list", "react_native_npm_library")'
      : 'load("@rules_react_native//react_native:defs.bzl", "react_native_codegen", "react_native_npm_library")',
    "",
    `def react_native_libraries(node_modules = ":node_modules", maven = ${JSON.stringify(maven)}, **kwargs):`,
    '    """Declares one react_native_npm_library per native dependency; returns their labels for the app\'s deps."""',
  ];
  if (libs.length === 0) {
    lines.push("    return []", "");
    return lines.join("\n");
  }
  for (const lib of libs) {
    const attrs = [];
    const a = (k, v) => attrs.push(`        ${k} = ${v},`);
    if (lib.codegen) {
      lines.push(
        "    react_native_codegen(",
        `        name = "${lib.target}_codegen",`,
        `        java_package = "${lib.codegen.javaPackage}",`,
        `        js_srcs_dir = "${lib.codegen.jsSrcsDir}",`,
        `        library_name = "${lib.codegen.libraryName}",`,
        "        node_modules = node_modules,",
        `        npm_package = "${lib.npmPackage}",`,
        "        **kwargs",
        "    )",
      );
    }
    a("name", JSON.stringify(lib.target));
    if (lib.buildConfig) a("build_config", "True");
    if (Object.keys(lib.buildConfigConstants).length) a("build_config_constants", starlarkDict(lib.buildConfigConstants, 8));
    if (lib.ccIncludes.length) a("cc_includes", starlarkList([...new Set(lib.ccIncludes)], 8));
    if (lib.ccSrcs.length) a("cc_srcs", starlarkList([...new Set(lib.ccSrcs)], 8));
    if (lib.codegen) a("codegen", `[":${lib.target}_codegen"]`);
    if (lib.codegen && lib.codegenCcDirs?.length) a("codegen_cc_dirs", starlarkList(lib.codegenCcDirs, 8));
    if (lib.componentDescriptors) a("component_descriptors", starlarkList(lib.componentDescriptors, 8));
    if (Object.keys(lib.cxxModules).length) a("cxx_modules", starlarkDict(lib.cxxModules, 8));
    if (lib.libraryDeps.length) {
      a("deps", starlarkList(lib.libraryDeps.map((d) => `:${targetName(d)}`), 8));
    }
    a("java_dirs", starlarkList(lib.javaDirs, 8));
    a("manifest", JSON.stringify(lib.manifest));
    if (lib.maven.length) {
      a(
        "maven_deps",
        `[\n${lib.maven.map((d) => `            ${mavenLabel(d.coordinate)},`).join("\n")}\n        ]`,
      );
    }
    if (lib.kotlinPlugins?.length) {
      a("kotlin_plugins", `[\n${lib.kotlinPlugins.map((d) => `            ${mavenLabel(d.coordinate)},`).join("\n")}\n        ]`);
    }
    if (lib.expo?.viaExpo) {
      // Expo's own modules come with the expo package; they have no link target of their own.
      a("npm_package", `node_modules + "/expo"`);
      a("npm_package_name", JSON.stringify(lib.npmPackage));
    } else {
      a("npm_package", `node_modules + "/${lib.npmPackage}"`);
    }
    a("package", JSON.stringify(lib.package));
    if (lib.prebuiltNativeLibs) a("prebuilt_native_libs", starlarkDict(lib.prebuiltNativeLibs, 8));
    if (Object.keys(lib.prefabHeaders).length) a("prefab_headers", starlarkDict(lib.prefabHeaders, 8));
    if (lib.proguard.length) a("proguard_specs", starlarkList(lib.proguard, 8));
    if (lib.reactPackages.length) a("react_packages", starlarkList(lib.reactPackages, 8));
    if (lib.resDirs.length) a("res_dirs", starlarkList(lib.resDirs, 8));
    if (Object.keys(lib.sharedLibraries).length) {
      a("shared_libraries", starlarkDict(lib.sharedLibraries, 8));
      if (Object.keys(lib.sharedLibraryDefines).length) a("shared_library_defines", starlarkDict(lib.sharedLibraryDefines, 8));
      a("shared_library_includes", starlarkDict(lib.sharedLibraryIncludes, 8));
      if (Object.keys(lib.sharedLibraryLinks).length) a("shared_library_links", starlarkDict(lib.sharedLibraryLinks, 8));
    }
    lines.push("    react_native_npm_library(", ...attrs, "        **kwargs", "    )");
  }
  const targets = libs.map((l) => l.target);
  if (expoPackageList) {
    const expoTargets = libs.filter((l) => l.expo).map((l) => `:${l.target}`);
    lines.push(
      "    react_native_expo_package_list(",
      '        name = "expo_package_list",',
      `        deps = ${starlarkList(expoTargets, 8)},`,
      `        modules = ${starlarkDict(expoPackageList.modules, 8)},`,
      `        packages = ${starlarkList(expoPackageList.packages, 8)},`,
      `        services = ${starlarkList(expoPackageList.services, 8)},`,
      "        **kwargs",
      "    )",
    );
    targets.push("expo_package_list");
  }
  lines.push("    return [", ...targets.map((t) => `        ":${t}",`), "    ]", "");
  return lines.join("\n");
}

function main() {
  const packageJson = path.resolve(args["package-json"]);
  const app = JSON.parse(fs.readFileSync(packageJson, "utf8"));
  const appRequire = createRequire(packageJson);
  const rnPackage = JSON.parse(fs.readFileSync(appRequire.resolve("react-native/package.json"), "utf8"));
  const reactNativeMinor = Number(rnPackage.version.split(".")[1]);
  const appDeps = new Set(Object.keys(app.dependencies ?? {}));
  const expoModules = resolveExpoModules(packageJson, appRequire);
  const expo = expoModules ? describeExpo(expoModules, appDeps, rnPackage.version, reactNativeMinor) : null;
  const expoPackages = new Set(expo ? expo.libs.map((l) => l.npmPackage) : []);
  const libs = [];
  for (const name of Object.keys(app.dependencies ?? {}).sort()) {
    if (name === "react-native" || name === "react" || expoPackages.has(name)) continue;
    let pkgDir;
    try {
      pkgDir = fs.realpathSync(path.dirname(appRequire.resolve(`${name}/package.json`)));
    } catch {
      // Packages whose `exports` hide package.json: find the directory through node_modules.
      pkgDir = fs.realpathSync(path.join(path.dirname(packageJson), "node_modules", name));
    }
    const lib = describe(name, pkgDir, appDeps, reactNativeMinor);
    if (lib) libs.push(lib);
  }
  if (expo) libs.push(...expo.libs);
  libs.sort((a, b) => a.target.localeCompare(b.target));
  const text = render(libs, args.label, args.maven, expo?.packageList);

  if (args.check) {
    const current = fs.readFileSync(args.check, "utf8");
    if (current !== text) {
      fail(`${args.check} is out of date; run \`bazel run ${args.label}\``);
    }
    console.log(`${args.check} is up to date (${libs.length} native libraries)`);
    return;
  }
  const workspace = process.env.BUILD_WORKSPACE_DIRECTORY;
  if (!workspace) fail("run me with `bazel run`");
  fs.writeFileSync(path.join(workspace, args.out), text);
  console.log(`wrote ${args.out}: ${libs.map((l) => l.npmPackage).join(", ") || "no native libraries"}`);
  const maven = new Map();
  for (const lib of libs) {
    for (const d of [...lib.maven, ...(lib.kotlinPlugins ?? [])]) {
      if (!maven.has(d.coordinate) || d.version) maven.set(d.coordinate, d.version);
    }
  }
  if (maven.size) {
    console.log(
      `\nThe libraries use these Maven artifacts; the app's Maven spec must pin them (then re-pin):\n${[...maven]
        .sort()
        .map(([c, v]) => `  ${c}${v ? `:${v}` : ""}`)
        .join("\n")}`,
    );
  }
}

main();
