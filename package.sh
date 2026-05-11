#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_DISPLAY_NAME="Apollo"
APP="build/${APP_DISPLAY_NAME}.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "Sources/DayPanel/Resources/Info.plist")"

DIST_DIR="dist"
STAGE_DIR="$DIST_DIR/.stage"
DMG_NAME="Apollo-${VERSION}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

./build.sh release --universal

rm -rf "$DIST_DIR"
mkdir -p "$STAGE_DIR"

cp -R "$APP" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

# Double-clickable bypass for Gatekeeper. Adhoc-signed apps get
# blocked on first launch from quarantined sources (downloaded
# DMGs); the recipient would otherwise have to right-click → Open
# or paste a Terminal command. With this `.command` script they
# just double-click after dragging the app to Applications and
# Apollo opens immediately.
cat > "$STAGE_DIR/Remover-Quarentena.command" <<'CMDEOF'
#!/bin/bash
# Apollo first-launch helper: removes macOS quarantine flag from the
# installed Apollo.app so Gatekeeper stops blocking it. Also kills
# any running translocated instance and relaunches Apollo from its
# real /Applications location, since a translocated copy keeps
# running from a read-only sandbox where some custom-window
# behavior (e.g. clicks on the title-bar toolbar) is broken.

set +e
clear
cat <<'BANNER'

  Apollo — Liberar o app no macOS
  ────────────────────────────────

BANNER

APP_PATH="/Applications/Apollo.app"

if [ ! -d "$APP_PATH" ]; then
    echo "  ✗ Não encontrei $APP_PATH"
    echo "    Arraste o Apollo.app para a pasta Applications primeiro,"
    echo "    depois rode este script de novo."
    echo ""
    read -n 1 -s -r -p "  Pressione qualquer tecla para fechar..."
    exit 1
fi

# Quit any running Apollo (including translocated instances) so the
# upcoming `open` actually starts a fresh launch from /Applications
# instead of just bringing the broken translocated window forward.
echo "  → Encerrando instância em execução (se houver)..."
osascript -e 'tell application id "com.painellunar.app" to quit' 2>/dev/null
pkill -x DayPanel 2>/dev/null
# Give the OS a moment to clean up the translocation mount.
sleep 1.2

echo "  → Removendo quarentena de $APP_PATH..."
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null
xattr -dr com.apple.provenance "$APP_PATH" 2>/dev/null

echo ""
echo "  ✓ Pronto. Abra o Apollo pelo Launchpad ou Spotlight."
sleep 1
exit 0
CMDEOF
chmod +x "$STAGE_DIR/Remover-Quarentena.command"

cat > "$STAGE_DIR/LEIA-ME.txt" <<EOF
Apollo ${VERSION}
=======================

Instalação em 3 passos
----------------------
1. Arraste "Apollo.app" para a pasta "Applications" ao lado.
2. Dê duplo-clique em "Remover-Quarentena.command".
   Vai abrir um Terminal, rodar ~2 segundos e fechar.
3. Abra o Apollo pelo Launchpad ou Spotlight.

⚠️  IMPORTANTE: NÃO abra o Apollo direto antes do passo 2.
    Se você já tentou e o app abriu mas a barra superior não
    responde a cliques, é porque o macOS isolou o app em modo
    "App Translocation" (sandbox read-only). O script "Remover-
    Quarentena.command" detecta a instância travada, encerra
    ela e libera a quarentena. Depois é só abrir pelo Launchpad
    como no passo 3.

Se preferir não rodar o script, libere manualmente:

OPÇÃO A — clique-direito
  1. Abra a pasta "Applications" no Finder.
  2. Clique com o botão direito em "Apollo" → "Abrir".
  3. No alerta que aparecer, clique "Abrir" novamente.
  (Funciona só se você AINDA não tinha aberto o app antes.)

OPÇÃO B — Terminal
  xattr -dr com.apple.quarantine "/Applications/Apollo.app"
  Se já abriu o app antes, encerre-o no Activity Monitor primeiro.

Permissões necessárias
----------------------
Na primeira vez, o app vai pedir:
  • Acesso ao Calendário (para mostrar eventos do macOS / Google Calendar)
  • Acesso a notificações (opcional, ativável em Configurações)
  • Acesso para enviar Apple Events (para sincronizar respostas RSVP)

Configurar Google Calendar
--------------------------
Se você ainda não tem o Google Calendar conectado ao macOS:
  Configurações do Sistema → Contas de Internet → Adicionar conta → Google
  Marque "Calendários" ao adicionar a conta.

Configurar ClickUp (opcional)
-----------------------------
No app, abra as configurações e cole o seu Personal API Token do ClickUp.
Você pode gerá-lo em: clickup.com → Configurações → Apps → API Token.
EOF

# Build a compact UDZO DMG. The volume name is what shows up in Finder.
hdiutil create \
    -volname "Apollo ${VERSION}" \
    -srcfolder "$STAGE_DIR" \
    -ov -format UDZO \
    "$DMG_PATH" > /dev/null

rm -rf "$STAGE_DIR"

echo ""
echo "✓ Built $DMG_PATH"
echo "  Size: $(du -h "$DMG_PATH" | cut -f1)"
echo ""
echo "  Distribute this file. Recipients should follow LEIA-ME.txt"
echo "  inside the DMG to bypass Gatekeeper on first launch."
