#!/bin/bash
# Apollo release packager + Sparkle signer.
#
# Produces, in dist/:
#   • Apollo-<version>.dmg        (drag-install distributable;
#                                  same shape as before)
#   • Apollo-<version>.zip        (Sparkle in-app update payload;
#                                  Sparkle prefers ZIP over DMG
#                                  for delta installs)
#   • Apollo-<version>.zip.sig    (sidecar with EdDSA signature
#                                  + size in bytes — passed to
#                                  appcast as `sparkle:edSignature`
#                                  + `length` attributes)
#   • appcast.xml                 (Sparkle feed; one <item> per
#                                  release. The script PREPENDS a
#                                  new item to the existing feed
#                                  if it's already there, else
#                                  bootstraps from template)
#
# After running this, upload:
#   • dist/appcast.xml            → root of the FEED host
#   • dist/Apollo-<version>.zip   → the URL referenced in the
#                                  <enclosure> attribute below
#   • dist/Apollo-<version>.dmg   → wherever you publish the
#                                  human-downloadable install
#
# Usage:
#   ./release.sh                          # uses current Info.plist version
#   ./release.sh --bump-patch             # 1.4.0 → 1.4.1
#   ./release.sh --bump-minor             # 1.4.0 → 1.5.0
#   ./release.sh --bump-major             # 1.4.0 → 2.0.0
#   ./release.sh --set-version 2.0.0      # explicit
#   ./release.sh --notes "Bug fixes"      # release notes (HTML or plain)
#
# Environment overrides:
#   APOLLO_GITHUB_SLUG    GitHub <user>/<repo> hosting the releases
#                         (e.g. "marconi/apollo"). Required for the
#                         appcast `<enclosure>` URL to point at
#                         GitHub Releases.
#   APOLLO_UPLOAD=1       When set, after producing dist/, also
#                         creates the GitHub release + uploads
#                         dist/Apollo-<version>.zip and the .dmg
#                         via `gh release create`. Requires the
#                         `gh` CLI authenticated.
#
# Hosting layout assumed (option A from the setup conversation):
#   • Appcast.xml      → GitHub Pages root:
#                        https://<user>.github.io/<repo>/appcast.xml
#   • .zip / .dmg      → per-tag GitHub Releases:
#                        https://github.com/<user>/<repo>/releases/
#                          download/vX.Y.Z/Apollo-X.Y.Z.zip

set -euo pipefail
cd "$(dirname "$0")"

# ── Config ────────────────────────────────────────────────────────────────
APP_DISPLAY_NAME="Apollo"
INFO_PLIST="Sources/DayPanel/Resources/Info.plist"
SPARKLE_BIN_DIR=".build/artifacts/sparkle/Sparkle/bin"
SIGN_UPDATE="$SPARKLE_BIN_DIR/sign_update"
DIST_DIR="dist"
APPCAST="$DIST_DIR/appcast.xml"

# GitHub slug — required for enclosure URLs in the appcast.
# Defaults to the canonical Apollo repo; override via
# `APOLLO_GITHUB_SLUG` if you fork or rename.
GH_SLUG="${APOLLO_GITHUB_SLUG:-MarconiTeles/Apollo}"

# ── Args ──────────────────────────────────────────────────────────────────
BUMP=""
EXPLICIT_VERSION=""
NOTES=""
# Optional Sparkle channel. Default = "" (public stream; every
# install on the default channel gets a scheduled-check banner).
# Pass `--silent` to tag the new item with
# `<sparkle:channel>silent</sparkle:channel>`. Apollo's
# `UpdateService` discovers silent items so a manual check
# (`⌘ → Verificar Atualizações…`) can install them, but the
# `SPUStandardUserDriver` delegate refuses to show the
# scheduled-check banner — release stays available without
# pinging every tester.
CHANNEL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bump-patch|--bump-minor|--bump-major)
            BUMP="${1#--bump-}"; shift ;;
        --set-version)
            EXPLICIT_VERSION="$2"; shift 2 ;;
        --notes)
            NOTES="$2"; shift 2 ;;
        --silent)
            CHANNEL="silent"; shift ;;
        --channel)
            CHANNEL="$2"; shift 2 ;;
        *)
            echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

# ── Version handling ──────────────────────────────────────────────────────
PB=/usr/libexec/PlistBuddy
CURRENT_VERSION="$($PB -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
CURRENT_BUILD="$($PB -c 'Print :CFBundleVersion' "$INFO_PLIST")"

bump_semver() {
    local v="$1" part="$2"
    IFS='.' read -r maj min pat <<< "$v"
    case "$part" in
        patch) pat=$((pat+1)) ;;
        minor) min=$((min+1)); pat=0 ;;
        major) maj=$((maj+1)); min=0; pat=0 ;;
    esac
    echo "$maj.$min.$pat"
}

