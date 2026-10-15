"""Repository rules for the hermetic Android SDK and the pinned Maven artifacts."""

_SDK_BUILD = """\
load("@rules_java//java:java_import.bzl", "java_import")

package(default_visibility = ["//visibility:public"])

java_import(
    name = "android_jar",
    jars = ["platform/android.jar"],
    neverlink = True,
)

filegroup(
    name = "android_jar_file",
    srcs = ["platform/android.jar"],
)

filegroup(
    name = "aapt2",
    srcs = ["build-tools/aapt2"],
)

# zipalign resolves libc++ through $ORIGIN/lib64, so the libraries travel with it as inputs.
filegroup(
    name = "zipalign",
    srcs = ["build-tools/zipalign"],
)

filegroup(
    name = "zipalign_libs",
    srcs = glob(["build-tools/lib64/libc++*"]),
)

filegroup(
    name = "adb",
    srcs = ["platform-tools/adb"],
)

filegroup(
    name = "d8_jar",
    srcs = ["build-tools/lib/d8.jar"],
)

filegroup(
    name = "apksigner_jar",
    srcs = ["build-tools/lib/apksigner.jar"],
)
"""

def _android_sdk_repository_impl(rctx):
    rctx.download_and_extract(
        url = rctx.attr.platform_url,
        sha256 = rctx.attr.platform_sha256,
        output = "platform",
        stripPrefix = rctx.attr.platform_strip_prefix,
    )
    rctx.download_and_extract(
        url = rctx.attr.build_tools_url,
        sha256 = rctx.attr.build_tools_sha256,
        output = "build-tools",
        stripPrefix = rctx.attr.build_tools_strip_prefix,
    )
    rctx.download_and_extract(
        url = rctx.attr.platform_tools_url,
        sha256 = rctx.attr.platform_tools_sha256,
        output = "platform-tools",
        stripPrefix = rctx.attr.platform_tools_strip_prefix,
    )
    rctx.file("BUILD.bazel", _SDK_BUILD)

android_sdk_repository = repository_rule(
    implementation = _android_sdk_repository_impl,
    doc = "Downloads one Android platform, one build-tools release and platform-tools (adb) for a single host OS.",
    attrs = {
        "build_tools_sha256": attr.string(mandatory = True),
        "build_tools_strip_prefix": attr.string(mandatory = True),
        "build_tools_url": attr.string(mandatory = True),
        "platform_sha256": attr.string(mandatory = True),
        "platform_strip_prefix": attr.string(mandatory = True),
        "platform_tools_sha256": attr.string(mandatory = True),
        "platform_tools_strip_prefix": attr.string(mandatory = True),
        "platform_tools_url": attr.string(mandatory = True),
        "platform_url": attr.string(mandatory = True),
    },
)

_SDK_ALIAS_BUILD = """\
package(default_visibility = ["//visibility:public"])

[
    alias(
        name = name,
        actual = select({{
            "@platforms//os:linux": "@{linux}//:" + name,
            "@platforms//os:macos": "@{macos}//:" + name,
        }}),
    )
    for name in {names}
]
"""

def _host_alias_repository_impl(rctx):
    rctx.file("BUILD.bazel", _SDK_ALIAS_BUILD.format(
        linux = rctx.attr.linux_repo,
        macos = rctx.attr.macos_repo,
        names = repr(rctx.attr.targets),
    ))

host_alias_repository = repository_rule(
    implementation = _host_alias_repository_impl,
    doc = "Aliases `targets` to the per-host repository. Tools are consumed in the exec configuration, so the select follows the exec platform.",
    attrs = {
        "linux_repo": attr.string(mandatory = True),
        "macos_repo": attr.string(mandatory = True),
        "targets": attr.string_list(mandatory = True),
    },
)

def _list_dirs(rctx, path):
    p = rctx.path(path)
    if not p.exists:
        return []
    return [child.basename for child in p.readdir() if child.is_dir]

def _manifest_package(rctx, manifest):
    content = rctx.read(manifest)
    start = content.find("package=\"")
    if start < 0:
        fail("no package attribute in {}".format(manifest))
    start += len("package=\"")
    return content[start:content.find("\"", start)]

