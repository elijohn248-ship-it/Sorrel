# Chromium edition: third-party components

Every dependency is pinned to an exact version with a SHA-256 checksum and is downloaded in CI only; none is committed to git (shared rule 5). Sections are per branch/agent; the CEF prototype adds its own section on its branch.

## Qt WebEngine prototype (`prototypes/qt`, branch `chromium-qt-proto`)

The machine-readable pins (exact file names and SHA-256 of every archive) are in `prototypes/qt/ci/pins.json` and `prototypes/qt/ci/requirements-aqt.txt`. CI refuses any archive whose hash differs or that is not pinned.

| Component | Version | Source | Integrity | License (as used) |
|---|---|---|---|---|
| Qt (qtbase, qtdeclarative, qtsvg, qttools, qttranslations, qtwebchannel, qtpositioning; ICU and Mesa/D3D runtime pieces Qt ships) | 6.12.0 (build 6.12.0-0-202609280346) | `download.qt.io/online/qtsdkrepository` (official open-source repository), installed by aqtinstall | aqtinstall checks each archive against download.qt.io's `.sha256`; then `fetch_deps.py` re-checks every kept archive against the SHA-256 values pinned in `pins.json` (Windows: 10 archives, Linux: 10 archives) | LGPL-3.0 (open-source Qt; also GPL-2.0/GPL-3.0). No Qt account, no commercial licence |
| Qt WebEngine (Chromium inside Qt) | 6.140.0 (package 6.12.0-0-202611110526; Chromium 140.0.7339.264 base, security patches up to 157.0.8103.50) | `download.qt.io/online/qtsdkrepository/{windows_x86,linux_x64}/extensions/qtwebengine/6120/61400/` | Windows `42cb94baf8f9d29a9e8f5710baab6ee036dc32d23053953257aac8fd9a22f39f`; Linux `5d6fc3a04e1d537021780a77b33e209eec3095d41c6bf9b5415ed5d4d9169a40` | LGPL-3.0 / GPL (Qt WebEngine); Chromium's own BSD-3-Clause and bundled third-party licences (listed by Qt in its "Third-Party Code" docs) |
| aqtinstall | 3.3.0 (+ 23 hash-pinned Python dependencies, wheels only) | PyPI | `--require-hashes` (`requirements-aqt.txt`) | MIT (dependencies: MIT/BSD/Apache/LGPL-2.1+ for py7zr) |
| uBlock Origin Lite (Chromium MV3 build, unmodified) | 2026.1122.1948 | `github.com/uBlockOrigin/uBOL-home/releases` | `7cd72ae78fe6fa007193de633d2dec085a0da50f53283e821918a77978d105fb` | GPL-3.0 |
| ffmpeg (Ubuntu package, CI only, makes synthetic codec test files) | Ubuntu 24.04 archive version | Ubuntu archive (apt, signed) | apt's signature checks | LGPL/GPL (encoders used only to make test files; nothing distributed) |

Notes:

- **Why WebEngine is fetched separately from aqtinstall:** since Qt 6.12, Qt WebEngine is a separately versioned product (6.140.x). The newest released aqtinstall (3.3.0, June 2025) only knows the older `extensions/qtwebengine/6120/<arch>` package (a pre-release build from 2026-07-08), not the current `6120/61400` one; aqtinstall's Qt 6.12 support was merged upstream on 2026-11-22 but is not released. So `fetch_deps.py` downloads the 6.140.0 archive by pinned URL and SHA-256 and unpacks it into the Qt prefix.
- **Licences for a future Birch build:** LGPL-3.0 Qt must be linked dynamically (as here), with Qt's licence texts and an offer of the Qt source shipped with the download; Birch itself is GPL-3.0, which is compatible. Qt WebEngine's prebuilt binaries contain no proprietary codecs (H.264/AAC/HEVC) and no Widevine.
- CI artifacts never contain Qt binaries (only logs, screenshots and host summaries), so nothing here is redistributed by this branch.