if [[ -n "$EXPLICIT_VERSION" ]]; then
    NEW_VERSION="$EXPLICIT_VERSION"
elif [[ -n "$BUMP" ]]; then
    NEW_VERSION="$(bump_semver "$CURRENT_VERSION" "$BUMP")"
else
    NEW_VERSION="$CURRENT_VERSION"
fi
NEW_BUILD=$((CURRENT_BUILD + 1))

if [[ "$NEW_VERSION" != "$CURRENT_VERSION" ]] || [[ "$NEW_BUILD" != "$CURRENT_BUILD" ]]; then
    echo "→ Bumping version: $CURRENT_VERSION ($CURRENT_BUILD) → $NEW_VERSION ($NEW_BUILD)"
    $PB -c "Set :CFBundleShortVersionString $NEW_VERSION" "$INFO_PLIST"
    $PB -c "Set :CFBundleVersion $NEW_BUILD" "$INFO_PLIST"
fi

# ── Build + package (reuses existing package.sh that produces the DMG) ────
echo "→ Building + packaging Apollo $NEW_VERSION (build $NEW_BUILD)…"
./package.sh

DMG_NAME="Apollo-${NEW_VERSION}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
APP_PATH="build/Apollo.app"

if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: build/Apollo.app missing — package.sh should have produced it." >&2
    exit 1
fi
if [[ ! -f "$DMG_PATH" ]]; then
    echo "ERROR: $DMG_PATH missing — package.sh should have produced it." >&2
    exit 1
fi

# ── Notarization (Apple notary service) ───────────────────────────────────
# Submit the .app (as a ZIP — the notary doesn't accept .app
# directly) to Apple's notary service, wait for the verdict,
# then staple the resulting ticket onto the bundle so Gatekeeper
# can validate it offline. After stapling, both the .zip we
# ship to Sparkle AND the .dmg get re-built so they include
# the stapled bundle.
#
# Credentials live in a Keychain profile created once with:
#   xcrun notarytool store-credentials AC_PASSWORD_APOLLO \
#     --apple-id "marconimpn@gmail.com" \
#     --team-id  CU544M36UD \
#     --password "<app-specific password>"
#
# Override the profile name via APOLLO_NOTARY_PROFILE if you
# rotate to a different credential set.
NOTARY_PROFILE="${APOLLO_NOTARY_PROFILE:-AC_PASSWORD_APOLLO}"

# Submission ZIP — separate from the Sparkle ZIP because we
# want the staple to land on the bundle BEFORE Sparkle
# packages it.
NOTARY_ZIP="$DIST_DIR/Apollo-${NEW_VERSION}-notary.zip"
rm -f "$NOTARY_ZIP"
echo "→ Zipping for notarization…"
ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP"

echo "→ Submitting to Apple notary (this can take 1–10 min)…"
NOTARY_OUT="$(xcrun notarytool submit "$NOTARY_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format plist 2>&1)" || {
    echo "✗ Notarization submit failed:" >&2
    echo "$NOTARY_OUT" >&2
    exit 1
}

# Pull the submission id + status out of the plist output so
# we can fetch the log on failure.
NOTARY_TMP="$(mktemp)"
echo "$NOTARY_OUT" > "$NOTARY_TMP"
NOTARY_STATUS="$($PB -c 'Print :status' "$NOTARY_TMP" 2>/dev/null || echo unknown)"
NOTARY_ID="$($PB -c 'Print :id' "$NOTARY_TMP" 2>/dev/null || echo unknown)"
rm -f "$NOTARY_TMP"

if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    echo "✗ Notarization status: $NOTARY_STATUS (id=$NOTARY_ID)" >&2
    echo "  Fetching notary log…" >&2
    xcrun notarytool log "$NOTARY_ID" \
        --keychain-profile "$NOTARY_PROFILE" >&2 || true
    exit 1
fi
echo "✓ Notarization accepted (id=$NOTARY_ID)"

echo "→ Stapling ticket onto the .app bundle…"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH" >/dev/null

# Remove the submission ZIP — we re-zip below with the stapled
# bundle so Sparkle ships the ticket-carrying copy.
rm -f "$NOTARY_ZIP"

# Rebuild the DMG so the .dmg distributed to users carries the
# stapled bundle too. CRITICAL: do NOT call package.sh here —
# it re-runs build.sh which re-codesigns the .app, generating
# a new CdHash and DESTROYING the staple we just attached.
# Instead, re-run only the DMG-creation steps directly against
# the already-stapled build/Apollo.app.
echo "→ Rebuilding DMG with stapled bundle (no re-sign)…"
STAGE_DIR="$DIST_DIR/.stage"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

