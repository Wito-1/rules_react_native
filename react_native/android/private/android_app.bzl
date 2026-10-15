"""Rules that link an Android app's resources and package it into a signed APK."""

load("@rules_java//java/common:java_common.bzl", "java_common")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load(":aar.bzl", "AndroidLibraryInfo", "collect_android_infos", "compile_resources", "resolve_app_deps")
load(":java.bzl", "JAVA_ATTRS", "run_java_tool")

AndroidAppResourcesInfo = provider(
    doc = "Linked resources of an app, consumed by `android_apk`.",
    fields = {
        "resources_apk": "File: APK written by `aapt2 link` (manifest, resources.arsc, res/)",
        "manifest": "File: the merged AndroidManifest.xml",
        "min_sdk": "int",
        "proguard_keep": "File: aapt2's keep rules for classes the manifest and resources reference",
    },
)

_BUILD_CONFIG = """\
package {package};

public final class BuildConfig {{
  public static final boolean DEBUG = {debug};
  public static final String APPLICATION_ID = "{application_id}";
  public static final String BUILD_TYPE = "{build_type}";
  public static final int VERSION_CODE = {version_code};
  public static final String VERSION_NAME = "{version_name}";
  public static final boolean IS_NEW_ARCHITECTURE_ENABLED = true;
  public static final boolean IS_HERMES_ENABLED = true;
  public static final boolean IS_EDGE_TO_EDGE_ENABLED = {edge_to_edge};
{fields}}}
"""

# Mirrors GenerateEntryPointTask in @react-native/gradle-plugin; apps call loadReactNative() from
# Application.onCreate().
_ENTRY_POINT = """\
package com.facebook.react;

import android.content.Context;
import com.facebook.react.defaults.DefaultNewArchitectureEntryPoint;
import com.facebook.react.soloader.OpenSourceMergedSoMapping;
import com.facebook.react.views.view.WindowUtilKt;
import com.facebook.soloader.SoLoader;
import java.io.IOException;

public class ReactNativeApplicationEntryPoint {{
  public static void loadReactNative(Context context) {{
    try {{
      SoLoader.init(context, OpenSourceMergedSoMapping.INSTANCE);
    }} catch (IOException error) {{
      throw new RuntimeException(error);
    }}
    if ({package}.BuildConfig.IS_NEW_ARCHITECTURE_ENABLED) {{
      DefaultNewArchitectureEntryPoint.load();
    }}
    if ({package}.BuildConfig.IS_EDGE_TO_EDGE_ENABLED) {{
      WindowUtilKt.setEdgeToEdgeFeatureFlagOn();
    }}
  }}
}}
"""

# Mirrors GeneratePackageListTask in @react-native/gradle-plugin, with `react_packages` standing in
# for autolinking.
_PACKAGE_LIST = """\
package com.facebook.react;

import android.app.Application;
import com.facebook.react.shell.MainPackageConfig;
import com.facebook.react.shell.MainReactPackage;
import java.util.ArrayList;
import java.util.Arrays;

@SuppressWarnings("deprecation")
public class PackageList {{
  private final MainPackageConfig mConfig;

  public PackageList(ReactNativeHost reactNativeHost) {{
    this(reactNativeHost, null);
  }}

  public PackageList(Application application) {{
    this(application, null);
  }}

  public PackageList(ReactNativeHost reactNativeHost, MainPackageConfig config) {{
    mConfig = config;
  }}

  public PackageList(Application application, MainPackageConfig config) {{
    mConfig = config;
  }}

  public ArrayList<ReactPackage> getPackages() {{
    return new ArrayList<>(Arrays.<ReactPackage>asList(
      new MainReactPackage(mConfig){extra}
    ));
  }}
}}
"""

def _application_id(ctx):
    return ctx.attr.application_id or ctx.attr.package

