<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Public API of the React Native ruleset. See README.md.

<a id="react_native_android_library"></a>

## react_native_android_library

<pre>
load("@rules_react_native//react_native:defs.bzl", "react_native_android_library")

react_native_android_library(<a href="#react_native_android_library-name">name</a>, <a href="#react_native_android_library-deps">deps</a>, <a href="#react_native_android_library-srcs">srcs</a>, <a href="#react_native_android_library-assets">assets</a>, <a href="#react_native_android_library-codegen">codegen</a>, <a href="#react_native_android_library-exports">exports</a>, <a href="#react_native_android_library-javacopts">javacopts</a>, <a href="#react_native_android_library-manifest">manifest</a>,
                             <a href="#react_native_android_library-package">package</a>, <a href="#react_native_android_library-react_native">react_native</a>, <a href="#react_native_android_library-react_packages">react_packages</a>, <a href="#react_native_android_library-res">res</a>)
</pre>

A library of a React Native Android app: Java sources, resources, manifest entries,
assets, codegen'd specs and the ReactPackages it contributes.

Everything flows to the app through `deps`: resources are linked with the app's (the library's R
class is regenerated with final ids in its own `package`), its manifest is merged, its assets are
packaged, its codegen C++ is compiled into libappmodules.so and registered in autolinking.cpp, and
its `react_packages` are added to PackageList.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="react_native_android_library-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="react_native_android_library-deps"></a>deps |  -   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="react_native_android_library-srcs"></a>srcs |  -   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="react_native_android_library-assets"></a>assets |  Files under one assets/ directory; packaged at the same relative paths.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="react_native_android_library-codegen"></a>codegen |  `react_native_codegen` targets for this library's specs.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="react_native_android_library-exports"></a>exports |  Deps that are part of this library's API (Gradle's `api`).   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="react_native_android_library-javacopts"></a>javacopts |  Extra javac flags, after the defaults (`-source 17 -target 17`).   | List of strings | optional |  `[]`  |
| <a id="react_native_android_library-manifest"></a>manifest |  Optional; components, permissions and meta-data to merge into the app's manifest.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |
| <a id="react_native_android_library-package"></a>package |  Java package of the library's R class (AGP's `namespace`).   | String | required |  |
| <a id="react_native_android_library-react_native"></a>react_native |  Compile and link resources against the consumer's release React Native set. It stays compile-only; the app supplies the runtime variant.   | Boolean | optional |  `True`  |
| <a id="react_native_android_library-react_packages"></a>react_packages |  Fully-qualified ReactPackage classes the app's PackageList must instantiate.   | List of strings | optional |  `[]`  |
| <a id="react_native_android_library-res"></a>res |  Files under one res/ directory.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |


<a id="react_native_apk_test"></a>

## react_native_apk_test

<pre>
load("@rules_react_native//react_native:defs.bzl", "react_native_apk_test")

react_native_apk_test(<a href="#react_native_apk_test-name">name</a>, <a href="#react_native_apk_test-abis">abis</a>, <a href="#react_native_apk_test-apk">apk</a>, <a href="#react_native_apk_test-assets">assets</a>, <a href="#react_native_apk_test-native_libs">native_libs</a>, <a href="#react_native_apk_test-package">package</a>)
</pre>

Checks a built APK without a device: manifest package, 16 KiB alignment, signature, and
that every ABI ships the expected native libraries uncompressed, plus the expected assets.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="react_native_apk_test-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="react_native_apk_test-abis"></a>abis |  Exactly the ABIs the APK must ship.   | List of strings | optional |  `["arm64-v8a", "x86_64"]`  |
| <a id="react_native_apk_test-apk"></a>apk |  -   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="react_native_apk_test-assets"></a>assets |  Paths under assets/ that must exist, e.g. index.android.bundle.   | List of strings | optional |  `[]`  |
| <a id="react_native_apk_test-native_libs"></a>native_libs |  Libraries every ABI must ship.   | List of strings | optional |  `["libreactnative.so", "libappmodules.so", "libhermesvm.so", "libc++_shared.so"]`  |
| <a id="react_native_apk_test-package"></a>package |  Expected application id.   | String | required |  |


<a id="react_native_java_library"></a>

## react_native_java_library

<pre>
load("@rules_react_native//react_native:defs.bzl", "react_native_java_library")

react_native_java_library(<a href="#react_native_java_library-name">name</a>, <a href="#react_native_java_library-deps">deps</a>, <a href="#react_native_java_library-srcs">srcs</a>, <a href="#react_native_java_library-exports">exports</a>, <a href="#react_native_java_library-javacopts">javacopts</a>)
</pre>

