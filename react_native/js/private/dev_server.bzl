"""Metro dev server for debug builds of a React Native app."""

load("@aspect_rules_js//js:defs.bzl", "js_run_devserver")

def react_native_dev_server(name, srcs, node_modules, port = 8081, **kwargs):
    """`bazel run` target serving this package's JS from Metro, like `react-native start`.

    Pair it with a `react_native_android_app(debug = True)`, whose `.install` target runs
    `adb reverse` for `port`. Run it under `ibazel run` so edits sync into the server's sandbox and
    reach the app through Fast Refresh; plain `bazel run` serves a snapshot.

    Args:
        name: Target name.
        srcs: The app's JS/TS sources, package.json, babel.config.js and metro.config.js if present.
        node_modules: The package's `npm_link_all_packages` target.
        port: Port to serve on; must match the app (8081 unless changed in native code).
        **kwargs: Common attributes.
    """
    js_run_devserver(
        name = name,
        tool = Label("//react_native/js:dev_server"),
        data = srcs + [node_modules],
        chdir = native.package_name(),
        args = ["--port=%d" % port],
        **kwargs
    )
