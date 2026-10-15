"""The `react_native` module extension.

The ruleset owns the Android SDK, NDK and its host tool jars (`@rn_android_sdk`, `@rn_android_ndk`,
`@rn_android_tools_maven`, `@rn_kotlin_compiler_maven`). Each consumer supplies the React Native artifact sets it builds against:

```starlark
react_native = use_extension("@rules_react_native//react_native:extensions.bzl", "react_native")
react_native.maven(name = "rn_maven", lock_file = "//android:maven_lock.json")
react_native.maven(name = "rn_maven_debug", lock_file = "//android:maven_debug_lock.json")
```

The react-android version in those lockfiles selects a toolchain profile (compileSdk, build-tools,
NDK, native compile flags) from `REACT_NATIVE_PROFILES`; an unsupported version fails here rather
than producing an app that crashes at startup. The root module can override the SDK/NDK choice
with `react_native.android_toolchain`.

The rules default to the release and debug sets (told apart by each lockfile's `build_type`), so
consumers only `use_repo` the hubs to reference individual artifacts.
"""

load(
    "//react_native/android/private:repositories.bzl",
    "android_maven_repository",
    "android_ndk_repository",
    "android_sdk_repository",
    "default_maven_repository",
    "host_alias_repository",
    "java_maven_repository",
    "profile_repository",
)
load(
    "//react_native/android/private:versions.bzl",
    "BUILD_TOOLS",
    "DEFAULT_PROFILE",
    "NDKS",
    "PLATFORMS",
    "PLATFORM_TOOLS",
    "REACT_NATIVE_PROFILES",
)

_HOSTS = ["linux", "macos"]
_REACT_ANDROID = "com_facebook_react_react_android"

def _react_android_minor(mctx, lock_file):
    lock = json.decode(mctx.read(lock_file))
    entry = lock["artifacts"].get(_REACT_ANDROID)
    if entry == None:
        return None, lock.get("build_type", "release")
    version = entry["coordinate"].split(":")[2]
    return ".".join(version.split(".")[:2]), lock.get("build_type", "release")

def _choose(kind, value, table):
    if value not in table:
        fail("react_native.android_toolchain: no pinned {} {}; known: {}".format(kind, value, ", ".join([str(k) for k in sorted(table)])))
    return value

