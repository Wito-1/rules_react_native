"""Java and Kotlin compilation for React Native Android code, with a pinned JDK rather than rules_java's toolchain."""

load("@rules_java//java/common:java_common.bzl", "java_common")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load(":aar.bzl", "AndroidLibraryInfo", "collect_android_infos", "merge_android_infos")

# React Native's own template compiles with Java 17 (compileOptions in the app's build.gradle).
DEFAULT_JAVACOPTS = ["-source", "17", "-target", "17"]

JAVA_ATTRS = {
    "javacopts": attr.string_list(doc = "Extra javac flags, after the defaults (`-source 17 -target 17`)."),
    "kotlincopts": attr.string_list(doc = "Extra kotlinc flags, after the defaults (`-jvm-target 17`)."),
    "_android_jar": attr.label(default = "@rn_android_sdk//:android_jar_file", allow_single_file = True),
    "_javac": attr.label(default = "//react_native/android/tools:javac", executable = True, cfg = "exec"),
    "_jdk": attr.label(
        default = "@rules_java//toolchains:remotejdk_21",
        cfg = "exec",
        providers = [java_common.JavaRuntimeInfo],
    ),
    "_kotlin_compiler": attr.label(default = "@rn_kotlin_compiler_maven//:all", cfg = "exec"),
}

JAVA_SRC_EXTENSIONS = [".java", ".kt", ".srcjar"]

def run_java_tool(ctx, main_class, classpath, arguments, inputs, jvm_flags = [], **kwargs):
    """Runs a Java tool's main class on the pinned JDK 21.

    The SDK's d8/apksigner and AGP's manifest merger need class file version 61+, newer than the
    exec JVM many repos default to, so they never go through java_binary launchers.

    Args:
        ctx: Rule context with JAVA_ATTRS.
        main_class: Fully-qualified main class.
        classpath: list of jars.
        arguments: list of Args for the tool.
        inputs: Extra action inputs.
        jvm_flags: Flags for the JVM itself.
        **kwargs: Passed to ctx.actions.run (outputs, mnemonic, progress_message, ...).
    """
    runtime = ctx.attr._jdk[java_common.JavaRuntimeInfo]
    jvm_args = ctx.actions.args()
    jvm_args.add_all(jvm_flags)
    jvm_args.add_joined("-cp", classpath, join_with = ctx.configuration.host_path_separator)
    jvm_args.add(main_class)
    ctx.actions.run(
        executable = runtime.java_executable_exec_path,
        arguments = [jvm_args] + arguments,
        inputs = depset(classpath + inputs),
        tools = runtime.files,
        **kwargs
    )

def compile_classpath(deps):
    """The API classpath of `deps`, as Gradle's compileClasspath would be.

    Args:
        deps: AndroidLibraryInfo and/or JavaInfo targets.

    Returns:
        depset of jars.
    """
    return depset(transitive = [i.compile_jars for i in collect_android_infos(deps)] + [
        d[JavaInfo].transitive_compile_time_jars
        for d in deps
        if AndroidLibraryInfo not in d and JavaInfo in d
    ])

def _kotlin_module_name(label):
    # Unique per target: every module's META-INF/<name>.kotlin_module lands in the same app.
    return "".join([c if c.isalnum() else "_" for c in (label.package + "_" + label.name).elems()]).strip("_")

