"""Compiles Android Java sources into a reproducible jar with a pinned JDK's javac.

The rules run javac directly instead of through rules_java's toolchain, so consumers don't have to
point `--java_runtime_version` at a hermetic JDK just to build an app.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from typing import Final

ZIP_EPOCH: Final = (1980, 1, 1, 0, 0, 0)


def _extract_srcjar(srcjar: str, dest: str) -> list[str]:
    files = []
    with zipfile.ZipFile(srcjar) as z:
        for name in z.namelist():
            if name.endswith(".java"):
                z.extract(name, dest)
                files.append(os.path.join(dest, name))
    return files


def _is_excluded(rel: str, excluded_r: list[str]) -> bool:
    for package in excluded_r:
        prefix = package.replace(".", "/") + "/R"
        if rel == prefix + ".class" or rel.startswith(prefix + "$"):
            return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, fromfile_prefix_chars="@")
    parser.add_argument("--javac", required=True)
    parser.add_argument("--src", action="append", default=[], help=".java source")
    parser.add_argument(
        "--srcjar", action="append", default=[], help="Zip of .java sources"
    )
    parser.add_argument(
        "--srcdir", action="append", default=[], help="Directory of .java sources"
    )
    parser.add_argument("--classpath", action="append", default=[])
    parser.add_argument("--javacopt", action="append", default=[])
    parser.add_argument(
        "--exclude_r",
        action="append",
        default=[],
        metavar="PACKAGE",
        help="Drop PACKAGE.R classes from the jar: a library compiles against placeholder ids the app regenerates",
    )
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    work = tempfile.mkdtemp(prefix="rn-javac-")
    try:
        sources = list(args.src)
        for i, srcjar in enumerate(args.srcjar):
            sources.extend(_extract_srcjar(srcjar, os.path.join(work, f"srcjar{i}")))
        for srcdir in args.srcdir:
            for root, _, names in os.walk(srcdir):
                sources.extend(
                    os.path.join(root, n) for n in names if n.endswith(".java")
                )
        classes = os.path.join(work, "classes")
        os.makedirs(classes)
        if sources:
            argfile = os.path.join(work, "javac.args")
            with open(argfile, "w") as f:
                for arg in [
                    "-encoding",
                    "UTF-8",
                    # Android code compiles against android.jar, not a JDK's system modules.
                    "-Xlint:-options",
                    "-proc:none",
                    "-implicit:none",
                    "-classpath",
                    os.pathsep.join(args.classpath),
                    "-d",
                    classes,
                    *args.javacopt,
                    *sources,
                ]:
                    f.write('"' + arg.replace("\\", "\\\\").replace('"', '\\"') + '"\n')
            result = subprocess.run([args.javac, "@" + argfile])
            if result.returncode != 0:
                return result.returncode
        entries = []
        for root, _, names in os.walk(classes):
            for n in names:
                path = os.path.join(root, n)
                rel = os.path.relpath(path, classes).replace(os.sep, "/")
                if not _is_excluded(rel, args.exclude_r):
                    entries.append((rel, path))
        with zipfile.ZipFile(args.out, "w") as jar:
            for rel, path in sorted(entries):
                info = zipfile.ZipInfo(rel, ZIP_EPOCH)
                info.compress_type = zipfile.ZIP_DEFLATED
                with open(path, "rb") as f:
                    jar.writestr(info, f.read())
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
