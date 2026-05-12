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

# ── Codesign (Developer ID + Hardened Runtime + entitlements) ──
#
# Switched from adhoc to Developer ID Application on 1.4.x →
# 1.5.0. With a real cert we get:
#   • Hardened Runtime — required by Apple's notary, also
#     enables the modern code-signing protections (no
#     unsigned dylibs, no DYLD_INSERT_LIBRARIES, etc).
#   • --timestamp — embeds a secure timestamp from Apple's
#     timestamp server. Required by the notary; lets users
#     install the app years later even after the cert expires.
#   • Entitlements file applied — `time-sensitive`
#     notifications + sandbox keys now resolve correctly
#     because AMFI honors restricted entitlements once they're
#     signed by a recognized Team ID (CU544M36UD here).
#
# Override via APOLLO_SIGNING_ID env var if a future signing
# identity rotates in.
SIGNING_ID="${APOLLO_SIGNING_ID:-Developer ID Application: Marconi Lima (CU544M36UD)}"
ENTITLEMENTS_PATH="Sources/DayPanel/Resources/Apollo.entitlements"

# Sign the inner Frameworks FIRST (deepest dependency first).
# Sparkle's framework ships with its own XPC services
# (Installer.xpc, Downloader.xpc) and the Autoupdate helper +
# Updater.app — each needs to be signed individually with its
# OWN entitlements so the outer-bundle signature is valid AND
# the Application Group membership lines up with the sandboxed
# main app. Without per-XPC entitlements, the install step times
# out with "installation data was never received" because the
# main app and the installer can't find each other's Mach
# service inside the sandbox.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_ENT_DIR="Sources/DayPanel/Resources/SparkleEntitlements"

if [ -d "$SPARKLE_FW" ]; then
    # Pairs of (path, entitlements-file). When the entitlements
    # file is empty / "-", sign without --entitlements.
    sparkle_sign() {
        local target="$1"
        local entitlements="$2"
        if [ -z "$entitlements" ] || [ "$entitlements" = "-" ]; then
            codesign --force --options runtime --timestamp \
                --sign "$SIGNING_ID" \
                "$target" > /dev/null
        else
            codesign --force --options runtime --timestamp \
                --sign "$SIGNING_ID" \
                --entitlements "$entitlements" \
                "$target" > /dev/null
        fi
    }

    if [ -e "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" ]; then
        sparkle_sign "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" \
                     "$SPARKLE_ENT_DIR/Installer.entitlements"
    fi
    if [ -e "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" ]; then
        sparkle_sign "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" \
                     "$SPARKLE_ENT_DIR/Downloader.entitlements"
    fi
    if [ -e "$SPARKLE_FW/Versions/B/Updater.app" ]; then
        sparkle_sign "$SPARKLE_FW/Versions/B/Updater.app" \
                     "$SPARKLE_ENT_DIR/Updater.entitlements"
    fi
    if [ -e "$SPARKLE_FW/Versions/B/Autoupdate" ]; then
        # Autoupdate is a plain Mach-O helper, no entitlements
        # needed beyond the framework's own.
        sparkle_sign "$SPARKLE_FW/Versions/B/Autoupdate" "-"
    fi

    sparkle_sign "$SPARKLE_FW" "-"
fi

# Embedded Ollama runtime — needs its own signature otherwise
# the outer --deep walk reports "not signed at all".
if [ -f "$OLLAMA_BUNDLE" ]; then
    codesign --force --options runtime --timestamp \
        --sign "$SIGNING_ID" \
        "$OLLAMA_BUNDLE" > /dev/null
fi

# Outer .app — apply entitlements, hardened runtime, timestamp.
codesign --force --options runtime --timestamp \
    --sign "$SIGNING_ID" \
    --entitlements "$ENTITLEMENTS_PATH" \
    "$APP" > /dev/null

# Sanity check: --deep --strict catches mismatched nested
# signatures (helper not signed with same identity, etc.) that
# the notary would reject silently.
codesign --verify --deep --strict "$APP" 2>&1 | head -3

# ── Self-check: required entitlements on the main app ─────────
#
# Hard-fails the build BEFORE notarization if any of the
# Sparkle-required entitlements is missing on the codesigned
# bundle. Each missed entitlement in past releases produced a
# version-bricking OTA error days later:
#
#   • Missing app-sandbox → app launches but the rest of the
#     security audit assumed sandboxing.
#   • Missing application-groups → "installation data was
#     never received" timeout (1.5.1 → 1.5.2).
#   • Missing mach-lookup spki/spks names → "failed to probe
#     status service / An error occurred while running the
#     updater" (1.5.3 → 1.5.4).
#
# `codesign -d --entitlements -` dumps the signed entitlements;
# we grep for the literal keys. Catching the regression here
# means the user gets a build failure instead of a broken
# OTA that requires a manual DMG reinstall to recover.
echo "→ Verifying required entitlements on signed bundle…"
ENT_DUMP="$(codesign -d --entitlements - "$APP" 2>&1)"
REQUIRED_KEYS=(
    "com.apple.security.app-sandbox"
    "com.apple.security.network.client"
    "com.apple.security.network.server"
    "com.apple.security.application-groups"
    "com.apple.security.temporary-exception.mach-lookup.global-name"
)
MISSING=()
for key in "${REQUIRED_KEYS[@]}"; do
    if ! echo "$ENT_DUMP" | grep -q "$key"; then
        MISSING+=("$key")
    fi
done
# Both Sparkle mach-lookup names must be present, not just the
# parent key. The previous regression had the key but missing
# values.
for name in "com.painellunar.app-spki" "com.painellunar.app-spks"; do
    if ! echo "$ENT_DUMP" | grep -q "$name"; then
        MISSING+=("mach-lookup name: $name")
    fi
done
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "✗ BUILD FAILED — missing required entitlements:" >&2
    for m in "${MISSING[@]}"; do
        echo "    - $m" >&2
    done
    echo "" >&2
    echo "  Fix Sources/DayPanel/Resources/Apollo.entitlements then rebuild." >&2
    exit 1
fi
echo "  ✓ All required entitlements present"

# Clean up any stale build/DayPanel.app from previous runs.
rm -rf build/DayPanel.app

echo ""
echo "✓ Built $APP"
echo "  Launch: open \"$APP\""
