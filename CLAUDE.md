# rules_react_native

Builds React Native apps with Bazel: no Gradle, CocoaPods or local Android SDK. Android produces
signed APKs; iOS stops at the JS bundle for now. [README.md](README.md) has setup, pipeline,
dependency model, rules and limitations. Read it before changing anything here.

Two Bazel modules live here: the ruleset at the root, and [`examples/`](examples), a separate
consumer module (`.bazelignore`d from the root) that depends on it via `local_path_override`.

```sh
bazel test //...                  # tool unit tests + docs freshness (Bazel 8 and 9)
bazel run //docs:update           # after changing any public docstring
cd examples && bazel test //...   # builds every app, runs react_native_apk_test on each APK
```

CI (`.github/workflows/ci.yml`) runs both on Linux (Bazel 8.x and 9.2.0) and macOS arm64, checks
that re-pinning the examples is a no-op, and checks that Linux arm64 fails with the host error.

## Public API

- [`react_native/defs.bzl`](react_native/defs.bzl): `react_native_android_app` (+ `.install`,
  `.sign`), `react_native_android_library`, `react_native_npm_library`, `react_native_java_library`,
  `react_native_bundle`, `react_native_codegen`, `react_native_dev_server`, `react_native_apk_test`,
  `react_native_maven_pin`. Generated reference: [`docs/defs.md`](docs/defs.md).
- [`react_native/extensions.bzl`](react_native/extensions.bzl): the `react_native` extension. Tags:
  `maven(name, lock_file)` (consumer artifact sets; the lockfile's `build_type` makes it the default
  release or debug set) and `android_toolchain(...)` (root-only SDK/NDK override). It always creates
  the ruleset's `@rn_android_sdk`, `@rn_android_ndk`, `@rn_android_tools_maven`,
  `@rn_kotlin_compiler_maven`, `@rn_profile` and `@rn_maven_default{,_debug}`; the rules reach those through `Label()`, never consumers.

## Gotchas

- **`libappmodules.so` is required**, even though `DefaultSoLoader` treats it as optional. Without
  it the app boots Hermes and then dies on `TurboModuleRegistry.getEnforcing('PlatformConstants')`,
  because `OnLoad.cpp` is what installs the Java TurboModule provider.
- **The React Native version drives the toolchain.** `extensions.bzl` reads react-android's version
  from the consumer's lockfiles and picks a `REACT_NATIVE_PROFILES` entry in
  [`versions.bzl`](react_native/android/private/versions.bzl); `@rn_profile//:profile.bzl` hands the
  result (compileSdk, native copts) to the macros. Adding a version: follow the checklist at the
  top of `versions.bzl`, then move the examples to it so CI covers it.
