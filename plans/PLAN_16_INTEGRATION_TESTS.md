# PLAN_16 — Testes de integração (Fase1/Fase2, dedup, top-up, invalidação)

## Objetivo

Criar testes de integração com `ModelContext`/`ModelContainer` do
SwiftData em memória (`inMemory: true`, mesmo padrão já usado nas
Previews, `ContentView.swift:158-162`), usando dublês (fakes) para
`StudyGenerator`, cobrindo os comportamentos introduzidos ou alterados
por `PLAN_06`, `PLAN_07` e `PLAN_10`.

## Por que esta etapa existe

`SOLUTIONS_PLAN.md` F19/§21, subseção "Integration tests": a mudança mais
arriscada do documento inteiro (persistência em 2 fases, patch reativo,
pool sob demanda) precisa de cobertura de regressão automatizada, não só
validação manual. O projeto já tem validações MANUAIS equivalentes
(`TopicRepositoryTestView.runRaceTest`,
`TopicRepositoryTestView.swift:265-293`) — este plano PORTA essa lógica
para `XCTestCase` automatizado, não a substitui.

## Estado esperado antes de começar

`PLAN_06`, `PLAN_07`, `PLAN_10` implementados — este plano testa o
comportamento resultante deles, não pode ser escrito de forma
significativa antes que esse comportamento exista.

## Dependências

`PLAN_06`, `PLAN_07`, `PLAN_10`.

## Arquivos provavelmente afetados

- Target de testes `SwiftStudyCoachTests` (criado em `PLAN_01`, se já
  existir — se não, criar aqui)
- Novo: `SwiftStudyCoachTests/TopicRepositoryTests.swift`
- Possível novo: dublê `FakeStudyGenerator` implementando a mesma
  interface que `StudyGenerator` expõe, registrando chamadas para
  assertions

## Mudanças a implementar

### 1. Cache HIT/MISS de `TopicRepository.fetchOrCreate`

Dado um `StudyTopic` pré-inserido com `sourceDatasetVersion`
batendo/não batendo com `DatasetVersion.current`, verificar que a geração
é ou não disparada (usando o `StudyGenerator` fake que registra
chamadas).

### 2. Dedup de geração concorrente

`inFlightGenerations` (`TopicRepository.swift:56,150-167`) — portar a
lógica já validada manualmente em
`TopicRepositoryTestView.runRaceTest` para um `XCTestCase`: disparar
`fetchOrCreate` 2x em paralelo com um `StudyGenerator` fake e contar
quantas vezes o fake foi chamado (deveria ser 1, não 2).

### 3. Geração parcial (Fase 1/Fase 2)

Verificar que depois da Fase 1 (`PLAN_06`), o `StudyTopic` já tem
`summary`/`quizPool` preenchidos mas `codeAnalysisPool` vazio (com
`generate-on-first-open`, `PLAN_10`); e que o patch de Fase 2
(`PLAN_07`) atualiza o objeto EXISTENTE (mesmo `persistentModelID`), não
cria um segundo `StudyTopic`.

### 4. Pool/top-up

Dado um pool com N itens abaixo do alvo, `replenishAfterSession` (com
generator fake) preenche até o alvo e para exatamente nele (não
ultrapassa).

### 5. Invalidação por `DatasetVersion`

Dado um `StudyTopic` com versão antiga, `fetchOrCreate` descarta e
regenera — reaproveita o cenário já exercitado manualmente pela seção 4
de `TopicRepositoryTestView` (`TopicRepositoryTestView.swift:226-237`).

## O que NÃO alterar nesta etapa

- **Não testar geração real de modelo (FM/MLX)** — todos os testes usam
  dublês/fakes; geração probabilística real é escopo do `MLX Model
  Benchmark Suite` (`PLAN_05`/`PLAN_14`), não de testes de integração
  determinísticos.
- **Não alterar `TopicRepository.swift`/`StudyGenerator.swift`** além do
  estritamente necessário para tornar as interfaces testáveis (ex.:
  injeção de dependência de um generator fake, se ainda não suportado) —
  este plano é sobre ADICIONAR testes, não sobre redesenhar as
  interfaces testadas.
- **Não remover a validação manual existente**
  (`TopicRepositoryTestView.runRaceTest` e cenários relacionados) — o
  teste automatizado é ADITIVO; a tela de debug continua existindo até
  `PLAN_17` decidir removê-la (e mesmo assim, a lógica testada
  manualmente já estará coberta pelo teste automatizado antes da
  remoção).

## Implementação detalhada

Ver `SOLUTIONS_PLAN.md` §21, subseção "Integration tests", para a lista
completa dos 5 cenários com a referência exata de código-fonte para cada
um. Usar `ModelContainer(for: StudyTopic.self, ..., configurations:
ModelConfiguration(isStoredInMemoryOnly: true))` como setup padrão de
cada teste (mesmo padrão das Previews).

## Instrumentação necessária

Nenhuma — testes de integração com dublês não exercitam
`GenerationMetrics` de forma significativa (não há chamada real de
modelo).

## Testes

São o próprio conteúdo deste plano.

## Benchmark, se aplicável

N/A.

## Success Criteria

- Todos os 5 cenários acima têm um `XCTestCase` correspondente, passando.
- `xcodebuild test` roda o target completo sem falha.
- O cenário de dedup confirma exatamente 1 chamada ao generator fake para
  2 chamadas paralelas de `fetchOrCreate`.
- O cenário de Fase 1/Fase 2 confirma que o patch atualiza o mesmo
  `persistentModelID`, nunca cria um `StudyTopic` duplicado.

## Rollback

Remover os arquivos de teste novos — zero risco para o app principal
(testes não são linkados no binário de produção).

## Resultado esperado

Cobertura de regressão automatizada para o comportamento mais arriscado
introduzido por este conjunto de planos (persistência em 2 fases, patch
reativo, dedup, pool sob demanda).

## Commit boundary

Um commit cobrindo `TopicRepositoryTests.swift` + qualquer dublê/fake
necessário.

Suggested commit: `test: add integration tests for phased persistence, dedup, top-up, invalidation`

## Próximo plano desbloqueado

Nenhum.

## Claude Model Recommendation

Model:
Claude Sonnet 5 (`claude-sonnet-5`)

Reasoning level:
Medium

Why this model:
Exige configurar corretamente `ModelContainer`/`ModelContext` em memória,
construir dublês fiéis à interface real de `StudyGenerator`, e reproduzir
cenários de concorrência (dedup) de forma determinística em teste — mais
complexo que testes unitários puros de `PLAN_01`, mas ainda um trabalho
de engenharia de teste bem delimitado, sem decisão de arquitetura de
produto.
