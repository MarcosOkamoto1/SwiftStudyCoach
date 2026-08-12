# PLAN_01 — Testes unitários de funções puras

## Objetivo

Criar um target `SwiftStudyCoachTests` com `XCTest` cobrindo as funções
determinísticas e sem I/O já existentes no projeto: `QuestionValidator`
(sanitização/validação), `StudyGenerator.looksTruncated`, o parsing de
lote de `MLXService.generateQuestionDrafts` (`itemSeparator`), e o léxico
de `DocumentIndex` (tokens/overlap). Nenhuma lógica de produto muda.

## Por que esta etapa existe

`SOLUTIONS_PLAN.md` F19/§21: ausência de testes automatizados é risco de
confiabilidade (Medium), e o histórico do projeto já documenta bugs reais
que passaram (`Button` sem action, `navigationDestination` com valor,
`@StateObject` mal aplicado). §21 e §23 são explícitos: "os unit tests de
funções PURAS... podem e devem ser escritos a qualquer momento, inclusive
antes de tudo" — este plano não espera nenhuma outra mudança de
arquitetura para existir.

## Estado esperado antes de começar

`PLAN_00` pode ou não já ter sido implementado — este plano não depende
dele. Nenhuma mudança de comportamento em `QuestionValidator.swift`,
`StudyGenerator.swift`, `MLXService.swift` ou `DocumentIndex.swift` feita
por outro plano ainda (se `PLAN_00` já rodou, isso não afeta as funções
puras testadas aqui, que não foram tocadas por ele).

## Dependências

Nenhuma.

## Arquivos provavelmente afetados

- Novo target de teste: `SwiftStudyCoachTests` (adicionar ao
  `project.pbxproj` — confirmar se já existe um target de teste vazio
  antes de criar um novo, checar `project.pbxproj` primeiro)
- Novo: `SwiftStudyCoachTests/QuestionValidatorTests.swift`
- Novo: `SwiftStudyCoachTests/StudyGeneratorPureFunctionsTests.swift`
- Novo: `SwiftStudyCoachTests/DocumentIndexLexicalTests.swift`
- Novo: `SwiftStudyCoachTests/MLXServiceDraftParsingTests.swift`
- Possível mudança de visibilidade: `DocumentIndex.swift` (`tokens(of:)`,
  `lexicalOverlap` de `private` para `internal`, ver nota abaixo) —
  **mudança de visibilidade, não de comportamento**.

## Mudanças a implementar

### 1. Target de testes

Criar (ou confirmar existente) o target `SwiftStudyCoachTests` linkado ao
app principal via `@testable import SwiftStudyCoach`.

### 2. `QuestionValidatorTests.swift`

Casos cobrindo `sanitizeText`/`sanitize`/`isValid`
(`QuestionValidator.swift:29-128`): cada resíduo de formatação listado em
`residues`/`enumerationPatterns`, cada regra de validação (opções
duplicadas, índice fora do range, enunciado curto/cortado, fallback
genérico caindo em inválido).

### 3. `StudyGeneratorPureFunctionsTests.swift`, `DocumentIndexLexicalTests.swift`, `MLXServiceDraftParsingTests.swift`

`looksTruncated` (`StudyGenerator.swift:479-509`): balanceamento de
chaves/parênteses/colchetes, strings com caracteres de escape, finais
suspeitos. `DocumentIndex` léxico (`tokens(of:)`, `lexicalOverlap`):
stopwords filtradas corretamente, overlap calculado certo para casos
conhecidos — **mudar visibilidade de `private` para `internal`** é
necessário para testar sem `@testable` cobrir `private` (confirmar antes:
`@testable import` já expõe `internal`, não `private`; se o projeto
preferir manter `private`, usar `@testable` combinado com reflection não é
uma opção limpa — a mudança de visibilidade é a via recomendada, risco
baixo). `MLXService.generateQuestionDrafts` — parsing do split por
`itemSeparator` (`MLXService.swift:230-233`): N itens completos, itens
vazios/curtos descartados, separador ausente (fallback pra 1 item).

## O que NÃO alterar nesta etapa

- Nenhuma lógica das funções testadas — só visibilidade, quando
  estritamente necessário para testabilidade (`DocumentIndex` léxico).
- Não escrever testes para código que depende de modelo real (FM/MLX) ou
  de `ModelContext`/SwiftData — isso é escopo de `PLAN_16` (integration
  tests), não deste plano.
- Não testar `GenerationOrchestrator` (F7, `SOLUTIONS_PLAN.md` — nenhuma
  mudança planejada nele; se algum dia ganhar testes, é um plano futuro
  separado, condicional ao experimento de `PLAN_13`).

## Implementação detalhada

Ver `SOLUTIONS_PLAN.md` §21, subseção "Unit tests", para a lista completa
de casos e a justificativa de cada um. Usar fixtures reais dos bugs já
documentados no histórico do projeto (`PLANO_V5.md`) como casos de teste
de regressão, não só casos sintéticos genéricos.

## Instrumentação necessária

Nenhuma — este plano não precisa de `GenerationMetrics` (`PLAN_00`), pois
testa funções puras sem custo de medir performance.

## Testes

São o próprio conteúdo deste plano.

## Benchmark, se aplicável

N/A.

## Success Criteria

- `xcodebuild test` (ou equivalente via Xcode) roda o novo target e todos
  os testes passam.
- Cobertura mínima: pelo menos 1 caso de teste por bug histórico
  documentado (`Button` sem action, `navigationDestination` com valor,
  `@StateObject` mal aplicado) — mesmo que hoje esses casos não sejam
  verificados em nenhum lugar do código de produção ainda (isso só entra
  com `PLAN_08`), os TESTES já podem existir e falhar/documentar o
  comportamento esperado quando `DeterministicCodeChecks` for criado.
- App principal continua compilando sem nenhuma mudança de comportamento.

## Rollback

Remover o target de testes e os arquivos novos — zero risco pro app
principal (testes não são linkados no binário de produção). Se a mudança
de visibilidade em `DocumentIndex` causar qualquer problema (não deveria,
`internal` é estritamente mais permissivo que `private` dentro do mesmo
módulo), reverter só essas duas linhas.

## Resultado esperado

Cobertura de regressão para os bugs já documentados no histórico do
projeto, sem qualquer risco para o comportamento do app.

## Commit boundary

Um commit cobrindo o novo target + os 4 arquivos de teste. Compila,
`xcodebuild test` passa.

Suggested commit: `test: add unit tests for QuestionValidator, looksTruncated, DocumentIndex lexical helpers`

## Próximo plano desbloqueado

Nenhum plano depende estritamente deste (é paralelo a tudo), mas ele
reduz o risco de regressão de todos os planos seguintes que tocam as
mesmas funções (`PLAN_02` toca `formatHardQuestion`, `PLAN_08` toca
código que usa `looksTruncated`).

## Claude Model Recommendation

Model:
Claude Haiku 4.5 (`claude-haiku-4-5-20251001`)

Reasoning level:
Low

Why this model:
Escrever testes para funções já existentes, puras, bem entendidas e sem
efeitos colaterais é um trabalho mecânico e bem especificado — não há
decisão de design a tomar, os casos de teste já estão listados neste
plano e em `SOLUTIONS_PLAN.md` §21. É exatamente o perfil de tarefa onde
Haiku é suficiente e mais rápido/barato que um modelo mais forte.
