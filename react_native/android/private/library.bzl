"""First-party Android library code for a React Native app: Java, resources, manifest, assets."""

load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//react_native/js/private:codegen.bzl", "ReactNativeCodegenInfo")
load(":aar.bzl", "AndroidLibraryInfo", "collect_android_infos", "compile_resources", "merge_android_infos")
load(":java.bzl", "JAVA_ATTRS", "compile_classpath", "compile_java", "run_java_tool")

_EMPTY_MANIFEST = """\
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="{package}" />
"""

def _dir_containing(files, marker):
    roots = {}
    for f in files:
        idx = f.path.find("/%s/" % marker)
        if idx < 0:
            fail("%s is not under a %s/ directory" % (f.path, marker))
        roots[f.path[:idx + len(marker) + 1]] = True
    if len(roots) != 1:
        fail("all `%s` files must share one %s/ directory, got %s" % (marker, marker, sorted(roots)))
    return roots.keys()[0]

def _library_manifest(ctx):
    out = ctx.actions.declare_file(ctx.label.name + "/AndroidManifest.xml")
    if not ctx.file.manifest:
        ctx.actions.write(out, _EMPTY_MANIFEST.format(package = ctx.attr.package))
        return out

    # Library manifests usually omit `package` (AGP's `namespace`); the app's merger needs it.
    args = ctx.actions.args()
    args.add("--main", ctx.file.manifest)
    args.add("--property", "PACKAGE=" + ctx.attr.package)
    args.add("--out", out)
    run_java_tool(
        ctx,
        main_class = "com.android.manifmerger.Merger",
        classpath = ctx.files._manifest_merger_classpath,
        arguments = [args],
        inputs = [ctx.file.manifest],
        outputs = [out],
        mnemonic = "AndroidLibraryManifest",
        progress_message = "Normalizing the manifest of %{label}",
    )
    return out

def _react_native_android_library_impl(ctx):
    # React Native itself is compile-only, as `compileOnly`/`implementation` of react-android is in
    # a Gradle library: the app decides which variant (release or debug) ships.
    compile_only = [ctx.attr._react_native] if ctx.attr.react_native else []
    dep_infos = collect_android_infos(ctx.attr.deps + ctx.attr.exports + compile_only)
    manifest = _library_manifest(ctx)

    flata = None
    r_txt = None
    r_srcs = None
    if ctx.files.res:
        flata = compile_resources(ctx, ctx.file._aapt2, ctx.label.name + "/res", _dir_containing(ctx.files.res, "res"), ctx.files.res)
        dep_resources = depset(transitive = [i.resources for i in dep_infos], order = "postorder").to_list()
        dep_flatas = [r.flata for r in dep_resources if r.flata]

        # A static-lib link checks references against the deps' resources and assigns placeholder
        # ids; the library compiles against those through non-final fields, and the app's link
        # assigns the real ones.
        linked_r_txt = ctx.actions.declare_file(ctx.label.name + "/linked_R.txt")
        static_apk = ctx.actions.declare_file(ctx.label.name + "/static.apk")
        r_srcs = ctx.actions.declare_directory(ctx.label.name + "/r_java")
        args = ctx.actions.args()
        args.add("link")
        args.add("--static-lib")
        args.add("-o", static_apk)
        args.add("-I", ctx.file._android_jar)
        args.add("--manifest", manifest)
        args.add("--auto-add-overlay")
        args.add("--non-final-ids")
        args.add("--java", r_srcs.path)
        args.add("--output-text-symbols", linked_r_txt)
        args.add_all(dep_flatas, before_each = "-R")
        args.add("-R", flata)
        ctx.actions.run(
            executable = ctx.file._aapt2,
            arguments = [args],
            inputs = [manifest, ctx.file._android_jar, flata] + dep_flatas,
            outputs = [r_srcs, linked_r_txt, static_apk],
            mnemonic = "Aapt2LinkLibrary",
            progress_message = "Linking Android resources of %{label}",
        )
        r_txt = ctx.actions.declare_file(ctx.label.name + "/R.txt")
        own_args = ctx.actions.args()
        own_args.add("--linked", linked_r_txt)
        dep_r_txts = [r.r_txt for r in dep_resources if r.r_txt]
        own_args.add_all(dep_r_txts, before_each = "--dep")
        own_args.add("--out", r_txt)
        ctx.actions.run(
            executable = ctx.executable._own_r_txt,
            arguments = [own_args],
            inputs = [linked_r_txt] + dep_r_txts,
            outputs = [r_txt],
            mnemonic = "AndroidLibraryRTxt",
            progress_message = "Listing the resources of %{label}",
        )

    jar = ctx.actions.declare_file("lib%s.jar" % ctx.label.name)
    codegen_srcjars = [c[DefaultInfo].files.to_list()[0] for c in ctx.attr.codegen]
    compile_java(
        ctx,
        jar,
        srcs = [f for f in ctx.files.srcs if f.extension == "java"],
        srcjars = [f for f in ctx.files.srcs if f.extension == "srcjar"] + codegen_srcjars,
        srcdirs = [r_srcs] if r_srcs else [],
        classpath = compile_classpath(ctx.attr.deps + ctx.attr.exports + compile_only),
        exclude_r = [ctx.attr.package],
    )

    assets = []
    if ctx.files.assets:
        root = _dir_containing(ctx.files.assets, "assets")
        assets = [struct(path = f.path[len(root) + 1:], file = f) for f in ctx.files.assets]

    return [
        DefaultInfo(files = depset([jar])),
        merge_android_infos(
            deps = ctx.attr.deps + ctx.attr.exports,
            exports = ctx.attr.exports,
            resources = [struct(package = ctx.attr.package, flata = flata, r_txt = r_txt, manifest = manifest)],
            assets = assets,
            jars = [jar],
            react_packages = ctx.attr.react_packages,
            codegen = [
                struct(library_name = c[ReactNativeCodegenInfo].library_name, jni = c[ReactNativeCodegenInfo].jni)
                for c in ctx.attr.codegen
            ],
        ),
        JavaInfo(
            output_jar = jar,
            compile_jar = jar,
            deps = [d[JavaInfo] for d in ctx.attr.deps if JavaInfo in d],
            exports = [d[JavaInfo] for d in ctx.attr.exports if JavaInfo in d],
        ),
        OutputGroupInfo(r_txt = depset([r_txt] if r_txt else [])),
    ]

