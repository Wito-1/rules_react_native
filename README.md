# rules_react_native

Bazel rules that build React Native apps without Gradle, CocoaPods or a local Android SDK.

Android is supported: release and debug APKs, Metro with Fast Refresh, codegen'd TurboModules and
Fabric components, first-party Android libraries, device-free APK tests, and release signing that
keeps keys out of the build. iOS currently stops at the JS bundle (see [iOS](#ios)).

| | |
| --- | --- |
| React Native | 0.86, 0.87 (see [Versions](#versions)) |
| Bazel | 8, 9 |
| Build hosts | Linux x86_64, macOS (Apple Silicon and Intel) |
| API reference | [`docs/defs.md`](docs/defs.md), [`docs/extensions.md`](docs/extensions.md) |

## Setup

`MODULE.bazel` (not on the BCR yet, so pin a release):

```starlark
bazel_dep(name = "rules_react_native", version = "0.1.0")
archive_override(
    module_name = "rules_react_native",
    integrity = "sha256-...",  # from the release notes
    strip_prefix = "rules_react_native-0.1.0",
    urls = ["https://github.com/Wito-1/rules_react_native/releases/download/v0.1.0/rules_react_native-v0.1.0.tar.gz"],
)

# Your React Native version is whatever these lockfiles pin (see "Maven" below).
react_native = use_extension("@rules_react_native//react_native:extensions.bzl", "react_native")
react_native.maven(name = "rn_maven", lock_file = "//android:maven_lock.json")
react_native.maven(name = "rn_maven_debug", lock_file = "//android:maven_debug_lock.json")
```

`use_repo(react_native, "rn_maven")` is only needed to reference individual artifacts
(`@rn_maven//:<group>_<artifact>`); the rules find the release and debug sets on their own.

You also need [aspect_rules_js](https://github.com/aspect-build/rules_js) with an
`npm_translate_lock` for the app's `package.json`. No JDK, Android SDK or NDK has to be installed,
and no `.bazelrc` flags are required.

[`examples/`](examples) is a complete consumer: its own module with two apps, a library, the pnpm
workspace, the Maven specs and lockfiles, and a `:pin` target.

## Usage

```starlark
load("@npm//:defs.bzl", "npm_link_all_packages")
load(
    "@rules_react_native//react_native:defs.bzl",
    "react_native_android_app",
    "react_native_apk_test",
    "react_native_bundle",
    "react_native_dev_server",
)

npm_link_all_packages(name = "node_modules")

_JS = ["App.tsx", "app.json", "babel.config.js", "index.js", "package.json"]

react_native_bundle(
    name = "bundle_android",
    srcs = _JS,
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

react_native_android_app(
    name = "hello_debug",
    debug = True,  # JS comes from Metro
    package = "com.example.hello",
    manifest = "android/AndroidManifest.xml",
    srcs = ["android/java/com/example/hello/MainActivity.java", "android/java/com/example/hello/MainApplication.java"],
    res = ["android/res/values/strings.xml", "android/res/values/styles.xml"],
)

react_native_dev_server(
    name = "start",
    srcs = _JS,
    node_modules = ":node_modules",
)

react_native_apk_test(
    name = "hello_apk_test",
    apk = ":hello",
    package = "com.example.hello",
    assets = ["index.android.bundle"],
)
```

```sh
cd examples
bazel build //hello                     # hello.apk: signed with the debug key, 16 KiB aligned
bazel test  //...                       # every APK's manifest, alignment, signature, contents
bazel run   //hello:hello.install       # adb install + launch

ibazel run //hello:start                # Metro, with edits synced live
bazel run  //hello:hello_debug.install  # debug app: install, adb reverse, launch

bazel run //hello:hello.sign -- --ks release.jks --ks-key-alias upload --ks-pass env:KS_PASS --out hello-release.apk
```

Edits to the app's JS reach the device through Fast Refresh, with component state kept. Shake the
device or press the menu key (`adb shell input keyevent 82`) for the dev menu: Reload, Open DevTools
(the Hermes debugger), the element inspector and the perf monitor. Native (Java/C++) changes need
the `.install` target again.

## Rules

Everything loads from `@rules_react_native//react_native:defs.bzl`; the generated reference is
[`docs/defs.md`](docs/defs.md).

| Rule | What it does |
| --- | --- |
| `react_native_android_app` | `<name>.apk` from Java sources and a bundle, plus `<name>.install` and `<name>.sign` |
| `react_native_android_library` | Java, resources, manifest entries, assets, codegen and ReactPackages that an app picks up through `deps` |
| `react_native_java_library` | Plain Java for an app, on the same compiler and classpath rules |
| `react_native_bundle` | Metro + Hermes bytecode, for `android` or `ios` |
| `react_native_codegen` | `codegenConfig`: TurboModule/Fabric specs → Java spec classes + C++ glue |
| `react_native_dev_server` | Metro dev server (`react-native start`) |
| `react_native_apk_test` | Device-free checks on a built APK |
| `react_native_maven_pin` | Resolves Maven specs into lockfiles |

### Libraries and native modules

[`examples/native_modules`](examples/native_modules) keeps its native code in a library,
[`examples/native_modules/greeting`](examples/native_modules/greeting): a TurboModule
(`NativeLocalStorage`, SharedPreferences), a Fabric component (`GreetingView`, a `TextView` that
sends a direct event back to JS), a color resource and an asset. The specs are TypeScript:

```starlark
react_native_codegen(
    name = "codegen",
    srcs = ["package.json", "specs/NativeLocalStorage.ts", "specs/GreetingViewNativeComponent.ts"],
    js_srcs_dir = "specs",
    library_name = "AppSpecs",
    java_package = "com.example.greeting.specs",
    node_modules = ":node_modules",
)

react_native_android_library(
    name = "greeting",
    package = "com.example.greeting",          # its R class, i.e. AGP's `namespace`
    srcs = [...],                               # implements NativeLocalStorageSpec, GreetingViewManagerInterface
    res = ["res/values/colors.xml"],
    assets = ["assets/greeting.txt"],
    codegen = ["//native_modules:codegen"],
    react_packages = ["com.example.greeting.AppSpecsPackage"],
)

react_native_android_app(
    name = "native_modules",
    deps = ["//native_modules/greeting"],      # resources, manifest, assets, C++, PackageList entry
    ...
)
```

A library compiles against React Native compile-only; the app decides whether the release or debug
variant ships. Its R class compiles against placeholder ids from an `aapt2 --static-lib` link and
is regenerated with final ids in the app, like AGP's non-transitive R classes. Each codegen library
gets an entry in the app's generated `autolinking.cpp`, which dispatches to its
`<lib>_ModuleProvider` and `<lib>_registerComponentDescriptorsFromCodegen`; React Native's stock
`OnLoad.cpp` is unchanged.

### Debug builds and the dev server

`react_native_android_app(debug = True)` builds against the `"build_type": "debug"` artifact set
(react-android/hermes-android's debug variants; every other artifact is the same), sets
`BuildConfig.DEBUG` (turning on developer support), dexes with `--debug`, allows cleartext traffic,
and compiles `libappmodules.so` *without* `NDEBUG` to match the debug `libreactnative.so`. `bundle`
is optional: without one the app needs Metro, with one it falls back to the embedded bundle. Its
`.install` target also runs `adb reverse tcp:8081 tcp:8081`.

`react_native_dev_server` is a `js_run_devserver` around Metro with the same Bazel/pnpm
adaptations as the bundler, plus `@react-native/dev-middleware` for the debugger. Two endpoints a
stock app expects normally come from the optional `@react-native-community/cli-server-api`, so the
dev server implements them itself: `/status`, which DevSupportManager probes before loading JS, and
the `/message` websocket, the app's packager connection (the dev menu only enables "Open DevTools"
once it's connected; it also carries `r`/`d` reload and dev-menu commands from the terminal). Run it
under `ibazel` so edits sync into the server's sandbox; plain `bazel run` serves a snapshot.

### Signing

The in-build signature uses `keystore`/`keystore_password`/`key_alias`, defaulting to
[`react_native/android/debug.keystore`](react_native/android/debug.keystore), a public debug key
(password `android`, as in the React Native template). That password is an action argument, so it's
only for keys that aren't secret.

For release keys, `bazel run //app:<name>.sign -- <apksigner sign args>` signs the zipaligned,
unsigned APK at run time. The keystore and its password (`env:VAR` or `file:path`) never become
build inputs, so they can't reach the action cache, a remote cache or build logs.

### Testing

`react_native_apk_test` checks an APK without a device: the manifest's package (`aapt2`), 16 KiB
page alignment (`zipalign -c -P 16`), the signature (`apksigner verify`), that `resources.arsc` and
every native library are stored uncompressed, that exactly the expected ABIs ship the expected
libraries, and that the expected assets exist. CI runs it for every example app on Linux and macOS.

## How it works

The React Native runtime ships prebuilt: `com.facebook.react:react-android` contains
`libreactnative.so` (the whole C++ core, Fabric and TurboModules) and
`com.facebook.hermes:hermes-android` contains the VM. The only native code an app compiles is
`libappmodules.so`, built from React Native's ~100-line default `OnLoad.cpp` plus any codegen'd
C++. It looks optional, since `DefaultSoLoader` swallows its absence, but it is what installs the
`javaModuleProvider` that resolves *every* Java TurboModule. Without it Hermes starts, then the
first `TurboModuleRegistry.getEnforcing('PlatformConstants')` throws.

| Step | Tool | Where |
| --- | --- | --- |
| Bundle JS (Metro) → Hermes bytecode | `@react-native/community-cli-plugin`, `hermesc` from the app's `node_modules` | [`js/bundle.cjs`](react_native/js/bundle.cjs) |
| Codegen specs → Java + C++ | `@react-native/codegen`, `react-native/scripts/generate-specs-cli.js` | [`js/codegen.cjs`](react_native/js/codegen.cjs) |
| Compile each AAR's / library's `res/` once | `aapt2 compile` | [`android/private/aar.bzl`](react_native/android/private/aar.bzl) |
| Library R classes against placeholder ids | `aapt2 link --static-lib` | [`android/private/library.bzl`](react_native/android/private/library.bzl) |
| Merge manifests | AGP's `manifest-merger` | [`android/private/android_app.bzl`](react_native/android/private/android_app.bzl) |
| Link resources, emit `R.txt` | `aapt2 link` | 〃 |
| R classes per library with final ids, `BuildConfig`, `PackageList`, `ReactNativeApplicationEntryPoint` | [`gen_r.py`](react_native/android/tools/gen_r.py) | 〃 |
| Compile Java | `javac` from a pinned JDK 21 | [`android/private/java.bzl`](react_native/android/private/java.bzl) |
| Compile `libappmodules.so` per ABI | NDK clang | [`android/private/appmodules.bzl`](react_native/android/private/appmodules.bzl) |
| Dex the runtime classpath | `d8` | [`android/private/android_app.bzl`](react_native/android/private/android_app.bzl) |
| Package, align (16 KiB pages), sign (v2+v3) | [`build_apk.py`](react_native/android/tools/build_apk.py), `zipalign -P 16`, `apksigner` | 〃 |

`ReactNativeApplicationEntryPoint` and `PackageList` are classes the React Native Gradle plugin
normally *generates* into the app. The templates here mirror `GenerateEntryPointTask` and
`GeneratePackageListTask` in `@react-native/gradle-plugin`, so app code written against the stock
template (`loadReactNative(this)`, `new PackageList(this).getPackages()`) compiles unchanged.

Every tool runs in the exec configuration from hermetic downloads, so builds also work under remote
execution, and outputs are byte-for-byte reproducible across machines and checkout paths. Java is
compiled and the Java tools (d8, apksigner, manifest merger) run on a pinned JDK 21 rather than
through rules_java's toolchain resolution, so consumers don't configure a JDK and those tools get
the class file version 61+ they need.

### Versions

The react-android version in the consumer's lockfiles selects a profile in
[`versions.bzl`](react_native/android/private/versions.bzl): compileSdk and build-tools, the NDK
React Native builds with (the app's C++ must share its `libc++_shared.so`), and native compile
flags. An unsupported version fails at module resolution with the list of supported ones.

| React Native | compileSdk / build-tools | NDK | Notes |
| --- | --- | --- | --- |
| 0.86 | 36 / 36.0.0 | 27.1.12297006 (r27b) | |
| 0.87 | 37 / 37.0.0 | 27.1.12297006 (r27b) | `HERMES_V1_ENABLED` for native code |

`versions.bzl` lists what adding a version involves. The root module can pick a different pinned
SDK/NDK with `react_native.android_toolchain(compile_sdk = ..., build_tools = ..., ndk = ...)`.

### Build hosts

Google publishes the SDK and NDK tools for Linux x86_64 and macOS; the macOS build-tools are
universal binaries. Any other execution platform (Linux arm64, Windows) fails at analysis with an
explicit error instead of running the wrong binaries; CI asserts that on a Linux arm64 runner.

### Maven (react-android and everything it pulls in)

A spec lists the roots and the build type:

```json
{
  "artifacts": [
    "com.facebook.react:react-android:0.87.1",
    "com.facebook.hermes:hermes-android:250829098.0.17"
  ],
  "build_type": "release",
  "excludes": []
}
```

(`hermes-android`'s version is the `hermes-compiler` npm version that `react-native` depends on.)
`react_native_maven_pin` resolves specs into lockfiles, reusing hashes it already has:

```starlark
react_native_maven_pin(
    name = "pin",
    pins = {
        "android/maven_spec.json": "android/maven_lock.json",
        "android/maven_debug_spec.json": "android/maven_debug_lock.json",
    },
)
```

The resolver ([`maven_resolve.py`](react_native/android/tools/maven_resolve.py)) follows **Gradle**
semantics rather than POM semantics, because most of the graph is published with Gradle module
metadata:

- Kotlin Multiplatform roots (`androidx.lifecycle:lifecycle-runtime`, …) redirect to their
  `-android`/`-jvm` artifact through `available-at`.
- react-android and hermes-android publish separate `debug`/`release` variants.
- androidx aligns versions through `dependencyConstraints`.
- Conflicts resolve to the highest requested version, in Gradle's version order; ranges and
  dynamic versions (`[1.0,2.0)`, `1.2.+`) resolve to the highest published match.
- Each artifact records which of its dependencies are API (its `java-api` variant, or a POM's
  compile scope). An app compiles against its roots' API closure only, as Gradle's
  `compileClasspath` would; everything is dexed.

AARs are unpacked at fetch time, so their jars, `res/`, `R.txt`, manifests, `jni/` libraries and
prefab headers are plain build inputs. The prefab `libs/` copies (unstripped duplicates of `jni/`,
~300 MB for react-android alone) are deleted.

### JavaScript

Apps declare the same npm packages as a stock React Native project. Every tool is resolved
**through the app's own `react-native` dependency**, so the ruleset itself has no npm deps. In
`package.json`:

- `react`, `react-native`
- `@babel/runtime`: Babel injects `@babel/runtime/helpers/*` imports into react-native's own files.
  npm/yarn hoisting hides this; pnpm's strict layout does not.
- `@react-native/babel-preset`, `@react-native/metro-config` (dev)

Metro is adapted to Bazel/pnpm in [`js/metro_config.cjs`](react_native/js/metro_config.cjs): every
directory a pnpm symlink passes through is a watch folder, the app's `node_modules` stands in for
hoisting, and `InitializeCore` is resolved from the app. A `metro.config.js` in the app package is
honored.

## Limitations

- **App code is Java.** There's no Kotlin compiler wired in. Kotlin *libraries* from Maven work.
- **No automatic linking of npm libraries.** Native libraries installed from npm keep their specs,
  Java and C++ inside `node_modules`, found via `react-native.config.js`; that isn't wired up. Their
  code can be vendored into a `react_native_android_library`.
- **No C++ TurboModules** (`cxxModuleProvider` returns nullptr) and no app-written C++ beyond what
  codegen emits.
- **APK only, no R8.** No `.aab` and no shrinking; about 30 MB for two ABIs.

## iOS

`react_native_bundle(platform = "ios")` produces `index.ios.bundle` (Hermes bytecode) on Linux or
macOS. The app build is the next step: React Native publishes precompiled iOS frameworks
(`React.xcframework`, `ReactNativeDependencies`, Hermes), which allows the same approach as Android
with `rules_apple`'s `ios_application` on a macOS executor instead of CocoaPods.

## Development

```sh
bazel test //...                  # tool unit tests, API docs freshness
bazel run //docs:update           # regenerate docs/ after changing a docstring
cd examples && bazel test //...   # build every app and test every APK
bazel run //react_native/android/tools:pin_tools   # re-pin the manifest merger
```

Releases are cut by pushing a `vX.Y.Z` tag whose version matches `MODULE.bazel`; the release
workflow attaches the source archive, and `.bcr/` holds the templates for publishing to the Bazel
Central Registry.

## License

MIT. React Native's `OnLoad.cpp` (in `react_native/android/native/`) is Meta's, also MIT.
