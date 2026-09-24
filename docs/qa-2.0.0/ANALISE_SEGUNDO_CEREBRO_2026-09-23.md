# Análise do Segundo Cérebro — Apollo

Análise solicitada pelo usuário; consulta direta ao MCP em 23/09/2026 e comparação pontual com Git, fonte e release remota. Nenhum código de produto nem nota canônica alterado.

## Registros consultados

- Mapa apollo-review: prj_01a053d003697cf8827c8be0595857fd, revisão 11. Leitura parcial orientada ao estado/histórico.
- Estado: prj_01a053ce0a15734087f7de57a555f0c0, revisão 12. Lidos os primeiros 9.585 caracteres, até início do histórico explicitamente encerrado; restante não necessário para avaliar o resumo vigente.
- Sessão recente: ses_01a0cbc4ee2e7558a11ee6d3a2ce0b43, revisão 32, lida integralmente. Contém a resposta final da publicação 2.0.1, mas seu título/pedido é a lista de plugins do ambiente, não o trabalho realizado.
- Buscas direcionadas: reversão DEV-01 (dec_01a08255c966781eaa9dddd5767f14d2), geometria experimental (dec_01a08214093778248660cda3b14274e5), plano de otimização (dec_01a081b8ac197438b07664709cba654f). Excertos, não releitura integral de cada decisão.

## Achados

1. O filtro projeto=“Apollo” retornou erro; a busca sem filtro encontrou o nome canônico “apollo-review”, sob o qual as consultas funcionaram. Não foi determinado se o erro é causado exclusivamente pelo alias. resolver_projeto não está exposto.
2. Resumo vigente desatualizado: abre com manutenção de caminhos em 14/09, main 698816f e estado de reversão DEV-01 de 08/09, que ainda diz produção 1.9.9 (97). Hoje Git local limpo em 63d54f7 e GitHub releases/latest confirmou v2.0.1 pública, sem draft/prerelease.
3. Histórico recente foi ingerido parcialmente como session_report: a sessão contém a publicação 2.0.1/macOS26+, mas faltam no resumo vigente a nova release, a migração SDK27 autorizada, o contrato visual atual e evidências de validação. Portanto não é ausência total da sessão, e sim falha de consolidação/qualidade do resumo.
4. O plano de otimização é recuperado como plano pendente, embora a seção vigente do estado diga explicitamente que foi cancelado pela reversão. Não retomar DEV-01 rejeitada por causa do ranking da busca. Decisões antigas de geometria tampouco representam o pedido final de 22/09: fonte atual usa raio 12 somente no macOS27, material dark por luminância e traffic lights nativos com SDK27.
5. Nome/descrição do mapa juntam host DayPanel e históricos do frontend Review/Tauri. Risco de escolher checkout/escopo errado; não houve renomeação ou separação automática nesta análise.
6. Saúde global do serviço reportou healthy=false, queue_failed=71, project_sync_pending=8 e queue_pending=11. São contagens globais, sem atribuição demonstrada ao Apollo nem causa diagnosticada. A busca genérica por arquivo Apollo devolveu principalmente produtos de build/frameworks nesta amostra.

## Estado útil para continuidade

Release atual 2.0.1 (99), universal, mínimo macOS26, SDK27; fonte da release 8348574, main atual 63d54f7. Evidências detalhadas em RELEASE_2.0.1_2026-09-23.md e release-2.0.1-audit.json. Testes prévios: 198 aprovados, quatro externos ignorados. Não houve teste físico em Intel/macOS26 nem upgrade OTA real sobre /Applications. Ausência dessas verificações não demonstra defeito.

Próxima manutenção recomendada: consolidar o resumo atual com links para evidências, marcar decisões/plano substituídos, melhorar título da sessão e distinguir host/Review sem perder agrupamento aprovado; diagnosticar saúde do serviço separadamente. Não reabrir automaticamente otimizações canceladas.

## Registro

Session_report local pendente de ingestão. registrar_report e resolver_projeto não estão expostos nesta sessão. A análise não foi gravada no vault por shell nem foi substituído conteúdo canônico a partir de leitura truncada.
