#!/usr/bin/env python3
"""Package a CI-only Ubuntu 24.04/Zorin test .deb, never publish a release.

python3 -I package_linux_test.py out/Release linux-package-work dist-linux REV
Uses only the existing build, local resources and Debian's packaging tools.
"""
import hashlib
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys

RESOURCES = Path(__file__).resolve().parent.parent / "resources/linux-test"
NAME = "birch-chromium-test"
SKIP = {"birch_spec_tests", "birch_ui_channel_tests", "birch.ico"}


def write(path, text, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    path.chmod(mode)


def main():
    if len(sys.argv) != 5 or not re.fullmatch(r"[0-9a-f]{7,40}", sys.argv[4]):
        sys.exit(__doc__)
    src, work, dest = [Path(p).resolve() for p in sys.argv[1:4]]
    revision = sys.argv[4]
    if work.exists():
        sys.exit("package: work folder must be new (nothing is deleted)")
    root = work / "root"
    app = root / "opt" / NAME
    for source in sorted(src.rglob("*")):
        if source.is_symlink():
            sys.exit("package: unexpected symlink: " + str(source.relative_to(src)))
        if not source.is_file() or source.name in SKIP or source.suffix in (
                ".a", ".o", ".log", ".debug", ".pdb"):
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
    size = sum(p.stat().st_size for p in app.rglob("*") if p.is_file())
    write(root / "DEBIAN/control", f"""Package: {NAME}
Version: 0.0.0+git{revision[:12]}
Architecture: amd64
Section: web
Priority: optional
Maintainer: Birch contributors <noreply@users.noreply.github.com>
Depends: {dependencies}, apparmor
Installed-Size: {(size + 1023) // 1024}
Homepage: https://github.com/elijohn248-ship-it/Sorrel
Description: Early Birch Chromium interface test for Ubuntu 24.04 and Zorin 18
 Basic tabs and HTML sidebar. Browser privacy features are incomplete.
 Uses a separate test profile; no automatic updater or default-browser change.
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
    package = dest / "Birch-Chromium-Test-amd64.deb"
    subprocess.run(["dpkg-deb", "--root-owner-group", "-Zxz", "-z6",
                    "--threads-max=2", "--build", str(root), str(package)], check=True)
    shutil.copyfile(RESOURCES / "READ-ME.txt", dest / "READ-ME.txt")
    digest = hashlib.sha256(package.read_bytes()).hexdigest()
    write(dest / "SHA256SUMS", f"{digest}  {package.name}\n")
    print(f"package: {package.name} {package.stat().st_size / 2**20:.1f} MiB")
    print("package: dependencies " + dependencies + ", apparmor")


if __name__ == "__main__":
    main()
