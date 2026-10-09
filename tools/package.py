"""Builds dist/GuildTradebook-<version>.zip for sharing with guild members.

The zip's TOC gets a version that names the commit, e.g. "0.1.0-d8dcb0e",
and the commit time as build number (X-Build), so "/gtb versions" can tell
builds apart and which one is newer. The development copy in the repo keeps
"0.1.0-dev" / build 0.

Uncommitted changes are packaged too, marked "-dirty" and stamped with the
current time.

Usage: python tools/package.py
"""
import os
import re
import subprocess
import sys
import time
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDON = "GuildTradebook"
SKIP = {".DS_Store", "Thumbs.db"}


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def main():
    toc_path = os.path.join(ROOT, ADDON, ADDON + ".toc")
    with open(toc_path, encoding="utf-8", newline="") as f:
        toc = f.read()
    match = re.search(r"^## Version: ([^\r\n]+?)(?:-dev)?\r?$", toc, re.M)
    if not match:
        sys.exit("no '## Version:' line in the TOC")
    base = match.group(1)

    commit = git("rev-parse", "--short", "HEAD")
    dirty = git("status", "--porcelain", "--", ADDON) != ""
    if dirty:
        version, build = f"{base}-{commit}-dirty", int(time.time())
    else:
        version, build = f"{base}-{commit}", int(git("log", "-1", "--format=%ct"))

    toc = re.sub(r"^## Version: [^\r\n]*", f"## Version: {version}", toc, count=1, flags=re.M)
    toc = re.sub(r"^## X-Build: [^\r\n]*", f"## X-Build: {build}", toc, count=1, flags=re.M)

    dist = os.path.join(ROOT, "dist")
    os.makedirs(dist, exist_ok=True)
    out = os.path.join(dist, f"{ADDON}-{version}.zip")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for folder, _, files in os.walk(os.path.join(ROOT, ADDON)):
            for name in sorted(files):
                if name in SKIP:
                    continue
                path = os.path.join(folder, name)
                arc = os.path.relpath(path, ROOT).replace(os.sep, "/")
                if arc == f"{ADDON}/{ADDON}.toc":
                    z.writestr(arc, toc)
                else:
                    z.write(path, arc)
    print(f"{out}\n  version {version}, build {build}" + ("  (uncommitted changes included)" if dirty else ""))


if __name__ == "__main__":
    main()