def _merge_manifests(ctx, libraries):
    # Relative class names resolve against the namespace (`package`), before the manifest's
    # package becomes the application id, as AGP does.
    qualified = ctx.actions.declare_file(ctx.label.name + "/qualified/AndroidManifest.xml")
    ctx.actions.run(
        executable = ctx.executable._qualify_manifest,
        arguments = ["--manifest", ctx.file.manifest.path, "--namespace", ctx.attr.package, "--out", qualified.path],
        inputs = [ctx.file.manifest],
        outputs = [qualified],
        mnemonic = "AndroidQualifyManifest",
        progress_message = "Qualifying the manifest of %{label}",
    )
    merged = ctx.actions.declare_file(ctx.label.name + "/AndroidManifest.xml")
    args = ctx.actions.args()
    args.add("--main", qualified)
    lib_manifests = [lib.manifest for lib in libraries]
    if lib_manifests:
        args.add_joined("--libs", lib_manifests, join_with = ":")
    args.add("--property", "PACKAGE=" + _application_id(ctx))
    args.add("--property", "MIN_SDK_VERSION=%d" % ctx.attr.min_sdk)
    args.add("--property", "TARGET_SDK_VERSION=%d" % ctx.attr.target_sdk)
    args.add("--property", "VERSION_CODE=%d" % ctx.attr.version_code)
    args.add("--property", "VERSION_NAME=" + ctx.attr.version_name)

    # The merger derives ${applicationId} from PACKAGE itself and rejects a duplicate.
    for k, v in sorted(ctx.attr.manifest_placeholders.items()):
        args.add("--placeholder", "%s=%s" % (k, v))
    args.add("--out", merged)
    run_java_tool(
        ctx,
        main_class = "com.android.manifmerger.Merger",
        classpath = ctx.files._manifest_merger_classpath,
        arguments = [args],
        inputs = [qualified] + lib_manifests,
        outputs = [merged],
        mnemonic = "AndroidManifestMerger",
        progress_message = "Merging Android manifests of %{label}",
    )
    return merged

def _compile_res_dir(ctx, name, res_dir, inputs):
    return compile_resources(ctx, ctx.file._aapt2, ctx.label.name + "/" + name, res_dir, inputs)

def _res_root(files):
    root = None
    for f in files:
        idx = f.path.find("/res/")
        if idx < 0:
            fail("resource %s is not under a res/ directory" % f.path)
        candidate = f.path[:idx + len("/res")]
        if root != None and root != candidate:
            fail("all `res` files must share one res/ directory, got %s and %s" % (root, candidate))
        root = candidate
    return root

def _react_packages(ctx, infos):
    packages = {p: True for p in ctx.attr.react_packages}
    for p in depset(transitive = [i.react_packages for i in infos]).to_list():
        packages[p] = True
    return packages.keys()

def _android_app_resources_impl(ctx):
    infos = collect_android_infos(resolve_app_deps(ctx.attr.deps))
    libraries = depset(transitive = [i.resources for i in infos], order = "postorder").to_list()

    merged_manifest = _merge_manifests(ctx, libraries)

    overlays = [lib.flata for lib in libraries if lib.flata]
    for i, tree in enumerate(ctx.files.generated_res):
        overlays.append(_compile_res_dir(ctx, "generated_%d" % i, tree.path, [tree]))
    if ctx.files.res:
        overlays.append(_compile_res_dir(ctx, "app", _res_root(ctx.files.res), ctx.files.res))

    resources_apk = ctx.actions.declare_file(ctx.label.name + "/resources.ap_")
    r_txt = ctx.actions.declare_file(ctx.label.name + "/R.txt")
    proguard_keep = ctx.actions.declare_file(ctx.label.name + "/aapt2_keep.pro")
    args = ctx.actions.args()
    args.add("link")
    args.add("-o", resources_apk)
    args.add("-I", ctx.file._android_jar)
    args.add("--manifest", merged_manifest)
    args.add("--min-sdk-version", str(ctx.attr.min_sdk))
    args.add("--target-sdk-version", str(ctx.attr.target_sdk))
    args.add("--version-code", str(ctx.attr.version_code))
    args.add("--version-name", ctx.attr.version_name)
    args.add("--auto-add-overlay")
    args.add("--no-version-vectors")
    args.add("--output-text-symbols", r_txt)
    args.add("--proguard", proguard_keep)
    args.add_all(overlays, before_each = "-R")
    ctx.actions.run(
        executable = ctx.file._aapt2,
        arguments = [args],
        inputs = [merged_manifest, ctx.file._android_jar] + overlays,
        outputs = [resources_apk, r_txt, proguard_keep],
        mnemonic = "Aapt2Link",
        progress_message = "Linking Android resources of %{label}",
    )

    generated = {
        ctx.attr.package.replace(".", "/") + "/BuildConfig.java": _BUILD_CONFIG.format(
            package = ctx.attr.package,
            application_id = _application_id(ctx),
            fields = "".join([
                "  public static final String %s = %s;\n" % (k, json.encode(v))
                for k, v in sorted(ctx.attr.build_config_fields.items())
            ]),
            debug = "true" if ctx.attr.debug else "false",
            build_type = "debug" if ctx.attr.debug else "release",
            version_code = ctx.attr.version_code,
            version_name = ctx.attr.version_name,
            edge_to_edge = "true" if ctx.attr.edge_to_edge else "false",
        ),
        "com/facebook/react/ReactNativeApplicationEntryPoint.java": _ENTRY_POINT.format(package = ctx.attr.package),
        "com/facebook/react/PackageList.java": _PACKAGE_LIST.format(
            extra = "".join([",\n      new %s()" % p for p in _react_packages(ctx, infos)]),
        ),
    }
    srcjar = ctx.actions.declare_file(ctx.label.name + "/generated.srcjar")
    gen_args = ctx.actions.args()
    gen_args.add("--r_txt", r_txt)
    gen_args.add("--package", ctx.attr.package)
    gen_inputs = [r_txt]
    for lib in libraries:
        if lib.r_txt:
            gen_args.add("--library", "%s=%s" % (lib.package, lib.r_txt.path))
            gen_inputs.append(lib.r_txt)
    for path, content in generated.items():
        f = ctx.actions.declare_file(ctx.label.name + "/java/" + path)
        ctx.actions.write(f, content)
        gen_args.add("--java", "%s=%s" % (path, f.path))
        gen_inputs.append(f)
    gen_args.add("--out", srcjar)
    ctx.actions.run(
        executable = ctx.executable._gen_r,
        arguments = [gen_args],
        inputs = gen_inputs,
        outputs = [srcjar],
        mnemonic = "AndroidGenerateR",
        progress_message = "Generating R classes for %{label}",
    )

    return [
        DefaultInfo(files = depset([srcjar])),
        AndroidAppResourcesInfo(
            resources_apk = resources_apk,
            manifest = merged_manifest,
            min_sdk = ctx.attr.min_sdk,
            proguard_keep = proguard_keep,
        ),
        OutputGroupInfo(
            manifest = depset([merged_manifest]),
            r_txt = depset([r_txt]),
        ),
    ]

