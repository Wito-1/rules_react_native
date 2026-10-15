"""Android library code for a React Native app: first-party sources, or an npm package's android/ tree."""

load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//react_native/js/private:codegen.bzl", "ReactNativeCodegenInfo")
load(":aar.bzl", "AndroidLibraryInfo", "appmodules_unit", "collect_android_infos", "compile_resources", "merge_android_infos")
load(":java.bzl", "JAVA_ATTRS", "JAVA_SRC_EXTENSIONS", "compile_classpath", "compile_java", "run_java_tool")

_EMPTY_MANIFEST = """\
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="{package}" />
"""

# AGP's library BuildConfig. A library is built once for every app variant, so DEBUG is false, as
# in a release AAR; the new-architecture flags many libraries add with buildConfigField are always
# true under this ruleset.
_LIBRARY_BUILD_CONFIG = """\
package {package};

public final class BuildConfig {{
  public static final boolean DEBUG = false;
  public static final String LIBRARY_PACKAGE_NAME = "{package}";
  public static final String BUILD_TYPE = "release";
  public static final boolean IS_NEW_ARCHITECTURE_ENABLED = true;
  public static final boolean IS_HERMES_ENABLED = true;
{fields}}}
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

def _library_manifest(ctx, manifest_path, inputs):
    out = ctx.actions.declare_file(ctx.label.name + "/AndroidManifest.xml")
    if not manifest_path:
        ctx.actions.write(out, _EMPTY_MANIFEST.format(package = ctx.attr.package))
        return out

    # Library manifests usually omit `package` (AGP's `namespace`); the app's merger needs it.
    args = ctx.actions.args()
    args.add("--main", manifest_path)
    args.add("--property", "PACKAGE=" + ctx.attr.package)
    args.add("--out", out)
    run_java_tool(
        ctx,
        main_class = "com.android.manifmerger.Merger",
        classpath = ctx.files._manifest_merger_classpath,
        arguments = [args],
        inputs = inputs,
        outputs = [out],
        mnemonic = "AndroidLibraryManifest",
        progress_message = "Normalizing the manifest of %{label}",
    )
    return out

def _build_library(ctx, manifest, flata, srcs, srcjars, srcdirs, srcdir_inputs, kotlin, assets, appmodules, proguard_specs):
    """Everything after manifest and resource compilation, shared by both rules."""
    compile_only = [ctx.attr._react_native] if ctx.attr.react_native else []
    dep_infos = collect_android_infos(ctx.attr.deps + ctx.attr.exports + compile_only)

    r_txt = None
    r_srcs = None
    if flata:
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

    if ctx.attr.build_config or ctx.attr.build_config_fields:
        build_config = ctx.actions.declare_file("%s/build_config/%s/BuildConfig.java" % (ctx.label.name, ctx.attr.package.replace(".", "/")))
        ctx.actions.write(build_config, _LIBRARY_BUILD_CONFIG.format(
            package = ctx.attr.package,
            fields = "".join([
                "  public static final String %s = %s;\n" % (k, json.encode(v))
                for k, v in sorted(ctx.attr.build_config_fields.items())
            ]),
        ))
        srcs = srcs + [build_config]

    jar = ctx.actions.declare_file("lib%s.jar" % ctx.label.name)
    codegen_srcjars = [c[DefaultInfo].files.to_list()[0] for c in ctx.attr.codegen]
    compile_java(
        ctx,
        jar,
        srcs = srcs,
        srcjars = srcjars + codegen_srcjars,
        srcdirs = srcdirs + ([r_srcs] if r_srcs else []),
        srcdir_inputs = srcdir_inputs,
        classpath = compile_classpath(ctx.attr.deps + ctx.attr.exports + compile_only),
        exclude_r = [ctx.attr.package],
        kotlin = kotlin,
    )

    return [
        DefaultInfo(files = depset([jar])),
        merge_android_infos(
            deps = ctx.attr.deps + ctx.attr.exports,
            exports = ctx.attr.exports,
            resources = [struct(package = ctx.attr.package, flata = flata, r_txt = r_txt, manifest = manifest)],
            assets = assets,
            jars = [jar],
            react_packages = ctx.attr.react_packages,
            appmodules = appmodules,
            proguard_specs = proguard_specs,
        ),
        JavaInfo(
            output_jar = jar,
            compile_jar = jar,
            deps = [d[JavaInfo] for d in ctx.attr.deps if JavaInfo in d],
            exports = [d[JavaInfo] for d in ctx.attr.exports if JavaInfo in d],
        ),
        OutputGroupInfo(r_txt = depset([r_txt] if r_txt else [])),
    ]

def _codegen_units(ctx, own_components):
    # With hand-listed descriptors, the library's codegen'd ones are registered from that list.
    return [
        appmodules_unit(
            key = c[ReactNativeCodegenInfo].library_name,
            codegen = c[ReactNativeCodegenInfo],
            register_codegen_components = not own_components,
        )
        for c in ctx.attr.codegen
    ]

def _package_path(ctx, rel):
    return "/".join([p for p in [ctx.label.workspace_root, ctx.label.package, rel] if p])

def _react_native_android_library_impl(ctx):
    manifest = _library_manifest(
        ctx,
        ctx.file.manifest.path if ctx.file.manifest else None,
        [ctx.file.manifest] if ctx.file.manifest else [],
    )
    flata = None
    if ctx.files.res:
        flata = compile_resources(ctx, ctx.file._aapt2, ctx.label.name + "/res", _dir_containing(ctx.files.res, "res"), ctx.files.res)

    assets = []
    if ctx.files.assets:
        root = _dir_containing(ctx.files.assets, "assets")
        assets = [struct(path = f.path[len(root) + 1:], file = f) for f in ctx.files.assets]

    appmodules = _codegen_units(ctx, ctx.attr.component_descriptors)
    if ctx.files.cc_srcs or ctx.attr.cxx_modules or ctx.attr.component_descriptors:
        hdrs = [f for f in ctx.files.cc_srcs if f.extension in ("h", "hpp")]
        appmodules.append(appmodules_unit(
            key = str(ctx.label),
            srcs = [f for f in ctx.files.cc_srcs if f.extension in ("c", "cc", "cpp")],
            hdrs = hdrs,
            includes = [_package_path(ctx, i) for i in ctx.attr.cc_includes] + {f.dirname: True for f in hdrs}.keys(),
            component_descriptors = ctx.attr.component_descriptors,
            cxx_modules = ctx.attr.cxx_modules,
        ))

    return _build_library(
        ctx,
        manifest = manifest,
        flata = flata,
        srcs = [f for f in ctx.files.srcs if f.extension in ("java", "kt")],
        srcjars = [f for f in ctx.files.srcs if f.extension == "srcjar"],
        srcdirs = [],
        srcdir_inputs = [],
        kotlin = None,
        assets = assets,
        appmodules = appmodules,
        proguard_specs = [struct(file = f, path = f.path) for f in ctx.files.proguard_specs],
    )

_COMMON_ATTRS = dict(JAVA_ATTRS, **{
    "build_config": attr.bool(
        doc = "Generate `<package>.BuildConfig` (AGP's `buildFeatures.buildConfig`): `DEBUG` (false), " +
              "`LIBRARY_PACKAGE_NAME`, `BUILD_TYPE`, `IS_NEW_ARCHITECTURE_ENABLED` and `IS_HERMES_ENABLED` (true).",
    ),
    "build_config_fields": attr.string_dict(doc = "Extra `public static final String` BuildConfig fields; implies `build_config`."),
    "codegen": attr.label_list(providers = [ReactNativeCodegenInfo], doc = "`react_native_codegen` targets for this library's specs."),
    "component_descriptors": attr.string_list(
        doc = "C++ ComponentDescriptor classes to register (react-native.config.js `componentDescriptors`). " +
              "When set, they replace registering the `codegen` targets' generated descriptors.",
    ),
    "deps": attr.label_list(providers = [[AndroidLibraryInfo], [JavaInfo]]),
    "exports": attr.label_list(providers = [[AndroidLibraryInfo], [JavaInfo]], doc = "Deps that are part of this library's API (Gradle's `api`)."),
    "package": attr.string(mandatory = True, doc = "Java package of the library's R class (AGP's `namespace`)."),
    "react_native": attr.bool(
        default = True,
        doc = "Compile and link resources against the consumer's release React Native set. It stays compile-only; the app supplies the runtime variant.",
    ),
    "react_packages": attr.string_list(doc = "Fully-qualified ReactPackage classes the app's PackageList must instantiate."),
    "_aapt2": attr.label(default = "@rn_android_sdk//:aapt2", allow_single_file = True, cfg = "exec"),
    "_manifest_merger_classpath": attr.label(default = "@rn_android_tools_maven//:all", cfg = "exec"),
    "_react_native": attr.label(default = "@rn_maven_default//:all"),
    "_own_r_txt": attr.label(default = "//react_native/android/tools:own_r_txt", executable = True, cfg = "exec"),
})

react_native_android_library = rule(
    implementation = _react_native_android_library_impl,
    doc = """A library of a React Native Android app: Java sources, resources, manifest entries,
