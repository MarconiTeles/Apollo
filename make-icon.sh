#!/bin/bash
# Builds AppIcon.icns from the curated PNG set in
# `../PainelLunar-icons` (relative to the daypanel-swift repo root).
# Run once (or whenever the source PNGs change).
#
# The source PNGs are FULL-BLEED (artwork fills the whole square).
# macOS 26 (Tahoe) auto-masks/insets icons, but older macOS shows them
# at full size — so a full-bleed icon looks oversized in the Dock there.
# We therefore inset each icon into the standard macOS icon grid
# (content centered at ~80% of the canvas, transparent margin around it)
# via `pad-icon.swift` before assembling the .icns.

set -euo pipefail
cd "$(dirname "$0")"

SRC="../PainelLunar-icons"
ICONSET="build/AppIcon.iconset"
SCALE="0.80"   # content fills 80% of the canvas (Apple's Big Sur+ grid)

if [ ! -d "$SRC" ]; then
    echo "✗ Source folder $SRC not found"
    exit 1
fi

mkdir -p build
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Compile the padding helper once.
PADDER="build/pad-icon"
if [ ! -x "$PADDER" ] || [ pad-icon.swift -nt "$PADDER" ]; then
    swiftc -O pad-icon.swift -o "$PADDER"
fi

# pad <source.png> <dest.png> — insets the full-bleed artwork.
pad() { "$PADDER" "$1" "$2" "$SCALE"; }

# Apple's iconutil expects @2x naming; the source folder uses _2x.
pad "$SRC/icon_16x16.png"      "$ICONSET/icon_16x16.png"
pad "$SRC/icon_16x16_2x.png"   "$ICONSET/icon_16x16@2x.png"
pad "$SRC/icon_32x32.png"      "$ICONSET/icon_32x32.png"
pad "$SRC/icon_32x32_2x.png"   "$ICONSET/icon_32x32@2x.png"
pad "$SRC/icon_128x128.png"    "$ICONSET/icon_128x128.png"
pad "$SRC/icon_128x128_2x.png" "$ICONSET/icon_128x128@2x.png"
pad "$SRC/icon_256x256.png"    "$ICONSET/icon_256x256.png"
pad "$SRC/icon_256x256_2x.png" "$ICONSET/icon_256x256@2x.png"
pad "$SRC/icon_512x512.png"    "$ICONSET/icon_512x512.png"
pad "$SRC/icon_512x512_2x.png" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o build/AppIcon.icns

echo "✓ build/AppIcon.icns (content inset to ${SCALE} of canvas)"
