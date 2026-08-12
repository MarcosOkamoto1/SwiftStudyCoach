# PLAN_02 — Correção de `formatHardQuestion` (orçamento de token)

## Objetivo

Adicionar orçamento de token explícito e retry-curto em caso de
truncamento a `formatHardQuestion`, hoje a única função de formatação FM
do arquivo sem esse padrão — trazendo paridade com
`formatCodeAnalysisQuestion`, que já tem o padrão correto.

## Por que esta etapa existe

`SOLUTIONS_PLAN.md` F8 (CONFIRMED): `formatHardQuestion`
(`StudyGenerator.swift:687-693`) não passa nenhum orçamento de token
explícito para a chamada FM, ao contrário de todas as outras funções de
formatação do mesmo arquivo — inconsistência confirmada por leitura direta
do código, não hipótese. Classificado como **Safe Win** em
`SOLUTIONS_PLAN.md` §25: correção isolada, sem dependência de benchmark,
risco baixo.

## Estado esperado antes de começar

`StudyGenerator.swift` no estado auditado (`formatHardQuestion` nas linhas
687-693, sem orçamento explícito). Pode rodar antes ou depois de
`PLAN_00` — não há dependência real, mas medir o efeito da correção
(taxa de truncamento antes/depois) fica mais fácil se `PLAN_00` já
existir.

## Dependências

Nenhuma.

## Arquivos provavelmente afetados

- `Services/StudyGenerator.swift` (só a função `formatHardQuestion`,
  linhas 687-693, e o que for necessário para replicar o padrão de
  `formatCodeAnalysisQuestion`, linhas 860-875, referenciado como modelo)

## Mudanças a implementar

### 1. Adicionar orçamento de token explícito

`formatHardQuestion` passa a receber/usar um `maxTokens` explícito na
chamada FM, seguindo a MESMA fórmula já usada e testada em produção para
lotes de `QuizQuestion` (`StudyGenerator.swift:606`): `220 * count + 150`.
Como hoje `formatHardQuestion` processa 1 item por chamada (será
batchado só em `PLAN_09`), usar `count = 1`: `220 * 1 + 150 = 370`.

### 2. Adicionar detecção de truncamento + retry-curto

Reaproveitar `StudyGenerator.looksTruncated`
(`StudyGenerator.swift:479-509`, já existe, não duplicar) e o mesmo padrão
de retry-mais-curto já usado em `formatCodeAnalysisQuestion`
(`StudyGenerator.swift:865-875`) e em `formatCodeExample`
(`StudyGenerator.swift:357-365`) — replicar a mesma estrutura, não
inventar uma nova.

### 3. Validar paridade com a função irmã

Depois da mudança, `formatHardQuestion` e `formatCodeAnalysisQuestion`
devem ter a mesma estrutura de orçamento+retry — isso é o critério de
"correção", não um efeito colateral.

## O que NÃO alterar nesta etapa

- Não mudar a assinatura pública de `formatHardQuestion` de forma que
  quebre os chamadores existentes além do necessário para adicionar o
  orçamento.
- Não fazer batching aqui — isso é `PLAN_09`, que virá depois e vai
  reescrever esta função para `formatHardQuestionsBatch`. Este plano
  conserta o bug ISOLADO primeiro; o batching é uma mudança maior,
  separada, benchmark-gated.
- Não tocar em `formatCodeAnalysisQuestion` além de ler como referência —
  ela já está correta (F8 é só sobre `formatHardQuestion`).

## Implementação detalhada

Comparar lado a lado a implementação atual de `formatCodeAnalysisQuestion`
(`StudyGenerator.swift:767-883`, especialmente o trecho 860-875 que já
tem orçamento+retry) com `formatHardQuestion`
(`StudyGenerator.swift:641-700`, especialmente 687-693) e aplicar o MESMO
padrão estrutural a `formatHardQuestion`. Ver `SOLUTIONS_PLAN.md` §13,
bloco "hard quiz — formatação", para o valor exato de orçamento
(`220 * count + 150`) e a razão de reusar essa fórmula em vez de inventar
uma nova.

## Instrumentação necessária

Se `PLAN_00` já estiver implementado, este plano deveria automaticamente
passar a gerar métricas para `hardQuizFormat` sem trabalho adicional (o
`taskType` já existe no enum de `PLAN_00`). Se `PLAN_00` ainda não
existir, nenhuma instrumentação é necessária para este plano — a validação
é manual.

## Testes

Gerar quiz difícil para os 3 tópicos do dataset atual
(`PlaceholderDocs.swift`: NavigationStack, Property Wrappers,
async/await), inspecionar manualmente se algum resultado vem truncado. Se
`PLAN_01` já tiver criado `StudyGeneratorPureFunctionsTests` com testes de
`looksTruncated`, nenhum teste novo é necessário aqui (a função reutilizada
já está coberta).

## Benchmark, se aplicável

N/A — Safe Win, não depende de benchmark para ser feito. Se `PLAN_00` já
existir, pode-se opcionalmente comparar a taxa de truncamento antes/depois
via `retryCount` em `GenerationMetrics`, mas isso é validação extra, não
um gate de decisão.

## Success Criteria

- `formatHardQuestion` tem orçamento de token explícito e retry-curto,
  estruturalmente idêntico ao padrão de `formatCodeAnalysisQuestion`.
- Gerar quiz difícil para os 3 tópicos do dataset não produz nenhum
  resultado visivelmente truncado em teste manual.
- Nenhuma outra função foi alterada.

## Rollback

Reverter a função isolada (`formatHardQuestion`) para o estado anterior —
mudança contida a uma única função, sem dependência de outros arquivos.

## Resultado esperado

F8 corrigido: paridade de orçamento+retry entre `formatHardQuestion` e
`formatCodeAnalysisQuestion`.

## Commit boundary

Um commit cobrindo só `formatHardQuestion`. Compila, gera quiz difícil
sem truncamento visível em teste manual.

Suggested commit: `fix: add explicit token budget and truncation retry to formatHardQuestion`

## Próximo plano desbloqueado

Nenhum plano depende estritamente deste, mas `PLAN_09` (batching) vai
reescrever esta mesma função depois — corrigir o bug isolado primeiro
evita herdar o bug F8 para dentro da versão batched.

## Claude Model Recommendation

Model:
Claude Haiku 4.5 (`claude-haiku-4-5-20251001`)

Reasoning level:
Low

Why this model:
É replicar um padrão já implementado e correto na função irmã
(`formatCodeAnalysisQuestion`) para a função com o bug — mudança
localizada, mecânica, sem decisão de design (a fórmula e o padrão de
retry já estão especificados). Tarefa clássica de "conserto pontual bem
delimitado" onde Haiku é suficiente.
