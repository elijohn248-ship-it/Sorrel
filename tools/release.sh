#!/bin/bash
# Cuts a Birch release (formerly Sorrel), and publishes it to GitHub when told to. Installed copies check
# https://github.com/<repo>/releases/latest/download/updates.json (Updater.swift) and install what it names.
#
#   tools/release.sh 0.2.0      cut: bump the version (CFBundleVersion +1), build, zip, sign, make the disk
#                               image, write dist/, commit "Birch 0.2.0" and tag v0.2.0. Nothing leaves this Mac.
#   tools/release.sh publish    push the branch and tag, create the GitHub release with the zip, updates.json
#                               and the disk image (edit dist/notes.md first if you like), then check the feed.
#   tools/release.sh dmg [app] [out.dmg]   only the disk image step (default build/Birch.app -> dist/), to try it
#
# Needs: the signing key (~/.config/sorrel/update-signing-key, or SORREL_UPDATE_KEY), and for publish either
# the gh CLI signed in, or GITHUB_TOKEN (or ~/.config/sorrel/github-token) with "repo"/"contents: write" access.
# The zip and updates.json are what installed copies update from; the .dmg is only for first downloads.
set -euo pipefail
cd "$(dirname "$0")/.."

CORE=Sources/SorrelUpdateCore/UpdateCore.swift
REPO=$(grep -o 'repository = "[^"]*"' "$CORE" | cut -d'"' -f2)
PUB=$(grep -o 'publicKey = "[^"]*"' "$CORE" | cut -d'"' -f2)
KEY=${SORREL_UPDATE_KEY:-$HOME/.config/sorrel/update-signing-key}
PB=/usr/libexec/PlistBuddy
PLIST=Resources/Info.plist

die() { echo "release: $*" >&2; exit 1; }

write_manifest() {   # from dist/release.env + dist/notes.md -> dist/updates.json
  # shellcheck disable=SC1091
  source dist/release.env
  python3 - "$VERSION" "$BUILD" "$URL" "$SIZE" "$SHA" "$SIG" "$MINOS" dist/notes.md > dist/updates.json <<'EOF'
import json, sys, datetime
v, b, u, size, sha, sig, minos, notes = sys.argv[1:9]
print(json.dumps({"version": v, "build": int(b), "minimumSystemVersion": minos, "url": u, "size": int(size),
                  "sha256": sha, "signature": sig, "date": datetime.date.today().isoformat(),
                  "notes": open(notes).read().strip()}, indent=2, ensure_ascii=False))
EOF
}

# The "drag to Applications" disk image for first downloads: Birch.app, a link to /Applications, a background
# picture with an arrow, and fixed icon positions. Built with hdiutil only. The window's look is a .DS_Store
# written by tools/dmg-layout.swift while the image is mounted hidden (-nobrowse), so no Finder window opens
# and nothing takes focus. Updates never use it: installed copies keep installing the signed zip.
make_dmg() {   # $1 = app bundle, $2 = output .dmg
  local SRC=$1 OUT=$2 VOL=Birch
  local NAME; NAME=$(basename "$SRC")
  [ -d "$SRC/Contents" ] || die "no app at $SRC"
  # The layout names its background by volume name and mount point, so it must mount as /Volumes/$VOL.
  [ -e "/Volumes/$VOL" ] && die "a disk named $VOL is already mounted (/Volumes/$VOL); eject it and try again"
  local TMP; TMP=$(mktemp -d /private/tmp/birch-dmg.XXXXXX)
  swift tools/dmg-layout.swift background "$TMP/bg.png" "$TMP/bg@2x.png"
  tiffutil -cathidpicheck "$TMP/bg.png" "$TMP/bg@2x.png" -out "$TMP/background.tiff" >/dev/null
  local MB; MB=$(( $(du -sm "$SRC" | cut -f1) + 40 ))
  hdiutil create -quiet -size "${MB}m" -fs HFS+ -volname "$VOL" -type UDIF "$TMP/rw.dmg"
  local ATTACHED DEV MNT
  # -noverify also keeps "Checksumming…" lines out of the output, so line 1 is the disk. (macOS 27 calls
  # hdiutil attach/detach deprecated in favour of `diskutil image`, which older macOS doesn't have.)
  ATTACHED=$(hdiutil attach -nobrowse -noverify -noautoopen "$TMP/rw.dmg")
  DEV=$(awk 'NR == 1 { print $1 }' <<<"$ATTACHED")
  MNT=$(awk -F'\t' '$NF ~ /^\/Volumes\// { print $NF }' <<<"$ATTACHED")
  # shellcheck disable=SC2064
  trap "hdiutil detach -quiet -force '$DEV' 2>/dev/null || true" EXIT
  [ "$MNT" = "/Volumes/$VOL" ] || die "the image mounted at '$MNT', not /Volumes/$VOL"

  touch "$MNT/.metadata_never_index"                  # keeps Spotlight from adding its folder
  ditto "$SRC" "$MNT/$NAME"
  ln -s /Applications "$MNT/Applications"
  mkdir "$MNT/.background"
  cp "$TMP/background.tiff" "$MNT/.background/background.tiff"
  if [ -f "$SRC/Contents/Resources/AppIcon.icns" ]; then   # the disk shows Birch's icon
    cp "$SRC/Contents/Resources/AppIcon.icns" "$MNT/.VolumeIcon.icns"
    xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 "$MNT"
  fi
  swift tools/dmg-layout.swift dsstore "$MNT" "$NAME"
  sync
  local tries=0
  until hdiutil detach -quiet "$DEV"; do
    tries=$((tries + 1)); [ $tries -lt 5 ] || die "couldn't eject the image at $MNT"; sleep 2
  done
  trap - EXIT

  mkdir -p "$(dirname "$OUT")"
  hdiutil convert -quiet "$TMP/rw.dmg" -format ULFO -ov -o "$OUT"   # read-only, lzfse-compressed
  rm -f "$TMP/rw.dmg" "$TMP/bg.png" "$TMP/bg@2x.png" "$TMP/background.tiff"; rmdir "$TMP"

  # Signed with the same self-signed identity as the app (build.sh) when it exists; otherwise left unsigned.
  # Either way Gatekeeper warns on first open: there is no notarization (it needs a paid Apple account).
  local KC="${SORREL_SIGNING_DIR:-$HOME/.config/sorrel}/signing.keychain-db" ID=""
  if [ -f "$KC" ]; then
    security unlock-keychain -p "" "$KC"
    ID=$(security find-identity -p codesigning "$KC" | awk '$1 == "1)" { print $2; exit }')
  fi
  if [ -n "$ID" ]; then
    codesign --force --keychain "$KC" --sign "$ID" "$OUT" >/dev/null
    echo "release: signed $OUT"
  else
    echo "release: $OUT is unsigned (no identity in $KC; tools/make-signing-identity.sh makes one)"
  fi
  hdiutil verify -quiet "$OUT" || die "$OUT doesn't verify"
  echo "release: made $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
}

