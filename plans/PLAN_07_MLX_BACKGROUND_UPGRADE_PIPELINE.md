# PLAN_07 — Upgrade de exemplo de código via MLX em background (patch reativo)

## Objetivo

Reintroduzir o pipeline MLX→crítica→formatação (draft MLX + crítica FM +
formatação FM) para o exemplo de código, agora rodando inteiramente em
background (nunca bloqueando a tela), aplicando o resultado como um PATCH
sobre o `StudyTopic` já persistido pela Fase 1 (`PLAN_06`) via
`applyCodeExampleUpgrade`.

## Por que esta etapa existe

`SOLUTIONS_PLAN.md` D1/§5.2, passos 3-8: o projeto já provou, com bugs
reais documentados (`PLAN.md` §8.1), que FM sozinho sem crítica alucina
API em código gerado — "nunca rodar a crítica" está descartado por
evidência própria do projeto. `PLAN_06` removeu o MLX do caminho
síncrono mas deixou o upgrade como stub/no-op; este plano implementa o
upgrade de verdade, preservando a defesa contra hallucination sem pagar
o custo no relógio do usuário.

## Estado esperado antes de começar

`PLAN_06` implementado e validado: Fase 1/Fase 2 de persistência
existente, `GenerationStage` funcionando, `generateCodeExampleFM` como
caminho síncrono principal, `upgradeCodeExampleViaMLX`/
`applyCodeExampleUpgrade` existindo como stubs/esqueleto.

## Dependências

`PLAN_06` (dependência real e direta — este plano preenche o esqueleto
que `PLAN_06` deixou pronto).

## Arquivos provavelmente afetados

- `Services/StudyGenerator.swift` (`upgradeCodeExampleViaMLX` —
  implementação real; reaproveita a lógica hoje existente em
  `critiqueCodeDraft`, linhas 380-417, e `formatCodeExample`, linhas
  298-369, que `PLAN_06` preservou/renomeou, não deletou)
- `Services/TopicRepository.swift` (`runBackgroundUpgrade`,
  `applyCodeExampleUpgrade` — implementação real do patch)

## Mudanças a implementar

### 1. `upgradeCodeExampleViaMLX(topic:context:draftContext:)` — implementação real

Reaproveita o pipeline hoje existente: MLX draft do exemplo (texto livre,
código + explicação) → FM critique (1 chamada, mesmo prompt de hoje,
`critiqueCodeDraft`) → FM format (1 chamada, +retry se truncado, mesmo
prompt de hoje, `formatCodeExample`). Roda inteiramente dentro da trilha
de background do `GenerationOrchestrator`, nunca no caminho síncrono.

### 2. `runBackgroundUpgrade` dispara o upgrade com prioridade inicial `.poolFill`

