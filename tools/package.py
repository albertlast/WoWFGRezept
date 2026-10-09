"""Builds dist/GuildTradebook-<version>.zip for sharing with guild members.

Release: the TOC says "## Version: 0.1.0" (no "-dev"). The zip keeps that
version, and the tree must be committed. Tag the commit "v0.1.0".

Test build: the TOC says "0.2.0-dev". The zip gets a version naming the
commit, e.g. "0.2.0-d8dcb0e"; uncommitted changes are included and marked
"-dirty".

Either way the commit time becomes the build number (X-Build), so
"/gtb versions" can tell which build is newer. The development copy in the
repo itself reports its TOC version with build 0.

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
    match = re.search(r"^## Version: ([^\r\n]+?)(-dev)?\r?$", toc, re.M)
    if not match:
        sys.exit("no '## Version:' line in the TOC")
    base, release = match.group(1), match.group(2) is None

    commit = git("rev-parse", "--short", "HEAD")
    dirty = git("status", "--porcelain", "--", ADDON) != ""
    if release:
        if dirty:
            sys.exit(f"release {base}: commit all changes first")
        version, build = base, int(git("log", "-1", "--format=%ct"))
    elif dirty:
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