assets, codegen'd specs and the ReactPackages it contributes.

Everything flows to the app through `deps`: resources are linked with the app's (the library's R
class is regenerated with final ids in its own `package`), its manifest is merged, its assets are
packaged, its codegen C++ is compiled into libappmodules.so and registered in autolinking.cpp, and
its `react_packages` are added to PackageList.""",
    attrs = dict(_COMMON_ATTRS, **{
        "assets": attr.label_list(allow_files = True, doc = "Files under one assets/ directory; packaged at the same relative paths."),
        "cc_includes": attr.string_list(doc = "Include roots for `cc_srcs`, relative to this package. Header directories are always included."),
        "cc_srcs": attr.label_list(
            allow_files = [".c", ".cc", ".cpp", ".h", ".hpp"],
            doc = "C++ compiled into the app's libappmodules.so: custom shadow nodes, pure C++ TurboModules.",
        ),
        "cxx_modules": attr.string_dict(
            doc = "Pure C++ TurboModules, `{class: header}`, e.g. `{\"facebook::react::NativeSampleModule\": \"NativeSampleModule.h\"}`. " +
                  "Registered in autolinking.cpp's cxxModuleProvider by `class::kModuleName` (from the codegen'd `<Name>CxxSpec`).",
        ),
        "manifest": attr.label(allow_single_file = [".xml"], doc = "Optional; components, permissions and meta-data to merge into the app's manifest."),
        "proguard_specs": attr.label_list(allow_files = True, doc = "R8/ProGuard rules apps that minify must apply (AGP's `consumerProguardFiles`)."),
        "res": attr.label_list(allow_files = True, doc = "Files under one res/ directory."),
        "srcs": attr.label_list(allow_files = JAVA_SRC_EXTENSIONS, doc = "Java and Kotlin sources, and srcjars."),
    }),
)

def _npm_package_dir(target, name):
    # npm_link_package's files are the package's whole closure; the package itself is the one
    # store directory named after it.
    suffix = "/node_modules/" + name
    for f in target[DefaultInfo].files.to_list():
        if f.is_directory and f.path.endswith(suffix) and "/.aspect_rules_js/" in f.path:
            return f
    fail("%s does not provide the %s package directory; pass the package's npm_link_all_packages target, e.g. \":node_modules/%s\"" % (target.label, name, name))

def _react_native_npm_library_impl(ctx):
    name = ctx.attr.npm_package.label.name
    if not name.startswith("node_modules/"):
        fail("npm_package must be an npm_link_all_packages target like \":node_modules/<package>\", got %s" % ctx.attr.npm_package.label)
    pkg = _npm_package_dir(ctx.attr.npm_package, name[len("node_modules/"):])

    def path(rel):
        return pkg.path + "/" + rel

    manifest = _library_manifest(ctx, path(ctx.attr.manifest) if ctx.attr.manifest else None, [pkg])
    flata = None
    if ctx.attr.res_dir:
        flata = compile_resources(ctx, ctx.file._aapt2, ctx.label.name + "/res", path(ctx.attr.res_dir), [pkg])

    appmodules = _codegen_units(ctx, ctx.attr.component_descriptors)
    if ctx.attr.cc_dirs or ctx.attr.component_descriptors:
        appmodules.append(appmodules_unit(
            key = str(ctx.label),
            trees = [pkg],
            tree_src_dirs = [path(d) for d in ctx.attr.cc_dirs],
            includes = [path(d) for d in ctx.attr.cc_includes],
            component_descriptors = ctx.attr.component_descriptors,
        ))

    return _build_library(
        ctx,
        manifest = manifest,
        flata = flata,
        srcs = [],
        srcjars = [],
        srcdirs = [path(d) for d in ctx.attr.java_dirs],
        srcdir_inputs = [pkg],
        # The sources are only known at execution time.
        kotlin = True,
        assets = [],
        appmodules = appmodules,
        proguard_specs = [struct(file = pkg, path = path(p)) for p in ctx.attr.proguard_specs],
    )

react_native_npm_library = rule(
    implementation = _react_native_npm_library_impl,
    doc = """The Android side of a React Native library installed from npm, built from its sources in
