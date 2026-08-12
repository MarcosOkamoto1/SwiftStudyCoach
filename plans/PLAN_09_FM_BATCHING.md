# PLAN_09 — Batching de formatação Foundation Models (quiz difícil + análise de código)

## Objetivo

Reduzir o número de chamadas FM de background trocando N chamadas
individuais (1 por item) por 1 chamada por lote de drafts MLX (≤4 itens),
tanto para formatação de quiz difícil quanto para crítica+formatação de
análise de código.

## Por que esta etapa existe

`SOLUTIONS_PLAN.md` F3/D3/§6: formatação FM pós-lote MLX não é batched
hoje (`StudyGenerator.swift:548-552,739-741`) — N chamadas em vez de 1,
maior contribuinte individual para o total de ~23-24 chamadas FM por
tópico novo (§6.1). O mapeamento CURRENT→TARGET (§6.1) mostra redução de
~18 chamadas de background para ~8-9 só com este batching (quiz difícil:
6→2; análise de código: 12→4).

## Estado esperado antes de começar

`PLAN_06` implementado (recomendado, não estritamente bloqueante — este
plano toca funções diferentes de `StudyGenerator.swift`/
`TopicRepository.swift` das que `PLAN_06`/`PLAN_07` tocam, mas
sequenciar depois reduz conflito de merge em arquivos grandes e
compartilhados). `PLAN_02` (correção de `formatHardQuestion`) deve estar
implementado ANTES deste plano — este plano vai reescrever
`formatHardQuestion` para a versão em lote; corrigir o bug F8 na versão
individual primeiro evita herdá-lo para dentro do batching.

## Dependências

`PLAN_00` (medir taxa de rejeição antes/depois via `retryCount`).
Recomendado, não bloqueante: `PLAN_02`, `PLAN_06`.

## Arquivos provavelmente afetados

- `Services/StudyGenerator.swift` (`formatHardQuestion` →
  `formatHardQuestionsBatch`; `formatCodeAnalysisQuestion` →
  `formatCodeAnalysisBatch`; `critiqueCodeDraft` ganha
  `critiqueCodeDraftsBatch`)
- `Services/TopicRepository.swift` (`growDifficulty`/`growCodeAnalysis`
  passam a chamar as versões em lote)
- `Services/QuestionValidator.swift` — **sem mudança de lógica**, só
  confirmar que `processQuizBatch`/`processCodeAnalysisBatch`
  (`QuestionValidator.swift:136-183`) já operam por item dentro do lote
  retornado (já operam assim hoje).

## Mudanças a implementar

### 1. `formatHardQuestionsBatch(drafts:...) -> [QuizQuestion]`

Reutiliza o schema `QuizQuestionBatch` (`StudyModels.swift:75-77`, já
existe, já usado com sucesso por `generateQuizBatch` fácil/médio para 6
itens). Recebe N rascunhos MLX (texto livre, delimitados por
`MLXService.itemSeparator`) e devolve `QuizQuestionBatch` com N
`QuizQuestion`. Tamanho de lote: **≤4** (mesmo tamanho já usado no lado
MLX, `TopicRepository.swift:464`, `min(4, target - currentCount)`).
Orçamento de tokens: `220 * count + 150` (mesma fórmula já usada e
testada para lotes de `QuizQuestion` — para lote de 4: `1030`). Retry:
reaproveitar o padrão de "1 regeneração, senão descarta" já existente em
`QuestionValidator.processQuizBatch`.

### 2. `formatCodeAnalysisBatch(drafts:...) -> [CodeAnalysisQuestion]`

Reutiliza `CodeAnalysisBatch` (`StudyModels.swift:97-100`, já existe,
nunca usado). Tamanho de lote: ≤4. Orçamento: `850 * count + 100` (ponto
de partida, a calibrar por medição). Truncamento: aplicar
`looksTruncated` + retry-mais-curto já existente
(`StudyGenerator.swift:865-875`) por ITEM do lote retornado, não ao lote
inteiro — se 1 item truncar, retry só daquele item.

### 3. `critiqueCodeDraftsBatch(drafts:...) -> [String]`

**Primeira tentativa (recomendada)**: manter texto livre, pedir
explicitamente "separe cada crítica com `MLXService.itemSeparator`, na
mesma ordem dos rascunhos" — reaproveita o mesmo padrão de parsing já
usado em `MLXService.generateQuestionDrafts`
(`MLXService.swift:230-233`), sem exigir schema `@Generable` novo.
Orçamento: `350 * count` (linear, ponto de partida). Só criar um schema
estruturado (`@Generable struct CritiqueBatch { var critiques: [String] }`)
se a abordagem de texto livre com separador se mostrar frágil em teste —
não implementar o schema estruturado preventivamente.

## O que NÃO alterar nesta etapa

