"""Resolves Android Maven artifacts into the lockfile read by the react_native module extension.

Resolution follows Gradle semantics rather than plain POM semantics, because most of the
React Native dependency graph (androidx, kotlin) is published with Gradle module metadata:
Kotlin Multiplatform roots redirect to their `-android` artifact through `available-at`,
react-android publishes separate debug/release variants, and androidx aligns versions
through `dependencyConstraints`. Conflicts resolve to the highest requested version, version
ranges and dynamic versions resolve to the highest published version that matches, and versions
order the way Gradle orders them.

Each artifact records its runtime `deps` and the subset that is its API (`api_deps`: the
`java-api` variant's dependencies, or a POM's compile-scope ones). The ruleset puts only the API
closure on an app's compile classpath, as Gradle does, and everything on its runtime classpath.

Usage (from the workspace that owns the spec; paths are relative to it):
    bazel run @rules_react_native//react_native/android/tools:maven_resolve -- \\
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
API_SCOPES: Final = frozenset({"", "compile"})
LOCK_FORMAT: Final = 2
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
    api_deps: list[tuple[Coord, str]]
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


def _sha256(url: str) -> str:
    h = hashlib.sha256()
    with _open(url, 600) as resp:
        while chunk := resp.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


# --- Versions -------------------------------------------------------------------------------------

# Gradle's ordering of non-numeric version parts: "dev" sorts below every other string, these sort
# above every other string (in this order), and anything else compares alphabetically between them.
_SPECIAL_HIGH: Final = ("rc", "snapshot", "final", "ga", "release", "sp")


def _version_parts(version: str) -> list[str]:
    parts = []
    for chunk in re.split(r"[.\-_+]", version):
        parts.extend(p for p in re.findall(r"\d+|[^\d]+", chunk) if p)
    return parts


def _compare_parts(a: str, b: str) -> int:
    a_num, b_num = a.isdigit(), b.isdigit()
    if a_num and b_num:
        return (int(a) > int(b)) - (int(a) < int(b))
    if a_num != b_num:
        return 1 if a_num else -1

    def rank(p: str) -> tuple[int, int, str]:
        low = p.lower()
        if low == "dev":
            return (0, 0, "")
        if low in _SPECIAL_HIGH:
            return (2, _SPECIAL_HIGH.index(low), "")
        return (1, 0, p)

    ra, rb = rank(a), rank(b)
    return (ra > rb) - (ra < rb)


def compare_versions(a: str, b: str) -> int:
    """Gradle's version ordering: <0 if a sorts before b, 0 if equal, >0 if after."""
    pa, pb = _version_parts(a), _version_parts(b)
    for x, y in zip(pa, pb):
        c = _compare_parts(x, y)
        if c:
            return c
    if len(pa) == len(pb):
        return 0
    # An extra numeric part makes a version higher (1.0.1 > 1.0); an extra string part makes it
    # lower (1.0-alpha < 1.0).
    longer, sign = (pa, 1) if len(pa) > len(pb) else (pb, -1)
    extra = longer[min(len(pa), len(pb))]
    return sign if extra.isdigit() else -sign


version_key = functools.cmp_to_key(compare_versions)


@dataclasses.dataclass(frozen=True)
class VersionRange:
    lower: str | None
    lower_inclusive: bool
    upper: str | None
    upper_inclusive: bool
    # Gradle's `1.2.+`: the version's leading parts must equal these.
    prefix: str | None = None

    def contains(self, version: str) -> bool:
        if self.prefix is not None:
            parts = _version_parts(self.prefix)
            return _version_parts(version)[: len(parts)] == parts
        if self.lower is not None:
            c = compare_versions(version, self.lower)
            if c < 0 or (c == 0 and not self.lower_inclusive):
                return False
        if self.upper is not None:
            c = compare_versions(version, self.upper)
            if c > 0 or (c == 0 and not self.upper_inclusive):
                return False
        return True


def parse_requested_version(raw: str) -> str | VersionRange:
    """An exact version, or the range a Maven range / Gradle dynamic version stands for."""
    raw = raw.strip()
    if raw.startswith(("[", "(")) and raw.endswith(("]", ")")):
        body = raw[1:-1]
        if "," not in body:
            if raw[0] == "[" and raw[-1] == "]":
                return body.strip()
            raise ValueError(f"malformed version range {raw!r}")
        lower, upper = (p.strip() or None for p in body.split(",", 1))
        return VersionRange(lower, raw[0] == "[", upper, raw[-1] == "]")
    if raw == "+" or raw.startswith("latest."):
        return VersionRange(None, True, None, True)
    if raw.endswith(".+"):
        return VersionRange(None, True, None, True, prefix=raw[:-2])
    return raw


