"""Resolves Android Maven artifacts into the lockfile read by the react_native module extension.

Resolution follows Gradle semantics rather than plain POM semantics, because most of the
React Native dependency graph (androidx, kotlin) is published with Gradle module metadata:
Kotlin Multiplatform roots redirect to their `-android` artifact through `available-at`,
react-android publishes separate debug/release variants, and androidx aligns versions
through `dependencyConstraints`. Conflicts resolve to the highest requested version.

Usage (from the workspace that owns the spec; paths are relative to it):
    bazel run @rules_react_native//react_native/android/tools:maven_resolve -- \
        --pin=android/maven_spec.json=android/maven_lock.json
or through a `react_native_maven_pin` target.
"""

import argparse
import dataclasses
import functools
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from typing import Final

REPOSITORIES: Final = (
    "https://dl.google.com/dl/android/maven2",
    "https://repo1.maven.org/maven2",
)
POM_NS: Final = "{http://maven.apache.org/POM/4.0.0}"
RUNTIME_SCOPES: Final = frozenset({"", "compile", "runtime"})
# Maven Central's CDN rejects the default `Python-urllib` agent for large artifacts.
USER_AGENT: Final = "rules_react_native-maven-resolve/1.0"


def _open(url: str, timeout_s: int):
    return urllib.request.urlopen(
        urllib.request.Request(url, headers={"User-Agent": USER_AGENT}),
        timeout=timeout_s,
    )


@dataclasses.dataclass(frozen=True)
class Coord:
    group: str
    artifact: str

    @property
    def key(self) -> str:
        return f"{self.group}:{self.artifact}"

    def path(self, version: str) -> str:
        return f"{self.group.replace('.', '/')}/{self.artifact}/{version}"


@dataclasses.dataclass
class Module:
    """One resolved module version: what it depends on and which file (if any) it ships."""

    deps: list[tuple[Coord, str]]
    constraints: list[tuple[Coord, str]]
    file_url: str | None
    packaging: str | None


def _fetch(url: str) -> bytes | None:
    try:
        with _open(url, 60) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


@functools.cache
def _find_repo(coord: Coord, version: str) -> str:
    for repo in REPOSITORIES:
        base = f"{repo}/{coord.path(version)}/{coord.artifact}-{version}"
        if _fetch(base + ".pom") is not None:
            return repo
    raise RuntimeError(f"{coord.key}:{version} not found in any repository")


def _version_key(version: str) -> tuple:
    parts = re.split(r"[.\-]", version)
    key = []
    for p in parts:
        if p.isdigit():
            key.append((2, int(p), ""))
        else:
            # Pre-release qualifiers sort below the release they precede ("1.0-alpha01" < "1.0").
            key.append(
                (0 if re.match(r"(alpha|beta|rc|dev|m)\d*", p, re.I) else 1, 0, p)
            )
    key.append((1, 0, ""))
    return tuple(key)


def _parse_requested_version(raw: str) -> str:
    raw = raw.strip()
    if raw.startswith("[") and raw.endswith("]") and "," not in raw:
        return raw[1:-1]
    if any(c in raw for c in "[](),"):
        # Ranges like "[1.0,2.0)": take the lower bound, which is what pins the graph in practice.
        lower = raw.strip("[]()").split(",")[0].strip()
        if lower:
            return lower
        raise RuntimeError(f"cannot resolve open version range {raw!r}")
    return raw


def _select_variant(variants: list[dict], build_type: str) -> dict | None:
    def score(v: dict) -> int | None:
        attrs = v.get("attributes", {})
        if (
            attrs.get("org.gradle.category", "library") != "library"
            or "org.gradle.docstype" in attrs
        ):
            return None
        usage = attrs.get("org.gradle.usage")
        if usage not in ("java-runtime", "java-api"):
            return None
        platform = attrs.get("org.jetbrains.kotlin.platform.type")
        if platform not in (None, "androidJvm", "jvm"):
            return None
        bt = attrs.get("com.android.build.api.attributes.BuildTypeAttr")
        if bt is not None and bt != build_type:
            return None
        s = 10 if usage == "java-runtime" else 0
        s += {"androidJvm": 5, None: 3, "jvm": 1}[platform]
        return s

    scored = [(score(v), i, v) for i, v in enumerate(variants)]
    scored = [(s, i, v) for s, i, v in scored if s is not None]
    if not scored:
        return None
    return max(scored, key=lambda t: (t[0], -t[1]))[2]


def _gradle_dep(d: dict) -> tuple[Coord, str] | None:
    if d.get("attributes", {}).get("org.gradle.category") in (
        "platform",
        "enforced-platform",
    ):
        return None
    v = d.get("version", {})
    raw = v.get("strictly") or v.get("requires") or v.get("prefers")
    if raw is None:
        return None
    return Coord(d["group"], d["module"]), _parse_requested_version(raw)