_SDK_ATTRS = dict(JAVA_ATTRS, **{
    "_aapt2": attr.label(default = "@rn_android_sdk//:aapt2", allow_single_file = True, cfg = "exec"),
})

android_app_resources = rule(
    implementation = _android_app_resources_impl,
    doc = "Merges manifests, links resources with aapt2 and writes a srcjar of R classes plus the React Native glue sources the Gradle plugin would generate.",
    attrs = dict(_SDK_ATTRS, **{
        "application_id": attr.string(doc = "The installed app's id, if it differs from `package` (Gradle's `applicationId` vs `namespace`)."),
        "build_config_fields": attr.string_dict(doc = "Extra `public static final String` fields of BuildConfig (Gradle's `buildConfigField`)."),
        "debug": attr.bool(default = False),
        "deps": attr.label_list(providers = [AndroidLibraryInfo]),
        "edge_to_edge": attr.bool(default = False),
        "generated_res": attr.label_list(allow_files = True, doc = "Directories (tree artifacts) laid out like res/, e.g. images emitted by the JS bundler."),
        "manifest": attr.label(allow_single_file = [".xml"], mandatory = True),
        "manifest_placeholders": attr.string_dict(),
        "min_sdk": attr.int(mandatory = True),
        "package": attr.string(mandatory = True),
        "react_packages": attr.string_list(doc = "Fully-qualified ReactPackage classes added to PackageList, besides those the deps declare."),
        "res": attr.label_list(allow_files = True),
        "target_sdk": attr.int(mandatory = True),
        "version_code": attr.int(mandatory = True),
        "version_name": attr.string(mandatory = True),
        "_gen_r": attr.label(default = "//react_native/android/tools:gen_r", executable = True, cfg = "exec"),
        "_qualify_manifest": attr.label(default = "//react_native/android/tools:qualify_manifest", executable = True, cfg = "exec"),
        "_manifest_merger_classpath": attr.label(default = "@rn_android_tools_maven//:all", cfg = "exec"),
    }),
)

def _app_assets(files):
    roots = {}
    for f in files:
        idx = f.path.find("/assets/")
        if idx < 0:
            fail("%s is not under an assets/ directory" % f.path)
        roots[f.path[:idx + len("/assets")]] = True
    if len(roots) > 1:
        fail("all `assets` files must share one assets/ directory, got %s" % sorted(roots))
    return [(f.path[f.path.find("/assets/") + len("/assets/"):], f) for f in files]

