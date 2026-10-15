import json
import unittest
from unittest import mock

import maven_resolve as mr

GOOGLE, CENTRAL = mr.REPOSITORIES


class FakeMaven:
    """An in-memory pair of Maven repositories, served through `maven_resolve._fetch`."""

    def __init__(self) -> None:
        self.files: dict[str, bytes] = {}

    def _base(self, repo: str, g: str, a: str, v: str) -> str:
        return f"{repo}/{g.replace('.', '/')}/{a}/{v}/{a}-{v}"

    def pom(
        self,
        coord: str,
        deps: list[tuple[str, str, str]] = (),
        packaging: str = "jar",
        repo: str = CENTRAL,
        extra: str = "",
    ) -> None:
        g, a, v = coord.split(":")
        dep_xml = "".join(
            f"<dependency><groupId>{d.split(':')[0]}</groupId><artifactId>{d.split(':')[1]}</artifactId>"
            + (f"<version>{d.split(':')[2]}</version>" if d.count(":") == 2 else "")
            + (f"<scope>{scope}</scope>" if scope else "")
            + ("<optional>true</optional>" if opt == "optional" else "")
            + "</dependency>"
            for d, scope, opt in deps
        )
        self.files[self._base(repo, g, a, v) + ".pom"] = (
            '<project xmlns="http://maven.apache.org/POM/4.0.0">'
            f"<groupId>{g}</groupId><artifactId>{a}</artifactId><version>{v}</version>"
            f"<packaging>{packaging}</packaging>{extra}<dependencies>{dep_xml}</dependencies></project>"
        ).encode()
        if packaging != "pom":
            self.files[self._base(repo, g, a, v) + "." + packaging] = b"artifact"

    def gradle_module(
        self, coord: str, variants: list[dict], repo: str = GOOGLE
    ) -> None:
        g, a, v = coord.split(":")
        self.pom(coord, repo=repo)
        self.files[self._base(repo, g, a, v) + ".module"] = json.dumps(
            {"variants": variants}
        ).encode()

    def metadata(self, coord: str, versions: list[str], repo: str = CENTRAL) -> None:
        g, a = coord.split(":")
        body = "".join(f"<version>{v}</version>" for v in versions)
        self.files[f"{repo}/{g.replace('.', '/')}/{a}/maven-metadata.xml"] = (
            f"<metadata><versioning><versions>{body}</versions></versioning></metadata>".encode()
        )

    def fetch(self, url: str) -> bytes | None:
        return self.files.get(url)


def variant(
    usage: str,
    deps: list[tuple[str, str]] = (),
    files: list[str] = (),
    build_type: str | None = None,
    platform: str | None = "androidJvm",
    available_at: str | None = None,
    constraints: list[tuple[str, str]] = (),
) -> dict:
    attrs = {"org.gradle.category": "library", "org.gradle.usage": usage}
    if platform:
        attrs["org.jetbrains.kotlin.platform.type"] = platform
    if build_type:
        attrs["com.android.build.api.attributes.BuildTypeAttr"] = build_type
    v: dict = {
        "name": f"{usage}-{build_type}-{platform}",
        "attributes": attrs,
        "dependencies": [
            {
                "group": d.split(":")[0],
                "module": d.split(":")[1],
                "version": {"requires": ver},
            }
            for d, ver in deps
        ],
        "dependencyConstraints": [
            {
                "group": d.split(":")[0],
                "module": d.split(":")[1],
                "version": {"requires": ver},
            }
            for d, ver in constraints
        ],
        "files": [{"name": f, "url": f} for f in files],
    }
    if available_at:
        g, m, ver = available_at.split(":")
        v["available-at"] = {"group": g, "module": m, "version": ver, "url": "unused"}
    return v


