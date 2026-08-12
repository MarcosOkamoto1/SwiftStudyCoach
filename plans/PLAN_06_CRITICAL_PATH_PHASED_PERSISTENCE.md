# PLAN_06 — Tirar MLX do caminho síncrono + persistência em Fase 1/Fase 2 + GenerationStage

## Objetivo

A maior mudança arquitetural do documento inteiro (D1 parte 1, D9,
`SOLUTIONS_PLAN.md` PR6a+PR6b tratados aqui como **uma única unidade de
entrega**, por recomendação explícita do próprio §28 do documento-fonte).
Duas mudanças coesas e interdependentes:

1. O exemplo de código deixa de forçar carga+geração MLX (7B) no caminho
   síncrono de abertura de um tópico novo — passa a usar só Foundation
   Models (`generateCodeExampleFM`, promovendo o que hoje é o fallback
   `generateCodeExampleFromScratch`).
2. `TopicRepository.generateAndPersist` deixa de ser uma escrita atômica
   única — passa a persistir em duas fases: Fase 1 (mínimo mostrável:
   resumo, quiz fácil/média, exemplo de código FM-only) e Fase 2
   (estrutura pronta para receber patches em background — o CONTEÚDO da
   Fase 2, ou seja, o upgrade MLX de verdade, é `PLAN_07`; aqui a Fase 2
   fica como esqueleto/no-op).

## Por que esta etapa existe

`SOLUTIONS_PLAN.md` F1 (Very High impact, confirmado): todo tópico novo
força carga do MLX 7B + 2-3 chamadas FM sequenciais, bloqueante
(`StudyGenerator.swift:239-280`, `TopicRepository.swift:208-210`). É o
gargalo #1 do documento inteiro, com maior ganho de latência isolado
(`SOLUTIONS_PLAN.md` §28, Final Priority Matrix, linha 5: "Very High"
performance, único item marcado assim). A Estratégia D (§5.2, escolhida
sobre A/B/C) exige que o exemplo FM-only tenha ONDE persistir
incrementalmente — por isso PR6a (mover MLX) e PR6b (persistência em 2
fases) são tratados como uma unidade só, seguindo a nota explícita do
próprio §28: "PR 6b precisa ser implementado ANTES ou JUNTO de PR 6a,
porque a Fase 1 de PR 6a precisa de um lugar pra persistir
incrementalmente... recomendo tratar PR 6a+6b como uma unidade de entrega
única na prática."

## Estado esperado antes de começar

Recomendado (não bloqueante tecnicamente, mas reduz risco de conflito de
merge): `PLAN_00`, `PLAN_02`, `PLAN_03`, `PLAN_04` já implementados —
este plano toca os MESMOS arquivos centrais (`StudyGenerator.swift`,
`TopicRepository.swift`) que esses planos menores já tocaram, então
implementá-los primeiro reduz a chance de resolver conflitos grandes no
meio de uma mudança arquitetural. `PLAN_00` é dependência real (não só
recomendada) porque este plano precisa medir o ganho de latência
antes/depois.

## Dependências

`PLAN_00` (dependência real — medir latência de abertura antes/depois é
o próprio success criteria deste plano). Sequenciamento recomendado
(não bloqueante): `PLAN_02`, `PLAN_03`, `PLAN_04`.

## Arquivos provavelmente afetados

- `Services/StudyGenerator.swift` (`generateCodeExample`,
  linhas 239-280, split em duas funções; `generateCodeExampleFromScratch`,
  linhas 421-475, promovida)
- `Services/TopicRepository.swift` (`generateAndPersist`,
  linhas 150-258, split em Fase 1/Fase 2; `async let exampleTask`,
  linhas 208-210, removido do formato atual)
- `Views/TopicStudyView.swift` (`load()`, linhas 116-133; `loadingState`,
  linhas 77-98 — passa a consumir `GenerationStage`)
- `Models/Persistence.swift` — **nenhuma mudança de schema** (os campos
  `codeExample`/`walkthroughSnippets`/`walkthroughExplanations` já
  existem; a Fase 2 só fará `UPDATE` neles em `PLAN_07`)

