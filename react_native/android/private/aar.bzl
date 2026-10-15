"""AndroidLibraryInfo and the import rule for one unpacked Maven artifact (AAR or JAR)."""

load("@rules_java//java/common:java_common.bzl", "java_common")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")

AndroidLibraryInfo = provider(
    doc = "Android-specific parts of a library and everything it depends on.",
    fields = {
        "resources": "depset[struct(package, flata, r_txt, manifest)], dependencies before dependents so later entries win when linked as overlays",
        "native_libs": "depset[struct(abi, file)]",
        "assets": "depset[struct(path, file)]",
        "cc_headers": "depset[File]: prefab headers, for compiling against the library's native code",
        "cc_include_dirs": "depset[str]: include roots of `cc_headers`",
        "compile_jars": "depset[File]: the library's jars plus its API closure, i.e. what a dependent compiles against (Gradle's compileClasspath)",
        "runtime_jars": "depset[File]: every jar the library needs at run time, to be dexed into the app",
        "react_packages": "depset[str]: ReactPackage classes the app's PackageList must instantiate",
        "codegen": "depset[struct(library_name, jni)]: codegen'd C++ to link into libappmodules.so",
    },
)

def collect_android_infos(deps):
    return [d[AndroidLibraryInfo] for d in deps if AndroidLibraryInfo in d]

def merge_android_infos(
        deps = [],
        exports = [],
        resources = [],
        native_libs = [],
        assets = [],
        cc_headers = [],
        cc_include_dirs = [],
        jars = [],
        react_packages = [],
        codegen = []):
    """Builds an AndroidLibraryInfo from a target's own parts and its deps/exports.

    Args:
        deps: Targets this one needs at run time (AndroidLibraryInfo or plain JavaInfo).
        exports: The subset of `deps` that is part of this target's API.
        resources: This target's own resource structs.
        native_libs: This target's own native library structs.
        assets: This target's own asset structs.
        cc_headers: This target's own prefab headers.
        cc_include_dirs: Include roots of `cc_headers`.
        jars: This target's own jars.
        react_packages: This target's own ReactPackage class names.
        codegen: This target's own codegen structs.

    Returns:
        AndroidLibraryInfo.
    """
    infos = collect_android_infos(deps)
    export_infos = collect_android_infos(exports)

    # Plain java_library deps carry only JavaInfo; their full compile classpath is API to us.
    java_only = [d[JavaInfo] for d in deps if AndroidLibraryInfo not in d and JavaInfo in d]
    java_only_exports = [d[JavaInfo] for d in exports if AndroidLibraryInfo not in d and JavaInfo in d]
    return AndroidLibraryInfo(
        resources = depset(resources, transitive = [i.resources for i in infos], order = "postorder"),
        native_libs = depset(native_libs, transitive = [i.native_libs for i in infos]),
        assets = depset(assets, transitive = [i.assets for i in infos]),
        cc_headers = depset(cc_headers, transitive = [i.cc_headers for i in infos]),
        cc_include_dirs = depset(cc_include_dirs, transitive = [i.cc_include_dirs for i in infos]),
        compile_jars = depset(
            jars,
            transitive = [i.compile_jars for i in export_infos] + [j.transitive_compile_time_jars for j in java_only_exports],
        ),
        runtime_jars = depset(
            jars,
            transitive = [i.runtime_jars for i in infos] + [j.transitive_runtime_jars for j in java_only],
        ),
        react_packages = depset(react_packages, transitive = [i.react_packages for i in infos]),
        codegen = depset(codegen, transitive = [i.codegen for i in infos]),
    )

def _dirname(path):
    return path[:path.rfind("/")]