Java code for a React Native Android app, compiled against android.jar with a pinned JDK 21.

Unlike rules_java's java_library, it needs no `--java_runtime_version` in the consumer's .bazelrc,
and its compile classpath is its deps' API closure (Gradle's `implementation` semantics).

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="react_native_java_library-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="react_native_java_library-deps"></a>deps |  -   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="react_native_java_library-srcs"></a>srcs |  -   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="react_native_java_library-exports"></a>exports |  Deps that are part of this library's API (Gradle's `api`).   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="react_native_java_library-javacopts"></a>javacopts |  Extra javac flags, after the defaults (`-source 17 -target 17`).   | List of strings | optional |  `[]`  |


<a id="react_native_maven_pin"></a>

## react_native_maven_pin

<pre>
load("@rules_react_native//react_native:defs.bzl", "react_native_maven_pin")

react_native_maven_pin(<a href="#react_native_maven_pin-name">name</a>, <a href="#react_native_maven_pin-pins">pins</a>)
</pre>

Resolves Maven specs into the lockfiles `react_native.maven` reads.

A spec is JSON: `{"artifacts": ["com.facebook.react:react-android:0.86.3", ...],
"build_type": "release" | "debug", "excludes": []}`. Resolution follows Gradle module metadata
(KMP redirects, build-type variants, dependency constraints), and hashes already in a lockfile are
reused, so re-pinning only downloads what changed.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="react_native_maven_pin-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="react_native_maven_pin-pins"></a>pins |  Spec file -> lockfile, both relative to this package.   | <a href="https://bazel.build/rules/lib/core/dict">Dictionary: String -> String</a> | required |  |


<a id="react_native_android_app"></a>

## react_native_android_app

<pre>
load("@rules_react_native//react_native:defs.bzl", "react_native_android_app")

react_native_android_app(<a href="#react_native_android_app-name">name</a>, <a href="#react_native_android_app-package">package</a>, <a href="#react_native_android_app-manifest">manifest</a>, <a href="#react_native_android_app-bundle">bundle</a>, <a href="#react_native_android_app-maven">maven</a>, <a href="#react_native_android_app-maven_debug">maven_debug</a>, <a href="#react_native_android_app-srcs">srcs</a>, <a href="#react_native_android_app-res">res</a>, <a href="#react_native_android_app-deps">deps</a>,
                         <a href="#react_native_android_app-codegen">codegen</a>, <a href="#react_native_android_app-react_packages">react_packages</a>, <a href="#react_native_android_app-min_sdk">min_sdk</a>, <a href="#react_native_android_app-target_sdk">target_sdk</a>, <a href="#react_native_android_app-version_code">version_code</a>, <a href="#react_native_android_app-version_name">version_name</a>,
                         <a href="#react_native_android_app-abis">abis</a>, <a href="#react_native_android_app-debug">debug</a>, <a href="#react_native_android_app-edge_to_edge">edge_to_edge</a>, <a href="#react_native_android_app-manifest_placeholders">manifest_placeholders</a>, <a href="#react_native_android_app-keystore">keystore</a>,
                         <a href="#react_native_android_app-keystore_password">keystore_password</a>, <a href="#react_native_android_app-key_alias">key_alias</a>, <a href="#react_native_android_app-javacopts">javacopts</a>, <a href="#react_native_android_app-kwargs">**kwargs</a>)
</pre>

Builds a signed React Native APK `<name>.apk` from Java sources and a `react_native_bundle`.

Also defines `<name>.install` (`bazel run` installs and launches the APK on a device) and
`<name>.sign` (`bazel run` signs it with a release key passed at run time; see `android_sign`).