## Mudanças a implementar

### 1. Dividir `generateCodeExample` em `generateCodeExampleFM` (síncrono) e um stub para `upgradeCodeExampleViaMLX` (implementado de verdade só em `PLAN_07`)

`generateCodeExampleFromScratch` (`StudyGenerator.swift:421-475`), hoje
tratada como fallback raro, é promovida a caminho PRINCIPAL, renomeada
para algo como `generateCodeExampleFM(topic:context:)` — chamada
diretamente e SEMPRE (não como fallback condicional) na Fase 1. O
pipeline MLX→crítica→formatação (hoje `generateCodeExample`,
`StudyGenerator.swift:239-280`) é temporariamente DESABILITADO como
caminho de geração de exemplo — vira só a base de uma função
`upgradeCodeExampleViaMLX` que, NESTE plano, pode ser um stub/no-op
(retorna `nil`/não faz nada) — a implementação real do upgrade é
`PLAN_07`. Isso é intencional: medir o ganho de latência de SÓ tirar o
MLX do caminho síncrono, isoladamente, antes de reintroduzir o upgrade em
background.

### 2. `TopicRepository.generateAndPersist` → Fase 1 / Fase 2

```swift
// assinaturas aproximadas, ver SOLUTIONS_PLAN.md §16.2
private func generateAndPersistPhase1(topic: String) async throws -> StudyTopic
private func runBackgroundUpgrade(topicID: PersistentIdentifier, ...) async
func applyCodeExampleUpgrade(topicID: PersistentIdentifier, example: ExplainedCodeExample) async
```

Fase 1 (síncrona, bloqueia a tela): resumo (1 chamada FM), quiz fácil
(1 chamada FM), quiz médio (1 chamada FM), exemplo de código FM-only
(1 chamada FM) — 4 chamadas FM total, ZERO MLX, ZERO carga de modelo.
Persiste um `StudyTopic` válido e retorna. Fase 2 (background, disparada
logo após a Fase 1 retornar, NUNCA aguardada pelo caminho síncrono): NESTE
plano, pode ser um esqueleto que só dispara o crescimento de pool já
existente (quiz difícil, análise de código — ainda não batched, isso é
`PLAN_09`/`PLAN_10`) — o upgrade de exemplo de código via MLX
(`applyCodeExampleUpgrade`) é implementado de verdade em `PLAN_07`; aqui
o método pode existir com assinatura completa mas corpo vazio/no-op,
documentado com um comentário claro apontando para `PLAN_07`.

### 3. `GenerationStage` observável + `TopicStudyView` consumindo

```swift
// ver SOLUTIONS_PLAN.md §16.1 para a lista completa de casos
enum GenerationStage: Equatable {
    case idle
    case indexing
    case generatingSummary
    case generatingQuizEasy
    case generatingQuizMedium
    case generatingCodeExample
    case ready                       // Fase 1 persistida, tela mostrável
    case upgradingCodeExample        // background, stub até PLAN_07
    case generatingHardQuiz
    case generatingCodeAnalysis
    case backgroundComplete
    case failed(step: String)
}
```

`TopicStudyView.loadingState` (`TopicStudyView.swift:77-98`) troca o
texto fixo "Gerando conteúdo de '\(topicName)'..." por um texto derivado
de `GenerationStage`. Tratamento de erro parcial: erro na Fase 1 continua
caindo no `errorState` atual (não muda — não há conteúdo mostrável ainda);
erro na Fase 2 (background) NÃO deve derrubar a tela — só atualiza
`GenerationStage` para `.failed(step:)` sem limpar `topic` (ver
`SOLUTIONS_PLAN.md` §16.5).

## O que NÃO alterar nesta etapa

