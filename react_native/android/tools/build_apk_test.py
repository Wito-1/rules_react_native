import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

import build_apk


def _write_zip(path: Path, entries: dict[str, bytes], stored: frozenset[str] = frozenset()) -> Path:
    with zipfile.ZipFile(path, "w") as z:
        for name, data in entries.items():
            z.writestr(name, data, compress_type=zipfile.ZIP_STORED if name in stored else zipfile.ZIP_DEFLATED)
    return path


class BuildApkTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.resources = _write_zip(
            self.tmp / "res.ap_",
            {"res/layout/a.xml": b"<a/>", "AndroidManifest.xml": b"manifest", "resources.arsc": b"arsc"},
            stored=frozenset({"resources.arsc"}),
        )
        self.dex = _write_zip(self.tmp / "dex.zip", {"classes.dex": b"dex1", "classes2.dex": b"dex2"})
        self.jar = _write_zip(
            self.tmp / "lib.jar",
            {
                "com/x/A.class": b"cls",
                "META-INF/MANIFEST.MF": b"mf",
                "META-INF/CERT.SF": b"sig",
                "okhttp3/publicsuffixes.gz": b"psl",
            },
        )

    def _file(self, name: str, data: bytes) -> Path:
        path = self.tmp / name
        path.write_bytes(data)
        return path

    def _build(self, extra: list[str]) -> tuple[int, Path]:
        out = self.tmp / "out.apk"
        sys.argv = [
            "build_apk",
            f"--resources={self.resources}",
            f"--dex={self.dex}",
            f"--java_resources_from={self.jar}",
            f"--out={out}",
            *extra,
        ]
        return build_apk.main(), out

    def test_layout_and_compression(self) -> None:
        so = self._file("libfoo.so", b"\x7fELF")
        bundle = self._file("index.android.bundle", b"hbc")
        status, out = self._build([f"--native_lib=x86_64/libfoo.so={so}", f"--asset=index.android.bundle={bundle}"])
        self.assertEqual(status, 0)
        with zipfile.ZipFile(out) as z:
            infos = {i.filename: i for i in z.infolist()}
            self.assertEqual(z.namelist()[0], "AndroidManifest.xml")
            self.assertEqual(
                set(infos),
                {
                    "AndroidManifest.xml",
                    "resources.arsc",
                    "res/layout/a.xml",
                    "classes.dex",
                    "classes2.dex",
                    "lib/x86_64/libfoo.so",
                    "assets/index.android.bundle",
                    "okhttp3/publicsuffixes.gz",
                },
            )
            for stored in ("resources.arsc", "lib/x86_64/libfoo.so", "assets/index.android.bundle"):
                self.assertEqual(infos[stored].compress_type, zipfile.ZIP_STORED, stored)
            self.assertEqual(infos["classes.dex"].compress_type, zipfile.ZIP_DEFLATED)
            self.assertEqual({i.date_time for i in infos.values()}, {build_apk.ZIP_EPOCH})

    def test_bundle_module_layout(self) -> None:
        so = self._file("libfoo.so", b"\x7fELF")
        status, out = self._build(["--bundle_module", f"--native_lib=x86_64/libfoo.so={so}"])
        self.assertEqual(status, 0)
        with zipfile.ZipFile(out) as z:
            self.assertEqual(
                set(z.namelist()),
                {
                    "manifest/AndroidManifest.xml",
                    "resources.arsc",
                    "res/layout/a.xml",
                    "dex/classes.dex",
                    "dex/classes2.dex",
                    "lib/x86_64/libfoo.so",
                    "root/okhttp3/publicsuffixes.gz",
                },
            )

    def test_identical_duplicate_native_libs_are_merged(self) -> None:
        a, b = self._file("a.so", b"same"), self._file("b.so", b"same")
        status, out = self._build([f"--native_lib=x86_64/libc++_shared.so={a}", f"--native_lib=x86_64/libc++_shared.so={b}"])
        self.assertEqual(status, 0)
        with zipfile.ZipFile(out) as z:
            self.assertEqual(z.namelist().count("lib/x86_64/libc++_shared.so"), 1)

    def test_conflicting_duplicate_native_libs_fail(self) -> None:
        a, b = self._file("a.so", b"one"), self._file("b.so", b"two")
        status, _ = self._build([f"--native_lib=x86_64/libc++_shared.so={a}", f"--native_lib=x86_64/libc++_shared.so={b}"])
        self.assertEqual(status, 1)


if __name__ == "__main__":
    unittest.main()