node_modules: what the library's android/build.gradle and react-native.config.js tell Gradle.

Java and Kotlin under `java_dirs` are compiled together; C++ under `cc_dirs` (custom shadow nodes,
the library's own `<lib>.h`) and its `codegen` are compiled into the app's libappmodules.so and
registered in autolinking.cpp. Directory attributes are paths inside the package.""",
    attrs = dict(_COMMON_ATTRS, **{
        "cc_dirs": attr.string_list(doc = "Directories whose .c/.cc/.cpp files are compiled (CMakeLists.txt's sources), e.g. `[\"android/src/main/jni\", \"common/cpp/react/renderer/components/foo\"]`."),
        "cc_includes": attr.string_list(doc = "Include roots (CMakeLists.txt's target_include_directories); searched before codegen output."),
        "java_dirs": attr.string_list(
            default = ["android/src/main/java"],
            doc = "Source roots of .java/.kt files: Gradle's `sourceSets.main` for the new architecture.",
        ),
        "manifest": attr.string(default = "android/src/main/AndroidManifest.xml", doc = "Library manifest; empty for none."),
        "proguard_specs": attr.string_list(doc = "R8/ProGuard rules files in the package that apps must apply (`consumerProguardFiles`), e.g. `[\"android/proguard-rules.pro\"]`."),
        "npm_package": attr.label(mandatory = True, doc = "The package's link target from `npm_link_all_packages`, e.g. `:node_modules/react-native-safe-area-context`."),
        "res_dir": attr.string(doc = "res/ directory, if the library has resources, e.g. `android/src/main/res`."),
    }),
)
