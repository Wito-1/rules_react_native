"""Writes a srcjar with the R classes of an app and of every Android library it links.

AAR classes.jar files are compiled against non-final R fields that do not exist until the app's
resources are linked, so every library package needs its own R class carrying the final ids. Each
library R only declares the symbols listed in that library's R.txt, which keeps the dex small
(an R class per package with every app symbol would multiply the field count by the number of
libraries).

With --compile_only it instead writes the R classes a library compiles against: one per
dependency package, from the dependency's own R.txt, with non-final fields so no id is inlined
(AGP's compile-time R jars). The library leaves them out of its jar; the app writes the real ones.
"""

import argparse
import dataclasses
import sys
import zipfile
from typing import Final

ZIP_EPOCH: Final = (1980, 1, 1, 0, 0, 0)


@dataclasses.dataclass(frozen=True)
class Symbol:
    java_type: str
    res_type: str
    name: str
    value: str


def parse_r_txt(path: str) -> list[Symbol]:
    symbols = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            java_type, res_type, name, value = line.split(" ", 3)
            symbols.append(Symbol(java_type, res_type, name, value))
    return symbols


def render(package: str, symbols: list[Symbol], final: bool = True) -> str:
    by_type: dict[str, list[Symbol]] = {}
    for s in symbols:
        by_type.setdefault(s.res_type, []).append(s)
    lines = [f"package {package};", "", "public final class R {"]
    for res_type in sorted(by_type):
        lines.append(f"  public static final class {res_type} {{")
        for s in sorted(by_type[res_type], key=lambda s: s.name):
            value = s.value
            if s.java_type == "int[]":
                value = "new int[] " + value
            modifiers = "public static final" if final else "public static"
            lines.append(f"    {modifiers} {s.java_type} {s.name} = {value};")
        lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def write_entry(out: zipfile.ZipFile, name: str, data: str) -> None:
    info = zipfile.ZipInfo(name, ZIP_EPOCH)
    info.compress_type = zipfile.ZIP_DEFLATED
    out.writestr(info, data)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--r_txt",
        help="R.txt written by `aapt2 link --output-text-symbols`",
    )
    parser.add_argument("--package", help="App package; its R gets every symbol")
    parser.add_argument(
        "--compile_only",
        action="store_true",
        help="Write each --library's R from its own R.txt, non-final, for compiling a library",
    )
    parser.add_argument(
        "--library",
        action="append",
        default=[],
        metavar="PACKAGE=R_TXT",
        help="Library package and the R.txt it shipped in its AAR",
    )
    parser.add_argument(
        "--java",
        action="append",
        default=[],
        metavar="PATH_IN_SRCJAR=FILE",
        help="Extra generated Java source to add to the srcjar",
    )
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    sources: dict[str, str] = {}
    if args.compile_only:
        for entry in args.library:
            package, r_txt = entry.split("=", 1)
            sources.setdefault(package, render(package, parse_r_txt(r_txt), final=False))
        _write(args.out, sources, [])
        return 0
    if not args.r_txt or not args.package:
        parser.error("--r_txt and --package are required without --compile_only")

    final = parse_r_txt(args.r_txt)
    final_by_key = {(s.res_type, s.name): s for s in final}

    sources[args.package] = render(args.package, final)
    for entry in args.library:
        package, r_txt = entry.split("=", 1)
        if package in sources:
            continue
        wanted = parse_r_txt(r_txt)
        symbols = [
            final_by_key[(s.res_type, s.name)]
            for s in wanted
            if (s.res_type, s.name) in final_by_key
        ]
        missing = len(wanted) - len(symbols)
        if missing:
            print(
                f"warning: {package}: {missing} R.txt symbols missing from the linked app",
                file=sys.stderr,
            )
        sources[package] = render(package, symbols)

    _write(args.out, sources, args.java)
    return 0


def _write(path: str, sources: dict[str, str], java: list[str]) -> None:
    with zipfile.ZipFile(path, "w") as out:
        for package in sorted(sources):
            write_entry(out, package.replace(".", "/") + "/R.java", sources[package])
        for entry in sorted(java):
            src_path, src = entry.split("=", 1)
            with open(src) as f:
                write_entry(out, src_path, f.read())


if __name__ == "__main__":
    sys.exit(main())
