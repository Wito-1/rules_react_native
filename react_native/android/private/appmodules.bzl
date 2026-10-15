"""Compiles the app's libappmodules.so, which registers React Native's TurboModule providers."""

load("//react_native/js/private:codegen.bzl", "ReactNativeCodegenInfo")
load(":aar.bzl", "AndroidLibraryInfo", "collect_android_infos")

_ABI_TARGETS = {
    "arm64-v8a": "aarch64-linux-android",
    "armeabi-v7a": "armv7a-linux-androideabi",
    "x86": "i686-linux-android",
    "x86_64": "x86_64-linux-android",
}

# react-native's folly-flags.cmake and react-native-flags.cmake, which ReactNative-application.cmake
# applies to the app library.
_COPTS = [
    "-std=c++20",
    "-fexceptions",
    "-frtti",
    "-fPIC",
    "-O2",
    "-Wall",
    "-DFOLLY_NO_CONFIG=1",
    "-DFOLLY_HAVE_CLOCK_GETTIME=1",
    "-DFOLLY_USE_LIBCPP=1",
    "-DFOLLY_CFG_NO_COROUTINES=1",
    "-DFOLLY_MOBILE=1",
    "-DFOLLY_HAVE_RECVMMSG=1",
    "-DFOLLY_HAVE_PTHREAD=1",
    "-DFOLLY_HAVE_XSI_STRERROR_R=1",
    "-DLOG_TAG=\"ReactNative\"",
    "-DRN_SERIALIZABLE_STATE",
]

# The react-android release AAR is built with NDEBUG, which compiles out the
# RN_DEBUG_STRING_CONVERTIBLE virtuals (getDebugProps, ...); the debug AAR keeps them. Codegen'd
# Fabric components must agree with the libreactnative.so they link against on that vtable layout,
# or they reference symbols it doesn't export.
_RELEASE_COPTS = ["-DNDEBUG"]

# DT_NEEDED of the stock libappmodules.so. libc++_shared comes from the AARs rather than the NDK
# so the app links the exact copy it ships.
_LINK_LIBS = ["libreactnative.so", "libjsi.so", "libfbjni.so", "libc++_shared.so"]

# What @react-native/gradle-plugin's GenerateAutolinkingNewArchitecturesFileTask emits, with one
# entry per codegen library. The plugin lists component descriptors one by one from each library's
# react-native.config.js; calling the codegen'd <lib>_registerComponentDescriptorsFromCodegen
# registers the same set.
_AUTOLINKING_CPP = """\
#include "autolinking.h"
{includes}

namespace facebook {{
namespace react {{

std::shared_ptr<TurboModule> autolinking_ModuleProvider(const std::string moduleName, const JavaTurboModule::InitParams &params) {{
{module_providers}
  return nullptr;
}}

std::shared_ptr<TurboModule> autolinking_cxxModuleProvider(const std::string moduleName, const std::shared_ptr<CallInvoker>& jsInvoker) {{
  return nullptr;
}}

void autolinking_registerProviders(std::shared_ptr<ComponentDescriptorProviderRegistry const> providerRegistry) {{
{component_registrations}
}}

}} // namespace react
}} // namespace facebook
"""

def _autolinking_cpp(ctx, libraries):
    out = ctx.actions.declare_file(ctx.label.name + "/autolinking.cpp")
    ctx.actions.write(out, _AUTOLINKING_CPP.format(
        includes = "\n".join([
            "#include <{0}.h>\n#include <react/renderer/components/{0}/ComponentDescriptors.h>".format(lib)
            for lib in libraries
        ]),
        module_providers = "\n".join([
            "  if (auto module = {0}_ModuleProvider(moduleName, params)) {{\n    return module;\n  }}".format(lib)
            for lib in libraries
        ]),
        component_registrations = "\n".join([
            "  {}_registerComponentDescriptorsFromCodegen(providerRegistry);".format(lib)
            for lib in libraries
        ]),
    ))
    return out

def _cpp_sources(f):
    return f.path if f.extension == "cpp" else None