@functools.cache
def _published_versions(coord: Coord) -> tuple[str, ...]:
    versions: set[str] = set()
    for repo in REPOSITORIES:
        raw = _fetch(
            f"{repo}/{coord.group.replace('.', '/')}/{coord.artifact}/maven-metadata.xml"
        )
        if raw is None:
            continue
        for v in ET.fromstring(raw).iter("version"):
            if v.text:
                versions.add(v.text.strip())
    return tuple(sorted(versions, key=version_key))


def resolve_requested(coord: Coord, raw: str) -> str:
    """The concrete version a dependency declaration asks for."""
    requested = parse_requested_version(raw)
    if isinstance(requested, str):
        return requested
    matching = [v for v in _published_versions(coord) if requested.contains(v)]
    if not matching:
        raise RuntimeError(f"{coord.key}: no published version matches {raw!r}")
    return matching[-1]


# --- Module metadata ------------------------------------------------------------------------------


@functools.cache
def _find_repo(coord: Coord, version: str) -> str:
    for repo in REPOSITORIES:
        base = f"{repo}/{coord.path(version)}/{coord.artifact}-{version}"
        if _fetch(base + ".pom") is not None:
            return repo
    raise RuntimeError(f"{coord.key}:{version} not found in any repository")


def _select_variant(variants: list[dict], build_type: str, usage: str) -> dict | None:
    """The Android-compatible library variant of `usage` (java-runtime or java-api)."""

    def score(v: dict) -> int | None:
        attrs = v.get("attributes", {})
        if (
            attrs.get("org.gradle.category", "library") != "library"
            or "org.gradle.docstype" in attrs
        ):
            return None
        if attrs.get("org.gradle.usage") != usage:
            return None
        platform = attrs.get("org.jetbrains.kotlin.platform.type")
        if platform not in (None, "androidJvm", "jvm"):
            return None
        bt = attrs.get("com.android.build.api.attributes.BuildTypeAttr")
        if bt is not None and bt != build_type:
            return None
        return {"androidJvm": 5, None: 3, "jvm": 1}[platform]

    scored = [(s, i, v) for i, v in enumerate(variants) if (s := score(v)) is not None]
    if not scored:
        return None
    return max(scored, key=lambda t: (t[0], -t[1]))[2]


def _gradle_dep(coord: Coord, d: dict) -> tuple[Coord, str] | None:
    if d.get("attributes", {}).get("org.gradle.category") in (
        "platform",
        "enforced-platform",
    ):
        return None
    v = d.get("version", {})
    raw = v.get("strictly") or v.get("requires") or v.get("prefers")
    if raw is None:
        return None
    dep = Coord(d["group"], d["module"])
    return dep, resolve_requested(dep, raw)


def _variant_deps(coord: Coord, variant: dict | None) -> list[tuple[Coord, str]]:
    if variant is None:
        return []
    if "available-at" in variant:
        at = variant["available-at"]
        return [(Coord(at["group"], at["module"]), at["version"])]
    return [
        d for d in (_gradle_dep(coord, x) for x in variant.get("dependencies", [])) if d
    ]


