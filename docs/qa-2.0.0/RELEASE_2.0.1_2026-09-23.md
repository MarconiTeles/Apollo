# Apollo 2.0.1 (99) — publicação pública

Publicação autorizada pelo usuário. Fonte e tag v2.0.1: 834857419a4c4497a8c66837cbc66552b2342ba6; helper Review: 5256f8644633131044ba9f6142f120b0b8be6475. Produto igual ao código validado anteriormente, com versão/build atualizados. Pipeline recebeu assinatura externa do DMG e opção de usar diretamente o backup existente da chave Sparkle, sem copiar/expor segredo nem alterar o Keychain.

- Release estável/latest: https://github.com/MarconiTeles/Apollo/releases/tag/v2.0.1.
- Universal arm64/x86_64, executável principal minos 26.0/sdk 27.0. Bundles principal e Review mínimo macOS 26.0.
- App e DMG notarizados e tickets anexados; assinatura deep/strict e Gatekeeper aprovados. IDs de notarização e hashes em release-2.0.1-audit.json.
- ZIP final extraído e conferido: versão 2.0.1 (99), mínimo 26, hash do executável, assinatura e ticket. Assinatura Ed25519 validada contra chave pública instalada no Apollo 2.0.0.
- App final aberto no macOS 27 (PID 66108); conferência visual da lista, header e traffic lights. Não foi substituído /Applications/Apollo.app, nem executado um upgrade OTA real sobre essa instalação.
- Testes do código atual na etapa anterior: 198 aprovados, 4 E2Es externos ignorados. Nesta etapa, validação de distribuição e smoke do pacote final. Sem execução física em Intel ou macOS 26.
- Ambos os assets baixados pelas URLs públicas: HTTP 200, tamanho e SHA-256 idênticos aos pacotes locais.
- Feed canônico https://marconiteles.github.io/Apollo/appcast.xml conferido após Pages run 35813660360 concluir com sucesso: 2.0.1 (99), mínimo 26.0, sem canal silent, assinatura/tamanho/URL idênticos ao pacote validado. Histórico anterior preservado. Atualização disponível aos usuários compatíveis no próximo check do Sparkle.

## Continuidade

Session_report local pendente de ingestão no Segundo Cérebro: buscar_memoria retornou erro e ferramentas de gravação não foram expostas. Evidência: Git, notarização, validação criptográfica, execução e readback público desta sessão. Trabalho realizado em apollo-2.0.0, branch codex/apollo-2.0.0; integrado à main local/remota.
