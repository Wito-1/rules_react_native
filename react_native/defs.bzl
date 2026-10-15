"""Public API of the React Native ruleset. See README.md."""

load("@rn_profile//:profile.bzl", "APPMODULES_COPTS", "COMPILE_SDK")
load(
    "//react_native/android/private:android_app.bzl",
    "android_apk",
    "android_app_resources",
    "android_install",
    "android_install_bundle",
    "android_sign",
    "android_sign_bundle",
)
load("//react_native/android/private:apk_test.bzl", _react_native_apk_test = "react_native_apk_test")
load("//react_native/android/private:appmodules.bzl", "react_native_appmodules")
load("//react_native/android/private:java.bzl", _react_native_java_library = "react_native_java_library")
load("//react_native/android/private:library.bzl", _react_native_android_library = "react_native_android_library", _react_native_npm_library = "react_native_npm_library")
load("//react_native/android/private:pin.bzl", _react_native_maven_pin = "react_native_maven_pin")
load("//react_native/js/private:autolink.bzl", _react_native_autolink = "react_native_autolink")
load("//react_native/js/private:bundle.bzl", _react_native_bundle = "react_native_bundle")
load("//react_native/js/private:codegen.bzl", _react_native_codegen = "react_native_codegen")
load("//react_native/js/private:dev_server.bzl", _react_native_dev_server = "react_native_dev_server")

react_native_android_library = _react_native_android_library
react_native_autolink = _react_native_autolink
react_native_apk_test = _react_native_apk_test
react_native_bundle = _react_native_bundle
react_native_codegen = _react_native_codegen
react_native_dev_server = _react_native_dev_server
react_native_java_library = _react_native_java_library
react_native_maven_pin = _react_native_maven_pin
react_native_npm_library = _react_native_npm_library

# Aliases the extension points at the consumer's release/debug `react_native.maven` sets.
_DEFAULT_MAVEN = Label("@rn_maven_default//:all")
_DEFAULT_MAVEN_DEBUG = Label("@rn_maven_default_debug//:all")

