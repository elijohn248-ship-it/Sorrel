#!/bin/bash
# Builds Drift.app into ./build.
#   ./build.sh            build only
#   ./build.sh run        build and open it
#   ./build.sh install    build and copy to /Applications
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Drift.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Drift "$APP/Contents/MacOS/Drift"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/welcome.html Resources/bangs.json Resources/emoji.tsv "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# uBlock Origin Lite ships inside the app (see vendor/ubol/README).
if [ -f vendor/ubol/ext/manifest.json ]; then
  mkdir -p "$APP/Contents/Resources/extensions"
  cp -R vendor/ubol/ext "$APP/Contents/Resources/extensions/ubol"
fi

# Ad-hoc signature: enough to run on this Mac, no Apple developer account needed.
# The hardened runtime stops other programs injecting code into Drift; the entitlements
# let websites ask for the camera and microphone under it.
codesign --force --options runtime --entitlements Resources/Drift.entitlements --sign - "$APP" >/dev/null

echo "Built $APP"

case "${1:-}" in
  run)
    open "$APP"
    ;;
  install)
    rm -rf /Applications/Drift.app
    cp -R "$APP" /Applications/Drift.app
    echo "Installed to /Applications/Drift.app"
    ;;
esac