The React Native runtime (react-android, Hermes) comes prebuilt from Maven; the only native
code built is the app's small libappmodules.so (React Native's default OnLoad.cpp). The sources
the React Native Gradle plugin would generate (BuildConfig, PackageList,
ReactNativeApplicationEntryPoint) are generated here.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="react_native_android_app-name"></a>name |  Target name; the APK is `<name>.apk`.   |  none |
| <a id="react_native_android_app-package"></a>package |  Application id and Java package of BuildConfig/R, e.g. "com.example.hello".   |  none |
| <a id="react_native_android_app-manifest"></a>manifest |  The app's AndroidManifest.xml. It needs no `package` attribute.   |  none |
| <a id="react_native_android_app-bundle"></a>bundle |  A `react_native_bundle` target for platform "android", embedded as assets/index.android.bundle. Required for release builds. Optional with `debug`, where the app loads JS from Metro (`react_native_dev_server`) and an embedded bundle is only the fallback when Metro isn't reachable.   |  `None` |
| <a id="react_native_android_app-maven"></a>maven |  The release Maven artifact set, a `react_native.maven` repository's `:all` target. Defaults to the set whose lockfile has `"build_type": "release"`.   |  `None` |
| <a id="react_native_android_app-maven_debug"></a>maven_debug |  The set with react-android/hermes-android's debug variants, used when `debug = True`. Defaults to the lockfile with `"build_type": "debug"`.   |  `None` |
| <a id="react_native_android_app-srcs"></a>srcs |  Java sources, typically MainApplication and MainActivity.   |  `[]` |
| <a id="react_native_android_app-res"></a>res |  Files under one `res/` directory.   |  `[]` |
| <a id="react_native_android_app-deps"></a>deps |  `react_native_android_library`, `react_native_java_library`, Maven artifacts (`@rn_maven//:<group>_<artifact>`) or plain `java_library` targets.   |  `[]` |
| <a id="react_native_android_app-codegen"></a>codegen |  `react_native_codegen` targets. Their Java specs are compiled with `srcs`, their C++ is linked into libappmodules.so and registered in the generated autolinking.cpp.   |  `[]` |
| <a id="react_native_android_app-react_packages"></a>react_packages |  Fully-qualified ReactPackage classes to register in PackageList, besides those `deps` declare.   |  `[]` |
| <a id="react_native_android_app-min_sdk"></a>min_sdk |  minSdkVersion.   |  `24` |
| <a id="react_native_android_app-target_sdk"></a>target_sdk |  targetSdkVersion. Defaults to the React Native profile's compileSdk.   |  `None` |
| <a id="react_native_android_app-version_code"></a>version_code |  versionCode.   |  `1` |
| <a id="react_native_android_app-version_name"></a>version_name |  versionName.   |  `"1.0"` |
| <a id="react_native_android_app-abis"></a>abis |  ABIs whose native libraries are packaged.   |  `["arm64-v8a", "x86_64"]` |
| <a id="react_native_android_app-debug"></a>debug |  Builds against react-android/hermes-android's debug variants and sets BuildConfig.DEBUG, which turns on developer support: loading JS from Metro with Fast Refresh, the dev menu, and the Hermes debugger. `<name>.install` also runs `adb reverse tcp:8081 tcp:8081` so the device reaches Metro on localhost.   |  `False` |
| <a id="react_native_android_app-edge_to_edge"></a>edge_to_edge |  Sets BuildConfig.IS_EDGE_TO_EDGE_ENABLED.   |  `False` |
| <a id="react_native_android_app-manifest_placeholders"></a>manifest_placeholders |  Extra `${...}` substitutions for the manifest merger. `applicationId` and `usesCleartextTraffic` (true in debug) are always set.   |  `{}` |
| <a id="react_native_android_app-keystore"></a>keystore |  Keystore for the in-build signature. Defaults to a public debug key; never ship that to a store. Sign release builds with `<name>.sign` instead, so the key and its password stay out of the build.   |  `Label("@rules_react_native//react_native/android:debug.keystore")` |
| <a id="react_native_android_app-keystore_password"></a>keystore_password |  Password of `keystore` and of its key. It's an action argument, so only for keys that aren't secret.   |  `"android"` |
| <a id="react_native_android_app-key_alias"></a>key_alias |  Alias of the signing key in `keystore`.   |  `"androiddebugkey"` |
| <a id="react_native_android_app-javacopts"></a>javacopts |  Extra javac flags for `srcs`.   |  `[]` |
| <a id="react_native_android_app-kwargs"></a>kwargs |  Common attributes (tags, visibility, ...) applied to every generated target.   |  none |


<a id="react_native_bundle"></a>

## react_native_bundle

<pre>
load("@rules_react_native//react_native:defs.bzl", "react_native_bundle")

react_native_bundle(<a href="#react_native_bundle-name">name</a>, <a href="#react_native_bundle-srcs">srcs</a>, <a href="#react_native_bundle-node_modules">node_modules</a>, <a href="#react_native_bundle-entry_point">entry_point</a>, <a href="#react_native_bundle-platform">platform</a>, <a href="#react_native_bundle-dev">dev</a>, <a href="#react_native_bundle-hermes">hermes</a>, <a href="#react_native_bundle-kwargs">**kwargs</a>)
</pre>

Bundles the app rooted at this package with Metro, as `react-native bundle` would.

