#!/usr/bin/env bash
# Strikes AppIcon.icns from the seal.
#
# VIGIL is an agent app, so this icon is never in the Dock. It appears in
# Finder, in Get Info, in notifications, and — the one that matters — in
# System Settings' Screen Recording and System Audio Recording lists, which is
# where a pilot has to recognise it before granting it anything.
#
# Two plates, because the seal cannot survive 32 points: its ring text turns to
# mud and the glyph disappears under it. Large sizes wear the full seal; small
# sizes wear the glyph alone. That is the same division the stationery makes —
# the seal goes on the document, the glyph goes on the rail.
set -euo pipefail
cd "$(dirname "$0")/.."

SEAL_B64=$(base64 -i Resources/seal.png | tr -d '\n')
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Large plate: the full seal.
cat > "$WORK/icon-seal.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
     width="1024" height="1024" viewBox="0 0 1024 1024">
  <rect x="100" y="100" width="824" height="824" rx="185" ry="185" fill="#12100e"/>
  <rect x="100" y="100" width="824" height="824" rx="185" ry="185"
        fill="none" stroke="#3a3530" stroke-width="4"/>
  <g transform="rotate(-5 512 512)">
    <image x="212" y="212" width="600" height="600"
           xlink:href="data:image/png;base64,${SEAL_B64}"/>
  </g>
</svg>
SVG

# Small plate: the glyph alone — triangle, eye, pupil — at a size that reads.
cat > "$WORK/icon-glyph.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <rect x="100" y="100" width="824" height="824" rx="185" ry="185" fill="#12100e"/>
  <rect x="100" y="100" width="824" height="824" rx="185" ry="185"
        fill="none" stroke="#3a3530" stroke-width="4"/>
  <g transform="translate(512,512) scale(3.0) translate(0,25)">
    <path d="M 0,-100 L 92,50 L -92,50 Z" fill="#C15F3C"/>
    <path d="M -56,8 Q 0,-56 56,8 Q 0,78.4 -56,8 Z" fill="#12100e"/>
    <circle cx="0" cy="8" r="22" fill="#C15F3C"/>
  </g>
</svg>
SVG

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
# Below 128 the seal is illegible, so the glyph takes over.
for spec in "16 16x16 glyph" "32 16x16@2x glyph" "32 32x32 glyph" "64 32x32@2x glyph" \
            "128 128x128 seal" "256 128x128@2x seal" "256 256x256 seal" \
            "512 256x256@2x seal" "512 512x512 seal" "1024 512x512@2x seal"; do
  set -- $spec
  rsvg-convert -w "$1" -h "$1" "$WORK/icon-$3.svg" -o "$ICONSET/icon_$2.png"
done

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "struck: Resources/AppIcon.icns ($(du -h Resources/AppIcon.icns | cut -f1))"
