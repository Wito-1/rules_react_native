"""Qualifies an app manifest's relative component names against its namespace.

AGP resolves `android:name=".MainActivity"` against the module's `namespace` before it sets the
manifest package to the application id. Doing the same here lets an app's id differ from the Java
package of its classes (e.g. `com.example.app.staging` vs `com.example.app`).
"""

import argparse
import re
import sys

_COMPONENTS = re.compile(r"<(application|activity|activity-alias|service|receiver|provider)\b[^>]*>", re.S)
_CLASS_ATTRS = re.compile(r'(android:(?:name|targetActivity|backupAgent)=")([^"]+)(")')


def qualify(manifest: str, namespace: str) -> str:
    def fix_attr(m: re.Match) -> str:
        value = m.group(2)
        if value.startswith("."):
            value = namespace + value
        elif "." not in value and "$" not in value:
            value = f"{namespace}.{value}"
        return m.group(1) + value + m.group(3)

    return _COMPONENTS.sub(lambda m: _CLASS_ATTRS.sub(fix_attr, m.group(0)), manifest)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    with open(args.manifest) as f:
        out = qualify(f.read(), args.namespace)
    with open(args.out, "w") as f:
        f.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
