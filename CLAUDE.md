# rules_react_native

Builds React Native apps with Bazel: no Gradle, CocoaPods or local Android SDK. Android
produces a signed APK; iOS stops at the JS bundle for now. [README.md](README.md) has the
setup, pipeline, dependency model, API and limitations. Read it before changing anything here.

Two Bazel modules live here: the ruleset at the root, and [`examples/`](examples), a separate
consumer module (`.bazelignore`d from the root) that depends on it via `local_path_override`. Root
`bazel test //...` runs the tool unit tests; `cd examples && bazel build //...` builds every app.

## Public API

- [`react_native/defs.bzl`](react_native/defs.bzl): `react_native_bundle`, `react_native_codegen`,
  `react_native_dev_server`, `react_native_maven_pin`, `react_native_android_app` (also defines
  `<name>.install`; `debug = True` builds against the consumer's `@rn_maven_debug` and loads JS
  from the dev server).
- [`react_native/extensions.bzl`](react_native/extensions.bzl): the `react_native` extension. It
  always creates the ruleset's `@rn_android_sdk`, `@rn_android_ndk` and `@rn_android_tools_maven`
  (used through `Label()` inside the rules, never by consumers) plus one hub per
  `react_native.maven(name, lock_file)` tag. Consumers own their React Native version through
  those lockfiles.
- `bazel run //react_native/android/tools:pin_tools` re-pins the ruleset's own manifest-merger
  lockfile. Never hand-edit lockfiles.

## Gotchas

- **`libappmodules.so` is required**, even though `DefaultSoLoader` treats it as optional. Without
  it the app boots Hermes and then dies on `TurboModuleRegistry.getEnforcing('PlatformConstants')`,
  because `OnLoad.cpp` is what installs the Java TurboModule provider.
- **Java tools run on JDK 21** through `_java_runtime` (`@rules_java//toolchains:remotejdk_21`).
  The repo's default exec JVM is 11, and AGP's manifest merger and build-tools 36 need 17+. Don't
  switch them back to `java_binary` launchers.
- **Maven resolution is Gradle-shaped** (module metadata, `available-at`, variants, constraints).
  A plain POM resolver (coursier) would pick empty KMP root jars and the wrong react-android variant.
- **Metro under rules_js** needs the store root as a watch folder, the app's `node_modules` in
  `nodeModulesPaths`, and `InitializeCore` resolved from the app. See the comments in
  [`react_native/js/metro_config.cjs`](react_native/js/metro_config.cjs). Apps must declare `@babel/runtime`.
- **A React Native bump** is split between consumer and ruleset. Consumers move `react-native` in
  `package.json` and `react-android`/`hermes-android` in their specs (hermes version = the
  `hermes-compiler` npm version react-native depends on), then re-pin. The ruleset must track the
  NDK in `react_native/android/private/versions.bzl` (match `ndkVersion` in react-native's
  `gradle/libs.versions.toml`), `react_native/android/native/OnLoad.cpp`, and the generated-source
  templates in `react_native/android/private/android_app.bzl` (they mirror
  `@react-native/gradle-plugin`'s `GenerateEntryPointTask` / `GeneratePackageListTask`).
- **Labels inside macros resolve in the caller's repo.** Anything that must point into this module
  (the SDK repo, the debug keystore) is wrapped in `Label()`; the Maven hubs are deliberately plain
  strings (`maven = "@rn_maven//:all"`) because they're the consumer's repos.
- **Generated repo BUILD files must not rely on the consumer's flags**: globs over AAR contents pass
  `allow_empty = True` (Bazel 8+ rejects empty globs by default; most AARs have no `assets/`).
- **Consumers need a hermetic JDK** (`--java_runtime_version=remotejdk_21`); a module can't set it.
- **`NDEBUG` must match the react-android variant**: on for release, off for debug (the debug
  `libreactnative.so` exports the `RN_DEBUG_STRING_CONVERTIBLE` virtuals, the release one doesn't).
  A mismatch makes codegen'd Fabric components fail to link (`getDebugProps`, `getDebugName`, ...).
- **Dev server endpoints**: `react_native/js/dev_server.cjs` serves `/status` and the `/message` websocket itself
  because `@react-native-community/cli-server-api` isn't installed. Without `/message` the dev menu
  shows "Connect to the bundler to debug JavaScript" instead of "Open DevTools".
- **Metro under `js_run_devserver`** reaches the store through an extra symlink hop
  (`bazel-out/.../<pkg>/node_modules`); `metro_config.cjs` watches every hop's directory, otherwise
  Metro can't resolve `react-native` at all.
- `autolinking.cpp` is generated per app in `appmodules.bzl` from the `codegen` targets; only
  `autolinking.h` is a static file.
- `glob()` has no character classes. `[0-9]*` silently matches nothing.

## Layout

| Path | Contents |
| --- | --- |
| [`react_native/`](react_native) | `defs.bzl`, `extensions.bzl` |
| [`react_native/android/`](react_native/android) | Tools lockfile/spec and the public debug keystore |
| [`react_native/android/private/`](react_native/android/private) | Repository rules, `android_maven_import`, resource/APK/appmodules/pin rules, pinned SDK/NDK versions |
| [`react_native/android/native/`](react_native/android/native) | `OnLoad.cpp` and `autolinking.h` |
| [`react_native/android/tools/`](react_native/android/tools) | `maven_resolve.py`, `gen_r.py`, `build_apk.py` and their unittest tests |
| [`react_native/js/`](react_native/js) | `bundle.cjs`, `dev_server.cjs`, `codegen.cjs`, the shared `metro_config.cjs`, and their rules |
| [`examples/`](examples) | Consumer module: `hello`, `native_modules`, Maven specs/lockfiles in `android/`, `:pin` |