def compile_java(ctx, out, srcs = [], srcjars = [], srcdirs = [], srcdir_inputs = [], classpath = depset(), exclude_r = [], kotlin = None):
    """Runs javac.py; returns nothing, `out` is the jar.

    Args:
        ctx: Rule context with JAVA_ATTRS.
        out: Output jar.
        srcs: .java and .kt Files.
        srcjars: .srcjar Files.
        srcdirs: Directories of .java/.kt files: tree artifacts, or paths (strings) inside one of
            `srcdir_inputs`.
        srcdir_inputs: Tree artifacts the string `srcdirs` point into.
        classpath: depset of jars.
        exclude_r: Packages whose R classes are dropped from `out`.
        kotlin: Whether to set up kotlinc; by default, when `srcs` has .kt files. Directories can't
            be inspected at analysis time, so callers with `srcdirs` say so.
    """
    if kotlin == None:
        kotlin = any([f.extension == "kt" for f in srcs])
    runtime = ctx.attr._jdk[java_common.JavaRuntimeInfo]
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    args.add("--javac", runtime.java_home + "/bin/javac")
    args.add_all(srcs, before_each = "--src")
    args.add_all(srcjars, before_each = "--srcjar")
    args.add_all(srcdirs, before_each = "--srcdir", expand_directories = False)
    kotlin_jars = []
    if kotlin:
        kotlin_jars = ctx.files._kotlin_compiler
        args.add("--java", runtime.java_executable_exec_path)
        args.add_all(kotlin_jars, before_each = "--kotlinc_classpath")
        args.add("--module_name", _kotlin_module_name(ctx.label))
        args.add_all(ctx.attr.kotlincopts, format_each = "--kotlincopt=%s")
    args.add("--classpath", ctx.file._android_jar)
    args.add_all(classpath, before_each = "--classpath")
    # `=` form: javac flags start with "-", which argparse would take for an option.
    args.add_all(DEFAULT_JAVACOPTS + ctx.attr.javacopts, format_each = "--javacopt=%s")
    args.add_all(exclude_r, before_each = "--exclude_r")
    args.add("--out", out)
    ctx.actions.run(
        executable = ctx.executable._javac,
        arguments = [args],
        inputs = depset(
            srcs + srcjars + [d for d in srcdirs if type(d) != "string"] + srcdir_inputs + kotlin_jars + [ctx.file._android_jar],
            transitive = [classpath],
        ),
        tools = runtime.files,
        outputs = [out],
        mnemonic = "ReactNativeKotlinc" if kotlin else "ReactNativeJavac",
        progress_message = "Compiling %s of %%{label}" % ("Kotlin/Java" if kotlin else "Java"),
    )

def _react_native_java_library_impl(ctx):
    jar = ctx.actions.declare_file("lib%s.jar" % ctx.label.name)
    compile_java(
        ctx,
        jar,
        srcs = [f for f in ctx.files.srcs if f.extension in ("java", "kt")],
        srcjars = [f for f in ctx.files.srcs if f.extension == "srcjar"],
        classpath = depset(transitive = [compile_classpath(ctx.attr.deps), compile_classpath(ctx.attr.exports)]),
    )
    return [
        DefaultInfo(files = depset([jar])),
        merge_android_infos(
            deps = ctx.attr.deps + ctx.attr.exports,
            exports = ctx.attr.exports,
            jars = [jar],
        ),
        JavaInfo(
            output_jar = jar,
            compile_jar = jar,
            deps = [d[JavaInfo] for d in ctx.attr.deps if JavaInfo in d],
            exports = [d[JavaInfo] for d in ctx.attr.exports if JavaInfo in d],
        ),
    ]

react_native_java_library = rule(
    implementation = _react_native_java_library_impl,
    doc = """Java and Kotlin code for a React Native Android app, compiled against android.jar with a pinned JDK 21.

Unlike rules_java's java_library, it needs no `--java_runtime_version` in the consumer's .bazelrc,
and its compile classpath is its deps' API closure (Gradle's `implementation` semantics).""",
    attrs = dict(JAVA_ATTRS, **{
        "deps": attr.label_list(providers = [[AndroidLibraryInfo], [JavaInfo]]),
        "exports": attr.label_list(providers = [[AndroidLibraryInfo], [JavaInfo]], doc = "Deps that are part of this library's API (Gradle's `api`)."),
        "srcs": attr.label_list(allow_files = JAVA_SRC_EXTENSIONS),
    }),
)
