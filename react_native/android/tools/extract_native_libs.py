"""Extracts a library's prebuilt native libraries from an archive in its npm package.

expo-modules-core ships `android/prebuilt/native-libs.tar.xz` laid out as
`<variant>/<abi>/lib*.so`; its Gradle build packages the matching variant instead of building the
C++ itself. This writes `<out_dir>/<abi>/<lib>` for every requested ABI and library.
"""

import argparse
import os
import shutil
import sys
import tarfile


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, help=".tar, .tar.gz or .tar.xz")
    parser.add_argument(
        "--variant", required=True, help="Top-level directory, e.g. release"
    )
    parser.add_argument("--abi", action="append", required=True)
    parser.add_argument(
        "--lib", action="append", required=True, help="File name, e.g. libfoo.so"
    )
    parser.add_argument("--out_dir", required=True)
    args = parser.parse_args()

    wanted = {
        f"{args.variant}/{abi}/{lib}": (abi, lib)
        for abi in args.abi
        for lib in args.lib
    }
    found = set()
    with tarfile.open(args.archive) as tar:
        for member in tar:
            name = member.name.removeprefix("./")
            if name not in wanted or not member.isfile():
                continue
            abi, lib = wanted[name]
            dest = os.path.join(args.out_dir, abi, lib)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            src = tar.extractfile(member)
            assert src is not None
            with src, open(dest, "wb") as out:
                shutil.copyfileobj(src, out)
            found.add(name)
    missing = sorted(set(wanted) - found)
    if missing:
        print(
            f"extract_native_libs: {args.archive} has no {', '.join(missing)}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
