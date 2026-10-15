# rules_react_native

Bazel rules that build React Native apps without Gradle, CocoaPods or a local Android SDK.
Android is supported today: release and debug APKs, Metro with Fast Refresh, and codegen'd
TurboModules and Fabric components. iOS currently stops at the JS bundle (see [iOS](#ios)).

## Setup

`MODULE.bazel` (not on the BCR yet, so pin a commit):

```starlark
bazel_dep(name = "rules_react_native", version = "0.1.0")
archive_override(
    module_name = "rules_react_native",
    integrity = "sha256-...",
    strip_prefix = "rules_react_native-<commit>",
    urls = ["https://github.com/Wito-1/rules_react_native/archive/<commit>.tar.gz"],
)

# Your React Native version is whatever these lockfiles pin (see "Maven" below).
react_native = use_extension("@rules_react_native//react_native:extensions.bzl", "react_native")
react_native.maven(name = "rn_maven", lock_file = "//android:maven_lock.json")
react_native.maven(name = "rn_maven_debug", lock_file = "//android:maven_debug_lock.json")
use_repo(react_native, "rn_maven", "rn_maven_debug")
```

You also need [aspect_rules_js](https://github.com/aspect-build/rules_js) with an
`npm_translate_lock` for the app's `package.json`, and a hermetic JDK in `.bazelrc` (rules_java
otherwise looks for one on the host):

```
common --java_runtime_version=remotejdk_21
common --tool_java_runtime_version=remotejdk_21
```

[`examples/`](examples) is a complete consumer: its own module with both apps, the pnpm
workspace, the Maven specs and lockfiles, and a `:pin` target.

## Usage

```starlark
load("@npm//:defs.bzl", "npm_link_all_packages")
load("@rules_react_native//react_native:defs.bzl", "react_native_android_app", "react_native_bundle")

npm_link_all_packages(name = "node_modules")

react_native_bundle(
    name = "bundle_android",
    srcs = ["App.tsx", "app.json", "babel.config.js", "index.js", "package.json"],
    node_modules = ":node_modules",
    platform = "android",
)

react_native_android_app(
    name = "hello",
    package = "com.example.hello",
    manifest = "android/AndroidManifest.xml",
    srcs = ["android/java/com/example/hello/MainActivity.java", "android/java/com/example/hello/MainApplication.java"],
    res = ["android/res/values/strings.xml", "android/res/values/styles.xml"],
    bundle = ":bundle_android",
)
```

```sh
cd examples
bazel build //hello                 # -> hello.apk (signed, zipaligned)
bazel run   //hello:hello.install   # adb install + launch
```

Day-to-day development uses a debug build that loads JS from Metro, run under
[ibazel](https://github.com/bazelbuild/bazel-watcher) so edits reach the dev server:

```sh
ibazel run //hello:start                 # Metro
bazel run  //hello:hello_debug.install   # install, adb reverse, launch
```

Edits to the app's JS reach the device through Fast Refresh, with component state kept. Shake the
device or press the menu key (`adb shell input keyevent 82`) for the dev menu: Reload, Open DevTools
(the Hermes debugger), the element inspector and the perf monitor. Native (Java/C++) changes need
the `.install` target again. See [Debug builds and the dev server](#debug-builds-and-the-dev-server).

## How it works

The React Native runtime ships prebuilt: `com.facebook.react:react-android` contains
`libreactnative.so` (the whole C++ core, Fabric and TurboModules) and
`com.facebook.hermes:hermes-android` contains the VM. The only native code an app compiles is
`libappmodules.so`, built from React Native's ~100-line default `OnLoad.cpp`. It looks optional,
since `DefaultSoLoader` swallows its absence, but it is what installs the `javaModuleProvider`
that resolves *every* Java TurboModule. Without it Hermes starts, then the first
`TurboModuleRegistry.getEnforcing('PlatformConstants')` throws. The pipeline Bazel runs directly
against the SDK/NDK tools:

| Step | Tool | Where |
| --- | --- | --- |
| Bundle JS (Metro) → Hermes bytecode | `@react-native/community-cli-plugin`, `hermesc` from the app's `node_modules` | [`js/bundle.cjs`](react_native/js/bundle.cjs), [`js/private/bundle.bzl`](react_native/js/private/bundle.bzl) |
| Compile each AAR's `res/` once | `aapt2 compile` | [`android/private/aar.bzl`](react_native/android/private/aar.bzl) |
| Merge manifests | AGP's `manifest-merger` | [`android/private/android_app.bzl`](react_native/android/private/android_app.bzl) |
| Link resources, emit `R.txt` | `aapt2 link` | 〃 |
| Generate R classes per library, `BuildConfig`, `PackageList`, `ReactNativeApplicationEntryPoint` | [`gen_r.py`](react_native/android/tools/gen_r.py) | 〃 |
| Compile app Java | `java_library` (rules_java) | [`defs.bzl`](react_native/defs.bzl) |
| Codegen: TurboModule/Fabric specs → Java spec classes + C++ glue | `@react-native/codegen`, `react-native/scripts/generate-specs-cli.js` | [`js/codegen.cjs`](react_native/js/codegen.cjs), [`js/private/codegen.bzl`](react_native/js/private/codegen.bzl) |
| Compile `libappmodules.so` per ABI (OnLoad.cpp, generated autolinking.cpp, codegen C++) against the AARs' prefab headers | NDK clang | [`android/private/appmodules.bzl`](react_native/android/private/appmodules.bzl), [`android/native/`](react_native/android/native) |
| Dex the runtime classpath | `d8` | [`android/private/android_app.bzl`](react_native/android/private/android_app.bzl) |
| Package, align (16 KiB pages), sign (v2+v3) | [`build_apk.py`](react_native/android/tools/build_apk.py), `zipalign -P 16`, `apksigner` | 〃 |

`ReactNativeApplicationEntryPoint` and `PackageList` are classes the React Native Gradle plugin
normally *generates* into the app. The templates here mirror `GenerateEntryPointTask` and
`GeneratePackageListTask` in `@react-native/gradle-plugin`, so app code written against the stock
template (`loadReactNative(this)`, `new PackageList(this).getPackages()`) compiles unchanged.

Every SDK tool runs in the exec configuration from hermetic downloads, so builds also work under
remote execution. The Java tools (d8, apksigner, manifest merger) run
on JDK 21 from rules_java regardless of the repo's default tool JVM, because they need class file
version 61+.

## Dependencies

### Android SDK and NDK

[`extensions.bzl`](react_native/extensions.bzl) downloads one platform (`android.jar`), one build-tools release,
platform-tools (`adb`) and NDK r27b (the version React Native 0.86 builds with, so the app's C++
uses the same libc++ as the `libc++_shared.so` react-android ships) for Linux and macOS.
Versions and hashes are in [`android/private/versions.bzl`](react_native/android/private/versions.bzl);
`@rn_android_sdk` and `@rn_android_ndk` select the host copy. Only clang, lld, the clang resource
headers/builtins and the sysroot are action inputs, not the whole ~2 GB NDK. Downloading the
archives directly skips `sdkmanager`'s license prompt; the Android SDK and NDK license terms still
apply.

### Maven (react-android and everything it pulls in)

Each consumer pins its own artifact set, which is what decides its React Native version. A spec
lists the roots and the build type:

```json
{
  "artifacts": [
    "com.facebook.react:react-android:0.86.3",
    "com.facebook.hermes:hermes-android:250829098.0.17"
  ],
  "build_type": "release",
  "excludes": []
}
```

(`hermes-android`'s version is the `hermes-compiler` npm version that `react-native` depends on.)
A second spec with `"build_type": "debug"` backs `debug = True` builds. `react_native_maven_pin`
resolves specs into lockfiles, reusing hashes it already has:

```starlark
load("@rules_react_native//react_native:defs.bzl", "react_native_maven_pin")

react_native_maven_pin(
    name = "pin",
    pins = {
        "android/maven_spec.json": "android/maven_lock.json",
        "android/maven_debug_spec.json": "android/maven_debug_lock.json",
    },
)
```

`@rn_maven//:all` is the whole set; each artifact is also `@rn_maven//:<group>_<artifact>` (dots
and dashes become `_`). `react_native_android_app` uses `@rn_maven//:all` and
`@rn_maven_debug//:all` unless you pass `maven`/`maven_debug`.

The resolver ([`maven_resolve.py`](react_native/android/tools/maven_resolve.py)) follows **Gradle** semantics
rather than POM semantics, because most of the graph is published with Gradle module metadata:

- Kotlin Multiplatform roots (`androidx.lifecycle:lifecycle-runtime`, `androidx.collection:collection`,
  …) redirect to their `-android`/`-jvm` artifact through `available-at`.
- react-android and hermes-android publish separate `debug`/`release` variants.
- androidx aligns versions through `dependencyConstraints`.
- Conflicts resolve to the highest requested version.

AARs are unpacked at fetch time, so their jars, `res/`, `R.txt`, manifests, `jni/` libraries and
prefab headers are plain build inputs. The prefab `libs/` copies (unstripped duplicates of `jni/`,
~300 MB for react-android alone) are deleted.

The ruleset pins its own host tool (AGP's manifest merger) the same way, in
[`react_native/android/maven_tools_spec.json`](react_native/android/maven_tools_spec.json)
(`bazel run //react_native/android/tools:pin_tools` to re-pin).

### JavaScript

Apps declare the same npm packages as a stock React Native project. Every tool is resolved
**through the app's own `react-native` dependency**, so the ruleset itself has no npm deps. In
`package.json`:

- `react`, `react-native`
- `@babel/runtime` — Babel injects `@babel/runtime/helpers/*` imports into react-native's own
  files. npm/yarn hoisting hides this; pnpm's strict layout does not.
- `@react-native/babel-preset`, `@react-native/metro-config` (dev)

The bundler adapts Metro to Bazel/pnpm in three ways (all in [`js/bundle.cjs`](react_native/js/bundle.cjs)):

- the rules_js virtual store (`<bindir>/node_modules`) is a watch folder, since Metro follows
  pnpm's symlinks to their real paths;
- the app's `node_modules` is in `resolver.nodeModulesPaths`, standing in for hoisting;
- `getModulesRunBeforeMainModule` resolves `InitializeCore` from the app, because
  `@react-native/metro-config` resolves it from its own location.

A `metro.config.js` / `metro.config.cjs` in the app package is honored; Metro's cache is disabled
since Bazel caches the action.

## API

Everything loads from `@rules_react_native//react_native:defs.bzl`; see the docstrings there and in
[`js/private/`](react_native/js/private).

- `react_native_bundle(name, srcs, node_modules, entry_point, platform, dev, hermes)` — default
  output `index.<platform>.bundle`; output group `res` is Metro's asset directory (Android
  `drawable-*` layout for `platform = "android"`).
- `react_native_codegen(name, srcs, node_modules, library_name, java_package, js_srcs_dir)` — the
  Bazel form of `codegenConfig`. Default output is a srcjar of the generated Java
  (`Native<Module>Spec`, `<Component>ManagerInterface`/`Delegate`); the C++ travels in
  `ReactNativeCodegenInfo`.
- `react_native_dev_server(name, srcs, node_modules, port)` — `bazel run` target running Metro over
  the package's sources, like `react-native start`.
- `react_native_maven_pin(name, pins)` — `bazel run` target resolving Maven specs into lockfiles.
- `react_native_android_app(name, package, manifest, bundle, srcs, res, deps, codegen, react_packages, …)`
  — `<name>.apk` plus `<name>.install`. Notable knobs: `debug` (debug AARs + dev support; `bundle`
  becomes optional), `codegen` (compiles the specs' Java with
  `srcs`, their C++ into libappmodules.so, and registers them in the generated autolinking.cpp),
  `react_packages` (the `ReactPackage`s to add to `PackageList`), `maven`/`maven_debug` (the
  artifact sets), `abis` (default arm64-v8a and x86_64), `min_sdk` (24), `target_sdk` (36),
  `keystore`.

### Debug builds and the dev server

`react_native_android_app(debug = True)` switches the whole Maven set to `@rn_maven_debug`
(react-android/hermes-android's `debug` variants, pinned from a `"build_type": "debug"` spec;
every other artifact is the same),
sets `BuildConfig.DEBUG` (turning on developer support), dexes with `--debug`, allows cleartext
traffic, and compiles `libappmodules.so` *without* `NDEBUG` to match the debug `libreactnative.so`.
`bundle` is optional: without one the app needs Metro, with one it falls back to the embedded bundle.
Its `.install` target also runs `adb reverse tcp:8081 tcp:8081`.

`react_native_dev_server` is a `js_run_devserver` around
[`js/dev_server.cjs`](react_native/js/dev_server.cjs): Metro with the same Bazel/pnpm adaptations as the bundler
(shared in [`js/metro_config.cjs`](react_native/js/metro_config.cjs)), plus `@react-native/dev-middleware` for
the debugger. Two endpoints a stock app expects normally come from the optional
`@react-native-community/cli-server-api`, so the dev server implements them itself:

- `/status`, which DevSupportManager probes before loading JS from the server;
- the `/message` websocket, the app's packager connection: the dev menu only enables
  "Open DevTools" once it's connected, and it carries reload/dev-menu commands (`r`/`d` in the
  Metro terminal when run interactively).

Run it under `ibazel` so source edits sync into the server's sandbox; plain `bazel run` serves a
snapshot. Changing the dev server tool itself needs an `ibazel` restart, since `js_run_devserver`
asks ibazel to notify rather than restart. On a headless Linux devbox, dev-middleware logs a
failure to install the standalone React Native DevTools window (Electron's `chrome-sandbox` isn't
SUID root there); the server is unaffected.

### Native modules and components

[`examples/native_modules`](examples/native_modules) has a
TurboModule (`NativeLocalStorage`, SharedPreferences) and a Fabric component (`GreetingView`, a
`TextView` that sends a direct event back to JS), both declared as TypeScript specs:

```starlark
react_native_codegen(
    name = "codegen",
    srcs = ["package.json", "specs/NativeLocalStorage.ts", "specs/GreetingViewNativeComponent.ts"],
    js_srcs_dir = "specs",
    library_name = "AppSpecs",
    java_package = "com.example.specs",
    node_modules = ":node_modules",
)

react_native_android_app(
    ...,
    codegen = [":codegen"],
    react_packages = ["com.example.AppSpecsPackage"],  # BaseReactPackage returning the module and view manager
)
```

The app writes the Java implementations (`extends NativeLocalStorageSpec`,
`implements GreetingViewManagerInterface`) and a `BaseReactPackage` that returns them. Each
codegen library gets an entry in the generated `autolinking.cpp`, which dispatches to its
`<lib>_ModuleProvider` and `<lib>_registerComponentDescriptorsFromCodegen`; RN's stock
`OnLoad.cpp` is unchanged. The C++ is compiled with `-DNDEBUG` like the release react-android it
links against; without it the Fabric `ShadowNode`/`Props` vtables reference debug-only virtuals
that `libreactnative.so` doesn't export.

Signing defaults to [`android/debug.keystore`](react_native/android/debug.keystore), a public debug key
(password `android`, as in the React Native template). Never ship it; pass a real `keystore` for
release.

## Limitations and next steps

- **App code is Java.** There's no Kotlin compiler wired in (no `rules_kotlin`). Kotlin *libraries*
  from Maven work; the app's own `MainActivity`/`MainApplication` must be Java.
- **No automatic linking of npm libraries.** Codegen works for specs in a Bazel package (the app's
  own, or a vendored library's). A library installed from npm keeps its specs, Java and C++ inside
  `node_modules`; pulling them out of the rules_js package tree and finding them from
  `react-native.config.js`, as the CLI's autolinking does, isn't wired up. Java-only libraries from
  Maven can go in `maven_spec.json` / `deps` plus `react_packages`.
- **No C++ TurboModules** (`cxxModuleProvider` returns nullptr) and no app-written C++ beyond what
  codegen emits.
- **No R8/ProGuard.** The APK is dexed with d8 only (about 30 MB for two ABIs). Split per ABI
  with `abis` if size matters.
- **APK only.** No `.aab`, no resource shrinking.

## iOS

`react_native_bundle(platform = "ios")` already produces `index.ios.bundle` (Hermes bytecode) on
Linux or macOS. The app build is the next step. React Native ≥0.80 publishes precompiled iOS
frameworks (`React.xcframework` and `ReactNativeDependencies` in
`com.facebook.react:react-native-artifacts`, Hermes in `hermes-ios`), which allows the same
approach as Android with `rules_apple`'s `ios_application` on a macOS executor instead of
CocoaPods.

## Layout

| Path | Contents |
| --- | --- |
| [`react_native/defs.bzl`](react_native/defs.bzl) | Public macros and rules |
| [`react_native/extensions.bzl`](react_native/extensions.bzl) | `react_native` module extension: `@rn_android_sdk`, `@rn_android_ndk`, `@rn_android_tools_maven`, and each consumer's `react_native.maven` sets |
| [`react_native/android/`](react_native/android) | The ruleset's tools lockfile and the public debug keystore |
| [`react_native/android/private/`](react_native/android/private) | Repository rules, `android_maven_import`, resource/APK/appmodules/pin rules, pinned SDK/NDK versions |
| [`react_native/android/native/`](react_native/android/native) | `OnLoad.cpp` and `autolinking.h`, compiled into `libappmodules.so` with the generated `autolinking.cpp` |
| [`react_native/android/tools/`](react_native/android/tools) | `maven_resolve.py`, `gen_r.py`, `build_apk.py` and their tests |
| [`react_native/js/`](react_native/js) | Drivers for the bundler, dev server and codegen, and the Metro config they share |
| [`examples/`](examples) | A consumer module: `hello` (plain) and `native_modules` (codegen'd TurboModule + Fabric component) |

## License

MIT. React Native's `OnLoad.cpp` (in `react_native/android/native/`) is Meta's, also MIT.