def _react_native_appmodules_impl(ctx):
    infos = collect_android_infos(ctx.attr.deps)
    native_libs = depset(transitive = [i.native_libs for i in infos]).to_list()
    headers = depset(transitive = [i.cc_headers for i in infos])
    include_dirs = depset(transitive = [i.cc_include_dirs for i in infos]).to_list()
    codegen = [c[ReactNativeCodegenInfo] for c in ctx.attr.codegen]
    srcs = [f for f in ctx.files.srcs if f.extension in ("c", "cc", "cpp")]
    srcs.append(_autolinking_cpp(ctx, [c.library_name for c in codegen]))
    hdrs = [f for f in ctx.files.srcs if f.extension in ("h", "hpp")]
    local_includes = {f.dirname: True for f in hdrs}.keys()
    codegen_dirs = [c.jni for c in codegen]
    codegen_includes = []
    for c in codegen:
        # Same include roots as the CMakeLists.txt codegen writes next to the sources.
        codegen_includes.append(c.jni.path)
        codegen_includes.append("%s/react/renderer/components/%s" % (c.jni.path, c.library_name))

    outputs = []
    for abi in ctx.attr.abis:
        if abi not in _ABI_TARGETS:
            fail("unsupported ABI %r; expected one of %s" % (abi, sorted(_ABI_TARGETS)))
        link_libs = {}
        for lib in native_libs:
            if lib.abi == abi and lib.file.basename in _LINK_LIBS and lib.file.basename not in link_libs:
                link_libs[lib.file.basename] = lib.file
        missing = [l for l in _LINK_LIBS if l not in link_libs]
        if missing:
            fail("no %s for %s among the deps' native libraries" % (", ".join(missing), abi))

        out = ctx.actions.declare_file("%s/%s/libappmodules.so" % (ctx.label.name, abi))
        args = ctx.actions.args()
        args.add("--target=%s%d" % (_ABI_TARGETS[abi], ctx.attr.min_sdk))
        args.add("-shared")
        args.add_all(_COPTS)
        if not ctx.attr.debug:
            args.add_all(_RELEASE_COPTS)
        args.add_all(ctx.attr.copts)
        args.add_all(local_includes, format_each = "-I%s")
        args.add_all(codegen_includes, format_each = "-I%s")
        args.add_all(include_dirs, format_each = "-I%s")
        args.add_all(srcs)
        args.add_all(codegen_dirs, map_each = _cpp_sources)
        args.add("-nostdlib++")
        args.add_all([link_libs[l] for l in _LINK_LIBS])
        args.add_all([
            "-llog",
            "-Wl,--no-undefined",
            "-Wl,--build-id=none",
            "-Wl,-z,max-page-size=16384",
            "-Wl,-soname,libappmodules.so",
            # Paths would otherwise leak into the binary through __FILE__ and debug info.
            "-ffile-prefix-map=%s=." % ctx.bin_dir.path,
            "-s",
        ])
        args.add("-o", out)
        ctx.actions.run(
            executable = ctx.file._clang,
            arguments = [args],
            inputs = depset(srcs + hdrs + codegen_dirs + link_libs.values(), transitive = [headers]),
            tools = ctx.files._toolchain_files,
            outputs = [out],
            mnemonic = "ReactNativeAppModules",
            progress_message = "Compiling libappmodules.so for %s of %%{label}" % abi,
        )
        outputs.append(struct(abi = abi, file = out))

    return [
        DefaultInfo(files = depset([o.file for o in outputs])),
        AndroidLibraryInfo(
            resources = depset(order = "postorder"),
            native_libs = depset(outputs),
            assets = depset(),
            cc_headers = depset(),
            cc_include_dirs = depset(),
        ),
    ]

react_native_appmodules = rule(
    implementation = _react_native_appmodules_impl,
    doc = """Builds libappmodules.so for each ABI with the NDK's clang.

React Native's DefaultTurboModuleManagerDelegate only finds Java TurboModules (PlatformConstants,
ExceptionsManager, ...) through the javaModuleProvider that the app's OnLoad.cpp installs, so an
app without this library starts Hermes and then fails on the first native module lookup.""",
    attrs = {
        "abis": attr.string_list(mandatory = True),
        "codegen": attr.label_list(providers = [ReactNativeCodegenInfo], doc = "`react_native_codegen` targets whose C++ is compiled in and registered in autolinking.cpp."),
        "copts": attr.string_list(),
        "debug": attr.bool(default = False, doc = "Build against react-android's debug variant (no NDEBUG)."),
        "deps": attr.label_list(providers = [AndroidLibraryInfo], doc = "Libraries providing react-native's prefab headers and .so files."),
        "min_sdk": attr.int(mandatory = True),
        "srcs": attr.label_list(
            allow_files = [".c", ".cc", ".cpp", ".h", ".hpp"],
            default = [
                "//react_native/android/native:OnLoad.cpp",
                "//react_native/android/native:autolinking.h",
            ],
        ),
        "_clang": attr.label(default = "@rn_android_ndk//:clang", allow_single_file = True, cfg = "exec"),
        "_toolchain_files": attr.label(default = "@rn_android_ndk//:toolchain_files", cfg = "exec"),
    },
)