def react_native_android_app(
        name,
        package,
        manifest,
        application_id = None,
        build_config_fields = {},
        bundle = None,
        maven = None,
        maven_debug = None,
        srcs = [],
        res = [],
        assets = [],
        deps = [],
        codegen = [],
        react_packages = [],
        min_sdk = 24,
        target_sdk = None,
        version_code = 1,
        version_name = "1.0",
        abis = ["arm64-v8a", "x86_64"],
        debug = False,
        edge_to_edge = False,
        manifest_placeholders = {},
        adb_reverse = [],
        minify = False,
        proguard_specs = [],
        keystore = Label("//react_native/android:debug.keystore"),
        keystore_password = "android",
        key_alias = "androiddebugkey",
        javacopts = [],
        kotlincopts = [],
        **kwargs):
    """Builds a signed React Native APK `<name>.apk` from Java or Kotlin sources and a `react_native_bundle`.

    Also defines `<name>.install` (`bazel run` installs and launches the APK on a device) and
    `<name>.sign` (`bazel run` signs it with a release key passed at run time; see `android_sign`),
    and for Play: `<name>.aab` (the unsigned Android App Bundle, carrying the R8 mapping and native
    debug symbols in its metadata), `<name>.aab.sign` (`bazel run` signs it with an upload key passed
    at run time) and `<name>.aab.install` (`bazel run` installs it through bundletool, as Play
    would). The output groups `native_debug_symbols` (Play's native-debug-symbols.zip),
    `proguard_mapping` and the bundle's `sourcemap` are what crash reporters need.

    The React Native runtime (react-android, Hermes) comes prebuilt from Maven; the only native
    code built is the app's small libappmodules.so (React Native's default OnLoad.cpp). The sources
    the React Native Gradle plugin would generate (BuildConfig, PackageList,
    ReactNativeApplicationEntryPoint) are generated here.

    Args:
        name: Target name; the APK is `<name>.apk`.
        package: Java package of BuildConfig and R, and the base for relative class names in the
            manifest (Gradle's `namespace`), e.g. "com.example.hello". Also the application id
            unless `application_id` is set.
        application_id: The installed app's id when it differs from `package`, e.g. a staging
            variant's "com.example.hello.staging" that installs next to the release.
        build_config_fields: Extra `public static final String` fields of BuildConfig, like
            Gradle's `buildConfigField`.
        manifest: The app's AndroidManifest.xml. It needs no `package` attribute.
        bundle: A `react_native_bundle` target for platform "android", embedded as
            assets/index.android.bundle. Required for release builds. Optional with `debug`, where
            the app loads JS from Metro (`react_native_dev_server`) and an embedded bundle is only
            the fallback when Metro isn't reachable.
        maven: The release Maven artifact set, a `react_native.maven` repository's `:all` target.
            Defaults to the set whose lockfile has `"build_type": "release"`.
        maven_debug: The set with react-android/hermes-android's debug variants, used when
            `debug = True`. Defaults to the lockfile with `"build_type": "debug"`.
        srcs: Java or Kotlin sources, typically MainApplication and MainActivity.
        res: Files under one `res/` directory.
        assets: Files under one `assets/` directory, packaged at the same relative paths. Custom
            fonts go in `assets/fonts/<fontFamily>.ttf`, where React Native's font manager looks.
        deps: `react_native_android_library`, `react_native_npm_library`, `react_native_java_library`, Maven artifacts
            (`@rn_maven//:<group>_<artifact>`) or plain `java_library` targets.
        codegen: `react_native_codegen` targets. Their Java specs are compiled with `srcs`, their
            C++ is linked into libappmodules.so and registered in the generated autolinking.cpp.
        react_packages: Fully-qualified ReactPackage classes to register in PackageList, besides
            those `deps` declare.
        min_sdk: minSdkVersion.
        target_sdk: targetSdkVersion. Defaults to the React Native profile's compileSdk.
        version_code: versionCode.
        version_name: versionName.
        abis: ABIs whose native libraries are packaged.
        debug: Builds against react-android/hermes-android's debug variants and sets
            BuildConfig.DEBUG, which turns on developer support: loading JS from Metro with Fast
            Refresh, the dev menu, and the Hermes debugger. `<name>.install` also runs
            `adb reverse tcp:8081 tcp:8081` so the device reaches Metro on localhost.
        edge_to_edge: Sets BuildConfig.IS_EDGE_TO_EDGE_ENABLED.
        adb_reverse: Host ports `<name>.install` exposes on the device's localhost (`adb reverse`),
            e.g. a development backend's.
        minify: Shrink, optimize and obfuscate the app's code with R8 (Gradle's `minifyEnabled`).
            Rules: the ruleset's defaults, aapt2's keep rules, every library's consumer rules
            (AAR proguard.txt, rules embedded in jars) and `proguard_specs`.
        proguard_specs: The app's own R8 rules (`proguard-rules.pro`).
        manifest_placeholders: Extra `${...}` substitutions for the manifest merger. `applicationId`
            and `usesCleartextTraffic` (true in debug) are always set.
        keystore: Keystore for the in-build signature. Defaults to a public debug key; never ship
            that to a store. Sign release builds with `<name>.sign` instead, so the key and its
            password stay out of the build.
        keystore_password: Password of `keystore` and of its key. It's an action argument, so only
            for keys that aren't secret.
        key_alias: Alias of the signing key in `keystore`.
        javacopts: Extra javac flags for `srcs`.
        kotlincopts: Extra kotlinc flags for Kotlin `srcs`.
        **kwargs: Common attributes (tags, visibility, ...) applied to every generated target.
    """
    # `|` rather than update() so `manifest_placeholders` can be a select().
    placeholders = {"usesCleartextTraffic": "true" if debug else "false"} | manifest_placeholders

    if bundle == None and not debug:
        fail("react_native_android_app: release builds need a `bundle`")
    if debug:
        rn_maven = maven_debug or _DEFAULT_MAVEN_DEBUG
    else:
        rn_maven = maven or _DEFAULT_MAVEN
    if target_sdk == None:
        target_sdk = COMPILE_SDK

    generated_res = []
    if bundle:
        native.filegroup(
            name = name + "_bundle_res",
            srcs = [bundle],
            output_group = "assets",
            **kwargs
        )
        generated_res = [name + "_bundle_res"]
    android_app_resources(
        name = name + "_resources",
        package = package,
        application_id = application_id,
        build_config_fields = build_config_fields,
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
    _react_native_java_library(
        name = name + "_lib",
        srcs = srcs + [name + "_resources"] + codegen,
        deps = deps + [rn_maven],
        javacopts = javacopts,
        kotlincopts = kotlincopts,
        **kwargs
    )
    react_native_appmodules(
        name = name + "_appmodules",
        abis = abis,
        codegen = codegen,
        copts = APPMODULES_COPTS,
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
        app_assets = assets,
        abis = abis,
        debug = debug,
        minify = minify,
        proguard_specs = proguard_specs,
        keystore = keystore,
        keystore_password = keystore_password,
        key_alias = key_alias,
        **kwargs
    )
    android_install(
        name = name + ".install",
        apk = name,
        debug = debug,
        package = application_id or package,
        reverse_ports = adb_reverse,
        **kwargs
    )
    android_sign(
        name = name + ".sign",
        apk = name,
        **kwargs
    )
    native.filegroup(
        name = name + ".aab",
        srcs = [name],
        output_group = "aab",
        **kwargs
    )
    android_sign_bundle(
        name = name + ".aab.sign",
        apk = name,
        **kwargs
    )
    android_install_bundle(
        name = name + ".aab.install",
        apk = name,
        keystore = keystore,
        keystore_password = keystore_password,
        key_alias = key_alias,
        package = application_id or package,
        reverse_ports = adb_reverse,
        **kwargs
    )