- **Não batchear a crítica + formatação do exemplo de código** (fluxo de
  `PLAN_07`) — são 1 item só por tópico, não há "lote" de exemplos de
  código; formatação depende do resultado da crítica (dependência
  sequencial real, não batchável). Fora de escopo por design, não por
  esquecimento.
- **Não batchear resumo nem feedback** — já são 1 chamada cada, sem lote
  a fazer.
- **Não mudar a granularidade de validação** — cada item do lote
  retornado continua passando por `QuestionValidator.isValid`
  individualmente, como já acontece hoje; batching na CHAMADA não muda a
  granularidade da VALIDAÇÃO.
- **Não deletar as funções individuais originais** — manter
  `formatHardQuestion`/`formatCodeAnalysisQuestion` (as versões corrigidas
  por `PLAN_02`) no código como fallback interno por pelo menos 1 ciclo de
  validação (nota explícita de `SOLUTIONS_PLAN.md` §27: "se um lote
  inteiro falhar de forma sistemática, cair para chamadas individuais é
  uma degradação graciosa mais barata que reverter o PR inteiro").

## Implementação detalhada

Ver `SOLUTIONS_PLAN.md` §6.1 (mapeamento CURRENT→TARGET completo, com os
números exatos de redução de chamadas), §6.2.1 (batching de quiz difícil,
detalhado: schema, tamanho, orçamento, retry, validação, fallback),
§6.2.2 (batching de análise de código, detalhado: schema reutilizado e
schema novo necessário para a crítica, tamanho, orçamento, risco de
truncamento maior por causa do `codeSnippet`, fallback), §6.3 (o que NÃO
deve ser batched, com a razão exata).

## Instrumentação necessária

Usa `GenerationMetricsStore` de `PLAN_00`. Comparar `retryCount` (já
capturado por `PLAN_00`) antes/depois do batching, por tipo de pergunta —
esta é a métrica que decide se o batching se mantém como está ou precisa
de ajuste (ver Rollback).

## Testes

Comparar taxa de rejeição do `QuestionValidator` antes/depois (via
`retryCount` em `GenerationMetrics`, de `PLAN_00`). Se `PLAN_01`/`PLAN_16`
já existirem, adicionar/confirmar unit tests de parsing do split por
`itemSeparator` para os novos formatos de resposta em lote (crítica em
texto livre com separador).

## Benchmark, se aplicável

**Benchmark-gated na CALIBRAÇÃO, não na decisão de fazer**: o tamanho de
lote (≤4) e a fórmula de orçamento são pontos de partida; a decisão de
manter/ajustar depende da taxa de rejeição medida (§6.2,
`SOLUTIONS_PLAN.md` §25). Rodar um tópico novo completo (background) e
comparar `retryCount` médio antes/depois via `GenerationMetrics`.

## Success Criteria

- Contagem de chamadas FM de background cai de ~18 para ~8-9 por tópico
  novo (verificável via `GenerationMetrics`, filtrando por `taskType` e
  contando registros).
- Taxa de rejeição do `QuestionValidator` (`retryCount` médio) não piora
  de forma significativa em relação à baseline pré-batching.
- Nenhuma regressão de qualidade perceptível no conteúdo gerado (inspeção
  manual de uma amostra).

## Rollback

Reverter o CHAMADOR para as versões individuais (mantidas no código, não
deletadas) — se a taxa de rejeição piorar de forma significativa (ex.
dobrar), primeiro tentar reduzir o batch size para 2 antes de abandonar a
ideia inteira (gatilho de reversão gradual, `SOLUTIONS_PLAN.md` D3).

## Resultado esperado

Redução de ~45-48% no total de chamadas FM por tópico novo (contagem
CONFIRMED por aritmética sobre o desenho; ganho de TEMPO correspondente
precisa de medição real via `PLAN_00`, porque cada chamada em lote é mais
cara individualmente mas paga menos overhead fixo de sessão).

## Commit boundary

Um commit cobrindo as 3 funções em lote + os chamadores atualizados em
`TopicRepository.swift`, com o resultado da comparação de `retryCount`
documentado no PR.

Suggested commit: `perf: batch Foundation Models formatting requests (hard quiz, code analysis)`

## Próximo plano desbloqueado

`PLAN_14` (benchmark decisivo de modelo — parte da topologia TARGET
completa).

## Claude Model Recommendation

Model:
Claude Sonnet 5 (`claude-sonnet-5`)

Reasoning level:
Medium

Why this model:
Reaproveita schemas e padrões de parsing já validados em produção
(`QuizQuestionBatch`, `itemSeparator`) — não é design do zero, mas exige
cuidado com orçamento de tokens, retry por item dentro de um lote, e
preservar o fallback individual como rede de segurança. Complexidade
moderada e bem delimitada, não justifica Opus; não é mecânico o
suficiente (múltiplos pontos de decisão sobre truncamento/retry) para
Haiku.
