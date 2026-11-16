#!/bin/bash
# End-to-end test of Sorrel's updater, using build/SorrelTest.app only (never Sorrel.app or the real profile).
#
#   tools/update-test.sh            full run
#   tools/update-test.sh /Applications   (or another folder) put the "installed" copy there instead of /private/tmp,
#                                   to test the swap where the real app lives; it is removed again afterwards
#
# What it does, all under /private/tmp/sorrel-update-test:
#   1. copies SorrelTest.app to app/ as the "installed" copy, and makes two fake newer builds of the same app
#      (CFBundleVersion +1 and +2, re-signed), zipped and signed with the owner's key (~/.config/sorrel/update-signing-key)
#   2. check:   a run that finds build+1, downloads and verifies it, and quits WITHOUT installing
#   3. tamper:  the same with a wrong signature; must be refused
#   4. install: Sorrel ▸ Relaunch to Update path (relaunch off in tests); the installer swaps the bundle after the app quits
#   5. quit:    install-on-quit path with build+2
#   6. version: the swapped app runs and reports the new build
#   7. badlog:  the updater service must refuse every log path that isn't the app's own update.log
#   8. swapzip: the zip is overwritten right after the handoff; the service must still install the bytes it checked
#   9. card:    the "update ready" card at the bottom of the sidebar: ready -> Update and Restart -> "Updated";
#               then a broken update (signed, but its app fails codesign) -> "Update didn't install" with the reason,
#               never "ready" again -> Try Again fails too -> "couldn't install" (gave up), and install on quit stops
#               trying. Pictures of each card go to $T/cards.
# Each app launch is a quiet background test run (SORREL_SNAPSHOT), so nothing takes focus.
set -euo pipefail
cd "$(dirname "$0")/.."
KEY=${SORREL_UPDATE_KEY:-$HOME/.config/sorrel/update-signing-key}
[ -f "$KEY" ] || { echo "No signing key at $KEY (see CLAUDE.md, Updates)"; exit 1; }
[ -d build/SorrelTest.app ] || { echo "Run ./build.sh first"; exit 1; }

