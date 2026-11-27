#!/usr/bin/env python3
"""Downloads and verifies the Chromium edition's pinned dependencies
(chromium/deps.json): CEF's minimal binary distribution and nlohmann/json.
A file whose size or checksum differs from the pin is deleted and the script
fails. Nothing here is committed to git (chromium/deps/ is ignored).

  python3 -I fetch_deps.py --dest <dir> [--platform windows64|linux64] [--json-only]

Writes <dir>/cef (the unpacked CEF distribution) and
<dir>/nlohmann/include/nlohmann/json.hpp (+ LICENSE.MIT).
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import tarfile
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DEPS = os.path.join(HERE, "..", "deps.json")
CEF_CDN = "https://cef-builds.spotifycdn.com/"


def download(url, path):
    req = urllib.request.Request(url, headers={"User-Agent": "birch-ci-fetch"})
    with urllib.request.urlopen(req, timeout=900) as r, open(path, "wb") as f:
        shutil.copyfileobj(r, f, 1 << 20)


def digest(path, algo):
    h = hashlib.new(algo)
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def verify(path, size, **sums):
    actual = os.path.getsize(path)
    if actual != size:
        os.remove(path)
        sys.exit(f"fetch: {os.path.basename(path)} size {actual} != pinned {size}")
    for algo, want in sums.items():
        got = digest(path, algo)
        if got != want:
            os.remove(path)
            sys.exit(f"fetch: {os.path.basename(path)} {algo} {got} != pinned {want}")
    print(f"fetch: verified {os.path.basename(path)} size={size} "
          + " ".join(f"{a}={w}" for a, w in sums.items()))


def fetch_json(deps, dest):
    pin = deps["nlohmann_json"]
    root = os.path.join(dest, "nlohmann")
    inc = os.path.join(root, "include", "nlohmann")
    os.makedirs(inc, exist_ok=True)
    for name, f in pin["files"].items():
        target = os.path.join(inc if name.endswith(".hpp") else root, name)
        if os.path.isfile(target):
            verify(target, f["size"], sha256=f["sha256"])  # cache: re-check
            continue
        tmp = target + ".download"
        download(f["url"], tmp)
        verify(tmp, f["size"], sha256=f["sha256"])
        os.replace(tmp, target)
    print(f"fetch: nlohmann/json {pin['version']} ready")


def fetch_cef(deps, dest, platform):
    cef = deps["cef"]["files"][platform]
    cef_root = os.path.join(dest, "cef")
    marker = os.path.join(cef_root, "birch-pin.txt")
    if os.path.isfile(marker) and open(marker).read().strip() == cef["sha256"]:
        print("fetch: cef already unpacked (cache)")
        return
    dl = os.path.join(dest, "downloads")
    os.makedirs(dl, exist_ok=True)
    arch = os.path.join(dl, cef["name"])
    if not os.path.exists(arch):
        download(CEF_CDN + urllib.parse.quote(cef["name"]), arch)
    verify(arch, cef["size"], sha1=cef["sha1"], sha256=cef["sha256"])
    tmp = os.path.join(dest, "cef.unpack")
    shutil.rmtree(tmp, ignore_errors=True)
    with tarfile.open(arch, "r:bz2") as t:
        t.extractall(tmp, filter="data")
    top = os.path.join(tmp, os.listdir(tmp)[0])
    shutil.rmtree(cef_root, ignore_errors=True)
    os.replace(top, cef_root)
    shutil.rmtree(tmp, ignore_errors=True)
    os.remove(arch)
    with open(marker, "w") as f:
        f.write(cef["sha256"] + "\n")
    print(f"fetch: cef {deps['cef']['version']} unpacked")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--dest", required=True)
    p.add_argument("--platform", choices=["windows64", "linux64"])
    p.add_argument("--json-only", action="store_true")
    a = p.parse_args()
    deps = json.load(open(DEPS))
    os.makedirs(a.dest, exist_ok=True)
    fetch_json(deps, a.dest)
    if not a.json_only:
        if not a.platform:
            sys.exit("fetch: --platform is required for CEF")
        fetch_cef(deps, a.dest, a.platform)


if __name__ == "__main__":
    main()