def _android_maven_repository_impl(rctx):
    lock = json.decode(rctx.read(rctx.attr.lock_file))
    import_bzl = str(rctx.attr._aar_bzl)
    build = [
        'load("{}", "android_maven_import")'.format(import_bzl),
        "",
        'package(default_visibility = ["//visibility:public"])',
        "",
    ]
    for name, entry in sorted(lock["artifacts"].items()):
        attrs = {
            "coordinate": repr(entry["coordinate"]),
            "deps": repr([":" + d for d in entry["deps"]]),
        }
        packaging = entry.get("packaging")
        if packaging == "aar":
            rctx.download_and_extract(
                url = entry["url"],
                sha256 = entry["sha256"],
                output = name,
                type = "zip",
            )

            # prefab/ holds headers plus unstripped copies of jni/ libraries (~300MB for
            # react-android alone). Linking against the stripped jni/ copies works the same.
            for module in _list_dirs(rctx, "{}/prefab/modules".format(name)):
                rctx.delete("{}/prefab/modules/{}/libs".format(name, module))
            attrs.update({
                "aar_package": repr(_manifest_package(rctx, "{}/AndroidManifest.xml".format(name))),
                "assets": 'glob(["{}/assets/**"], allow_empty = True)'.format(name),
                "jars": 'glob(["{0}/classes.jar", "{0}/libs/*.jar"], allow_empty = True)'.format(name),
                "manifest": repr("{}/AndroidManifest.xml".format(name)),
                "native_libs": 'glob(["{}/jni/*/*.so"], allow_empty = True)'.format(name),
                "prefab_headers": 'glob(["{}/prefab/modules/*/include/**"], allow_empty = True)'.format(name),
                "r_txt": 'glob(["{}/R.txt"], allow_empty = True)'.format(name),
                "res": 'glob(["{}/res/**"], exclude = ["**/.*"], allow_empty = True)'.format(name),
            })
        elif packaging == "jar":
            jar = "{0}/{0}.jar".format(name)
            rctx.download(url = entry["url"], sha256 = entry["sha256"], output = jar)
            attrs["jars"] = repr([jar])
        build.append("android_maven_import(\n    name = {},\n{})\n".format(
            repr(name),
            "".join(["    {} = {},\n".format(k, v) for k, v in sorted(attrs.items())]),
        ))
    build.append("alias(\n    name = \"all\",\n    actual = \":_all\",\n)\n")

    # Every artifact is a direct dep so the whole pinned set is on the app's compile classpath,
    # as Gradle's `api` closure of react-android would make it.
    build.append("android_maven_import(\n    name = \"_all\",\n    coordinate = \"all\",\n    deps = {},\n)\n".format(
        repr([":" + name for name in sorted(lock["artifacts"])]),
    ))
    rctx.file("BUILD.bazel", "\n".join(build))

android_maven_repository = repository_rule(
    implementation = _android_maven_repository_impl,
    doc = "Downloads every artifact in an Android Maven lockfile; AARs are unpacked so their parts are plain inputs.",
    attrs = {
        "lock_file": attr.label(mandatory = True, allow_single_file = True),
        "_aar_bzl": attr.label(default = "//react_native/android/private:aar.bzl"),
    },
)

def _java_maven_repository_impl(rctx):
    lock = json.decode(rctx.read(rctx.attr.lock_file))
    jars = []
    for name, entry in sorted(lock["artifacts"].items()):
        if entry.get("packaging") != "jar":
            continue
        jar = "{}.jar".format(name)
        rctx.download(url = entry["url"], sha256 = entry["sha256"], output = jar)
        jars.append(jar)
    rctx.file("BUILD.bazel", """\
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "all",
    srcs = {},
)
""".format(repr(jars)))

java_maven_repository = repository_rule(
    implementation = _java_maven_repository_impl,
    doc = "Downloads a flat classpath of host-side Java tool jars from a lockfile.",
    attrs = {
        "lock_file": attr.label(mandatory = True, allow_single_file = True),
    },
)

_NDK_BUILD = """\
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "clang",
    srcs = ["{tc}/bin/clang++"],
)

# Only what compiling and linking one shared library needs: clang finds bin/../sysroot and its
# resource dir on its own, and invokes ld.lld from its own bin/.
filegroup(
    name = "toolchain_files",
    srcs = glob([
        "{tc}/bin/clang",
        "{tc}/bin/clang++",
        "{tc}/bin/clang-*",
        "{tc}/bin/ld.lld",
        "{tc}/bin/lld",
        "{tc}/lib/clang/*/include/**",
        "{tc}/lib/clang/*/lib/linux/libclang_rt.builtins-*-android.a",
        "{tc}/lib/clang/*/lib/linux/*/libunwind.a",
        "{tc}/sysroot/usr/include/**",
        "{tc}/sysroot/usr/lib/*/2*/**",
        "{tc}/sysroot/usr/lib/*/3*/**",
    ], exclude = ["{tc}/bin/clang-*-*"]),
)
"""

def _android_ndk_repository_impl(rctx):
    rctx.download_and_extract(
        url = rctx.attr.url,
        sha256 = rctx.attr.sha256,
        stripPrefix = rctx.attr.strip_prefix,
    )
    rctx.file("BUILD.bazel", _NDK_BUILD.format(tc = "toolchains/llvm/prebuilt/" + rctx.attr.host_dir))

android_ndk_repository = repository_rule(
    implementation = _android_ndk_repository_impl,
    doc = "Downloads the Android NDK for one host OS and exposes its clang toolchain as plain files.",
    attrs = {
        "host_dir": attr.string(mandatory = True, doc = "Directory under toolchains/llvm/prebuilt/, e.g. linux-x86_64."),
        "sha256": attr.string(mandatory = True),
        "strip_prefix": attr.string(mandatory = True),
        "url": attr.string(mandatory = True),
    },
)
