# Ajustes visuais solicitados após o merge

Base: `6e4de9a`, Apollo 2.0.0 (98), após a integração da estável 1.9.9 (97) com o PR #1.

Solicitações explícitas do usuário, com capturas de tela em 22/09/2026:

- Equiparar ícone e texto de **Anexar**, na barra de seleção, aos menus vizinhos. O botão simples usava `Editorial.sans(11)` (9,35 pt); agora usa `NSFont.systemFontSize`, confirmado como 13 pt no macOS atual. O restante da barra permanece igual.
- Remover Liquid Glass do fundo da pergunta **O que deseja fazer?**. Os estados de carregamento e escolha usam `Editorial.popup` opaco, sem conteúdo da lista atravessando o cartão.
- No arrasto de arquivos, manter a cápsula da linha com sua largura original, altura de 26 pt e rótulo normal **ANEXAR**. Foram retirados o crescimento horizontal de 28 pt, a altura de 30 pt e o texto **ARRASTE AQUI**. O realce de soltura permanece, dentro da coluna original.

Somente três arquivos de interface foram alterados. Não houve mudança de lógica de upload, roteamento ou substituição. Não foram criados testes que apenas repetem esses valores de estilo. A validação desta etapa é compilação Release universal, assinatura e abertura do aplicativo; a aceitação visual pertence ao usuário.

Resultado: `./build.sh release --universal` concluiu com sucesso. Assinatura Developer ID com timestamp, entitlements e verificação `--deep --strict` aprovados. Os hashes desta build e dos três fontes alterados estão em `ui-build-audit.json`.

Os arquivos `pr-visual-audit.json` e `build-audit.json` registram o estado anterior, validado no merge. Estas três diferenças posteriores são autorizadas pelo usuário e não fazem parte daquela comparação histórica.

Continuidade: session_report local, pendente de ingestão. O MCP Segundo Cérebro retornou erro em `buscar_memoria`; as ferramentas de resolução e registro não estão disponíveis nesta sessão.