def _load_from_gradle_metadata(
    coord: Coord, version: str, repo: str, build_type: str
) -> Module | None:
    base = f"{repo}/{coord.path(version)}"
    raw = _fetch(f"{base}/{coord.artifact}-{version}.module")
    if raw is None:
        return None
    meta = json.loads(raw)
    variant = _select_variant(meta.get("variants", []), build_type)
    if variant is None:
        # e.g. kotlin-stdlib-common 2.x only publishes `common` metadata; Gradle contributes
        # nothing from it to an Android runtime classpath either.
        print(
            f"warning: {coord.key}:{version} has no Android runtime variant; skipping",
            file=sys.stderr,
        )
        return Module(deps=[], constraints=[], file_url=None, packaging=None)
    if "available-at" in variant:
        at = variant["available-at"]
        return Module(
            deps=[(Coord(at["group"], at["module"]), at["version"])],
            constraints=[],
            file_url=None,
            packaging=None,
        )
    deps = [d for d in (_gradle_dep(x) for x in variant.get("dependencies", [])) if d]
    constraints = [
        d
        for d in (_gradle_dep(x) for x in variant.get("dependencyConstraints", []))
        if d
    ]
    files = [
        f for f in variant.get("files", []) if f["name"].endswith((".aar", ".jar"))
    ]
    if len(files) > 1:
        raise RuntimeError(
            f"{coord.key}:{version}: variant {variant['name']} ships several files"
        )
    file_url = f"{base}/{files[0]['url']}" if files else None
    packaging = files[0]["name"].rsplit(".", 1)[1] if files else None
    return Module(
        deps=deps, constraints=constraints, file_url=file_url, packaging=packaging
    )


def _pom_text(el: ET.Element | None, tag: str) -> str | None:
    if el is None:
        return None
    child = el.find(POM_NS + tag)
    return child.text.strip() if child is not None and child.text else None


@functools.cache
def _load_pom(
    coord: Coord, version: str
) -> tuple[dict[str, str], dict[str, str], ET.Element]:
    """Returns (properties, managed versions, root) with the parent chain folded in."""
    repo = _find_repo(coord, version)
    raw = _fetch(f"{repo}/{coord.path(version)}/{coord.artifact}-{version}.pom")
    assert raw is not None
    root = ET.fromstring(raw)
    props: dict[str, str] = {}
    managed: dict[str, str] = {}
    parent = root.find(POM_NS + "parent")
    if parent is not None:
        p_props, p_managed, _ = _load_pom(
            Coord(
                _pom_text(parent, "groupId") or "",
                _pom_text(parent, "artifactId") or "",
            ),
            _pom_text(parent, "version") or "",
        )
        props.update(p_props)
        managed.update(p_managed)
    group = _pom_text(root, "groupId") or _pom_text(parent, "groupId") or coord.group
    props.update(
        {"project.version": version, "project.groupId": group, "pom.version": version}
    )
    props_el = root.find(POM_NS + "properties")
    if props_el is not None:
        for p in props_el:
            props[p.tag.removeprefix(POM_NS)] = (p.text or "").strip()
    dm = root.find(f"{POM_NS}dependencyManagement/{POM_NS}dependencies")
    if dm is not None:
        for d in dm.findall(POM_NS + "dependency"):
            g, a, v = (_pom_text(d, t) for t in ("groupId", "artifactId", "version"))
            if g and a and v:
                managed[f"{_subst(g, props)}:{_subst(a, props)}"] = _subst(v, props)
    return props, managed, root


def _subst(value: str, props: dict[str, str]) -> str:
    def repl(m: re.Match) -> str:
        if m.group(1) not in props:
            raise RuntimeError(f"unresolved POM property ${{{m.group(1)}}}")
        return props[m.group(1)]

    for _ in range(5):
        value = re.sub(r"\$\{([^}]+)\}", repl, value)
    return value


def _load_from_pom(coord: Coord, version: str, repo: str) -> Module:
    props, managed, root = _load_pom(coord, version)
    deps = []
    deps_el = root.find(POM_NS + "dependencies")
    for d in deps_el.findall(POM_NS + "dependency") if deps_el is not None else []:
        if (_pom_text(d, "optional") or "false") == "true":
            continue
        if (_pom_text(d, "scope") or "") not in RUNTIME_SCOPES:
            continue
        g = _subst(_pom_text(d, "groupId") or "", props)
        a = _subst(_pom_text(d, "artifactId") or "", props)
        v = _pom_text(d, "version")
        v = _subst(v, props) if v else managed.get(f"{g}:{a}")
        if v is None:
            raise RuntimeError(
                f"{coord.key}:{version}: no version for dependency {g}:{a}"
            )
        deps.append((Coord(g, a), _parse_requested_version(v)))
    packaging = _pom_text(root, "packaging") or "jar"
    if packaging == "bundle":
        packaging = "jar"
    if packaging == "pom":
        return Module(deps=deps, constraints=[], file_url=None, packaging=None)
    base = f"{repo}/{coord.path(version)}/{coord.artifact}-{version}"
    if _fetch(f"{base}.{packaging}") is None and packaging == "aar":
        packaging = "jar"
    return Module(
        deps=deps, constraints=[], file_url=f"{base}.{packaging}", packaging=packaging
    )