def _android_apk_impl(ctx):
    res_info = ctx.attr.resources[AndroidAppResourcesInfo]
    infos = collect_android_infos(resolve_app_deps(ctx.attr.deps))
    runtime_jars = depset(transitive = [i.runtime_jars for i in infos] + [
        d[JavaInfo].transitive_runtime_jars
        for d in ctx.attr.deps
        if AndroidLibraryInfo not in d and JavaInfo in d
    ]).to_list()

    dex = ctx.actions.declare_file(ctx.label.name + "/classes.dex.zip")
    mapping = None
    if ctx.attr.minify:
        mapping = ctx.actions.declare_file(ctx.label.name + "/mapping.txt")
        specs = depset(transitive = [i.proguard_specs for i in infos]).to_list()
        runtime = ctx.attr._jdk[java_common.JavaRuntimeInfo]
        r8_args = ctx.actions.args()
        r8_args.use_param_file("@%s", use_always = True)
        r8_args.set_param_file_format("multiline")
        r8_args.add("--java", runtime.java_executable_exec_path)
        r8_args.add_all(ctx.files._d8_classpath, before_each = "--r8_classpath")
        r8_args.add("--lib", ctx.file._android_jar)
        r8_args.add("--min_api", str(res_info.min_sdk))
        if ctx.attr.debug:
            r8_args.add("--debug")
        r8_args.add_all([ctx.file._proguard_defaults, res_info.proguard_keep] + ctx.files.proguard_specs, before_each = "--pg_conf")
        r8_args.add_all([s.path for s in specs], before_each = "--pg_conf")
        r8_args.add_all(runtime_jars, before_each = "--program")
        r8_args.add("--mapping_out", mapping)
        r8_args.add("--out", dex)
        ctx.actions.run(
            executable = ctx.executable._r8,
            arguments = [r8_args],
            inputs = depset(
                runtime_jars + ctx.files._d8_classpath + ctx.files.proguard_specs +
                [ctx.file._android_jar, ctx.file._proguard_defaults, res_info.proguard_keep] +
                [s.file for s in specs],
            ),
            tools = runtime.files,
            outputs = [dex, mapping],
            mnemonic = "AndroidR8",
            progress_message = "Shrinking and dexing %{label} with R8",
        )
    else:
        d8_args = ctx.actions.args()
        d8_args.add("--debug" if ctx.attr.debug else "--release")

        # Debug dexing keeps local-variable tables and reports every malformed one in third-party
        # jars (kotlinx-coroutines has hundreds) at info level; they're harmless and drown real output.
        d8_args.add_all(["--map-diagnostics", "info", "none"])
        d8_args.add("--min-api", str(res_info.min_sdk))
        d8_args.add("--lib", ctx.file._android_jar)
        d8_args.add("--output", dex)
        d8_args.add_all(runtime_jars)
        run_java_tool(
            ctx,
            main_class = "com.android.tools.r8.D8",
            classpath = ctx.files._d8_classpath,
            jvm_flags = ["-Xmx4g"],
            arguments = [d8_args],
            inputs = runtime_jars + [ctx.file._android_jar],
            outputs = [dex],
            mnemonic = "AndroidDex",
            progress_message = "Dexing %{label}",
        )

    native_libs = depset(transitive = [i.native_libs for i in infos]).to_list()
    native_libs = [lib for lib in native_libs if lib.abi in ctx.attr.abis]
    assets = depset(transitive = [i.assets for i in infos]).to_list()

    def package(resources, out, bundle_module):
        args = ctx.actions.args()
        args.use_param_file("@%s", use_always = True)
        args.set_param_file_format("multiline")
        args.add("--resources", resources)
        args.add("--dex", dex)
        for lib in native_libs:
            args.add("--native_lib", "%s/%s=%s" % (lib.abi, lib.file.basename, lib.file.path))
        for asset in assets:
            args.add("--asset", "%s=%s" % (asset.path, asset.file.path))
        for f in ctx.files.assets:
            args.add("--asset", "%s=%s" % (f.basename, f.path))
        for path, f in _app_assets(ctx.files.app_assets):
            args.add("--asset", "%s=%s" % (path, f.path))
        args.add_all(runtime_jars, before_each = "--java_resources_from")
        if bundle_module:
            args.add("--bundle_module")
        args.add("--out", out)
        ctx.actions.run(
            executable = ctx.executable._build_apk,
            arguments = [args],
            inputs = depset(
                [resources, dex] + runtime_jars + ctx.files.assets + ctx.files.app_assets +
                [lib.file for lib in native_libs] + [a.file for a in assets],
            ),
            outputs = [out],
            mnemonic = "AndroidBuildBundleModule" if bundle_module else "AndroidBuildApk",
            progress_message = "Packaging %{label}" + (" as a bundle module" if bundle_module else ""),
        )

    unsigned = ctx.actions.declare_file(ctx.label.name + "/unsigned.apk")
    package(res_info.resources_apk, unsigned, bundle_module = False)

    # 16 KiB page alignment for .so files is required on Android 15+ devices with 16 KiB pages.
    aligned = ctx.actions.declare_file(ctx.label.name + "/aligned.apk")
    ctx.actions.run(
        executable = ctx.file._zipalign,
        arguments = ["-P", "16", "-f", "4", unsigned.path, aligned.path],
        inputs = [unsigned] + ctx.files._zipalign_libs,
        outputs = [aligned],
        mnemonic = "AndroidZipalign",
        progress_message = "Aligning %{label}",
    )

    apk = ctx.actions.declare_file(ctx.label.name + ".apk")
    sign_args = ctx.actions.args()
    sign_args.add("sign")
    sign_args.add("--ks", ctx.file.keystore)
    sign_args.add("--ks-pass", "pass:" + ctx.attr.keystore_password)
    sign_args.add("--ks-key-alias", ctx.attr.key_alias)
    sign_args.add("--min-sdk-version", str(res_info.min_sdk))
    sign_args.add("--out", apk)
    sign_args.add(aligned)
    run_java_tool(
        ctx,
        main_class = "com.android.apksigner.ApkSignerTool",
        classpath = ctx.files._apksigner_classpath,
        arguments = [sign_args],
        inputs = [aligned, ctx.file.keystore],
        outputs = [apk],
        mnemonic = "AndroidSignApk",
        progress_message = "Signing %{label}",
    )

    aab = _app_bundle(ctx, res_info, package, mapping)
    debug_libs = [l for l in depset(transitive = [i.native_debug_libs for i in infos]).to_list() if l.abi in ctx.attr.abis]
    native_debug_symbols = ctx.actions.declare_file(ctx.label.name + "/native-debug-symbols.zip")
    zip_args = ctx.actions.args()
    zip_args.add("c", native_debug_symbols)
    zip_args.add_all(["%s/%s=%s" % (l.abi, l.file.basename, l.file.path) for l in debug_libs])
    ctx.actions.run(
        executable = ctx.executable._zipper,
        arguments = [zip_args],
        inputs = [l.file for l in debug_libs],
        outputs = [native_debug_symbols],
        mnemonic = "AndroidNativeDebugSymbols",
        progress_message = "Zipping native debug symbols of %{label}",
    )

    return [
        DefaultInfo(files = depset([apk])),
        AndroidApkInfo(unsigned = aligned, min_sdk = res_info.min_sdk, aab = aab),
        OutputGroupInfo(
            aab = depset([aab]),
            native_debug_symbols = depset([native_debug_symbols]),
            proguard_mapping = depset([mapping] if mapping else []),
            unsigned = depset([aligned]),
        ),
    ]

