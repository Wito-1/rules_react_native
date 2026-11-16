"""Sets a merged manifest's versionCode from the build's --embed_label, when it has one.

Stores reject a versionCode they have already seen, so a release pipeline numbers each store build
with its build number. The label comes from Bazel's stable status file, which changes with every
commit; this action's output only changes with the label, so the rest of the app stays cached.
"""

import argparse
import re
import sys

_MAX_VERSION_CODE = 2100000000  # Google Play's maximum.
_VERSION_CODE = re.compile(r'(android:versionCode=")[^"]*(")')


def embed_label(status: str) -> str:
    for line in status.splitlines():
        key, _, value = line.partition(" ")
        if key == "BUILD_EMBED_LABEL":
            return value.strip()
    return ""


def stamp(manifest: str, version_code: int) -> str:
    out, n = _VERSION_CODE.subn(rf"\g<1>{version_code}\g<2>", manifest, count=1)
    if n == 0:
        out = re.sub(r"<manifest\b", f'<manifest android:versionCode="{version_code}"', manifest, count=1)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--status", required=True, help="Bazel's stable status file (ctx.info_file)")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    with open(args.status) as f:
        label = embed_label(f.read())
    with open(args.manifest) as f:
        manifest = f.read()
    if label:
        if not re.fullmatch(r"[1-9][0-9]{0,9}", label) or int(label) > _MAX_VERSION_CODE:
            print(
                f"error: --embed_label={label!r} is the app's versionCode, so it must be an integer "
                f"from 1 to {_MAX_VERSION_CODE}",
                file=sys.stderr,
            )
            return 1
        manifest = stamp(manifest, int(label))
    with open(args.out, "w") as f:
        f.write(manifest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