@functools.cache
def _load_module(coord: Coord, version: str, build_type: str) -> Module:
    repo = _find_repo(coord, version)
    return _load_from_gradle_metadata(
        coord, version, repo, build_type
    ) or _load_from_pom(coord, version, repo)


def resolve(
    roots: list[tuple[Coord, str]], build_type: str, excludes: set[str]
) -> dict[Coord, str]:
    """Fixpoint resolution: re-walk the graph until the selected version of every module is stable."""
    selected: dict[Coord, str] = {}
    while True:
        requested: dict[Coord, set[str]] = {}
        constraints: dict[Coord, set[str]] = {}
        stack = list(roots)
        seen: set[Coord] = set()
        for c, v in roots:
            requested.setdefault(c, set()).add(v)
        while stack:
            coord, version = stack.pop()
            if coord in seen:
                continue
            seen.add(coord)
            module = _load_module(coord, selected.get(coord, version), build_type)
            for dep, dep_version in module.deps:
                if dep.key in excludes:
                    continue
                requested.setdefault(dep, set()).add(dep_version)
                stack.append((dep, selected.get(dep, dep_version)))
            for dep, dep_version in module.constraints:
                constraints.setdefault(dep, set()).add(dep_version)
        new = {}
        for coord, versions in requested.items():
            versions |= constraints.get(coord, set())
            new[coord] = max(versions, key=_version_key)
        if new == selected:
            return selected
        selected = new


def _sha256(url: str) -> str:
    h = hashlib.sha256()
    with _open(url, 600) as resp:
        while chunk := resp.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def _target_name(coord: Coord) -> str:
    return re.sub(r"[^A-Za-z0-9_]", "_", coord.key)


def pin(spec_path: str, lockfile: str, workspace: str) -> None:
    with open(os.path.join(workspace, spec_path)) as f:
        spec = json.load(f)
    roots = []
    for artifact in spec["artifacts"]:
        g, a, v = artifact.split(":")
        roots.append((Coord(g, a), v))
    build_type = spec.get("build_type", "release")
    excludes = set(spec.get("excludes", []))

    out = os.path.join(workspace, lockfile)
    known_sha256: dict[str, str] = {}
    if os.path.exists(out):
        with open(out) as f:
            for entry in json.load(f)["artifacts"].values():
                if "url" in entry:
                    known_sha256[entry["url"]] = entry["sha256"]

    selected = resolve(roots, build_type, excludes)
    artifacts = {}
    for coord in sorted(selected, key=lambda c: c.key):
        version = selected[coord]
        module = _load_module(coord, version, build_type)
        deps = sorted(
            {_target_name(d) for d, _ in module.deps if d.key not in excludes}
        )
        entry: dict = {"coordinate": f"{coord.key}:{version}", "deps": deps}
        if module.file_url:
            sha256 = known_sha256.get(module.file_url)
            if sha256 is None:
                print(f"hashing {coord.key}:{version}", file=sys.stderr)
                sha256 = _sha256(module.file_url)
            entry.update(url=module.file_url, packaging=module.packaging, sha256=sha256)
        artifacts[_target_name(coord)] = entry

    lock = {
        "_comment": "Generated by rules_react_native's maven_resolve (react_native_maven_pin). Do not edit.",
        "build_type": build_type,
        "roots": [_target_name(c) for c, _ in roots],
        "artifacts": artifacts,
    }
    with open(out, "w") as f:
        json.dump(lock, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"wrote {len(artifacts)} artifacts to {lockfile}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--pin",
        action="append",
        required=True,
        metavar="SPEC=LOCKFILE",
        help="Workspace-relative spec JSON (`artifacts`, `build_type`, `excludes`) and lockfile to write",
    )
    args = parser.parse_args()
    workspace = os.environ.get("BUILD_WORKSPACE_DIRECTORY", ".")
    for pair in args.pin:
        spec_path, lockfile = pair.split("=", 1)
        pin(spec_path, lockfile, workspace)
    return 0


if __name__ == "__main__":
    sys.exit(main())
