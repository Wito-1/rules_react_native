"""Runs React Native codegen over a library's or app's JS/TS specs."""

load("@aspect_rules_js//js:defs.bzl", "js_run_binary")

ReactNativeCodegenInfo = provider(
    doc = "Native sources generated from one library's specs.",
    fields = {
        "library_name": "str: codegen library name; prefixes the generated <name>_ModuleProvider",
        "jni": "File: directory of generated C++ (<name>.h, <name>-generated.cpp, react/renderer/components/<name>/...)",
    },
)

def _tree_entry(f):
    return "%s=%s" % (f.tree_relative_path, f.path)

def _react_native_codegen_info_impl(ctx):
    java_dir, jni_dir = None, None
    for f in ctx.attr.generate[DefaultInfo].files.to_list():
        if f.basename == "java":
            java_dir = f
        elif f.basename == "jni":
            jni_dir = f
    srcjar = ctx.actions.declare_file(ctx.label.name + ".srcjar")
    args = ctx.actions.args()
    args.add("c", srcjar)
    args.add_all([java_dir], map_each = _tree_entry)
    ctx.actions.run(
        executable = ctx.executable._zipper,
        arguments = [args],
        inputs = [java_dir],
        outputs = [srcjar],
        mnemonic = "ReactNativeCodegenSrcjar",
        progress_message = "Packaging generated Java of %{label}",
    )
    return [
        DefaultInfo(files = depset([srcjar])),
        ReactNativeCodegenInfo(library_name = ctx.attr.library_name, jni = jni_dir),
    ]

_react_native_codegen_info = rule(
    implementation = _react_native_codegen_info_impl,
    doc = "Exposes codegen output: the Java specs as a srcjar (default output) and the C++ through ReactNativeCodegenInfo.",
    attrs = {
        "generate": attr.label(mandatory = True),
        "library_name": attr.string(mandatory = True),
        "_zipper": attr.label(default = "@bazel_tools//tools/zip:zipper", executable = True, cfg = "exec"),
    },
)

def react_native_codegen(name, node_modules, library_name, java_package, js_srcs_dir, srcs = [], npm_package = None, **kwargs):
    """Generates TurboModule and Fabric component glue from specs, as `codegenConfig` does in Gradle.

    The default output is a srcjar of the Java spec classes (`Native<Module>Spec`,
    `<Component>ManagerInterface`/`Delegate`), for a `java_library`'s srcs. Pass the target to
    `react_native_android_app(codegen = ...)` as well, which compiles the C++ into
    libappmodules.so and registers it in the generated autolinking.cpp.

    For a library installed from npm, pass `npm_package` instead of `srcs`: the specs are read from
    the installed package, and `js_srcs_dir` is relative to it. Pass the target to
    `react_native_npm_library(codegen = ...)`.

    Args:
        name: Target name.
        node_modules: The package's `npm_link_all_packages` target.
        library_name: `codegenConfig.name`, e.g. "AppSpecs".
        java_package: `codegenConfig.android.javaPackageName`.
        js_srcs_dir: `codegenConfig.jsSrcsDir`, relative to this package (or to `npm_package`).
        srcs: The spec files (`Native*.ts`, `*NativeComponent.ts`) and package.json.
        npm_package: Name of an installed npm package whose specs to generate from, e.g.
            "react-native-safe-area-context".
        **kwargs: Common attributes.
    """
    if bool(srcs) == bool(npm_package):
        fail("react_native_codegen: pass exactly one of `srcs` and `npm_package`")
    pkg = native.package_name()
    prefix = pkg + "/" if pkg else ""
    js_run_binary(
        name = name + "_generate",
        tool = Label("//react_native/js:codegen"),
        srcs = srcs + [node_modules],
        out_dirs = [name + "/java", name + "/jni"],
        args = [
            "--project-root=" + (pkg or "."),
            "--js-srcs-dir=" + js_srcs_dir,
            "--library-name=" + library_name,
            "--java-package=" + java_package,
            "--out-java={}{}/java".format(prefix, name),
            "--out-jni={}{}/jni".format(prefix, name),
        ] + (["--npm-package=" + npm_package] if npm_package else []),
        mnemonic = "ReactNativeCodegen",
        progress_message = "Running React Native codegen for %{label}",
        **kwargs
    )
    _react_native_codegen_info(
        name = name,
        generate = name + "_generate",
        library_name = library_name,
        **kwargs
    )
