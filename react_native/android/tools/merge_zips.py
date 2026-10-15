"""Merges zips (e.g. aapt2 .flata archives of several res/ directories) into one, reproducibly.

Later inputs win on duplicate entry names, like overlays.
"""

import argparse
import sys
import zipfile
from typing import Final

ZIP_EPOCH: Final = (1980, 1, 1, 0, 0, 0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True)
    parser.add_argument("inputs", nargs="+")
    args = parser.parse_args()
    entries: dict[str, bytes] = {}
    for path in args.inputs:
        with zipfile.ZipFile(path) as z:
            for name in z.namelist():
                if not name.endswith("/"):
                    entries[name] = z.read(name)
    with zipfile.ZipFile(args.out, "w") as out:
        for name in sorted(entries):
            info = zipfile.ZipInfo(name, ZIP_EPOCH)
            info.compress_type = zipfile.ZIP_DEFLATED
            out.writestr(info, entries[name])
    return 0


if __name__ == "__main__":
    sys.exit(main())
