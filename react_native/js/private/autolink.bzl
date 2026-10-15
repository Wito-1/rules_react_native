"""Generates react_native_npm_library targets for an app's native npm dependencies."""

load("@aspect_rules_js//js:defs.bzl", "js_binary", "js_test")

def react_native_autolink(name, node_modules, package_json = "package.json", out = "react_native_libraries.bzl", maven = "@rn_maven", **kwargs):
    """Autolinking for Bazel: `bazel run :<name>` writes `out`, a macro declaring the app's native npm libraries.

    For every dependency in `package_json` that ships Android code, the generated
    `react_native_libraries()` declares a `react_native_npm_library` (plus `react_native_codegen` for
    its `codegenConfig`) and returns their labels:

    ```starlark
    load(":react_native_libraries.bzl", "react_native_libraries")

    react_native_android_app(name = "app", deps = react_native_libraries(), ...)
    ```

    It reads what Gradle's autolinking reads: the package's `codegenConfig`, its
    `react-native.config.js` (`libraryName`, `componentDescriptors`, `cmakeListsPath`,
    `packageImportPath`, `cxxModuleHeaderName`) and `android/build.gradle` (`namespace`,
    `buildConfigField`, `consumerProguardFiles`). Libraries that need more go in BUILD by hand.
    `<name>_test` fails while `out` is stale.

    Args:
        name: Target name of the generator; the test is `<name>_test`.
        node_modules: The app's `npm_link_all_packages` target.
        package_json: The app's package.json; its `dependencies` are scanned.
        out: Generated file, in this package.
        maven: The consumer's release Maven repository (a `react_native.maven` name), the default
            for `react_native_libraries(maven = ...)`. Libraries compile against their Gradle Maven
            dependencies from it; `bazel run :<name>` lists the ones the spec must pin.
        **kwargs: Common attributes.
    """
    pkg = native.package_name()
    label = "//%s:%s" % (pkg, name)
    common_args = [
        "--package-json=$(rootpath %s)" % package_json,
        "--label=" + label,
        "--maven=" + maven,
    ]
    js_binary(
        name = name,
        entry_point = Label("//react_native/js:autolink"),
        data = [node_modules, package_json],
        args = common_args + ["--out=%s" % (pkg + "/" + out if pkg else out)],
        **kwargs
    )
    js_test(
        name = name + "_test",
        entry_point = Label("//react_native/js:autolink"),
        data = [node_modules, package_json, out],
        args = common_args + ["--check=$(rootpath %s)" % out],
        **kwargs
    )