def _react_native_impl(mctx):
    hubs = {}
    defaults = {}
    rn_minors = {}
    for mod in mctx.modules:
        for tag in mod.tags.maven:
            if tag.name in hubs:
                fail("react_native.maven: repository {} is declared by both {} and {}".format(tag.name, hubs[tag.name], mod.name))
            hubs[tag.name] = mod.name
            android_maven_repository(name = tag.name, lock_file = tag.lock_file)
            minor, build_type = _react_android_minor(mctx, tag.lock_file)
            if minor:
                rn_minors[tag.name] = minor

            # The root module's sets win; a dependency's are a fallback for running its examples.
            if build_type not in defaults or mod.is_root:
                defaults[build_type] = tag.name

    minors = sorted({m: True for m in rn_minors.values()})
    if len(minors) > 1:
        fail("react_native.maven: the lockfiles pin different React Native versions: {}".format(rn_minors))
    rn_minor = minors[0] if minors else DEFAULT_PROFILE
    if rn_minor not in REACT_NATIVE_PROFILES:
        fail(("rules_react_native supports React Native {} but the lockfiles pin react-android {}.x. " +
              "See react_native/android/private/versions.bzl for what a new version needs.").format(
            ", ".join(sorted(REACT_NATIVE_PROFILES)),
            rn_minor,
        ))
    profile = REACT_NATIVE_PROFILES[rn_minor]
    compile_sdk, build_tools, ndk = profile.compile_sdk, profile.build_tools, profile.ndk
    for mod in mctx.modules:
        for tag in mod.tags.android_toolchain:
            if not mod.is_root:
                continue
            if tag.compile_sdk:
                compile_sdk = _choose("platform", tag.compile_sdk, PLATFORMS)
            if tag.build_tools:
                build_tools = _choose("build-tools", tag.build_tools, BUILD_TOOLS)
            if tag.ndk:
                ndk = _choose("NDK", tag.ndk, NDKS)

    platform = PLATFORMS[compile_sdk]
    for host in _HOSTS:
        archive = BUILD_TOOLS[build_tools][host]
        android_sdk_repository(
            name = "rn_android_sdk_" + host,
            platform_url = platform.url,
            platform_sha256 = platform.sha256,
            platform_strip_prefix = platform.strip_prefix,
            build_tools_url = archive.url,
            build_tools_sha256 = archive.sha256,
            build_tools_strip_prefix = archive.strip_prefix,
            platform_tools_url = PLATFORM_TOOLS[host].url,
            platform_tools_sha256 = PLATFORM_TOOLS[host].sha256,
            platform_tools_strip_prefix = PLATFORM_TOOLS[host].strip_prefix,
        )
        ndk_archive = NDKS[ndk][host]
        android_ndk_repository(
            name = "rn_android_ndk_" + host,
            url = ndk_archive.url,
            sha256 = ndk_archive.sha256,
            strip_prefix = ndk_archive.strip_prefix,
            host_dir = ndk_archive.host_dir,
        )
    host_alias_repository(
        name = "rn_android_sdk",
        linux_repo = "rn_android_sdk_linux",
        macos_repo = "rn_android_sdk_macos",
        targets = ["aapt2", "adb", "android_jar", "android_jar_file", "apksigner_jar", "d8_jar", "zipalign", "zipalign_libs"],
    )
    host_alias_repository(
        name = "rn_android_ndk",
        linux_repo = "rn_android_ndk_linux",
        macos_repo = "rn_android_ndk_macos",
        targets = ["clang", "toolchain_files"],
    )
    profile_repository(
        name = "rn_profile",
        react_native_version = rn_minor,
        compile_sdk = compile_sdk,
        appmodules_copts = profile.appmodules_copts,
    )
    for build_type, repo in [("release", "rn_maven_default"), ("debug", "rn_maven_default_debug")]:
        default_maven_repository(
            name = repo,
            actual = defaults.get(build_type, ""),
            missing_message = ("rules_react_native: no react_native.maven tag pins a {0} artifact set " +
                               "(a lockfile with \"build_type\": \"{0}\"); add one, or pass `maven{1}` explicitly.").format(
                build_type,
                "_debug" if build_type == "debug" else "",
            ),
        )
    java_maven_repository(
        name = "rn_android_tools_maven",
        lock_file = "//react_native/android:maven_tools_lock.json",
    )
    java_maven_repository(
        name = "rn_kotlin_compiler_maven",
        lock_file = "//react_native/android:maven_kotlin_lock.json",
    )
    return mctx.extension_metadata(reproducible = True)

_maven = tag_class(
    doc = "An Android Maven artifact set (react-android, hermes-android and their closure), pinned by `react_native_maven_pin`.",
    attrs = {
        "name": attr.string(mandatory = True, doc = "Repository name; `@<name>//:all` is the whole set."),
        "lock_file": attr.label(mandatory = True, doc = "Lockfile written by `react_native_maven_pin`. Its `build_type` makes it the default release or debug set."),
    },
)

_android_toolchain = tag_class(
    doc = "Overrides the SDK/NDK the React Native profile picks. Root module only; values must be pinned in versions.bzl.",
    attrs = {
        "build_tools": attr.string(doc = "e.g. \"37.0.0\""),
        "compile_sdk": attr.int(doc = "e.g. 37"),
        "ndk": attr.string(doc = "e.g. \"27.1.12297006\""),
    },
)

react_native = module_extension(
    implementation = _react_native_impl,
    doc = "Android SDK and NDK, the ruleset's host tools, and each consumer's React Native Maven artifact sets.",
    tag_classes = {
        "android_toolchain": _android_toolchain,
        "maven": _maven,
    },
)
