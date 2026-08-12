# PLAN_00 — Instrumentação (GenerationMetrics)

## Objetivo

Criar uma coleta real de métricas de geração (tokens, TTFT, tokens/s,
tempo total, retries, estado de cache) para MLX e Foundation Models, hoje
inexistente além de `print` (F23) e de uma métrica de "chars/s" que não é
tokens/s real (F9). Este plano NÃO otimiza nada — é a ferramenta de
medição que todos os planos benchmark-gated seguintes (`PLAN_03`,
`PLAN_09`, `PLAN_11`, `PLAN_12`, `PLAN_13`, `PLAN_14`) dependem para
existir.

## Por que esta etapa existe

`SOLUTIONS_PLAN.md` F9/F23/§10: a instrumentação atual não permite
responder nenhuma pergunta de "melhorou ou piorou" com dado real. A API
real do `mlx-swift-examples` pinado já devolve tudo que precisamos
(`GenerateCompletionInfo` com `promptTokenCount`, `generationTokenCount`,
`promptTime`, `generateTime`, `tokensPerSecond`) — hoje descartada. Este
plano é classificado como **Safe Win** em `SOLUTIONS_PLAN.md` §25: não
depende de nenhuma medição prévia (é a própria medição) e não tem risco
comportamental (é coleta aditiva).

## Estado esperado antes de começar

Working tree igual ao auditado em `PLAN.md`/`SOLUTIONS_PLAN.md` — nenhuma
mudança de código feita ainda em nenhum dos arquivos abaixo. Nenhum outro
`PLAN_XX` deste diretório foi implementado ainda (este é o primeiro).

## Dependências

Nenhuma. Este é o plano raiz — todos os outros que envolvem medição ou
decisão benchmark-gated dependem deste.

## Arquivos provavelmente afetados

- Novo: `Services/GenerationMetrics.swift`
- `Services/MLXService.swift` (captura de `GenerateCompletionInfo` em
  `generate`, linhas atuais 316-342; instrumentação de carga em
  `performLoad`, linhas 129-167)
- `Services/StudyGenerator.swift` (instrumentar as chamadas FM — usar o
  padrão já existente em `TopicRepository.swift:262-266`, `Self.timed`,
  como referência de estilo)
- `Services/TopicRepository.swift` (`Self.timed` passa a também alimentar
  a store, além do `print` já existente)
- `Services/DocumentIndex.swift` (instrumentar `buildIndex`,
  linhas 71-103, e cache hit/miss)
- `Services/QuestionValidator.swift` (contagem de `retryCount` em
  `process*Batch`, linhas 136-183 — só leitura/contagem, sem mudar lógica)

## Mudanças a implementar

### 1. Criar `GenerationMetrics.swift`

Struct `Codable`/`Sendable` com os campos: `id`, `timestamp`, `engine`
(`foundationModels`/`mlx`), `taskType` (enum cobrindo cada tipo de
chamada: `summary`, `easyQuiz`, `mediumQuiz`, `hardQuizDraft`,
`hardQuizFormat`, `codeExampleDraft`, `codeExampleCritique`,
`codeExampleFormat`, `codeAnalysisDraft`, `codeAnalysisCritique`,
`codeAnalysisFormat`, `feedback`, `embeddingIndex`), `topic`, `modelID`,
`isColdStart`, `inputTokenCount: Int?`, `outputTokenCount: Int?`,
`timeToFirstTokenMs: Double?`, `decodeTimeMs: Double?`, `totalTimeMs:
Double`, `tokensPerSecond: Double?`, `retryCount: Int`, `ragContextChars:
Int`, `ragChunkCount: Int`, `batchSize: Int`, `promptCacheState`
(`hit`/`miss`/`notApplicable` — hoje sempre `notApplicable`, não há cache
ainda, ver `PLAN_11`), `memoryBeforeBytes: Int?`, `memoryAfterBytes: Int?`
(deixar `nil` por enquanto — `GPU.snapshot()` só entra em `PLAN_12`).
Ver `SOLUTIONS_PLAN.md` §10.1 para a definição completa do struct.