cut_release() {
  local VERSION=$1
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "version should look like 0.2.0, got '$VERSION'"
  [ -f "$KEY" ] || die "no signing key at $KEY (CLAUDE.md, Updates)"
  [ "$(swift tools/update-sign.swift public "$KEY")" = "$PUB" ] || die "$KEY is not the key built into Birch ($CORE); installed copies would refuse the update"
  [ -z "$(git status --porcelain --untracked-files=no)" ] || die "commit or set aside your changes first (git status)"
  git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && die "tag v$VERSION already exists"
  local BRANCH; BRANCH=$(git rev-parse --abbrev-ref HEAD)
  [ "$BRANCH" = "main" ] || echo "release: note: cutting from branch '$BRANCH', not main"

  local BUILD; BUILD=$(( $($PB -c "Print :CFBundleVersion" "$PLIST") + 1 ))
  local MINOS; MINOS=$($PB -c "Print :LSMinimumSystemVersion" "$PLIST")
  $PB -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"
  echo "release: Birch $VERSION (build $BUILD)"
  ./build.sh

  rm -rf dist; mkdir -p dist
  local ZIP="dist/Birch-$VERSION.zip"
  ditto -c -k --keepParent build/Birch.app "$ZIP"
  local SIG SHA SIZE
  SIG=$(swift tools/update-sign.swift sign "$KEY" "$ZIP")
  SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
  SIZE=$(stat -f %z "$ZIP")
  swift tools/update-sign.swift verify "$PUB" "$ZIP" "$SIG" >/dev/null || die "the archive doesn't verify with the built-in key"
  make_dmg build/Birch.app "dist/Birch-$VERSION.dmg"   # after the zip, which it doesn't touch

  # Release notes: what changed since the last tag, plus the first-run note for people new to Birch.
  local LAST; LAST=$(git describe --tags --abbrev=0 2>/dev/null || true)
  {
    echo "## Birch $VERSION"
    echo
    git log --format='- %s' "${LAST:+$LAST..}HEAD" | grep -v -E '^- (Sorrel|Birch) [0-9]' || true
    echo
    echo "**New here?** Download **Birch-$VERSION.dmg**, open it and drag Birch onto the Applications folder, then open Birch from Applications. (The zip works too: unzip it and drag Birch into Applications.) The first time, macOS says it can't verify the app (Birch isn't notarized); go to System Settings ▸ Privacy & Security and choose **Open Anyway**. Birch updates itself after that. (Birch was called Sorrel until 0.3.1: copies already installed update to Birch by themselves.)"
  } > dist/notes.md
  cat > dist/release.env <<EOF
VERSION=$VERSION
BUILD=$BUILD
MINOS=$MINOS
URL=https://github.com/$REPO/releases/download/v$VERSION/Birch-$VERSION.zip
SIZE=$SIZE
SHA=$SHA
SIG=$SIG
EOF
  write_manifest

  git add "$PLIST"
  git commit -q -m "Birch $VERSION (build $BUILD)"
  git tag -a "v$VERSION" -m "Birch $VERSION"
  echo
  echo "release: cut. dist/ has the signed zip, updates.json, the disk image and notes.md (edit the notes if you like)."
  echo "release: to put it in front of users: tools/release.sh publish"
}

