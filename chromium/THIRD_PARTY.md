# Chromium edition: third-party components

Every dependency is pinned to an exact version and checksum. Downloads happen
in CI (or on a developer's machine) through `chromium/tools/fetch_deps.py`,
which refuses any file whose size or checksum differs; nothing downloaded is
committed to git (`chromium/deps/` is ignored). Each branch keeps its own
section; edit only yours.

## App shell (`chromium/`, branch `chromium-shell`, wave 2)

Pins live in `chromium/deps.json`. CEF is the same build the wave-1 prototype
proved; on 2026-11-24 the CEF index listed no newer stable build than
158.0.3 (a 156.0.32 maintenance build is newer by date only).

| Component | Version | Source | Checksum | License | How it's used |
|---|---|---|---|---|---|
| Chromium Embedded Framework, Windows x64 "minimal" distribution | `158.0.3+g8c29be2+chromium-158.0.8127.18` (stable, built 2026-11-20) | `https://cef-builds.spotifycdn.com/cef_binary_158.0.3%2Bg8c29be2%2Bchromium-158.0.8127.18_windows64_minimal.tar.bz2` | size 180,772,981; SHA-1 `a8634573a10fb514fb9e8bc9fcf39016a2fb17bd` (CEF index); SHA-256 `a5659888cca36e3b7fde841c05c67f923065c3bb2d62609ba379c7f79986a02b` | CEF: BSD-3-Clause. Chromium: BSD-3-Clause plus the third-party licenses in the distribution's `LICENSE.txt` / `CREDITS.html` | The engine. Its `LICENSE.txt` (and `CREDITS.html` if present) ship in the app's `licenses/` folder |
| Chromium Embedded Framework, Linux x64 "minimal" distribution | same version | `https://cef-builds.spotifycdn.com/cef_binary_158.0.3%2Bg8c29be2%2Bchromium-158.0.8127.18_linux64_minimal.tar.bz2` | size 338,967,910; SHA-1 `620b80a02dfe93ed7884a9eb1b265ff34f799024`; SHA-256 `2c5dfc7c1073f61f2511ab0183e835e0810d6ace7e17811ae9d375faa838fd25` | as above | as above |
| CEF bootstrap executable (`bootstrap.exe`, Windows) | inside the CEF distribution | — | covered by the distribution checksum | BSD-3-Clause | Shipped as `birch.exe` (needed for the Windows sandbox since M138); its icon resources are replaced with Birch's at build time |
| nlohmann/json (single header) | `3.12.0` | `https://github.com/nlohmann/json/releases/download/v3.12.0/json.hpp` | size 953,436; SHA-256 `aaf127c04cb31c406e5b04a63f1ae89369fccde6d8fa7cdda1ed4f32dfc5de63` | MIT (`LICENSE.MIT`, size 1,076, SHA-256 `46a65cffd1ea955132d95a8dd921640714a8d6b537d2e4e482d31145ae95b603`, from the v3.12.0 tag) | JSON for `core/` (state.json, settings.json, …). Fetched like CEF rather than vendored: one pinned path for every dependency, and no 950 KB file in the public repo. Its license ships in `licenses/` |
| GitHub Actions used by `.github/workflows/chromium-shell.yml` | checkout v7.0.1, cache v6.1.0, upload-artifact v7.0.2 | pinned by commit SHA in the workflow | commit SHAs | MIT | CI only |

Birch's icon is made at build time from the Mac app's own
`Resources/AppIcon.icns` (Birch's artwork, GPL-3.0 with the rest of the repo)
by `chromium/tools/make_icons.py`; no third-party code.

Not used in wave 2: uBlock Origin Lite (wave-3 agent 7 pins it; the
prototype's pin was `2026.1122.1948`, SHA-256
`7cd72ae78fe6fa007193de633d2dec085a0da50f53283e821918a77978d105fb`).

Licensing note (Birch is GPL-3.0): CEF, Chromium's own code and nlohmann/json
are compatible. A shipped build must carry Chromium's license/credits file,
which the build copies into `licenses/`. Proprietary codecs (H.264/AAC) and
Widevine are not in the official CEF builds and are not added (owner
decision, 2026-11-24).

## CEF prototype (`prototypes/cef`, branch `chromium-cef-proto`, wave 1)

Same CEF pins as above, recorded on that branch with uBlock Origin Lite
`2026.1122.1948` (see `git show chromium-cef-proto:chromium/THIRD_PARTY.md`).