### 2. Criar `GenerationMetricsStore` (actor)

`actor GenerationMetricsStore` com `static let shared`, `record(_:)`
(acumula em `[GenerationMetrics]` E mantém o `print` com emoji já usado no
projeto, formato: `"📊 [\(taskType)/\(engine)] \(totalTimeMs)ms" +
tokensPerSecond?`), `snapshot() -> [GenerationMetrics]`, `summary() ->
[TaskType: (count, avgMs, p50Ms)]` (agregação simples, sem dependência
nova), `exportJSON() -> Data` (usa `Codable`, escreve em
`FileManager.default.urls(for: .documentDirectory,...)`, mesmo padrão de
`DocumentIndex.cacheURL`, `DocumentIndex.swift:278-285`). Ver
`SOLUTIONS_PLAN.md` §10.3/§10.4.

### 3. Instrumentar os pontos reais de geração

Em `MLXService.generate`: trocar o consumo do stream para capturar o caso
`.info(let info)` de `Generation` (API real confirmada,
`Evaluate.swift`), extraindo `promptTokenCount`, `generationTokenCount`,
`promptTime`, `generateTime`, `tokensPerSecond` — **isso substitui
diretamente a métrica de "chars/s" (F9)**, sem precisar calcular nada na
mão. Em `MLXService.performLoad`: registrar `isColdStart`/tempo de carga
como métrica (já é logado em texto — só precisa também virar um
`GenerationMetrics`). Em cada função de `StudyGenerator` que chama FM:
envolver a chamada com um cronômetro (mesmo padrão de
`TopicRepository.timed`) e registrar `totalTimeMs`. **Tokens de
entrada/saída do FM**: `Needs runtime measurement` se a API pública do
`FoundationModels` não expuser contagem — nesse caso, usar o tokenizer já
disponível via `Tokenizers` (dependência já presente via
`swift-transformers`, usada pelo MLX) só para fins de diagnóstico
aproximado, deixando claro no código (comentário) que é uma aproximação,
não um valor oficial do framework. Em `DocumentIndex.buildIndex`:
registrar `embeddingIndex` com cache hit/miss (já logado em texto). Em
`QuestionValidator.process*Batch`: contar `retryCount` sem mudar a lógica
de validação existente.

## O que NÃO alterar nesta etapa

- Nenhuma lógica de geração, batching, prioridade, cache ou pipeline —
  este plano é estritamente aditivo/observacional.
- Não remover nenhum `print` existente — a store é aditiva ao console, não
  substitui o hábito já estabelecido no projeto (`SOLUTIONS_PLAN.md`
  §10.3).
- Não construir nenhum dashboard/visualização além da exportação JSON —
  complexidade desproporcional ao objetivo (§10.4).
- Não mudar `QuestionValidator`'s lógica de validação/regeneração — só
  contar quantas vezes ela roda.

## Implementação detalhada

Ver `SOLUTIONS_PLAN.md` §10.1 (struct completo), §10.2 (tabela de pontos
de instrumentação com arquivo:linha exatos), §10.3 (API da store),
§10.4 (exportação). Não reimplementar do zero — as assinaturas
aproximadas já estão especificadas lá; este plano é sobre EXECUTAR essa
especificação, não redesenhá-la.

Pontos de instrumentação (resumo, detalhe em §10.2 do documento-fonte):