# Play's defaults for a React Native app, as AGP writes them: native libraries and the JS bundle
# stay uncompressed so they can be mmapped from the installed APKs.
_BUNDLE_CONFIG = {
    "compression": {"uncompressedGlob": ["assets/**/*.bundle"]},
    "optimizations": {
        "splitsConfig": {
            "splitDimension": [
                {"value": "ABI"},
                {"value": "SCREEN_DENSITY"},
                {"value": "LANGUAGE"},
            ],
        },
        "uncompressNativeLibraries": {"enabled": True},
    },
}

def _app_bundle(ctx, res_info, package, mapping):
    """Builds the unsigned .aab: same content as the APK, resources in proto format."""
    proto_resources = ctx.actions.declare_file(ctx.label.name + "/proto_resources.ap_")
    ctx.actions.run(
        executable = ctx.file._aapt2,
        arguments = ["convert", "--output-format", "proto", "-o", proto_resources.path, res_info.resources_apk.path],
        inputs = [res_info.resources_apk],
        outputs = [proto_resources],
        mnemonic = "Aapt2Convert",
        progress_message = "Converting resources of %{label} for the app bundle",
    )
    module = ctx.actions.declare_file(ctx.label.name + "/base.zip")
    package(proto_resources, module, bundle_module = True)

    config = ctx.actions.declare_file(ctx.label.name + "/BundleConfig.json")
    ctx.actions.write(config, json.encode_indent(_BUNDLE_CONFIG))

    # Play reads these from the bundle's metadata: deobfuscation of Java stack traces and
    # symbolication of native ones, with no separate upload.
    infos = collect_android_infos(resolve_app_deps(ctx.attr.deps))
    debug_libs = [l for l in depset(transitive = [i.native_debug_libs for i in infos]).to_list() if l.abi in ctx.attr.abis]
    metadata = [("com.android.tools.build.debugsymbols/%s/%s.dbg" % (l.abi, l.file.basename), l.file) for l in debug_libs]
    if mapping:
        metadata.append(("com.android.tools.build.obfuscation/proguard.map", mapping))

    aab = ctx.actions.declare_file(ctx.label.name + ".aab")
    args = ctx.actions.args()
    args.add("build-bundle")
    args.add("--modules=" + module.path)
    args.add("--config=" + config.path)
    args.add_all(["--metadata-file=%s:%s" % (path, f.path) for path, f in metadata])
    args.add("--output=" + aab.path)
    run_java_tool(
        ctx,
        main_class = "com.android.tools.build.bundletool.BundleToolMain",
        classpath = ctx.files._bundletool_classpath,
        arguments = [args],
        inputs = [module, config] + [f for _, f in metadata],
        outputs = [aab],
        mnemonic = "AndroidBuildBundle",
        progress_message = "Building the app bundle of %{label}",
    )
    return aab

