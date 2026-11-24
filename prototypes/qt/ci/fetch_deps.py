#!/usr/bin/env python3
"""Fetch and verify the pinned third-party pieces for the Qt WebEngine prototype (CI only).

  fetch_deps.py qt <windows|linux> <qt-root> <archive-dir>
      Qt 6.12.0 base + qtwebchannel + qtpositioning through the pinned aqtinstall
      (aqt checks each archive against download.qt.io's own .sha256 files), then
      every archive aqt kept is checked again against ci/pins.json; an archive
      that is missing from the pins or differs fails the step.
      Then Qt WebEngine 6.140.0 (separately versioned since Qt 6.12; aqtinstall
      3.3.0 predates that layout) is downloaded by pinned URL, checked against its
      pinned SHA-256 and unpacked into the Qt prefix.

  fetch_deps.py ubol <out-dir>
      uBlock Origin Lite's Chromium MV3 zip from the pinned upstream release,
      checked against its pinned SHA-256. Unmodified; never committed to git.

Nothing here reads secrets or the owner's data. Run with `python -I`.
"""
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
PINS = json.loads((HERE / "pins.json").read_text(encoding="utf-8"))


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url, dest, expected_sha):
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and sha256_file(dest) == expected_sha:
        print(f"deps: cached {dest.name} sha256 ok")
        return dest
    last = None
    for attempt in range(4):
        try:
            tmp = dest.with_suffix(dest.suffix + ".part")
            with urllib.request.urlopen(url, timeout=120) as r, open(tmp, "wb") as f:
                while True:
                    chunk = r.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
            got = sha256_file(tmp)
            if got != expected_sha:
                tmp.unlink()
                raise SystemExit(f"deps: SHA-256 MISMATCH for {url}: expected={expected_sha} got={got}")
            tmp.replace(dest)
            print(f"deps: downloaded {dest.name} sha256 expected={expected_sha} got={got}")
            return dest
        except SystemExit:
            raise
        except Exception as e:  # network hiccup: retry
            last = e
            time.sleep(5 * (attempt + 1))
    raise SystemExit(f"deps: download failed for {url}: {last}")


def verify_kept_archives(osname, archive_dir):
    import re
    pins = PINS["qt"]["base_archives_sha256"][osname]
    by_name = {}
    for full, sha in pins.items():
        by_name[full] = sha
        # aqt may keep the archive with or without the "6.12.0-0-<build>" prefix
        by_name[re.sub(r"^\d+\.\d+\.\d+-\d+-\d+", "", full)] = sha
    files = sorted(p for p in Path(archive_dir).rglob("*.7z") if "webengine" not in p.parts)
    if not files:
        raise SystemExit("deps: aqt kept no archives; cannot verify pins")
    bad = 0
    seen = set()
    for f in files:
        got = sha256_file(f)
        exp = by_name.get(f.name)
        status = "ok" if exp == got else ("UNPINNED" if exp is None else "MISMATCH")
        print(f"deps: qt-archive {f.name} expected={exp} got={got} {status}")
        if status != "ok":
            bad += 1
        seen.add(got)
    missing = [n for n, s in pins.items() if s not in seen]
    for n in missing:
        print(f"deps: pinned archive not downloaded by aqt (ok if aqt skipped it): {n}")
    if bad:
        raise SystemExit(f"deps: {bad} Qt archive(s) failed the pin check")


def install_qt(osname, qt_root, archive_dir):
    q = PINS["qt"]
    arch = q["windows_arch"] if osname == "windows" else q["linux_arch"]
    host = "windows" if osname == "windows" else "linux"
    cmd = [sys.executable, "-m", "aqt", "install-qt", host, "desktop", q["version"], arch,
           "-m", *q["modules"], "-O", str(qt_root), "--keep", "--archive-dest", str(archive_dir)]
    print("deps: " + " ".join(cmd[2:]))
    subprocess.run(cmd, check=True)
    verify_kept_archives(osname, archive_dir)

    we = PINS["webengine"][osname]
    arc = download(we["url"], Path(archive_dir) / "webengine" / Path(we["url"]).name, we["sha256"])
    import py7zr  # installed (hash-pinned) as an aqtinstall dependency
    dest = Path(qt_root) / we["dest"]
    with py7zr.SevenZipFile(arc, "r") as z:
        z.extractall(path=dest)
    print(f"deps: Qt WebEngine {PINS['webengine']['version']} unpacked into {dest}")


def fetch_ubol(out_dir):
    u = PINS["ubol"]
    out = Path(out_dir)
    z = download(u["url"], out / Path(u["url"]).name, u["sha256"])
    (out / "ubol-zip-path.txt").write_text(str(z), encoding="utf-8")
    print(f"deps: uBOL Lite {u['version']} ready (unmodified zip)")


def main(argv):
    if len(argv) >= 4 and argv[0] == "qt":
        install_qt(argv[1], Path(argv[2]), Path(argv[3]))
    elif len(argv) == 2 and argv[0] == "ubol":
        fetch_ubol(argv[1])
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
