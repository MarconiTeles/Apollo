# Apollo 2.0.0 (98) — publicação

Publicação autorizada explicitamente pelo usuário em 22/09/2026, após os ajustes visuais da cápsula e do switch.

## Proveniência

- Base estável 1.9.9 (97), integração do PR #1 e ajustes aprovados nas etapas anteriores.
- Fonte `2e50a9e6d3c64e996e133b7d305014dceb731c6b`, main remota e local conferidas iguais antes da preparação. Código de produto idêntico à build aprovada de `06c0dd6`.
- Apollo Review: `5256f8644633131044ba9f6142f120b0b8be6475`, checkout limpo.
- Build universal 2.0.0 (98), arm64/x86_64, mínimo macOS 14.0 em ambos os executáveis. Hash do executável principal preservado da build aprovada: `9e52240c441b0d352b08c2eff444c870807570753b740684ac94a44bdaff0688`.
- Usadas as etapas existentes de `release.sh` a partir de `verify_review_helper`, sem incrementar a build nem recompilar o aplicativo aprovado. Perfil antigo `AC_PASSWORD_APOLLO` ausente; perfil existente `HubbleNotary` autenticou com sucesso e foi usado sem ler ou copiar credenciais.

## Verificações

- `swift test -c release`: 201 testes executados, 197 aprovados, quatro testes externos pulados, zero falhas. Os externos exigem `REVIEW_E2E=1` e publicação no backend; continuam fora desta execução.
- Notarização do aplicativo Accepted: `5672728d-86f5-460c-9208-9b1802c328be`.
- Notarização do DMG Accepted: `a4abd458-2864-4e41-8343-135b8af3c052`.
- Tickets de notarização anexados ao aplicativo e ao DMG. O ZIP OTA é criado após anexar o ticket.
- Assinatura Ed25519 do ZIP final validada por CryptoKit contra a chave pública instalada na estável 1.9.9. A entrada padrão no Keychain estava ausente; o assinador oficial usou o backup existente diretamente, sem copiar/expor a chave, gerar outra chave ou alterar o Keychain.
- ZIP final extraído: hash do executável aprovado preservado, assinatura profunda válida e ticket de notarização verificado.
- O DMG gerado pelo script não tinha assinatura externa utilizável pelo Gatekeeper. Aplicada assinatura Developer ID ao contêiner; nova notarização do DMG assinado Accepted (`2eb32b77-9947-4e9d-bdcd-04ef4d379d9d`), ticket anexado e Gatekeeper aprovado antes da publicação.
- DMG final montado somente para leitura: executável aprovado, assinatura profunda e ticket verificados.

## Estado da publicação

Release pública estável criada em https://github.com/MarconiTeles/Apollo/releases/tag/v2.0.0, marcada como latest em 2026-09-22T23:26:48Z. SHA-256 e tamanhos dos dois assets remotos conferidos iguais aos pacotes locais validados. ZIP público respondeu HTTP 200 com 50.770.414 bytes. Feed público promovido neste commit para 2.0.0 (98), sem canal silent; a propagação no GitHub Pages será conferida após o push. Não foi executada uma atualização real sobre a instalação estável deste Mac.

## Continuidade

Registro local pendente de ingestão no Segundo Cérebro: `buscar_memoria` retornou erro; operações de resolução e gravação não foram expostas. Proveniência: session_report, Git, testes, notarização e verificações dos artefatos desta sessão.
