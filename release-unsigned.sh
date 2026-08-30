#!/usr/bin/env bash
# Builds an interim, ad-hoc signed release zip.
#
# Ad-hoc rather than the maintainer's Apple Development certificate: that one is
# for development on one machine, not for handing to strangers, and Apple will
# not notarise it anyway. Ad-hoc is honest about what it is.
#
# What that costs the person installing it:
#
#   · Gatekeeper refuses it on first open, and since macOS 15 a Control-click
#     no longer overrides that. They must go to System Settings › Privacy &
#     Security and press Open Anyway, or strip the quarantine attribute.
#
#   · Permission grants are keyed to the signature, and an ad-hoc signature is
#     a hash of the binary. Every new build is therefore a new app as far as
#     TCC is concerned, and Screen Recording and System Audio Recording must be
#     granted again after each update. A Developer ID fixes this; see
#     release.sh.
#
# Builds into its own directory so the working development bundle — which holds
# live permission grants — is left alone.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
[ -z "$VERSION" ] && { echo "usage: ./release-unsigned.sh <version>"; exit 1; }

OUT=".build/artifacts"
APP="$OUT/VIGIL.app"
ZIP=".build/VIGIL-$VERSION-unsigned.zip"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Resources/Info.plist

swift build -c release

rm -rf "$OUT"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp .build/release/vigil "$APP/Contents/MacOS/vigil"
cp Resources/seal.png Resources/stamp.wav Resources/latch.wav \
   Resources/AppIcon.icns "$APP/Contents/Resources/"

# cp carries extended attributes, and codesign refuses a bundle wearing Finder
# detritus. Strip them before signing rather than after being told.
xattr -cr "$APP"
# Prove it, rather than assume: codesign refuses FinderInfo and resource forks,
# and its complaint names the bundle root whatever the real culprit was.
if xattr -lr "$APP" | grep -q "com.apple.FinderInfo\|com.apple.ResourceFork"; then
  echo "still carrying disallowed attributes after xattr -cr:"
  xattr -lr "$APP" | grep "FinderInfo\|ResourceFork"
  exit 1
fi

codesign --force --options runtime --sign - "$APP"
codesign --verify --strict --verbose=1 "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "built: $ZIP  ($(du -h "$ZIP" | cut -f1))"
codesign -dv "$APP" 2>&1 | grep -E "^Identifier|^Signature"
