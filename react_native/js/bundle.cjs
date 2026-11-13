// Bundles a React Native app with Metro and compiles it to Hermes bytecode, inside a Bazel action.
// The source map is what react-native's Gradle plugin produces: Metro's packager map composed with
// hermesc's, so crash reporters can symbolicate bytecode stack traces back to the sources.
"use strict";

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { parseArgs } = require("node:util");
const { createRequire } = require("node:module");
const { linkRoots, loadMetroConfig } = require("./metro_config.cjs");

const { values: args } = parseArgs({
  allowNegative: true,
  options: {
    "project-root": { type: "string" },
    entry: { type: "string" },
    platform: { type: "string" },
    dev: { type: "boolean", default: false },
    "bundle-out": { type: "string" },
    "sourcemap-out": { type: "string" },
    "assets-dest": { type: "string" },
    hermes: { type: "boolean", default: true },
  },
});

function fail(message) {
  console.error(`react_native_bundle: ${message}`);
  process.exit(1);
}

function hermescPath(hermesCompilerDir) {
  const hostDir = {
    linux: "linux64-bin",
    darwin: "osx-bin",
  }[process.platform];
  if (hostDir == null) {
    fail(`hermesc has no build for host ${process.platform}`);
  }
  return path.join(hermesCompilerDir, "hermesc", hostDir, "hermesc");
}

// The Expo CLI's bin, when the app depends on expo: its Metro setup (autolinking-based module
// resolution, virtual modules such as expo/virtual/env) only exists inside the CLI.
function expoCli(projectRoot) {
  try {
    return createRequire(path.join(projectRoot, "package.json")).resolve("expo/bin/cli");
  } catch {
    return null;
  }
}

// `expo export:embed`, as Expo's Gradle and Xcode build phases run it, with a Metro config that
// wraps the app's own (or Expo's default) to watch the rules_js store the packages live in.
function expoBundle(projectRoot, cli) {
  const work = path.resolve(`${args["bundle-out"]}.expo`);
  fs.mkdirSync(work, { recursive: true });
  const userConfig = ["metro.config.js", "metro.config.cjs"]
    .map((f) => path.join(projectRoot, f))
    .find((f) => fs.existsSync(f));
  const metroConfig = path.join(work, "metro.config.cjs");
  fs.writeFileSync(
    metroConfig,
    `"use strict";
const projectRoot = ${JSON.stringify(projectRoot)};
const extraRoots = ${JSON.stringify(linkRoots(projectRoot))};
module.exports = async () => {
  let config = ${
    userConfig
      ? `require(${JSON.stringify(userConfig)})`
      : `require(require.resolve("expo/metro-config", { paths: [projectRoot] })).getDefaultConfig(projectRoot)`
  };
  if (typeof config === "function") config = await config();
  config = await config;
  return {
    ...config,
    watchFolders: [...new Set([...(config.watchFolders ?? []), ...extraRoots])],
    cacheStores: [],
    resetCache: true,
  };
};
`,
  );
  fs.mkdirSync(args["assets-dest"], { recursive: true });
  const cliArgs = [
    cli,
    "export:embed",
    `--platform=${args.platform}`,
    `--dev=${args.dev}`,
    `--minify=${!args.dev}`,
    `--entry-file=${args.entry}`,
    `--bundle-output=${path.resolve(args["bundle-out"])}`,
    `--sourcemap-output=${path.resolve(args["sourcemap-out"])}`,
    `--assets-dest=${path.resolve(args["assets-dest"])}`,
    `--config=${metroConfig}`,
    "--reset-cache",
  ];
  if (args.hermes) cliArgs.push("--bytecode");
  const tmp = path.join(work, "tmp");
  fs.mkdirSync(tmp, { recursive: true });
  const result = spawnSync(process.execPath, cliArgs, {
    cwd: projectRoot,
    stdio: "inherit",
    env: {
      ...process.env,
      // Expo's .env loading and telemetry are off: an action's inputs are its only config.
      CI: "1",
      EXPO_NO_DOTENV: "1",
      EXPO_NO_TELEMETRY: "1",
      // Metro caches transforms in os.tmpdir() under a key that ignores env vars.
      TMPDIR: tmp,
    },
  });
  if (result.status !== 0) {
    fail(`expo export:embed exited with ${result.status ?? result.signal}`);
  }
  fs.rmSync(work, { recursive: true, force: true });
  relativizeSources(args["sourcemap-out"], projectRoot);
}