AndroidApkInfo = provider(
    doc = "An APK before signing, for signing outside the build (`android_sign`), and the app bundle.",
    fields = {
        "unsigned": "File: the zipaligned, unsigned APK",
        "min_sdk": "int",
        "aab": "File: the unsigned Android App Bundle",
    },
)

android_apk = rule(
    implementation = _android_apk_impl,
    doc = """Dexes (or shrinks with R8) the app's runtime classpath and packages it with linked resources,
native libraries and assets into a signed APK. Output groups: `aab` (the unsigned app bundle, with
the R8 mapping and native debug symbols in its metadata), `native_debug_symbols`,
`proguard_mapping`, `unsigned`.""",
    attrs = dict(_SDK_ATTRS, **{
        "abis": attr.string_list(mandatory = True),
        "app_assets": attr.label_list(allow_files = True, doc = "Files under one assets/ directory, packaged at the same relative paths (e.g. assets/fonts/X.ttf)."),
        "assets": attr.label_list(allow_files = True, doc = "Files placed at the root of assets/, e.g. index.android.bundle."),
        "debug": attr.bool(default = False),
        "deps": attr.label_list(providers = [[JavaInfo], [AndroidLibraryInfo]]),
        "key_alias": attr.string(mandatory = True),
        "keystore": attr.label(allow_single_file = True, mandatory = True),
        "keystore_password": attr.string(mandatory = True, doc = "Stored in the action command line; only for keys that aren't secret. See `android_sign` for release keys."),
        "minify": attr.bool(doc = "Shrink, optimize and obfuscate with R8 instead of dexing with D8."),
        "proguard_specs": attr.label_list(allow_files = True, doc = "The app's own R8 rules, besides the defaults, aapt2's and the libraries' consumer rules."),
        "resources": attr.label(providers = [AndroidAppResourcesInfo], mandatory = True),
        "_apksigner_classpath": attr.label(default = "@rn_android_sdk//:apksigner_jar", cfg = "exec"),
        "_build_apk": attr.label(default = "//react_native/android/tools:build_apk", executable = True, cfg = "exec"),
        "_bundletool_classpath": attr.label(default = "@rn_bundletool_maven//:all", cfg = "exec"),
        "_d8_classpath": attr.label(default = "@rn_android_sdk//:d8_jar", cfg = "exec"),
        "_proguard_defaults": attr.label(default = "//react_native/android:proguard-defaults.pro", allow_single_file = True),
        "_r8": attr.label(default = "//react_native/android/tools:r8", executable = True, cfg = "exec"),
        "_zipper": attr.label(default = "@bazel_tools//tools/zip:zipper", executable = True, cfg = "exec"),
        "_zipalign": attr.label(default = "@rn_android_sdk//:zipalign", allow_single_file = True, cfg = "exec"),
        "_zipalign_libs": attr.label(default = "@rn_android_sdk//:zipalign_libs", cfg = "exec"),
    }),
)

_INSTALL_SCRIPT = """\
#!/usr/bin/env bash
# Installs and launches the app on the device adb selects (set ANDROID_SERIAL to choose one).
set -euo pipefail
"{adb}" install -r -d "{apk}"
{reverse}"{adb}" shell monkey -p "{package}" -c android.intent.category.LAUNCHER 1 >/dev/null
echo "Launched {package}"
"""

def _android_install_impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        script,
        _INSTALL_SCRIPT.format(
            adb = ctx.file._adb.short_path,
            apk = ctx.file.apk.short_path,
            package = ctx.attr.package,
            # Debug builds load JS from Metro at localhost:8081 on the device; apps can ask for more
            # host ports (e.g. a backend) the same way.
            reverse = "".join([
                '"{}" reverse tcp:{port} tcp:{port}\n'.format(ctx.file._adb.short_path, port = port)
                for port in ([ctx.attr.metro_port] if ctx.attr.debug else []) + ctx.attr.reverse_ports
            ]),
        ),
        is_executable = True,
    )
    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(files = [ctx.file._adb, ctx.file.apk]),
    )]

