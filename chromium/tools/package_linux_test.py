#!/usr/bin/env python3
"""Package a CI-only Ubuntu 24.04/Zorin test .deb, never publish a release.

python3 -I package_linux_test.py out/Release linux-package-work dist-linux REV [--build RUN_ID]
Uses only the existing build, local resources and Debian's packaging tools.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys

CHROMIUM = Path(__file__).resolve().parent.parent
RESOURCES = CHROMIUM / "resources/linux-test"
NAME = "birch-chromium-test"
REPOSITORY = "elijohn248-ship-it/Sorrel"
FEED_TAG = "chromium-linux-test"
FEED_NAME = "updates-linux-test.json"
DOWNLOAD_ROOT = f"https://github.com/{REPOSITORY}/releases/download"
FEED = f"{DOWNLOAD_ROOT}/{FEED_TAG}/{FEED_NAME}"
MAX_BUILD = 2**53 - 1
PACKAGE_FILE = "Birch-Chromium-Test-amd64.deb"
IDENTITY = {
    "schema": 1, "channel": "linux-test", "edition": "chromium",
    "os": "linux", "arch": "x86_64", "package": NAME,
}


def write(path, text, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    path.chmod(mode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("src", "work", "dest"):
        parser.add_argument(name, type=Path)
    parser.add_argument("revision")
    parser.add_argument("--build", type=int, default=0)
    args = parser.parse_args()
    src, work, dest = [path.resolve() for path in (args.src, args.work, args.dest)]
    revision, build = args.revision, args.build
    if not 0 <= build <= MAX_BUILD:
        parser.error("build is outside the supported range")
    if not re.fullmatch(r"[0-9a-f]{40}" if build else r"[0-9a-f]{7,40}", revision):
        parser.error("revision must be a Git SHA (full SHA when an updater is included)")
    if work.exists():
        sys.exit("package: work folder must be new (nothing is deleted)")
    root = work / "root"
    app = root / "opt" / NAME
    for source in sorted(src.rglob("*")):
        if source.is_symlink():
            sys.exit("package: unexpected symlink: " + str(source.relative_to(src)))
        if (not source.is_file() or source.name in {"birch.ico", "linux-updater.py", "update-config.json"}
                or source.stem.endswith("_tests") or source.suffix in (".a", ".o", ".log", ".debug", ".pdb")):
            continue
        target = app / source.relative_to(src)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        # Never carry setuid/setgid bits into the test package.
        target.chmod(0o755 if source.stat().st_mode & 0o111 else 0o644)
    for needed in ("birch", "libcef.so", "birch.png", "licenses"):
        if not (app / needed).exists():
            sys.exit("package: missing " + needed)
    (app / "birch").chmod(0o755)
    config = None
    version = f"0.0.0+git{revision[:12]}"
    if build:
        version = f"0.0.0+test.{build}"
        config = {**IDENTITY, "build": build, "version": version, "revision": revision,
                  "feed": FEED, "public_key_pem": (RESOURCES / "update-public-key.pem").read_text()}
        write(app / "update-config.json", json.dumps(config, sort_keys=True) + "\n")
        write(app / "linux-updater.py", (CHROMIUM / "update/linux_updater.py").read_text(), 0o755)

    # Derive runtime dependencies from every shipped ELF, including CEF's
    # libraries, rather than relying on the CI runner's extra installed apps.
    write(work / "debian/control", f"""Source: {NAME}
Section: web
Priority: optional
Maintainer: Birch contributors <noreply@users.noreply.github.com>

Package: {NAME}
Architecture: amd64
Description: Early Birch Chromium interface test
""")
    elfs = []
    for path in app.rglob("*"):
        if path.is_file():
            with path.open("rb") as stream:
                if stream.read(4) == b"\x7fELF":
                    elfs.append(path)
    result = subprocess.check_output(
        ["dpkg-shlibdeps", "-O", "--ignore-missing-info", "-l" + str(app)] +
        ["-e" + str(p) for p in elfs], cwd=work, text=True)
    dependencies = next(line.split("=", 1)[1] for line in result.splitlines()
                        if line.startswith("shlibs:Depends="))
    dependencies += ", apparmor"
    if build:
        dependencies += ", python3, openssl, pkexec, libglib2.0-bin, gsettings-desktop-schemas"
    size = sum(p.stat().st_size for p in app.rglob("*") if p.is_file())
    write(root / "DEBIAN/control", f"""Package: {NAME}
Version: {version}
Architecture: amd64
Section: web
Priority: optional
Maintainer: Birch contributors <noreply@users.noreply.github.com>
Depends: {dependencies}
Installed-Size: {(size + 1023) // 1024}
Homepage: https://github.com/elijohn248-ship-it/Sorrel
Description: Early Birch Chromium interface test for Ubuntu 24.04 and Zorin 18
 Basic tabs and HTML sidebar. Browser privacy features are incomplete.
 Uses a separate test profile and leaves your default browser setting intact.
""")
    files = {
        "birch-chromium-test": (f"usr/bin/{NAME}", 0o755),
        "birch-chromium-test.desktop": (f"usr/share/applications/{NAME}.desktop", 0o644),
        "apparmor": (f"etc/apparmor.d/{NAME}", 0o644),
        "postinst": ("DEBIAN/postinst", 0o755),
        "postrm": ("DEBIAN/postrm", 0o755),
        "READ-ME.txt": (f"usr/share/doc/{NAME}/README", 0o644),
    }
    for source, (relative, mode) in files.items():
        write(root / relative, (RESOURCES / source).read_text(), mode)
    icon = root / f"usr/share/icons/hicolor/256x256/apps/{NAME}.png"
    icon.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(app / "birch.png", icon)
    write(root / "DEBIAN/conffiles", f"/etc/apparmor.d/{NAME}\n")
    for path in root.rglob("*"):
        if path.is_dir():
            path.chmod(0o755)
        elif path.stat().st_mode & (stat.S_ISUID | stat.S_ISGID):
            sys.exit("package: privileged file mode refused")
    dest.mkdir(parents=True, exist_ok=True)
    package = dest / PACKAGE_FILE
    subprocess.run(["dpkg-deb", "--root-owner-group", "-Zxz", "-z6",
                    "--threads-max=2", "--build", str(root), str(package)], check=True)
    shutil.copyfile(RESOURCES / "READ-ME.txt", dest / "READ-ME.txt")
    sha256 = hashlib.sha256()
    with package.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            sha256.update(block)
    digest = sha256.hexdigest()
    write(dest / "SHA256SUMS", f"{digest}  {package.name}\n")
    if config is not None:
        info = {**config, "size": package.stat().st_size, "sha256": digest}
        write(dest / "build-info.json", json.dumps(info, sort_keys=True, indent=2) + "\n")
    print(f"package: {package.name} {package.stat().st_size / 2**20:.1f} MiB")
    print("package: dependencies " + dependencies)


if __name__ == "__main__":
    main()
