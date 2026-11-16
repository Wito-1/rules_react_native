import unittest

import stamp_version_code


class StampVersionCodeTest(unittest.TestCase):
    def test_embed_label(self):
        status = "BUILD_HOST host\nBUILD_EMBED_LABEL 1234\nBUILD_USER me\n"
        self.assertEqual(stamp_version_code.embed_label(status), "1234")
        self.assertEqual(stamp_version_code.embed_label("BUILD_EMBED_LABEL\n"), "")
        self.assertEqual(stamp_version_code.embed_label("BUILD_HOST host\n"), "")

    def test_replaces_version_code(self):
        manifest = '<manifest xmlns:android="x" android:versionCode="1" android:versionName="1.0">'
        self.assertEqual(
            stamp_version_code.stamp(manifest, 42),
            '<manifest xmlns:android="x" android:versionCode="42" android:versionName="1.0">',
        )

    def test_adds_version_code(self):
        self.assertEqual(
            stamp_version_code.stamp('<manifest xmlns:android="x">', 7),
            '<manifest android:versionCode="7" xmlns:android="x">',
        )


if __name__ == "__main__":
    unittest.main()
