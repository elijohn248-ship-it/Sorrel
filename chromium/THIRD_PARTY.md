# Chromium edition: third-party components

Every dependency is pinned to an exact version and checksum. Downloads happen
in CI only and are never committed to git. Each prototype/branch keeps its own
section; edit only yours.

## CEF prototype (`prototypes/cef`, branch `chromium-cef-proto`, wave 1)

Pins live in `prototypes/cef/deps.json`; `prototypes/cef/tools/fetch_deps.py`
refuses any file whose size or checksum differs.

| Component | Version | Source | Checksum | License |
|---|---|---|---|---|
| Chromium Embedded Framework, Windows x64 "minimal" distribution | `158.0.3+g8c29be2+chromium-158.0.8127.18` (stable channel, built 2026-11-20) | `https://cef-builds.spotifycdn.com/cef_binary_158.0.3%2Bg8c29be2%2Bchromium-158.0.8127.18_windows64_minimal.tar.bz2` (CEF automated builds) | SHA-1 `a8634573a10fb514fb9e8bc9fcf39016a2fb17bd` (published by the CEF index), size 180,772,981 bytes; SHA-256 recorded by CI below | CEF: BSD-3-Clause. Bundled Chromium: BSD-3-Clause plus the third-party licenses listed in the distribution's `LICENSE.txt` / `CREDITS.html` (LGPL/MPL/Apache/MIT components among them) |
| Chromium Embedded Framework, Linux x64 "minimal" distribution | same version | `https://cef-builds.spotifycdn.com/cef_binary_158.0.3%2Bg8c29be2%2Bchromium-158.0.8127.18_linux64_minimal.tar.bz2` | SHA-1 `620b80a02dfe93ed7884a9eb1b265ff34f799024`, size 338,967,910 bytes; SHA-256 recorded by CI below | as above |
| CEF bootstrap executable (`bootstrapc.exe`, Windows) | ships inside the CEF distribution above | — | covered by the distribution checksum | BSD-3-Clause |
| uBlock Origin Lite, Chromium MV3 build (unmodified) | `2026.1122.1948` | `https://github.com/uBlockOrigin/uBOL-home/releases/download/2026.1122.1948/uBOLite_2026.1122.1948.chromium.zip` | SHA-256 `7cd72ae78fe6fa007193de633d2dec085a0da50f53283e821918a77978d105fb` (GitHub release digest), size 9,192,442 bytes | GPL-3.0 |
| GitHub Actions used by the workflow | checkout v7.0.1, cache v6.1.0, upload-artifact v7.0.2, download-artifact v8.0.2 | pinned by commit SHA in `.github/workflows/chromium-cef-proto.yml` | commit SHAs in the workflow | MIT |
| Media test fixtures | generated in CI by Ubuntu 24.04's `ffmpeg` package | `prototypes/cef/tools/make_media.sh` | not kept | n/a (generated test patterns/tones) |

Licensing note for Birch (GPL-3.0): CEF and Chromium's own code are
BSD-licensed and compatible. Shipping a build means shipping Chromium's
license/credits file with it. Proprietary codecs (H.264/AAC) are not in the
official CEF builds; turning them on means building CEF from source with
`proprietary_codecs=true ffmpeg_branding=Chrome`, which brings patent-licensing
questions the owner would have to decide on.