Prioridade inicial `.poolFill` (não compete com nada user-facing) — a
lógica de prioridade adaptativa baseada em checks determinísticos é
`PLAN_08`; NESTE plano, a prioridade é sempre `.poolFill`, fixa (passo
intermediário deliberado, mesma lógica de "não implementar a próxima
camada antes desta existir").

### 3. `applyCodeExampleUpgrade(topicID:example:)` — patch reativo real

SE o resultado do upgrade for estruturalmente válido E diferente do
exemplo FM-only da Fase 1 (comparação simples: código diferente OU
walkthrough diferente) → PATCH no `StudyTopic` persistido (mesmo
`persistentModelID`, não cria um novo objeto). SE inválido → descarta,
mantém a versão FM-only da Fase 1. Usar `PersistentIdentifier` para
localizar o objeto correto no `ModelContext` de background (mesmo padrão
já usado no crescimento de pool, `TopicRepository.swift`).

## O que NÃO alterar nesta etapa

- **Não implementar `DeterministicCodeChecks`** nem a prioridade
  adaptativa baseada neles — isso é `PLAN_08`. Aqui a prioridade é sempre
  `.poolFill` fixa.
- **Não mudar o mecanismo de patch para "aplicar só na próxima abertura"**
  — o patch reativo ao vivo é a implementação PADRÃO deste plano; a
  mitigação de "aplicar só na próxima abertura" é um gatilho de reversão
  descrito em `SOLUTIONS_PLAN.md` §5.2, acionável só se teste de usuário
  mostrar desconforto real — não implementar preventivamente.
- **Não mudar o stream do MLX para chegar à UI** — F15 em
  `SOLUTIONS_PLAN.md`: "NÃO ALTERAR o stream do MLX" (é rascunho interno,
  consumido só internamente, por bom motivo).
- **Não tocar em `GenerationOrchestrator`** — a fila/prioridade já
  existente cobre exatamente o que este plano precisa (F7, "NÃO
  ALTERAR").

## Implementação detalhada

Ver `SOLUTIONS_PLAN.md` §5.2, passos 3-8 completos (fluxo da Estratégia
D), com a ressalva de que o passo 3 (checks determinísticos determinando
prioridade) fica simplificado NESTE plano para "prioridade sempre
`.poolFill`" — o gate condicional é `PLAN_08`. Ver também §22, seção
`StudyGenerator.swift` e `TopicRepository.swift`, para a lista de funções
novas (`upgradeCodeExampleViaMLX`) e alteradas (`runBackgroundUpgrade`,
`applyCodeExampleUpgrade`).

A comparação "resultado diferente do FM-only" (passo 8 do fluxo) pode ser
tão simples quanto `example.code != previousExample.code ||
example.walkthroughExplanations != previousExample.walkthroughExplanations`
— não precisa de comparação semântica sofisticada, só suficiente para
decidir se vale a pena persistir o patch (evita um `UPDATE` redundante
quando o upgrade não mudou nada).

## Instrumentação necessária

Usa `GenerationMetricsStore` de `PLAN_00`. Métrica nova relevante para
avaliar a própria Estratégia D (mencionada como evidência pendente em
`SOLUTIONS_PLAN.md` §5.2): registrar, por tópico, se o patch efetivamente
mudou o conteúdo (frequência de "o upgrade mudou algo" vs. "o FM sozinho
já estava certo") — pode ser um campo simples de log/contagem, não
precisa entrar no struct `GenerationMetrics` formal se for mais simples
como um contador à parte.

## Testes

Integration test (`PLAN_16`): Fase 2 atualiza o objeto EXISTENTE (mesmo
`persistentModelID`), não cria um segundo `StudyTopic`. Validação manual:
confirmar que o exemplo "melhora" na tela sem duplicar o `StudyTopic` —
abrir um tópico novo, observar o exemplo FM-only inicial, aguardar o
background completar, confirmar que o conteúdo muda in-place (SwiftUI
reativo via `@Query`/referência de objeto `@Model`).

## Benchmark, se aplicável

Medir (via `PLAN_00`) o tempo entre EVENT "tela aparece" (fim da Fase 1)
e o patch do passo 8 — evidência pendente listada em
`SOLUTIONS_PLAN.md` §5.2: se for muito longo, o valor perceptível do
upgrade cai (mas ainda vale a pena persistir, a próxima visita já vem
corrigida). Não é benchmark-gated no sentido de decidir SE implementar
(a decisão já foi tomada em D1) — é medição de caracterização, não um
gate de aprovação.

## Success Criteria

- O pipeline MLX→crítica→formatação roda em background para 100% dos
  tópicos novos, sem bloquear a tela.
- O patch atualiza o `StudyTopic` existente (mesmo `persistentModelID`)
  quando o resultado é válido e diferente do FM-only.
- Nenhum `StudyTopic` duplicado é criado.
- A tela reflete a atualização automaticamente (reatividade SwiftData),
  sem necessidade de recarregar a view.

## Rollback

Reverter só este plano mantém `PLAN_06` (ganho de latência sem o upgrade
— degrada qualidade de volta ao nível "FM-only sempre", pior que o
comportamento histórico em qualidade mas melhor em latência; é um estado
intermediário aceitável, explicitamente descrito como tal em
`SOLUTIONS_PLAN.md` §24, PR6c). Gatilho de reversão do PATCH reativo ao
vivo (não do plano inteiro): se teste de usuário mostrar que "o exemplo
de código muda sozinho na tela" é confuso/desconfortável, mudar para
aplicar o upgrade só na PRÓXIMA abertura da tela — mudança pequena e já
desenhada (`SOLUTIONS_PLAN.md` §5.2, gatilho de reversão).

## Resultado esperado

Estratégia D completa (D1): defesa contra hallucination preservada
(crítica MLX sempre roda), custo pago no relógio do processador, não no
do usuário.

## Commit boundary

Um commit cobrindo `upgradeCodeExampleViaMLX` + `runBackgroundUpgrade` +
`applyCodeExampleUpgrade` implementados de verdade. Compila, roda,
upgrade visível em teste manual sem duplicar `StudyTopic`.

Suggested commit: `feat: reintroduce MLX code example upgrade as background patch (Strategy D)`

## Próximo plano desbloqueado

`PLAN_08` (deterministic quality gate — precisa do upgrade existir para
ter algo a priorizar), `PLAN_14` (benchmark decisivo de modelo — precisa
da topologia TARGET completa), `PLAN_16` (integration tests).

## Claude Model Recommendation

Model:
Claude Opus 5 (`claude-opus-5`)

Reasoning level:
High

Why this model:
Envolve encadear MLX e Foundation Models em background com concorrência
via `GenerationOrchestrator`, aplicar patches reativos sobre objetos
SwiftData já persistidos (risco real de duplicar entidades ou de
condições de corrida se a leitura/escrita do `PersistentIdentifier` não
for cuidadosa), e preservar a reatividade de UI entre `ModelContext`s
diferentes — mesma classe de complexidade de `PLAN_06`. Erros aqui
seriam sutis (ex.: duplicar `StudyTopic`, ou o patch não disparar
re-render) e caros de depurar depois.
