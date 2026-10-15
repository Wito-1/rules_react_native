"""Compiles the app's libappmodules.so, which registers React Native's TurboModule providers."""

load("//react_native/js/private:codegen.bzl", "ReactNativeCodegenInfo")
load(":aar.bzl", "AndroidLibraryInfo", "appmodules_unit", "collect_android_infos", "merge_android_infos")

_ABI_TARGETS = {
    "arm64-v8a": "aarch64-linux-android",
    "armeabi-v7a": "armv7a-linux-androideabi",
    "x86": "i686-linux-android",
    "x86_64": "x86_64-linux-android",
}

# react-native's folly-flags.cmake and react-native-flags.cmake, which ReactNative-application.cmake
# applies to the app library, plus what the NDK's CMake toolchain file adds: libraries guard their
# Android-only code (folly::dynamic state, MapBuffer) with `ANDROID`, not clang's `__ANDROID__`.
_COPTS = [
    "-DANDROID",
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

# What @react-native/gradle-plugin's GenerateAutolinkingNewArchitecturesFileTask emits. The plugin
# lists component descriptors from each library's react-native.config.js; for libraries that don't
# list them, calling the codegen'd <lib>_registerComponentDescriptorsFromCodegen registers the same
# set.
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
{cxx_module_providers}
  return nullptr;
}}