# Helper script + LEIA-ME — kept in sync with package.sh by
# inlining the same templates. (If you change either copy,
# update the other so DMG installs from both paths behave
# identically.)
cat > "$STAGE_DIR/Remover-Quarentena.command" <<'CMDEOF'
#!/bin/bash
set +e
clear
echo ""
echo "  Apollo — Liberar o app no macOS"
echo "  ────────────────────────────────"
APP_PATH="/Applications/Apollo.app"
if [ ! -d "$APP_PATH" ]; then
    echo "  ✗ Não encontrei $APP_PATH"
    read -n 1 -s -r -p "  Pressione qualquer tecla para fechar..."
    exit 1
fi
osascript -e 'tell application id "com.painellunar.app" to quit' 2>/dev/null
pkill -x DayPanel 2>/dev/null
sleep 1.2
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null
xattr -dr com.apple.provenance "$APP_PATH" 2>/dev/null
echo "  ✓ Pronto. Abra o Apollo pelo Launchpad ou Spotlight."
sleep 1
exit 0
CMDEOF
chmod +x "$STAGE_DIR/Remover-Quarentena.command"

cat > "$STAGE_DIR/LEIA-ME.txt" <<EOF
Apollo ${NEW_VERSION} (notarizado)

Instalação:
  1. Arraste "Apollo.app" para a pasta "Applications".
  2. Abra pelo Launchpad ou Spotlight.

Como esta versão é notarizada pela Apple, o Gatekeeper
aceita o app sem prompt. Se você vier de uma versão adhoc
e ainda ver o aviso de quarentena, rode o script
"Remover-Quarentena.command" uma única vez.
EOF

hdiutil create \
    -volname "Apollo ${NEW_VERSION}" \
    -srcfolder "$STAGE_DIR" \
    -ov -format UDZO \
    "$DMG_PATH" > /dev/null
rm -rf "$STAGE_DIR"
echo "✓ DMG rebuilt at $DMG_PATH (stapled bundle preserved)"

# ── ZIP for Sparkle ───────────────────────────────────────────────────────
# Sparkle expects a ZIP that, when unzipped, contains Apollo.app
# at the top level. `ditto` preserves resource forks, symlinks,
# and code-signing metadata better than plain `zip`. Run AFTER
# the notarization staple so the ZIP carries the ticket.
ZIP_NAME="Apollo-${NEW_VERSION}.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
echo "→ Packaging $ZIP_NAME for Sparkle…"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

# ── Sign the ZIP with the EdDSA private key from Keychain ─────────────────
echo "→ Signing $ZIP_NAME…"
SIGN_OUTPUT="$("$SIGN_UPDATE" "$ZIP_PATH")"
# Output looks like: sparkle:edSignature="…" length="…"
SIGNATURE_LINE="$SIGN_OUTPUT"
echo "  $SIGNATURE_LINE"
# Save sidecar so the appcast generator can read it back even on
# re-runs (sign_update is deterministic given the same input bytes,
# but caching avoids a redundant Keychain prompt).
echo "$SIGNATURE_LINE" > "$ZIP_PATH.sig"

