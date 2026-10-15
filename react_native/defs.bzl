"""Public API of the React Native ruleset. See README.md."""

load("@rules_java//java:java_library.bzl", "java_library")
load("//react_native/android/private:android_app.bzl", "android_apk", "android_app_resources", "android_install")
load("//react_native/android/private:appmodules.bzl", "react_native_appmodules")
load("//react_native/android/private:pin.bzl", _react_native_maven_pin = "react_native_maven_pin")
load("//react_native/android/private:versions.bzl", "COMPILE_SDK")
load("//react_native/js/private:bundle.bzl", _react_native_bundle = "react_native_bundle")
load("//react_native/js/private:codegen.bzl", _react_native_codegen = "react_native_codegen")
load("//react_native/js/private:dev_server.bzl", _react_native_dev_server = "react_native_dev_server")

react_native_bundle = _react_native_bundle
react_native_codegen = _react_native_codegen
react_native_dev_server = _react_native_dev_server
react_native_maven_pin = _react_native_maven_pin

_ANDROID_JAR = Label("@rn_android_sdk//:android_jar")

def react_native_android_app(
        name,
        package,
        manifest,
        bundle = None,
        maven = "@rn_maven//:all",
        maven_debug = "@rn_maven_debug//:all",
        srcs = [],
        res = [],
        deps = [],
        codegen = [],
        react_packages = [],
        min_sdk = 24,
        target_sdk = COMPILE_SDK,
        version_code = 1,
        version_name = "1.0",
        abis = ["arm64-v8a", "x86_64"],
        debug = False,
        edge_to_edge = False,
        manifest_placeholders = {},
        keystore = Label("//react_native/android:debug.keystore"),
        keystore_password = "android",
        key_alias = "androiddebugkey",
        javacopts = [],
        **kwargs):
    """Builds a signed React Native APK `<name>.apk` from Java sources and a `react_native_bundle`.

    Also defines `<name>.install`, which `bazel run` uses to install and launch the APK on a device.

    The React Native runtime (react-android, Hermes) comes prebuilt from Maven; the only native
    code built is the app's small libappmodules.so (React Native's default OnLoad.cpp). The sources
    the React Native Gradle plugin would generate (BuildConfig, PackageList,
    ReactNativeApplicationEntryPoint) are generated here.

    Args:
        name: Target name; the APK is `<name>.apk`.
        package: Application id and Java package of BuildConfig/R, e.g. "com.example.hello".
        manifest: The app's AndroidManifest.xml. It needs no `package` attribute.
        bundle: A `react_native_bundle` target for platform "android", embedded as
            assets/index.android.bundle. Required for release builds. Optional with `debug`, where
            the app loads JS from Metro (`react_native_dev_server`) and an embedded bundle is only
            the fallback when Metro isn't reachable.
        maven: The release Maven artifact set, a `react_native.maven` repository's `:all` target.
            Resolved in the calling package, so the default needs `use_repo(react_native, "rn_maven")`.
        maven_debug: The same set with react-android/hermes-android's debug variants, used when
            `debug = True`.
        srcs: Java sources, typically MainApplication and MainActivity.
        res: Files under one `res/` directory.
        deps: Extra Java or Android library deps.
        codegen: `react_native_codegen` targets. Their Java specs are compiled with `srcs`, their
            C++ is linked into libappmodules.so and registered in the generated autolinking.cpp.
        react_packages: Fully-qualified ReactPackage classes to register in PackageList (manual autolinking).
        min_sdk: minSdkVersion.
        target_sdk: targetSdkVersion.
        version_code: versionCode.
        version_name: versionName.
        abis: ABIs whose native libraries are packaged.
        debug: Builds against react-android/hermes-android's debug variants and sets
            BuildConfig.DEBUG, which turns on developer support: loading JS from Metro with Fast
            Refresh, the dev menu, and the Hermes debugger. `<name>.install` also runs
            `adb reverse tcp:8081 tcp:8081` so the device reaches Metro on localhost.
        edge_to_edge: Sets BuildConfig.IS_EDGE_TO_EDGE_ENABLED.
        manifest_placeholders: Extra `${...}` substitutions for the manifest merger. `applicationId`
            and `usesCleartextTraffic` (true in debug) are always set.
        keystore: Signing keystore. Defaults to a public debug key; never ship that to a store.
        keystore_password: Password of `keystore` and of its key.
        key_alias: Alias of the signing key in `keystore`.
        javacopts: Extra javac flags for `srcs`.
        **kwargs: Common attributes (tags, visibility, ...) applied to every generated target.
    """
    placeholders = {"usesCleartextTraffic": "true" if debug else "false"}
    placeholders.update(manifest_placeholders)

    if bundle == None and not debug:
        fail("react_native_android_app: release builds need a `bundle`")
    rn_maven = maven_debug if debug else maven

    generated_res = []
    if bundle:
        native.filegroup(
            name = name + "_bundle_res",
            srcs = [bundle],
            output_group = "res",
            **kwargs
        )
        generated_res = [name + "_bundle_res"]
    android_app_resources(
        name = name + "_resources",
        package = package,
        manifest = manifest,
        res = res,
        generated_res = generated_res,
        deps = deps + [rn_maven],
        react_packages = react_packages,
        min_sdk = min_sdk,
        target_sdk = target_sdk,
        version_code = version_code,
        version_name = version_name,
        debug = debug,
        edge_to_edge = edge_to_edge,
        manifest_placeholders = placeholders,
        **kwargs
    )
    java_library(
        name = name + "_lib",
        srcs = srcs + [name + "_resources"] + codegen,
        deps = deps + [rn_maven, _ANDROID_JAR],
        javacopts = javacopts,
        **kwargs
    )
    react_native_appmodules(
        name = name + "_appmodules",
        abis = abis,
        codegen = codegen,
        debug = debug,
        min_sdk = min_sdk,
        deps = deps + [rn_maven],
        **kwargs
    )
    android_apk(
        name = name,
        resources = name + "_resources",
        deps = [name + "_lib", name + "_appmodules", rn_maven] + deps,
        assets = [bundle] if bundle else [],
        abis = abis,
        debug = debug,
        keystore = keystore,
        keystore_password = keystore_password,
        key_alias = key_alias,
        **kwargs
    )
    android_install(
        name = name + ".install",
        apk = name,
        debug = debug,
        package = package,
        **kwargs
    )