android_install = rule(
    implementation = _android_install_impl,
    doc = "`bazel run` target that installs an APK with the hermetic adb and launches it.",
    executable = True,
    attrs = {
        "apk": attr.label(allow_single_file = [".apk"], mandatory = True),
        "debug": attr.bool(default = False),
        "metro_port": attr.int(default = 8081),
        "reverse_ports": attr.int_list(doc = "Host ports to expose on the device's localhost via `adb reverse`."),
        "package": attr.string(mandatory = True),
        "_adb": attr.label(default = "@rn_android_sdk//:adb", allow_single_file = True),
    },
)

def _rlocation(workspace_name, short_path):
    if short_path.startswith("../"):
        return short_path[len("../"):]
    return workspace_name + "/" + short_path

_SIGN_SCRIPT = """\
#!/usr/bin/env bash
# Signs {name}'s APK with a key that stays out of Bazel. Arguments go to `apksigner sign`, e.g.
#   bazel run {label} -- --ks release.jks --ks-key-alias upload --ks-pass env:KS_PASS --out app.apk
set -euo pipefail
runfiles="$(cd "${{RUNFILES_DIR:-$0.runfiles}}" && pwd)"
cd "${{BUILD_WORKING_DIRECTORY:-$PWD}}"
out=()
case " $* " in
  *" --out "*) ;;
  *) out=(--out "{default_out}"); echo "Writing {default_out} in $PWD" ;;
esac
"$runfiles/{java}" -cp "$runfiles/{apksigner}" com.android.apksigner.ApkSignerTool sign \\
  --min-sdk-version {min_sdk} "${{out[@]}}" "$@" "$runfiles/{unsigned}"
"""

def _android_sign_impl(ctx):
    info = ctx.attr.apk[AndroidApkInfo]
    runtime = ctx.attr._jdk[java_common.JavaRuntimeInfo]
    default_out = ctx.attr.apk.label.name + "-signed.apk"
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(script, _SIGN_SCRIPT.format(
        name = ctx.attr.apk.label.name,
        label = str(ctx.label),
        default_out = default_out,
        java = _rlocation(ctx.workspace_name, runtime.java_executable_runfiles_path),
        apksigner = _rlocation(ctx.workspace_name, ctx.file._apksigner.short_path),
        unsigned = _rlocation(ctx.workspace_name, info.unsigned.short_path),
        min_sdk = info.min_sdk,
    ), is_executable = True)
    runfiles = ctx.runfiles(files = [ctx.file._apksigner, info.unsigned], transitive_files = runtime.files)
    return [DefaultInfo(executable = script, runfiles = runfiles)]

android_sign = rule(
    implementation = _android_sign_impl,
    doc = """`bazel run` target that signs an app's aligned, unsigned APK with a key passed at run time.

The keystore and its password never become action inputs, so they can't leak into the action
cache, a remote cache or build logs. Use apksigner's `env:` or `file:` password forms.""",
    executable = True,
    attrs = {
        "apk": attr.label(providers = [AndroidApkInfo], mandatory = True),
        "_apksigner": attr.label(default = "@rn_android_sdk//:apksigner_jar", allow_single_file = True),
        "_jdk": attr.label(default = "@rules_java//toolchains:remotejdk_21", providers = [java_common.JavaRuntimeInfo]),
    },
)

_SIGN_BUNDLE_SCRIPT = """\
#!/usr/bin/env bash
# Signs {name}'s app bundle for upload with a key that stays out of Bazel. Arguments go to
# `jarsigner`, key alias last, e.g.
#   bazel run {label} -- -keystore upload.jks -storepass:env KS_PASS upload
set -euo pipefail
runfiles="$(cd "${{RUNFILES_DIR:-$0.runfiles}}" && pwd)"
cd "${{BUILD_WORKING_DIRECTORY:-$PWD}}"
if [ $# -lt 1 ]; then
  echo "usage: bazel run {label} -- <jarsigner options> <key alias>" >&2
  exit 2
fi
out=()
case " $* " in
  *" -signedjar "*) ;;
  *) out=(-signedjar "{default_out}"); echo "Writing {default_out} in $PWD" ;;
esac
"$runfiles/{jarsigner}" "${{out[@]}}" "${{@:1:$#-1}}" "$runfiles/{aab}" "${{@: -1}}"
"""

def _android_sign_bundle_impl(ctx):
    info = ctx.attr.apk[AndroidApkInfo]
    runtime = ctx.attr._jdk[java_common.JavaRuntimeInfo]
    default_out = ctx.attr.apk.label.name + "-signed.aab"
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(script, _SIGN_BUNDLE_SCRIPT.format(
        name = ctx.attr.apk.label.name,
        label = str(ctx.label),
        default_out = default_out,
        jarsigner = _rlocation(ctx.workspace_name, runtime.java_home_runfiles_path + "/bin/jarsigner"),
        aab = _rlocation(ctx.workspace_name, info.aab.short_path),
    ), is_executable = True)
    runfiles = ctx.runfiles(files = [info.aab], transitive_files = runtime.files)
    return [DefaultInfo(executable = script, runfiles = runfiles)]

