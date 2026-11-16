#!/bin/bash
# Creates Sorrel's code-signing identity, once per Mac that builds Sorrel. Free: a self-signed certificate,
# no Apple developer account.
#
# Why: macOS remembers what you allowed an app to do (its Downloads folder, camera, microphone, location)
# against the app's code signature. An ad-hoc signature is just a hash of this exact build, so every rebuild
# or update looked like a brand-new app and macOS asked again ("Sorrel would like to access files in your
# Downloads folder" on the first download after every update). Signed with this certificate, every build
# counts as the same app, so you are asked once.
#
# It writes, outside the repo (the repo is public):
#   ~/.config/sorrel/signing.keychain-db   a keychain holding only this certificate and its private key
# The keychain has no password (like update-signing-key, it is protected by the folder's permissions), so
# build.sh can unlock it without putting a secret on a command line. build.sh uses it whenever it exists and
# falls back to ad-hoc signing when it doesn't (anyone else building from source).
#
# If it is lost, make a new one: the only cost is one more round of macOS permission prompts.
set -euo pipefail

DIR="${SORREL_SIGNING_DIR:-$HOME/.config/sorrel}"
KC="$DIR/signing.keychain-db"
NAME="Sorrel Code Signing (self-signed)"

if [ -e "$KC" ]; then
  echo "Already exists: $KC"
  security find-identity -p codesigning "$KC"
  exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
umask 077
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# RSA 3072, valid 20 years, marked for code signing only.
openssl req -x509 -newkey rsa:3072 -nodes -days 7300 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
P12PW=$(openssl rand -hex 16)
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/identity.p12" -passout "pass:$P12PW"

security create-keychain -p "" "$KC"
security set-keychain-settings "$KC"            # never locks itself again
security unlock-keychain -p "" "$KC"
security import "$WORK/identity.p12" -k "$KC" -P "$P12PW" -T /usr/bin/codesign >/dev/null
# Let codesign use the key without a "codesign wants to use the key" dialog.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KC" >/dev/null

echo "Created $KC"
security find-identity -p codesigning "$KC" | sed -n 's/^ *1) /  /p'
echo "(\"not trusted\" is expected for a self-signed certificate; codesign uses it all the same.)"
echo "Back up $DIR. Next: ./build.sh"