class ResolveTest(unittest.TestCase):
    def setUp(self) -> None:
        self.maven = FakeMaven()
        mr.clear_caches()
        self.enterContext(mock.patch.object(mr, "_fetch", self.maven.fetch))
        self.enterContext(
            mock.patch.object(mr, "_sha256", lambda url: "sha-" + url.rsplit("/", 1)[1])
        )

    def lock(
        self, *roots: str, build_type: str = "release", excludes: list[str] = ()
    ) -> dict:
        return mr.build_lock(
            {
                "artifacts": list(roots),
                "build_type": build_type,
                "excludes": list(excludes),
            },
            {},
        )["artifacts"]

    def test_highest_requested_version_wins(self) -> None:
        self.maven.pom("app:a:1", [("lib:x:1.0", "", "")])
        self.maven.pom("app:b:1", [("lib:x:1.10", "", "")])
        self.maven.pom("lib:x:1.0")
        self.maven.pom("lib:x:1.10")
        self.assertEqual(
            self.lock("app:a:1", "app:b:1")["lib_x"]["coordinate"], "lib:x:1.10"
        )

    def test_pom_scopes_split_runtime_and_api(self) -> None:
        self.maven.pom(
            "app:a:1",
            [
                ("lib:api:1", "compile", ""),
                ("lib:impl:1", "runtime", ""),
                ("lib:test:1", "test", ""),
                ("lib:opt:1", "", "optional"),
                ("lib:dflt:1", "", ""),
            ],
        )
        for c in ("lib:api:1", "lib:impl:1", "lib:dflt:1"):
            self.maven.pom(c)
        a = self.lock("app:a:1")["app_a"]
        self.assertEqual(a["deps"], ["lib_api", "lib_dflt", "lib_impl"])
        self.assertEqual(a["api_deps"], ["lib_api", "lib_dflt"])

    def test_pom_parent_properties_and_dependency_management(self) -> None:
        self.maven.pom(
            "corp:parent:7",
            packaging="pom",
            extra="<properties><x.version>2.0</x.version></properties>"
            "<dependencyManagement><dependencies><dependency><groupId>lib</groupId><artifactId>y</artifactId>"
            "<version>${x.version}</version></dependency></dependencies></dependencyManagement>",
        )
        self.maven.pom(
            "app:a:1",
            [("lib:x:${x.version}", "", ""), ("lib:y", "", "")],
            extra="<parent><groupId>corp</groupId><artifactId>parent</artifactId><version>7</version></parent>",
        )
        self.maven.pom("lib:x:2.0")
        self.maven.pom("lib:y:2.0")
        lock = self.lock("app:a:1")
        self.assertEqual(lock["lib_x"]["coordinate"], "lib:x:2.0")
        self.assertEqual(lock["lib_y"]["coordinate"], "lib:y:2.0")

    def test_kmp_root_redirects_to_android_artifact(self) -> None:
        self.maven.gradle_module(
            "androidx.lifecycle:lifecycle-runtime:2.8.7",
            [
                variant(
                    "java-runtime",
                    available_at="androidx.lifecycle:lifecycle-runtime-android:2.8.7",
                ),
                variant(
                    "java-runtime",
                    platform="jvm",
                    available_at="androidx.lifecycle:lifecycle-runtime-desktop:2.8.7",
                ),
            ],
        )
        self.maven.gradle_module(
            "androidx.lifecycle:lifecycle-runtime-android:2.8.7",
            [variant("java-runtime", files=["lifecycle-runtime-android-2.8.7.aar"])],
        )
        lock = self.lock("androidx.lifecycle:lifecycle-runtime:2.8.7")
        root = lock["androidx_lifecycle_lifecycle_runtime"]
        self.assertNotIn("url", root)
        self.assertEqual(root["deps"], ["androidx_lifecycle_lifecycle_runtime_android"])
        self.assertEqual(root["api_deps"], root["deps"])
        self.assertNotIn("androidx_lifecycle_lifecycle_runtime_desktop", lock)
        self.assertEqual(
            lock["androidx_lifecycle_lifecycle_runtime_android"]["packaging"], "aar"
        )

    def test_build_type_variant_and_api_variant(self) -> None:
        self.maven.gradle_module(
            "com.facebook.react:react-android:0.86.3",
            [
                variant(
                    "java-api",
                    deps=[("lib:pub:1", "1")],
                    build_type="release",
                    files=["ra-release.aar"],
                ),
                variant(
                    "java-runtime",
                    deps=[("lib:pub:1", "1"), ("lib:priv:1", "1")],
                    build_type="release",
                    files=["ra-release.aar"],
                ),
                variant(
                    "java-runtime",
                    deps=[("lib:dbg:1", "1")],
                    build_type="debug",
                    files=["ra-debug.aar"],
                ),
            ],
        )
        for c in ("lib:pub:1", "lib:priv:1", "lib:dbg:1"):
            self.maven.pom(c)
        release = self.lock("com.facebook.react:react-android:0.86.3")
        ra = release["com_facebook_react_react_android"]
        self.assertTrue(ra["url"].endswith("ra-release.aar"))
        self.assertEqual(ra["deps"], ["lib_priv", "lib_pub"])
        self.assertEqual(ra["api_deps"], ["lib_pub"])
        mr.clear_caches()
        debug = self.lock("com.facebook.react:react-android:0.86.3", build_type="debug")
        self.assertTrue(
            debug["com_facebook_react_react_android"]["url"].endswith("ra-debug.aar")
        )
        self.assertIn("lib_dbg", debug)

    def test_dependency_constraints_raise_present_modules_only(self) -> None:
        self.maven.gradle_module(
            "androidx.core:core:1.13.1",
            [
                variant(
                    "java-runtime",
                    deps=[("androidx.collection:collection:1", "1.0")],
                    files=["core.aar"],
                    constraints=[
                        ("androidx.collection:collection", "1.4.2"),
                        ("absent:lib", "9"),
                    ],
                )
            ],
        )
        self.maven.pom("androidx.collection:collection:1.0")
        self.maven.pom("androidx.collection:collection:1.4.2")
        lock = self.lock("androidx.core:core:1.13.1")
        self.assertEqual(
            lock["androidx_collection_collection"]["coordinate"],
            "androidx.collection:collection:1.4.2",
        )
        self.assertNotIn("absent_lib", lock)

    def test_common_only_kotlin_module_is_skipped(self) -> None:
        self.maven.gradle_module(
            "org.jetbrains.kotlin:kotlin-stdlib-common:2.1.20",
            [variant("kotlin-api", platform="common")],
        )
        entry = self.lock("org.jetbrains.kotlin:kotlin-stdlib-common:2.1.20")[
            "org_jetbrains_kotlin_kotlin_stdlib_common"
        ]
        self.assertNotIn("url", entry)
        self.assertEqual(entry["deps"], [])

    def test_ranges_resolve_to_highest_published_match(self) -> None:
        self.maven.pom("app:a:1", [("lib:x:[1.0,2.0)", "", "")])
        self.maven.metadata("lib:x", ["0.9", "1.0", "1.5", "1.10", "2.0"])
        for v in ("1.10",):
            self.maven.pom(f"lib:x:{v}")
        self.assertEqual(self.lock("app:a:1")["lib_x"]["coordinate"], "lib:x:1.10")

    def test_dynamic_prefix_versions(self) -> None:
        self.maven.pom("app:a:1", [("lib:x:1.2.+", "", "")])
        self.maven.metadata("lib:x", ["1.2.1", "1.2.9", "1.3.0"])
        self.maven.pom("lib:x:1.2.9")
        self.assertEqual(self.lock("app:a:1")["lib_x"]["coordinate"], "lib:x:1.2.9")

    def test_excludes_drop_modules_and_edges(self) -> None:
        self.maven.pom("app:a:1", [("lib:x:1", "", ""), ("lib:y:1", "", "")])
        self.maven.pom("lib:x:1")
        lock = self.lock("app:a:1", excludes=["lib:y"])
        self.assertNotIn("lib_y", lock)
        self.assertEqual(lock["app_a"]["deps"], ["lib_x"])

    def test_known_hashes_are_reused(self) -> None:
        self.maven.pom("lib:x:1")
        url = f"{CENTRAL}/lib/x/1/x-1.jar"
        with mock.patch.object(mr, "_sha256", side_effect=AssertionError("re-hashed")):
            lock = mr.build_lock({"artifacts": ["lib:x:1"]}, {url: "known"})
        self.assertEqual(lock["artifacts"]["lib_x"]["sha256"], "known")