# Parse signature + length out of the sign_update output.
ED_SIG="$(echo "$SIGNATURE_LINE" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"
LEN="$(echo "$SIGNATURE_LINE" | sed -E 's/.*length="([^"]+)".*/\1/')"

# ── Appcast item ──────────────────────────────────────────────────────────
RFC_DATE="$(LC_TIME=en_US.UTF-8 date -u '+%a, %d %b %Y %H:%M:%S +0000')"
# GitHub Releases per-tag URL pattern. Each release lives at
# its own /releases/download/vX.Y.Z/ subpath, so the URL is
# computed per release rather than from a flat base.
ENCLOSURE_URL="https://github.com/${GH_SLUG}/releases/download/v${NEW_VERSION}/${ZIP_NAME}"

ITEM_XML="    <item>
      <title>Apollo $NEW_VERSION</title>
      <pubDate>$RFC_DATE</pubDate>
      <sparkle:version>$NEW_BUILD</sparkle:version>
      <sparkle:shortVersionString>$NEW_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>"
if [[ -n "$CHANNEL" ]]; then
    ITEM_XML+="
      <sparkle:channel>$CHANNEL</sparkle:channel>"
fi
if [[ -n "$NOTES" ]]; then
    ITEM_XML+="
      <description><![CDATA[$NOTES]]></description>"
fi
ITEM_XML+="
      <enclosure
        url=\"$ENCLOSURE_URL\"
        sparkle:edSignature=\"$ED_SIG\"
        length=\"$LEN\"
        type=\"application/octet-stream\" />
    </item>"

# ── Insert into appcast.xml ───────────────────────────────────────────────
# If appcast.xml already exists, PREPEND the new item right after
# the opening <channel> chrome. If not, bootstrap from a fresh
# template so first-time runs Just Work.
if [[ ! -f "$APPCAST" ]]; then
    echo "→ Bootstrapping fresh appcast.xml…"
    cat > "$APPCAST" <<APPCAST_HEADER
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Apollo updates</title>
    <description>Atualizações OTA do Apollo</description>
    <language>pt-br</language>
$ITEM_XML
  </channel>
</rss>
APPCAST_HEADER
else
    echo "→ Prepending new item to existing appcast.xml…"
    # Insert ITEM_XML on the line right after <channel>'s last
    # chrome (we anchor on "<language>" since the bootstrap puts
    # it as the last header element). If your appcast has a
    # different header, adjust the anchor pattern here.
    python3 - "$APPCAST" <<PYEOF
import sys, re
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()
new_item = """$ITEM_XML"""
# Insert right after </language> if present, else right after
# the opening <channel> tag.
if "</language>" in content:
    content = content.replace("</language>", "</language>\n" + new_item, 1)
else:
    content = re.sub(r"(<channel[^>]*>)", r"\1\n" + new_item, content, count=1)
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
PYEOF
fi

echo ""
echo "✓ Release $NEW_VERSION (build $NEW_BUILD) ready"
echo ""
echo "  dist/$ZIP_NAME"
echo "  dist/$DMG_NAME"
echo "  dist/appcast.xml"
echo ""

# ── Optional: auto-upload via gh CLI ──────────────────────────────────────
# Triggered with `APOLLO_UPLOAD=1`. Requires:
#   • `gh` CLI installed and authenticated to the org/user
#     that owns the repo (`gh auth login` if needed).
#   • `APOLLO_GITHUB_SLUG` set to the real "user/repo".
#   • The repo already exists on GitHub.
#
# After the upload:
#   • A GitHub Release tagged `vX.Y.Z` is created (or
#     updated) with both the .zip and .dmg attached.
#   • The appcast.xml is left in dist/ — you commit + push
#     it (typically to a `docs/` folder or `gh-pages`
#     branch) so GitHub Pages re-serves the feed.
if [[ "${APOLLO_UPLOAD:-0}" = "1" ]]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "✗ APOLLO_UPLOAD=1 set but `gh` CLI not installed." >&2
        echo "  Install: brew install gh" >&2
        exit 1
    fi
    TAG="v$NEW_VERSION"
    TITLE="Apollo $NEW_VERSION"
    NOTES_BODY="${NOTES:-Build $NEW_BUILD}"

    echo "→ Creating GitHub Release $TAG on $GH_SLUG…"
    # `gh release create` will error if the tag already
    # exists. In that case, fall back to uploading assets
    # onto the existing release (useful for rebuilds that
    # keep the same version number).
    if gh release view "$TAG" --repo "$GH_SLUG" >/dev/null 2>&1; then
        echo "  Tag $TAG already exists — uploading assets to existing release."
        gh release upload "$TAG" "$ZIP_PATH" "$DMG_PATH" \
            --repo "$GH_SLUG" --clobber
    else
        gh release create "$TAG" "$ZIP_PATH" "$DMG_PATH" \
            --repo "$GH_SLUG" \
            --title "$TITLE" \
            --notes "$NOTES_BODY"
    fi

    echo ""
    echo "✓ Uploaded to https://github.com/${GH_SLUG}/releases/tag/${TAG}"
    echo ""
    echo "──────────────────────────────────────────────────"
    echo "  $NEW_VERSION is on GitHub but NOT advertised yet."
    echo "  Sparkle feed (docs/appcast.xml) still serves the"
    echo "  PREVIOUS release. Existing testers won't be"
    echo "  notified until you explicitly promote."
    echo "──────────────────────────────────────────────────"
    echo ""
    echo "Test the build first:"
    echo "  open dist/$DMG_NAME    (or copy build/Apollo.app to /Applications)"
    echo ""
    echo "When you're happy and want testers to see the update:"
    echo "  ./promote.sh"
    echo ""
    echo "Dry-run the promotion (preview the diff, no push):"
    echo "  ./promote.sh --dry-run"
else
    echo "Next steps:"
    echo "  1. Upload dist/$ZIP_NAME + dist/$DMG_NAME to a GitHub Release"
    echo "     gh release create v$NEW_VERSION dist/$ZIP_NAME dist/$DMG_NAME"
    echo "     (or run again with APOLLO_UPLOAD=1 to do it automatically)"
    echo "  2. When ready to notify testers: ./promote.sh"
    echo ""
    echo "Verify the new appcast head before promoting:"
    echo "  head -30 dist/appcast.xml"
fi
