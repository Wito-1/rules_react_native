# rules_react_native

Bazel rules that build React Native apps without Gradle, CocoaPods or a local Android SDK.

Android is supported: release and debug APKs, Play-ready app bundles (R8, native debug symbols,
Hermes source maps), Java and Kotlin, Metro with Fast Refresh, codegen'd
TurboModules and Fabric components, pure C++ TurboModules, first-party Android libraries, native
libraries installed from npm, device-free APK tests, and release signing that keeps keys out of the
build. iOS currently stops at the JS bundle (see [iOS](#ios)).

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
| `react_native_android_app` | `<name>.apk` and `<name>.aab` from Java/Kotlin sources and a bundle, plus `.install`/`.sign` targets for each |
| `react_native_android_library` | Java/Kotlin, resources, manifest entries, assets, codegen, C++ and ReactPackages that an app picks up through `deps` |
| `react_native_npm_library` | The same, built from an npm package's `android/` and C++ sources in `node_modules` |
| `react_native_java_library` | Plain Java/Kotlin for an app, on the same compiler and classpath rules |
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

### Kotlin

`.kt` files go in `srcs` next to `.java` files, in apps and libraries. They compile as Gradle's
Kotlin plugin does: kotlinc first (seeing the Java sources, including codegen's, for resolution
only), then javac against kotlinc's classes, into one jar. kotlinc is
`org.jetbrains.kotlin:kotlin-compiler-embeddable`, pinned in
[`maven_kotlin_lock.json`](react_native/android/maven_kotlin_lock.json) and run on the same pinned
JDK 21 as javac; the Kotlin stdlib is react-android's. `kotlincopts` passes extra flags.

[rules_kotlin](https://github.com/bazelbuild/rules_kotlin) targets work as `deps` too (every
library here carries `JavaInfo`), but the ruleset doesn't use it: it couldn't compile sources from
inside an npm package, its Java half goes through rules_java's toolchain, and it brings
rules_android into every consumer's graph.

### Libraries from npm (autolinking)

Native libraries installed from npm are built from their sources in `node_modules`, without
vendoring. `react_native_autolink` is Gradle's autolinking for Bazel: it reads each dependency's
`codegenConfig`, `react-native.config.js` and `android/build.gradle` (and the CMakeLists.txt files
those name) and writes `react_native_libraries.bzl`, which declares a `react_native_codegen` and a
`react_native_npm_library` per native dependency:

```starlark
load(":react_native_libraries.bzl", "react_native_libraries")

react_native_autolink(name = "autolink", node_modules = ":node_modules")   # bazel run :autolink

react_native_android_app(name = "app", deps = react_native_libraries(), ...)
```

`autolink_test` fails when the file is stale (after adding or upgrading a library), like
`bazel run //:gazelle` and its diff check. `bazel run :autolink` also lists the Maven artifacts
the libraries use (from their `build.gradle` `dependencies`): put those in the Maven spec's
`"libraries"` and re-pin. Libraries compile against them; an app ships only the ones its own
libraries need, from its own (release or debug) set, so they don't bloat other apps.
[`examples/ecosystem`](examples/ecosystem) uses React Navigation's native stack on
react-native-screens, react-native-gesture-handler, react-native-svg and
react-native-safe-area-context, all autolinked; [`examples/third_party`](examples/third_party)
autolinks react-native-safe-area-context alone. What the generator reproduces:

- **Source sets**: the directories `build.gradle` adds for the new architecture; optional
  integrations (`svg/` vs `nosvg/`) follow the app's own dependencies.
- **C++**: the `cmakeListsPath` CMakeLists.txt's sources (custom shadow nodes, hand-written
  component descriptors) go into the app's `libappmodules.so`, as Gradle links them; only the
  codegen output that CMakeLists.txt globs is compiled (libraries that ship their own `<lib>.cpp`
  take just the components). The library's own `externalNativeBuild` becomes its own
  `lib<name>.so` (`shared_libraries`), which its Java loads by name.
- **Resources**, including several `res.srcDirs`; **consumer ProGuard rules**; **BuildConfig**
  with typed `buildConfigField`s (values `build.gradle` computes take the type's zero value); R
  classes of the library's dependencies (`com.facebook.react.R`), as AGP's compile R jars;
  dependencies between libraries (`rootProject.subprojects.find { it.name == ... }`).

The hand-written form of the same target, for a library the generator doesn't handle:

```starlark
react_native_codegen(
    name = "safe_area_context_codegen",
    npm_package = "react-native-safe-area-context",   # specs come from the installed package
    js_srcs_dir = "src/specs",
    library_name = "safeareacontext",
    java_package = "com.th3rdwave.safeareacontext",
    node_modules = ":node_modules",
)

react_native_npm_library(
    name = "safe_area_context",
    npm_package = ":node_modules/react-native-safe-area-context",
    package = "com.th3rdwave.safeareacontext",
    java_dirs = ["android/src/main/java", "android/src/fabric/java"],
    build_config = True,
    cc_srcs = ["common/cpp/react/renderer/components/safeareacontext/RNCSafeAreaViewShadowNode.cpp", ...],
    cc_includes = ["android/src/main/jni", "common/cpp"],
    codegen = [":safe_area_context_codegen"],
    component_descriptors = ["RNCSafeAreaProviderComponentDescriptor", "RNCSafeAreaViewComponentDescriptor"],
    react_packages = ["com.th3rdwave.safeareacontext.SafeAreaContextPackage"],
)
```

The package's files are only known at execution time (rules_js extracts it in an action), so its
attributes are paths inside it rather than labels. If a stale generated file stops the package
from loading (e.g. after a ruleset upgrade renamed an attribute), replace it with
`def react_native_libraries(**kwargs): return []` and run `:autolink` again.

### C++ in libraries, and pure C++ TurboModules

`react_native_android_library(cc_srcs = ...)` compiles C++ into `libappmodules.so`.
`cxx_modules = {"facebook::react::NativeSampleModule": "NativeSampleModule.h"}` registers a
module implemented against codegen's `<Name>CxxSpec` in `autolinking.cpp`'s `cxxModuleProvider`,
under its `kModuleName`, so the same C++ can serve Android and iOS with no Java at all.
`component_descriptors` registers hand-written Fabric descriptors. See
[`examples/cxx_module`](examples/cxx_module).

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

### Shipping to Play

```sh
bazel build //hello:hello.aab                                  # unsigned bundle for Play
bazel run //hello:hello.aab.sign -- -keystore upload.jks -storepass:env KS_PASS upload
bazel run //hello:hello.aab.install                            # install the bundle's split APKs, as Play would
```

`minify = True` shrinks, optimizes and obfuscates with R8 instead of dexing with D8 (`hello`'s dex
goes from 11.6 MB to 2.2 MB). Its rules are
[`proguard-defaults.pro`](react_native/android/proguard-defaults.pro) (the essentials of AGP's
`proguard-android-optimize.txt`, plus line numbers), aapt2's keep rules for classes the manifest
and layouts name, every library's consumer rules (an AAR's `proguard.txt`, rules embedded in jars
under `META-INF/`, a library's `proguard_specs`) and the app's `proguard_specs`.

`<name>.aab` is built by bundletool from the same content as the APK, with resources converted to
proto format. Like AGP's, it carries the R8 mapping and `libappmodules.so`'s debug symbols in its
metadata, so Play deobfuscates and symbolicates crashes with no separate upload. For other crash
reporters, the app's output groups `proguard_mapping` and `native_debug_symbols` (Play's
`native-debug-symbols.zip` layout) and the bundle's `sourcemap` (Metro's map composed with Hermes',
as the Gradle plugin makes it) hold the same data. The bundle is unsigned in the build:
`jarsigner` embeds a signing time, which would make it irreproducible, and the upload key belongs
outside the build anyway.