class VersionTest(unittest.TestCase):
    def test_gradle_ordering(self) -> None:
        ordered = [
            "1.0-dev",
            "1.0-alpha01",
            "1.0-alpha02",
            "1.0-beta01",
            "1.0-rc01",
            "1.0-SNAPSHOT",
            "1.0",
            "1.0.1",
            "1.1",
            "1.9",
            "1.10",
            "2.0",
        ]
        self.assertEqual(sorted(reversed(ordered), key=mr.version_key), ordered)

    def test_equal_versions(self) -> None:
        self.assertEqual(mr.compare_versions("1.0.0", "1.0.0"), 0)
        self.assertEqual(mr.compare_versions("1-0", "1.0"), 0)

    def test_numeric_beats_string_part(self) -> None:
        self.assertGreater(mr.compare_versions("1.0.1", "1.0.a"), 0)

    def test_parse_requested(self) -> None:
        self.assertEqual(mr.parse_requested_version("[1.2.3]"), "1.2.3")
        self.assertEqual(mr.parse_requested_version("1.2.3"), "1.2.3")
        r = mr.parse_requested_version("(1.0,2.0]")
        self.assertFalse(r.contains("1.0"))
        self.assertTrue(r.contains("1.5"))
        self.assertTrue(r.contains("2.0"))
        self.assertFalse(r.contains("2.0.1"))
        self.assertTrue(mr.parse_requested_version("[1.0,)").contains("99"))
        with self.assertRaises(ValueError):
            mr.parse_requested_version("(1.0)")


if __name__ == "__main__":
    unittest.main()