- **Não implementar o upgrade MLX de verdade** (`upgradeCodeExampleViaMLX`
  com corpo funcional, patch reativo via `applyCodeExampleUpgrade`) — isso
  é `PLAN_07`, deliberadamente separado. Este plano deixa o pipeline de
  crítica MLX temporariamente inoperante (não deletado — o código de
  `generateCodeExample` original é preservado/renomeado, não descartado),
  é um passo intermediário deliberado (ver `SOLUTIONS_PLAN.md` §24, nota
  de PR6a: "MLX temporariamente DESABILITADO pro exemplo de código — um
  passo intermediário deliberado").
- **Não implementar `DeterministicCodeChecks`** — isso é `PLAN_08`, que
  depende de `PLAN_07` (o gate de prioridade só faz sentido depois que
  existe um upgrade de verdade para priorizar).
- **Não implementar batching de formatação FM** (quiz difícil, análise de
  código) — isso é `PLAN_09`, independente deste em termos de código
  (funções diferentes), mas sequenciado depois para evitar conflito de
  merge.
- **Não mudar `codeAnalysisPool` para geração sob demanda** — isso é
  `PLAN_10`.
- **Não mudar schema do SwiftData** — `StudyTopic` já tem os campos
  necessários; Fase 2 só fará `UPDATE`, não requer migração.
- **Não introduzir skeleton screens/placeholders de layout** — decisão
  explícita de `SOLUTIONS_PLAN.md` §16.3: a Fase 1 já é rápida o
  suficiente (4 chamadas FM sequenciais, sem MLX) para ser tratada como
  um loading único, não progressivo por dentro de si mesma.

## Implementação detalhada

Ver `SOLUTIONS_PLAN.md` §5.2 (fluxo completo da Estratégia D, passos
1-9 — este plano implementa os passos 1-2 e o esqueleto do passo 9 parcial
[quiz/análise ainda não batched], passos 3-8 ficam para `PLAN_07`/`PLAN_08`),
§16.1 (`GenerationStage` completo), §16.2 (persistência em 2 fases,
assinaturas aproximadas), §16.3 (por que não skeleton), §16.4
(disponibilidade parcial — botões desabilitados com opacidade reduzida já
existem, `TopicStudyView.swift:294-304`, só o texto precisa acompanhar
`GenerationStage`), §16.5 (tratamento de erro parcial), §16.6 (nota sobre
UX de patch reativo — não se aplica ainda neste plano, relevante só a
partir de `PLAN_07`), §16.7 (resumo de mudanças por arquivo), §22 (seção
`TopicRepository.swift` e `StudyGenerator.swift`, File-by-File Changes).

A UI já observa `StudyTopic` via SwiftData (`@Query`,
`StudyHomeView.swift:19`) — o mesmo mecanismo reativo cobre um
`StudyTopic` sendo editado por um `ModelContext` de background, desde que
a View leia as propriedades diretamente (`TopicStudyView` já guarda
`@State private var topic: StudyTopic?`, uma REFERÊNCIA a um objeto
`@Model` — `TopicStudyView.swift:36`). Este mecanismo já está validado
pelo padrão de crescimento de pool existente
(`TopicRepositoryTestView.swift:21-23`).

## Instrumentação necessária

Usa `GenerationMetricsStore` de `PLAN_00`. Medir especificamente: tempo
total da Fase 1 (deveria cair de forma visível vs. o fluxo atual, que
inclui carga+geração MLX bloqueante) e confirmar que ZERO chamadas MLX
acontecem no caminho síncrono (verificável filtrando `GenerationMetrics`
por `engine == .mlx` e `taskType` associado à abertura de tela — não
deveria haver nenhum registro MLX até a tela já estar em `.ready`).

## Testes

Integration test (`PLAN_16`, mas pode ser adiantado aqui se conveniente):
depois da Fase 1, o `StudyTopic` já tem `summary`/`quizPool` preenchidos;
verificar que o patch de Fase 2 (quando `PLAN_07` implementar de verdade)
vai atualizar o objeto EXISTENTE (mesmo `persistentModelID`), não criar um
segundo `StudyTopic` — este plano deve garantir que a estrutura permite
isso, mesmo que o teste completo só faça sentido depois de `PLAN_07`.
Validação manual: abrir tópico novo, confirmar que o texto de loading
muda por etapa (`GenerationStage`), confirmar visualmente que a tela
aparece SEM esperar por MLX.

## Benchmark, se aplicável

Medir (via `PLAN_00`) o tempo de abertura de tópico novo antes/depois —
deveria cair de forma visível. Não é benchmark-gated no sentido de "só
fazer se o benchmark aprovar" — `SOLUTIONS_PLAN.md` §25 classifica esta
mudança como **Safe Win**: "o raciocínio (não fazer o usuário esperar por
um modelo de 7B quando existe um caminho FM-only que já funciona) não
depende de benchmark pra ser válido; o benchmark só quantifica o ganho,
não decide SE fazer."

