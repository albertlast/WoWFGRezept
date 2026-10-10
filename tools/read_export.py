"""Reads the JSON of "/gtb export".

Input, either
  - the SavedVariables file: the game writes the export when you /reload or
    log out, to WTF/Account/<ACCOUNT>/SavedVariables/GuildTradebook.lua, as
    a Lua string in GuildTradebookExport["json"];
  - a text file with the "GTB1:..." text of "/gtb export zip" (copied from
    the copy window), or "-" to read that text from stdin.

Usage:
  python tools/read_export.py <file | -> [out.json]

Without out.json the JSON is printed (indented). The format is described at
the top of GuildTradebook/Features/Export.lua.
"""
import base64
import json
import re
import sys
import zlib

ZIP_PREFIX = b"GTB1:"

LUA_ESCAPES = {"n": b"\n", "r": b"\r", "t": b"\t", "a": b"\a", "b": b"\b", "f": b"\f", "v": b"\v",
               "\\": b"\\", '"': b'"', "'": b"'", "\n": b"\n"}


def lua_string(data, start):
    """Decodes the Lua string literal starting at data[start] (a quote)."""
    out = bytearray()
    i = start + 1
    while True:
        c = data[i:i + 1]
        if c == b"":
            raise ValueError("unterminated string")
        if c == b'"':
            return out.decode("utf-8")
        if c == b"\\":
            n = data[i + 1:i + 2].decode("latin-1")
            if n.isdigit():
                digits = re.match(rb"\d{1,3}", data[i + 1:i + 4]).group(0)
                out.append(int(digits))
                i += 1 + len(digits)
                continue
            if n == "\r" and data[i + 2:i + 3] == b"\n":
                out += b"\n"
                i += 3
                continue
            if n not in LUA_ESCAPES:
                raise ValueError("unknown escape \\" + n)
            out += LUA_ESCAPES[n]
            i += 2
            continue
        out += c
        i += 1


def unzip(text):
    """Decodes "GTB1:" + Base64(Deflate(JSON))."""
    packed = base64.b64decode(b"".join(text[len(ZIP_PREFIX):].split()))
    # The game writes raw Deflate (seen on Forever); zlib and gzip are tried
    # too, in case another client wraps it.
    for wbits in (-15, 15, 31):
        try:
            return json.loads(zlib.decompress(packed, wbits).decode("utf-8"))
        except zlib.error:
            continue
    sys.exit("GTB1 text: not a Deflate stream")


def read(path):
    if path == "-":
        data = sys.stdin.buffer.read()
    else:
        with open(path, "rb") as f:
            data = f.read()
    stripped = data.strip().lstrip(b"\xef\xbb\xbf")
    if stripped.startswith(ZIP_PREFIX):
        return unzip(stripped)
    block = re.search(rb"^GuildTradebookExport\s*=\s*\{", data, re.M)
    if not block:
        sys.exit("no GuildTradebookExport in this file: run /gtb export, then /reload")
    key = re.compile(rb'\[\s*"json"\s*\]\s*=\s*"').search(data, block.end())
    if not key:
        sys.exit("GuildTradebookExport has no json field")
    return json.loads(lua_string(data, key.end() - 1))


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    export = read(sys.argv[1])
    text = json.dumps(export, ensure_ascii=False, indent=2)
    if len(sys.argv) > 2:
        with open(sys.argv[2], "w", encoding="utf-8") as f:
            f.write(text)
        print(f"{len(export.get('members', []))} members, {len(export.get('recipes', {}))} recipes -> {sys.argv[2]}")
    else:
        sys.stdout.reconfigure(encoding="utf-8")
        print(text)


if __name__ == "__main__":
    main()
