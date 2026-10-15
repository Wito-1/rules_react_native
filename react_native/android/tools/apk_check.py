"""Checks that an APK is installable and complete without a device.

Runs the SDK's own verifiers (aapt2 for the manifest, zipalign for 16 KiB page alignment,
apksigner for the signature) and checks the archive layout React Native needs at startup.
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

    if failures:
        print(f"{args.apk}: {len(failures)} problem(s)", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print(f"{args.apk}: OK ({len(infos)} entries, ABIs {sorted(abis)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
