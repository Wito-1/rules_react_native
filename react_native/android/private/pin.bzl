"""`bazel run` target that re-resolves a package's Maven specs into lockfiles."""

_SCRIPT = """\
#!/usr/bin/env bash
set -euo pipefail
export RUNFILES_DIR="${{RUNFILES_DIR:-$0.runfiles}}"
exec "$RUNFILES_DIR/{tool}" {args} "$@"
"""

def _rlocation(ctx, f):
    if f.short_path.startswith("../"):
        return f.short_path[len("../"):]
    return ctx.workspace_name + "/" + f.short_path

def _join(pkg, path):
    return pkg + "/" + path if pkg else path

def _react_native_maven_pin_impl(ctx):
    tool = ctx.executable._resolver
    pins = [
        "'--pin=%s=%s'" % (_join(ctx.label.package, spec), _join(ctx.label.package, lock))
        for spec, lock in sorted(ctx.attr.pins.items())
    ]
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(script, _SCRIPT.format(tool = _rlocation(ctx, tool), args = " ".join(pins)), is_executable = True)
    runfiles = ctx.runfiles(files = [tool]).merge(ctx.attr._resolver[DefaultInfo].default_runfiles)
    return [DefaultInfo(executable = script, runfiles = runfiles)]

react_native_maven_pin = rule(
    implementation = _react_native_maven_pin_impl,
    executable = True,
    doc = """Resolves Maven specs into the lockfiles `react_native.maven` reads.

A spec is JSON: `{"artifacts": ["com.facebook.react:react-android:0.86.3", ...],
"build_type": "release" | "debug", "excludes": []}`. Resolution follows Gradle module metadata
(KMP redirects, build-type variants, dependency constraints), and hashes already in a lockfile are
reused, so re-pinning only downloads what changed.""",
    attrs = {
        "pins": attr.string_dict(mandatory = True, doc = "Spec file -> lockfile, both relative to this package."),
        "_resolver": attr.label(
            default = "//react_native/android/tools:maven_resolve",
            executable = True,
            cfg = "target",
        ),
    },
)
