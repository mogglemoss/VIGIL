#!/usr/bin/env bash
# Builds, signs, notarises and staples a release zip.
#
# Requires, once, on this machine:
#
#   1. A "Developer ID Application" certificate in the login keychain.
#      Xcode › Settings › Accounts › (your Apple ID) › Manage Certificates ›
#      + › Developer ID Application. Enrolment must be active first.
#
#   2. Notarisation credentials stored in the keychain — NOT here, and not in
#      any file this repository can see. Run it yourself, interactively:
#
#        xcrun notarytool store-credentials VIGIL-notary \
#          --apple-id <your-apple-id> --team-id <your-team-id>
#
#      It will prompt for an app-specific password, made at appleid.apple.com
#      › Sign-In and Security › App-Specific Passwords. The password is never
#      echoed and never leaves your keychain.
#
# Then: ./release.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
PROFILE="${NOTARY_PROFILE:-VIGIL-notary}"
[ -z "$VERSION" ] && { echo "usage: ./release.sh <version>   e.g. ./release.sh 0.2.0"; exit 1; }

IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
if [ -z "$IDENTITY" ]; then
  echo "No Developer ID Application certificate found."
  echo "An Apple Development certificate cannot be notarised — it signs for this"
  echo "Mac only. See the header of this script."
  exit 1
fi

APP=".build/VIGIL.app"
ZIP=".build/VIGIL-$VERSION.zip"

# Stamp the version into the bundle so About and the release agree.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Resources/Info.plist

IDENTITY="$IDENTITY" ./bundle.sh

# Notarisation requires a secure timestamp; bundle.sh omits one for local
# development builds, so re-sign properly here.
xattr -cr "$APP"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "submitting to Apple…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# Re-zip so the artifact carries the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "ready: $ZIP"
echo "check on another Mac with:  spctl -a -vvv -t install /path/to/VIGIL.app"