T=/private/tmp/sorrel-update-test
APPDIR=${1:-$T/app}
PB=/usr/libexec/PlistBuddy
rm -rf "$T"
mkdir -p "$T/feed" "$T/home" "$APPDIR"
APP="$APPDIR/SorrelTest.app"
rm -rf "$APP"
cp -R build/SorrelTest.app "$APP"
xattr -cr "$APP"
BASE=$($PB -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
SHORT=$($PB -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "installed copy: $APP (version $SHORT, build $BASE)"

fake_release() {   # $1 = build number, $2 = "broken" for an app that fails codesign --verify; writes feed/Sorrel-<build>.zip
  local B=$1 DIR="$T/new-$1"
  rm -rf "$DIR"; mkdir -p "$DIR"
  cp -R build/SorrelTest.app "$DIR/SorrelTest.app"
  $PB -c "Set :CFBundleVersion $B" -c "Set :CFBundleShortVersionString $SHORT-test$B" "$DIR/SorrelTest.app/Contents/Info.plist"
  codesign --force --options runtime --sign - "$DIR/SorrelTest.app/Contents/XPCServices/SorrelUpdater.xpc" >/dev/null
  codesign --force --options runtime --entitlements .build/test-bundle/Sorrel.entitlements --sign - "$DIR/SorrelTest.app" >/dev/null
  # Broken: a sealed resource changed after signing. The archive's own signature is still valid.
  if [ "${2:-}" = broken ]; then echo "tampered" >> "$DIR/SorrelTest.app/Contents/Resources/welcome.html"; fi
  local ZIP="$T/feed/Sorrel-$B.zip"
  ditto -c -k --keepParent "$DIR/SorrelTest.app" "$ZIP"
  local SIG SHA SIZE
  SIG=$(swift tools/update-sign.swift sign "$KEY" "$ZIP")
  SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
  SIZE=$(stat -f %z "$ZIP")
  cat > "$T/feed/updates-$B.json" <<EOF
{ "version": "$SHORT-test$B", "build": $B, "minimumSystemVersion": "15.4",
  "url": "file://$ZIP", "size": $SIZE, "sha256": "$SHA", "signature": "$SIG",
  "date": "$(date +%F)", "notes": "Test build $B" }
EOF
  # A tampered copy: the right file, the wrong signature.
  sed 's|"signature": "[^"]*"|"signature": "'"$(swift tools/update-sign.swift sign "$KEY" build.sh)"'"|' "$T/feed/updates-$B.json" > "$T/feed/updates-$B-bad.json"
}
fake_release $((BASE + 1))
fake_release $((BASE + 2))
fake_release $((BASE + 3))
fake_release $((BASE + 4))
fake_release $((BASE + 5)) broken

run() {   # $1 = SORREL_UPDATETEST mode, $2 = feed file
  rm -rf "$T/home/Updates"   # a fresh download each time
  SORREL_HOME="$T/home" SORREL_SNAPSHOT="$T/shot.png" SORREL_DELAY=60 SORREL_UPDATETEST="$1" \
    SORREL_UPDATE_FEED="file://$2" "$APP/Contents/MacOS/Sorrel" 2>&1 | grep -E '^updater:' || true
}
wait_for_install() {   # waits until the detached installer has written its last line
  for _ in $(seq 1 120); do
    grep -q "installer: installed\|installer: refused\|failed\|giving up" "$T/home/Updates/update.log" 2>/dev/null && break
    sleep 0.5
  done
  sed 's/^/  log: /' "$T/home/Updates/update.log"
  echo "  now: version $($PB -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist") build $($PB -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")" \
       "quarantine=$(xattr -l "$APP/Contents/MacOS/Sorrel" | grep -c quarantine || true)" \
       "leftovers=$(ls -d "$APPDIR"/.sorrel-* "$APP"/.sorrel-* "$APP"/Contents.old-* 2>/dev/null | wc -l | tr -d ' ')"
}

echo "== version"; run version "$T/feed/updates-$((BASE + 1)).json"
echo "== check (no install)"; run check "$T/feed/updates-$((BASE + 1)).json"
echo "   zip kept: $(ls "$T/home/Updates"/*.zip 2>/dev/null | wc -l | tr -d ' '), app still build $($PB -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")"
echo "== tamper (must be refused)"; run check "$T/feed/updates-$((BASE + 1))-bad.json"
echo "== install (Relaunch to Update)"; run install "$T/feed/updates-$((BASE + 1)).json"; wait_for_install
echo "== version after install"; run version "$T/feed/updates-$((BASE + 1)).json"
echo "== quit (install on quit)"; run quit "$T/feed/updates-$((BASE + 2)).json"; wait_for_install
echo "== version after quit-install"; run version "$T/feed/updates-$((BASE + 2)).json"
echo "== already current (no newer build)"; run check "$T/feed/updates-$((BASE + 2)).json"
echo "== bad log paths (each must be refused)"; run badlog "$T/feed/updates-$((BASE + 3)).json"
echo "== zip swapped after handoff (must still install the checked bytes; logs inside the app's container, like the real app)"
run swapzip "$T/feed/updates-$((BASE + 3)).json"
for _ in $(seq 1 40); do [ "$($PB -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")" = "$((BASE + 3))" ] && break; sleep 0.5; done
sleep 1; run containerlog "$T/feed/updates-$((BASE + 3)).json" | grep containerlog: | sed 's/^updater: containerlog: /  log: /'
echo "== version after swapzip"; run version "$T/feed/updates-$((BASE + 3)).json"
echo "   private copies left: $(ls "$HOME/Library/Caches/app.sorrel.browser.test.updater" 2>/dev/null | wc -l | tr -d ' ') (in ~/Library/Caches/app.sorrel.browser.test.updater)"

echo "== card (the sidebar's update card)"
mkdir -p "$T/cards"
rm -rf "$T/home/Updates"
card() {   # $1 = mode, $2 = feed file, $3 = picture name; keeps Updates/ (marker, failure count, log) between runs
  SORREL_HOME="$T/home" SORREL_SNAPSHOT="$T/shot.png" SORREL_DELAY=60 SORREL_UPDATETEST="$1" SORREL_CARDSHOTS="$T/cards" \
    SORREL_CARDSTEP="$3" SORREL_UPDATE_FEED="file://$2" "$APP/Contents/MacOS/Sorrel" 2>&1 | grep -E '^updater: (card|launch|install failed|install on quit)' || true
}
wait_new() {   # waits for the installer started after log line $1 to finish (including its reopen step), then prints its lines
  for _ in $(seq 1 240); do
    tail -n +$(($1 + 1)) "$T/home/Updates/update.log" 2>/dev/null | grep -q "reopen\|giving up" && break
    sleep 0.5
  done
  tail -n +$(($1 + 1)) "$T/home/Updates/update.log" | grep installer: | sed 's/^/  log: /'
  echo "  now: build $($PB -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")"
}
loglines() { wc -l < "$T/home/Updates/update.log" 2>/dev/null | tr -d ' ' || echo 0; }
GOOD="$T/feed/updates-$((BASE + 4)).json"; BROKEN="$T/feed/updates-$((BASE + 5)).json"
echo "-- 1. an update is ready (expect: none at launch, ready after the check, the box, ×)"; card card "$GOOD" 1-ready
echo "-- 2. Update and Restart (expect: updating, then installed and reopened)"; N=$(loglines); card relaunch "$GOOD" 2-relaunch; wait_new "$N"
echo "-- 3. next launch (expect: Updated to …-test$((BASE + 4)), and still that after the check, never ready)"; card card "$GOOD" 3-updated
echo "-- 4. a broken update (expect: installer fails codesign, still reopens)"; N=$(loglines); card relaunch "$BROKEN" 4-broken; wait_new "$N"
echo "-- 5. next launch (expect: failed with the codesign reason, and still failed after the check, never ready)"; card card "$BROKEN" 5-failed
echo "-- 6. Try Again (expect: downloading/updating, installer fails again, reopens)"; N=$(loglines); card retry "$BROKEN" 6-retry; wait_new "$N"
echo "-- 7. next launch (expect: gaveUp at launch and after the check)"; card card "$BROKEN" 7-gaveup
echo "-- 8. quitting with the broken update ready (expect: install on quit skipped)"; N=$(loglines)
SORREL_HOME="$T/home" SORREL_SNAPSHOT="$T/shot.png" SORREL_DELAY=60 SORREL_UPDATETEST=quit SORREL_UPDATE_FEED="file://$BROKEN" \
  "$APP/Contents/MacOS/Sorrel" 2>&1 | grep -E '^updater: (state|install on quit)' || true
sleep 2; echo "  installer runs after quitting: $(tail -n +$((N + 1)) "$T/home/Updates/update.log" | grep -c 'installer: start' || true)"
echo "   pictures: $T/cards"

if [ "$APPDIR" != "$T/app" ]; then rm -rf "$APP"; echo "removed $APP"; fi
echo "done; scratch in $T"
