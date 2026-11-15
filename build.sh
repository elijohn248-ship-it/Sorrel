#!/bin/bash
# Builds Sorrel.app into ./build.
#   ./build.sh            build only
#   ./build.sh run        build and open it
#   ./build.sh install    build and copy to /Applications
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

# Two apps from one build:
#   build/Sorrel.app      the owner's browser (bundle id app.sorrel.browser)
#   build/SorrelTest.app  for test runs only: bundle id app.sorrel.browser.test, so it gets its own sandbox
#                         container, preferences and site data, and may also write to /private/tmp scratch folders.
make_app() {   # $1 = app path, $2 = Info.plist, $3 = entitlements, $4 = updater service Info.plist
  local APP="$1"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp .build/release/Sorrel "$APP/Contents/MacOS/Sorrel"
  cp "$2" "$APP/Contents/Info.plist"
  cp Resources/welcome.html Resources/bangs.json Resources/emoji.tsv "$APP/Contents/Resources/"
  [ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

  # uBlock Origin Lite ships inside the app (see vendor/ubol/README).
  if [ -f vendor/ubol/ext/manifest.json ]; then
    mkdir -p "$APP/Contents/Resources/extensions"
    cp -R vendor/ubol/ext "$APP/Contents/Resources/extensions/ubol"
  fi

  # The updater service (Sources/SorrelUpdater) replaces the app bundle after an update downloads. launchd
  # starts it for Sorrel on demand, and it is signed WITHOUT the sandbox entitlements on purpose: inside the
  # sandbox nothing could write to /Applications. It accepts only archives signed with the key in
  # Sources/SorrelUpdateCore (see CLAUDE.md, Updates).
  local XPC="$APP/Contents/XPCServices/SorrelUpdater.xpc"
  mkdir -p "$XPC/Contents/MacOS"
  cp .build/release/SorrelUpdater "$XPC/Contents/MacOS/SorrelUpdater"
  cp "$4" "$XPC/Contents/Info.plist"
  codesign --force --options runtime --sign - "$XPC" >/dev/null

  # Ad-hoc signature: enough to run on this Mac, no Apple developer account needed.
  # The hardened runtime stops other programs injecting code into Sorrel; the entitlements switch on the
  # App Sandbox and list the few things outside it Sorrel may use (see CLAUDE.md, Sandbox).
  codesign --force --options runtime --entitlements "$3" --sign - "$APP" >/dev/null
}

# The test build's Info.plist and entitlements are derived from the real ones.
GEN=".build/test-bundle"
mkdir -p "$GEN"
PB=/usr/libexec/PlistBuddy
cp Resources/Info.plist "$GEN/Info.plist"
$PB -c "Set :CFBundleIdentifier app.sorrel.browser.test" -c "Set :CFBundleDisplayName Sorrel Test" \
    -c "Delete :CFBundleURLTypes" -c "Delete :CFBundleDocumentTypes" "$GEN/Info.plist" >/dev/null
sed -e 's|app\.sorrel\.browser|app.sorrel.browser.test|g' \
    -e 's|Application Support/Sorrel/|Application Support/Sorrel Test/|g' Resources/Sorrel.entitlements > "$GEN/Sorrel.entitlements"
$PB -c "Add :com.apple.security.temporary-exception.files.absolute-path.read-write array" \
    -c "Add :com.apple.security.temporary-exception.files.absolute-path.read-write:0 string /private/tmp/" \
    "$GEN/Sorrel.entitlements" >/dev/null
sed -e 's|app\.sorrel\.browser\.updater|app.sorrel.browser.test.updater|' Resources/SorrelUpdater.plist > "$GEN/SorrelUpdater.plist"

APP="build/Sorrel.app"
make_app "$APP" Resources/Info.plist Resources/Sorrel.entitlements Resources/SorrelUpdater.plist
make_app build/SorrelTest.app "$GEN/Info.plist" "$GEN/Sorrel.entitlements" "$GEN/SorrelUpdater.plist"

echo "Built $APP (and build/SorrelTest.app for tests)"

case "${1:-}" in
  run)
    open "$APP"
    ;;
  install)
    rm -rf /Applications/Sorrel.app /Applications/Sorrel.app
    cp -R "$APP" /Applications/Sorrel.app
    echo "Installed to /Applications/Sorrel.app"
    ;;
esac
