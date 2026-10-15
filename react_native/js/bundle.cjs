// Bundles a React Native app with Metro and compiles it to Hermes bytecode, inside a Bazel action.
// The source map is what react-native's Gradle plugin produces: Metro's packager map composed with
// hermesc's, so crash reporters can symbolicate bytecode stack traces back to the sources.
"use strict";

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { parseArgs } = require("node:util");
const { loadMetroConfig } = require("./metro_config.cjs");

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

async function main() {
  const projectRoot = path.resolve(args["project-root"]);
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
