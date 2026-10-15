// Metro configuration shared by the bundler (a Bazel action) and the dev server (`bazel run`).
//
// Every tool is resolved through the app's own `react-native` dependency, so apps declare the
// same packages a stock React Native project does and the ruleset carries no npm dependencies.
"use strict";

const fs = require("node:fs");
const { createRequire } = require("node:module");
const path = require("node:path");

const STORE_MARKER = `${path.sep}node_modules${path.sep}.aspect_rules_js${path.sep}`;

/** Requires rooted at the app, at react-native, and at RN's CLI plugin (which depends on metro). */
function appRequires(projectRoot) {
  const app = createRequire(path.join(projectRoot, "package.json"));
  const rn = createRequire(app.resolve("react-native/package.json"));
  const cli = createRequire(rn.resolve("@react-native/community-cli-plugin/package.json"));
  return { app, rn, cli };
}

// rules_js lays packages out in a virtual store under <bindir>/node_modules/.aspect_rules_js and
// symlinks them into each package's node_modules. Metro serves only files under projectRoot or a
// watch folder, and it follows symlinks one hop at a time, so every directory a package link passes
// through must be watched: inside a Bazel action that is just the store, but js_run_devserver adds
// a hop through the package's node_modules in bazel-out before reaching the store.
function linkRoots(projectRoot) {
  const roots = [];
  const covered = (dir) => [projectRoot, ...roots].some((r) => dir === r || dir.startsWith(r + path.sep));
  const add = (dir) => {
    if (!covered(dir)) {
      roots.push(dir);
    }
  };
  for (let dir = projectRoot; path.dirname(dir) !== dir; dir = path.dirname(dir)) {
    if (fs.existsSync(path.join(dir, "node_modules", ".aspect_rules_js"))) {
      add(path.join(dir, "node_modules"));
      break;
    }
  }
  let link = path.join(projectRoot, "node_modules", "react-native");
  while (fs.lstatSync(link).isSymbolicLink()) {
    const target = path.resolve(path.dirname(link), fs.readlinkSync(link));
    const idx = target.indexOf(STORE_MARKER);
    add(idx >= 0 ? path.join(target.slice(0, idx), "node_modules") : path.dirname(target));
    link = target;
  }
  if (roots.length === 0) {
    throw new Error(`no rules_js node_modules store found for ${projectRoot}`);
  }
  return roots;
}

/**
 * @param {string} projectRoot
 * @param {{ hermetic: boolean }} options `hermetic` disables Metro's cache and file watching, for
 *   a one-shot Bazel action; the dev server keeps both for Fast Refresh.
 */
async function loadMetroConfig(projectRoot, { hermetic }) {
  const req = appRequires(projectRoot);
  const { loadConfig, mergeConfig } = req.cli("metro");
  const { getDefaultConfig } = req.app("@react-native/metro-config");

  const userConfigPath = ["metro.config.js", "metro.config.cjs"]
    .map((f) => path.join(projectRoot, f))
    .find((f) => fs.existsSync(f));
  const baseConfig = userConfigPath
    ? await loadConfig({ cwd: projectRoot, config: userConfigPath })
    : getDefaultConfig(projectRoot);
  const overrides = {
    projectRoot,
    // metro's loadConfig() prepends projectRoot to watchFolders; getDefaultConfig() alone does not.
    watchFolders: [...new Set([projectRoot, ...(baseConfig.watchFolders ?? []), ...linkRoots(projectRoot)])],
    resolver: {
      useWatchman: false,
      // Babel injects `@babel/runtime/helpers/*` imports into files inside react-native itself.
      // npm/yarn hoisting makes the app's copy visible from there; pnpm's strict layout does not,
      // so the app's node_modules is the fallback for every module.
      nodeModulesPaths: [...(baseConfig.resolver?.nodeModulesPaths ?? []), path.join(projectRoot, "node_modules")],
    },
    serializer: {
      // @react-native/metro-config resolves this from its own location, which only works when
      // react-native is hoisted next to it.
      getModulesRunBeforeMainModule: () => [req.app.resolve("react-native/Libraries/Core/InitializeCore")],
    },
  };
  if (hermetic) {
    // Bazel caches the action; Metro's own cache would live outside the sandbox.
    overrides.cacheStores = [];
    overrides.resetCache = true;
    overrides.watcher = { healthCheck: { enabled: false } };
  }
  return { config: mergeConfig(baseConfig, overrides), req };
}

module.exports = { appRequires, loadMetroConfig };
