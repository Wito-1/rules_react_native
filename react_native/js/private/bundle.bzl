"""Bundles a React Native app's JavaScript with Metro and compiles it to Hermes bytecode."""

load("@aspect_rules_js//js:defs.bzl", "js_run_binary")

def _react_native_bundle_info_impl(ctx):
    files = ctx.attr.build[DefaultInfo].files.to_list()
    return [
        DefaultInfo(files = depset([f for f in files if not f.is_directory])),
        OutputGroupInfo(assets = depset([f for f in files if f.is_directory])),
    ]

_react_native_bundle_info = rule(
    implementation = _react_native_bundle_info_impl,
    doc = "Splits the bundler's outputs: the bundle file by default, the asset directory as output group `assets`.",
    attrs = {
        "build": attr.label(mandatory = True, doc = "The js_run_binary that ran the bundler."),
    },
)

def react_native_bundle(name, srcs, node_modules, entry_point = "index.js", platform = "android", dev = False, hermes = True, **kwargs):
    """Bundles the app rooted at this package with Metro, as `react-native bundle` would.

    The default output is `index.<platform>.bundle` (Hermes bytecode unless `hermes = False`); the
    output group `assets` is the directory of image assets Metro wrote (Android `drawable-*` resource layout for "android", the iOS asset layout for "ios").

    Args:
        name: Target name.
        srcs: JS/TS sources plus package.json, babel.config.js and metro.config.js if present.
        node_modules: The package's `npm_link_all_packages` target (e.g. ":node_modules").
        entry_point: Entry file relative to this package.
        platform: "android" or "ios".
        dev: Builds a development bundle (__DEV__ true, unoptimized).
        hermes: Compiles the bundle to Hermes bytecode.
        **kwargs: Common attributes.
    """
    pkg = native.package_name()
    bundle = "{}/index.{}.bundle".format(name, platform)
    assets = "{}/assets".format(name)
    args = [
        "--project-root=" + (pkg or "."),
        "--entry=" + entry_point,
        "--platform=" + platform,
        "--bundle-out={}/{}".format(pkg, bundle) if pkg else "--bundle-out=" + bundle,
        "--assets-dest={}/{}".format(pkg, assets) if pkg else "--assets-dest=" + assets,
    ]
    if dev:
        args.append("--dev")
    if not hermes:
        args.append("--no-hermes")
    js_run_binary(
        name = name + "_build",
        tool = Label("//react_native/js:bundler"),
        srcs = srcs + [node_modules],
        outs = [bundle],
        out_dirs = [assets],
        args = args,
        mnemonic = "ReactNativeBundle",
        progress_message = "Bundling React Native app %{label}",
        **kwargs
    )
    _react_native_bundle_info(
        name = name,
        build = name + "_build",
        **kwargs
    )
