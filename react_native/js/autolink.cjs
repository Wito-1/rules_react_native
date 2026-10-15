// Generates react_native_codegen + react_native_npm_library targets for an app's npm dependencies
// that ship Android code: what @react-native/gradle-plugin's autolinking learns from
// `react-native config`, read from each package's package.json (codegenConfig),
// react-native.config.js and android/build.gradle.
//
//   bazel run //app:autolink           writes <app>/react_native_libraries.bzl
//   bazel test //app:autolink_test     fails when that file is out of date
"use strict";

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


// Just enough CMake to list what a library's CMakeLists.txt compiles: set(), file(GLOB[_RECURSE]),
// add_library() and include directories. Conditionals are not evaluated (every branch counts),
// sources under build/generated (codegen, which Bazel generates itself) and anything under
// React Native's own tree (prefab headers stand in for it) are dropped.
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

function readCMake(file) {
  const dir = path.dirname(file);
  const vars = { CMAKE_CURRENT_SOURCE_DIR: dir, CMAKE_SOURCE_DIR: dir, PROJECT_SOURCE_DIR: dir };
  const subst = (s) => s.replace(/\$\{(\w+)\}/g, (_, v) => vars[v] ?? `\u0000${v}`);
  const values = (argv) =>
    argv.flatMap((a) => subst(a).split(";")).filter((a) => a !== "" && !CMAKE_KEYWORDS.has(a));
  const resolve = (p) => (path.isAbsolute(p) ? path.normalize(p) : path.join(dir, p));
  const libraries = {};
  const globalIncludes = [];
  const codegenDirs = new Set();
  for (const { name, argv } of cmakeCommands(fs.readFileSync(file, "utf8"))) {
    if (name === "project" && argv[0]) {
      vars.PROJECT_NAME = argv[0];
    } else if (name === "set" && argv.length) {
      vars[argv[0]] = values(argv.slice(1)).join(";");
    } else if (name === "file" && /^GLOB(_RECURSE)?$/.test(argv[0])) {
      const recursive = argv[0] === "GLOB_RECURSE";
      const patterns = values(argv.slice(2)).filter((p) => !p.includes("\u0000"));
      for (const p of patterns) {
        const m = resolve(p).split(path.sep).join("/").match(/build\/generated\/source\/codegen\/jni\/?(.*)$/);
        if (m) {
          // Codegen output the library compiles; recursive globs take all of it.
          codegenDirs.add(recursive ? "**" : path.posix.dirname(m[1] || "x") || ".");
        }
      }
      vars[argv[1]] = patterns.flatMap((p) => expandGlob(resolve(p), recursive)).join(";");
    } else if (name === "add_library" && argv.length) {
      const target = subst(argv[0]);
      libraries[target] ??= { sources: [], includes: [] };
      libraries[target].sources.push(...values(argv.slice(1)).filter((p) => !p.includes("\u0000")).map(resolve));
    } else if (name === "target_include_directories" && argv.length) {
      const target = subst(argv[0]);
      libraries[target] ??= { sources: [], includes: [] };
      libraries[target].includes.push(...values(argv.slice(1)).filter((p) => !p.includes("\u0000")).map(resolve));
    } else if (name === "include_directories") {
      globalIncludes.push(...values(argv).filter((p) => !p.includes("\u0000")).map(resolve));
    }
  }
  const keep = (p) => !p.includes(`${path.sep}build${path.sep}generated`) && fs.existsSync(p);
  return Object.entries(libraries).map(([name, lib]) => ({
    name,
    sources: [...new Set(lib.sources)].filter(keep).filter((p) => /\.(c|cc|cpp)$/.test(p)),
    includes: [...new Set([...lib.includes, ...globalIncludes])].filter(keep),
    codegenDirs: codegenDirs.has("**") ? null : [...codegenDirs].sort(),
  }));
}

