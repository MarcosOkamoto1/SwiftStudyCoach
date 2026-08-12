# PLAN.md — Auditoria técnica do SwiftStudyCoach

> Metodologia: li o código-fonte completo (24 arquivos Swift, ~5.650 linhas), o
> histórico de commits (`git log`), o estado atual não commitado (`git diff`),
> o `Package.resolved`/`project.pbxproj` (dependências e deployment target), e
> os planos anteriores (`PLANOS_DE_MELHORIA.md`, `PLANO_V2/V3/V5.md`,
> `GUIA_APRESENTACAO.md`) para não repetir diagnóstico já feito nem propor de
> novo algo que já foi implementado. Nenhum arquivo do projeto foi alterado.
>
> Toda afirmação abaixo é classificada como **CONFIRMED** (o código mostra o
> fato diretamente), **HIGHLY LIKELY** (evidência forte, mas sem medição em
> runtime) ou **HYPOTHESIS** (precisa de benchmark/profiling — a seção
> específica diz exatamente como medir). Números de token/tempo que aparecem
> no código (orçamentos, `maxTokens`) são citados como **configurado**, não
> como "gasto real" — gasto real está marcado explicitamente como `Needs
> runtime measurement`.
>
> Um fato importante descoberto **antes** de qualquer outra coisa: boa parte
> dos itens dos planos anteriores (`PLANOS_DE_MELHORIA.md`, `PLANO_V2.md`,
> `PLANO_V3.md`) **já foi implementada** no estado atual do working tree
> (índice RAG singleton com cache em disco, busca híbrida, `QuestionValidator`,
> `GenerationOrchestrator` com filas por motor, geração em paralelo FM/MLX,
> top-up pós-sessão). Este documento audita o código **como ele está agora**,
> não os planos antigos — e identifica o que continua lento **apesar** dessas
> melhorias, incluindo pelo menos uma mudança recente (o passo a passo de
> "crítica + reformatação" de 2 passadas) que resolveu um problema de
> qualidade real mas que é, pela minha leitura, a maior fonte de latência do
> app hoje.

---

## 0. Contexto do projeto

- App **macOS-only** (SwiftUI + SwiftData): `project.pbxproj` define
  `SDKROOT = macosx` e `MACOSX_DEPLOYMENT_TARGET = 26.2`; não há
  `IPHONEOS_DEPLOYMENT_TARGET`. Trechos como
  `TopicStudyView.swift:66-68` (`#if os(macOS)` no tamanho do sheet)
  confirmam isso.
- Dependências (`Package.resolved`): `mlx-swift 0.29.1`,
  `mlx-swift-examples 2.29.1` (MLXLLM/MLXLMCommon), `NaturalLanguageEmbeddings
  1.0.1` (wrapper do `NLContextualEmbedding` nativo da Apple), `swift-transformers
  1.0.0`, `swift-jinja 2.4.2`.
- Modelo MLX atual: **`mlx-community/Qwen2.5-Coder-7B-Instruct-4bit`**
  (`MLXService.swift:44`), ~4,3 GB (`MLXService.swift:49`). O comentário de
  cabeçalho do arquivo (`MLXService.swift:7-15`) documenta que um modelo MoE
  de 30B (`Qwen3-Coder-30B-A3B-4bit`, 17,2 GB) foi testado e **revertido**
  porque estourava o limite de memória wired da GPU do macOS (~75% da RAM
  unificada) e derrubava os tokens/s por swap — decisão já tomada com
  evidência real, não preciso reabrir essa discussão.
- Dataset RAG atual (`PlaceholderDocs.swift:60-273`): **apenas 3 tópicos**
  (NavigationStack, Property Wrappers, async/await), 2-3 chunks de ~200-250
  palavras cada → **8 chunks no total**. Isso é importante: quase todas as
  preocupações clássicas de "RAG lento/caro" (busca O(n) grande, custo de
  reindexação, redundância entre muitos chunks) **não se aplicam hoje**, na
  escala atual. Isso não invalida a arquitetura, mas muda a prioridade: o
  gargalo real não está no retrieval, está na geração.
- Working tree tem mudanças **não commitadas** (`git status`/`git diff
  --stat`) em `MLXService.swift`, `TopicRepository.swift`,
  `GenerationOrchestrator.swift`, `Persistence.swift`, `ModelDownloadView.swift`,
  `TopicStudyView.swift` — é exatamente o "Plano V6" citado nos comentários
  do código. Auditei o estado **do disco** (o que roda de fato), não o
  último commit.

---

## 1. Current Architecture

### 1.1 Fluxo real (seguido pelo código, não pelos nomes de arquivo)

```
StudyHomeView (lista tópicos curados = PlaceholderDocs.topicsByBlock())
        │  tap num tópico
        ▼
TopicStudyView(topicName:).task { load() }
        │
        ├─ 1. DocumentIndex.shared.ensureReady()          [singleton, cache em disco]
        │        └─ cache HIT (hash do dataset bate) → carrega JSON, pronto em ms
        │        └─ cache MISS → embeda os 8 chunks (sequencial) via NLContextualEmbedding,
        │                        salva cache em Application Support
        │
        ├─ 2. StudyGenerator(documentIndex) + TopicRepository(modelContext, generator)
        │
        └─ 3. TopicRepository.fetchOrCreate(topic:)
                 │
                 ├─ SwiftData fetch por nome
                 │     ├─ cache HIT (mesma DatasetVersion, pool não vazio)
                 │     │      → retorna na hora, ZERO chamada a modelo
                 │     │      → (se pool incompleto, retoma crescimento em BG)
                 │     ├─ cache STALE (DatasetVersion mudou) → apaga e regenera
                 │     └─ cache MISS → gera do zero
                 │
                 └─ generateAndPersist(topic:)  [1ª visita — CAMINHO BLOQUEANTE]
                        │
                        │  context = retrieveContext(topic, topK:3)   ← 1x, reusado
                        │  codeContext = retrieveContext(topic, topK:2)
                        │
                        ├─ async let exampleTask = generateCodeExample(...)  ── trilha MLX
                        │        │   1. MLXService.loadModel() [download/carga se preciso]
                        │        │   2. MLX: gera 1 rascunho (código+explicação texto puro)
                        │        │   3. FM: critiqueCodeDraft (crítica técnica, texto livre)
                        │        │   4. FM: formatCodeExample (reformata pro schema,
                        │        │      aplicando a crítica; pode ter +1 retry)
                        │
                        ├─ await generateSummary(...)                  ── FM (schema TopicSummary)
                        ├─ await generateQuizBatch(.easy, count:6)      ── FM (schema, 1 call batched)
                        ├─ await generateQuizBatch(.medium, count:6)    ── FM (schema, 1 call batched)
                        │        (cada lote passa por QuestionValidator: sanitiza,
                        │         valida, 1 regeneração se inválido, senão descarta)
                        │
                        ├─ await exampleTask   ← junta a trilha MLX aqui
                        │
                        ├─ persiste StudyTopic no SwiftData (tela já pode aparecer)
                        │
                        └─ startBackgroundGrowthIfNeeded(...)   ── Task.detached, NÃO bloqueia a UI
                                 │
                                 ├─ Trilha A (FM): cresce fácil/média até 6/6
                                 │     (normalmente NO-OP: já vieram 6/6 no caminho síncrono)
                                 │
                                 └─ Trilha B (MLX): loadModel() [dedup, já carregado]
                                       → cresce DIFÍCIL até 6 (lotes de MLX + N formatações FM,
                                         uma por item — NÃO batched)
                                       → cresce ANÁLISE DE CÓDIGO até 6 (lotes de MLX +
                                         N × [crítica FM + formatação FM] — NÃO batched)

Usuário abre Quiz / Análise de código (sampleQuiz — puro SwiftData, sem modelo)
        │
        └─ ao fechar o sheet: TopicRepository.replenishAfterSession()
                 → repõe só o consumido, até o alvo cheio (top-up, Task solta)

Usuário vê resultado da sessão → StudyResultView.task
        └─ StudyGenerator.generateFeedback(...)   ── FM (schema StudyFeedback)
        └─ resolve recommendedNextTopic: match normalizado; se falhar, hybridSearch (RAG fuzzy)
```

### 1.2 Componentes e responsabilidades

| Componente | Arquivo | Responsabilidade |
|---|---|---|
| `DocumentIndex` | `Services/DocumentIndex.swift` | Índice RAG singleton: embeddings via `NaturalLanguageEmbeddings`/`NLContextualEmbedding`, cache em disco, busca semântica pura, busca híbrida, busca exata por tópico |
| `StudyGenerator` | `Services/StudyGenerator.swift` (917 linhas — o maior arquivo do projeto) | Toda a comunicação com Foundation Models e MLX: resumo, exemplo de código (MLX→FM), quiz (FM ou MLX→FM conforme dificuldade), análise de código (MLX→FM), feedback |
| `MLXService` | `Services/MLXService.swift` | Download/carga do modelo MLX, geração de texto livre (single e batched), progresso de download, pré-aquecimento |
| `GenerationOrchestrator` | `Services/GenerationOrchestrator.swift` | Actor com 1 fila serial por motor (FM, MLX) e 3 prioridades — serializa chamadas concorrentes ao mesmo motor |
| `TopicRepository` | `Services/TopicRepository.swift` (537 linhas) | Cache/persistência via SwiftData, dedup de geração concorrente por tópico, crescimento de pool em background, top-up pós-sessão |
| `QuestionValidator` | `Services/QuestionValidator.swift` | Sanitização + validação determinística de toda questão antes de persistir (nunca chama modelo) |
| `DocChunk` / `StudyModels` / `Persistence` | `Models/*.swift` | DTOs de RAG, schemas `@Generable` do Foundation Models, entidades `@Model` do SwiftData |
| `PlaceholderDocs` | `Data/PlaceholderDocs.swift` | Dataset estático (hoje 3 tópicos / 8 chunks) |
| Views (`TopicStudyView`, `QuizView`, `CodeAnalysisView`, `StudyResultView`, `ModelDownloadView`, `StudyHomeView`) | `Views/*.swift` | UI; `ContentView`, `RAGTestView`, `TopicRepositoryTestView` são telas de debug/teste manual (comentários no próprio código dizem isso) |

### 1.3 Onde cada tecnologia entra

- **MLX** entra em 3 pontos por tópico: (1) rascunho do exemplo de código
  (`StudyGenerator.swift:239-280`, síncrono/bloqueante), (2) rascunhos de quiz
  difícil (`StudyGenerator.swift:519-546`, background), (3) rascunhos de
  análise de código (`StudyGenerator.swift:706-756`, background). MLX nunca
  produz o conteúdo final — sempre um rascunho em texto livre que o Foundation
  Models reformata depois.
- **Foundation Models** entra em: resumo, quiz fácil/média (geração direta),
  crítica + formatação do exemplo de código, formatação de cada questão
  difícil, crítica + formatação de cada questão de análise de código,
  feedback final. É o único motor usado para produzir dados no schema
  `@Generable` que a UI de fato renderiza.
- **NaturalLanguage** (via `NLContextualEmbedding`/`NaturalLanguageEmbeddings`)
  entra só em `DocumentIndex`: embeddings dos chunks (uma vez, cacheados) e
  embeddings da query em `hybridSearch`/`search`. **Achado importante** (ver
  §16.1): o caminho de geração de produção usa `chunks(forExactTopic:)`
  (`DocumentIndex.swift:211-213`), que é um filtro por igualdade de string —
  **não usa embedding nenhum**. `NaturalLanguage`/embeddings hoje só
  alimentam a tela de debug (`RAGTestView`) e o fallback de
  "tópico recomendado" (`StudyResultView.resolveRecommendedTopic`).
- **RAG** (no sentido de retrieval-augmented generation) entra como grounding:
  o texto do(s) chunk(s) do tópico exato é concatenado e injetado no prompt
  de cada chamada de geração. Não há reranking, não há deduplicação de
  chunks (desnecessário — datasets de 2-3 chunks por tópico, sem
  redundância) e não há passo de "recuperação" custoso no caminho quente,
  porque o "retrieval" é um filtro de array.
- **Síncrono vs. assíncrono**: praticamente tudo é `async`/`await`
  estruturado. Os pontos de concorrência real são: `async let exampleTask`
  em `TopicRepository.swift:208` (MLX em paralelo com FM no caminho
  bloqueante) e `withTaskGroup` em `TopicRepository.swift:384-431` (trilha FM
  vs. trilha MLX no crescimento em background). Dentro de cada motor, tudo é
  serializado pelo `GenerationOrchestrator` (ver §6).

---

## 2. Investigação MLX — por que a geração está demorando

### 2.1 CONFIRMED — o exemplo de código (mostrado em TODO tópico) sempre tenta MLX primeiro, no caminho bloqueante

`StudyGenerator.generateCodeExample` (`StudyGenerator.swift:239-280`) roda
para **qualquer** tópico, não só para conteúdo "difícil":

```swift
func generateCodeExample(topic: String, context: String, priority: ...) async throws -> ExplainedCodeExample {
    do {
        try await MLXService.shared.loadModel()          // linha 241
        ...
        let draft = ... generateQuestionDraft(...)        // 1 chamada MLX
        return try await formatCodeExample(draft: ...)     // crítica FM + formatação FM
    } catch {
        return try await generateCodeExampleFromScratch(...)  // fallback 100% FM
    }
}
```

Isso é chamado dentro de `async let exampleTask = ...` em
`TopicRepository.swift:208-210`, que faz parte do caminho **bloqueante** de
`generateAndPersist` (a tela "Gerando conteúdo..." só sai do ar quando
`fetchOrCreate` retorna). Ou seja: **abrir qualquer tópico pela primeira vez
paga o custo de carregar um modelo local de 7B parâmetros na RAM**, mesmo
que o usuário nunca toque em quiz difícil ou análise de código.

