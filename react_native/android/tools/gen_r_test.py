import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

import gen_r

FINAL_R_TXT = """\
int attr colorAccent 0x7f010001
int attr colorPrimary 0x7f010002
int drawable logo 0x7f020001
int string app_name 0x7f030001
int[] styleable Toolbar { 0x7f010001, 0x7f010002 }
int styleable Toolbar_colorAccent 0
int styleable Toolbar_colorPrimary 1
"""

LIBRARY_R_TXT = """\
int attr colorAccent 0x7f000001
int[] styleable Toolbar { 0x7f000001, 0x7f000002 }
int styleable Toolbar_colorAccent 0
int styleable Toolbar_colorPrimary 1
int string removed_by_app 0x7f000003
"""


class GenRTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        final = tmp / "R.txt"
        final.write_text(FINAL_R_TXT)
        lib = tmp / "lib_R.txt"
        lib.write_text(LIBRARY_R_TXT)
        extra = tmp / "BuildConfig.java"
        extra.write_text("package com.app; public final class BuildConfig {}\n")
        out = tmp / "out.srcjar"
        sys.argv = [
            "gen_r",
            f"--r_txt={final}",
            "--package=com.app",
            f"--library=com.lib={lib}",
            f"--java=com/app/BuildConfig.java={extra}",
            f"--out={out}",
        ]
        self.assertEqual(gen_r.main(), 0)
        with zipfile.ZipFile(out) as z:
            self.sources = {n: z.read(n).decode() for n in z.namelist()}

    def test_app_r_has_every_symbol(self) -> None:
        app_r = self.sources["com/app/R.java"]
        self.assertIn("public static final int logo = 0x7f020001;", app_r)
        self.assertIn("public static final int app_name = 0x7f030001;", app_r)

    def test_library_r_has_only_its_symbols_with_final_ids(self) -> None:
        lib_r = self.sources["com/lib/R.java"]
        self.assertIn("public static final int colorAccent = 0x7f010001;", lib_r)
        self.assertIn("public static final int[] Toolbar = new int[] { 0x7f010001, 0x7f010002 };", lib_r)
        self.assertIn("Toolbar_colorPrimary = 1;", lib_r)
        self.assertNotIn("logo", lib_r)
        self.assertNotIn("removed_by_app", lib_r)

    def test_extra_sources_are_included(self) -> None:
        self.assertIn("com/app/BuildConfig.java", self.sources)


class CompileOnlyTest(unittest.TestCase):
    def test_dependency_r_classes_are_non_final(self) -> None:
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        lib = tmp / "lib_R.txt"
        lib.write_text(LIBRARY_R_TXT)
        out = tmp / "out.srcjar"
        sys.argv = ["gen_r", "--compile_only", f"--library=com.lib={lib}", f"--out={out}"]
        self.assertEqual(gen_r.main(), 0)
        with zipfile.ZipFile(out) as z:
            self.assertEqual(z.namelist(), ["com/lib/R.java"])
            src = z.read("com/lib/R.java").decode()
        self.assertIn("public static int colorAccent = 0x7f000001;", src)
        self.assertIn("public static int removed_by_app = 0x7f000003;", src)
        self.assertNotIn("final int", src)


if __name__ == "__main__":
    unittest.main()
