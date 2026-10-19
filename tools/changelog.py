"""Prints the CHANGELOG.md section of one version (without its heading).

Usage: python tools/changelog.py 0.6.0
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def section(version):
    with open(os.path.join(ROOT, "CHANGELOG.md"), encoding="utf-8") as f:
        text = f.read()
    match = re.search(
        r"^## " + re.escape(version) + r"(?:[ \t(][^\r\n]*)?\r?\n(.*?)(?=^## |\Z)",
        text,
        re.M | re.S,
    )
    if not match or not match.group(1).strip():
        sys.exit(f"CHANGELOG.md has no entry for {version}")
    return match.group(1).strip()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.stdout.reconfigure(encoding="utf-8")
    print(section(sys.argv[1]))
