#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
# Optional second argument toggles a universal (arm64 + x86_64)
# build for distribution. Default is single-arch (host only) so
# day-to-day dev rebuilds stay fast.
UNIVERSAL="${2:-}"
APP_DISPLAY_NAME="Apollo"

if [ "$UNIVERSAL" = "--universal" ]; then
    echo "Building $APP_DISPLAY_NAME ($CONFIG, universal arm64 + x86_64)..."
    # Build each slice separately, then lipo them together. We
    # avoid `swift build --arch arm64 --arch x86_64` because its
    # output directory layout shifts between Swift toolchain
    # versions; per-arch builds keep the path stable.
    swift build -c "$CONFIG" --arch arm64
    swift build -c "$CONFIG" --arch x86_64
    BIN_ARM64=".build/arm64-apple-macosx/$CONFIG/DayPanel"
    BIN_X86="\
.build/x86_64-apple-macosx/$CONFIG/DayPanel"
    BIN_DIR="build/universal"
    BIN="$BIN_DIR/DayPanel"
    mkdir -p "$BIN_DIR"
    lipo -create "$BIN_ARM64" "$BIN_X86" -output "$BIN"
    echo "  Universal slices:"
    lipo -info "$BIN" | sed 's/^/    /'
else
    echo "Building $APP_DISPLAY_NAME ($CONFIG)..."
    swift build -c "$CONFIG"
    BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
    BIN="$BIN_DIR/DayPanel"
fi
APP="build/${APP_DISPLAY_NAME}.app"

# Generate the icon if it doesn't already exist (or after a clean build/).
if [ ! -f build/AppIcon.icns ]; then
    ./make-icon.sh
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN"                                "$APP/Contents/MacOS/DayPanel"
cp Sources/DayPanel/Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns                    "$APP/Contents/Resources/AppIcon.icns"

# ── Bundle Sparkle.framework ──────────────────────────────────────────────
# Sparkle is pulled in via SPM (see `Package.swift`), but
# `swift build` only links its dylib — the .framework
# bundle (which ships with the Autoupdate helper, the
# Updater.app sub-bundle, XPC services and Resources) is
# left in `.build/artifacts/.../Sparkle.framework` and
# wouldn't make it into the .app without an explicit copy.
# Sparkle's runtime probes `Bundle.main.bundlePath +
# "/Contents/Frameworks/Sparkle.framework"` for the helper
# tools, so it MUST live there.
#
# We use `cp -R` (or `rsync -a` if available) to preserve
# symlinks and permissions; `cp -L` would break the
# Versions/B → Current symlink Sparkle relies on.
SPARKLE_SRC="$(find .build/artifacts -name Sparkle.framework -type d | head -1)"
if [ -z "$SPARKLE_SRC" ]; then
    echo "ERROR: Sparkle.framework not found under .build/artifacts." >&2
    echo "       Run 'swift package resolve' then re-run this script." >&2
    exit 1
fi
echo "Bundling Sparkle.framework from $SPARKLE_SRC"
if command -v rsync >/dev/null 2>&1; then
    rsync -a "$SPARKLE_SRC" "$APP/Contents/Frameworks/"
else
    cp -R "$SPARKLE_SRC" "$APP/Contents/Frameworks/"
fi

# `swift build` links Sparkle as `@rpath/Sparkle.framework/...`
# but only injects `@executable_path` and the toolchain's swift
# lib directory into the binary's rpath list — neither resolves
# to `Apollo.app/Contents/Frameworks/`. Inject the standard
# Cocoa rpath that points one directory up from the executable
# so dyld can find the bundled framework. Errors are tolerated
# because the rpath is harmless if it's already present (e.g.
# on a re-run of the script).
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/DayPanel" 2>/dev/null || true

# ── Bundle the embedded AI runtime ────────────────────────────────────────
# Apollo's default AI backend ("Apollo IA") is fully self-
# contained: both the inference engine (Ollama binary, ~74 MB
# universal Mach-O) AND the model weights (GGUF, ~750 MB) ship
# inside the .app. At runtime the user never touches a terminal,
# never installs anything, never sees an API key field — they
# open Apollo, click sparkles, ask a question, get an answer.

# 1. Ollama binary (engine)
OLLAMA_BUNDLE="$APP/Contents/Resources/ollama"
OLLAMA_CACHE="build/ollama-runtime"
if [ ! -f "$OLLAMA_CACHE" ]; then
    echo "Bundling Ollama runtime…"
    LOCAL_OLLAMA="/Applications/Ollama.app/Contents/Resources/ollama"
    if [ -f "$LOCAL_OLLAMA" ]; then
        echo "  Copying from $LOCAL_OLLAMA"
        cp -L "$LOCAL_OLLAMA" "$OLLAMA_CACHE"
    else
        echo "  Downloading latest Ollama from GitHub…"
        TMP_DIR="$(mktemp -d)"
        curl -fsSL "https://github.com/ollama/ollama/releases/latest/download/Ollama-darwin.zip" \
             -o "$TMP_DIR/ollama.zip"
        unzip -q "$TMP_DIR/ollama.zip" -d "$TMP_DIR"
        cp -L "$TMP_DIR/Ollama.app/Contents/Resources/ollama" "$OLLAMA_CACHE"
        rm -rf "$TMP_DIR"
    fi
    chmod +x "$OLLAMA_CACHE"
fi
cp "$OLLAMA_CACHE" "$OLLAMA_BUNDLE"
chmod +x "$OLLAMA_BUNDLE"
xattr -dr com.apple.quarantine "$OLLAMA_BUNDLE" 2>/dev/null || true

# Note: GGUF model weights are NOT bundled in the .app any more
# — they're optional and downloaded by the user on demand from
# the onboarding step or directly from the AI chat. The .app
# stays small (~85 MB) and users who don't want the AI feature
# don't have to download 2 GB they'll never use. The model
# lands at:
#   ~/Library/Application Support/Apollo/Models/apollo-ia.gguf
# managed by `EmbeddedRuntimeManager.downloadModel()`.

# Sandbox is OFF for adhoc builds (Sparkle's installer XPC
# can't gain authorization without a Developer ID Team ID,
# breaking OTA updates — see Apollo.entitlements for the full
# rationale). We also skip --entitlements entirely on adhoc:
# the only key currently declared in the file is
# `time-sensitive`, which AMFI rejects on adhoc binaries with
# code 163, silently failing launch. Re-enable both
# (--entitlements + the sandbox block in the .entitlements
# file) AFTER notarization with Developer ID.
codesign --force --deep --sign - "$APP" > /dev/null 2>&1

# Clean up any stale build/DayPanel.app from previous runs.
rm -rf build/DayPanel.app

echo ""
echo "✓ Built $APP"
echo "  Launch: open \"$APP\""
