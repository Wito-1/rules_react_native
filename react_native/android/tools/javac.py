"""Compiles Android Java and Kotlin sources into a reproducible jar with a pinned JDK.

The rules run javac (and kotlinc, on the same JDK) directly instead of through rules_java's or
rules_kotlin's toolchains, so consumers don't have to point `--java_runtime_version` at a hermetic
JDK just to build an app. Mixed sources compile as Gradle's Kotlin plugin does: kotlinc first, seeing
the Java sources for symbol resolution only, then javac against kotlinc's classes.
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
            if name.endswith((".java", ".kt")):
                z.extract(name, dest)
                files.append(os.path.join(dest, name))
    return files


def _is_excluded(rel: str, excluded_r: list[str]) -> bool:
    for package in excluded_r:
        prefix = package.replace(".", "/") + "/R"
        if rel == prefix + ".class" or rel.startswith(prefix + "$"):
            return True
    return False


def _write_argfile(path: str, args: list[str]) -> None:
    with open(path, "w") as f:
        for arg in args:
            f.write('"' + arg.replace("\\", "\\\\").replace('"', '\\"') + '"\n')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, fromfile_prefix_chars="@")
    parser.add_argument("--javac", required=True)
    parser.add_argument("--java", help="JVM that runs kotlinc; required with Kotlin sources")
    parser.add_argument(
        "--kotlinc_classpath",
        action="append",
        default=[],
        help="kotlin-compiler-embeddable and its runtime closure",
    )
    parser.add_argument(
        "--module_name", default="main", help="Kotlin module (META-INF/*.kotlin_module)"
    )
    parser.add_argument("--kotlincopt", action="append", default=[])
    parser.add_argument("--src", action="append", default=[], help=".java or .kt source")
    parser.add_argument(
        "--srcjar", action="append", default=[], help="Zip of .java sources"
    )
    parser.add_argument(
        "--srcdir",
        action="append",
        default=[],
        help="Directory of .java/.kt sources, e.g. inside an npm package",
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
                    os.path.join(root, n)
                    for n in sorted(names)
                    if n.endswith((".java", ".kt"))
                )
        java_sources = [s for s in sources if s.endswith(".java")]
        kotlin_sources = [s for s in sources if s.endswith(".kt")]
        classpath = list(args.classpath)
        class_dirs = []

        if kotlin_sources:
            if not args.java or not args.kotlinc_classpath:
                print(
                    "javac.py: Kotlin sources need --java and --kotlinc_classpath",
                    file=sys.stderr,
                )
                return 1
            kotlin_classes = os.path.join(work, "kotlin_classes")
            os.makedirs(kotlin_classes)
            argfile = os.path.join(work, "kotlinc.args")
            _write_argfile(
                argfile,
                [
                    # android.jar (first on the classpath) replaces the JDK; the stdlib comes from
                    # the deps, so the app dexes the one version React Native pins.
                    "-no-jdk",
                    "-no-stdlib",
                    "-no-reflect",
                    "-jvm-target",
                    "17",
                    "-module-name",
                    args.module_name,
                    "-classpath",
                    os.pathsep.join(classpath),
                    "-d",
                    kotlin_classes,
                    *args.kotlincopt,
                    *kotlin_sources,
                    *java_sources,
                ],
            )
            result = subprocess.run(
                [
                    args.java,
                    # The compiler otherwise looks for an IntelliJ home and a daemon.
                    "-Didea.io.use.nio2=true",
                    "-Dkotlin.environment.keepalive=false",
                    "-Xss8m",
                    "-cp",
                    os.pathsep.join(args.kotlinc_classpath),
                    "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
                    "@" + argfile,
                ]
            )
            if result.returncode != 0:
                return result.returncode
            classpath.append(kotlin_classes)
            class_dirs.append(kotlin_classes)

        classes = os.path.join(work, "classes")
        os.makedirs(classes)
        class_dirs.append(classes)
        if java_sources:
            argfile = os.path.join(work, "javac.args")
            _write_argfile(
                argfile,
                [
                    "-encoding",
                    "UTF-8",
                    # Android code compiles against android.jar, not a JDK's system modules.
                    "-Xlint:-options",
                    "-proc:none",
                    "-implicit:none",
                    "-classpath",
                    os.pathsep.join(classpath),
                    "-d",
                    classes,
                    *args.javacopt,
                    *java_sources,
                ],
            )
            result = subprocess.run([args.javac, "@" + argfile])
            if result.returncode != 0:
                return result.returncode
        entries = {}
        for class_dir in class_dirs:
            for root, _, names in os.walk(class_dir):
                for n in names:
                    path = os.path.join(root, n)
                    rel = os.path.relpath(path, class_dir).replace(os.sep, "/")
                    if not _is_excluded(rel, args.exclude_r):
                        entries[rel] = path
        with zipfile.ZipFile(args.out, "w") as jar:
            for rel, path in sorted(entries.items()):
                info = zipfile.ZipInfo(rel, ZIP_EPOCH)
                info.compress_type = zipfile.ZIP_DEFLATED
                with open(path, "rb") as f:
                    jar.writestr(info, f.read())
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