android_sign_bundle = rule(
    implementation = _android_sign_bundle_impl,
    doc = """`bazel run` target that signs an app's .aab with an upload key passed at run time.

As with `android_sign`, the keystore and password never become action inputs. Use jarsigner's
`-storepass:env VAR` or `-storepass:file path` forms.""",
    executable = True,
    attrs = {
        "apk": attr.label(providers = [AndroidApkInfo], mandatory = True),
        "_jdk": attr.label(default = "@rules_java//toolchains:remotejdk_21", providers = [java_common.JavaRuntimeInfo]),
    },
)

_INSTALL_BUNDLE_SCRIPT = """\
#!/usr/bin/env bash
# Installs {name} from its app bundle the way Play would: bundletool generates the split APKs for
# the connected device (set ANDROID_SERIAL to choose one), signs them with the build's key and
# installs them.
set -euo pipefail
runfiles="$(cd "${{RUNFILES_DIR:-$0.runfiles}}" && pwd)"
adb="$runfiles/{adb}"
bundletool() {{
  "$runfiles/{java}" -cp "{classpath}" com.android.tools.build.bundletool.BundleToolMain "$@"
}}
device=()
if [ -n "${{ANDROID_SERIAL:-}}" ]; then device=(--device-id="$ANDROID_SERIAL"); fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bundletool build-apks --bundle="$runfiles/{aab}" --output="$work/app.apks" --connected-device \\
  --adb="$adb" "${{device[@]}}" --aapt2="$runfiles/{aapt2}" --ks="$runfiles/{keystore}" --ks-pass=pass:{password} \\
  --ks-key-alias={alias} --key-pass=pass:{password}
bundletool install-apks --apks="$work/app.apks" --adb="$adb" "${{device[@]}}"
{reverse}"$adb" shell monkey -p "{package}" -c android.intent.category.LAUNCHER 1 >/dev/null
echo "Launched {package} from its app bundle"
"""

def _android_install_bundle_impl(ctx):
    info = ctx.attr.apk[AndroidApkInfo]
    runtime = ctx.attr._jdk[java_common.JavaRuntimeInfo]
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    classpath = ":".join(['$runfiles/' + _rlocation(ctx.workspace_name, f.short_path) for f in ctx.files._bundletool_classpath])
    adb = _rlocation(ctx.workspace_name, ctx.file._adb.short_path)
    ctx.actions.write(script, _INSTALL_BUNDLE_SCRIPT.format(
        name = ctx.attr.apk.label.name,
        java = _rlocation(ctx.workspace_name, runtime.java_executable_runfiles_path),
        classpath = classpath,
        adb = adb,
        aapt2 = _rlocation(ctx.workspace_name, ctx.file._aapt2.short_path),
        aab = _rlocation(ctx.workspace_name, info.aab.short_path),
        keystore = _rlocation(ctx.workspace_name, ctx.file.keystore.short_path),
        password = ctx.attr.keystore_password,
        alias = ctx.attr.key_alias,
        package = ctx.attr.package,
        reverse = "".join(['"$adb" reverse tcp:{0} tcp:{0}\n'.format(p) for p in ctx.attr.reverse_ports]),
    ), is_executable = True)
    runfiles = ctx.runfiles(
        files = [info.aab, ctx.file.keystore, ctx.file._adb, ctx.file._aapt2] + ctx.files._bundletool_classpath,
        transitive_files = runtime.files,
    )
    return [DefaultInfo(executable = script, runfiles = runfiles)]

android_install_bundle = rule(
    implementation = _android_install_bundle_impl,
    doc = "`bazel run` target that installs an app from its .aab through bundletool, as Play would deliver it.",
    executable = True,
    attrs = {
        "apk": attr.label(providers = [AndroidApkInfo], mandatory = True),
        "key_alias": attr.string(mandatory = True),
        "keystore": attr.label(allow_single_file = True, mandatory = True),
        "keystore_password": attr.string(mandatory = True),
        "package": attr.string(mandatory = True),
        "reverse_ports": attr.int_list(),
        # The Maven build of bundletool doesn't embed aapt2, which build-apks needs.
        "_aapt2": attr.label(default = "@rn_android_sdk//:aapt2", allow_single_file = True),
        "_adb": attr.label(default = "@rn_android_sdk//:adb", allow_single_file = True),
        "_bundletool_classpath": attr.label(default = "@rn_bundletool_maven//:all"),
        "_jdk": attr.label(default = "@rules_java//toolchains:remotejdk_21", providers = [java_common.JavaRuntimeInfo]),
    },
)