async function main() {
  const projectRoot = path.resolve(args["project-root"]);
  const cli = expoCli(projectRoot);
  if (cli) {
    expoBundle(projectRoot, cli);
    return;
  }
  const { config, req } = await loadMetroConfig(projectRoot, { hermetic: true });
  const { unstable_buildBundleWithConfig } = req.cli("@react-native/community-cli-plugin");

  const jsBundle = args.hermes ? `${args["bundle-out"]}.js` : args["bundle-out"];
  const packagerMap = args.hermes ? `${jsBundle}.map` : args["sourcemap-out"];
  fs.mkdirSync(args["assets-dest"], { recursive: true });
  await unstable_buildBundleWithConfig(
    {
      platform: args.platform,
      entryFile: path.resolve(projectRoot, args.entry),
      dev: args.dev,
      // Hermes optimizes the bytecode itself; minifying first only slows the build.
      minify: args.hermes ? false : !args.dev,
      bundleOutput: path.resolve(jsBundle),
      sourcemapOutput: path.resolve(packagerMap),
      assetsDest: path.resolve(args["assets-dest"]),
      resetCache: true,
    },
    config,
  );

  if (args.hermes) {
    const hermesCompilerDir = path.dirname(req.rn.resolve("hermes-compiler/package.json"));
    const hermesc = hermescPath(hermesCompilerDir);
    const flags = [
      "-w",
      "-emit-binary",
      "-max-diagnostic-width=80",
      "-output-source-map",
      "-out",
      args["bundle-out"],
    ];
    if (!args.dev) {
      flags.push("-O");
    }
    const result = spawnSync(hermesc, [...flags, jsBundle], { stdio: "inherit" });
    if (result.status !== 0) {
      fail(`hermesc exited with ${result.status ?? result.signal}`);
    }
    // hermesc writes <bundle>.map, which may be the requested output path itself.
    const hermesMap = `${args["bundle-out"]}.map`;
    const composed = `${args["sourcemap-out"]}.composed`;
    const compose = spawnSync(
      process.execPath,
      [
        path.join(path.dirname(req.rn.resolve("react-native/package.json")), "scripts/compose-source-maps.js"),
        packagerMap,
        hermesMap,
        "-o",
        composed,
      ],
      { stdio: "inherit" },
    );
    if (compose.status !== 0) {
      fail(`compose-source-maps exited with ${compose.status ?? compose.signal}`);
    }
    for (const f of [jsBundle, packagerMap, hermesMap]) {
      fs.rmSync(f, { force: true });
    }
    fs.renameSync(composed, args["sourcemap-out"]);
  }
  relativizeSources(args["sourcemap-out"], projectRoot);
}

// Metro writes absolute (sandbox) paths, and the CLI drops `sourcemapSourcesRoot`; paths relative
// to the app keep the map identical across sandboxes and checkouts.
function relativizeSources(mapPath, root) {
  const map = JSON.parse(fs.readFileSync(mapPath, "utf8"));
  map.sources = map.sources.map((s) => (path.isAbsolute(s) ? path.relative(root, s) : s));
  fs.writeFileSync(mapPath, JSON.stringify(map));
}

main().then(
  // Metro leaves worker processes and timers alive after runBuild resolves.
  () => process.exit(0),
  (err) => fail(err?.stack ?? String(err)),
);
