"""Assembles an unsigned, unaligned APK from linked resources, dex, native libraries and assets.

Entries are written in a fixed order with fixed timestamps so the output is reproducible. Native
libraries, resources.arsc and the JS bundle are stored uncompressed: Android requires the first two
to be mmap-able from the APK (targetSdk >= 30 for resources.arsc, extractNativeLibs=false for .so),
and React Native reads the bundle through the AssetManager, which can mmap stored assets.
"""

import argparse
import sys
import zipfile
from typing import Final

ZIP_EPOCH: Final = (1980, 1, 1, 0, 0, 0)
STORED_SUFFIXES: Final = (".so", ".arsc", ".bundle", ".hbc")
SKIPPED_JAVA_RESOURCES: Final = ("META-INF/MANIFEST.MF", "module-info.class")
SIGNATURE_SUFFIXES: Final = (".SF", ".RSA", ".DSA", ".EC")


class ApkWriter:
    def __init__(self, path: str) -> None:
        self._zip = zipfile.ZipFile(path, "w")
        self._names: set[str] = set()

    def add(self, name: str, data: bytes, *, compress: bool | None = None) -> None:
        if name in self._names:
            return
        self._names.add(name)
        info = zipfile.ZipInfo(name, ZIP_EPOCH)
        if compress is None:
            compress = not name.endswith(STORED_SUFFIXES)
        info.compress_type = zipfile.ZIP_DEFLATED if compress else zipfile.ZIP_STORED
        info.external_attr = 0o644 << 16
        self._zip.writestr(info, data)

    def close(self) -> None:
        self._zip.close()


def _is_java_resource(name: str) -> bool:
    if name.endswith("/") or name.endswith(".class") or name in SKIPPED_JAVA_RESOURCES:
        return False
    if name.startswith("META-INF/") and name.endswith(SIGNATURE_SUFFIXES):
        return False
    return not name.startswith("META-INF/versions/")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, fromfile_prefix_chars="@")
    parser.add_argument(
        "--resources", required=True, help="APK written by `aapt2 link`"
    )
    parser.add_argument(
        "--dex", required=True, help="Zip of classes*.dex written by d8"
    )
    parser.add_argument(
        "--native_lib",
        action="append",
        default=[],
        metavar="ABI/NAME=FILE",
        help="Shared library to place under lib/",
    )
    parser.add_argument(
        "--asset",
        action="append",
        default=[],
        metavar="PATH=FILE",
        help="File to place under assets/",
    )
    parser.add_argument(
        "--java_resources_from",
        action="append",
        default=[],
        help="Jar whose non-class files ship in the APK",
    )
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    apk = ApkWriter(args.out)
    with zipfile.ZipFile(args.resources) as res:
        # AndroidManifest.xml first keeps the layout identical to what aapt2/AGP produce.
        for info in sorted(
            res.infolist(),
            key=lambda i: (i.filename != "AndroidManifest.xml", i.filename),
        ):
            apk.add(
                info.filename,
                res.read(info),
                compress=info.compress_type != zipfile.ZIP_STORED,
            )
    with zipfile.ZipFile(args.dex) as dex:
        for name in sorted(n for n in dex.namelist() if n.endswith(".dex")):
            apk.add(name, dex.read(name))
    # fbjni and react-android both ship libc++_shared.so and libfbjni.so. Identical copies are
    # expected; differing ones would load whichever won, so refuse rather than guess.
    native_libs: dict[str, tuple[str, bytes]] = {}
    for entry in args.native_lib:
        path, src = entry.split("=", 1)
        with open(src, "rb") as f:
            data = f.read()
        if path in native_libs:
            if native_libs[path][1] != data:
                print(
                    f"error: lib/{path} differs between {native_libs[path][0]} and {src}",
                    file=sys.stderr,
                )
                return 1
            continue
        native_libs[path] = (src, data)
    for path in sorted(native_libs):
        apk.add("lib/" + path, native_libs[path][1], compress=False)
    for entry in sorted(args.asset):
        path, src = entry.split("=", 1)
        with open(src, "rb") as f:
            apk.add("assets/" + path, f.read())
    for jar in args.java_resources_from:
        with zipfile.ZipFile(jar) as j:
            for name in j.namelist():
                if _is_java_resource(name):
                    apk.add(name, j.read(name))
    apk.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
