#!/usr/bin/env python3
"""Stages the Windows build for the CI artifact "Birch (Chromium) for
Windows" and writes a zip of it for the unpack-and-run test.

  python -I package_windows.py <out/Release> <stage dir> <zip path>

The stage folder holds Birch/ (birch.exe, birch.dll, CEF's files, the icon,
licenses/ and "READ ME.txt"); build leftovers (.pdb, .lib, …) and the spec
test runner are left out.
"""
import os
import shutil
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKIP_EXT = (".pdb", ".lib", ".exp", ".ilk", ".log")
SKIP = {"birch_spec_tests.exe"}


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    src, stage_root, zip_path = sys.argv[1:]
    stage = os.path.join(stage_root, "Birch")
    for d, _, fs in os.walk(src):
        for f in fs:
            if f.endswith(SKIP_EXT) or f in SKIP:
                continue
            p = os.path.join(d, f)
            t = os.path.join(stage, os.path.relpath(p, src))
            os.makedirs(os.path.dirname(t), exist_ok=True)
            shutil.copy2(p, t)
    shutil.copy(os.path.join(HERE, "..", "resources", "README-windows.txt"),
                os.path.join(stage, "READ ME.txt"))
    for needed in ("birch.exe", "birch.dll", "libcef.dll", "birch.png", "licenses"):
        if not os.path.exists(os.path.join(stage, needed)):
            sys.exit(f"package: {needed} missing")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for d, _, fs in os.walk(stage_root):
            for f in fs:
                p = os.path.join(d, f)
                z.write(p, os.path.relpath(p, stage_root))
    total = sum(os.path.getsize(os.path.join(d, f))
                for d, _, fs in os.walk(stage) for f in fs)
    print(f"package: zip {os.path.getsize(zip_path) / 2**20:.1f} MiB, "
          f"unpacked {total / 2**20:.1f} MiB, files "
          f"{sum(len(fs) for _, _, fs in os.walk(stage))}")


if __name__ == "__main__":
    main()