// Gradle source sets the new architecture compiles: directories named in build.gradle's
// sourceSets (srcDirs/directories.add), minus old-architecture ones. Pairs like svg/ and nosvg/
// (optional integrations) follow whether the app depends on the matching react-native-* package.
function sourceSetDirs(gradle, androidDir, appDeps) {
  const named = [...gradle.matchAll(/["']((?:src\/|[\w-]+\/src\/)[\w/.-]+)["']/g)].map((m) => m[1]);
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

function buildConfigConstants(gradle) {
  const constants = {};
  for (const m of gradle.matchAll(/buildConfigField\s*\(?\s*["'](\w+)["']\s*,\s*["'](\w+)["']\s*,\s*([^\n)]*)/g)) {
    const [, type, name, raw] = m;
    if (ALWAYS_DECLARED.has(name)) continue;
    const literal = raw.trim().match(/^["']([^"'$]*)["']$/);
    constants[name] = `${type} ${literal ? literal[1] : ZERO[type] ?? "null"}`;
  }
  return constants;
}

// Gradle `implementation`/`api` Maven coordinates. React Native itself and the Kotlin stdlib come
// with react-android.
function mavenDeps(gradle) {
  const deps = new Map();
  for (const m of gradle.matchAll(/^\s*(?:implementation|api)\s*\(?\s*["']([\w.-]+):([\w.-]+)(?::([^"']*))?["']/gm)) {
    const [, group, artifact, version] = m;
    if (group === "com.facebook.react" || (group === "org.jetbrains.kotlin" && artifact.startsWith("kotlin-stdlib"))) {
      continue;
    }
    deps.set(`${group}:${artifact}`, version && !version.includes("$") && version !== "+" ? version : null);
  }
  return [...deps].sort().map(([coordinate, version]) => ({ coordinate, version }));
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

function targetName(npmPackage) {
  return "npm_" + npmPackage.replace(/^@/, "").replace(/[^A-Za-z0-9]+/g, "_");
}

function describe(name, pkgDir, appDeps) {
  const pkg = JSON.parse(fs.readFileSync(path.join(pkgDir, "package.json"), "utf8"));
  const platforms = loadConfig(pkgDir);
  if (platforms.android === null) {
    return null;
  }
  const android = platforms.android ?? {};
  const androidRel = android.sourceDir ?? "android";
  const androidDir = path.join(pkgDir, androidRel);
  if (!exists(androidDir, "build.gradle") && !exists(androidDir, "build.gradle.kts")) {
    return null;
  }
  const gradle = fs.readFileSync(
    [path.join(androidDir, "build.gradle"), path.join(androidDir, "build.gradle.kts")].find(fs.existsSync),
    "utf8",
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
    javaDirs: javaDirs.map((d) => `${androidRel}/${d}`),
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
    cxxModules: {},
    maven: mavenDeps(gradle),
    libraryDeps: [...new Set([...gradle.matchAll(/it\.name\s*==\s*["']([\w@/.-]+)["']/g)].map((m) => m[1]))]
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
    for (const l of readCMake(autolinked)) {
      lib.ccSrcs.push(...l.sources.map(rel));
      lib.ccIncludes.push(...l.includes.map(rel));
      if (l.codegenDirs) lib.codegenCcDirs = l.codegenDirs;
    }
  }
  // The library's own externalNativeBuild builds .so files its Java loads by name.
  const own = gradle.match(/externalNativeBuild\s*\{\s*cmake\s*\{[^}]*?path\s*=?\s*\(?\s*["']([^"']+)["']/);
  if (own) {
    const file = path.join(androidDir, own[1]);
    if (path.resolve(file) !== path.resolve(autolinked) && fs.existsSync(file)) {
      for (const l of readCMake(file)) {
        if (l.sources.length === 0) continue;
        lib.sharedLibraries[l.name] = l.sources.map(rel);
        lib.sharedLibraryIncludes[l.name] = l.includes.map(rel);
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

function render(libs, label, maven) {
  const lines = [
    `"""React Native libraries from npm, generated by \`bazel run ${label}\`. Do not edit.`,
    "",
    "Re-run it after adding, removing or upgrading a native npm dependency; the generated",
    `\`${label}_test\` fails while this file is stale.`,
    '"""',
    "",
    'load("@rules_react_native//react_native:defs.bzl", "react_native_codegen", "react_native_npm_library")',
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
        `[\n${lib.maven.map((d) => `            maven + "//:${d.coordinate.replace(/[^A-Za-z0-9_]/g, "_")}",`).join("\n")}\n        ]`,
      );
    }
    a("npm_package", `node_modules + "/${lib.npmPackage}"`);
    a("package", JSON.stringify(lib.package));
    if (lib.proguard.length) a("proguard_specs", starlarkList(lib.proguard, 8));
    if (lib.reactPackages.length) a("react_packages", starlarkList(lib.reactPackages, 8));
    if (lib.resDirs.length) a("res_dirs", starlarkList(lib.resDirs, 8));
    if (Object.keys(lib.sharedLibraries).length) {
      a("shared_libraries", starlarkDict(lib.sharedLibraries, 8));
      a("shared_library_includes", starlarkDict(lib.sharedLibraryIncludes, 8));
    }
    lines.push("    react_native_npm_library(", ...attrs, "        **kwargs", "    )");
  }
  lines.push("    return [", ...libs.map((l) => `        ":${l.target}",`), "    ]", "");
  return lines.join("\n");
}

function main() {
  const packageJson = path.resolve(args["package-json"]);
  const app = JSON.parse(fs.readFileSync(packageJson, "utf8"));
  const appRequire = createRequire(packageJson);
  const libs = [];
  for (const name of Object.keys(app.dependencies ?? {}).sort()) {
    if (name === "react-native" || name === "react") continue;
    let pkgDir;
    try {
      pkgDir = fs.realpathSync(path.dirname(appRequire.resolve(`${name}/package.json`)));
    } catch {
      // Packages whose `exports` hide package.json: find the directory through node_modules.
      pkgDir = fs.realpathSync(path.join(path.dirname(packageJson), "node_modules", name));
    }
    const lib = describe(name, pkgDir, new Set(Object.keys(app.dependencies ?? {})));
    if (lib) libs.push(lib);
  }
  const text = render(libs, args.label, args.maven);

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
    for (const d of lib.maven) {
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
