#!/bin/bash
# Cuts a Sorrel release, and publishes it to GitHub when told to. Installed copies check
# https://github.com/<repo>/releases/latest/download/updates.json (Updater.swift) and install what it names.
#
#   tools/release.sh 0.2.0      cut: bump the version (CFBundleVersion +1), build, zip, sign, write dist/,
#                               commit "Sorrel 0.2.0" and tag v0.2.0. Nothing leaves this Mac.
#   tools/release.sh publish    push the branch and tag, create the GitHub release with the zip and
#                               updates.json (edit dist/notes.md first if you like), then check the feed.
#
# Needs: the signing key (~/.config/sorrel/update-signing-key, or SORREL_UPDATE_KEY), and for publish either
# the gh CLI signed in, or GITHUB_TOKEN (or ~/.config/sorrel/github-token) with "repo"/"contents: write" access.
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

cut_release() {
  local VERSION=$1
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "version should look like 0.2.0, got '$VERSION'"
  [ -f "$KEY" ] || die "no signing key at $KEY (CLAUDE.md, Updates)"
  [ "$(swift tools/update-sign.swift public "$KEY")" = "$PUB" ] || die "$KEY is not the key built into Sorrel ($CORE); installed copies would refuse the update"
  [ -z "$(git status --porcelain --untracked-files=no)" ] || die "commit or set aside your changes first (git status)"
  git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && die "tag v$VERSION already exists"
  local BRANCH; BRANCH=$(git rev-parse --abbrev-ref HEAD)
  [ "$BRANCH" = "main" ] || echo "release: note: cutting from branch '$BRANCH', not main"

  local BUILD; BUILD=$(( $($PB -c "Print :CFBundleVersion" "$PLIST") + 1 ))
  local MINOS; MINOS=$($PB -c "Print :LSMinimumSystemVersion" "$PLIST")
  $PB -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"
  echo "release: Sorrel $VERSION (build $BUILD)"
  ./build.sh

  rm -rf dist; mkdir -p dist
  local ZIP="dist/Sorrel-$VERSION.zip"
  ditto -c -k --keepParent build/Sorrel.app "$ZIP"
  local SIG SHA SIZE
  SIG=$(swift tools/update-sign.swift sign "$KEY" "$ZIP")
  SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
  SIZE=$(stat -f %z "$ZIP")
  swift tools/update-sign.swift verify "$PUB" "$ZIP" "$SIG" >/dev/null || die "the archive doesn't verify with the built-in key"

  # Release notes: what changed since the last tag, plus the first-run note for people new to Sorrel.
  local LAST; LAST=$(git describe --tags --abbrev=0 2>/dev/null || true)
  {
    echo "## Sorrel $VERSION"
    echo
    git log --format='- %s' "${LAST:+$LAST..}HEAD" | grep -v '^- Sorrel [0-9]' || true
    echo
    echo "**New here?** Download the zip, unzip it, drag Sorrel into Applications and open it from there. The first time, macOS says it can't verify the app (Sorrel isn't notarized); go to System Settings ▸ Privacy & Security and choose **Open Anyway**. Sorrel updates itself after that."
  } > dist/notes.md
  cat > dist/release.env <<EOF
VERSION=$VERSION
BUILD=$BUILD
MINOS=$MINOS
URL=https://github.com/$REPO/releases/download/v$VERSION/Sorrel-$VERSION.zip
SIZE=$SIZE
SHA=$SHA
SIG=$SIG
EOF
  write_manifest

  git add "$PLIST"
  git commit -q -m "Sorrel $VERSION (build $BUILD)"
  git tag -a "v$VERSION" -m "Sorrel $VERSION"
  echo
  echo "release: cut. dist/ has the signed zip, updates.json and notes.md (edit the notes if you like)."
  echo "release: to put it in front of users: tools/release.sh publish"
}

publish_release() {
  [ -f dist/release.env ] || die "nothing cut yet (tools/release.sh <version> first)"
  # shellcheck disable=SC1091
  source dist/release.env
  local ZIP="dist/Sorrel-$VERSION.zip"
  [ -f "$ZIP" ] || die "$ZIP is missing"
  git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || die "tag v$VERSION is missing"
  local ORIGIN; ORIGIN=$(git remote get-url origin 2>/dev/null || true)
  [ -n "$ORIGIN" ] || die "no git remote 'origin'. Create the GitHub repository $REPO, then: git remote add origin https://github.com/$REPO.git"
  case "$ORIGIN" in *"$REPO"*) ;; *) die "origin is $ORIGIN but Sorrel looks for updates at $REPO ($CORE); make them match" ;; esac
  write_manifest

  local BRANCH; BRANCH=$(git rev-parse --abbrev-ref HEAD)
  git push origin "$BRANCH"
  git push origin "v$VERSION"

  if command -v gh >/dev/null; then
    gh release create "v$VERSION" "$ZIP" dist/updates.json --repo "$REPO" --title "Sorrel $VERSION" --notes-file dist/notes.md
  else
    local TOKEN=${GITHUB_TOKEN:-$(cat "$HOME/.config/sorrel/github-token" 2>/dev/null || true)}
    [ -n "$TOKEN" ] || die "install the gh CLI (and gh auth login), or put a GitHub token in GITHUB_TOKEN / ~/.config/sorrel/github-token"
    local API="https://api.github.com/repos/$REPO/releases"
    local BODY; BODY=$(python3 -c 'import json,sys; print(json.dumps({"tag_name": "v"+sys.argv[1], "name": "Sorrel "+sys.argv[1], "body": open("dist/notes.md").read(), "draft": False, "prerelease": False}))' "$VERSION")
    local RESP; RESP=$(curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" "$API" -d "$BODY")
    local UPLOAD; UPLOAD=$(python3 -c 'import json,sys; r=json.load(sys.stdin); print(r.get("upload_url","").split("{")[0] or sys.exit("GitHub said: "+json.dumps(r)))' <<<"$RESP")
    for f in "$ZIP" dist/updates.json; do
      local TYPE=application/zip; [[ "$f" == *.json ]] && TYPE=application/json
      curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: $TYPE" --data-binary @"$f" \
        "$UPLOAD?name=$(basename "$f")" >/dev/null
    done
    echo "release: created https://github.com/$REPO/releases/tag/v$VERSION"
  fi

  echo "release: checking the feed…"
  local FEED="https://github.com/$REPO/releases/latest/download/updates.json"
  for _ in 1 2 3 4 5 6; do
    if curl -sSL --fail "$FEED" 2>/dev/null | grep -q "\"build\": $BUILD"; then
      echo "release: $FEED now names build $BUILD. Installed copies pick it up within 6 hours, or from Sorrel ▸ Check for Updates."
      return
    fi
    sleep 5
  done
  echo "release: the feed doesn't name build $BUILD yet; check $FEED in a minute (a draft or prerelease isn't 'latest')."
}

case "${1:-}" in
  publish) publish_release ;;
  "" | -h | --help) sed -n '2,12p' "$0" ;;
  *) cut_release "$1" ;;
esac
