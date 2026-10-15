"""Checks that an APK is installable and complete without a device.

Runs the SDK's own verifiers (aapt2 for the manifest, zipalign for 16 KiB page alignment,
apksigner for the signature) and checks the archive layout React Native needs at startup. With
--aab it also validates the app bundle with bundletool and checks that it carries the same
content plus the native debug symbols Play reads from its metadata.
"""

import argparse
import re
import subprocess
import sys
import zipfile


def _run(cmd: list[str]) -> tuple[int, str]:
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode, result.stdout + result.stderr


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", required=True)
    parser.add_argument("--aapt2", required=True)
    parser.add_argument("--zipalign", required=True)
    parser.add_argument("--java", required=True)
    parser.add_argument("--apksigner", required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--abi", action="append", default=[])
    parser.add_argument(
        "--native_lib", action="append", default=[], help="Library every ABI must ship"
    )
    parser.add_argument(
        "--asset",
        action="append",
        default=[],
        help="Path under assets/ that must exist",
    )
    parser.add_argument("--entry", action="append", default=[], help="Any other path that must exist in the APK")
    parser.add_argument("--aab", help="The app's bundle, checked as well")
    parser.add_argument("--bundletool_classpath", action="append", default=[])
    args = parser.parse_args()

    failures: list[str] = []

    code, out = _run([args.aapt2, "dump", "badging", args.apk])
    if code:
        failures.append(f"aapt2 dump badging failed:\n{out}")
    else:
        match = re.search(r"package: name='([^']+)'", out)
        if not match or match.group(1) != args.package:
            failures.append(
                f"manifest package is {match.group(1) if match else None!r}, expected {args.package!r}"
            )

    code, out = _run([args.zipalign, "-c", "-P", "16", "4", args.apk])
    if code:
        failures.append(
            f"zipalign -c -P 16 failed (native libraries must be 16 KiB aligned):\n{out}"
        )

    code, out = _run(
        [
            args.java,
            "-cp",
            args.apksigner,
            "com.android.apksigner.ApkSignerTool",
            "verify",
            args.apk,
        ]
    )
    if code:
        failures.append(f"apksigner verify failed:\n{out}")

    with zipfile.ZipFile(args.apk) as apk:
        infos = {i.filename: i for i in apk.infolist()}
    for required in ("AndroidManifest.xml", "resources.arsc", "classes.dex"):
        if required not in infos:
            failures.append(f"missing {required}")
    if (
        "resources.arsc" in infos
        and infos["resources.arsc"].compress_type != zipfile.ZIP_STORED
    ):
        failures.append(
            "resources.arsc is compressed; Android 11+ refuses to install that"
        )
    abis = {
        name.split("/")[1]
        for name in infos
        if name.startswith("lib/") and name.count("/") == 2
    }
    if abis != set(args.abi):
        failures.append(f"APK ships ABIs {sorted(abis)}, expected {sorted(args.abi)}")
    for abi in args.abi:
        for lib in args.native_lib:
            info = infos.get(f"lib/{abi}/{lib}")
            if info is None:
                failures.append(f"missing lib/{abi}/{lib}")
            elif info.compress_type != zipfile.ZIP_STORED:
                failures.append(
                    f"lib/{abi}/{lib} is compressed; it must be stored to load in place"
                )
    for asset in args.asset:
        if f"assets/{asset}" not in infos:
            failures.append(f"missing assets/{asset}")
    for entry in args.entry:
        if entry not in infos:
            failures.append(f"missing {entry}")

    if args.aab:
        failures.extend(_check_bundle(args))

    if failures:
        print(f"{args.apk}: {len(failures)} problem(s)", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print(f"{args.apk}: OK ({len(infos)} entries, ABIs {sorted(abis)})")
    return 0


def _check_bundle(args: argparse.Namespace) -> list[str]:
    failures = []
    code, out = _run(
        [
            args.java,
            "-cp",
            ":".join(args.bundletool_classpath),
            "com.android.tools.build.bundletool.BundleToolMain",
            "validate",
            "--bundle=" + args.aab,
        ]
    )
    if code:
        failures.append(f"bundletool validate failed:\n{out}")
    with zipfile.ZipFile(args.aab) as aab:
        names = set(aab.namelist())
    for required in ("base/manifest/AndroidManifest.xml", "base/resources.pb", "base/dex/classes.dex"):
        if required not in names:
            failures.append(f"bundle is missing {required}")
    for abi in args.abi:
        for lib in args.native_lib:
            if f"base/lib/{abi}/{lib}" not in names:
                failures.append(f"bundle is missing base/lib/{abi}/{lib}")
        symbols = f"BUNDLE-METADATA/com.android.tools.build.debugsymbols/{abi}/libappmodules.so.dbg"
        if symbols not in names:
            failures.append(f"bundle is missing {symbols}")
    for asset in args.asset:
        if f"base/assets/{asset}" not in names:
            failures.append(f"bundle is missing base/assets/{asset}")
    return failures


if __name__ == "__main__":
    sys.exit(main())