def _load_from_gradle_metadata(
    coord: Coord, version: str, repo: str, build_type: str
) -> Module | None:
    base = f"{repo}/{coord.path(version)}"
    raw = _fetch(f"{base}/{coord.artifact}-{version}.module")
    if raw is None:
        return None
    variants = json.loads(raw).get("variants", [])
    runtime = _select_variant(variants, build_type, "java-runtime")
    api = _select_variant(variants, build_type, "java-api") or runtime
    if runtime is None:
        # e.g. kotlin-stdlib-common 2.x only publishes `common` metadata; Gradle contributes
        # nothing from it to an Android runtime classpath either.
        print(
            f"warning: {coord.key}:{version} has no Android runtime variant; skipping",
            file=sys.stderr,
        )
        return Module(
            deps=[], api_deps=[], constraints=[], file_url=None, packaging=None
        )
    deps = _variant_deps(coord, runtime)
    api_deps = _variant_deps(coord, api)
    if "available-at" in runtime:
        return Module(
            deps=deps, api_deps=deps, constraints=[], file_url=None, packaging=None
        )
    constraints = [
        d
        for d in (
            _gradle_dep(coord, x) for x in runtime.get("dependencyConstraints", [])
        )
        if d
    ]
    files = [
        f for f in runtime.get("files", []) if f["name"].endswith((".aar", ".jar"))
    ]
    if len(files) > 1:
        raise RuntimeError(
            f"{coord.key}:{version}: variant {runtime['name']} ships several files"
        )
    file_url = f"{base}/{files[0]['url']}" if files else None
    packaging = files[0]["name"].rsplit(".", 1)[1] if files else None
    return Module(
        deps=deps,
        api_deps=api_deps,
        constraints=constraints,
        file_url=file_url,
        packaging=packaging,
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
    if raw is None:
        raise RuntimeError(f"{coord.key}:{version}: POM disappeared from {repo}")
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
    deps, api_deps = [], []
    deps_el = root.find(POM_NS + "dependencies")
    for d in deps_el.findall(POM_NS + "dependency") if deps_el is not None else []:
        if (_pom_text(d, "optional") or "false") == "true":
            continue
        scope = _pom_text(d, "scope") or ""
        if scope not in RUNTIME_SCOPES:
            continue
        dep = Coord(
            _subst(_pom_text(d, "groupId") or "", props),
            _subst(_pom_text(d, "artifactId") or "", props),
        )
        v = _pom_text(d, "version")
        v = _subst(v, props) if v else managed.get(dep.key)
        if v is None:
            raise RuntimeError(
                f"{coord.key}:{version}: no version for dependency {dep.key}"
            )
        entry = (dep, resolve_requested(dep, v))
        deps.append(entry)
        if scope in API_SCOPES:
            api_deps.append(entry)
    packaging = _pom_text(root, "packaging") or "jar"
    if packaging == "bundle":
        packaging = "jar"
    if packaging == "pom":
        return Module(
            deps=deps, api_deps=api_deps, constraints=[], file_url=None, packaging=None
        )
    base = f"{repo}/{coord.path(version)}/{coord.artifact}-{version}"
    if packaging == "aar" and _fetch(f"{base}.aar") is None:
        packaging = "jar"
    return Module(
        deps=deps,
        api_deps=api_deps,
        constraints=[],
        file_url=f"{base}.{packaging}",
        packaging=packaging,
    )


@functools.cache
def _load_module(coord: Coord, version: str, build_type: str) -> Module:
    repo = _find_repo(coord, version)
    return _load_from_gradle_metadata(
        coord, version, repo, build_type
    ) or _load_from_pom(coord, version, repo)


def clear_caches() -> None:
    """Forgets every fetched document; tests swap `_fetch` between cases."""
    for f in (_published_versions, _find_repo, _load_pom, _load_module):
        f.cache_clear()


# --- Resolution -----------------------------------------------------------------------------------


def resolve(
    roots: list[tuple[Coord, str]], build_type: str, excludes: set[str]
) -> dict[Coord, str]:
    """Fixpoint resolution: re-walk the graph until the selected version of every module is stable."""
    roots = [(c, resolve_requested(c, v)) for c, v in roots]
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
            new[coord] = max(versions, key=version_key)
        if new == selected:
            return selected
        selected = new


def target_name(coord: Coord) -> str:
    return re.sub(r"[^A-Za-z0-9_]", "_", coord.key)


def build_lock(spec: dict, known_sha256: dict[str, str]) -> dict:
    roots = []
    for artifact in spec["artifacts"]:
        g, a, v = artifact.split(":")
        roots.append((Coord(g, a), v))
    build_type = spec.get("build_type", "release")
    excludes = set(spec.get("excludes", []))

    selected = resolve(roots, build_type, excludes)
    present = {target_name(c) for c in selected}
    artifacts = {}
    for coord in sorted(selected, key=lambda c: c.key):
        version = selected[coord]
        module = _load_module(coord, version, build_type)
        deps = sorted({target_name(d) for d, _ in module.deps if d.key not in excludes})
        # An API dependency that isn't also a runtime one never enters the graph; Gradle would
        # fail to compile against it too, so drop it rather than dangle.
        api_deps = sorted(
            {target_name(d) for d, _ in module.api_deps if d.key not in excludes}
            & present
        )
        entry: dict = {
            "coordinate": f"{coord.key}:{version}",
            "deps": deps,
            "api_deps": api_deps,
        }
        if module.file_url:
            sha256 = known_sha256.get(module.file_url)
            if sha256 is None:
                print(f"hashing {coord.key}:{version}", file=sys.stderr)
                sha256 = _sha256(module.file_url)
            entry.update(url=module.file_url, packaging=module.packaging, sha256=sha256)
        artifacts[target_name(coord)] = entry

    return {
        "_comment": "Generated by rules_react_native's maven_resolve (react_native_maven_pin). Do not edit.",
        "format": LOCK_FORMAT,
        "build_type": build_type,
        "roots": [target_name(c) for c, _ in roots],
        "artifacts": artifacts,
    }


def pin(spec_path: str, lockfile: str, workspace: str) -> None:
    with open(os.path.join(workspace, spec_path)) as f:
        spec = json.load(f)
    out = os.path.join(workspace, lockfile)
    known_sha256: dict[str, str] = {}
    if os.path.exists(out):
        with open(out) as f:
            for entry in json.load(f)["artifacts"].values():
                if "url" in entry:
                    known_sha256[entry["url"]] = entry["sha256"]
    lock = build_lock(spec, known_sha256)
    with open(out, "w") as f:
        json.dump(lock, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"wrote {len(lock['artifacts'])} artifacts to {lockfile}", file=sys.stderr)


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
