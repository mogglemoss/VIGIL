#!/usr/bin/env bash
# Assemble and sign the .app. A bare SPM executable cannot hold TCC grants:
# NSAudioCaptureUsageDescription only prompts from a signed bundle, and the
# grant is keyed to the signing identity — which is why we use the Apple
# Development cert rather than ad-hoc, so the grant survives a rebuild.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [ -z "$IDENTITY" ]; then
  echo "No codesigning identity found. Ad-hoc signing works but TCC will"
  echo "re-prompt on every rebuild. Set IDENTITY=... to choose one."
  exit 1
fi
echo "signing as: $IDENTITY"
APP=".build/Observance.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp .build/release/observance "$APP/Contents/MacOS/observance"
mkdir -p "$APP/Contents/Resources"
cp Resources/seal.png Resources/stamp.wav Resources/latch.wav "$APP/Contents/Resources/"

codesign --force --options runtime --timestamp=none \
         --sign "$IDENTITY" "$APP"

echo
echo "built: $APP"
echo "run:   '$APP/Contents/MacOS/observance' --help"
echo
echo "Launch the inner binary directly, not with 'open' — you want stdout in"
echo "your terminal, and TCC still attributes to the bundle's identity."
