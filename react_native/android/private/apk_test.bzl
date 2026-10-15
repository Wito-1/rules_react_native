"""Device-free checks on a built APK and its app bundle."""

load("@rules_java//java/common:java_common.bzl", "java_common")

def _rlocation(ctx, short_path):
    if short_path.startswith("../"):
        return short_path[len("../"):]
    return ctx.workspace_name + "/" + short_path

_SCRIPT = """\
#!/usr/bin/env bash
set -euo pipefail
r="${{RUNFILES_DIR:-$TEST_SRCDIR}}"
exec "$r/{tool}" --apk "$r/{apk}" --aapt2 "$r/{aapt2}" --zipalign "$r/{zipalign}" \\
  --java "$r/{java}" --apksigner "$r/{apksigner}" {args}
"""

def _react_native_apk_test_impl(ctx):
    runtime = ctx.attr._jdk[java_common.JavaRuntimeInfo]
    args = ["--package=" + ctx.attr.package]
    args += ["--abi=" + a for a in ctx.attr.abis]
    args += ["--native_lib=" + lib for lib in ctx.attr.native_libs]
    args += ["--asset=" + a for a in ctx.attr.assets]
    args += ["--entry=" + e for e in ctx.attr.entries]
    bundle_files = []
    if ctx.attr.aab:
        aab = [f for f in ctx.attr.apk[OutputGroupInfo].aab.to_list()][0]
        bundle_files = [aab] + ctx.files._bundletool_classpath
        args.append("--aab=$r/" + _rlocation(ctx, aab.short_path))
        args += ["--bundletool_classpath=$r/" + _rlocation(ctx, f.short_path) for f in ctx.files._bundletool_classpath]
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(script, _SCRIPT.format(
        tool = _rlocation(ctx, ctx.executable._apk_check.short_path),
        apk = _rlocation(ctx, ctx.file.apk.short_path),
        aapt2 = _rlocation(ctx, ctx.file._aapt2.short_path),
        zipalign = _rlocation(ctx, ctx.file._zipalign.short_path),
        java = _rlocation(ctx, runtime.java_executable_runfiles_path),
        apksigner = _rlocation(ctx, ctx.file._apksigner.short_path),
        args = " ".join(['"%s"' % a for a in args]),
    ), is_executable = True)
    runfiles = ctx.runfiles(
        files = [ctx.file.apk, ctx.file._aapt2, ctx.file._zipalign, ctx.file._apksigner] + ctx.files._zipalign_libs + bundle_files,
        transitive_files = runtime.files,
    ).merge(ctx.attr._apk_check[DefaultInfo].default_runfiles)
    return [DefaultInfo(executable = script, runfiles = runfiles)]

react_native_apk_test = rule(
    implementation = _react_native_apk_test_impl,
    test = True,
    doc = """Checks a built APK without a device: manifest package, 16 KiB alignment, signature, and
that every ABI ships the expected native libraries uncompressed, plus the expected assets. With
`aab = True`, also validates the app's bundle with bundletool and checks it carries the same
libraries and assets plus native debug symbols.""",
    attrs = {
        "aab": attr.bool(doc = "Also check the app bundle (`apk` must be a `react_native_android_app`)."),
        "abis": attr.string_list(default = ["arm64-v8a", "x86_64"], doc = "Exactly the ABIs the APK must ship."),
        "apk": attr.label(allow_single_file = [".apk"], mandatory = True),
        "assets": attr.string_list(doc = "Paths under assets/ that must exist, e.g. index.android.bundle."),
        "entries": attr.string_list(doc = "Any other paths that must exist in the APK, e.g. res/drawable-xhdpi-v4/images_logo.png."),
        "native_libs": attr.string_list(
            default = ["libreactnative.so", "libappmodules.so", "libhermesvm.so", "libc++_shared.so"],
            doc = "Libraries every ABI must ship.",
        ),
        "package": attr.string(mandatory = True, doc = "Expected application id."),
        "_aapt2": attr.label(default = "@rn_android_sdk//:aapt2", allow_single_file = True),
        "_apk_check": attr.label(default = "//react_native/android/tools:apk_check", executable = True, cfg = "target"),
        "_apksigner": attr.label(default = "@rn_android_sdk//:apksigner_jar", allow_single_file = True),
        "_bundletool_classpath": attr.label(default = "@rn_bundletool_maven//:all"),
        "_jdk": attr.label(default = "@rules_java//toolchains:remotejdk_21", providers = [java_common.JavaRuntimeInfo]),
        "_zipalign": attr.label(default = "@rn_android_sdk//:zipalign", allow_single_file = True),
        "_zipalign_libs": attr.label(default = "@rn_android_sdk//:zipalign_libs"),
    },
)
