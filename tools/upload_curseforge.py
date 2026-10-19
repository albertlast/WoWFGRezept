"""Uploads a release zip to CurseForge (upload API, https://support.curseforge.com).

The project ID comes from "## X-Curse-Project-ID" in the TOC, the game version
from "## Interface" (16001 -> "1.60.1", game version type "Forever"). The token
is read from CF_API_TOKEN (CurseForge > Author settings > API tokens), never
from the command line.

Release type: a tag with "alpha" or "beta" in it uploads as that, anything else
as a release.

Usage: python tools/upload_curseforge.py <zip> <version> [--dry-run]
  --dry-run  asks CurseForge for the game version and prints what would be
             uploaded, without uploading.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from changelog import ROOT, section  # noqa: E402

SITE = "https://wow.curseforge.com"
ADDON = "GuildTradebook"
FOREVER_TYPE_ID = 88568  # gameVersionTypeID of "World of Warcraft: Forever" (same as BigWigsMods/packager)


def api(path, token, body=None, content_type=None):
    req = urllib.request.Request(SITE + path, data=body, headers={"X-Api-Token": token})
    if content_type:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"CurseForge answered {e.code} for {path}: {e.read().decode('utf-8', 'replace')[:500]}")


def toc_field(name):
    with open(os.path.join(ROOT, ADDON, ADDON + ".toc"), encoding="utf-8") as f:
        match = re.search(rf"^## {name}: *([^\r\n]+)", f.read(), re.M)
    if not match:
        sys.exit(f"no '## {name}:' line in the TOC")
    return match.group(1).strip()


def game_version_id(token):
    interface = int(toc_field("Interface").split(",")[0])
    wanted = f"{interface // 10000}.{interface // 100 % 100}.{interface % 100}"
    versions = [v for v in api("/api/game/wow/versions", token) if v["gameVersionTypeID"] == FOREVER_TYPE_ID]
    if not versions:
        sys.exit("CurseForge lists no Forever game versions; check FOREVER_TYPE_ID against /api/game/wow/version-types")
    for v in versions:
        if v["name"] == wanted:
            return v["id"], wanted
    newest = max(versions, key=lambda v: v["id"])
    print(f"WARNING: no CurseForge game version \"{wanted}\", using \"{newest['name']}\"", file=sys.stderr)
    return newest["id"], newest["name"]


def multipart(fields, file_path):
    boundary = uuid.uuid4().hex
    parts = []
    for name, value in fields.items():
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode("utf-8")
        )
    parts.append(
        (
            f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{os.path.basename(file_path)}"\r\n'
            "Content-Type: application/zip\r\n\r\n"
        ).encode("utf-8")
    )
    with open(file_path, "rb") as f:
        parts.append(f.read())
    parts.append(f"\r\n--{boundary}--\r\n".encode("utf-8"))
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry-run" in sys.argv
    if len(args) != 2:
        sys.exit(__doc__)
    zip_path, version = args
    token = os.environ.get("CF_API_TOKEN", "")
    if not token:
        sys.exit("CF_API_TOKEN is not set")
    project = toc_field("X-Curse-Project-ID")
    release_type = "alpha" if "alpha" in version.lower() else "beta" if "beta" in version.lower() else "release"
    version_id, version_name = game_version_id(token)
    metadata = {
        "displayName": version,
        "gameVersions": [version_id],
        "releaseType": release_type,
        "changelog": section(version.split("-")[0]),
        "changelogType": "markdown",
    }
    print(f"{os.path.basename(zip_path)} -> CurseForge project {project}, {version_name}, {release_type}")
    if dry:
        print("dry run, nothing uploaded")
        return
    body, content_type = multipart({"metadata": json.dumps(metadata)}, zip_path)
    result = api(f"/api/projects/{project}/upload-file", token, body, content_type)
    print(f"uploaded, file id {result.get('id')}")


if __name__ == "__main__":
    main()
