const path = require("node:path");

module.exports = {
  // The package's `exports` only exposes "." (its jest-preset.js), which blocks Jest's lookup of the
  // "<preset>/jest-preset" subpath under strict resolution. Jest treats a preset as a file path only
  // when it starts with ".", so hand it the resolved file relative to this directory.
  preset: `./${path.relative(__dirname, require.resolve("@react-native/jest-preset"))}`,
  // The preset transforms react-native's own (Flow) sources; under pnpm/rules_js they sit behind
  // node_modules/.aspect_rules_js/<pkg>@<version>/node_modules/<pkg>, so let that prefix through too.
  // rules_jest sets its own `haste` options (symlink support), and Jest takes object options from the
  // config over the preset's wholesale, so restate the preset's platform resolution here.
  haste: {
    defaultPlatform: "ios",
    platforms: ["android", "ios", "native"],
  },
  // Babel injects `@babel/runtime/helpers/*` imports into files inside react-native and the preset;
  // npm hoisting makes the app's copy visible from there, pnpm's strict layout doesn't.
  modulePaths: [path.join(__dirname, "node_modules")],
  transformIgnorePatterns: ["node_modules/(?!(\\.aspect_rules_js|(jest-)?react-native|@react-native(-community)?)/)"],
};