publish_release() {
  [ -f dist/release.env ] || die "nothing cut yet (tools/release.sh <version> first)"
  # shellcheck disable=SC1091
  source dist/release.env
  local ZIP="dist/Birch-$VERSION.zip"
  [ -f "$ZIP" ] || die "$ZIP is missing"
  local DMG="dist/Birch-$VERSION.dmg"
  [ -f "$DMG" ] || die "$DMG is missing (tools/release.sh dmg makes it from build/Birch.app)"
  git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || die "tag v$VERSION is missing"
  local ORIGIN; ORIGIN=$(git remote get-url origin 2>/dev/null || true)
  [ -n "$ORIGIN" ] || die "no git remote 'origin'. Create the GitHub repository $REPO, then: git remote add origin https://github.com/$REPO.git"
  case "$ORIGIN" in *"$REPO"*) ;; *) die "origin is $ORIGIN but Birch looks for updates at $REPO ($CORE); make them match" ;; esac
  write_manifest

  local BRANCH; BRANCH=$(git rev-parse --abbrev-ref HEAD)
  git push origin "$BRANCH"
  git push origin "v$VERSION"

  if command -v gh >/dev/null; then
    gh release create "v$VERSION" "$ZIP" dist/updates.json "$DMG" --repo "$REPO" --title "Birch $VERSION" --notes-file dist/notes.md
  else
    local TOKEN=${GITHUB_TOKEN:-$(cat "$HOME/.config/sorrel/github-token" 2>/dev/null || true)}
    [ -n "$TOKEN" ] || die "install the gh CLI (and gh auth login), or put a GitHub token in GITHUB_TOKEN / ~/.config/sorrel/github-token"
    local API="https://api.github.com/repos/$REPO/releases"
    # The token goes to curl as a header file, never as an argument: arguments show in `ps` to every process.
    # (printf is a shell builtin, so it never runs as a process of its own either.)
    auth() { printf 'Authorization: Bearer %s\n' "$TOKEN"; }
    local BODY; BODY=$(python3 -c 'import json,sys; print(json.dumps({"tag_name": "v"+sys.argv[1], "name": "Birch "+sys.argv[1], "body": open("dist/notes.md").read(), "draft": False, "prerelease": False}))' "$VERSION")
    local RESP; RESP=$(curl -sS -X POST -H @<(auth) -H "Accept: application/vnd.github+json" "$API" -d "$BODY")
    local UPLOAD; UPLOAD=$(python3 -c 'import json,sys; r=json.load(sys.stdin); print(r.get("upload_url","").split("{")[0] or sys.exit("GitHub said: "+json.dumps(r)))' <<<"$RESP")
    for f in "$ZIP" dist/updates.json; do
      local TYPE=application/zip; [[ "$f" == *.json ]] && TYPE=application/json
      curl -sS -X POST -H @<(auth) -H "Content-Type: $TYPE" --data-binary @"$f" \
        "$UPLOAD?name=$(basename "$f")" >/dev/null
    done
    # The disk image goes last, after the feed is complete: if it fails, updates are unaffected.
    local CODE; CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H @<(auth) \
      -H "Content-Type: application/x-apple-diskimage" --data-binary @"$DMG" "$UPLOAD?name=$(basename "$DMG")")
    [ "$CODE" = 201 ] || echo "release: uploading $DMG failed (HTTP $CODE); add it to the release by hand on GitHub"
    echo "release: created https://github.com/$REPO/releases/tag/v$VERSION"
  fi

  echo "release: checking the feed…"
  local FEED="https://github.com/$REPO/releases/latest/download/updates.json"
  for _ in 1 2 3 4 5 6; do
    if curl -sSL --fail "$FEED" 2>/dev/null | grep -q "\"build\": $BUILD"; then
      echo "release: $FEED now names build $BUILD. Installed copies pick it up within 6 hours, or from Birch ▸ Check for Updates."
      return
    fi
    sleep 5
  done
  echo "release: the feed doesn't name build $BUILD yet; check $FEED in a minute (a draft or prerelease isn't 'latest')."
}

case "${1:-}" in
  publish) publish_release ;;
  dmg)
    APP=${2:-build/Birch.app}
    make_dmg "$APP" "${3:-dist/Birch-$($PB -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist").dmg}" ;;
  "" | -h | --help) sed -n '2,13p' "$0" ;;
  *) cut_release "$1" ;;
esac