def compile_resources(ctx, aapt2, name, res_dir, res_files):
    """Compiles one res/ directory into a .flata archive.

    Args:
        ctx: Rule context.
        aapt2: The aapt2 executable.
        name: Output basename.
        res_dir: Path of the res/ directory.
        res_files: Its files (action inputs).

    Returns:
        The .flata File.
    """
    flata = ctx.actions.declare_file(name + ".flata")
    args = ctx.actions.args()
    args.add_all(["compile", "--legacy", "--dir", res_dir, "-o", flata])
    ctx.actions.run(
        executable = aapt2,
        arguments = [args],
        inputs = res_files,
        outputs = [flata],
        mnemonic = "Aapt2Compile",
        progress_message = "Compiling Android resources of %{label}",
    )
    return flata

def _android_maven_import_impl(ctx):
    resources = []
    native_libs = []
    assets = []
    include_dirs = {}
    for f in ctx.files.prefab_headers:
        include_dirs[f.path[:f.path.find("/include/") + len("/include")]] = True
    if ctx.file.manifest:
        aar_root = _dirname(ctx.file.manifest.path)
        flata = None
        if ctx.files.res:
            flata = compile_resources(ctx, ctx.file._aapt2, ctx.label.name, aar_root + "/res", ctx.files.res)
        resources.append(struct(
            package = ctx.attr.aar_package,
            flata = flata,
            r_txt = ctx.files.r_txt[0] if ctx.files.r_txt else None,
            manifest = ctx.file.manifest,
        ))
        for f in ctx.files.native_libs:
            native_libs.append(struct(abi = f.dirname.rsplit("/", 1)[1], file = f))
        for f in ctx.files.assets:
            assets.append(struct(path = f.path[len(aar_root) + len("/assets/"):], file = f))

    # JavaInfo is for interop with rules_java targets that depend on an artifact directly.
    java_deps = [d[JavaInfo] for d in ctx.attr.deps if JavaInfo in d]
    java_exports = [d[JavaInfo] for d in ctx.attr.exports if JavaInfo in d]
    java_infos = [
        JavaInfo(output_jar = jar, compile_jar = jar, deps = java_deps, exports = java_exports)
        for jar in ctx.files.jars
    ]
    providers = [
        DefaultInfo(files = depset(ctx.files.jars)),
        merge_android_infos(
            deps = ctx.attr.deps,
            exports = ctx.attr.exports,
            resources = resources,
            native_libs = native_libs,
            assets = assets,
            cc_headers = ctx.files.prefab_headers,
            cc_include_dirs = include_dirs.keys(),
            jars = ctx.files.jars,
        ),
    ]
    if java_infos:
        providers.append(java_common.merge(java_infos))
    elif java_deps:
        # Coordinates like androidx.annotation:annotation only redirect to a platform artifact;
        # forwarding keeps their dependents' classpath what Gradle would give them.
        providers.append(java_common.merge(java_exports or java_deps))
    return providers

android_maven_import = rule(
    implementation = _android_maven_import_impl,
    doc = "One artifact from an `android_maven_repository`; generated by the repository rule, not written by hand.",
    attrs = {
        "aar_package": attr.string(doc = "Java package from the AAR manifest; its R class is generated in that package."),
        "assets": attr.label_list(allow_files = True),
        "coordinate": attr.string(doc = "Maven coordinate, for diagnostics."),
        "deps": attr.label_list(providers = [[JavaInfo], [AndroidLibraryInfo]], doc = "Runtime dependencies."),
        "exports": attr.label_list(providers = [[JavaInfo], [AndroidLibraryInfo]], doc = "The API subset of `deps`."),
        "jars": attr.label_list(allow_files = [".jar"]),
        "manifest": attr.label(allow_single_file = True),
        "native_libs": attr.label_list(allow_files = [".so"]),
        "prefab_headers": attr.label_list(allow_files = True),
        "r_txt": attr.label_list(allow_files = True),
        "res": attr.label_list(allow_files = True),
        "_aapt2": attr.label(
            default = "@rn_android_sdk//:aapt2",
            allow_single_file = True,
            cfg = "exec",
        ),
    },
)
