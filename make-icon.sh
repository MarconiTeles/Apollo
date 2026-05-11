#!/bin/bash
# Builds AppIcon.icns from the curated PNG set in
# `../PainelLunar-icons` (relative to the daypanel-swift repo root).
# Run once (or whenever the source PNGs change).

set -euo pipefail
cd "$(dirname "$0")"

SRC="../PainelLunar-icons"
ICONSET="build/AppIcon.iconset"

if [ ! -d "$SRC" ]; then
    echo "✗ Source folder $SRC not found"
    exit 1
fi

mkdir -p build
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Apple's iconutil expects @2x naming; the source folder uses _2x.
cp "$SRC/icon_16x16.png"      "$ICONSET/icon_16x16.png"
cp "$SRC/icon_16x16_2x.png"   "$ICONSET/icon_16x16@2x.png"
cp "$SRC/icon_32x32.png"      "$ICONSET/icon_32x32.png"
cp "$SRC/icon_32x32_2x.png"   "$ICONSET/icon_32x32@2x.png"
cp "$SRC/icon_128x128.png"    "$ICONSET/icon_128x128.png"
cp "$SRC/icon_128x128_2x.png" "$ICONSET/icon_128x128@2x.png"
cp "$SRC/icon_256x256.png"    "$ICONSET/icon_256x256.png"
cp "$SRC/icon_256x256_2x.png" "$ICONSET/icon_256x256@2x.png"
cp "$SRC/icon_512x512.png"    "$ICONSET/icon_512x512.png"
cp "$SRC/icon_512x512_2x.png" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o build/AppIcon.icns

echo "✓ build/AppIcon.icns"
