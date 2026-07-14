#!/bin/bash
# Build Apollo's macOS AppIcon.icns from the canonical 1024px artwork.
# The source is exported from `cópia de APOLLO_ICON_06.pxd` and committed
# beside the app resources so release builds remain reproducible even when
# the original Pixelmator document is not present on another machine.

set -euo pipefail
cd "$(dirname "$0")"

SRC="Sources/DayPanel/Resources/APOLLO_ICON_06.png"
ICONSET="build/AppIcon.iconset"

if [ ! -f "$SRC" ]; then
    echo "✗ Canonical icon source $SRC not found"
    exit 1
fi

mkdir -p build
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# The new artwork already contains the intended macOS silhouette and optical
# margin. Resizing it directly avoids the old second 80% inset that made the
# icon look smaller than Finder/Dock neighbours.
resize() {
    local size="$1" dest="$2"
    sips -z "$size" "$size" "$SRC" --out "$ICONSET/$dest" >/dev/null
}

resize 16   icon_16x16.png
resize 32   icon_16x16@2x.png
resize 32   icon_32x32.png
resize 64   icon_32x32@2x.png
resize 128  icon_128x128.png
resize 256  icon_128x128@2x.png
resize 256  icon_256x256.png
resize 512  icon_256x256@2x.png
resize 512  icon_512x512.png
resize 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o build/AppIcon.icns
echo "✓ build/AppIcon.icns generated from APOLLO_ICON_06.png"