The default output is `index.<platform>.bundle` (Hermes bytecode unless `hermes = False`); the
output group `assets` is the directory of image assets Metro wrote (Android `drawable-*` resource layout for "android", the iOS asset layout for "ios").


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="react_native_bundle-name"></a>name |  Target name.   |  none |
| <a id="react_native_bundle-srcs"></a>srcs |  JS/TS sources plus package.json, babel.config.js and metro.config.js if present.   |  none |
| <a id="react_native_bundle-node_modules"></a>node_modules |  The package's `npm_link_all_packages` target (e.g. ":node_modules").   |  none |
| <a id="react_native_bundle-entry_point"></a>entry_point |  Entry file relative to this package.   |  `"index.js"` |
| <a id="react_native_bundle-platform"></a>platform |  "android" or "ios".   |  `"android"` |
| <a id="react_native_bundle-dev"></a>dev |  Builds a development bundle (__DEV__ true, unoptimized).   |  `False` |
| <a id="react_native_bundle-hermes"></a>hermes |  Compiles the bundle to Hermes bytecode.   |  `True` |
| <a id="react_native_bundle-kwargs"></a>kwargs |  Common attributes.   |  none |


<a id="react_native_codegen"></a>

## react_native_codegen

<pre>
load("@rules_react_native//react_native:defs.bzl", "react_native_codegen")

react_native_codegen(<a href="#react_native_codegen-name">name</a>, <a href="#react_native_codegen-srcs">srcs</a>, <a href="#react_native_codegen-node_modules">node_modules</a>, <a href="#react_native_codegen-library_name">library_name</a>, <a href="#react_native_codegen-java_package">java_package</a>, <a href="#react_native_codegen-js_srcs_dir">js_srcs_dir</a>, <a href="#react_native_codegen-kwargs">**kwargs</a>)
</pre>

Generates TurboModule and Fabric component glue from specs, as `codegenConfig` does in Gradle.

The default output is a srcjar of the Java spec classes (`Native<Module>Spec`,
`<Component>ManagerInterface`/`Delegate`), for a `java_library`'s srcs. Pass the target to
`react_native_android_app(codegen = ...)` as well, which compiles the C++ into
libappmodules.so and registers it in the generated autolinking.cpp.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="react_native_codegen-name"></a>name |  Target name.   |  none |
| <a id="react_native_codegen-srcs"></a>srcs |  The spec files (`Native*.ts`, `*NativeComponent.ts`) and package.json.   |  none |
| <a id="react_native_codegen-node_modules"></a>node_modules |  The package's `npm_link_all_packages` target.   |  none |
| <a id="react_native_codegen-library_name"></a>library_name |  `codegenConfig.name`, e.g. "AppSpecs".   |  none |
| <a id="react_native_codegen-java_package"></a>java_package |  `codegenConfig.android.javaPackageName`.   |  none |
| <a id="react_native_codegen-js_srcs_dir"></a>js_srcs_dir |  `codegenConfig.jsSrcsDir`, relative to this package.   |  none |
| <a id="react_native_codegen-kwargs"></a>kwargs |  Common attributes.   |  none |


<a id="react_native_dev_server"></a>

## react_native_dev_server

<pre>
load("@rules_react_native//react_native:defs.bzl", "react_native_dev_server")

react_native_dev_server(<a href="#react_native_dev_server-name">name</a>, <a href="#react_native_dev_server-srcs">srcs</a>, <a href="#react_native_dev_server-node_modules">node_modules</a>, <a href="#react_native_dev_server-port">port</a>, <a href="#react_native_dev_server-kwargs">**kwargs</a>)
</pre>

`bazel run` target serving this package's JS from Metro, like `react-native start`.

Pair it with a `react_native_android_app(debug = True)`, whose `.install` target runs
`adb reverse` for `port`. Run it under `ibazel run` so edits sync into the server's sandbox and
reach the app through Fast Refresh; plain `bazel run` serves a snapshot.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="react_native_dev_server-name"></a>name |  Target name.   |  none |
| <a id="react_native_dev_server-srcs"></a>srcs |  The app's JS/TS sources, package.json, babel.config.js and metro.config.js if present.   |  none |
| <a id="react_native_dev_server-node_modules"></a>node_modules |  The package's `npm_link_all_packages` target.   |  none |
| <a id="react_native_dev_server-port"></a>port |  Port to serve on; must match the app (8081 unless changed in native code).   |  `8081` |
| <a id="react_native_dev_server-kwargs"></a>kwargs |  Common attributes.   |  none |


