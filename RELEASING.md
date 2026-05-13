# Releasing Apollo (OTA via Sparkle)

Apollo entrega atualizações automáticas via [Sparkle](https://sparkle-project.org).
Tudo é hospedado no GitHub: os binários como assets de **GitHub Releases**, e o
`appcast.xml` (feed que Sparkle consulta) via **GitHub Pages**.

Não precisa de servidor próprio. Quase tudo está no `release.sh`.

---

## Visão geral do fluxo

```
[ Seu Mac ]                              [ GitHub ]                   [ Usuário ]
   │                                          │                            │
   │  release.sh --bump-patch                 │                            │
   │  ├─ build universal + DMG                │                            │
   │  ├─ ZIP + sign_update (EdDSA Keychain)   │                            │
   │  ├─ adiciona <item> em appcast.xml       │                            │
   │  └─ (APOLLO_UPLOAD=1)                    │                            │
   │     └─ gh release create vX.Y.Z ─────────▶ Release com .zip + .dmg   │
   │                                          │                            │
   │  git add docs/appcast.xml                │                            │
   │  git commit && git push ─────────────────▶ Pages re-serve appcast.xml │
   │                                          │                            │
   │                                          │   Apollo chama ⌘ "Verificar│
   │                                          │   Atualizações…"           │
   │                                          │      ▲                     │
   │                                          │      │                     │
   │                                          ◀──────┴──── Apollo lê       │
   │                                          │             appcast.xml    │
   │                                          │             via Sparkle    │
   │                                          ◀──── baixa .zip ───────────│
   │                                          │     Sparkle valida         │
   │                                          │     assinatura, reinicia   │
```

---

## Setup inicial (one-time)

### 1. Instalar `gh` CLI

```bash
brew install gh
gh auth login
```

### 2. Criar o repo no GitHub

Sugestão: `<seu-user>/apollo` (ou outro nome). PÚBLICO se quiser usar Pages
no plano grátis — Pages em repo privado exige GitHub Pro.

```bash
# do diretório local do Apollo:
git init
git add .
git commit -m "Initial commit"
gh repo create MarconiTeles/Apollo --source=. --public --push
```

### 3. Configurar Pages

No GitHub web → repo → **Settings → Pages**:

- **Source**: Deploy from a branch
- **Branch**: `main` / pasta `/docs`

(O `release.sh` vai usar `docs/appcast.xml` como caminho canônico. Crie a pasta
`docs/` no repo se ainda não existir.)

Após habilitar, sua URL fica:
```
https://marconiteles.github.io/Apollo/appcast.xml
```

### 4. Apontar `SUFeedURL` no Info.plist

Edite `Sources/DayPanel/Resources/Info.plist`:

```xml
<key>SUFeedURL</key>
<string>https://marconiteles.github.io/Apollo/appcast.xml</string>
```

Já está apontando para `https://marconiteles.github.io/Apollo/appcast.xml` no
Info.plist — só certifique que o Pages do repo `MarconiTeles/Apollo` esteja
configurado pra servir essa URL exata (Sparkle compara string a string).

### 5. Configurar o slug no shell

Para o `release.sh` montar as URLs corretas no `<enclosure>`:

```bash
# no seu ~/.zshrc ou ~/.bash_profile:
export APOLLO_GITHUB_SLUG="MarconiTeles/Apollo"
```

E recarregue (`source ~/.zshrc`).

### 6. Chaves EdDSA (já feito)

A chave pública já está no `Info.plist`. A privada está no seu **macOS Keychain**
(item "ed25519 sparkle key for application updates"). **Mantenha um backup**:

- Abra `Keychain Access.app`
- Procure por "ed25519 sparkle"
- File → Export Items → salve `.p12` num lugar seguro (1Password / cofre)

Se você perder essa chave, todos os usuários instalados ficam órfãos —
você terá que distribuir uma versão totalmente nova manualmente.

---

## Fazendo um release

A cada nova versão:

```bash
./release.sh --bump-patch --notes "Corrigido bug X, adicionada feature Y"
```

Variações de bump:
- `--bump-patch`  → 1.4.0 → 1.4.1 (bugfix)
- `--bump-minor`  → 1.4.0 → 1.5.0 (feature)
- `--bump-major`  → 1.4.0 → 2.0.0 (breaking change)
- `--set-version 2.0.0` → versão explícita

O script:

1. Bump `CFBundleShortVersionString` e `CFBundleVersion` no Info.plist
2. Roda `./package.sh` (build universal + DMG)
3. Gera `dist/Apollo-X.Y.Z.zip` (Sparkle prefere ZIP)
4. Assina o ZIP com a private key do Keychain (`sign_update`)
5. Adiciona um novo `<item>` em `dist/appcast.xml`

### Upload automático

Defina `APOLLO_UPLOAD=1` e o script também cria o GitHub Release:

```bash
APOLLO_UPLOAD=1 ./release.sh --bump-patch --notes "Bug fixes"
```

Faz `gh release create vX.Y.Z dist/Apollo-X.Y.Z.zip dist/Apollo-X.Y.Z.dmg`
no repo definido por `APOLLO_GITHUB_SLUG`.

### Publicar o appcast (parte que ainda é manual)

Depois do `release.sh`:

```bash
cp dist/appcast.xml docs/appcast.xml
git add docs/appcast.xml Sources/DayPanel/Resources/Info.plist
git commit -m "Release vX.Y.Z"
git push
```

Em ~30 segundos o Pages re-serve o appcast e os usuários do Apollo já podem
"Verificar Atualizações…" e baixar a nova versão.

---

## Como o usuário recebe o update

Sparkle agenda verificações automáticas a cada 24h (`SUScheduledCheckInterval = 86400`)
e também aparece no menu **Apollo → Verificar Atualizações…**. Quando encontra
uma versão mais nova no appcast:

1. Mostra dialog "Apollo X.Y.Z is available!" com release notes
2. Usuário clica "Install Update"
3. Sparkle baixa o ZIP, valida a assinatura EdDSA contra `SUPublicEDKey`
4. Substitui o app no `/Applications` automaticamente
5. Relança o Apollo na nova versão

Tudo sem o usuário precisar baixar DMG, arrastar, mover, etc.

---

## Debug / sanity checks

### Validar o appcast localmente

```bash
xmllint --noout dist/appcast.xml && echo "well-formed"
```

### Verificar a assinatura de um ZIP

```bash
.build/artifacts/sparkle/Sparkle/bin/sign_update dist/Apollo-X.Y.Z.zip
```

Compara o output com o `sparkle:edSignature=...` no appcast — devem ser idênticos.

### Forçar uma checagem agora

No Apollo: **⌘ → "Verificar Atualizações…"**. Se a versão atual for igual à do
appcast, Sparkle mostra "You're up to date!". Se for menor, oferece o update.

### Logs do Sparkle

```bash
log stream --predicate 'subsystem == "org.sparkle-project.Sparkle"' --info
```

Filtra por mensagens do Sparkle no Console — útil pra debugar feed URL
errada / assinatura inválida / etc.

---

## Limitação conhecida: adhoc → Developer ID não atualiza via Sparkle

Sparkle **rejeita por design** o update quando o Team ID do app
atual não bate com o da nova versão. Isso vale na transição
one-time adhoc → Developer ID — qualquer usuário que ainda tem
instalado um build pré-1.5.0 (sem certificado, sem Team ID) vai
ver um erro do Sparkle ao tentar atualizar pra uma versão
notarizada, mesmo que a nova esteja perfeitamente assinada.

Pra eles, o fluxo é **instalação manual one-time**:

1. Baixa o DMG da versão atual em
   https://github.com/MarconiTeles/Apollo/releases/latest
2. Apaga `/Applications/Apollo.app`
3. Arrasta o `Apollo.app` do DMG pra `/Applications`
4. Abre — Gatekeeper aceita sem prompt (notarizado)
5. Reconecta ClickUp + Google Calendar (TCC + Keychain ACLs
   resetam porque o macOS vê como "app diferente" pela mudança
   de identidade de assinatura)

A partir daí, OTA via Sparkle funciona normal entre releases.

Se você ver "An error occurred while running the updater" ou
"failed to probe status service" em um teste de OTA, primeira
coisa a verificar é se o app instalado é adhoc ou Developer ID:

```bash
codesign -dv /Applications/Apollo.app 2>&1 | grep TeamIdentifier
```

Sem `TeamIdentifier` (= adhoc) → é esse caso, manda instalar o
DMG manualmente.

---

## Anatomia do appcast.xml

Cada release vira um `<item>` no canal. O mais novo fica no topo:

```xml
<item>
  <title>Apollo 1.5.0</title>
  <pubDate>Sat, 11 May 2026 02:45:00 +0000</pubDate>
  <sparkle:version>12</sparkle:version>                    <!-- CFBundleVersion -->
  <sparkle:shortVersionString>1.5.0</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
  <description><![CDATA[Release notes em Markdown ou HTML]]></description>
  <enclosure
    url="https://github.com/MarconiTeles/Apollo/releases/download/v1.5.0/Apollo-1.5.0.zip"
    sparkle:edSignature="abcdef…"
    length="93421056"
    type="application/octet-stream" />
</item>
```

Você pode editar manualmente pra reescrever release notes, mas geralmente
deixe o `release.sh` cuidar do XML.
