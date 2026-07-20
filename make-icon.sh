#!/bin/bash
# Compila o AppIcon do Apollo a partir do documento Icon Composer
# `Sources/DayPanel/Resources/APOLLO.icon` (formato .icon do macOS 26, com
# gradiente + Liquid Glass dinâmico). Gera DOIS artefatos:
#   • build/icon/Assets.car   — o ícone dinâmico (glass/gradient) que o macOS 26
#                               resolve via CFBundleIconName;
#   • build/icon/AppIcon.icns — fallback estático (Finder antigo, thumbnails).
# Committado junto ao app para builds reprodutíveis sem o Xcode/Icon Composer
# aberto. (Antes: iconset estático a partir de APOLLO_ICON_06.png.)

set -euo pipefail
cd "$(dirname "$0")"

SRC="Sources/DayPanel/Resources/APOLLO.icon"
OUT="build/icon"

if [ ! -d "$SRC" ]; then
    echo "✗ Documento Icon Composer $SRC não encontrado"
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

# actool compila o .icon → Assets.car (dinâmico) + AppIcon.icns (fallback).
# `--app-icon AppIcon` casa com CFBundleIconName/CFBundleIconFile no Info.plist;
# por isso o .icon precisa se chamar AppIcon.icon durante a compilação.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -R "$SRC" "$WORK/AppIcon.icon"

xcrun actool "$WORK/AppIcon.icon" \
    --compile "$OUT" \
    --app-icon AppIcon \
    --output-partial-info-plist "$OUT/icon-info.plist" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --errors --warnings --notices >/dev/null

[ -f "$OUT/Assets.car" ]   || { echo "✗ actool não gerou Assets.car"; exit 1; }
[ -f "$OUT/AppIcon.icns" ] || { echo "✗ actool não gerou AppIcon.icns"; exit 1; }
echo "✓ $OUT/{Assets.car,AppIcon.icns} gerados de APOLLO.icon"