Isso contradiz a descrição em `GUIA_APRESENTACAO.md:51` ("resumo, exemplo,
quiz fácil/média são 100% Foundation Models (sem rede)") — essa afirmação
está **desatualizada** em relação ao código atual. Vale alinhar a
documentação com a realidade ou (mais importante) decidir se esse é
realmente o comportamento desejado.

`formatCodeExample` (`StudyGenerator.swift:298-369`) então faz **duas**
chamadas de Foundation Models em série, cada uma dependente da anterior:
`critiqueCodeDraft` (350 tokens de orçamento, linha 412) seguida de uma
formatação com **1600 tokens de orçamento** (linha 353) — com um possível
retry inteiro (mais 1600 tokens de orçamento) se o código sair truncado
(linhas 357-365).

**Cadeia mínima só para o exemplo de código de UM tópico**: `loadModel()` +
1 chamada MLX + 1 chamada FM (crítica) + 1 chamada FM (formatação) — no pior
caso, + 1 chamada FM extra (retry de truncamento).

Isso é o achado de maior impacto deste relatório. Ver §16.2 para a pergunta
de arquitetura ("isso precisa de MLX?").

### 2.2 CONFIRMED — fila global única serializa TODAS as chamadas de Foundation Models do app

`GenerationOrchestrator` (`GenerationOrchestrator.swift:25-158`) mantém
`fmQueue`/`mlxQueue` como filas **seriais** — só um worker por motor
(`runFMWorker`/`runMLXWorker`, linhas 141-157), processando um job de cada
vez. Isso é uma decisão de design correta e bem documentada (evita
`rateLimited`/`concurrentRequests` do Foundation Models e contenção no MLX —
comentário em `GenerationOrchestrator.swift:12-21`), mas tem uma
consequência direta: **toda** chamada FM do app — resumo, quiz fácil, quiz
médio, crítica do exemplo, formatação do exemplo, formatação de cada questão
difícil, crítica+formatação de cada questão de análise — passa pela mesma
fila, uma de cada vez, mesmo as que rodam "em paralelo" via `async let`
(`TopicRepository.swift:208`) ou `withTaskGroup`
(`TopicRepository.swift:384-431`).

Na prática, o paralelismo declarado no código (trilha FM × trilha MLX) só
ajuda a sobrepor **carga do modelo MLX + geração MLX** com **as primeiras
chamadas FM** (resumo, quiz). A partir do momento em que a trilha MLX
termina o rascunho e entra na fase de crítica/formatação (2 chamadas FM),
essas chamadas competem pela MESMA fila FM que resumo/quiz — não há speedup
adicional aí, só ordenação por prioridade.

**Contagem de chamadas FM para 1 tópico novo** (contando com o crescimento
em background completo, que roda logo em seguida, não só o caminho
síncrono):

| Etapa | Chamadas FM | Onde |
|---|---:|---|
| Resumo | 1 | `generateSummary` |
| Quiz fácil (batch de 6) | 1 (+ 0-N regenerações do validador) | `generateQuizBatch(.easy)` |
| Quiz médio (batch de 6) | 1 (+ 0-N regenerações) | `generateQuizBatch(.medium)` |
| Exemplo de código: crítica | 1 | `critiqueCodeDraft` |
| Exemplo de código: formatação | 1 (+0-1 retry) | `formatCodeExample` |
| **Subtotal síncrono (bloqueia a tela)** | **5-6+** | |
| Quiz difícil até 6 (2 lotes MLX de até 4) | 6 (1 por item, NÃO batched) | `formatHardQuestion` × 6 |
| Análise de código até 6 (2 lotes MLX de até 4) | 12 (crítica + formatação por item) | `formatCodeAnalysisQuestion` × 6 |
| **Subtotal background (não bloqueia, mas ocupa a fila)** | **~18** | |
| **Total por tópico novo** | **~23-24 chamadas FM + ~5-6 chamadas MLX** | |

Isso é uma contagem **CONFIRMED** de chamadas (o código enumera exatamente
essas chamadas); a duração real de cada uma é `Needs runtime measurement`
(ver §9 para como instrumentar).

### 2.3 CONFIRMED — rascunhos MLX são batched, mas a formatação FM correspondente NÃO é

`generateQuestionDrafts` (`MLXService.swift:219-237`) já faz N rascunhos numa
única chamada MLX (1 prefill para N itens — otimização já aplicada, boa).
Mas o consumo desses rascunhos é sequencial, um FM call por item:

```swift
// StudyGenerator.swift:548-552 (quiz difícil)
var results: [QuizQuestion] = []
for draft in drafts.prefix(count) {
    let question = await formatHardQuestion(draft: draft, ...)   // 1 chamada FM cada
    results.append(question)
}
```

O mesmo padrão se repete em `generateCodeAnalysisBatch`
(`StudyGenerator.swift:739-741`), só que pior: cada item paga **duas**
chamadas FM (crítica + formatação, `formatCodeAnalysisQuestion`,
`StudyGenerator.swift:767-883`). Como a fila FM já é serial de qualquer
forma (§2.2), essas chamadas nunca rodariam em paralelo mesmo se
disparadas concorrentemente — mas elas **poderiam** ser 1 chamada FM pedindo
N formatações de uma vez (a própria `QuizQuestionBatch`/`CodeAnalysisBatch`
já existem como schemas em `StudyModels.swift:75-77,97-100` e não são usados
para isso hoje — só `generateQuizBatch` fácil/médio usa `QuizQuestionBatch`).
Isso reduziria o número de sessões `LanguageModelSession` criadas (cada uma
paga o custo de processar as `instructions` de novo) de N para 1 por lote.

### 2.4 CONFIRMED — nenhuma reutilização de KV cache / prompt cache no MLX

`MLXService.generate` (`MLXService.swift:316-342`) monta um prompt novo do
zero em toda chamada:

```swift
let fullPrompt = "<|im_start|>system\n\(systemPrompt)<|im_end|>\n<|im_start|>user\n\(promptContext)<|im_end|>\n<|im_start|>assistant\n"
...
let input = try await context.processor.prepare(input: .init(prompt: fullPrompt))
return try MLXLMCommon.generate(input: input, parameters: generateParams, context: context)
```

Não há nenhum objeto de cache (`KVCache`/prompt cache) sendo criado,
guardado ou reutilizado entre chamadas. Isso importa porque, **dentro do
mesmo tópico**, até 3 chamadas MLX diferentes (exemplo de código, lote de
quiz difícil, lote de análise de código) reenviam um contexto RAG
praticamente idêntico (o mesmo texto de 2-3 chunks do tópico) mais um
preâmbulo de sistema muito parecido ("Você é um especialista em Swift...").
Cada uma dessas chamadas paga o prefill inteiro do zero.

- **CONFIRMED**: a ausência do mecanismo (não há cache em nenhum lugar do
  arquivo).
- **HIGHLY LIKELY**: isso custa tempo real, porque prefill de um modelo 7B
  para ~600-750 palavras de contexto + preâmbulo não é gratuito.
- **HYPOTHESIS** (precisa medir): quanto exatamente isso custa em relação ao
  tempo de geração (decode). Ver §2.8 para como medir prompt-eval vs.
  decode separadamente.

`MLXLMCommon` (a mesma dependência já usada, versão 2.29.1) expõe suporte a
prompt cache reutilizável — isso já estava anotado em
`PLANOS_DE_MELHORIA.md:36` e continua não implementado no código atual.

### 2.5 CONFIRMED — chat template montado manualmente como string

`MLXService.swift:321` monta o prompt ChatML (`<|im_start|>...`) como
concatenação de string, em vez de usar a API de template do tokenizer via
`swift-transformers`/`MLXLMCommon` (que já é dependência do projeto). Isso
não é necessariamente um bug de correção (o formato ChatML do Qwen é
conhecido e estável), mas é um ponto de fragilidade: se o modelo for trocado
por outro com um `chat_template` diferente (algo que o próprio código já fez
uma vez — 30B MoE → 7B, ver `MLXService.swift:7-15`), o prompt manual não
acompanha a troca automaticamente. `HIGHLY LIKELY` gerar tokens extras ou mal
formados só se o token especial não bater exatamente com o vocabulário do
tokenizer — como é o mesmo formato ChatML usado por toda a família Qwen,
`HYPOTHESIS` de que isso hoje cause problema de qualidade/latência
mensurável; risco é mais de manutenção futura do que de performance atual.

### 2.6 CONFIRMED — nenhum tuning de `MLX.GPU.set(cacheLimit:)`

Busquei em todo o projeto (`grep -r "GPU.set\|cacheLimit" SwiftStudyCoach/`)
e não há nenhuma chamada de configuração de cache da GPU. O projeto usa os
defaults do `mlx-swift`. Isso já estava listado como pendência em
`PLANOS_DE_MELHORIA.md:39` e continua pendente. `HYPOTHESIS`: em macOS com
RAM unificada limitada (o comentário do cabeçalho de `MLXService.swift` já
fala de pressão de memória como causa de queda de tokens/s), ajustar o
`cacheLimit` pode ajudar ou atrapalhar dependendo do hardware — precisa
medir em vez de aplicar um valor arbitrário (ver §9.7 para benchmark
sugerido).

### 2.7 CONFIRMED — dedup de carregamento do modelo já existe (não é um problema)

Vale registrar o que **não** é um problema: `MLXService.loadModel()`
(`MLXService.swift:102-127`) já deduplica chamadas concorrentes via
`loadTask` compartilhada, e `isLoaded` evita recarregar o modelo depois do
primeiro sucesso. `TopicRepository` chama `loadModel()` em pelo menos 3
pontos diferentes (`generateCodeExample`, trilha MLX de
`growPoolInBackground`, `generateQuizBatch`/`generateCodeAnalysisBatch`) e
todos batem nessa dedup — **não há recarregamento repetido do modelo**. Bom
já ter descartado essa hipótese.

### 2.8 HYPOTHESIS — onde exatamente o tempo vai (prompt eval vs. decode vs. carga)

O código já loga elapsed time e "chars/s" (`MLXService.swift:337-339`,
`TopicRepository.swift:262-266`), mas:
- "chars/s" **não é** tokens/s (caracteres ≠ tokens; para português a razão
  é ~3-4 chars/token). O rótulo no código está correto tecnicamente (diz
  "chars/s", não "tokens/s"), mas é fácil de ler errado como throughput real
  do modelo. Recomendo trocar para tokens/s de verdade (ver §9.5).
- Não há separação entre **tempo até o primeiro token** (prompt evaluation)
  e **tempo de geração** (decode). Isso é essencial para saber se o
  problema é "o prefill do contexto RAG + system prompt é caro" (aponta pra
  prompt caching, §2.4) ou "o modelo gera devagar mesmo depois de começar"
  (aponta pra quantização/tamanho do modelo, já resolvido ao usar 4-bit, ou
  pra `maxTokens` alto demais).

**Como medir** (Phase 0): capturar `Date()` antes de `MLXLMCommon.generate`
e novamente no primeiro chunk não-vazio recebido do stream em
`MLXService.generate` (`MLXService.swift:330-335`); isso dá TTFT. Tokens/s
real: contar tokens do stream (`generation` normalmente expõe informação de
token, ou usar o tokenizer do `context.processor` para contar tokens do
`outputText` final) em vez de `outputText.count` (chars). Rodar isso pros 3
pontos de entrada MLX (exemplo de código, quiz difícil, análise de código)
separadamente, porque os prompts têm tamanhos diferentes.

### 2.9 Resumo da seção — o que sabemos vs. o que falta medir

| Fator investigado pelo pedido do usuário | Status |
|---|---|
| Tempo para carregar o modelo | CONFIRMED: acontece de forma bloqueante no primeiro tópico (`generateCodeExample`), com dedup correto entre chamadas concorrentes. Duração real: `Needs runtime measurement` (já logada em `MLXService.swift:162`, só falta agregar) |
| Modelo carregado mais de uma vez | CONFIRMED que NÃO acontece (dedup funciona) |
| Inicialização do tokenizer | Feita dentro de `loadContainer` (biblioteca), sem instrumentação própria — `Needs runtime measurement` se relevante |
| Warm-up / pré-aquecimento | CONFIRMED implementado (`prewarmIfCached`, `RootTabView.swift:33`), mas só dispara se os pesos já estiverem no cache local — não ajuda no 1º download |
| 1ª inferência vs. seguintes | Não há warm-up de inferência (só de carga de pesos) — `HYPOTHESIS`: a 1ª geração real após carregar pode ser mais lenta por compilação/JIT do grafo MLX; medir separadamente |
| Prompt evaluation / TTFT | Não instrumentado — `Needs runtime measurement`, ver §2.8 |
| Tokens/s | Métrica atual usa chars, não tokens — impreciso; `Needs runtime measurement` com contagem real |
| Tamanho do contexto/prompt de sistema | CONFIRMED e pequeno hoje (dataset de 3 tópicos) — ver §3 |
| KV cache / cache reutilizável | CONFIRMED ausente (§2.4) |
| Quantização/tamanho do modelo | CONFIRMED: 4-bit, 7B, decisão já validada com evidência (comentário do cabeçalho) — não reabrir sem novo motivo |
| Chamadas sequenciais desnecessárias | CONFIRMED: formatação FM pós-batch MLX não é batched (§2.3); crítica+formatação do exemplo de código são inerentemente sequenciais (a segunda depende da primeira) — correto, não é um "bug" |
| Operações na main thread | `TopicRepository` é `@MainActor` (`TopicRepository.swift:35`), mas todo o trabalho pesado usa `Task.detached`/`withTaskGroup` fora do main actor para o crescimento em background; o caminho síncrono (`generateAndPersist`) roda a partir de `.task` da View, fora da main thread real de UI — sem evidência de bloqueio de main thread |
| Streaming | CONFIRMED: MLX suporta stream (`MLXService.swift:325-335`), mas o wrapper consome o stream inteiro antes de retornar — não exposto à UI (§8) |
| Pré-carregamento | CONFIRMED implementado parcialmente (só pesos, não warm-up de inferência) |

---

## 3. Análise de tokens

Os números abaixo são **orçamentos configurados no código** (tetos), não
consumo real medido — sinalizo isso em cada linha.

| Chamada | Orçamento configurado (`maximumResponseTokens`) | Arquivo:linha |
|---|---:|---|
| Resumo | 750 | `StudyGenerator.swift:224` |
| Quiz fácil (6 itens, 1 chamada) | 220×6+150 = 1.470 | `StudyGenerator.swift:606` |
| Quiz médio (6 itens, 1 chamada) | 220×6+150 = 1.470 | `StudyGenerator.swift:606` |
| Crítica do exemplo de código | 350 | `StudyGenerator.swift:412` |
| Formatação do exemplo de código | 1.600 (+1.600 se retry) | `StudyGenerator.swift:353` |
| Formatação de questão difícil (`formatHardQuestion`) | **nenhum explícito** (default implícito da API) | `StudyGenerator.swift:689-692` — ver achado abaixo |
| Formatação de análise de código | 900 | `StudyGenerator.swift:860` |
| Feedback final | 600 | `StudyGenerator.swift:911` |
| Rascunho MLX único | 350 | `MLXService.swift:211` |
| Rascunho MLX em lote (N itens) | 300×N+50 | `MLXService.swift:227` |

**CONFIRMED — inconsistência**: `formatHardQuestion`
(`StudyGenerator.swift:687-693`) chama
`session.respond(to: formatterPrompt, generating: QuizQuestion.self)` **sem**
passar `options:`, diferente de toda outra chamada estruturada do arquivo
(todas as outras têm `GenerationOptions(maximumResponseTokens:)` explícito).
O comentário em `formatCodeAnalysisQuestion`
(`StudyGenerator.swift:852-857`) até documenta que esse mesmo bug foi
corrigido ali ("`maximumResponseTokens` também estava usando o default
implícito... agora fixado explicitamente com folga") — mas a correção não
foi replicada em `formatHardQuestion`, que é o caminho irmão para quiz
difícil. Risco: truncamento silencioso específico de perguntas difíceis, sem
o mesmo retry-com-versão-mais-curta que existe para código. Ver Quick Win
§12.1.

### 3.1 Onde o token é gasto de forma potencialmente desnecessária

- **Contexto RAG repetido, não redundante**: `context` (topK 3) é calculado
  **uma vez** por `generateAndPersist` (`TopicRepository.swift:190-191`) e
  reutilizado em resumo/quiz — isso já está correto, sem retrabalho. Mas as
  chamadas MLX (`generateQuizBatch` difícil, `generateCodeAnalysisBatch`)
  **recalculam** `retrieveContext` internamente
  (`StudyGenerator.swift:526,711`) em vez de receber o contexto já
  calculado pelo chamador. Como o caminho é o filtro exato (sem embedding),
  isso é barato (não é uma chamada cara), mas é uma pequena duplicação de
  trabalho e de tokens idênticos remontados — fácil de eliminar passando o
  `context` como parâmetro (Quick Win §12.2).
- **`instructions` (system prompt) repetido em toda sessão nova**: por
  design (comentário em `PLANOS_DE_MELHORIA.md` e no próprio código,
  `StudyGenerator.swift` — "Sessão sempre nova por retry... sessão
  reutilizada acumula transcript e estoura contexto"), cada chamada FM cria
  uma `LanguageModelSession` nova. Isso é uma decisão correta para evitar
  estouro de contexto em retries, mas significa que os ~23 `instructions`
  (texto de sistema, repetido com pequenas variações por etapa) são
  reprocessados do zero em cada uma das ~23 chamadas por tópico. Não há API
  pública do Foundation Models neste código para cachear isso entre sessões
  — é uma limitação do framework, não do app. Classifico como
  **HYPOTHESIS**: não sei quantificar o custo sem medir tokens de entrada
  reais (Foundation Models não expõe contagem de tokens no código atual —
  ver gap de instrumentação, §9).
- **Poças de geração especulativa**: o pool completo (6 fácil + 6 média + 6
  difícil + 6 análise = 24 questões) é gerado para **todo** tópico novo, na
  criação (`TopicRepository.swift:252-256`, alvo cheio, não só o "piso" da
  1ª sessão). Uma sessão de quiz consome 3+4+3=10 questões; a análise de
  código pode nunca ser aberta. Isso já é uma redução de 55% em relação ao
  volume antigo (`PLANO_V3.md:14-16`, de 53 para 24), mas o princípio
  "gerar sob demanda" do `PLANO_V2.md:29-31`/`PLANO_V3.md §4.1` (top-up
  **em vez de** enchimento inicial) só foi meio-implementado: o top-up
  (`replenishAfterSession`) existe e funciona, mas ele é **adicional** ao
  enchimento completo que já acontece na criação — não o substituiu. Ver
  §16.3 para a pergunta de arquitetura.
- **`maxTokens` do quiz fácil/médio**: 220 tokens por pergunta (comentário
  em `StudyGenerator.swift:602-605` já explica que 220 foi calibrado depois
  de ver truncamento em 600 tokens fixos para todo o lote) — parece
  razoável e já foi ajustado com evidência real, não é um achado novo.

### 3.2 Estimativa qualitativa (não numérica) de "tokens úteis vs. desperdiçados"

Não dá pra afirmar um número tipo "500 úteis + 4000 desnecessários" sem medir
tokens de entrada reais — o Foundation Models não expõe contagem de tokens
no código atual, e eu não tenho acesso a rodar o app. O que dá pra afirmar
pelo código:
- O contexto RAG em si é pequeno e **não** parece ser a fonte principal de
  desperdício (2-3 chunks, ~200-250 palavras cada, sem redundância entre
  chunks do mesmo tópico).
- O maior "desperdício" identificável estruturalmente é a **geração
  especulativa de conteúdo que pode nunca ser consumido** (24 questões
  geradas, ~10 tipicamente vistas na 1ª sessão) — isso é desperdício de
  **geração** (tempo de GPU/ANE, bateria), não necessariamente de "tokens
  mal aproveitados dentro de um único prompt".
- `Needs runtime measurement`: para confirmar/negar a hipótese de tokens de
  entrada desperdiçados por sessão nova a cada chamada, instrumentar (ver
  §9.4) e comparar tokens de entrada com e sem RAG (contexto vazio) pro
  mesmo tópico.

---

## 4. Auditoria do RAG

### Retrieval Quality

- A estratégia de chunking (200-250 palavras, 2-3 chunks por tópico, um
  ângulo conceitual por chunk) segue a recomendação do próprio pacote de
  embeddings (comentário em `PlaceholderDocs.swift:23-26`) e não mostra
  sinais de redundância dentro do mesmo tópico (li os 8 chunks inteiros —
  cada um cobre um aspecto distinto: mecanismo geral, API de
  navegação/estado, uso prático).
- `hybridSearch` (`DocumentIndex.swift:150-195`) combina cosseno (peso 0.35)
  + overlap léxico (peso 0.5) + boost de tópico (0.40 exato / 0.15 parcial),
  com stopwords em português filtradas do overlap léxico
  (`DocumentIndex.swift:243-253`) e threshold adaptativo (corte 0.45, relaxa
  pra 0.30 exigindo sinal léxico ou boost de tópico —
  `DocumentIndex.swift:182-194`). Os pesos foram recalibrados com evidência
  real documentada no próprio comentário (`DocumentIndex.swift:129-149`,
  viram que cosseno puro do `NLContextualEmbedding` tem baseline alto demais
  pra esse domínio). Essa é uma análise de qualidade já bem feita.
- **CONFIRMED — porém, esse mecanismo praticamente não roda em produção
  hoje**: `StudyGenerator.retrieveContext` (`StudyGenerator.swift:89-96`),
  usado por 100% das chamadas de geração internas, usa
  `chunks(forExactTopic:)` primeiro (`DocumentIndex.swift:211-213`, filtro
  de igualdade, sem embedding) e só cai no `hybridSearch` se não achar nada
  — o que não deveria acontecer, já que `StudyHomeView` deriva os nomes de
  tópico diretamente do mesmo dataset (`StudyHomeView.swift:23`,
  `PlaceholderDocs.topicsByBlock()`). Ou seja: **toda a engenharia de
  scoring híbrido roda hoje só em `RAGTestView` (debug) e no fallback de
  "próximo tópico recomendado"** em `StudyResultView.resolveRecommendedTopic`
  (`StudyResultView.swift:271-282`). Ver §16.1 — pergunta legítima: dado que
  a lista de tópicos é curada e fechada, embeddings são realmente
  necessários no caminho principal?
- Sem reranking e sem deduplicação de chunks no `hybridSearch` — mas com
  8 chunks totais e no máximo 3 por tópico, isso não é um problema de
  qualidade hoje. Voltaria a importar se o dataset crescer de volta a 21
  tópicos (como chegou a ser, segundo `PLANO_V3.md` e o comentário em
  `PlaceholderDocs.swift:8-17`).
- Sem metadados de fonte por chunk na estrutura persistida (`DocChunk` só
  tem `topic`/`text`/`embedding` — `DocChunk.swift:13-24`), embora
  `PlaceholderDocs.swift` tenha comentários `// Fonte:` apontando a doc
  oficial (não entram no RAG, são só para auditoria humana). Isso já era um
  item do `PLANOS_DE_MELHORIA.md:21` e continua não implementado — baixo
  impacto agora (não há UI que mostraria a fonte), mas fácil de adicionar se
  quiser citar a doc oficial na resposta.

### Retrieval Performance

- Com 8 chunks, qualquer busca (semântica, léxica ou híbrida) é
  essencialmente instantânea — não há gargalo de performance de busca hoje.
  `Needs runtime measurement` só voltaria a fazer sentido se o dataset
  crescer para centenas/milhares de chunks (o comentário em
  `GUIA_APRESENTACAO.md:54` já antecipa isso e sugere um índice vetorial
  nesse cenário — concordo que seria overengineering agora).
- Cache de embeddings em disco (`DocumentIndex.swift:271-311`, chave SHA256
  do dataset) funciona e evita reindexação — **CONFIRMED, bem implementado**.
  Em cache HIT, `buildIndex` retorna após um único read+decode de JSON
  (`DocumentIndex.swift:82-87`).
- Em cache MISS, os embeddings são gerados **sequencialmente**
  (`DocumentIndex.swift:94-98`, loop `for` com `await`), com justificativa
  explícita no comentário (thread-safety do `NLContextualEmbedding`
  subjacente não é documentada). Para 8 chunks isso é irrelevante
  (provavelmente < 1s). Se o dataset voltar a crescer para 21+ tópicos
  (50+ chunks), reindexação sequencial após uma mudança de conteúdo pode
  somar alguns segundos — não é urgente, mas é a única parte do RAG onde
  paralelizar (`withThrowingTaskGroup`, como o `PLANOS_DE_MELHORIA.md:18` já
  sugeria) teria efeito real, **se** o pacote de embeddings comprovar ser
  thread-safe (precisa verificar antes de paralelizar — não presumir).
- **Achado de arquitetura**: `TopicStudyView.load()`
  (`TopicStudyView.swift:116-133`) faz `await documentIndex.ensureReady()`
  **antes** de sequer construir o `TopicRepository`, bloqueando a entrada em
  qualquer tela de tópico até o índice de embeddings estar pronto — mesmo
  que o caminho de geração que vai rodar em seguida (`chunks(forExactTopic:)`)
  não precise de embedding nenhum. Em cache HIT (caso comum) isso é barato
  (leitura de um JSON pequeno), mas arquiteturalmente acopla dois
  subsistemas independentes (dados de chunk vs. embeddings) que só
  precisariam estar acoplados no caminho fuzzy. Ver Quick Win §12.4.
- Duas chaves de cache independentes para "o dataset mudou": o hash SHA256
  em `DocumentIndex` (baseado no conteúdo de `rawChunks`) e a string
  `DatasetVersion.current` em `Persistence.swift:44` (bump manual). Hoje
  andam sincronizadas porque ambas mudam junto com edições em
  `PlaceholderDocs.swift`, mas são dois mecanismos de invalidação
  desacoplados para o mesmo evento — risco baixo, mas é uma fonte possível
  de inconsistência futura (ex.: alguém edita o texto de um chunk sem
  lembrar de bumpar `DatasetVersion`, ou vice-versa).

### Estamos recuperando contexto demais/de menos?

Não — pelo tamanho atual do dataset (2-3 chunks por tópico, topK 2-3), o
contexto recuperado é o tópico inteiro, sempre. Não há corte de informação
relevante nem inclusão de chunks de outros tópicos (o caminho exato
`chunks(forExactTopic:)` garante isso por construção). Essa parte do
pipeline está bem dimensionada para a escala atual.

---

## 5. Repeated Work / Missing Caches

O que **já está cacheado corretamente** (não preciso reabrir):
- Embeddings do dataset (`DocumentIndex`, disco, chave por hash) ✅
- Carga do modelo MLX (dedup via `loadTask` compartilhada) ✅
- Construção do índice RAG (dedup via `buildTask` compartilhada,
  `DocumentIndex.swift:53-67`) ✅
- Geração de tópico já existente (SwiftData, `fetchOrCreate`) ✅
- Geração concorrente do MESMO tópico (dedup via `inFlightGenerations`,
  `TopicRepository.swift:56,150-167` — corrigido depois de um bug real
  visto em teste, segundo o comentário) ✅

O que **é recalculado sem necessidade** (baixo impacto individual, mas vale
listar):
1. `retrieveContext(for:topK:)` chamado de novo dentro de
   `generateQuizBatch`/`generateCodeAnalysisBatch`
   (`StudyGenerator.swift:526,711`) mesmo quando o chamador
   (`TopicRepository.generateAndPersist`) já tinha calculado o mesmo
   contexto na linha 190. Caminho exato = barato (filtro de array), mas é
   trabalho e string-building duplicado sem necessidade. **Quick Win §12.2**.
2. Cada chamada de formatação (`formatHardQuestion`,
   `formatCodeAnalysisQuestion`) cria uma `LanguageModelSession` nova com as
   mesmas `instructions` de sistema — necessário pelo design (evitar
   estouro de contexto entre retries), mas efetivamente "reconstrói" o
   mesmo texto de instruções 6-18 vezes por tópico. Não há como evitar isso
   sem uma API de reuso de instruções do próprio framework (não vi uma no
   código) — registrado como limitação externa, não bug do app.
3. `SyntaxHighlighter.highlight` (`CodeBlockView.swift:78-106`) roda a
   regex de tokenização toda vez que a view recalcula seu `body` (não há
   cache do resultado do highlight por string de entrada). Para snippets de
   5-15 linhas isso é barato por chamada, mas o SwiftUI pode recalcular
   `body` várias vezes por segundo durante animações/scroll — se isso vier
   a aparecer em profiling de UI (Instruments, Time Profiler), cachear por
   `code` (ex.: `@State private var highlighted: AttributedString`
   calculado uma vez no `.task`/`onAppear`) é trivial. `HYPOTHESIS`: baixo
   impacto hoje (poucos code blocks visíveis por vez).
4. `PlaceholderDocs.topicsByBlock()` (`PlaceholderDocs.swift:281-295`) é
   chamado como inicializador de `let track` em `StudyHomeView.swift:23` —
   isso já roda só uma vez por instância de view (é `let`, não recomputado a
   cada render), então não é repetido de forma problemática. Só registrando
   que confirmei — não é um achado.

Nenhum outro padrão de "recalcular o que devia estar cacheado" encontrado
nos arquivos lidos. O projeto já tem bons hábitos de cache/dedup nos pontos
que mais importariam (índice, modelo, geração por tópico).

---

## 6. Concorrência e pipeline

### O que roda em paralelo hoje (correto, com dependências respeitadas)

- `async let exampleTask` (trilha MLX) `+ await` sequencial de
  resumo/quiz/média (trilha FM) em `TopicRepository.swift:208-229` — MLX e
  FM são motores diferentes, sem dependência de dados entre eles até o
  `await exampleTask` final. Correto.
- `withTaskGroup` de 2 tracks em `growPoolInBackground`
  (`TopicRepository.swift:384-431`) — trilha FM (fácil/média) e trilha MLX
  (difícil → análise), cada uma com seu próprio `ModelContext` isolado
  (comentário explícito em `TopicRepository.swift:358-360`: "cada trilha
  usa seu PRÓPRIO ModelContext... os saves não conflitam"). Isso evita
  exatamente o tipo de race condition que SwiftData teria se dois contextos
  concorrentes escrevessem no mesmo objeto.
- Dentro de cada trilha, difícil → análise de código é **sequencial de
  propósito** (`growPoolInBackground`, mesma trilha B) — ambos usam o motor
  MLX, então rodar em paralelo dentro da trilha não ganharia nada (a fila
  MLX já serializa) e complicaria o código à toa. Decisão correta.

### O que é serial por design, e por quê (não recomendo mudar sem medir)

- Fila FM e fila MLX do `GenerationOrchestrator` — serial por
  **necessidade documentada** (evitar `rateLimited`/`concurrentRequests` do
  Foundation Models e contenção de recursos no MLX, que tem só uma
  instância de modelo carregada). `HYPOTHESIS` a explorar (não a assumir):
  será que o Foundation Models aceita 2 sessões concorrentes sem erro? Se
  sim, uma fila com profundidade 2 só para trabalho `.poolFill` (nunca para
  `.userBlocking`) poderia acelerar o crescimento em background sem arriscar
  a experiência do usuário ativo. **Como testar**: rodar 2
  `LanguageModelSession.respond` concorrentes manualmente numa build de
  debug e ver se `concurrentRequests`/`rateLimited` disparam; se não
  dispararem em nenhuma tentativa razoável, considerar aumentar a
  profundidade só da fila de background. Risco de tentar isso sem medir:
  reintroduzir exatamente os retries de contenção que o `GenerationOrchestrator`
  foi criado para eliminar (`GenerationOrchestrator.swift:12-21`).
- Formatação de rascunhos MLX em lote (§2.3) — sequencial hoje, mas nada
  impede tecnicamente enviar N formatações numa única chamada FM (usando
  `QuizQuestionBatch`/`CodeAnalysisBatch`, que já existem). Essa é uma
  paralelização **de prompt** (1 chamada maior), não de concorrência real —
  reduz o número de sessões, não introduz race condition nova. **Quick Win
  candidato de maior impacto depois do problema do §2.1.**

### Riscos de race condition avaliados

- `inFlightGenerations` (dedup por tópico) e `buildTask`/`loadTask` (dedup
  de índice/modelo) são todos `@MainActor` ou guardados por padrão de Task
  compartilhada — sem evidência de race condition nova introduzida pelo
  código atual. O próprio projeto tem uma tela de teste manual dedicada a
  isso (`TopicRepositoryTestView.runRaceTest`,
  `TopicRepositoryTestView.swift:265-293`, dispara `fetchOrCreate` 2x em
  paralelo e verifica se duplica) — bom sinal de disciplina de engenharia,
  mesmo sem testes automatizados (ver §11.3).
- `isGeneratingPool` (flag em `StudyTopic`) é setada **antes** de qualquer
  `await` longo (`TopicRepository.swift:328`, comentário explícito sobre
  isso) — evita disparo duplicado de crescimento em background para o
  mesmo tópico. Correto.

### Risco de memória avaliado

- `ProcessInfo.processInfo.beginActivity` com
  `.userInitiatedAllowingIdleSystemSleep` + `.automaticTerminationDisabled`
  (`TopicRepository.swift:378-382`) evita que o macOS estrangule o app em
  background (App Nap) durante o crescimento do pool — bem pensado,
  documentado com o motivo certo.
- Não há limite de quantos tópicos podem estar `isGeneratingPool = true`
  simultaneamente — se o usuário abrir vários tópicos novos rapidamente (via
  `StudyHomeView`), cada um dispara sua própria `growPoolInBackground` em
  paralelo (todas enfileiradas nas mesmas filas FM/MLX seriais, então o
  paralelismo real é limitado pelo `GenerationOrchestrator`, mas cada
  `Task.detached` consome sua própria pilha de execução e mantém um
  `ModelContext` próprio vivo). `HYPOTHESIS`: baixo risco na prática (o
  gargalo das filas seriais naturalmente limita o quanto isso pode crescer),
  mas não vi nenhum limite superior de tópicos gerando em paralelo. Não
  recomendo adicionar um limite sem antes confirmar que isso é um problema
  real em uso — seria complexidade adicionada sem evidência de necessidade.

---

## 7. Gargalos de UI percebida

### 7.1 CONFIRMED — loading binário, sem granularidade

`TopicStudyView.loadingState` (`TopicStudyView.swift:77-98`) só distingue
dois estados: "baixando/carregando modelo MLX" (via `ModelDownloadView`,
que tem progresso real — bom) ou um spinner genérico com o texto **fixo**
"Gerando conteúdo de '\(topicName)'..." — sem nenhuma indicação de qual das
5-6 chamadas em andamento (resumo, quiz fácil, quiz médio, crítica, formatação
do exemplo) está rodando. Para um usuário, "Gerando conteúdo..." por
potencialmente dezenas de segundos sem qualquer mudança visual parece
travado, mesmo que o app esteja progredindo normalmente.

O código já tem tudo que precisa para melhorar isso sem custo de latência
real: `TopicRepository.timed` (`TopicRepository.swift:262-266`) já loga o
nome e a duração de cada etapa no console — só falta expor esse mesmo sinal
(qual etapa está rodando agora) como estado observável para a UI.

### 7.2 CONFIRMED — nada é mostrado progressivamente

`TopicStudyView.load()` (`TopicStudyView.swift:116-133`) só sai do estado
`isLoading` quando `fetchOrCreate` retorna **tudo** (resumo + quiz +
exemplo, já persistidos). Não há renderização incremental — por exemplo,
mostrar o resumo assim que ele estiver pronto (a chamada mais rápida,
provavelmente) enquanto o exemplo de código (a mais lenta, por causa do
MLX) ainda está em andamento. Isso é puramente de percepção: o tempo total
não muda, mas o usuário veria conteúdo útil muito mais cedo.

### 7.3 CONFIRMED — streaming existe no MLX mas não chega à UI

`MLXService.generate` consome o stream inteiro internamente
(`MLXService.swift:330-335`, loop que acumula em `outputText` antes de
retornar) — o texto do MLX nunca é exibido incrementalmente, e faz sentido
que não seja (é um rascunho interno, reformatado depois pelo FM antes de
virar conteúdo final; mostrar o rascunho cru ao usuário seria confuso e
incorreto). Não é um bug — é registrar que "usar streaming" não se aplica
diretamente ao MLX neste fluxo específico, porque o output do MLX nunca é
o produto final.
- **Diferente para Foundation Models**: se a versão do framework em uso
  suportar geração incremental de saída estruturada (structured streaming),
  isso poderia mostrar o resumo/exemplo "aparecendo" progressivamente em vez
  de tudo de uma vez. Não encontrei uso de API de streaming do
  `LanguageModelSession` no código (`session.respond(to:generating:options:)`
  é sempre chamado de forma não-streaming). Classifico como **HYPOTHESIS**:
  não confirmei nesta auditoria se a versão do framework alvo do projeto
  expõe uma API de streaming para saída estruturada com schema — precisa
  verificar a documentação/versão do SDK antes de prometer isso.

### 7.4 O que já está bem feito em UI percebida

- Download do modelo com progresso real, velocidade e ETA
  (`ModelDownloadView.swift`, `MLXService.recordProgress`,
  `MLXService.swift:169-205`) — isso já resolve o problema descrito em
  `PLANOS_DE_MELHORIA.md §6` ("download parece travado"), com média móvel
  para suavizar a leitura (linha 199-203). Bom trabalho já feito aqui.
- Banner compacto de download embutido no artigo (`TopicStudyView.swift:180-183`)
  em vez de bloquear a tela inteira quando o download acontece durante
  retomada de pool incompleto.
- Pill "crescendo em background" (`TopicStudyView.swift:157-164`) já dá
  algum feedback de que mais conteúdo está a caminho, sem bloquear a
  interação.

### 7.5 Recomendação de perceived performance (sem mudar o tempo real)

Ver Quick Win §12.5 e Fase 5 (§14) — expor um `@Published`-like "etapa
atual" no `StudyGenerator`/`TopicRepository` (ex.: enum `GenerationStage`)
e mostrar isso como texto dinâmico no lugar do spinner fixo custa pouco e
muda a percepção de "travado" para "progredindo".

---

## 8. Análise de qualidade das respostas

### 8.1 A correção que mais custou performance foi também a que resolveu bugs reais

O padrão "crítica técnica (texto livre) → formatação aplicando a crítica"
(`critiqueCodeDraft` + `formatCodeExample`/`formatCodeAnalysisQuestion`) foi
adicionado especificamente depois de bugs reais vistos em teste ao vivo,
documentados nos comentários do próprio código
(`StudyGenerator.swift:286-297`: `.navigationDestination(for: 1)` em vez de
`for: Int.self`, `ContentView(selection:)` com parâmetro inexistente,
`@StateObject` usado em tipo de valor). Uma tentativa anterior de fazer
"criticar e corrigir" numa única chamada não pegava esses erros
(comentário explícito: "sobrecarrega o modelo pequeno"). Ou seja: **essa
complexidade não é acidental nem overengineering — foi adicionada com
evidência de que a alternativa mais simples não funcionava.**

Isso cria uma tensão real que este relatório precisa deixar explícita: a
correção que melhorou a qualidade (2 passadas) é, ao mesmo tempo, o maior
contribuinte de latência identificado (§2.1-2.3). A recomendação de fase
(§14, Fase 2) não é "reverter a crítica" — é buscar formas de manter o
ganho de qualidade sem pagar 2-3 chamadas FM sequenciais toda vez (ex.:
cachear a crítica quando o rascunho MLX não muda, ou tornar a crítica
condicional a uma heurística barata primeiro).

### 8.2 Verificações determinísticas já implementadas (bom)

- `QuestionValidator` (sanitização + validação, nunca chama modelo) roda em
  **toda** questão antes de persistir — remove resíduos de formatação,
  rejeita fallback genérico, rejeita opções duplicadas/vazias, valida índice
  da resposta correta.
- `StudyGenerator.looksTruncated` (`StudyGenerator.swift:479-509`) — checa
  chaves/parênteses balanceados e finais de linha suspeitos antes de aceitar
  código gerado, com 1 retry pedindo versão mais curta.
- `commonCodeMistakesChecklist` (`StudyGenerator.swift:618-628`) — lista
  fixa de erros reais observados em teste, injetada tanto na crítica quanto
  na formatação, reduzindo a chance de repetir os mesmos erros.

### 8.3 Riscos de qualidade ainda abertos

- `formatHardQuestion` não passa pelo mesmo `looksTruncated`/retry-curto que
  o exemplo de código e a análise de código têm — só a validação genérica
  de "enunciado não termina cortado" do `QuestionValidator.looksCutOff`
  (`QuestionValidator.swift:97-103`), que é uma heurística mais fraca (não
  olha pra estrutura de opções truncadas, só pro texto da pergunta). Some
  isso à ausência de orçamento de token explícito (§3) e questões difíceis
  são, pela minha leitura, o tipo de conteúdo com **menos** proteção de
  qualidade do projeto, apesar de serem geradas pelo pipeline mais
  complexo (MLX→FM). Ver Quick Win §12.1.
- Sem controle explícito de `sampling`/temperatura nas chamadas de
  Foundation Models (`GenerationOptions` só define
  `maximumResponseTokens` em todo o arquivo) — usa o default do framework.
  `HYPOTHESIS`: não sei se o comportamento default é bom o suficiente para
  todas as tarefas (resumo pede consistência/factualidade; quiz "difícil"
  poderia se beneficiar de mais diversidade). Precisa experimentar com
  `GenerationOptions(sampling:)` se a API expuser isso nesta versão do
  framework — não assumir, verificar a assinatura disponível primeiro.
- MLX usa `temperature: 0.3, repetitionPenalty: 1.1`
  (`MLXService.swift:322`) para **todo** uso (rascunho de exemplo de
  código, rascunho de quiz difícil, rascunho de análise) — parâmetros
  fixos, sem diferenciação por tarefa. Não há evidência de que isso seja
  ruim (0.3 é uma temperatura baixa/conservadora, razoável para
  rascunhos técnicos que serão revisados depois), mas também não há
  registro de terem sido testados por tarefa.
- Sem testes automatizados (ver §11.3) para `QuestionValidator`,
  `hybridSearch`, `looksTruncated` — funções puras, fáceis de testar, que
  hoje só são validadas manualmente via as telas de debug
  (`RAGTestView`, `TopicRepositoryTestView`). Regressões como as descritas
  em `PLANO_V5.md` (bugs vistos "ao vivo") são exatamente o tipo de coisa
  que um punhado de testes unitários preveniria de voltar.

### 8.4 Oportunidades que reduzem tokens/latência E aumentam qualidade ao mesmo tempo

Priorizadas por ordem de impacto esperado:

1. **Aplicar o mesmo orçamento explícito + retry-curto de
   `formatCodeExample`/`formatCodeAnalysisQuestion` para `formatHardQuestion`**
   — mais tokens de "espaço de manobra" pro modelo não truncar, e detecção
   de truncamento consistente. Reduz regenerações desnecessárias
   disparadas pelo `QuestionValidator` quando a causa raiz é orçamento
   insuficiente, não conteúdo ruim.
2. **Batching da formatação FM** (§2.3) — menos chamadas = menos
   `instructions` repetidas = menos tokens de overhead fixo por item,
   além de menos latência.
3. **Cache de crítica por rascunho** (§8.1) — se o mesmo rascunho MLX nunca
   muda entre um `formatCodeExample` e um eventual retry externo, cachear a
   crítica evita reprocessar; impacto real só se retries externos
   (`fetchOrCreate` chamado de novo pro mesmo tópico com pool quebrado)
   forem comuns — `Needs runtime measurement` de quão frequente isso é.

---

## 9. Instrumentação

### 9.1 O que já existe hoje (não começar do zero)

- `MLXService.performLoad`: loga duração de carga do modelo
  (`MLXService.swift:162`).
- `MLXService.generate`: loga duração + "chars/s" (impreciso, ver §2.8)
  (`MLXService.swift:337-339`).
- `MLXService.generateQuestionDrafts`: loga quantos itens foram pedidos vs.
  obtidos no split do lote (`MLXService.swift:235`).
- `TopicRepository.timed`: loga duração de cada etapa nomeada do caminho
  síncrono — resumo, quiz fácil, quiz médio, exemplo de código
  (`TopicRepository.swift:212-229,262-266`).
- `TopicRepository.generateAndPersist`: loga o tempo total até a tela ser
  liberada (`TopicRepository.swift:245`).
- `DocumentIndex`: loga cache HIT/MISS de embeddings e tamanho do cache
  salvo (`DocumentIndex.swift:83,93,306`).
- `QuestionValidator`: loga toda vez que uma questão é descartada ou
  regenerada.

Ou seja: **já existe uma base de logging de duração por etapa** — falta (a)
tempos de sub-etapas dentro de `generateCodeExample` (crítica vs. formatação
separadas) e do crescimento em background, (b) contagem real de tokens
(entrada e saída), e (c) agregação/exportação disso num formato que dê pra
tabular (hoje é só `print`, sem persistência nem métricas agregadas).

### 9.2 O que falta, e onde adicionar

| Métrica pedida | Onde adicionar | Como |
|---|---|---|
| Total request latency | `TopicRepository.generateAndPersist` (já parcialmente lá) | Já existe em `TopicRepository.swift:245` — só falta persistir/agregar em vez de só `print` |
| Retrieval latency | `StudyGenerator.retrieveContext` (`StudyGenerator.swift:89`) | Envolver com `Self.timed` (já existe o helper em `TopicRepository`, mover para um util compartilhado) |
| Embedding latency | `DocumentIndex.buildIndex` (`DocumentIndex.swift:71`) | Medir o loop de `service.generateEmbeddings` (linha 96) separado do resto |
| Prompt construction latency | `StudyGenerator` (cada função que monta `prompt`/`mlxPrompt`) | Geralmente desprezível (string interpolation), mas medir se quiser confirmar |
| Model loading latency | `MLXService.performLoad` | Já existe (`MLXService.swift:162`) |
| Prompt evaluation latency (TTFT) | `MLXService.generate` (`MLXService.swift:325-335`) | Marcar `Date()` antes de `MLXLMCommon.generate` e no primeiro `chunk` não-nulo recebido no loop `for try await generation in stream` |
| Generation latency (decode) | mesmo local | TTFT até o último chunk |
| Tokens gerados | `MLXService.generate` + toda chamada FM | MLX: contar tokens reais via tokenizer do `context.processor`, não `outputText.count`. FM: verificar se `LanguageModelSession`/`response` expõe contagem de tokens nesta versão do framework — se não expuser, aproximar por tokenizador local só para fins de diagnóstico |
| Tokens/s | idem | `tokens / elapsed`, não `chars / elapsed` |
| Input token count | Toda chamada FM/MLX | Contar tokens do prompt final antes de enviar — para MLX, `context.processor` tem acesso ao tokenizer; para FM, mesma ressalva acima |
| Output token count | idem | Ver acima |
| Número de chunks recuperados | `StudyGenerator.retrieveContext` | Já é derivável (`exact.prefix(topK).count`) — só logar |
| Tamanho do contexto (chars/tokens) | mesmo local | `context.count` já é trivial; tokens precisa do tokenizer |
| Memória utilizada | `MLXService.performLoad`/`generate` | `ProcessInfo.processInfo.physicalMemory` não ajuda (é o total do sistema); usar `mach_task_basic_info` (footprint do processo) antes/depois de carregar o modelo, ou medir via Instruments (Allocations/VM Tracker) em vez de instrumentar em código — mais confiável para memória wired de GPU |

### 9.3 Formato recomendado

Como o app já loga com `print` e emojis como prefixo visual (padrão
consistente no código atual — `⏱️`, `🟢`, `🟠`, `⚠️`, `❌`), a forma de
menor atrito é manter esse padrão para logs de desenvolvimento, mas
**adicionalmente** acumular as métricas numéricas num struct simples (ex.
`GenerationMetrics`) que a instrumentação de Phase 0 grava (em memória, ou
num arquivo JSON local) para permitir comparar "antes vs. depois" de cada
otimização de forma tabulável — hoje isso exigiria reler o console
manualmente, o que não escala para comparar várias rodadas.

---

## 10. Classificação consolidada (CONFIRMED / HIGHLY LIKELY / HYPOTHESIS)

Resumo cruzado dos achados das seções 2-9 (detalhes e citações estão nas
seções correspondentes):

**CONFIRMED** (o código mostra o fato diretamente):
- Exemplo de código sempre tenta MLX no caminho bloqueante, para todo tópico (§2.1)
- Fila FM global única serializa toda chamada FM do app (§2.2)
- Formatação FM pós-lote MLX não é batched, N chamadas em vez de 1 (§2.3)
- Nenhum KV cache/prompt cache reutilizado entre chamadas MLX (§2.4)
- Chat template montado manualmente como string (§2.5)
- Nenhum tuning de `MLX.GPU.set(cacheLimit:)` (§2.6)
- Dedup de carga de modelo/índice/geração já funciona corretamente (§2.7, §5)
- `formatHardQuestion` sem orçamento de token explícito, diferente do resto do arquivo (§3, §8.3)
- Métrica "chars/s" não é tokens/s real (§2.8)
- `retrieveContext` recalculado sem necessidade em 2 pontos (barato, mas redundante) (§5.1)
- Caminho de produção usa filtro exato, não embeddings — hybridSearch só roda em debug/fallback (§4, §16.1)
- `ensureReady()` (embeddings) bloqueia entrada na tela mesmo quando o caminho de geração não precisa de embedding (§4)
- Loading da UI é binário, sem granularidade de etapa (§7.1)
- Nada é renderizado progressivamente — tudo ou nada (§7.2)
- Stream do MLX é consumido internamente, nunca chega à UI (mas por bom motivo — não é produto final) (§7.3)
- Geração especulativa do pool completo acontece na criação do tópico, não só sob demanda (§3.1, §16.3)

**HIGHLY LIKELY** (evidência forte, sem medição):
- Prefill repetido nas 3 chamadas MLX por tópico custa tempo real (§2.4)
- A cadeia MLX→crítica→formatação é a maior fonte de latência percebida na abertura de um tópico novo (§2.1, consequência direta dos fatos CONFIRMED acima)

**HYPOTHESIS** (precisa medir — método descrito na seção):
- Quanto exatamente o prefill repetido custa vs. a geração em si (§2.4, §2.8)
- Se Foundation Models aceitaria 2+ sessões concorrentes sem erro (§6)
- Se `MLX.GPU.set(cacheLimit:)` ajudaria neste hardware específico (§2.6)
- Se a 1ª inferência MLX após carregar é mais lenta que as seguintes (compilação de grafo) (§2.9)
- Custo real de tokens de entrada por sessão nova do Foundation Models (§3.1, §3.2)
- Se a versão atual do framework Foundation Models expõe streaming de saída estruturada (§7.3)
- Se `GenerationOptions(sampling:)` está disponível e ajudaria a qualidade do quiz difícil (§8.3)

---

## 11. Problemas arquiteturais (além de performance)

Sigo a regra pedida: só listo o que tem benefício concreto, não estética.

### 11.1 Duplicação de responsabilidade entre `formatHardQuestion` e `formatCodeAnalysisQuestion`

Os dois métodos (`StudyGenerator.swift:641-700` e `767-883`) têm estrutura
quase idêntica (sanitizar rascunho → construir fallback → checar
disponibilidade do modelo → montar instructions/prompt → loop de 3
tentativas com sleep de 2s → retornar fallback se tudo falhar), mas com
pequenas divergências que já causaram bugs (a ausência do orçamento
explícito em um dos dois, §3/§8.3, é exatamente esse tipo de divergência
por duplicação). Isso não é estética — é uma fonte real de inconsistência:
correções feitas num caminho não se propagam automaticamente para o outro
(o próprio histórico do projeto mostra isso acontecendo, `PLANO_V5.md §3`:
"faltava aqui o MESMO `looksTruncated` + retry-mais-curto que já existia em
`formatCodeExample`"). Uma função genérica parametrizada por schema
reduziria a chance da próxima correção esquecer um dos dois caminhos.
**Risco de não corrigir**: a cada novo ajuste de qualidade, alguém precisa
lembrar de replicar manualmente em 2-3 lugares — já aconteceu 2 vezes
segundo o histórico de commits.

### 11.2 `ContentView`, `RAGTestView`, `TopicRepositoryTestView` são telas de debug misturadas na navegação principal

`RootTabView.swift:13-27` expõe 4 abas, sendo 3 delas (`ContentView`,
`TopicRepositoryTestView`, `RAGTestView`) explicitamente descritas nos
próprios comentários dos arquivos como temporárias/de teste
("TEMPORÁRIA só para validar...", "Não é UI final", "Raiz temporária de
navegação enquanto o app é só telas de teste/debug" —
`RootTabView.swift:5-7`). Isso não é um problema de performance, mas é
código morto-em-produção real: essas 3 telas comparam >700 linhas
combinadas que não fazem parte da experiência final do produto (a que é
descrita em `GUIA_APRESENTACAO.md`), aumentam a superfície de manutenção, e
ficam sujeitas a quebrar silenciosamente se a API de `TopicRepository`/
`StudyGenerator` mudar (ninguém as vê rodar no fluxo real). Recomendo
decidir: (a) mover para um alvo de desenvolvimento separado (scheme
debug-only) ou (b) apagar de vez, já que o próprio comentário de
`RAGTestView.swift:9-10` já autoriza isso ("Depois que validar, pode apagar
essa view"). Benefício concreto: menos superfície pra manter, sem perda de
funcionalidade do produto real.

### 11.3 Ausência de testes automatizados

Não há alvo de teste (`XCTest`) no projeto — toda validação de regressão
(dedup de geração, truncamento, formato de resposta, scoring do RAG) é
manual, via as telas de debug do item 11.2. Funções como
`QuestionValidator.isValid`, `StudyGenerator.looksTruncated`,
`DocumentIndex.hybridSearch`/`lexicalOverlap` são **puras** (sem I/O, sem
modelo) e triviais de testar com XCTest — cobrem exatamente o tipo de bug
que o histórico do projeto mostra terem sido pegos manualmente, "ao vivo"
(`PLANO_V5.md`), depois de já estar em uso. Benefício concreto: pega
regressão antes de rodar o app, mais rápido que o ciclo atual de
"rodar → ver log → descobrir bug → corrigir → rodar de novo". Não é
sugestão estética — é testabilidade real de um código que já mostrou
propensão a esse tipo de bug recorrente.

### 11.4 Dupla chave de invalidação de cache (já citado em §4)

`DocumentIndex` invalida por hash de conteúdo; `StudyTopic` invalida por
`DatasetVersion.current` (string manual). Duas fontes de verdade para "o
dataset mudou" — funcionam hoje porque estão sincronizadas manualmente, mas
são um ponto de fragilidade de manutenção, não de performance.

### 11.5 O que **não** listo como problema (para deixar claro que não é ignorância, é avaliação)

- `GenerationOrchestrator` como actor singleton: é um singleton, mas
  resolve um problema real de coordenação global (2 recursos físicos
  compartilhados — 1 modelo MLX carregado, 1 acesso ao Foundation Models do
  sistema) — não é "singleton problemático", é o padrão certo para esse
  caso.
- `DocumentIndex.shared`/`MLXService.shared` como singletons: mesma
  justificativa — são recursos físicos únicos (um índice, um modelo
  carregado), não estado de conveniência.
- A complexidade de retry/degradação em `StudyGenerator.withDiagnostics`
  (`StudyGenerator.swift:133-175`): parece muita coisa, mas cada branch
  (contexto excedeu → reduz contexto; decodingFailure → 1 retry;
  rateLimited → espera e tenta de novo) corresponde a um erro real e
  documentado do `LanguageModelSession.GenerationError`, não a
  especulação. Não é overengineering.

---

## 12. Quick Wins

Ordenados por impacto esperado, decrescente.

### 12.1 Orçamento de token explícito + detecção de truncamento em `formatHardQuestion`

**Problema**: `formatHardQuestion` (`StudyGenerator.swift:687-693`) chama
`session.respond(to:generating:)` sem `options:`, ao contrário de toda
outra chamada estruturada do arquivo, e sem o mesmo `looksTruncated` +
retry-curto que `formatCodeExample`/`formatCodeAnalysisQuestion` têm.
**Arquivo(s)**: `StudyGenerator.swift:641-700`.
**Por que acontece**: a correção equivalente foi feita em
`formatCodeAnalysisQuestion` (comentário `StudyGenerator.swift:852-857`
documenta o próprio bug) mas não replicada no caminho irmão de quiz
difícil.
**Mudança proposta**: adicionar `GenerationOptions(maximumResponseTokens:)`
com valor calibrado (seguir o padrão de ~220-300 tokens de uma QuizQuestion
única, ver linha 606) e aplicar checagem de truncamento nos campos de texto
(`question`, `options`) antes de aceitar, com 1 retry pedindo resposta mais
curta, no mesmo padrão dos outros dois caminhos.
**Impacto esperado**: Medium — reduz truncamento silencioso e regenerações
disparadas pelo `QuestionValidator` por causa raiz evitável.
**Risco**: Low — é replicar um padrão já testado em produção em outro
caminho.
**Complexidade**: Small.

### 12.2 Passar `context` já calculado para `generateQuizBatch`(difícil)/`generateCodeAnalysisBatch` em vez de recalcular

**Problema**: essas duas funções chamam `retrieveContext` internamente
mesmo quando o chamador já tem o contexto calculado.
**Arquivo(s)**: `StudyGenerator.swift:526,711`; chamadores em
`TopicRepository.swift` (`growDifficulty`/`growCodeAnalysis` já recebem
`context:` como parâmetro e poderiam repassá-lo até o fim da cadeia sem
recomputar).
**Por que acontece**: a assinatura de `generateQuizBatch`/
`generateCodeAnalysisBatch` já recebe `context:` como parâmetro — a
recomputação interna do RAG (`ragContext`) é redundante com esse parâmetro
em alguns casos, mas não em todos (`generateQuizBatch` usa o `context:`
recebido pra formatação FM e recalcula `ragContext` separadamente só pro
MLX — checar se são o mesmo texto ou se há um motivo real pra manter
separado antes de unificar).
**Mudança proposta**: revisar se `context` (parâmetro) e `ragContext`
(recalculado) são sempre idênticos; se forem, eliminar o recálculo.
**Impacto esperado**: Low — o caminho exato é barato, o ganho é limpeza e
consistência, não velocidade perceptível.
**Risco**: Low.
**Complexidade**: Trivial.

### 12.3 `DocChunk.embedding` de `[Double]` para `[Float]`

**Problema**: embeddings armazenados como `[Double]` (8 bytes/dimensão) em
vez de `[Float]` (4 bytes/dimensão) — `DocChunk.swift:17`.
**Arquivo(s)**: `DocChunk.swift`, `DocumentIndex.swift` (cache
serializado/desserializado como `Codable`).
**Por que acontece**: `NLContextualEmbedding`/`NaturalLanguageEmbeddings`
provavelmente retorna `[Double]` nativamente (não confirmei a assinatura
exata do pacote — não tive acesso ao código-fonte dele neste ambiente);
`Needs runtime measurement/verificação de API` antes de assumir que a
conversão é trivial.
**Mudança proposta**: se a API permitir, converter para `Float` ao
persistir no `DocChunk`/cache — reduz pela metade o tamanho do cache em
disco e o footprint em memória do índice.
**Impacto esperado**: Low hoje (8 chunks); Medium se o dataset voltar a
crescer para 21+ tópicos (já aconteceu antes, segundo o histórico).
**Risco**: Low — precisão de `Float` é mais que suficiente para similaridade
de cosseno neste domínio.
**Complexidade**: Small (mudança de tipo + verificar compatibilidade com a
API do pacote de embeddings antes).

### 12.4 Desacoplar "chunks disponíveis" (instantâneo) de "embeddings prontos" (assíncrono) no carregamento da tela

**Problema**: `TopicStudyView.load()` aguarda `documentIndex.ensureReady()`
(que inclui a etapa de embedding) antes de sequer tentar
`chunks(forExactTopic:)`, que não precisa de embedding nenhum.
**Arquivo(s)**: `TopicStudyView.swift:121-127`, `DocumentIndex.swift`.
**Por que acontece**: `DocumentIndex.chunks` só é populado dentro de
`buildIndex`, junto com o embedding — não há uma via de acesso aos dados
crus (`topic`/`text`, sem embedding) antes disso.
**Mudança proposta**: expor os `rawChunks` (já estático, já disponível
sincronamente via `PlaceholderDocs.rawChunks`) diretamente para o caminho
exato, sem depender de `ensureReady()`; manter `ensureReady()` só como
pré-requisito do caminho fuzzy (`hybridSearch`).
**Impacto esperado**: Low hoje (cache HIT de embeddings já é rápido);
Medium em cache MISS (1ª execução após mudança de dataset) ou se o
`NLContextualEmbedding` demorar mais para inicializar em hardware mais
lento — remove uma dependência desnecessária do caminho quente.
**Risco**: Low.
**Complexidade**: Small.

### 12.5 Estado de "etapa atual" observável durante a geração

**Problema**: UI mostra só um spinner + texto fixo durante toda a geração
(§7.1).
**Arquivo(s)**: `TopicRepository.swift` (onde `Self.timed` já delimita cada
etapa), `TopicStudyView.swift:77-98`.
**Por que acontece**: não existe hoje um canal observável entre
`TopicRepository`/`StudyGenerator` e a `View` para o "nome da etapa atual"
— só `print` no console.
**Mudança proposta**: adicionar um `enum GenerationStage` observável
(`@Observable` já é usado no projeto, mesmo padrão de
`MLXService.loadState`) atualizado nos mesmos pontos onde `Self.timed`
já delimita etapas; `TopicStudyView` lê esse estado no lugar do texto fixo.
**Impacto esperado**: High em percepção (não muda o tempo real, muda a
sensação de progresso) — reusa instrumentação que já existe.
**Risco**: Low.
**Complexidade**: Small.

### 12.6 Batching da formatação FM pós-lote MLX (quiz difícil e análise de código)

**Problema**: N chamadas FM sequenciais (uma por rascunho) em vez de 1
chamada pedindo N formatações (§2.3).
**Arquivo(s)**: `StudyGenerator.swift:548-552` (quiz difícil),
`StudyGenerator.swift:739-741` (análise de código); schemas já existem
(`QuizQuestionBatch`, `CodeAnalysisBatch` em `StudyModels.swift:75-77,97-100`).
**Por que acontece**: o batching foi aplicado no lado MLX (rascunhos) mas
não replicado no lado FM (formatação) quando o pipeline MLX→FM foi
introduzido.
**Mudança proposta**: enviar todos os rascunhos de um lote numa única
chamada FM, pedindo um array de questões formatadas de volta (usando os
schemas de batch já existentes); ajustar orçamento de token proporcionalmente
(como já é feito em `generateQuizBatch` fácil/médio, linha 606).
**Impacto esperado**: High — reduz de até 12 chamadas FM (análise de
código) para 2 por tópico; menos overhead de `instructions` repetidas, menos
tempo total na fila FM serial.
**Risco**: Medium — lotes maiores em uma única chamada estruturada podem
sofrer o mesmo problema de truncamento que motivou reduzir de "tudo numa
chamada" para "lotes pequenos" originalmente (`StudyModels.swift:9-12`
já documenta essa lição); precisa de orçamento de token generoso e
validação cuidadosa antes de assumir que funciona tão bem quanto o batch de
quiz fácil/médio (que já usa esse padrão com sucesso, mas para um schema
mais simples que não inclui crítica prévia).
**Complexidade**: Medium.

### 12.7 Tornar o exemplo de código independente de MLX no caminho síncrono (ver também §14 Fase 1/2 e §16.2)

**Problema**: todo tópico novo paga carga do modelo MLX + 2-3 chamadas FM
sequenciais só para o exemplo de código, no caminho que bloqueia a tela
(§2.1) — a peça de maior impacto deste relatório.
**Arquivo(s)**: `StudyGenerator.swift:239-280` (`generateCodeExample`),
`TopicRepository.swift:208-210` (onde é chamado como `async let`).
**Por que acontece**: decisão de produto para melhorar qualidade do
exemplo de código (ver §8.1) — não é um bug, é uma troca consciente que
talvez precise ser revisitada à luz do custo real medido.
**Mudança proposta**: não decido aqui qual caminho tomar (ver §16.2 para as
opções, cada uma com trade-off diferente) — mas independentemente da opção
escolhida, o primeiro passo barato é medir (Phase 0) quanto tempo
`generateCodeExample` via MLX→FM realmente adiciona vs.
`generateCodeExampleFromScratch` (FM puro, já existe como fallback no
código) para o MESMO tópico, e comparar a qualidade percebida das duas
saídas.
**Impacto esperado**: Very High se a medição confirmar que MLX→FM domina o
tempo de abertura de tópico novo (que é o `HIGHLY LIKELY` da §10).
**Risco**: depende da opção escolhida — trocar de motor tem risco de
qualidade (é exatamente o problema que o 2-pass resolveu, §8.1); mover para
background tem risco de a tela mostrar um exemplo de código placeholder por
mais tempo.
**Complexidade**: Medium a Large, dependendo da opção.

---

## 13. Bottleneck Ranking

| # | Gargalo | Evidência | Impacto | Confiança | Complexidade da correção |
|---|---|---|---|---|---|
| 1 | Exemplo de código força carga do modelo MLX 7B + 2-3 chamadas FM sequenciais, no caminho bloqueante, para TODO tópico novo | `StudyGenerator.swift:239-280`, `TopicRepository.swift:208-210` | Very High | HIGHLY LIKELY (mecanismo CONFIRMED; magnitude precisa medição) | Medium-Large |
| 2 | Fila FM global serial processa ~23 chamadas por tópico novo (síncronas + background), sem batching na formatação pós-MLX | `GenerationOrchestrator.swift:141-157`, `StudyGenerator.swift:548-552,739-741` | High | CONFIRMED (contagem de chamadas); impacto em tempo real precisa medição | Medium |
| 3 | Nenhum KV cache/prompt cache reaproveitado entre as 3 chamadas MLX de um mesmo tópico (contexto RAG quase idêntico reenviado 3x) | `MLXService.swift:316-342` (ausência do mecanismo) | Medium-High | HIGHLY LIKELY | Medium (depende de API do MLXLMCommon 2.29.1) |
| 4 | UI sem granularidade de progresso durante geração — percepção de "travado" independente do tempo real | `TopicStudyView.swift:77-98` | High (percepção) | CONFIRMED | Small |
| 5 | Pool completo (24 questões) gerado especulativamente na criação do tópico, além do top-up pós-sessão | `TopicRepository.swift:252-256` | Medium (tokens/GPU/bateria desperdiçados em conteúdo não visto) | CONFIRMED (mecanismo); frequência de não-uso precisa medição de produto | Medium (decisão de produto, não só técnica) |
| 6 | `formatHardQuestion` sem orçamento de token/detecção de truncamento — risco de qualidade específico do quiz difícil | `StudyGenerator.swift:687-693` | Medium (qualidade, pode gerar regenerações evitáveis) | CONFIRMED | Small |
| 7 | Chat template MLX manual (string), sem usar template nativo do tokenizer | `MLXService.swift:321` | Low-Medium (risco de manutenção futura, não de performance atual) | CONFIRMED (fato); impacto HYPOTHESIS | Small-Medium |
| 8 | Ausência de tuning de `MLX.GPU.set(cacheLimit:)` | grep vazio no projeto | Unknown | HYPOTHESIS | Small (testar) |
| 9 | `ensureReady()` (embeddings) bloqueia entrada na tela mesmo quando o caminho de geração não usa embedding | `TopicStudyView.swift:121-127` | Low hoje (cache HIT rápido) | CONFIRMED (mecanismo); impacto Low na escala atual | Small |
| 10 | Sem instrumentação de tokens reais (só chars/tempo) — impede medir com precisão os itens 1-3 acima | `MLXService.swift:337-339` e ausência equivalente nas chamadas FM | Indireto (bloqueia diagnóstico preciso) | CONFIRMED | Small-Medium |

---

## 14. Plano de otimização por fases

> Ordem: medir → identificar → simplificar → otimizar. Nenhuma fase depois
> da 0 deveria começar sem os números da Fase 0 confirmando (ou refutando)
> as hipóteses listadas em §10.

### Phase 0 — Measurement

- [ ] Adicionar contagem real de tokens (entrada e saída) nas chamadas MLX,
      usando o tokenizer já disponível via `context.processor`
      (`MLXService.swift:325-335`), em vez de `outputText.count` (chars).
      **Arquivos**: `MLXService.swift`. **Problema**: métrica atual não é
      tokens/s. **Motivo**: sem isso, não dá pra confirmar §2.4/§2.8 nem
      calibrar `maxTokens` com precisão. **Critério de sucesso**: log mostra
      tokens/s real, comparável entre chamadas.
- [ ] Separar TTFT (time to first token) de tempo total de geração no MLX.
      **Arquivos**: `MLXService.swift:325-335`. **Motivo**: distinguir
      custo de prefill (aponta pra prompt caching) de custo de decode
      (aponta pra tamanho/quantização do modelo, já resolvido). **Critério
      de sucesso**: dois números logados por chamada MLX, TTFT e
      tokens/s pós-primeiro-token.
- [ ] Instrumentar `critiqueCodeDraft` e `formatCodeExample` (e os
      equivalentes de análise de código) separadamente com `Self.timed`
      (hoje só a chamada externa `generateCodeExample` tem tempo agregado
      via `TopicRepository.swift:208`). **Arquivos**: `StudyGenerator.swift`.
      **Motivo**: confirmar/refutar que a cadeia de 2-3 chamadas FM (não só
      a carga do MLX) domina o tempo do achado #1 do ranking. **Critério de
      sucesso**: log mostra duração de MLX-draft, crítica-FM e
      formatação-FM como 3 números separados.
- [ ] Rodar o benchmark de §15 (cold start, warm reuse, cache HIT) e
      preencher a tabela "Before".
- [ ] Testar concorrência real do Foundation Models: disparar 2 sessões
      `LanguageModelSession.respond` simultâneas manualmente numa build de
      debug fora do `GenerationOrchestrator`, ver se
      `concurrentRequests`/`rateLimited` disparam. **Motivo**: valida ou
      invalida a hipótese do §6 sobre profundidade de fila > 1.
      **Critério de sucesso**: resposta objetiva sim/não, documentada.
- [ ] Medir `MLX.GPU.set(cacheLimit:)` com 2-3 valores diferentes no
      hardware alvo, comparando tokens/s. **Motivo**: §2.6/§10. **Critério
      de sucesso**: tabela valor→tokens/s, decisão do valor final baseada
      nisso, não em achismo.

### Phase 1 — Critical Performance Fixes (alto impacto, baixo/médio risco)

- [ ] **Quick Win §12.1**: orçamento de token explícito + retry-curto em
      `formatHardQuestion`. **Arquivos**: `StudyGenerator.swift:641-700`.
      **Problema**: inconsistência com o resto do arquivo, risco de
      truncamento silencioso. **Alteração**: replicar o padrão de
      `formatCodeAnalysisQuestion`. **Motivo**: qualidade + reduz
      regenerações evitáveis. **Impacto esperado**: Medium. **Risco**: Low.
      **Como testar**: gerar quiz difícil para os 3 tópicos do dataset
      atual, inspecionar se alguma pergunta/opção sai cortada antes e
      depois. **Critério de sucesso**: zero truncamento observado em 20+
      gerações de teste.
- [ ] **Quick Win §12.5**: estado de "etapa atual" observável na UI.
      **Arquivos**: `TopicRepository.swift`, `StudyGenerator.swift`,
      `TopicStudyView.swift:77-98`. **Problema**: §7.1. **Alteração**:
      enum `GenerationStage` observável. **Motivo**: perceived performance
      sem custo de latência real. **Impacto esperado**: High (percepção).
      **Risco**: Low. **Como testar**: abrir um tópico novo e observar a
      tela mudar de texto conforme cada etapa progride (comparar com os
      logs `⏱️` do console, que já existem, para confirmar que bate).
      **Critério de sucesso**: usuário vê pelo menos 3 estados distintos
      durante uma geração de tópico novo.
- [ ] **Quick Win §12.6**: batching da formatação FM pós-lote MLX (quiz
      difícil e análise de código). **Arquivos**: `StudyGenerator.swift:548-552,739-741`,
      usando `QuizQuestionBatch`/`CodeAnalysisBatch` já existentes em
      `StudyModels.swift`. **Problema**: §2.3. **Alteração**: 1 chamada FM
      por lote em vez de N. **Motivo**: reduz de até 18 para ~4 chamadas FM
      de background por tópico. **Impacto esperado**: High. **Risco**:
      Medium (lotes estruturados grandes podem truncar — testar com
      orçamento generoso e o `looksTruncated` já existente). **Como
      testar**: gerar o pool completo de um tópico novo, comparar tempo
      total do crescimento em background antes/depois, e taxa de rejeição
      do `QuestionValidator` antes/depois (não deveria piorar). **Critério
      de sucesso**: tempo de crescimento em background reduz sem aumentar a
      taxa de rejeição do validador.

### Phase 2 — MLX Optimization

- [ ] **Decisão de produto informada pela Fase 0**: revisar se
      `generateCodeExample` deveria continuar tentando MLX no caminho
      bloqueante para TODO tópico (ver §16.2 para as opções concretas).
      **Arquivos**: `StudyGenerator.swift:239-280`,
      `TopicRepository.swift:208-210`. **Problema**: achado #1 do ranking.
      **Alteração**: depende da opção escolhida em §16.2 — não prescrevo
      uma única resposta aqui, é uma decisão que precisa dos números da
      Fase 0. **Motivo**: maior impacto identificado nesta auditoria.
      **Impacto esperado**: Very High. **Risco**: depende da opção
      (qualidade vs. latência). **Como testar**: comparar tempo de abertura
      de tópico novo e qualidade do exemplo de código (revisão manual,
      comparando com os bugs documentados em `PLANO_V5.md`) entre a opção
      atual e a nova. **Critério de sucesso**: definido junto com a escolha
      da opção (ex.: "reduzir tempo de abertura em X% sem reintroduzir os
      bugs de API inventada que motivaram o 2-pass").
- [ ] Investigar e, se viável, implementar reuso de prompt/KV cache do
      `MLXLMCommon` para o prefixo comum (system + contexto RAG) entre as
      chamadas MLX de um mesmo tópico. **Arquivos**: `MLXService.swift:316-342`.
      **Problema**: §2.4. **Motivo**: elimina prefill repetido. **Impacto
      esperado**: Medium-High (depende da Fase 0). **Risco**: Medium —
      depende de quão bem documentada/estável é essa API na versão
      2.29.1 do `mlx-swift-examples`. **Como testar**: comparar TTFT (já
      instrumentado na Fase 0) das chamadas MLX 2ª e 3ª de um mesmo tópico
      antes/depois. **Critério de sucesso**: TTFT da 2ª/3ª chamada MLX do
      mesmo tópico cai em relação à 1ª.
- [ ] Aplicar o valor de `MLX.GPU.set(cacheLimit:)` decidido na Fase 0.
      **Arquivos**: `MLXService.swift` (provavelmente perto de
      `loadModel`/`performLoad`). **Motivo**: §2.6. **Impacto esperado**:
      depende da medição. **Risco**: Low (é um parâmetro reversível).
      **Como testar**: já feito na Fase 0. **Critério de sucesso**: já
      definido na Fase 0.
- [ ] Migrar o chat template manual para a API de template do tokenizer
      (se `MLXLMCommon`/`swift-transformers` expuser uma). **Arquivos**:
      `MLXService.swift:321`. **Motivo**: §2.5, robustez a troca de modelo.
      **Impacto esperado**: Low-Medium (mais robustez que velocidade).
      **Risco**: Medium — precisa confirmar que o output tokenizado é
      idêntico ao formato manual atual antes de trocar (regressão de
      qualidade seria pior que o ganho). **Como testar**: comparar a saída
      de geração para os mesmos prompts, manual vs. template da API, byte a
      byte no prompt tokenizado se possível. **Critério de sucesso**: sem
      regressão de qualidade observável, tokenização documentada como
      correta pela biblioteca em vez de mantida à mão.

### Phase 3 — RAG Optimization

- [ ] Decidir (não só documentar) se o `hybridSearch`/embeddings continuam
      necessários no caminho principal, dado que a produção usa
      `chunks(forExactTopic:)` (ver §16.1). **Arquivos**:
      `DocumentIndex.swift`, `StudyGenerator.swift:89-96`. **Problema**:
      complexidade mantida (busca híbrida calibrada, stopwords, threshold
      adaptativo) para um caminho que só roda em debug/fallback hoje.
      **Alteração**: manter se houver plano concreto de voltar a expandir o
      dataset e reintroduzir busca livre; caso contrário, considerar
      simplificar. **Motivo**: §17 (simplificação > otimização). **Impacto
      esperado**: Low performance, Medium manutenção. **Risco**: Low se a
      decisão for "manter" (é reversível manter código funcionando); Medium
      se for "remover" (perde capacidade que pode ser necessária se o
      dataset crescer de novo). **Como testar**: N/A (decisão de produto).
      **Critério de sucesso**: decisão documentada com o trade-off
      explícito, não deixada implícita.
- [ ] Desacoplar disponibilidade de `chunks` (dados crus) de
      `ensureReady()` (embeddings) — Quick Win §12.4. **Arquivos**:
      `TopicStudyView.swift:121-127`, `DocumentIndex.swift`. **Já descrito
      em §12.4** com problema/motivo/impacto/risco.
- [ ] Se o dataset crescer de volta (histórico mostra que já foi 21
      tópicos), paralelizar a indexação de embeddings em cache MISS —
      **mas só depois de confirmar thread-safety do
      `NaturalLanguageEmbeddings`/`NLContextualEmbedding`** (não presumir).
      **Arquivos**: `DocumentIndex.swift:94-98`. **Motivo**: §4 (Retrieval
      Performance). **Impacto esperado**: Low na escala atual (3 tópicos),
      Medium se voltar a 21+. **Risco**: Medium se a lib não for
      thread-safe (corrupção silenciosa de embeddings) — **validar
      primeiro**. **Como testar**: rodar indexação paralela em build de
      debug com o dataset de 21 tópicos (recuperável do histórico do git,
      conforme `PlaceholderDocs.swift:8-17`) e comparar embeddings
      resultantes com a versão sequencial (deveriam ser idênticos ou
      equivalentes numericamente). **Critério de sucesso**: embeddings
      idênticos entre versão sequencial e paralela, tempo de indexação
      reduzido.
- [ ] Converter `DocChunk.embedding` para `[Float]` — Quick Win §12.3, já
      descrito.

### Phase 4 — Architecture

- [ ] Unificar `formatHardQuestion`/`formatCodeAnalysisQuestion` numa
      função genérica parametrizada por schema, reduzindo a duplicação
      descrita em §11.1. **Arquivos**: `StudyGenerator.swift:641-700,767-883`.
      **Problema**: §11.1. **Motivo**: evita que a próxima correção de
      qualidade esqueça de replicar num dos dois caminhos (já aconteceu 2x
      segundo o histórico). **Impacto esperado**: Medium (manutenção,
      confiabilidade). **Risco**: Medium — os dois caminhos têm schemas e
      fallbacks diferentes (`QuizQuestion` vs. `CodeAnalysisQuestion`,
      4 vs. 5 opções), a unificação precisa ser genérica o suficiente sem
      virar uma abstração forçada. **Como testar**: gerar quiz difícil e
      análise de código para os 3 tópicos, comparar saída antes/depois da
      refatoração (deveria ser comportamentalmente idêntica). **Critério de
      sucesso**: mesma saída (ou equivalente), uma função a menos para
      manter sincronizada.
- [ ] Mover `ContentView`, `RAGTestView`, `TopicRepositoryTestView` para
      fora da navegação de produção (scheme separado ou remoção, conforme
      §11.2). **Arquivos**: `RootTabView.swift`, os 3 arquivos de view
      citados. **Motivo**: §11.2. **Impacto esperado**: Low performance,
      Medium clareza de manutenção. **Risco**: Low — os próprios comentários
      do código já autorizam remover depois de validado. **Como testar**:
      confirmar que o fluxo real (`StudyHomeView` → `TopicStudyView`) não
      depende de nada exclusivo dessas telas. **Critério de sucesso**:
      `RootTabView` expõe só as telas de produto real.
- [ ] Adicionar um alvo de testes (`XCTest`) cobrindo
      `QuestionValidator`, `StudyGenerator.looksTruncated`,
      `DocumentIndex.hybridSearch`/`lexicalOverlap` — funções puras, sem
      dependência de modelo. **Arquivos**: novo target de teste + os
      arquivos citados. **Motivo**: §11.3. **Impacto esperado**: Medium
      (confiabilidade, pega regressão antes de "ao vivo"). **Risco**: Low.
      **Como testar**: os próprios testes são o teste. **Critério de
      sucesso**: cobertura dos casos de bug já documentados no histórico
      (`PLANO_V5.md`) como casos de teste de regressão.

### Phase 5 — Product Quality

- [ ] Renderização progressiva do artigo do tópico (mostrar resumo assim
      que pronto, sem esperar exemplo de código/quiz) — §7.2. **Arquivos**:
      `TopicStudyView.swift`, `TopicRepository.generateAndPersist`.
      **Problema**: §7.2. **Alteração**: persistir/expor o `StudyTopic`
      parcialmente conforme cada etapa completa, em vez de só no final.
      **Motivo**: perceived performance. **Impacto esperado**: High
      (percepção). **Risco**: Medium — precisa decidir o que fazer com o
      "resultado da sessão"/pool de quiz enquanto ainda incompleto (a UI já
      lida com pool incompleto via `isGeneratingPool`, pode reaproveitar
      esse padrão). **Como testar**: abrir tópico novo, cronometrar quando
      o resumo aparece vs. quando tudo aparece hoje. **Critério de
      sucesso**: resumo visível antes do tempo total de geração completar.
- [ ] Revisitar a decisão de geração especulativa do pool completo na
      criação (§16.3) — considerar reduzir ainda mais o "piso" inicial ou
      atrasar o crescimento da análise de código até o usuário abrir essa
      seção pela primeira vez. **Arquivos**: `TopicRepository.swift:252-256`.
      **Motivo**: §3.1, §16.3. **Impacto esperado**: Medium (menos
      trabalho de GPU/bateria gasto em conteúdo não visto). **Risco**:
      Medium — trade-off direto com "análise de código pronta na hora que o
      usuário clica". **Como testar**: medir, em uso real (ou simulado),
      qual fração das sessões abre "Análise de código"; se for baixa,
      justifica adiar a geração. **Critério de sucesso**: decisão tomada
      com dado real de uso, não suposição.
- [ ] Explorar `GenerationOptions(sampling:)` (se disponível na versão do
      framework) para diferenciar sampling entre tarefas (resumo
      determinístico vs. quiz difícil com mais diversidade) — §8.3.
      **Arquivos**: `StudyGenerator.swift`. **Motivo**: qualidade.
      **Impacto esperado**: Unknown até testar. **Risco**: Low (reversível).
      **Como testar**: gerar múltiplas rodadas do mesmo tópico com
      parâmetros diferentes, avaliar diversidade/qualidade manualmente.
      **Critério de sucesso**: critério qualitativo definido antes de
      testar (ex.: "questões difíceis não devem repetir o mesmo ângulo em
      lotes consecutivos").

---

## 15. Benchmarks

### 15.1 Conjunto de inputs representativos

1. **Cold start completo**: sem modelo MLX baixado, sem cache de embeddings,
   sem `StudyTopic` persistido — abrir "NavigationStack" (o tópico com mais
   chunks, 3). Mede o pior caso real (1ª instalação).
2. **Warm model, novo tópico**: modelo MLX já baixado e carregado (ex.:
   depois do teste 1), mas `DatasetVersion` invalidada manualmente via
   `TopicRepositoryTestView` (`TopicRepositoryTestView.swift:226-236`, já
   existe essa ferramenta) para forçar regeneração de "Property Wrappers".
   Mede o custo de geração puro, sem custo de download/carga.
3. **Cache HIT**: reabrir um tópico já gerado, mesma `DatasetVersion`. Deve
   ser quase instantâneo — valida que o cache está funcionando (já existe
   a expectativa documentada em `TopicRepositoryTestView.swift:118-121`:
   "< 0.3s = cache HIT esperado").
4. **Sessão de quiz completa + top-up**: responder um quiz inteiro (10
   questões) e fechar o sheet, medir o tempo/chamadas de
   `replenishAfterSession`.
5. **Abrir "Análise de código" antes do pool de background terminar**:
   mede a experiência de pool incompleto (`topic.codeAnalysisPool.isEmpty`
   desabilita o botão, `TopicStudyView.swift:303-304` — confirmar que essa
   UX é aceitável ou se vale a pena esperar/mostrar progresso ali também).

### 15.2 Tabela de baseline (a preencher na Fase 0 — não invento números aqui)

| Metric | Before | Target | After |
|---|---:|---:|---:|
| Time to first token (MLX, exemplo de código) | `Needs runtime measurement` | Definir após Before | |
| Tempo até tela liberada (tópico novo, warm model) | `Needs runtime measurement` (já logado em `TopicRepository.swift:245`, só precisa ser coletado) | Definir após Before | |
| Tempo até tela liberada (cache HIT) | `Needs runtime measurement` (esperado < 0.3s por `TopicRepositoryTestView.swift:119`) | Manter < 0.3s | |
| Input tokens (exemplo de código, por chamada MLX) | `Needs runtime measurement` | — | |
| Output tokens (exemplo de código) | `Needs runtime measurement` | — | |
| Tokens/s (MLX, decode) | `Needs runtime measurement` (métrica atual é chars/s, não comparável) | — | |
| Retrieval time (`retrieveContext`, caminho exato) | `Needs runtime measurement` (esperado sub-ms, é um filtro de array) | — | |
| Tempo de crescimento em background (pool completo) | `Needs runtime measurement` | — | |
| Número de chamadas FM por tópico novo | CONFIRMED pelo código: ~23-24 (contadas em §2.2) | Reduzir para ~8-10 via batching (§12.6) | |
| Memória (footprint do processo com modelo MLX carregado) | `Needs runtime measurement` via Instruments (não em código) | — | |

Não defino metas ("Target") numéricas de tempo/tokens/s aqui porque isso
dependeria de conhecer o hardware alvo real (o comentário do próprio
projeto já fala em Macs de 24GB de RAM unificada,
`MLXService.swift:10-11`, mas não sei se é o único hardware alvo) — a
Fase 0 deveria definir metas relativas ao "Before" medido (ex.: "reduzir em
X%"), não valores absolutos inventados.

---

## 16. Questionando decisões existentes

### 16.1 RAG/embeddings são necessários no caminho principal, hoje?

**Fato**: 100% da geração de conteúdo em produção usa
`chunks(forExactTopic:)` (filtro de string, sem embedding) — ver §4, §1.3.
`NLContextualEmbedding`/embeddings só alimentam: a tela de debug
(`RAGTestView`) e um fallback de "resolver tópico recomendado" que só
dispara se um match de string normalizado falhar
(`StudyResultView.swift:271-282`).

**A favor de manter como está**: o dataset já foi 21 tópicos antes
(histórico documentado em `PlaceholderDocs.swift:8-17`) e pode voltar a
crescer; se a home reintroduzir busca livre (removida em `PLANO_V3.md`,
"busca livre sai; lista curada entra"), o `hybridSearch` calibrado volta a
ser essencial no caminho principal. Reconstruir esse scoring do zero depois
custaria mais do que mantê-lo hoje, parado.

**Contra manter como está**: enquanto a lista de tópicos for curada e
fechada (estado atual), toda a complexidade de scoring híbrido (pesos
calibrados, stopwords, threshold adaptativo — ~150 linhas de
`DocumentIndex.swift`) existe para resolver um problema que não ocorre em
produção. Isso não custa performance hoje (dataset pequeno), mas é
superfície de manutenção sem retorno atual.

**Não decido isso por vocês** — é uma decisão de produto (a home vai
continuar curada ou volta a ter busca livre?), não só técnica. Recomendo
decidir explicitamente e documentar, em vez de deixar implícito.

### 16.2 O exemplo de código realmente precisa do pipeline MLX→crítica→formatação, para TODO tópico, no caminho bloqueante?

Esta é a pergunta mais importante do relatório, porque aponta diretamente
pro achado #1 do ranking. Três respostas possíveis, cada uma com trade-off
real — não escolho por vocês, mas deixo as opções concretas:

- **Opção A — manter como está**: se a Fase 0 confirmar que a diferença de
  qualidade entre MLX→FM (2-pass) e FM puro
  (`generateCodeExampleFromScratch`, que já existe como fallback) é grande
  o suficiente para justificar o custo (os bugs documentados em
  `PLANO_V5.md` eram reais), manter — mas então investir pesado nas
  otimizações de Fase 1/2 (batching, prompt cache) para baixar o custo
  absoluto.
- **Opção B — mover para background, mostrar fallback FM primeiro**: gerar
  o exemplo de código inicial via `generateCodeExampleFromScratch` (FM
  puro, rápido, já existe) no caminho síncrono, e disparar o pipeline
  MLX→crítica→formatação em background para **substituir** o exemplo por
  uma versão revisada quando pronta (like um "upgrade silencioso"). Ganha
  velocidade de abertura sem perder o benefício de qualidade do 2-pass —
  mas a UI precisa lidar com o exemplo "trocando" depois de renderizado
  (aceitável? precisa validar com o time de produto).
  d
- **Opção C — usar só a crítica, não o pipeline completo, condicionalmente**:
  gerar o exemplo direto via FM (`generateCodeExampleFromScratch`), e só
  disparar a crítica MLX/2-pass se uma heurística barata (ex.: o mesmo
  `looksTruncated`, ou um checklist determinístico simplificado de
  `commonCodeMistakesChecklist`) sinalizar risco. Reduz custo médio sem
  eliminar a proteção nos casos que mais precisam dela — mas heurísticas
  determinísticas não pegam os mesmos erros que a crítica por modelo pegou
  (ex.: `navigationDestination(for: 1)` é um erro semântico, não teria
  detecção puramente sintática fácil).

Cada opção troca velocidade por complexidade de UI ou por cobertura de
qualidade de forma diferente — recomendo que a equipe escolha depois de ver
os números reais da Fase 0 (quanto tempo o pipeline atual realmente
adiciona), não antes.

### 16.3 O pool completo (24 questões) precisa ser gerado na criação do tópico, mesmo com o top-up pós-sessão já existindo?

**Fato**: `generateAndPersist` já dispara `startBackgroundGrowthIfNeeded`
com os alvos **cheios** (`targetEasy/Medium/Hard/CodeAnalysis`, todos 6)
logo após persistir o tópico (`TopicRepository.swift:252-256`) — isso
acontece **antes** de qualquer sessão de quiz real, então é puramente
especulativo (o usuário pode nunca voltar, ou pode só querer ler o artigo).
O top-up pós-sessão (`replenishAfterSession`) já existe e funciona bem para
repor o que foi **consumido** — mas ele não substituiu esse enchimento
inicial completo, é adicional a ele.

**Pergunta**: dado que o `sampleQuiz` só usa 3+4+3=10 do total de 18 de
quiz na 1ª sessão, e a análise de código pode nunca ser aberta — o pool
completo (particularmente a análise de código, que fica atrás de um botão
que o usuário pode nunca clicar) precisa nascer cheio, ou poderia nascer
vazio/mínimo e crescer só quando o usuário efetivamente interage com essa
seção pela primeira vez (ex.: só disparar `growCodeAnalysis` quando o
usuário abrir o sheet de análise de código pela primeira vez, não na
criação do tópico)?

**Não afirmo que isso está errado** — é uma escolha de produto legítima
(pool pronto na hora = zero espera quando o usuário decide praticar), só
que ela custa GPU/bateria/tokens para conteúdo estatisticamente menos
provável de ser visto, rodando em background mesmo assim (App Nap
desabilitado de propósito, `TopicRepository.swift:370-382`, justamente para
esse trabalho continuar mesmo com o app em segundo plano). Recomendo medir
(Fase 5) a taxa real de abertura de "Análise de código" antes de decidir se
vale adiar essa geração.

### 16.4 Dois modelos (MLX + Foundation Models) para resolver uma tarefa que talvez um resolvesse

Esse é o pitch central do projeto (`GUIA_APRESENTACAO.md:21-22`: "cada um no
que é bom") e a auditoria não encontrou evidência de que seja
desnecessário — pelo contrário, o histórico de commits mostra
especificamente **por que** um modelo só (Foundation Models, otimizado
para tarefas rápidas do sistema) não bastava para as tarefas mais técnicas
(análise de código, quiz difícil), e por que confiar cegamente no rascunho
do MLX sem revisão (`formatCodeExample`/`formatCodeAnalysisQuestion`) também
não bastava (os bugs de API inventada). Não questiono a decisão de usar
dois motores — questiono (§16.2) **quando e onde no fluxo** essa
combinação é paga pelo usuário esperando.

---

## 17. Oportunidades de simplificação (antes de otimizar)

Seguindo a prioridade pedida ("remover trabalho antes de fazer o mesmo
trabalho mais rápido"):

1. **Maior oportunidade de remoção real**: se a Fase 0 confirmar que
   `generateCodeExampleFromScratch` (FM puro, já existe, já é usado como
   fallback) produz qualidade aceitável para a maioria dos tópicos, a
   simplificação não é "otimizar o pipeline MLX→crítica→formatação" — é
   **não rodar esse pipeline no caminho síncrono para todo tópico**
   (Opção B/C do §16.2). Isso remove, do caminho crítico, 1 carga de
   modelo de 7B + até 3 chamadas FM sequenciais — mais impactante que
   qualquer otimização incremental dessas mesmas chamadas.
2. **Consolidar `formatHardQuestion`/`formatCodeAnalysisQuestion`** (§11.1,
   Fase 4) remove ~100 linhas duplicadas e uma fonte recorrente de bugs de
   "esqueceram de replicar a correção no caminho irmão" — simplificação de
   manutenção, não de performance direta, mas com histórico real de
   custar bugs.
3. **Remover ou isolar as 3 telas de debug** (§11.2) da navegação de
   produção — não afeta performance do app real, mas reduz a superfície de
   código que precisa continuar compilando/funcionando a cada mudança nas
   camadas de serviço.
4. **Decidir sobre o `hybridSearch`** (§16.1) — se a resposta for "a home
   vai continuar curada", considerar se vale simplificar
   `DocumentIndex` para não manter uma busca híbrida completa calibrada
   para um cenário (busca livre) que não existe mais na UI atual. Se a
   resposta for "pode voltar", manter como está é a decisão certa — de
   novo, não decido isso por vocês.

Não encontrei oportunidades de remoção de escopo maior que essas quatro — o
resto do código (dedup, cache de embeddings, validação determinística,
orquestração por prioridade) já parece ter passado por um processo de
simplificação real ao longo das iterações anteriores (a leitura do
histórico de commits e dos planos antigos mostra bastante disciplina de
"resolver o problema mínimo necessário", não acúmulo de complexidade
gratuita).

---

## 18. O que este relatório NÃO fez (limitações explícitas)

- Não rodei o app. Todo número de tempo/tokens/memória está marcado como
  `Needs runtime measurement` — a Fase 0 é o próximo passo real, não este
  documento.
- Não tive acesso ao código-fonte do pacote `NaturalLanguageEmbeddings`
  nem à documentação exata da API `LanguageModelSession`/`GenerationOptions`
  desta versão do Foundation Models — pontos marcados como "verificar antes
  de assumir" (§8.3, §12.3, §7.3) refletem essa limitação, não uma
  afirmação categórica.
- Não medi cobertura de qualidade end-to-end (quantas questões geradas
  hoje passam no `QuestionValidator` na 1ª tentativa vs. precisam de
  regeneração) — isso seria um ótimo dado complementar para calibrar §12.1
  e §12.6, mas exige rodar gerações reais.