- **Java never goes through rules_java's toolchain.** `java.bzl` runs `javac` and the Java tools
  (d8, apksigner, AGP's manifest merger) on `@rules_java//toolchains:remotejdk_21` directly. That's
  what lets consumers skip `--java_runtime_version`, and the tools need class file version 61+.
  Don't switch to `java_library`/`java_binary`.
- **Kotlin is the same path**: `javac.py` runs kotlinc (`@rn_kotlin_compiler_maven`, pinned by
  `pin_tools`) on that JDK first, with `-no-jdk -no-stdlib` (android.jar and react-android's stdlib
  come from the classpath), then javac against its classes. Each target's Kotlin module name is
  derived from its label, because every `META-INF/*.kotlin_module` lands in one app. rules_kotlin
  was considered and rejected; see the README's Kotlin section.
- **npm packages are tree artifacts.** rules_js extracts a package in an action, so
  `react_native_npm_library` finds the package's store directory among the link target's files and
  addresses everything inside it by path (`--srcdir` for javac.py, `args.add_all(map_each = ...,
  allow_closure = True)` for C++ sources). Never try to glob or label files inside it.
- **libappmodules.so is built from `appmodules_unit`s** (`aar.bzl`): one per codegen library plus
  one per library with C++, deduplicated by key. A unit's own includes come before codegen's, so a
  library's hand-written `<lib>.h` shadows the generated one. `component_descriptors` replaces
  `<lib>_registerComponentDescriptorsFromCodegen` (codegen `interfaceOnly` components have no
  generated descriptor); `cxx_modules` fills `cxxModuleProvider`.
- **`-DANDROID`** is in the appmodules copts because the NDK's CMake toolchain defines it and
  libraries guard Android-only code (folly::dynamic state, MapBuffer) with it rather than
  `__ANDROID__`. Without it, react-native-safe-area-context's state lacks `getDynamic`.
- **Compile classpath = API closure.** Lockfiles (format 2) record `api_deps`; `android_maven_import`
  turns them into `exports`, and `AndroidLibraryInfo.compile_jars` follows only exports.
  `runtime_jars` carries everything to d8. Lockfiles without `api_deps` are treated as all-API.
- **Libraries compile against React Native compile-only** (`_react_native` =
  `@rn_maven_default//:all`), so a debug app never dexes release react-android next to debug.
- **Library R classes**: `aapt2 link --static-lib --non-final-ids` gives compile-time placeholders;
  `own_r_txt.py` subtracts the deps' symbols; `javac.py --exclude_r` drops the library's R from its
  jar; the app's `gen_r.py` regenerates it with final ids from the library's R.txt.
- **`NDEBUG` must match the react-android variant**: on for release, off for debug. A mismatch makes
  codegen'd Fabric components fail to link (`getDebugProps`, `getDebugName`, ...).
- **Labels inside macros resolve in the caller's repo.** Anything that must point into this module
  is a `Label()`.
- **Generated repo BUILD files must not rely on the consumer's flags**: globs over AAR contents pass
  `allow_empty = True`.
- **Hosts**: `host_alias_repository` selects on `linux_x86_64`/`macos` config settings with a
  `no_match_error`; Google ships no Linux arm64 build-tools.
- **Bazel 8 floor**: rules_python stays at 2.2.0 (2.3+ uses `flag_alias`, Bazel 9 only). Consumers
  on Bazel 9 get whatever newer rules_python their graph selects.
- **Metro under rules_js / `js_run_devserver`**: see `react_native/js/metro_config.cjs` (watch every
  symlink hop, `nodeModulesPaths`, `InitializeCore` from the app). Apps must declare `@babel/runtime`.
  `js/dev_server.cjs` serves `/status` and `/message` itself.
- **Reproducibility**: APKs are byte-identical across checkouts and output bases. Keep zips at fixed
  timestamps and sorted, and keep absolute paths out of compiled outputs (`-ffile-prefix-map`).
- `glob()` has no character classes. `[0-9]*` silently matches nothing.

## Releasing

Bump `version` in `MODULE.bazel`, push a `vX.Y.Z` tag: `.github/workflows/release.yml` checks the
version, attaches `rules_react_native-vX.Y.Z.tar.gz` and prints its integrity. `.bcr/` holds the
publish-to-bcr templates.

## Layout

| Path | Contents |
| --- | --- |
| [`react_native/`](react_native) | `defs.bzl`, `extensions.bzl`, `bzl_library` targets |
| [`react_native/android/`](react_native/android) | Tools and kotlinc lockfiles/specs and the public debug keystore |
| [`react_native/android/private/`](react_native/android/private) | Repository rules, providers, app/library/npm-library/java/appmodules/apk-test/sign/pin rules, versions |
| [`react_native/android/native/`](react_native/android/native) | `OnLoad.cpp` and `autolinking.h` |
| [`react_native/android/tools/`](react_native/android/tools) | Python tools (`maven_resolve`, `gen_r`, `build_apk`, `javac`, `own_r_txt`, `apk_check`) and their unittest tests |
| [`react_native/js/`](react_native/js) | `bundle.cjs`, `dev_server.cjs`, `codegen.cjs`, the shared `metro_config.cjs`, and their rules |
| [`docs/`](docs) | Stardoc-generated API reference (`bazel run //docs:update`) |
| [`examples/`](examples) | Consumer module: `hello`, `native_modules`, `cxx_module`, `third_party`, `assets`, `fleet`, `brownfield`, `variants`, `connect` (the README's Examples table), Maven specs/lockfiles, `:pin` |