| Ponto | Arquivo:linha atual | Captura |
|---|---|---|
| `MLXService.generate` | `MLXService.swift:316-342` | `GenerateCompletionInfo` real via `.info` do stream |
| `MLXService.loadModel`/`performLoad` | `MLXService.swift:129-167` | `isColdStart`, tempo de carga |
| Chamadas FM em `StudyGenerator` | vários | `totalTimeMs`, aproximação de tokens se necessário |
| `DocumentIndex.buildIndex` | `DocumentIndex.swift:71-103` | cache hit/miss |
| `StudyGenerator.retrieveContext` | `StudyGenerator.swift:89-96` | `ragChunkCount`, `ragContextChars` |
| `QuestionValidator.process*Batch` | `QuestionValidator.swift:136-183` | `retryCount` |

## Instrumentação necessária

É o próprio conteúdo deste plano — não há uma etapa de instrumentação
separada de si mesma.

## Testes

Sem `XCTest` novo neste plano (a store em si é simples o suficiente para
validar manualmente; testá-la formalmente, se desejado, cabe no escopo de
`PLAN_01`/`PLAN_16` como um extra, não é obrigatório aqui). Validação
manual: rodar um tópico novo end-to-end no simulador/dispositivo, abrir a
exportação JSON (via botão temporário em `TopicRepositoryTestView` ou
chamando `exportJSON()` num breakpoint/print), e confirmar que os valores
são plausíveis — não-zero, não-`NaN`, `tokensPerSecond` na faixa esperada
para um modelo 7B 4-bit rodando localmente (ordem de grandeza, não um
valor exato).

## Benchmark, se aplicável

N/A — este plano é a ferramenta de benchmark, não um benchmark em si.

## Success Criteria

- `GenerationMetricsStore.shared.snapshot()` depois de gerar 1 tópico novo
  completo (síncrono + background) contém registros para cada `taskType`
  esperado, todos com `totalTimeMs > 0`.
- Para chamadas MLX: `tokensPerSecond`, `inputTokenCount`,
  `outputTokenCount` não são `nil` e não são `NaN`/`0` de forma
  suspeita (uma chamada de 300 tokens de saída não pode reportar
  `outputTokenCount: 3`).
- O app compila e roda sem regressão de comportamento visível — nenhuma
  tela deveria se comportar diferente depois deste plano.

## Rollback

Reverter o arquivo novo (`GenerationMetrics.swift`) e as poucas linhas
aditivas nos arquivos existentes. Risco de rollback: zero — nenhuma
lógica de produto foi alterada, só coleta de dados adicionada.

## Resultado esperado

Tokens/TTFT/tokens-por-segundo reais disponíveis para todas as decisões
benchmark-gated seguintes. F9 corrigido (métrica real substitui
"chars/s"). F23 corrigido (instrumentação deixa de ser só `print`).

## Commit boundary

Um commit único cobrindo o novo arquivo + instrumentação aditiva em todos
os pontos da tabela acima. Compila, roda, nenhuma tela muda de
comportamento.

Suggested commit: `feat: add GenerationMetrics instrumentation (tokens, TTFT, tokens/s)`

## Próximo plano desbloqueado

`PLAN_03` (chat template — precisa de `promptTokenCount` real para o
teste de equivalência), `PLAN_04`, `PLAN_05`, `PLAN_06`, `PLAN_09`,
`PLAN_11`, `PLAN_12`, `PLAN_13`, `PLAN_14` — todos os planos que medem
algo antes/depois dependem deste.

## Claude Model Recommendation

Model:
Claude Sonnet 5 (`claude-sonnet-5`)

Reasoning level:
Medium

Why this model:
É implementação padrão em Swift/SwiftUI espalhada por várias camadas
(novo actor, novo struct, instrumentação aditiva em 5+ arquivos), mas a
arquitetura já está inteiramente especificada em `SOLUTIONS_PLAN.md` §10
— não há decisão de design a tomar, só execução cuidadosa. Exige entender
a API real de `AsyncStream<Generation>`/`GenerateCompletionInfo` do
`MLXLMCommon` (não trivial o suficiente para Haiku, que erraria a
integração com o stream), mas não envolve concorrência nova, mudança de
arquitetura, nem lifecycle complexo — não justifica Opus.