react_native_android_library = rule(
    implementation = _react_native_android_library_impl,
    doc = """A library of a React Native Android app: Java sources, resources, manifest entries,
assets, codegen'd specs and the ReactPackages it contributes.

Everything flows to the app through `deps`: resources are linked with the app's (the library's R
class is regenerated with final ids in its own `package`), its manifest is merged, its assets are
packaged, its codegen C++ is compiled into libappmodules.so and registered in autolinking.cpp, and
its `react_packages` are added to PackageList.""",
    attrs = dict(JAVA_ATTRS, **{
        "assets": attr.label_list(allow_files = True, doc = "Files under one assets/ directory; packaged at the same relative paths."),
        "codegen": attr.label_list(providers = [ReactNativeCodegenInfo], doc = "`react_native_codegen` targets for this library's specs."),
        "deps": attr.label_list(providers = [[AndroidLibraryInfo], [JavaInfo]]),
        "exports": attr.label_list(providers = [[AndroidLibraryInfo], [JavaInfo]], doc = "Deps that are part of this library's API (Gradle's `api`)."),
        "manifest": attr.label(allow_single_file = [".xml"], doc = "Optional; components, permissions and meta-data to merge into the app's manifest."),
        "package": attr.string(mandatory = True, doc = "Java package of the library's R class (AGP's `namespace`)."),
        "react_native": attr.bool(
            default = True,
            doc = "Compile and link resources against the consumer's release React Native set. It stays compile-only; the app supplies the runtime variant.",
        ),
        "react_packages": attr.string_list(doc = "Fully-qualified ReactPackage classes the app's PackageList must instantiate."),
        "res": attr.label_list(allow_files = True, doc = "Files under one res/ directory."),
        "srcs": attr.label_list(allow_files = [".java", ".srcjar"]),
        "_aapt2": attr.label(default = "@rn_android_sdk//:aapt2", allow_single_file = True, cfg = "exec"),
        "_manifest_merger_classpath": attr.label(default = "@rn_android_tools_maven//:all", cfg = "exec"),
        "_react_native": attr.label(default = "@rn_maven_default//:all"),
        "_own_r_txt": attr.label(default = "//react_native/android/tools:own_r_txt", executable = True, cfg = "exec"),
    }),
)