void autolinking_registerProviders(std::shared_ptr<ComponentDescriptorProviderRegistry const> providerRegistry) {{
{component_registrations}
}}

}} // namespace react
}} // namespace facebook
"""

def _autolinking_cpp(ctx, units):
    includes = []
    module_providers = []
    cxx_module_providers = []
    component_registrations = []
    for u in units:
        lib = u.codegen_library
        if lib:
            includes.append("#include <{0}.h>\n#include <react/renderer/components/{0}/ComponentDescriptors.h>".format(lib))
            module_providers.append("  if (auto module = {0}_ModuleProvider(moduleName, params)) {{\n    return module;\n  }}".format(lib))
            if u.register_codegen_components:
                component_registrations.append("  {}_registerComponentDescriptorsFromCodegen(providerRegistry);".format(lib))
        for d in u.component_descriptors:
            component_registrations.append("  providerRegistry->add(concreteComponentDescriptorProvider<{}>());".format(d))
        for m in u.cxx_modules:
            includes.append("#include <{}>".format(m.header))
            cxx_module_providers.append("  if (moduleName == {0}::kModuleName) {{\n    return std::make_shared<{0}>(jsInvoker);\n  }}".format(m.cls))
    out = ctx.actions.declare_file(ctx.label.name + "/autolinking.cpp")
    ctx.actions.write(out, _AUTOLINKING_CPP.format(
        includes = "\n".join(includes),
        module_providers = "\n".join(module_providers),
        cxx_module_providers = "\n".join(cxx_module_providers),
        component_registrations = "\n".join(component_registrations),
    ))
    return out

def _cpp_sources(f):
    return f.path if f.extension in ("c", "cc", "cpp") else None

def _tree_sources(dirs):
    prefixes = [d.rstrip("/") + "/" for d in dirs]

    def map_each(f):
        if f.extension not in ("c", "cc", "cpp"):
            return None
        for prefix in prefixes:
            if f.path.startswith(prefix):
                return f.path
        return None

    return map_each

def _react_native_appmodules_impl(ctx):
    infos = collect_android_infos(ctx.attr.deps)
    native_libs = depset(transitive = [i.native_libs for i in infos]).to_list()
    headers = depset(transitive = [i.cc_headers for i in infos])
    include_dirs = depset(transitive = [i.cc_include_dirs for i in infos]).to_list()

    # The app's own codegen plus every library's units; one per key (diamonds).
    units = {}
    for c in ctx.attr.codegen:
        info = c[ReactNativeCodegenInfo]
        units.setdefault(info.library_name, appmodules_unit(key = info.library_name, codegen = info))
    for u in depset(transitive = [i.appmodules for i in infos]).to_list():
        units.setdefault(u.key, u)
    units = units.values()

    srcs = [f for f in ctx.files.srcs if f.extension in ("c", "cc", "cpp")]
    srcs.append(_autolinking_cpp(ctx, units))
    hdrs = [f for f in ctx.files.srcs if f.extension in ("h", "hpp")]
    local_includes = {f.dirname: True for f in hdrs}.keys()
    codegen_dirs = [u.jni for u in units if u.jni]
    unit_srcs, unit_hdrs, unit_trees, unit_includes = [], [], [], []
    for u in units:
        unit_srcs.extend(u.srcs)
        unit_hdrs.extend(u.hdrs)
        unit_trees.extend(u.trees)
        unit_includes.extend(u.includes)
    codegen_includes = []
    for u in units:
        if u.jni:
            # Same include roots as the CMakeLists.txt codegen writes next to the sources.
            codegen_includes.append(u.jni.path)
            codegen_includes.append("%s/react/renderer/components/%s" % (u.jni.path, u.codegen_library))

    outputs = []
    debug_outputs = []
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

        unstripped = ctx.actions.declare_file("%s/unstripped/%s/libappmodules.so" % (ctx.label.name, abi))
        out = ctx.actions.declare_file("%s/%s/libappmodules.so" % (ctx.label.name, abi))
        args = ctx.actions.args()
        args.add("--target=%s%d" % (_ABI_TARGETS[abi], ctx.attr.min_sdk))
        args.add("-shared")
        args.add_all(_COPTS)
        if not ctx.attr.debug:
            args.add_all(_RELEASE_COPTS)
        args.add_all(ctx.attr.copts)
        args.add_all(local_includes, format_each = "-I%s")

        # Libraries' own headers win over codegen's: a library's hand-written <lib>.h (declaring
        # its custom descriptors) shadows the generated one, as its CMakeLists.txt arranges.
        args.add_all(unit_includes, format_each = "-I%s", uniquify = True)
        args.add_all(codegen_includes, format_each = "-I%s")
        args.add_all(include_dirs, format_each = "-I%s")
        args.add_all(srcs + unit_srcs)
        args.add_all(codegen_dirs, map_each = _cpp_sources)
        for u in units:
            if u.tree_src_dirs:
                args.add_all(u.trees, map_each = _tree_sources(u.tree_src_dirs), allow_closure = True)
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
            # Debug info for symbolicating native crashes; the packaged copy is stripped below.
            "-g",
        ])
        args.add("-o", unstripped)
        ctx.actions.run(
            executable = ctx.file._clang,
            arguments = [args],
            inputs = depset(
                srcs + hdrs + unit_srcs + unit_hdrs + unit_trees + codegen_dirs + link_libs.values(),
                transitive = [headers],
            ),
            tools = ctx.files._toolchain_files,
            outputs = [unstripped],
            mnemonic = "ReactNativeAppModules",
            progress_message = "Compiling libappmodules.so for %s of %%{label}" % abi,
        )
        ctx.actions.run(
            executable = ctx.file._objcopy,
            # What AGP's StripDebugSymbolsTask runs.
            arguments = ["--strip-unneeded", unstripped.path, out.path],
            inputs = [unstripped],
            outputs = [out],
            mnemonic = "ReactNativeStrip",
            progress_message = "Stripping libappmodules.so for %s of %%{label}" % abi,
        )
        outputs.append(struct(abi = abi, file = out))
        debug_outputs.append(struct(abi = abi, file = unstripped))

    return [
        DefaultInfo(files = depset([o.file for o in outputs])),
        merge_android_infos(native_libs = outputs, native_debug_libs = debug_outputs),
        OutputGroupInfo(native_debug_symbols = depset([o.file for o in debug_outputs])),
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
        "_objcopy": attr.label(default = "@rn_android_ndk//:objcopy", allow_single_file = True, cfg = "exec"),
        "_toolchain_files": attr.label(default = "@rn_android_ndk//:toolchain_files", cfg = "exec"),
    },
)