## Success Criteria

- Abertura de tópico novo não dispara nenhuma chamada MLX no caminho
  síncrono (verificável via `GenerationMetrics`).
- Tempo de abertura de tópico novo cai de forma mensurável e visível em
  relação ao baseline medido antes deste plano.
- `GenerationStage` muda de texto visivelmente durante a Fase 1.
- Erro na Fase 1 continua caindo em `errorState` normalmente; a estrutura
  para erro de Fase 2 não derrubar a tela está implementada (mesmo que o
  conteúdo real de Fase 2 ainda seja um stub).
- Nenhum `StudyTopic` duplicado é criado.

## Rollback

Reverter para chamar a versão MLX→crítica→formatação síncrona de novo
(comportamento atual) — o código antigo de `generateCodeExample` é
preservado/renomeado, não deletado, facilitando a reversão. Se a
persistência em 2 fases causar qualquer problema de reatividade de UI,
reverter para persistência atômica única (código anterior também
preservado).

## Resultado esperado

Maior ganho de latência do documento inteiro: usuário nunca mais espera
diretamente pela carga+geração MLX ao abrir um tópico novo. Estrutura de
persistência incremental pronta para receber o upgrade real em `PLAN_07`.
Percepção de progresso melhora imediatamente (`GenerationStage` visível).

## Commit boundary

Recomenda-se DOIS commits dentro do mesmo PR/branch (mantendo os diffs
revisáveis, mas como unidade de entrega única, conforme `SOLUTIONS_PLAN.md`
§28): (1) split de `generateCodeExample` + Fase 1 síncrona; (2)
persistência em 2 fases + `GenerationStage` + `TopicStudyView` consumindo.
Ambos precisam estar mesclados juntos antes de considerar este plano
concluído — a Fase 1 sozinha, sem a estrutura de 2 fases, não tem onde
persistir incrementalmente.

Suggested commit: `perf: move code example generation off MLX sync path, add phased persistence + GenerationStage`

## Próximo plano desbloqueado

`PLAN_07` (upgrade MLX em background — precisa da Fase 1/2 existir),
`PLAN_09` (batching, recomendado depois para reduzir conflito),
`PLAN_10` (pool sob demanda — precisa de `TopicRepository` já
restruturado), `PLAN_11` (KV cache — só faz sentido depois que MLX é
background-only), `PLAN_14` (benchmark decisivo de modelo — precisa da
topologia TARGET), `PLAN_16` (integration tests da Fase1/Fase2).

## Claude Model Recommendation

Model:
Claude Opus 5 (`claude-opus-5`)

Reasoning level:
High

Why this model:
É a mudança de maior risco e maior blast radius de todo o documento —
reestruturação de concorrência/async (`async let` removido, novo modelo
de persistência em 2 fases), reatividade de SwiftData entre
`ModelContext`s, e um arquivo central de 917 linhas
(`StudyGenerator.swift`) com muitas dependências. Um erro aqui contamina
todos os planos seguintes que dependem desta estrutura (07, 09, 10, 11,
14, 16). A revisão de "estado esperado antes/depois", concorrência, e
lifecycle de UI reativa exige o nível de raciocínio mais forte disponível
— não é uma tarefa onde economizar modelo vale o risco.
