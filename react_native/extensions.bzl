"""The `react_native` module extension.

The ruleset owns the Android SDK, NDK and its host tool jars (`@rn_android_sdk`, `@rn_android_ndk`,
`@rn_android_tools_maven`). Each consumer supplies the React Native artifact set it builds against,
which is what fixes its React Native version:

```starlark
react_native = use_extension("@rules_react_native//react_native:extensions.bzl", "react_native")
react_native.maven(name = "rn_maven", lock_file = "//android:maven_lock.json")
react_native.maven(name = "rn_maven_debug", lock_file = "//android:maven_debug_lock.json")
use_repo(react_native, "rn_maven", "rn_maven_debug")
```
"""

load(
    "//react_native/android/private:repositories.bzl",
    "android_maven_repository",
    "android_ndk_repository",
    "android_sdk_repository",
    "host_alias_repository",
    "java_maven_repository",
)
load(
    "//react_native/android/private:versions.bzl",
    "BUILD_TOOLS_ARCHIVES",
    "NDK_ARCHIVES",
    "PLATFORM",
    "PLATFORM_TOOLS_ARCHIVES",
)

def _react_native_impl(mctx):
    for host, archive in BUILD_TOOLS_ARCHIVES.items():
        android_sdk_repository(
            name = "rn_android_sdk_" + host,
            platform_url = PLATFORM.url,
            platform_sha256 = PLATFORM.sha256,
            platform_strip_prefix = PLATFORM.strip_prefix,
            build_tools_url = archive.url,
            build_tools_sha256 = archive.sha256,
            build_tools_strip_prefix = archive.strip_prefix,
            platform_tools_url = PLATFORM_TOOLS_ARCHIVES[host].url,
            platform_tools_sha256 = PLATFORM_TOOLS_ARCHIVES[host].sha256,
            platform_tools_strip_prefix = PLATFORM_TOOLS_ARCHIVES[host].strip_prefix,
        )
    host_alias_repository(
        name = "rn_android_sdk",
        linux_repo = "rn_android_sdk_linux",
        macos_repo = "rn_android_sdk_macos",
        targets = ["aapt2", "adb", "android_jar", "android_jar_file", "apksigner_jar", "d8_jar", "zipalign", "zipalign_libs"],
    )
    for host, archive in NDK_ARCHIVES.items():
        android_ndk_repository(
            name = "rn_android_ndk_" + host,
            url = archive.url,
            sha256 = archive.sha256,
            strip_prefix = archive.strip_prefix,
            host_dir = archive.host_dir,
        )
    host_alias_repository(
        name = "rn_android_ndk",
        linux_repo = "rn_android_ndk_linux",
        macos_repo = "rn_android_ndk_macos",
        targets = ["clang", "toolchain_files"],
    )
    seen = {}
    for mod in mctx.modules:
        for tag in mod.tags.maven:
            if tag.name in seen:
                fail("react_native.maven: repository {} is declared by both {} and {}".format(tag.name, seen[tag.name], mod.name))
            seen[tag.name] = mod.name
            android_maven_repository(name = tag.name, lock_file = tag.lock_file)
    java_maven_repository(
        name = "rn_android_tools_maven",
        lock_file = "//react_native/android:maven_tools_lock.json",
    )
    return mctx.extension_metadata(reproducible = True)

_maven = tag_class(
    doc = "An Android Maven artifact set (react-android, hermes-android and their closure), pinned by `react_native_maven_pin`.",
    attrs = {
        "name": attr.string(mandatory = True, doc = "Repository name; `@<name>//:all` is the whole set."),
        "lock_file": attr.label(mandatory = True, doc = "Lockfile written by `react_native_maven_pin`."),
    },
)

react_native = module_extension(
    implementation = _react_native_impl,
    doc = "Android SDK and NDK, the ruleset's host tools, and each consumer's React Native Maven artifact sets.",
    tag_classes = {"maven": _maven},
)