APKs, bundles, mappings, symbols and source maps are byte-identical across checkouts and machines.

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

## Examples

[`examples/`](examples) is a consumer module (`cd examples && bazel test //...` builds every app
and runs every test):

| Example | Shows |
| --- | --- |
| [`hello`](examples/hello) | Release and debug apps, Metro, the iOS bundle, APK tests, Jest component tests under rules_jest |
| [`native_modules`](examples/native_modules) | Codegen'd TurboModule and Fabric component in a library, with resources and assets |
| [`cxx_module`](examples/cxx_module) | A pure C++ TurboModule, no Java |
| [`third_party`](examples/third_party) | `react-native-safe-area-context` from npm (Kotlin, codegen, custom C++ shadow node), and Kotlin app code |
| [`ecosystem`](examples/ecosystem) | React Navigation's native stack, react-native-screens, -gesture-handler, -svg, -safe-area-context: autolinked, minified |
| [`assets`](examples/assets) | Density-qualified images (`@2x`, `@3x`) and a custom font |
| [`fleet`](examples/fleet) | Two apps sharing a workspace JS package and a native library, each overriding a library resource |
| [`brownfield`](examples/brownfield) | A native launcher activity opening React Native screens with launch options |
| [`variants`](examples/variants) | `--//variants:env=staging` builds an app with its own `application_id`, BuildConfig fields, manifest placeholders and JS config, installable side by side |
| [`connect`](examples/connect) | One `.proto` generating code for a node server, a Vite web app and the mobile app, which reaches the server over `adb_reverse` |

Some of these needed adaptations worth knowing about:

- **Jest under rules_jest**: `hello/jest.config.js` resolves `@react-native/jest-preset` to a
  relative path, restates Haste's platforms (rules_jest overrides `haste`), adds the app's
  `node_modules` to `modulePaths`, and lets Babel transform `.aspect_rules_js` paths;
  `pnpm-workspace.yaml` gives the preset `react`/`react-native` as peers.
- **Hermes has no `TextDecoder`**, which Connect (and protobuf-es) need; `connect/mobile` loads
  `fast-text-encoding` before anything else.

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

- **Autolinking reads build files, it doesn't run them.** The generator understands the
  conventional shapes of `build.gradle` and `CMakeLists.txt`; logic beyond that (computed source
  sets, CMake conditionals) needs a hand-written `react_native_npm_library`.
- **Library BuildConfig is release-only.** A library is built once for every app variant, so its
  `BuildConfig.DEBUG` is false, as in a release AAR.
- **No resource shrinking** (`shrinkResources`); R8 shrinks code only.

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
bazel run //react_native/android/tools:pin_tools   # re-pin the manifest merger, kotlinc and bundletool
```

Releases are cut by pushing a `vX.Y.Z` tag whose version matches `MODULE.bazel`; the release
workflow attaches the source archive, and `.bcr/` holds the templates for publishing to the Bazel
Central Registry.

## License

MIT. React Native's `OnLoad.cpp` (in `react_native/android/native/`) is Meta's, also MIT.
