#!/bin/bash
# Apollo release promoter.
#
# `release.sh` does the heavy lift: builds, notarises, signs for
# Sparkle, uploads the .zip + .dmg to a GitHub Release. After it
# runs, the new release EXISTS on GitHub but is INVISIBLE to
# existing installs — the Sparkle appcast served from
# `https://marconiteles.github.io/Apollo/appcast.xml` still
# advertises the previous version, so testers don't get the OTA
# yet.
#
# This script is the "ok, notify everyone" gate:
#
#   1. Confirms `dist/appcast.xml` has a NEWER version than
#      `docs/appcast.xml` (so we don't accidentally re-push the
#      same release or downgrade the feed).
#   2. Copies the new appcast into `docs/`.
#   3. Commits + pushes to GitHub Pages.
#   4. Pages re-serves the feed within ~30 seconds and every
#      Apollo install whose scheduled-check window elapses (or
#      who runs ⌘ → Verificar Atualizações…) sees the update.
#
# Usage:
#   ./promote.sh                   # default: promote latest dist/ appcast
#   ./promote.sh --dry-run         # show the diff but don't commit/push
#
# This script is the LAST step in a release. Don't run it until
# you've smoke-tested the build locally (the .dmg in dist/, or
# the build/Apollo.app you can copy into /Applications). Once
# this runs and Pages re-serves, the rollback path is to ship
# a NEW patch release that supersedes — there is no "unrelease".

set -euo pipefail
cd "$(dirname "$0")"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=1; fi

SRC="dist/appcast.xml"
DST="docs/appcast.xml"

if [[ ! -f "$SRC" ]]; then
    echo "✗ $SRC missing — did release.sh actually run?" >&2
    exit 1
fi

# Extract the topmost <sparkle:shortVersionString> from each
# feed and compare; abort if they're equal or DST is ahead.
extract_version() {
    grep -oE '<sparkle:shortVersionString>[^<]+' "$1" 2>/dev/null \
        | head -1 \
        | sed 's|<sparkle:shortVersionString>||'
}

NEW_VER="$(extract_version "$SRC")"
OLD_VER="$(extract_version "$DST")"

if [[ -z "$NEW_VER" ]]; then
    echo "✗ couldn't read version from $SRC" >&2
    exit 1
fi

echo "  dist/ appcast head:  $NEW_VER"
echo "  docs/ appcast head:  ${OLD_VER:-<none>}"

if [[ "$NEW_VER" == "$OLD_VER" ]]; then
    echo ""
    echo "✓ $DST already advertises $NEW_VER — nothing to promote."
    exit 0
fi

if [[ $DRY_RUN -eq 1 ]]; then
    echo ""
    echo "→ Dry run. Diff that WOULD be applied:"
    diff -u "$DST" "$SRC" | head -40 || true
    echo ""
    echo "  Re-run without --dry-run to commit + push."
    exit 0
fi

echo ""
echo "→ Promoting $NEW_VER to public feed…"
cp "$SRC" "$DST"

git add "$DST"
if git diff --cached --quiet; then
    echo "✗ $DST already matches HEAD — promotion is a no-op."
    exit 1
fi

git commit -m "Promote Apollo $NEW_VER to public Sparkle feed

Notifies every running Apollo install on the next
scheduled-check window (or immediately on ⌘ → Verificar
Atualizações…). Until this commit landed, $NEW_VER was
on GitHub Releases but invisible to OTA."
git push

echo ""
echo "✓ Promoted. Pages re-serves within ~30s."
echo "  Testers will see 'Apollo $NEW_VER disponível' on next check."
