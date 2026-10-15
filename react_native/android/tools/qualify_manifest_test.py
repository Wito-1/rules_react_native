import unittest

import qualify_manifest


class QualifyTest(unittest.TestCase):
    def test_relative_and_bare_names_are_qualified(self) -> None:
        out = qualify_manifest.qualify(
            '<application android:name=".App"><activity android:name="Main"/>'
            '<service android:name="com.other.Svc"/><activity-alias android:targetActivity=".Main"/></application>',
            "com.example",
        )
        self.assertIn('android:name="com.example.App"', out)
        self.assertIn('android:name="com.example.Main"', out)
        self.assertIn('android:name="com.other.Svc"', out)
        self.assertIn('android:targetActivity="com.example.Main"', out)

    def test_non_component_names_are_untouched(self) -> None:
        manifest = '<uses-permission android:name="INTERNET"/><meta-data android:name=".key" android:value="v"/>'
        self.assertEqual(qualify_manifest.qualify(manifest, "com.example"), manifest)

    def test_placeholders_are_untouched(self) -> None:
        manifest = '<provider android:name="androidx.startup.InitializationProvider" android:authorities="${applicationId}.startup"/>'
        self.assertEqual(qualify_manifest.qualify(manifest, "com.example"), manifest)


if __name__ == "__main__":
    unittest.main()
