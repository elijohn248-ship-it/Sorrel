#!/usr/bin/env python3
"""Download and verify the pinned CEF distribution and uBlock Origin Lite.

Pins live in prototypes/cef/deps.json. A file whose size or checksum differs
from the pin is deleted and the script fails. Nothing here is committed to git.

  python3 -I fetch_deps.py --platform windows64 --dest <dir>
Writes <dir>/cef (unpacked distribution root) and <dir>/ubol (unpacked
extension), and prints the SHA-256 of each archive for THIRD_PARTY.md.
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
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEPS = os.path.join(HERE, "..", "deps.json")
CEF_CDN = "https://cef-builds.spotifycdn.com/"


def download(url, path):
    req = urllib.request.Request(url, headers={"User-Agent": "birch-ci-fetch"})
    with urllib.request.urlopen(req, timeout=600) as r, open(path, "wb") as f:
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


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--platform", required=True, choices=["windows64", "linux64"])
    p.add_argument("--dest", required=True)
    a = p.parse_args()
    deps = json.load(open(DEPS))
    os.makedirs(a.dest, exist_ok=True)
    dl = os.path.join(a.dest, "downloads")
    os.makedirs(dl, exist_ok=True)

    cef = deps["cef"]["files"][a.platform]
    cef_root = os.path.join(a.dest, "cef")
    if os.path.isfile(os.path.join(cef_root, "include", "cef_version.h")):
        print("fetch: cef already unpacked (cache)")
    else:
        arch = os.path.join(dl, cef["name"])
        if not os.path.exists(arch):
            download(CEF_CDN + urllib.parse.quote(cef["name"]), arch)
        sums = {"sha1": cef["sha1"]}
        if cef.get("sha256"):
            sums["sha256"] = cef["sha256"]
        verify(arch, cef["size"], **sums)
        tmp = os.path.join(a.dest, "cef.unpack")
        shutil.rmtree(tmp, ignore_errors=True)
        with tarfile.open(arch, "r:bz2") as t:
            t.extractall(tmp, filter="data")
        top = os.path.join(tmp, os.listdir(tmp)[0])
        shutil.rmtree(cef_root, ignore_errors=True)
        os.replace(top, cef_root)
        shutil.rmtree(tmp, ignore_errors=True)
        os.remove(arch)
        print("fetch: cef unpacked")

    ubol = deps["ubol"]
    ubol_root = os.path.join(a.dest, "ubol")
    if os.path.isfile(os.path.join(ubol_root, "manifest.json")):
        print("fetch: ubol already unpacked (cache)")
    else:
        arch = os.path.join(dl, ubol["name"])
        download(ubol["url"], arch)
        verify(arch, ubol["size"], sha256=ubol["sha256"])
        shutil.rmtree(ubol_root, ignore_errors=True)
        with zipfile.ZipFile(arch) as z:
            for n in z.namelist():
                if n.startswith("/") or ".." in n.split("/"):
                    sys.exit("fetch: unsafe path in uBOL zip")
            z.extractall(ubol_root)
        os.remove(arch)
        # The zip may contain one top-level folder; point at the manifest.
        if not os.path.isfile(os.path.join(ubol_root, "manifest.json")):
            inner = [d for d in os.listdir(ubol_root)
                     if os.path.isfile(os.path.join(ubol_root, d, "manifest.json"))]
            if len(inner) != 1:
                sys.exit("fetch: uBOL manifest not found")
            tmp = ubol_root + ".tmp"
            os.replace(os.path.join(ubol_root, inner[0]), tmp)
            shutil.rmtree(ubol_root)
            os.replace(tmp, ubol_root)
        m = json.load(open(os.path.join(ubol_root, "manifest.json"), encoding="utf-8"))
        print(f"fetch: ubol unpacked manifest_version={m.get('manifest_version')} "
              f"version={m.get('version')}")


if __name__ == "__main__":
    main()
