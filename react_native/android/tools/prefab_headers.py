"""Copies a library's headers into one flat include directory, as its Gradle prefab publication does.

Libraries such as react-native-nitro-modules publish headers that live in several source
directories under one prefix (`#include <NitroModules/HybridObject.hpp>`): a Gradle Copy task
flattens every header below those directories into `<prefix>/`. This does the same.
"""

import argparse
import os
import shutil
import sys
from typing import Final

HEADER_EXTENSIONS: Final = (".h", ".hpp")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out",
        required=True,
        help="Directory to create; headers land in <out>/<prefix>/.",
    )
    parser.add_argument(
        "--dir",
        action="append",
        default=[],
        metavar="PREFIX=DIR",
        help="Copy every header below DIR (recursively) to <out>/PREFIX/<basename>. Later ones win.",
    )
    args = parser.parse_args()
    for spec in args.dir:
        prefix, sep, src = spec.partition("=")
        if not sep:
            parser.error(f"--dir takes PREFIX=DIR, got {spec!r}")
        if not os.path.isdir(src):
            print(f"prefab_headers: {src} is not a directory", file=sys.stderr)
            return 1
        dest = os.path.join(args.out, prefix)
        os.makedirs(dest, exist_ok=True)
        for root, dirs, files in os.walk(src):
            dirs.sort()
            for name in sorted(files):
                if name.endswith(HEADER_EXTENSIONS):
                    shutil.copyfile(os.path.join(root, name), os.path.join(dest, name))
    os.makedirs(args.out, exist_ok=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
