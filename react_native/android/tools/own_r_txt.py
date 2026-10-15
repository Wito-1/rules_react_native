"""Writes the R.txt of a library's own resources: everything aapt2 linked minus its deps' symbols.

`aapt2 link --static-lib` needs the dependencies' resources to resolve references, so its R.txt
covers them too. The app generates one R class per package from these lists, and each library's
class should only declare what that library defines, as AGP's non-transitive R classes do.
"""

import argparse
import sys


def _key(line: str) -> tuple[str, str] | None:
    parts = line.split(" ", 3)
    return (parts[1], parts[2]) if len(parts) == 4 else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, fromfile_prefix_chars="@")
    parser.add_argument("--linked", required=True, help="R.txt from the static-lib link")
    parser.add_argument("--dep", action="append", default=[], help="A dependency's R.txt")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    theirs: set[tuple[str, str]] = set()
    for dep in args.dep:
        with open(dep) as f:
            theirs.update(k for k in map(_key, f) if k)
    with open(args.linked) as f, open(args.out, "w") as out:
        for line in f:
            key = _key(line)
            if key and key not in theirs:
                out.write(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
