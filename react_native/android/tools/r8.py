"""Shrinks, optimizes and dexes an app with R8, collecting the rules AGP would.

Besides the explicit rule files (the app's, libraries' consumer rules, aapt2's keep rules for
classes the manifest and layouts reference), jars carry their own rules under META-INF:
`com.android.tools/r8*/` (R8-specific) wins over `proguard/` when a jar has both, as in AGP.
"""

import argparse
import os
import subprocess
import sys
import tempfile
import zipfile


def _embedded_rules(jar: str) -> list[tuple[str, bytes]]:
    r8, proguard = [], []
    with zipfile.ZipFile(jar) as z:
        for name in sorted(z.namelist()):
            if name.endswith("/"):
                continue
            if name.startswith("META-INF/com.android.tools/r8"):
                r8.append((name, z.read(name)))
            elif name.startswith("META-INF/proguard/"):
                proguard.append((name, z.read(name)))
    return r8 or proguard


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, fromfile_prefix_chars="@")
    parser.add_argument("--java", required=True)
    parser.add_argument("--r8_classpath", action="append", required=True)
    parser.add_argument("--lib", required=True, help="android.jar")
    parser.add_argument("--program", action="append", default=[], help="Runtime jar")
    parser.add_argument("--pg_conf", action="append", default=[], help="Rules file")
    parser.add_argument("--min_api", required=True)
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--mapping_out", required=True)
    parser.add_argument("--out", required=True, help="Zip of classes*.dex")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="rn-r8-") as work:
        confs = list(args.pg_conf)
        for i, jar in enumerate(args.program):
            for j, (name, data) in enumerate(_embedded_rules(jar)):
                path = os.path.join(work, f"embedded_{i}_{j}.pro")
                with open(path, "wb") as f:
                    f.write(b"# from " + jar.encode() + b"!/" + name.encode() + b"\n" + data)
                confs.append(path)
        r8_args = [
            "--debug" if args.debug else "--release",
            "--min-api",
            args.min_api,
            "--lib",
            args.lib,
            "--pg-map-output",
            args.mapping_out,
            "--output",
            args.out,
            # Java resources are packaged from the jars by build_apk.py; only the dex is used here.
            "--no-data-resources",
            # Consumer rules for classes the app doesn't use are expected; AGP hides these too.
            "--map-diagnostics",
            "info",
            "none",
            # Jars routinely reference optional classes (annotations, other platforms).
            "--map-diagnostics:MissingDefinitionsDiagnostic",
            "error",
            "warning",
            *[x for c in confs for x in ("--pg-conf", c)],
            *args.program,
        ]
        result = subprocess.run(
            [
                args.java,
                "-Xmx4g",
                "-cp",
                os.pathsep.join(args.r8_classpath),
                "com.android.tools.r8.R8",
                *r8_args,
            ]
        )
        return result.returncode


if __name__ == "__main__":
    sys.exit(main())
