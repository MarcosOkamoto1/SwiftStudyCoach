# SOLUTIONS_PLAN.md — Plano técnico definitivo de implementação

> Este documento assume a autoridade de **decisão**, não de diagnóstico. O
> `PLAN.md` é tratado como fonte de problemas, não como fonte de soluções —
> toda recomendação aqui foi reavaliada contra o código atual e, quando
> relevante, contra as APIs reais das dependências instaladas (verificadas
> por leitura direta do código-fonte no commit/tag pinado em
> `Package.resolved`, não por suposição).
>
> **Verificação de estado do projeto**: reconferido nesta sessão via
> `git status`/`git diff --stat` — o working tree está **idêntico** ao
> estado auditado em `PLAN.md` (mesmos 8 arquivos modificados, mesmo diff).
> Nenhuma linha de código mudou entre a auditoria e este documento. Todas as
> referências de arquivo:linha deste documento reusam as coordenadas já
> verificadas em `PLAN.md`.
>
> **APIs externas verificadas nesta sessão** (fetch direto do código-fonte
> no commit pinado, não documentação genérica nem suposição):
> - `mlx-swift` @ `072b684a` (v0.29.1): `GPU.set(cacheLimit:)`,
>   `GPU.set(memoryLimit:relaxed:)`, `GPU.withWiredLimit(_:_:)`,
>   `GPU.snapshot()`/`GPU.cacheMemory`/`GPU.activeMemory` — todos reais,
>   lidos de `Source/MLX/GPU.swift`.
> - `mlx-swift-examples` @ `9bff95ca` (v2.29.1), pacote `MLXLMCommon`:
>   `KVCache` (protocolo), `KVCacheSimple`, `QuantizedKVCache`,
>   `makePromptCache(model:parameters:)`, `savePromptCache`/`loadPromptCache`,
>   `trimPromptCache`/`canTrimPromptCache`, `GenerateParameters` (com
>   `maxKVSize`, `kvBits`, `kvGroupSize`, `prefillStepSize`),
>   `TokenIterator.init(input:model:cache:parameters:)`,
>   `generate(input:cache:parameters:context:) -> AsyncStream<Generation>`,
>   `UserInput.init(chat: [Chat.Message])`, `Chat.Message.system/user/assistant(_:)`,
>   `MessageGenerator` — todos lidos de
>   `Libraries/MLXLMCommon/{KVCache,Evaluate,UserInput,Chat}.swift` no commit
>   exato pinado pelo projeto. `ChatSession` foi buscado no mesmo commit e
>   **não existe nele** (fetch retornou 404) — só aparece em buscas que
>   apontam para o repositório sucessor `ml-explore/mlx-swift-lm`, mais
>   recente que a versão pinada. Não assumo `ChatSession` disponível neste
>   projeto sem uma migração de versão dedicada (ver §7 e §23).
> - `FoundationModels` (framework fechado da Apple, sem código-fonte
>   público): a existência de `GenerationOptions(sampling:temperature:)`
>   com `.sampling = .greedy` ou aleatório com `top`/`seed`, faixa de
>   `temperature` 0...2, e `session.streamResponse(...)` retornando
>   snapshots parciais de saída estruturada (`PartiallyGenerated`, não
>   tokens brutos) foi corroborada por múltiplas fontes secundárias (posts
>   técnicos independentes) nesta sessão — a documentação oficial da Apple é
>   renderizada em JavaScript e não pôde ser lida diretamente pelas
>   ferramentas desta sessão. Tratado como **HIGHLY LIKELY, não CONFIRMED
>   em fonte primária** — qualquer uso precisa de um teste de compilação
>   real antes de depender disso (ver §7.3/§13).
> - Modelos MLX candidatos: nomes de repositório confirmados via busca
>   (Hugging Face) nesta sessão — ver §8 para a lista exata e o que foi e
>   não foi possível verificar.
>
> Convenção de rótulos mantida de `PLAN.md`: **CONFIRMED** / **HIGHLY
> LIKELY** / **HYPOTHESIS**. Toda decisão importante segue o formato
> **WHAT / WHY / WHERE / HOW / TRADE-OFF / BENCHMARK / SUCCESS CRITERIA /
> ROLLBACK** pedido nas regras finais.

---

## 1. Findings Consolidation

| ID | Problema | Evidência (PLAN.md) | Impacto | Solução recomendada | Prioridade |
|----|----------|----------------------|---------|----------------------|------------|
| F1 | Exemplo de código força carga do MLX 7B + 2-3 chamadas FM sequenciais, bloqueante, em TODO tópico novo | §2.1 — `StudyGenerator.swift:239-280`, `TopicRepository.swift:208-210` | Very High | Mover para Estratégia B+D (FM primeiro, MLX vira upgrade em background com gate determinístico) — ver §5 | P0 |
| F2 | Fila FM global serial processa ~23 chamadas por tópico novo | §2.2 — `GenerationOrchestrator.swift:141-157` | High | Manter fila serial (não é o problema em si — é o **volume** de chamadas); reduzir volume via F1+F3 | P0 (via F1/F3) |
| F3 | Formatação FM pós-lote MLX não é batched (N chamadas em vez de 1) | §2.3 — `StudyGenerator.swift:548-552,739-741` | High | Batching com schemas existentes (`QuizQuestionBatch`/`CodeAnalysisBatch`) — ver §6 | P0 |
| F4 | Nenhum KV/prompt cache reutilizado entre as 3 chamadas MLX de um tópico | §2.4 — ausência confirmada em `MLXService.swift:316-342` | Medium-High | Cache de prefixo (system+RAG) via `KVCache` real do `MLXLMCommon`, primed uma vez por tópico, clonado por chamada — ver §7 | P1 (benchmark-gated) |
| F5 | Chat template ChatML montado manualmente como string | §2.5 — `MLXService.swift:321` | Low perf / Medium manutenção | Migrar para `UserInput(chat: [Chat.Message])` — API real confirmada nesta sessão. **Achado novo**: o código atual passa o template manual inteiro como conteúdo de UMA mensagem `.user` (via `UserInput(prompt:)`), o que provavelmente resulta em **duplo template** (o processor do modelo aplica o template real por cima do texto já formatado) — ver §19 | P0 (safe win, não depende de benchmark) |
| F6 | Nenhum tuning de `MLX.GPU.set(cacheLimit:)` | §2.6 — grep vazio, reconfirmado nesta sessão | Unknown | Medir antes de fixar valor — API real confirmada (`GPU.set(cacheLimit:)`, `GPU.snapshot()`) — ver §11 | P2 (benchmark-gated) |
| F7 | Dedup de carga de modelo/índice/geração já funciona | §2.7, §5 | — | **NÃO ALTERAR** | N/A |
| F8 | `formatHardQuestion` sem orçamento de token explícito, diferente do resto do arquivo | §3, §8.3 — `StudyGenerator.swift:687-693` | Medium (qualidade) | Aplicar o mesmo padrão de orçamento+retry-curto já usado em `formatCodeAnalysisQuestion` — ver §13 | P0 (safe win) |
| F9 | Métrica "chars/s" não é tokens/s real | §2.8 — `MLXService.swift:337-339` | Indireto (bloqueia diagnóstico) | Contagem real de tokens via `GenerateCompletionInfo` (API real, já devolvida por `MLXLMCommon.generate`, mas descartada hoje) — ver §10 | P0 (safe win) |
| F10 | `retrieveContext` recalculado sem necessidade em 2 pontos | §5.1 — `StudyGenerator.swift:526,711` | Low | Passar `context` já calculado como parâmetro | P2 (safe win, baixo valor) |
| F11 | Caminho de produção usa filtro exato, embeddings só em debug/fallback | §4, §16.1 | Low perf / Medium manutenção | Manter arquitetura híbrida, mas formalizar o caminho exato como política oficial e tirar embeddings do caminho crítico de ABERTURA de tela — ver §17/§18 | P1 |
| F12 | `ensureReady()` (embeddings) bloqueia entrada na tela mesmo quando geração não usa embedding | §4, `TopicStudyView.swift:121-127` | Low hoje, cresce com dataset | Desacoplar `rawChunks` (síncrono) de embeddings prontos (assíncrono) — ver §18 | P0 (safe win) |
| F13 | UI sem granularidade de progresso durante geração | §7.1 — `TopicStudyView.swift:77-98` | High (percepção) | `GenerationStage` observável — ver §16 | P1 |
| F14 | Nada é renderizado progressivamente | §7.2 | High (percepção) | Persistência incremental do `StudyTopic` por etapa — ver §16 | P1 |
| F15 | Stream do MLX consumido internamente, nunca chega à UI | §7.3 — por bom motivo (rascunho interno) | — | **NÃO ALTERAR o stream do MLX**; considerar `streamResponse` do FM só se F1 mover o exemplo pro FM síncrono — ver §16 | N/A / P2 |
| F16 | Geração especulativa do pool completo (24 questões) na criação do tópico | §3.1, §16.3 — `TopicRepository.swift:252-256` | Medium (GPU/bateria/tokens) | Pool mínimo viável + top-up já existente, adiar `codeAnalysisPool` até 1º acesso — ver §14 | P1 (decisão de produto, recomendação técnica dada) |
| F17 | Duplicação `formatHardQuestion`/`formatCodeAnalysisQuestion` | §11.1 | Medium (manutenção, já causou bug 2x) | Unificar via função genérica parametrizada por schema | P2 |
| F18 | 3 telas de debug na navegação de produção | §11.2 — `RootTabView.swift:13-27` | Low perf / Medium manutenção | Mover para scheme de debug ou remover | P3 |
| F19 | Ausência de testes automatizados | §11.3 | Medium (confiabilidade) | `XCTest` para funções puras — ver §21 | P1 |
| F20 | Dupla chave de invalidação de cache (hash SHA256 vs. `DatasetVersion`) | §4, §16 | Low | **NÃO ALTERAR agora** — funcionam sincronizadas; documentar a relação | N/A |
| F21 | `DocChunk.embedding` como `[Double]` em vez de `[Float]` | §12.3 | Low hoje, Medium se dataset crescer | Converter para `Float` se a API do pacote permitir — verificar antes | P3 |
| F22 | `GenerationOrchestrator`: 1 worker FM + 1 worker MLX, serialização total | §6 | High (mecanismo correto, mas nunca testado se FM aguentaria >1) | Manter serialização por default; desenhar experimento de concorrência FM=2 só para `.poolFill`, benchmark-gated, não implementar sem dado — ver §15 | P2 (benchmark-gated) |
| F23 | Instrumentação existente é só `print`, sem tokens reais nem agregação | §9 | Indireto (bloqueia tudo que depende de medição) | `GenerationMetrics` struct — ver §10 | P0 |
| F24 | Nenhum warm-up de inferência (só de carga de pesos) | §2.9 | Unknown | Medir 1ª vs. 2ª inferência antes de decidir se compensa — ver §12 | P2 (benchmark-gated) |
| F25 | RAG: `hybridSearch` calibrado mas não usado em produção | §4, §16.1 | Low perf / Medium manutenção | Mesma decisão de F11 | P1 |
| F26 | Dataset atual (3 tópicos/8 chunks) torna preocupações de RAG performance moot hoje | §0, §4 | — | **NÃO otimizar retrieval agora**; arquitetura já suporta crescimento | N/A |
| F27 | Sem `sampling`/temperatura diferenciada por tarefa no Foundation Models | §8.3 | Unknown | Testar `GenerationOptions(sampling:)` (API HIGHLY LIKELY real, não CONFIRMED em fonte primária) — ver §13 | P2 (benchmark-gated) |
| F28 | MLX usa parâmetros fixos (`temperature: 0.3, repetitionPenalty: 1.1`) para toda tarefa | §8.3 — `MLXService.swift:322` | Low-Medium | Diferenciar por tarefa **depois** que F1 reduzir o escopo de uso do MLX a background/upgrade — não priorizar agora | P3 |
| F29 | Modelo atual `Qwen2.5-Coder-7B-Instruct-4bit`; `14B` já testado no histórico do projeto (commit `5f1305a`) e nunca invalidado por evidência de memória — foi apenas leapfrogged pelo experimento de 30B MoE que falhou | Histórico de commits (`git log`), reconfirmado nesta sessão | High (qualidade) | **KEEP CURRENT MODEL** como padrão; `14B` como Quality Alternative benchmark-gated — ver §8 | P1 (benchmark-gated) |
| F30 | Nenhuma validação determinística de erros de API Swift antes de pagar uma chamada de crítica por modelo | §8.1, §20 (novo) | Medium-High (custo + qualidade) | Camada de checks estáticos baratos antes/em vez da crítica por modelo, quando aplicável | P0/P1 |

---

## 2. Decisões de arquitetura (log de decisão)

Formato por decisão: **Opções → Trade-offs → Escolha → Por quê (para ESTE
projeto) → Evidência pendente → Gatilho de reversão**. Detalhamento completo
de cada uma está nas seções dedicadas linkadas.

### D1 — Onde o exemplo de código (MLX→crítica→formatação) deve rodar

- **Opções**: (A) manter no caminho bloqueante como hoje; (B) FM gera
  primeiro, MLX/crítica melhora em background; (C) pipeline complexo só
  quando heurística indicar risco; (D) combinação.
- **Trade-offs**: A é simples mas é o gargalo #1 confirmado; B remove o
  gargalo mas troca o conteúdo depois de renderizado (UX de "trocar depois"
  precisa ser aceitável); C reduz custo médio mas heurísticas sintáticas não
  pegam os erros semânticos que motivaram a crítica (ex.:
  `navigationDestination(for: 1)`).
- **Escolha**: **B+C combinadas** (chamada de "Estratégia D" na análise da
  §5): FM gera o exemplo síncrono e rápido; checks determinísticos baratos
  (§20) rodam imediatamente sobre esse resultado; SE os checks passarem
  limpo, a chamada MLX/crítica ainda roda em background (não é opcional —
  ela pega erros que a heurística sintática não pega), mas com prioridade
  `.poolFill` (não compete com nada user-facing); SE os checks falharem, a
  prioridade sobe para `.nextSession` (upgrade mais urgente, mas ainda não
  bloqueia a tela).
- **Por quê**: preserva a defesa contra hallucination que motivou o 2-pass
  (não é overengineering, tem evidência real de bug — §8.1 do `PLAN.md`),
  mas tira TODO o custo de MLX do caminho que o usuário espera ver.
- **Evidência pendente**: Fase 0 precisa medir (a) tempo de
  `generateCodeExampleFromScratch` sozinho vs. o pipeline completo, (b) taxa
  real de "o FM sozinho já estava certo" vs. "o upgrade MLX corrigiu algo" —
  esse segundo número decide se vale simplificar ainda mais depois.
- **Gatilho de reversão**: se a taxa de correção do upgrade MLX for muito
  alta (ex. >30% dos exemplos precisam de correção) e a troca de conteúdo
  pós-render incomodar em teste de usuário, considerar voltar a bloquear —
  mas aí o alvo devia ser reduzir o tempo do pipeline (batching, cache),
  não reintroduzir o bloqueio sem mais.

### D2 — Modelo MLX

Decisão completa em §8. Resumo: **KEEP CURRENT MODEL**
(`Qwen2.5-Coder-7B-Instruct-4bit`) como padrão de produção; `14B` como
Quality Alternative sob benchmark; `3B` como Performance Alternative sob
benchmark. Não reabrir a hipótese de MoE 30B sem evidência nova de que a
pressão de memória foi resolvida (nenhuma evidência nova foi encontrada
nesta sessão).

### D3 — Batching de formatação FM

- **Opções**: (A) manter 1 chamada por item; (B) 1 chamada por lote inteiro
  (todos os itens gerados na criação do tópico); (C) 1 chamada por lote no
  MESMO tamanho do lote MLX já existente (≤4).
- **Trade-offs**: A é caro (confirmado, F3); B minimiza chamadas mas
  arrisca truncamento em lotes estruturados grandes (a própria razão
  histórica documentada em `StudyModels.swift:9-12` para não pedir tudo
  numa chamada só); C é o meio-termo com menor risco, porque reusa um
  tamanho de lote (4) que o projeto já demonstrou ser seguro no lado MLX.
- **Escolha**: **C**. Ver §6 para o mapeamento completo de chamadas
  antes/depois.
- **Por quê**: menor risco de regressão de truncamento, ganho ainda grande
  (3x menos chamadas), consistente com o padrão de lotes pequenos que o
  próprio histórico do projeto já validou (`PLANO_V2.md`: "lotes pequenos
  (3-5), nunca tudo de uma vez").
- **Evidência pendente**: taxa de rejeição do `QuestionValidator` antes/depois
  do batching, por tipo de pergunta.
- **Gatilho de reversão**: se a taxa de rejeição subir de forma
  estatisticamente notável (ex. dobrar) após o batching, reduzir o batch
  size para 2 antes de abandonar a ideia inteira.

### D4 — KV/Prompt cache MLX

- **Opções**: (A) não fazer nada; (B) cache de prefixo compartilhado entre
  as chamadas MLX de um mesmo tópico, com clone-por-chamada; (C) usar
  `savePromptCache`/`loadPromptCache` em disco entre sessões do app.
- **Escolha**: **B**, com C explicitamente descartado por ora (ver §7 —
  overhead de I/O de disco para um cache que dura só a vida de uma sessão
  de geração de tópico não se paga).
- **Por quê**: as 3 chamadas MLX de um tópico (exemplo de código, quiz
  difícil, análise de código) compartilham system prompt + contexto RAG
  quase idênticos — B ataca exatamente essa redundância com API real
  (`KVCache`/`makePromptCache`), sem reescrever a lib.
- **Evidência pendente**: §7 lista o experimento exato (comparar TTFT da
  2ª/3ª chamada MLX de um tópico com e sem cache).
- **Gatilho de reversão**: se o ganho de TTFT for marginal (a hipótese
  concorrente é que o gargalo real é decode, não prefill, dado que o
  contexto RAG hoje é pequeno — 8 chunks, ~600-750 palavras por tópico) OU
  se o padrão "clonar e descartar" (não documentado oficialmente pela lib)
  se mostrar instável em teste, reverter para A e reavaliar quando o
  dataset crescer (contexto RAG maior = prefill mais caro = cache compensa
  mais).

### D5 — Concorrência no `GenerationOrchestrator`

- **Escolha**: manter **1 worker FM + 1 worker MLX** como default de
  produção. Não implementar profundidade >1 sem o experimento descrito em
  §15 rodar primeiro e mostrar resultado seguro.
- **Por quê**: a serialização resolve um problema documentado
  (`rateLimited`/`concurrentRequests`) por construção; o ganho teórico de
  paralelizar é menor depois que D1+D3 já cortam o volume de chamadas pela
  metade.

### D6 — RAG / embeddings

- **Escolha**: **Opção B** de §17 — manter a arquitetura híbrida completa
  (não deletar código), mas tirá-la formalmente do caminho crítico de
  qualquer tela (não só de geração, que já está fora). Ver §17/§18.

### D7 — Chat template MLX

- **Escolha**: migrar para `UserInput(chat: [.system(...), .user(...)])`
  usando a API real confirmada (`Chat.Message`). Classificado como **safe
  win**, não benchmark-gated, porque o achado de duplo-template (F5) é um
  problema de correção/eficiência de tokens, não uma otimização
  especulativa — mas ainda assim recomendo um teste de equivalência antes
  de remover a string manual (ver §19), porque mudar como o modelo VÊ o
  prompt pode mudar a saída.

### D8 — Geração especulativa do pool

- **Escolha**: reduzir o "piso" já gerado no caminho síncrono para o mínimo
  da 1ª sessão (já é assim: 3 fácil + 4 média chegam via `sampleQuiz`, mas
  o código gera 6+6); adiar `growCodeAnalysis` até o usuário abrir essa
  seção pela 1ª vez. Ver §14. Marcado explicitamente como **decisão de
  produto com recomendação técnica** (não puramente técnica) — ver
  justificativa em §14.

### D9 — Renderização progressiva

- **Escolha**: persistir o `StudyTopic` em 2 fases (resumo primeiro, depois
  patch com exemplo/quiz) em vez de uma escrita atômica única. Ver §16.

---

## 3. Target Architecture

### 3.1 CURRENT (resumido de `PLAN.md` §1.1)

```text
CURRENT
User toca no tópico
 ↓
TopicStudyView.load()
 ↓
DocumentIndex.ensureReady()  ── BLOQUEIA a tela (embeddings, mesmo não usados no caminho exato)
 ↓
TopicRepository.fetchOrCreate()
 ↓
generateAndPersist() ── BLOQUEIA a tela inteira até tudo terminar
 ├─ async let exampleTask:
 │     MLXService.loadModel()  ── carga do modelo 7B, síncrona (dentro do async let)
 │     → MLX draft (1 chamada)
 │     → FM critique (1 chamada)
 │     → FM format (1 chamada, +retry)
 ├─ await generateSummary()          ── FM (1 chamada)
 ├─ await generateQuizBatch(.easy)   ── FM (1 chamada, batched)
 ├─ await generateQuizBatch(.medium) ── FM (1 chamada, batched)
 └─ await exampleTask (join)
 ↓
persiste StudyTopic (1 escrita atômica, tudo ou nada)
 ↓
TELA APARECE (só agora)
 ↓
startBackgroundGrowthIfNeeded() ── background, não bloqueia
 ├─ Trilha FM: fácil/média até 6/6 (geralmente no-op)
 └─ Trilha MLX: loadModel() [dedup] → 6 difíceis (2 lotes MLX + 6 FM formats
    NÃO batched) → 6 análise de código (2 lotes MLX + 6 FM critique + 6 FM
    format NÃO batched)
```

### 3.2 TARGET

```text
TARGET
User toca no tópico
 ↓
TopicStudyView.load()
 ↓
PlaceholderDocs.rawChunks disponível IMEDIATAMENTE (síncrono, estático)
 ── DocumentIndex.ensureReady() dispara em paralelo, SEM bloquear (só é
    aguardado pelos caminhos fuzzy: hybridSearch/RAGTestView/recommended-topic)
 ↓
TopicRepository.fetchOrCreate()
 ↓
generateAndPersist() ── só bloqueia pelo que é MOSTRADO PRIMEIRO
 ├─ context = retrieveContext(topic) ── síncrono, filtro de array (já é assim)
 ├─ await generateSummary()          ── FM (1 chamada)   ┐
 ├─ await generateQuizBatch(.easy)   ── FM (1 chamada)    ├─ sequencial na fila FM
 ├─ await generateQuizBatch(.medium) ── FM (1 chamada)    ┤  (já serializada mesmo
 ├─ await generateCodeExampleFM()    ── FM (1 chamada)   ┘   sem mudar isso)
 ↓
PERSISTE StudyTopic FASE 1 (resumo + keyPoints + quiz fácil/média + exemplo
FM-only) ── escrita parcial, TELA APARECE AQUI (ver §4)
 ↓
BACKGROUND (prioridade .nextSession, não bloqueia nada visível):
 ├─ checks determinísticos (§20) sobre o exemplo FM-only
 │    └─ se falhar → prioridade sobe; se passar → prioridade fica .poolFill
 ├─ MLXService.loadModel() [dedup, 1x por processo]
 ├─ Trilha MLX (usa KVCache de prefixo primed 1x por tópico — §7):
 │    → MLX draft exemplo de código (clone do cache primed)
 │    → FM critique (clone/nova sessão, como hoje)
 │    → FM format → SE mudou algo relevante, PATCH no StudyTopic já
 │      persistido (StudyTopic é @Model, a UI observa via @Query/@Observable
 │      e re-renderiza sozinha)
 │    → MLX draft quiz difícil em lote(s) de ≤4 (mesmo cache primed)
 │    → FM format EM LOTE (1 chamada por lote de ≤4, não 1 por item — §6)
 │    → MLX draft análise de código em lote(s) de ≤4 (mesmo cache primed)
 │    → FM critique EM LOTE + FM format EM LOTE (§6)
 └─ Trilha FM: fácil/média até 6/6 (no-op na maioria dos casos, como hoje)
```

### 3.3 O que muda, explicitamente

- **Sai do caminho crítico**: carga do modelo MLX, geração MLX, crítica FM
  do exemplo de código, formatação MLX→FM do exemplo de código,
  `ensureReady()` (embeddings).
- **Vai para background**: tudo relacionado a MLX (exemplo "de verdade",
  quiz difícil, análise de código) — MLX deixa de estar no caminho que o
  usuário espera ver, em qualquer situação.
- **Continua bloqueante** (e está correto que continue): resumo, quiz
  fácil/média, exemplo de código **versão FM-only** — são as 4 chamadas FM
  mínimas necessárias pra mostrar algo útil e correto (grounded no RAG,
  sem hallucination não verificada — o FM sozinho já tem instrução
  conservadora "não invente o que não está no contexto", `StudyGenerator.swift:190-193`).
- **Quando MLX é carregado**: só quando a trilha MLX de background
  realmente começa a rodar (primeira vez que qualquer tópico precisa de
  quiz difícil/análise de código/upgrade de exemplo) — não muda o
  mecanismo de `prewarmIfCached`/dedup, só o ponto em que ele é
  necessário pela primeira vez no fluxo de abertura de tópico.
- **Quando MLX é chamado**: 3x por tópico (mesmo de hoje), mas agora todas
  em background, e compartilhando o KVCache de prefixo primed (§7).
- **Quando FM é chamado**: síncrono (4 chamadas: resumo, quiz fácil, quiz
  médio, exemplo FM-only) + background (upgrade do exemplo condicional,
  formatação em lote do quiz difícil, crítica+formatação em lote da
  análise de código — total de background cai de ~18 para ~6-8 chamadas,
  ver §6).
- **Quais chamadas são batched**: quiz difícil (formatação) e análise de
  código (crítica E formatação), em lotes de ≤4 — ver §6.
- **O que é cacheado**: embeddings (já é — não muda), modelo MLX carregado
  (já é — não muda), índice RAG (já é — não muda), e **novo**: KV cache de
  prefixo MLX por tópico (§7).
- **Quando RAG entra**: exatamente como hoje — filtro exato por tópico,
  síncrono, antes de qualquer chamada de geração. `hybridSearch`/embeddings
  só entram nos caminhos fuzzy (debug, recomendação de próximo tópico), que
  não fazem parte do caminho de abertura de tela.
- **Quando SwiftData entra**: 2 momentos agora em vez de 1 — persistência
  FASE 1 (libera a tela) e patch FASE 2 (upgrade de background, quando
  aplicável). Ambos usam o padrão de `ModelContext` já existente
  (`TopicRepository.swift:387-390`, contexto próprio por trilha).
- **Quando conteúdo fica disponível pra UI**: resumo+quiz fácil/média+exemplo
  básico ficam disponíveis assim que a FASE 1 persiste (bem mais cedo que
  hoje); quiz difícil, análise de código, e a versão "revisada" do exemplo
  ficam disponíveis conforme a trilha de background completa cada etapa —
  a UI já tem o padrão de "pool incompleto, desabilitar botão"
  (`TopicStudyView.swift:294,303-304`) para lidar com isso; só falta o
  `GenerationStage` (§16) pra deixar isso visível em vez de silencioso.

---

## 4. First Topic Open — Critical Path

Esta é a mudança de maior impacto percebido. Estrutura em eventos/fases (sem
inventar tempos — todo T é um marcador de ordem, não de duração):

```text
EVENT 0 — Usuário toca no tópico (StudyHomeView → TopicStudyView.task { load() })

EVENT 1 — Dados essenciais disponíveis (síncrono, sem I/O de rede/modelo)
  • PlaceholderDocs.rawChunks[topic] já está em memória (constante estática)
  • TopicRepository.fetchExisting(topic:) roda (fetch SwiftData local, rápido)
  • CACHE HIT → pula direto pro EVENT 5 (tela aparece com tudo, como já
    acontece hoje — não muda)
  • CACHE MISS → segue pro EVENT 2

EVENT 2 — Contexto RAG resolvido (síncrono, filtro de array, sem embedding)
  • context = documentIndex.chunks(forExactTopic: topic) — já não depende
    de ensureReady() completar (F12/§18)

EVENT 3 — Conteúdo "mostrável" começa a ser gerado (bloqueante, só FM)
  • generateSummary() — FM
  • generateQuizBatch(.easy) — FM
  • generateQuizBatch(.medium) — FM
  • generateCodeExampleFromScratch() — FM (era o fallback; vira o caminho
    PRINCIPAL síncrono — ver D1)
  • Estas 4 chamadas continuam serializadas pela fila FM do
    GenerationOrchestrator (não removo essa serialização — D5) — então o
    tempo desta fase é a SOMA das 4, não o max

EVENT 4 — Persistência FASE 1 + liberação da tela
  • StudyTopic persistido com summary/keyPoints/quizPool(fácil+média)/
    codeExample(versão FM) — sourceDatasetVersion, isGeneratingPool = true
  • fetchOrCreate() RETORNA aqui — TopicStudyView sai de isLoading

EVENT 5 — Tela renderizada com conteúdo útil
  • Resumo, pontos-chave e exemplo de código (FM-only) visíveis
  • Botão de Quiz habilitado (fácil+média já preenchem `sampleQuiz`, que já
    tolera pool parcial repetindo itens — `TopicRepository.swift:295-309`)
  • Botão de Análise de código DESABILITADO (pool vazio — UX já existe,
    `TopicStudyView.swift:303-304`) — `GenerationStage` (§16) mostra
    "melhorando exemplo e gerando mais conteúdo em segundo plano"

BACKGROUND (não bloqueia nenhum dos eventos acima)
  • loadModel() MLX [dedup]
  • upgrade do exemplo de código (MLX→crítica→formatação, condicional ao
    gate determinístico — D1)
  • quiz difícil (lotes MLX + formatação em lote — §6)
  • análise de código (lotes MLX + crítica/formatação em lote — §6)
  • cada etapa de background que produz resultado válido faz PATCH no
    StudyTopic já persistido; a UI observa via SwiftData (@Query já usado
    em `TopicRepositoryTestView.swift:24`, `StudyHomeView.swift:19` — o
    mesmo padrão reativo se aplica a uma view que observe o StudyTopic
    específico sendo editado)
```

### 4.1 O que precisa existir ANTES da tela aparecer

Só as 4 chamadas FM do EVENT 3 + a leitura síncrona de RAG do EVENT 2.
Nada de MLX, nada de crítica, nada de embeddings.

### 4.2 O que pode continuar depois

Tudo que hoje já é "background" (quiz difícil, análise de código) MAIS o
que hoje é síncrono e deixa de ser (exemplo de código via MLX/crítica).

### 4.3 Redução esperada de "time to useful content" (qualitativa, não numérica)

De **5-6 chamadas FM + 1 carga de MLX + 1 chamada MLX + 2-3 chamadas FM**
(hoje) para **4 chamadas FM** (target) no caminho que bloqueia a tela.
Proporção exata de redução de tempo: `Needs runtime measurement` — mas a
redução de **carga de modelo local de 7B do caminho bloqueante** é, por si
só, a mudança de maior impacto identificável sem medir (é a diferença entre
"a tela espera só por texto pequeno via um modelo de sistema já residente"
e "a tela espera por um modelo de 7B carregar na RAM + gerar + ser
revisado").

---

## 5. Pipeline MLX → Foundation Models — análise de arquitetura

### 5.1 Comparação de estratégias

| Critério | A — Manter atual | B — FM primeiro, MLX melhora em background | C — Pipeline complexo só sob heurística | D — B+C combinadas (recomendada) |
|---|---|---|---|---|
| Latência (abertura de tópico) | Alta (carga MLX + 3 chamadas no caminho crítico) | Baixa (só FM no caminho crítico) | Média (depende de quão bem a heurística evita o pipeline) | Baixa (igual a B) |
| Qualidade | Alta (crítica sempre roda) | Alta, mas com delay (crítica roda depois, conteúdo pode trocar) | Média — heurísticas sintáticas não pegam erros semânticos (`navigationDestination(for: 1)` é sintaticamente válido) | Alta — crítica sempre roda em background (não é pulada, só desacelerada em prioridade) |
| Consumo de memória | Alto cedo (modelo carregado no momento mais sensível — usuário esperando) | Alto, mas tarde (modelo carrega quando não há usuário esperando ativamente) | Alto só quando heurística dispara | Igual a B |
| Número de chamadas | 1 MLX + 2-3 FM, sempre | 1 FM (síncrono) + 1 MLX + 2-3 FM (background), sempre | 1 FM sempre + (1 MLX + 2-3 FM) condicional | 1 FM (síncrono) + 1 MLX + 2-3 FM (background), sempre — mas com prioridade adaptativa |
| Complexidade | Baixa (já existe) | Média (persistência em 2 fases, UI reativa a patch) | Média-Alta (heurística de decisão, risco de falso-negativo silencioso) | Média-Alta (soma de B + gate determinístico de D1, mas o gate é aditivo, não substitui a crítica) |
| UX | Ruim (espera longa, sem conteúdo) | Boa, com ressalva: conteúdo pode "trocar" depois de renderizado | Boa na maioria dos casos, ruim quando a heurística erra silenciosamente | Boa — mesma ressalva de B, mitigada por `GenerationStage` (§16) avisando que uma versão melhorada está a caminho |
| Confiabilidade | Alta (testada em produção) | Precisa validar que "trocar conteúdo depois" não quebra estado da UI (respostas de quiz já dadas, etc.) | Depende inteiramente da heurística nunca ter falso-negativo | Mesma ressalva de B, mas com rede de segurança (crítica nunca é pulada, só reordenada) |
| Risco de hallucination/API inventada | Baixo (mitigado pela crítica, que sempre roda antes do usuário ver) | **Médio** — usuário pode ver a versão FM-only por um tempo antes do upgrade chegar; o FM-only já tem instrução conservadora mas não tem a mesma defesa em camadas | Médio-Alto — depende de a heurística cobrir os casos reais | Baixo — igual a A no fim, porque a crítica sempre roda; a diferença é só QUANDO o usuário vê o resultado final |
| Manutenção | Baixa (nada muda) | Média (2 fases de persistência, patch reativo) | Alta (heurística + os dois caminhos + risco de deriva entre eles) | Média (mesmo custo de B, o gate de C é aditivo e barato — reusa checks de §20) |

### 5.2 Recommended Generation Strategy

**Escolha: Estratégia D.** Combina B (tirar MLX do caminho síncrono) com um
elemento de C (gate determinístico, §20) que **não decide se a crítica
roda**, mas decide a **prioridade** com que ela roda — isso evita o
principal risco de C isolado (heurística sintática deixando passar um erro
semântico sem que ninguém mais olhe) enquanto ainda captura o benefício de
C (recursos de background gastos com mais urgência onde o risco é maior).

```text
FLUXO COMPLETO (Estratégia D)

1. generateCodeExampleFromScratch(topic, context)     [FM, síncrono]
   → ExplainedCodeExample (code + walkthrough)

2. persistir StudyTopic FASE 1 (inclui este exemplo)   [SwiftData]
   → TELA APARECE

3. [background, prioridade inicial .poolFill]
   checks determinísticos (§20) sobre `example.code`:
     - looksTruncated (já existe, `StudyGenerator.swift:479-509`)
     - checklist sintático de erros conhecidos (novo, baseado em
       `commonCodeMistakesChecklist`, `StudyGenerator.swift:618-628`,
       convertido de "prompt pro modelo" para "checks de string/regex"
       onde for mecanicamente verificável — ver §20.1 para o que É e não É
       verificável sem modelo)
   SE algum check falhar → prioridade sobe para .nextSession
   (a lógica de prioridade já existe no GenerationOrchestrator — só
   escolher qual enfileirar)

4. [background] MLXService.loadModel() [dedup — já existe]

5. [background] MLX draft do exemplo (usa cache de prefixo primed — §7)
   → texto livre (código + explicação)

6. [background] FM critique (1 chamada) — mesmo prompt de hoje
   (`critiqueCodeDraft`, `StudyGenerator.swift:380-417`)

7. [background] FM format (1 chamada, +retry se truncado) — mesmo prompt de
   hoje (`formatCodeExample`, `StudyGenerator.swift:298-369`)

8. SE o resultado de (7) for estruturalmente válido E diferente do exemplo
   FM-only da fase 1 (comparação simples: código diferente OU walkthrough
   diferente) → PATCH no StudyTopic persistido (novo método,
   `TopicRepository.applyCodeExampleUpgrade(topicID:example:)`)
   SE inválido → descarta, mantém a versão FM-only (que já passou pelos
   checks determinísticos do passo 3 — não fica sem defesa nenhuma)

9. [background, paralelo aos passos 4-8] quiz difícil e análise de código
   seguem o fluxo de §6 (batched)
```

**Por que esta é a melhor escolha para ESTE projeto**: o projeto já provou,
com bugs reais documentados (§8.1 do `PLAN.md`), que FM sozinho sem crítica
alucina API em código gerado — então "nunca rodar a crítica" (uma versão
mais radical de C) está descartado por evidência própria do projeto, não
por precaução genérica. Ao mesmo tempo, o custo dessa crítica não precisa
ser pago pelo relógio do usuário — só precisa ser pago pelo relógio do
processador, que é um recurso mais barato de gastar em background numa
sessão de leitura de artigo (o usuário está lendo o resumo por alguns
segundos de qualquer forma).

**Evidências que ainda precisam de benchmark**:
- Frequência real de "o upgrade mudou algo" — se for baixíssima, o valor
  marginal da crítica pode não justificar rodá-la para 100% dos tópicos
  (poderia virar amostragem); se for alta, reforça que ela precisa continuar
  rodando sempre, só não bloqueando.
- Tempo entre EVENT 4 (tela aparece) e o patch do passo 8 — se for muito
  longo (ex. o usuário já terminou de ler o artigo e fechou a tela antes do
  patch chegar), o valor perceptível do upgrade cai; ainda assim vale a pena
  persistir (a próxima visita já vem com a versão corrigida via cache HIT).

**Gatilho de reversão**: se o teste de usuário mostrar que "o exemplo de
código muda sozinho na tela" é confuso/desconfortável mesmo com aviso de
`GenerationStage`, mudar o passo 8 para: só fazer o patch se o usuário
ainda não abriu esse tópico nesta sessão de app (heurística de "não trocar
conteúdo debaixo dos olhos de quem já está olhando"), aplicando a versão
revisada só na PRÓXIMA abertura da tela — mantém o ganho de latência inicial
sem o efeito colateral de UI.

---

## 6. Redução de chamadas Foundation Models

### 6.1 Mapeamento CURRENT → TARGET

```text
CURRENT (por tópico novo, caminho síncrono + background completo)
────────────────────────────────────────────────────────────────
resumo                          → 1 chamada FM
quiz fácil (lote de 6)          → 1 chamada FM
quiz médio (lote de 6)          → 1 chamada FM
exemplo de código: crítica      → 1 chamada FM         ┐ síncronas,
exemplo de código: formatação   → 1 (+0-1 retry) FM     ┘ bloqueiam a tela
                                   subtotal síncrono: 5-6 chamadas FM
                                   + 1 carga MLX + 1 chamada MLX
quiz difícil (6 itens, 2 lotes MLX) → 6 chamadas FM (1 por item, formatação)
análise de código (6 itens, 2 lotes MLX) → 6 críticas + 6 formatações = 12 FM
                                   subtotal background: 18 chamadas FM
                                   + 2 chamadas MLX (lotes de draft)
TOTAL: ~23-24 chamadas FM + ~3 chamadas MLX + 1 carga MLX (bloqueante)


TARGET (mesma unidade de trabalho — 1 tópico novo completo)
────────────────────────────────────────────────────────────────
resumo                          → 1 chamada FM   ┐
quiz fácil (lote de 6)          → 1 chamada FM    │ síncronas,
quiz médio (lote de 6)          → 1 chamada FM    │ bloqueiam a tela
exemplo de código (FM-only)     → 1 chamada FM   ┘
                                   subtotal síncrono: 4 chamadas FM
                                   + ZERO MLX, ZERO carga de modelo

exemplo de código: upgrade (crítica + formatação) → 2 (+0-1 retry) FM
   (condicional só na PRIORIDADE, não na execução — roda sempre, mas nunca
   bloqueia)
quiz difícil (6 itens, 2 lotes MLX de ≤4)   → 2 chamadas FM (formatação
   EM LOTE, 1 por lote de draft, não 1 por item)
análise de código (6 itens, 2 lotes MLX de ≤4) → 2 críticas EM LOTE + 2
   formatações EM LOTE = 4 chamadas FM
                                   subtotal background: 8-9 chamadas FM
                                   + 3 chamadas MLX (mesmo de hoje) + 1
                                   carga MLX (não-bloqueante)
TOTAL: ~12-13 chamadas FM + ~3 chamadas MLX + 1 carga MLX (background)
```

**Redução**: de ~23-24 para ~12-13 chamadas FM por tópico novo (~45-48%
menos chamadas), e a carga de modelo MLX sai inteiramente do caminho
bloqueante. Números de "quantas chamadas" são **CONFIRMED por contagem no
desenho da solução** (é aritmética sobre o fluxo proposto); o ganho de
**tempo** correspondente é `Needs runtime measurement` (cada chamada em
lote é mais cara individualmente que uma chamada de item único, mas paga
menos overhead fixo de sessão — o ganho líquido depende de quanto desse
overhead fixo existe, que é exatamente o que a Fase 0 vai medir).

### 6.2 Batching detalhado

#### 6.2.1 Quiz difícil (formatação)

- **Schema reutilizado**: `QuizQuestionBatch` (`StudyModels.swift:75-77`) —
  já existe, já é usado por `generateQuizBatch` fácil/médio com sucesso
  para 6 itens numa chamada.
- **Schema novo**: nenhum — o formatador recebe N rascunhos MLX (texto
  livre, já delimitados por `MLXService.itemSeparator`) e devolve
  `QuizQuestionBatch` com N `QuizQuestion`.
- **Tamanho ideal do lote**: **≤4**, igual ao tamanho de lote de draft MLX
  já usado (`TopicRepository.swift:464`, `min(4, target - currentCount)`)
  — reaproveita um tamanho já validado no lado MLX, evita introduzir um
  segundo número "mágico" não testado.
- **Orçamento de tokens**: seguir a mesma fórmula já usada e testada em
  produção para lotes FM de `QuizQuestion` (`StudyGenerator.swift:606`,
  `220 * count + 150`) — para um lote de 4: `220*4+150 = 1030`.
- **Risco de truncamento**: médio — o lote de formatação de quiz difícil é
  estruturalmente idêntico ao lote fácil/médio que já roda em produção com
  6 itens (mais que os 4 propostos aqui), então o risco é, se algo, MENOR
  que um padrão já validado.
- **Estratégia de retry**: reaproveitar o padrão de "1 regeneração, senão
  descarta" do `QuestionValidator.processQuizBatch` (`QuestionValidator.swift:136-158`)
  — já opera por item dentro do lote retornado, não precisa mudar.
- **Validação individual**: cada `QuizQuestion` do lote passa por
  `QuestionValidator.isValid` individualmente, como já acontece — batching
  na CHAMADA não muda a granularidade da VALIDAÇÃO.
- **Fallback se um item do lote for inválido**: descartar só o item
  inválido (como já acontece hoje item a item) — a regeneração de
  `regenerateOne` no `QuestionValidator` já é por item único, não por lote;
  manter assim (regenerar 1 item único é mais barato e mais provável de
  corrigir que regenerar o lote inteiro).

#### 6.2.2 Análise de código (crítica + formatação)

- **Schema reutilizado para formatação**: `CodeAnalysisBatch`
  (`StudyModels.swift:97-100`) — já existe, nunca foi usado (a chamada
  atual usa `CodeAnalysisQuestion` individual, não o batch).
- **Schema novo necessário**: **sim, para a crítica em lote** — hoje
  `critiqueCodeDraft` devolve texto livre sem schema
  (`session.respond(to:options:)`, sem `generating:`,
  `StudyGenerator.swift:412-413`); para criticar N rascunhos numa chamada
  só, a resposta precisa distinguir qual crítica corresponde a qual
  rascunho. Duas opções: (a) manter texto livre e pedir explicitamente
  "separe cada crítica com `\(MLXService.itemSeparator)`, na mesma ordem
  dos rascunhos" — reaproveita o padrão já usado pelo MLX para lotes,
  sem exigir schema novo; (b) criar `@Generable struct CritiqueBatch {
  var critiques: [String] }`. Recomendo **(a)** primeiro — mais barato de
  tentar, mesmo padrão de parsing (`components(separatedBy:)`) já usado em
  `MLXService.generateQuestionDrafts` (`MLXService.swift:230-233`); só criar
  o schema estruturado (b) se (a) se mostrar frágil em teste (crítica em
  texto livre com separador é menos garantida que um schema, mas a
  crítica em si já não é estruturada hoje — não é uma regressão).
- **Tamanho ideal do lote**: **≤4**, mesma razão de §6.2.1.
- **Orçamento de tokens**: para a crítica em lote, escalar o orçamento
  individual já usado (`StudyGenerator.swift:412`, 350 tokens/item) —
  proposto: `350 * count` (crítica é mais curta e não tem o overhead fixo
  de formato estruturado, escalar linear é razoável como ponto de partida,
  a calibrar por medição). Para a formatação em lote, escalar o orçamento
  individual já usado (`StudyGenerator.swift:860`, 900 tokens/item) —
  proposto: `900 * count` menos uma margem pequena pelo overhead
  compartilhado do array wrapper, ex. `850 * count + 100`.
- **Risco de truncamento**: maior que o do quiz difícil, porque cada item
  de análise de código carrega um `codeSnippet` (5-15 linhas) — mais
  volume de texto por item. Mitigação: manter o `looksTruncated` +
  retry-mais-curto já existente (`StudyGenerator.swift:865-875`), aplicado
  a CADA item do lote retornado (não ao lote inteiro) — se 1 item vier
  truncado, retry só daquele item (chamada individual, não reprocessa o
  lote inteiro).
- **Fallback se um item do lote estiver inválido**: mesmo padrão do
  `QuestionValidator.processCodeAnalysisBatch` (`QuestionValidator.swift:161-183`)
  — já é por item.

### 6.3 O que NÃO deve ser batched

- **Crítica + formatação do exemplo de código** (fluxo do §5): são 1 item
  só por tópico (não há "lote" de exemplos de código), e formatação
  depende do resultado da crítica (dependência sequencial real, não
  paralelizável nem batchável).
- **Resumo, feedback**: já são 1 chamada cada, sem lote a fazer.

---

## 7. MLX Prompt / KV Cache Design

### 7.1 API real disponível (verificada nesta sessão, não inventada)

Do fetch direto de `Libraries/MLXLMCommon/KVCache.swift` e
`Evaluate.swift` no commit exato pinado (`9bff95ca…`, v2.29.1):

```swift
// protocolo real
public protocol KVCache: Evaluatable {
    var offset: Int { get }
    var maxSize: Int? { get }
    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray)
    var state: [MLXArray] { get set }
    var metaState: [String] { get set }
    var isTrimmable: Bool { get }
    @discardableResult func trim(_ n: Int) -> Int
}

// implementação concreta real, usada por padrão
public class KVCacheSimple: BaseKVCache { ... }

// construtor real de cache pro modelo carregado
public func makePromptCache(
    model: any LanguageModel,
    parameters: GenerateParameters? = nil
) -> [KVCache]

// generate() JÁ aceita cache externo — real, hoje ignorado pelo projeto
public func generate(
    input: LMInput, cache: [KVCache]? = nil, parameters: GenerateParameters,
    context: ModelContext
) throws -> AsyncStream<Generation>

// persistência em disco, se algum dia fizer sentido entre execuções do app
public func savePromptCache(url: URL, cache: [KVCache], metadata: [String: String] = [:]) throws
public func loadPromptCache(url: URL) throws -> ([KVCache], [String: String]?)
public func trimPromptCache(_ cache: [KVCache], numTokens: Int) -> Int
public func canTrimPromptCache(_ cache: [KVCache]) -> Bool
```

`MLXService.generate` hoje chama
`MLXLMCommon.generate(input:parameters:context:)` **sem** o parâmetro
`cache:` (`MLXService.swift:327`) — que é opcional e default `nil`, então
cada chamada cria um `KVCacheSimple` novo via `model.newCache(parameters:)`
internamente (confirmado no `TokenIterator.init`, `Evaluate.swift`:
`self.cache = cache ?? model.newCache(parameters: parameters)`). Isso
confirma, com evidência de código real (não suposição), o achado F4 do
`PLAN.md`: zero reuso de cache entre chamadas, hoje.

Também confirmado: `GenerateParameters` já expõe `maxKVSize`, `kvBits`,
`kvGroupSize`, `prefillStepSize` (default 512) — alavancas reais de
memória/velocidade do prefill, nenhuma usada hoje.

### 7.2 Desenho: cache de prefixo por tópico

**Ideia central**: o system prompt + contexto RAG são **idênticos** (ou
quase — variam um pouco por tarefa, ver 7.2.1) entre as 3 chamadas MLX que
um mesmo tópico dispara (exemplo de código, quiz difícil, análise de
código). Em vez de reprocessar esse prefixo do zero 3 vezes, processar uma
vez ("primed cache") e clonar o estado antes de cada chamada divergente.

```swift
// pseudocódigo — assinaturas aproximadas, NÃO implementar ainda

/// Um cache MLX "primed" com o prefixo comum de um tópico (system prompt
/// genérico de rascunho + contexto RAG do tópico), pronto para ser clonado
/// antes de cada chamada MLX específica de tarefa.
struct TopicPromptCache {
    let topicKey: String       // ex: hash(topic + context) — ver 7.2.2 chave
    let primedState: [KVCache] // snapshot do estado após o prefill do prefixo
    let prefixTokenCount: Int  // pra instrumentação (§10)
}

actor MLXPromptCacheStore {
    private var cached: TopicPromptCache?

    /// Garante que existe um cache primed para este tópico; reusa se a
    /// chave bater, descarta e recria se mudou de tópico.
    func primed(for topic: String, systemPrompt: String, ragContext: String,
                model: any LanguageModel) async throws -> [KVCache] {
        let key = Self.key(topic: topic, systemPrompt: systemPrompt, ragContext: ragContext)
        if let cached, cached.topicKey == key {
            return Self.clone(cached.primedState)   // ver 7.2.3 — clone, não reuso direto
        }
        let fresh = makePromptCache(model: model)   // API real, §7.1
        // "prefill-only": roda o prefixo pelo modelo sem gerar texto de
        // saída (maxTokens: 0 ou 1 descartado) só para popular o cache —
        // ⚠️ precisa de protótipo: confirmar que TokenIterator aceita
        // maxTokens: 0 sem erro, ou usar prefillStepSize + 1 token
        // descartado como forma prática de "só prefill".
        try await Self.prefillOnly(prefix: systemPrompt + "\n" + ragContext,
                                    model: model, cache: fresh)
        let primed = TopicPromptCache(topicKey: key, primedState: fresh,
                                       prefixTokenCount: /* medir, §10 */ 0)
        self.cached = primed
        return Self.clone(fresh)
    }

    private static func clone(_ cache: [KVCache]) -> [KVCache] {
        // usa a API real de state (get/set) — não existe um `.copy()`
        // oficial no protocolo, então "clonar" = criar instâncias novas e
        // copiar o `state`/`metaState` (arrays MLXArray, valor lógico
        // imutável do ponto de vista do chamador mesmo sendo referência —
        // KVCacheSimple.update() sempre realoca/cresce em vez de mutar in
        // place quando precisa crescer, então isso é seguro NA PRÁTICA,
        // mas não é um padrão documentado pela lib — marcar como
        // HYPOTHESIS/protótipo obrigatório antes de confiar em produção)
        cache.map { original in
            let copy = KVCacheSimple()
            copy.state = original.state
            copy.metaState = original.metaState
            return copy as KVCache
        }
    }

    private static func key(topic: String, systemPrompt: String, ragContext: String) -> String {
        // reusar o mesmo padrão de hash já usado em DocumentIndex
        // (SHA256, DocumentIndex.swift:287-291) — não inventar um novo
        // esquema de chave
        Self.sha256("\(topic)\u{1F}\(systemPrompt)\u{1F}\(ragContext)")
    }
}
```

### 7.2.1 O prefixo é REALMENTE idêntico entre as 3 chamadas?

Não 100% — hoje cada chamada tem um `systemPrompt` ligeiramente diferente
("Você é um especialista em Swift. Gere um código de exemplo..." vs.
"...Gere perguntas técnicas difíceis..." vs. "...Gere trechos de código e
perguntas de análise...", `StudyGenerator.swift:270,542,732`). Duas opções:
(a) unificar os 3 `systemPrompt`s num único texto genérico
("Você é um especialista em Swift, ajudando a gerar material de estudo
sobre um tópico específico.") e deixar a instrução ESPECÍFICA da tarefa
(exemplo/quiz/análise) no `promptContext` (que já é o texto que muda por
chamada) — maximiza reuso do prefixo cacheado; (b) manter os 3 prompts
diferentes e aceitar que o prefixo cacheável é só o contexto RAG (menor,
mas ainda é a parte mais longa — ~600-750 palavras vs. 1-2 frases de
system prompt). Recomendo **(a)**, é uma mudança pequena e de baixo risco
(mudar 3 strings de instrução), e maximiza o valor do cache.

### 7.2.2 Chave do cache

`SHA256(topic + systemPrompt unificado + ragContext)` — mesmo padrão já
usado em `DocumentIndex.hash(of:)` (`DocumentIndex.swift:287-291`), não um
mecanismo novo. Como `ragContext` já é determinístico por tópico (filtro
exato, `chunks(forExactTopic:)`), a chave é estável entre as 3 chamadas do
mesmo tópico e muda automaticamente se o dataset mudar (mesma garantia que
já existe pro cache de embeddings).

### 7.2.3 Lifecycle

- **Quando criar**: na primeira chamada MLX de um tópico (dentro da trilha
  de background — nunca no caminho síncrono, já que MLX não está mais lá,
  D1).
- **Quando reutilizar**: nas chamadas MLX seguintes do MESMO tópico, dentro
  da mesma sessão de geração em background (`growPoolInBackground`).
- **Quando destruir**: ao trocar de tópico (chave não bate) — descartar o
  `primedState` anterior e criar um novo; **não** manter um cache por
  tópico indefinidamente em memória (custo de RAM cresce com o número de
  tópicos gerados na sessão do app) — manter só o **último** tópico primed
  (`cached: TopicPromptCache?`, um valor só, não um dicionário) é
  suficiente, porque o crescimento em background de um tópico roda até o
  fim antes do próximo tópico tipicamente começar (fila serial MLX, D5).
- **Ownership**: vive dentro de `MLXService` (ou um novo tipo auxiliar
  injetado nele), não em `TopicRepository` — é um detalhe de implementação
  do motor MLX, não da camada de persistência.
- **Concorrência**: `actor` (como o pseudocódigo acima) — a fila MLX do
  `GenerationOrchestrator` já serializa as chamadas que usariam isso, então
  não há race condition real, mas encapsular como `actor` custa pouco e
  remove qualquer dúvida.
- **Memória**: cada `KVCache` primed ocupa memória proporcional ao tamanho
  do prefixo em tokens × dimensões do modelo — para o contexto RAG atual
  (pequeno, 8 chunks no total, ~600-750 palavras por tópico) isso é
  pequeno; ver §11 para como medir com `GPU.snapshot()` antes/depois de
  primar o cache.
- **Comportamento ao trocar de tópico**: descarta e recria (acima) — nunca
  reusa cache de um tópico para outro (contexto RAG diferente tornaria a
  geração incorreta).

### 7.3 O que NÃO fazer (descartado conscientemente)

- **Persistir o cache em disco entre execuções do app**
  (`savePromptCache`/`loadPromptCache`, API real confirmada) — descartado
  por ora: o cache só vale a pena durante a janela em que os 3 usos MLX de
  um tópico acontecem em sequência (minutos, não sessões do app); overhead
  de I/O de `.safetensors` provavelmente não se paga para esse caso de uso.
  Reconsiderar só se o dataset crescer a ponto do contexto RAG por tópico
  ficar grande o suficiente pra tornar o prefill caro mesmo fora dessa
  janela.
- **`ChatSession`** — não existe na versão pinada (§0, confirmado por
  fetch), não é uma opção hoje sem migrar de versão (ver §23).
- **KV cache quantizado (`kvBits`)** — API real existe
  (`GenerateParameters.kvBits`, `QuantizedKVCache`), mas é uma otimização de
  MEMÓRIA, não de latência de prefill; só faz sentido se `GPU.snapshot()`
  (§11) mostrar pressão de memória real com o cache de prefixo ativo — não
  aplicar preventivamente.

### 7.4 BENCHMARK

Comparar, para os 3 tópicos do dataset atual: TTFT (§10) da 2ª e 3ª chamada
MLX de um mesmo tópico, COM e SEM o cache primed. **SUCCESS CRITERIA**: TTFT
da 2ª/3ª chamada cai de forma mensurável (>10%, número de corte a calibrar
depois de ver a variância natural das medições) em relação à 1ª chamada do
mesmo tópico, sem regressão de qualidade de saída (comparar texto gerado
com/sem cache para o mesmo prompt — deveria ser idêntico ou
estatisticamente equivalente, já que só muda ONDE o prefill é computado,
não o conteúdo semântico do prompt). **ROLLBACK**: reverter para `cache:
nil` (comportamento atual, 1 linha de mudança) se a saída divergir de forma
não-trivial ou se o padrão de clone se mostrar instável (crash, memória
descontrolada) em teste.

---

## 8. Modelo MLX — análise nova

### 8.0 Por que a análise muda com a Estratégia D (§5)

Com D1/D5, o MLX **sai do caminho síncrono** — o usuário nunca mais espera
diretamente pela geração MLX. Isso muda o critério de escolha: latência de
TTFT/tokens-por-segundo continua importando (menos trabalho de background
pendente = pool completo mais cedo = menos tempo com quiz difícil/análise
desabilitados), mas **qualidade e taxa de hallucination passam a pesar
mais** que velocidade bruta, porque o custo de tempo já não é sentido
diretamente pelo usuário na tela que ele está olhando.

### 8.1 Model Requirements

Critérios, na ordem de importância PARA ESTE produto (não uma lista
genérica — derivada de §5, §8.0 e do histórico de bugs reais do projeto):

1. **Baixa hallucination de API Swift/SwiftUI** — é a causa raiz documentada
   do pipeline de crítica existir (`PLAN.md` §8.1); é o critério #1.
2. **Instruction-following em tarefas de formato rígido** — o modelo
   precisa respeitar o `itemSeparator` em lotes (`MLXService.swift:52,230-233`)
   e o formato `CODIGO:`/`PASSO A PASSO:` pedido nos prompts
   (`StudyGenerator.swift:260-266`); o próprio histórico do projeto já
   documentou que o 14B seguia essas instruções "com mais consistência que
   o 7B" (commit `5f1305a`) — evidência própria, não genérica.
3. **Raciocínio técnico curto em Swift/SwiftUI/concorrência** — precisa
   gerar rascunhos de quiz difícil e trechos de análise de código
   plausíveis e tecnicamente corretos.
4. **Execução local eficiente em Mac com RAM unificada compartilhada com
   Foundation Models + resto do sistema** — restrição real e já
   evidenciada (o MoE de 30B causou swap, comentário de cabeçalho de
   `MLXService.swift:7-15`).
5. **Compatibilidade comprovada com o stack MLX instalado** (`mlx-swift`
   0.29.1 / `mlx-swift-examples` 2.29.1, arquitetura Qwen2 já suportada
   pelo `MLXLLM` usado no projeto).

### 8.2 Model Candidates

Todos os repositórios abaixo foram **verificados via busca nesta sessão**
(existência confirmada na organização `mlx-community` do Hugging Face).
Tamanhos de download em GB: os de 3B/7B/14B vêm do **próprio histórico de
commits deste projeto** (números que a equipe já confirmou na página do
modelo, não estimativa minha — `PLANOS_DE_MELHORIA.md`/commits `5f1305a`,
`MLXService.swift:44-49`). Os demais (0.5B, 1.5B, 32B) são **interpolados**
a partir da razão GB/parâmetro observada nesses 3 pontos confirmados
(~0.57-0.61 GB por bilhão de parâmetros em 4-bit) — marcados como
estimativa, não como número confirmado; confirmar na página do HF antes de
qualquer download real.

| Modelo (mlx-community) | Params | Quantização | Download/RAM (GB) | Swift/Coding | Velocidade esperada | Qualidade esperada | Compat. MLX | Risco |
|---|---:|---|---:|---|---|---|---|---|
| `Qwen2.5-Coder-0.5B-Instruct-4bit` | 0.5B | 4-bit | ~0.3-0.4 (estimado) | Baixa — modelo pequeno demais pra crítica técnica confiável | Muito alta | Baixa — alto risco de instruction-following fraco em lotes | Sim (mesma família já em uso) | Alto risco de qualidade insuficiente para a tarefa de crítica |
| `Qwen2.5-Coder-1.5B-4bit`\* | 1.5B | 4-bit | ~0.85-0.95 (estimado) | Baixa-Média | Muito alta | Baixa-Média | Sim | Risco de qualidade; \*variante `-Instruct-` não confirmada nesta sessão — verificar antes de considerar |
| `Qwen2.5-Coder-3B-Instruct-4bit` | 3B | 4-bit | ~1.7 (confirmado, histórico do projeto) | Média | Alta | Média — já testado neste projeto e trocado por qualidade insuficiente no pipeline de crítica (histórico de commits, troca 3B→7B) | Sim (já rodou neste projeto) | Baixo risco técnico, risco de qualidade já observado |
| **`Qwen2.5-Coder-7B-Instruct-4bit`** (ATUAL) | 7B | 4-bit | ~4.3 (confirmado, `MLXService.swift:49`) | Boa | Média | Boa — em produção hoje, sem relato de swap/pressão de memória | Sim (rodando em produção) | Baixo — já validado |
| `Qwen2.5-Coder-14B-Instruct-4bit` | 14B | 4-bit | ~8.3 (confirmado, commit `5f1305a`) | Muito boa (relato próprio do projeto: segue instruções complexas com mais consistência que o 7B) | Média-Baixa | Muito boa | Sim (já rodou neste projeto, commit `5f1305a`) | Médio — nunca testado sob a carga combinada de MLX+FM+RAG residentes ao mesmo tempo que a arquitetura TARGET propõe (rodava sozinho quando testado) |
| `Qwen2.5-Coder-32B-Instruct-4bit` | 32B | 4-bit | ~18-19 (estimado, interpolado) | Excelente (esperado) | Baixa | Excelente (esperado) | Sim | **Alto** — tamanho próximo ao do MoE de 17,2 GB já rejeitado por pressão de memória; sem evidência nova, mesma classe de risco |
| `Qwen3-Coder-30B-A3B-Instruct-4bit` | 30B (MoE, ~3B ativos) | 4-bit | ~17-18 (já testado neste projeto) | Boa (MoE) | Média (ativação esparsa) | Boa | Sim | **Já rejeitado neste projeto** (header de `MLXService.swift:7-15`) por swap/pressão de memória — não reabrir sem evidência nova |

\* Não confirmei nesta sessão se existe uma variante `-Instruct-` do
1.5B especificamente (o resultado de busca mostrou `Qwen2.5-Coder-1.5B-4bit`
sem sufixo `-Instruct-`, e `Qwen2.5-1.5B-Instruct-4bit` — que é a linha
BASE do Qwen2.5, não a linha `-Coder`); **não incluir no download real sem
confirmar exatamente qual variante existe**.

**Famílias fora do escopo desta análise** (não pesquisadas a fundo nesta
sessão — não invento avaliação sobre elas): DeepSeek-Coder, StarCoder2,
CodeGemma, Yi-Coder. Se algum dia forem consideradas, precisam da mesma
verificação de existência real em `mlx-community` + compatibilidade
confirmada com a arquitetura suportada pelo `MLXLLM` instalado antes de
entrarem numa tabela como esta.

### 8.3 Recommended MLX Model

> ## KEEP CURRENT MODEL
> `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit`

**Por quê**: é o único modelo, além do 14B (ver alternativa de qualidade
abaixo), com evidência real de funcionar bem DENTRO deste projeto
especificamente — sem relato de swap, com download/carga já validados, e
já integrado ao pipeline de crítica com resultados documentados como
aceitáveis (o histórico de bugs corrigidos, `PLANO_V5.md`, é sobre a
LÓGICA do pipeline — prompt de crítica, 2 passadas —, não sobre o 7B ser
incapaz de gerar código plausível). Trocar de modelo sem uma causa concreta
identificada (a causa real do achado F1 é ARQUITETURA — MLX no caminho
síncrono —, não o modelo em si) seria otimizar a variável errada.

**Por que não permanecer seria pior agora**: não seria — permanecer é a
recomendação. A pergunta "por que não o 14B" está respondida na alternativa
de qualidade abaixo: falta uma variável de evidência (14B nunca rodou sob a
carga combinada MLX+FM residentes simultaneamente, que é exatamente o
cenário que a arquitetura D introduz — hoje MLX e FM já rodam em paralelo
via `async let`, mas o 14B foi testado ANTES dessa mudança, então ainda não
tem evidência sob a topologia atual).

**Expectativa de TTFT / tokens/s / memória**: `Needs runtime measurement`
— nenhum número de tokens/s real existe hoje no projeto (§9/§10 resolvem
isso). Não vou inventar uma expectativa numérica sem o benchmark rodar.

**Impacto sobre o pipeline**: com D1/D5, o modelo passa a rodar só em
background — isso **reduz a urgência** de trocar por algo mais rápido
(o usuário não sente diretamente), o que reforça a recomendação de manter
o 7B (ou considerar o 14B) em vez de baixar para 3B só por velocidade.

### Performance Alternative

> `mlx-community/Qwen2.5-Coder-3B-Instruct-4bit`

Já rodou neste projeto (histórico de commits) e foi trocado por qualidade
insuficiente **quando estava no caminho síncrono** (a pressão por
velocidade existia porque o usuário esperava). Com D1/D5 tirando o MLX do
caminho síncrono, a motivação original para essa troca (latência
percebida) desaparece — então recomendo o 3B só como alternativa para
hardware mais fraco (Macs com menos RAM unificada, fora do "Mac de 24GB"
assumido no comentário de `MLXService.swift:10-11`) ou se o benchmark do
Phase 0 mostrar que o volume de trabalho de background (mesmo não-bloqueante)
está gerando pressão térmica/de bateria perceptível em uso prolongado.

### Quality Alternative

> `mlx-community/Qwen2.5-Coder-14B-Instruct-4bit`

Candidato mais forte que "considerar" — tem evidência real e própria do
projeto de funcionar (commit `5f1305a`) e de ser qualitativamente melhor
em instruction-following que o 7B, segundo a própria equipe. A única
lacuna é a variável nova introduzida por este documento (MLX+FM residentes
ao mesmo tempo, cache de prefixo do §7 também residente). Recomendo
promover a **Recommended** SE o benchmark do §9 confirmar, sob a topologia
TARGET completa (não isolado), que não há pressão de memória/swap — sinal
a observar: `GPU.snapshot()` (§11) mostrando `cacheMemory`+`activeMemory`
dentro do `memoryLimit` reportado por `GPU.deviceInfo()`, sem crescimento
sustentado ao longo de uma sessão de geração de pool completo.

---

## 9. MLX Model Benchmark Suite

### 9.1 Prompts representativos (18)

Cobrem os 3 tópicos reais do dataset (`PlaceholderDocs.swift`) + tarefas
fora do dataset para testar hallucination em terreno não coberto pelo RAG
(o modelo precisa admitir incerteza ou recusar, não inventar). Cada prompt
usa o MESMO formato de instrução que o código de produção usa hoje
(reaproveitar `StudyGenerator.swift:243-266,528-536,713-727`), não um
formato de benchmark artificial.

| # | Categoria | Prompt (resumo) | Tópico/contexto RAG |
|---|---|---|---|
| 1 | Geração de exemplo | Exemplo de uso de `NavigationStack` com `navigationDestination(for:)` | NavigationStack (contexto real do dataset) |
| 2 | Geração de exemplo | Exemplo de uso de `@State`/`@Observable` numa View real | Property Wrappers (contexto real) |
| 3 | Geração de exemplo | Exemplo de `async let` com 2 operações paralelas | async/await (contexto real) |
| 4 | Identificação de API inexistente | Rascunho com `NavigationPath.popToRoot()` (método que não existe) — pedir crítica | NavigationStack |
| 5 | Bug semântico | Rascunho com `.navigationDestination(for: 1)` (valor em vez de tipo) — pedir crítica | NavigationStack |
| 6 | Bug semântico | Rascunho com `@StateObject` aplicado a um `Int`/`Bool` — pedir crítica | Property Wrappers |
| 7 | Bug semântico | Rascunho com `Button("Salvar")` sem `action:`/closure — pedir crítica | Property Wrappers |
| 8 | Pergunta difícil | Gerar 1 pergunta técnica avançada sobre `NavigationPath` type-erasure | NavigationStack |
| 9 | Pergunta difícil | Gerar 1 pergunta técnica avançada sobre granularidade de `@Observable` | Property Wrappers |
| 10 | Pergunta difícil | Gerar 1 pergunta técnica avançada sobre `Task.detached` vs. `Task` estruturada | async/await |
| 11 | Pergunta difícil em LOTE (4) | Gerar 4 perguntas avançadas distintas sobre async/await numa única chamada | async/await (testa §6.2.1) |
| 12 | Análise de código | Trecho com `actor` e 2 chamadas concorrentes a um método — perguntar comportamento | (Actors não está no dataset atual — testa raciocínio fora do RAG) |
| 13 | Análise de código em LOTE (4) | 4 trechos distintos sobre closures capturando `self` — pedir comportamento de cada | (fora do dataset — testa §6.2.2) |
| 14 | Explicação técnica curta | Explicar em 2-3 frases a diferença entre `@Binding` e `@State` | Property Wrappers |
| 15 | Adherence à instrução de formato | Pedir resposta EXATA no formato `CODIGO:`/`PASSO A PASSO:` sem markdown | NavigationStack |
| 16 | Adherence ao RAG | Perguntar algo que o contexto RAG NÃO cobre (ex.: `NavigationSplitView`) — o modelo deveria evitar inventar e sinalizar que não tem certeza | NavigationStack (contexto deliberadamente insuficiente) |
| 17 | Instruction-following em lote | Pedir 4 itens separados por `MLXService.itemSeparator` e verificar se os 4 delimitadores saem corretos | qualquer tópico |
| 18 | Raciocínio sobre concorrência | Pedir explicação de por que `Task.detached` "joga fora garantias estruturais" (conceito do próprio dataset, `PlaceholderDocs.swift:263-270`) | async/await |

### 9.2 Métricas por modelo/prompt

`load time`, `memory footprint` (via `GPU.snapshot()`, API real — §11),
`TTFT`, `prompt tokens`, `output tokens`, `tokens/sec` (via
`GenerateCompletionInfo`, API real confirmada em `Evaluate.swift` — já
devolve `promptTokenCount`, `generationTokenCount`, `promptTime`,
`generateTime`, `promptTokensPerSecond`, `tokensPerSecond` **prontos**, sem
precisar calcular na mão), `total latency`, e as avaliações qualitativas da
rubrica abaixo.

### 9.3 Rubrica de qualidade

| Critério | Peso | Justificativa do peso |
|---|---:|---|
| API real (sem hallucination) | 30 | Critério #1 de §8.1 — é a causa raiz documentada do pipeline de crítica existir |
| Instruction following (formato/separador) | 25 | O pipeline inteiro depende de parsing determinístico do output (`itemSeparator`, `CODIGO:`/`PASSO A PASSO:`) — falha aqui quebra o parsing, não só a qualidade |
| Grounding (adherence ao RAG, sem inventar além do contexto) | 20 | Mitiga hallucination num nível diferente da API (inventar COMPORTAMENTO, não só nome de método) |
| Correção Swift (compilaria) | 15 | Importante, mas parcialmente redundante com "API real" — peso menor pra não duplo-contar |
| Latência (TTFT + tokens/s) | 7 | Pesa pouco DE PROPÓSITO — com D1/D5, MLX não está mais no caminho que o usuário sente diretamente |
| Memória | 3 | Só vira crítico se `GPU.snapshot()` mostrar pressão real — peso simbólico até haver esse dado |

**Nota explícita**: os pesos refletem a arquitetura TARGET (MLX em
background). Se a Estratégia D (§5) for revertida por algum motivo e o MLX
voltar ao caminho síncrono, os pesos de latência/memória devem subir e os
de qualidade/grounding devem cair proporcionalmente — a rubrica não é
universal, é derivada da decisão de arquitetura deste documento.

### 9.4 Como declarar um vencedor

Não escolher só por tokens/s (regra explícita do pedido). Calcular um score
ponderado pela rubrica acima para cada modelo candidato (§8.2, restrito aos
que passarem o filtro de memória do §11) rodando os 18 prompts; o vencedor é
o modelo com maior score ponderado, com um veto duro: **qualquer modelo com
≥1 ocorrência de API inventada nos prompts 4-7 (categoria "bug
semântico"/"identificação de API inexistente") fica automaticamente abaixo
de qualquer modelo com zero ocorrências**, independentemente do score total
— reflete a prioridade #1 do produto (F30, §20) de nunca reintroduzir os
bugs de hallucination já documentados.

---

## 10. Instrumentação — `GenerationMetrics`

### 10.1 Struct

```swift
// Novo arquivo: Services/GenerationMetrics.swift
// Puramente de profiling técnico — não é analytics de produto, não sai do
// device, não é persistido além da sessão de desenvolvimento (a menos que
// explicitamente exportado — ver 10.4).

struct GenerationMetrics: Sendable, Codable {
    enum Engine: String, Codable { case foundationModels, mlx }
    enum TaskType: String, Codable {
        case summary, easyQuiz, mediumQuiz, hardQuizDraft, hardQuizFormat,
             codeExampleDraft, codeExampleCritique, codeExampleFormat,
             codeAnalysisDraft, codeAnalysisCritique, codeAnalysisFormat,
             feedback, embeddingIndex
    }
    enum CacheState: String, Codable { case hit, miss, notApplicable }

    let id: UUID
    let timestamp: Date
    let engine: Engine
    let taskType: TaskType
    let topic: String
    let modelID: String              // MLXService.modelID ou "system" (FM)
    let isColdStart: Bool            // true se envolveu loadModel() nesta chamada
    let inputTokenCount: Int?        // MLX: de GenerateCompletionInfo.promptTokenCount (real)
                                      // FM: Needs runtime measurement (ver 10.2)
    let outputTokenCount: Int?       // idem
    let timeToFirstTokenMs: Double?  // só MLX, via promptTime da GenerateCompletionInfo
    let decodeTimeMs: Double?        // generateTime da GenerateCompletionInfo
    let totalTimeMs: Double
    let tokensPerSecond: Double?     // GenerateCompletionInfo.tokensPerSecond (real, já pronto)
    let retryCount: Int
    let ragContextChars: Int
    let ragChunkCount: Int
    let batchSize: Int               // 1 se não for lote
    let promptCacheState: CacheState // hit/miss/notApplicable (§7)
    let memoryBeforeBytes: Int?      // GPU.snapshot() antes, só quando relevante (§11)
    let memoryAfterBytes: Int?
}
```

### 10.2 Onde instrumentar

| Ponto de instrumentação | Arquivo:linha (atual) | O que captura |
|---|---|---|
| `MLXService.generate` | `MLXService.swift:316-342` | Trocar `MLXLMCommon.generate(input:parameters:context:)` pela variante que já devolve `GenerateCompletionInfo`/usa o stream `.info(let info)` (API real, `Evaluate.swift`, `Generation.info`) em vez de só acumular `outputText` — isso dá `promptTokenCount`, `generationTokenCount`, `promptTime`, `generateTime`, `tokensPerSecond` **de graça**, sem calcular nada na mão. Substitui a métrica de "chars/s" (F9) diretamente. |
| `MLXService.loadModel`/`performLoad` | `MLXService.swift:129-167` | `isColdStart`, tempo de carga (já logado, só precisa virar um `GenerationMetrics` em vez de só `print`) |
| `StudyGenerator.generateSummary` etc. (todas as chamadas FM) | `StudyGenerator.swift` (vários) | `totalTimeMs` via `Self.timed`-like wrapper (já existe o padrão em `TopicRepository.swift:262-266`, só precisa devolver a métrica em vez de só imprimir). **Tokens de entrada/saída do FM**: `Needs runtime measurement` — o framework fechado não expõe contagem de tokens no código do projeto; se a API pública do `FoundationModels` não expõir isso (não verificado nesta sessão, fonte fechada), a alternativa é tokenizar `prompt`/`response.content` localmente só para fins de diagnóstico, usando o MESMO tokenizer já disponível via `Tokenizers` (dependência já presente via `swift-transformers`, usada pelo MLX) — aproximado, não exato, mas comparável entre execuções. |
| `DocumentIndex.buildIndex` | `DocumentIndex.swift:71-103` | `embeddingIndex` task type, cache hit/miss (já logado em texto — vira métrica) |
| `StudyGenerator.retrieveContext` | `StudyGenerator.swift:89-96` | `ragChunkCount`, `ragContextChars` |
| `TopicPromptCache` (§7, novo) | novo | `promptCacheState` |
| `QuestionValidator.process*Batch` | `QuestionValidator.swift:136-183` | `retryCount` (contar regenerações) |

### 10.3 API de coleta

```swift
actor GenerationMetricsStore {
    static let shared = GenerationMetricsStore()
    private var records: [GenerationMetrics] = []

    func record(_ metric: GenerationMetrics) {
        records.append(metric)
        // mantém o print existente em paralelo (não remove o hábito já
        // estabelecido no projeto de logar com prefixo emoji) — a store é
        // ADITIVA à instrumentação atual, não substitui o console
        print("📊 [\(metric.taskType.rawValue)/\(metric.engine.rawValue)] \(metric.totalTimeMs.formatted())ms" +
              (metric.tokensPerSecond.map { " · \($0.formatted()) tok/s" } ?? ""))
    }

    func snapshot() -> [GenerationMetrics] { records }

    /// Agregação simples por taskType — média/percentis, pra não precisar
    /// abrir uma planilha só pra ler o console.
    func summary() -> [GenerationMetrics.TaskType: (count: Int, avgMs: Double, p50Ms: Double)] {
        // implementação trivial de agregação — sem dependência nova
    }
}
```

### 10.4 Como imprimir / exportar durante desenvolvimento

- **Console**: mantém o padrão `print` com emoji já usado no projeto
  (consistência, §9.3 do `PLAN.md` já documentou esse padrão como
  intencional) — `record(_:)` já imprime uma linha resumida.
- **Exportação pontual**: um método `GenerationMetricsStore.exportJSON() ->
  Data` (usa `Codable`, sem dependência nova) chamável a partir de uma
  das telas de debug já existentes (`TopicRepositoryTestView`, que já tem
  um padrão de log em tela, `TopicRepositoryTestView.swift:295-312`) — um
  botão "Exportar métricas da sessão" que escreve o JSON em
  `FileManager.default.urls(for: .documentDirectory,...)`, mesmo padrão de
  `DocumentIndex.cacheURL` (`DocumentIndex.swift:278-285`). Não é
  analytics de produção — fica atrás da mesma tela de debug que já existe
  e já é candidata a sair da navegação de produção (F18).
- **Visualização**: nenhuma ferramenta nova — o JSON exportado é
  suficiente para abrir numa planilha/notebook ad-hoc durante o
  desenvolvimento das fases seguintes. Não vale construir um dashboard
  para isso agora (seria complexidade desproporcional ao objetivo de
  profiling técnico único).

---

## 11. MLX Memory Strategy

### 11.1 O que a API real permite medir/controlar (confirmado, §0)

- `GPU.snapshot() -> Snapshot { activeMemory, cacheMemory, peakMemory }`
- `GPU.cacheMemory` / `GPU.activeMemory` / `GPU.peakMemory`
- `GPU.cacheLimit` (getter) / `GPU.set(cacheLimit:)` (setter) — "cache
  includes memory not currently used that has not been returned to the
  system allocator... buffers from previous computations kept in a buffer
  pool for potential reuse" (doc real, lida nesta sessão)
- `GPU.memoryLimit` / `GPU.set(memoryLimit:relaxed:)` — limite total,
  default "1.5x o `recommendedMaxWorkingSetSize` do Metal"
- `GPU.withWiredLimit(_:_:)` — altera temporariamente o limite de memória
  "wired" (relevante pro comentário do cabeçalho de `MLXService.swift:10-11`
  sobre o macOS limitar memória wired da GPU a ~75% da RAM unificada)
- `GPU.deviceInfo() -> DeviceInfo { architecture, maxBufferSize,
  maxRecommendedWorkingSetSize, memorySize }`
- `GPU.clearCache()`

Nenhum desses é usado hoje no projeto (confirmado, grep vazio, F6).

### 11.2 Estratégia — não escolher valores mágicos

A própria documentação da API (lida nesta sessão) já avisa: "the optimal
cache size varies significantly by workload... developers often find that
relatively small cache sizes (e.g., 2MB) perform just as well... The best
approach is to experiment with different cache limits and measure
performance for your particular workload." Ou seja, mesmo a fonte oficial
recomenda benchmark, não um valor fixo — reforça a regra do documento
(§26 das regras finais: não valores mágicos).

### 11.3 Benchmark para decidir cada parâmetro

| Parâmetro | Como medir | Critério de decisão |
|---|---|---|
| `cacheLimit` | Rodar os 18 prompts do §9 com `cacheLimit` em pelo menos 3 valores (default/sem alterar, ~2MB conforme sugestão da doc, e um valor intermediário ex. 64MB) — medir `tokensPerSecond` (via `GenerateCompletionInfo`, §10) e `GPU.cacheMemory` pico por valor | Escolher o menor valor que não regride `tokensPerSecond` de forma mensurável — cache menor = memória devolvida ao sistema mais cedo, sem custo de performance |
| `memoryLimit` | Só ajustar se `GPU.deviceInfo().maxRecommendedWorkingSetSize` sugerir que o default (1.5x) está perto demais do limite físico ao rodar o modelo Quality Alternative (14B, §8) simultaneamente com Foundation Models residente | Não mexer preventivamente — só se `GPU.snapshot()` mostrar `activeMemory` chegando perto do `memoryLimit` em uso real |
| `withWiredLimit` | Testar só se o benchmark do 14B (§8.3) mostrar sinais de pressão de memória wired (o cenário que já causou swap com o MoE de 30B, header de `MLXService.swift`) | Usar como mitigação pontual durante a carga do modelo maior, não como configuração permanente |
| KV cache quantizado (`kvBits`, §7.3) | Só medir se o cache de prefixo do §7 mostrar footprint de memória relevante em `GPU.snapshot()` | Não aplicar preventivamente (regra geral do documento) |

### 11.4 Modelo residente quando não está sendo usado

Hoje o modelo MLX fica carregado na RAM indefinidamente após o primeiro
`loadModel()` (`isLoaded = true`, nunca há um caminho de descarregar,
confirmado por leitura completa de `MLXService.swift`). Isso é uma decisão
correta para este produto: com D1/D5, o MLX passa a ser usado
repetidamente em background (upgrade de exemplo, quiz difícil, análise de
código, para CADA tópico visitado) — descarregar e recarregar entre usos
pagaria o custo de carga (que já foi o vilão original do achado F1)
repetidamente. **Não introduzir descarregamento automático** a menos que o
Phase 0 mostre pressão de memória sustentada em sessões longas com muitos
tópicos abertos — nesse caso, um TTL de inatividade (ex.: descarregar após
N minutos sem nenhum job na fila MLX) seria a mitigação, não descarregar
a cada uso.

---

## 12. MLX Warm-up Strategy

### 12.1 Warm-up de pesos (já existe) vs. warm-up de inferência (não existe)

Confirmado em `PLAN.md` §2.9: `prewarmIfCached` (`MLXService.swift:299-314`)
só carrega os PESOS na RAM; não há nenhuma chamada de geração "descartável"
para aquecer o grafo de computação MLX (compilação/JIT de kernels Metal na
1ª chamada real).

### 12.2 Warm-up real é necessário?

`HYPOTHESIS` — não confirmável sem medir. A forma de descobrir é
justamente comparar TTFT/tokens-por-segundo da 1ª chamada MLX real de uma
sessão de app vs. a 2ª/3ª (usando a instrumentação do §10, que já devolve
`promptTime`/`tokensPerSecond` reais via `GenerateCompletionInfo`).

### 12.3 Se for necessário: qual prompt mínimo, quando executar

- **Prompt mínimo**: reusar o MESMO prefixo que o cache de prefixo do §7 já
  vai primar na primeira chamada MLX real de qualquer tópico — ou seja, SE
  o warm-up for necessário, ele pode ser literalmente a etapa de "primed
  cache" do §7 rodando um pouco mais cedo (na hora do `prewarmIfCached`,
  não só na hora do primeiro tópico precisar de MLX) — não introduz um
  MECANISMO novo, só adianta um que já existe no design. Evita o
  anti-padrão de "gerar um prompt fake tipo 'oi' só pra aquecer", que
  gastaria um ciclo de compilação em tokens/formato diferentes do uso real.
- **Quando executar**: só quando `prewarmIfCached` já decidiu carregar o
  modelo (ou seja, só quando os pesos já estão em cache local — a mesma
  guarda condicional que já existe, `MLXService.swift:299-314`, "sem
  download não-solicitado"). Rodar o warm-up de inferência
  IMEDIATAMENTE após `loadModel()` completar dentro do mesmo
  `Task.detached(priority: .utility)` (`MLXService.swift:311`), sem
  esperar o primeiro tópico real precisar de MLX.
- **Quando NÃO executar**: se os pesos não estão em cache local (evita
  disparar carga+warm-up não solicitados, mesma regra já aplicada ao
  download); se o app acabou de abrir e ainda está construindo o índice
  RAG (`ensureReady`) — não competir por CPU/I want com o launch inicial,
  ainda que agora `ensureReady` não bloqueie mais a tela (F12/§18), ele
  ainda consome recursos: manter o warm-up de inferência com prioridade
  `.utility`, igual ao resto do pré-aquecimento hoje.

### 12.4 Impacto energético

`Needs runtime measurement` — um warm-up de inferência custa uma geração
"descartável" real (não é grátis). Se o Phase 0 mostrar que a diferença
1ª-vs-2ª-chamada é pequena (compilação de grafo Metal já é rápida o
suficiente), **não vale o custo energético** de rodar um warm-up sempre no
launch — nesse caso, aceitar que a primeira chamada MLX de cada sessão do
app é um pouco mais lenta (ela já roda em background, D1/D5, então o custo
extra não é sentido pelo usuário do mesmo jeito que seria se MLX ainda
estivesse no caminho síncrono).

### 12.5 Como evitar deixar a inicialização do app mais lenta

Mesma resposta de sempre neste documento: manter tudo em
`Task.detached(priority: .utility)`, nunca no caminho de `RootTabView.task`
que já hoje só dispara `prewarmIfCached()` de forma fire-and-forget
(`RootTabView.swift:33`) — não mudar essa característica.

---

## 13. Token Budget Strategy

Formato pedido por operação. Valores atuais são citados de `PLAN.md` §3
(já verificados linha a linha); valores propostos são pontos de partida
para calibração via §10, não números finais.

**summary**
```text
current:  750 (StudyGenerator.swift:224)
proposed: manter 750 — já foi calibrado com evidência real (subiu de 500,
          comentário do próprio código explica o motivo, commit 5f1305a)
reason:   não mexer no que já foi calibrado por medição real anterior
risk:     nenhum (sem mudança)
fallback: n/a
```

**code example (FM-only, síncrono — novo papel principal, D1)**
```text
current:  1600, via generateCodeExampleFromScratch (StudyGenerator.swift:456)
          — hoje é só fallback, pouco exercitado
proposed: manter 1600 como ponto de partida, mas MEDIR taxa de truncamento
          real agora que este caminho vira o principal (era fallback raro)
reason:   o orçamento foi dimensionado pensando em ser fallback ocasional;
          precisa validar que aguenta ser o caminho comum
risk:     se a taxa de truncamento subir sob uso constante, aumentar
          seguindo o mesmo raciocínio já documentado no código (walkthrough
          repete trechos do código, ~2x o tamanho do código em si)
fallback: retry com "8 linhas/3 passos" já existe (StudyGenerator.swift:463-471)
          — reaproveitar sem mudança
```

**code example: critique (background, D1/§5)**
```text
current:  350 (StudyGenerator.swift:412)
proposed: manter — não muda de papel, só de prioridade de execução
reason:   sem motivo para recalibrar algo que não mudou de forma
risk:     nenhum
fallback: n/a
```

**code example: formatting/upgrade (background, D1/§5)**
```text
current:  1600, +1600 no retry (StudyGenerator.swift:353,361)
proposed: manter
reason:   já calibrado por 2 rodadas de hotfix documentadas (PLANO_V5.md §3)
risk:     nenhum
fallback: já existe (retry-mais-curto)
```

**easy quiz / medium quiz**
```text
current:  220 * count + 150 (StudyGenerator.swift:606)
proposed: manter a fórmula; se D3/§6 padronizar batch=6 pra estes dois
          (já é 6 hoje) não muda nada aqui
reason:   já calibrado com evidência real (comentário explica que 600
          fixo causava decodingFailure)
risk:     nenhum
fallback: n/a
```

**hard quiz — formatação (agora em LOTE, §6.2.1)**
```text
current:  NENHUM explícito (StudyGenerator.swift:687-693) — bug F8/CONFIRMED
proposed: 220 * count + 150 (MESMA fórmula do quiz fácil/médio, count ≤ 4)
reason:   reusa uma fórmula já validada em produção em vez de inventar uma
          nova; corrige a inconsistência apontada em F8
risk:     baixo — é a mesma fórmula que já funciona pra QuizQuestion em
          lote (fácil/médio usam até 6, aqui propomos ≤4)
fallback: aplicar o MESMO looksTruncated + retry-mais-curto que
          formatCodeExample já tem (StudyGenerator.swift:357-365) — hoje
          formatHardQuestion não tem NENHUM (segunda parte do bug F8)
```

**hard quiz — draft MLX**
```text
current:  300 * count + 50 (MLXService.swift:227)
proposed: manter
reason:   já é uma fórmula de lote calibrada, sem evidência de problema
risk:     nenhum
fallback: n/a
```

**code analysis — crítica (agora em LOTE, §6.2.2)**
```text
current:  350 por item, individual (StudyGenerator.swift:412, reusado)
proposed: 350 * count (linear, ponto de partida — calibrar por medição)
reason:   crítica é texto livre curto, escalar linear é razoável como
          primeira aproximação
risk:     médio — nunca foi testado em lote; overhead do array/separador
          pode exigir folga extra
fallback: se truncar, cair para chamadas individuais (comportamento atual)
          como circuit breaker automático (ver estratégia de retry §6.2.2)
```

**code analysis — formatação (agora em LOTE, §6.2.2)**
```text
current:  900 por item, individual (StudyGenerator.swift:860)
proposed: 850 * count + 100
reason:   leve desconto por item assumindo compartilhamento de overhead de
          schema entre os itens do array — a calibrar
risk:     médio-alto — é o lote com maior volume de texto por item
          (codeSnippet de 5-15 linhas); é o candidato mais provável a
          precisar de ajuste depois de medir
fallback: looksTruncated + retry por item já existe
          (StudyGenerator.swift:865-875) — manter granularidade por item
          mesmo com a chamada sendo em lote
```

**feedback**
```text
current:  600 (StudyGenerator.swift:911)
proposed: manter
reason:   sem evidência de problema
risk:     nenhum
fallback: n/a
```

**MLX drafts (código, quiz difícil, análise)**
```text
current:  350 single-item (MLXService.swift:211); 300*count+50 em lote
proposed: manter ambos
reason:   já calibrados; a mudança de arquitetura (§5/§7) não muda o
          TAMANHO do texto que o MLX precisa gerar, só ONDE/QUANDO ele
          gera
risk:     nenhum
fallback: n/a
```

---

## 14. Geração sob demanda

### 14.1 Comparação

| Estratégia | Descrição | Trade-off |
|---|---|---|
| Pre-generate everything | Gerar o pool completo (24 quiz + 6 análise) na criação, como hoje | Simples, mas gasta GPU/bateria/tokens em conteúdo que pode nunca ser visto (F16) |
| Minimum viable pool | Gerar só o suficiente pra 1ª sessão (3 fácil + 4 média + 3 difícil = 10 quiz; 0 análise), crescer sob demanda depois | Reduz trabalho especulativo; já parcialmente implementado (`replenishAfterSession` existe) |
| Generate-on-first-open | Não gerar NADA de um tipo de conteúdo até o usuário abrir aquela seção pela 1ª vez (ex.: análise de código só começa a gerar quando o botão é tocado) | Zero desperdício, mas introduz espera visível na primeira interação com aquela seção — precisa de loading state dedicado |
| Predictive background generation | Prever o que o usuário vai querer (ex.: sempre gerar análise de código pouco depois do quiz, assumindo que quem estuda um tópico costuma abrir os dois) | Mais complexo, precisa de dado de uso real pra calibrar a predição — não temos esse dado ainda |

### 14.2 Escolha

**Minimum viable pool + generate-on-first-open HÍBRIDO, por tipo de
conteúdo**: quiz (fácil/média/difícil) continua no padrão "minimum viable
pool" que o projeto já tem (o código JÁ faz isso bem — `targetEasy/Medium/Hard
= 6/6/6`, `TopicRepository.swift:61-64`, e o consumo real de uma sessão é
3+4+3=10 — a única mudança real aqui é que ISSO já é razoavelmente
eficiente, não decidido mudar). **Análise de código muda para
generate-on-first-open**: hoje é gerada especulativamente junto com o quiz
(`growCodeAnalysis` disparado sempre, `TopicRepository.swift:252-256`),
mesmo que o botão "Análise de código" possa nunca ser tocado — essa é a
parte identificada como mais claramente especulativa em `PLAN.md` §16.3
(fica atrás de um botão, ao contrário do quiz que é a ação primária de
"Praticar").

Isso é classificado explicitamente como **decisão de produto com
recomendação técnica** (regra do pedido, §2): a decisão de "vale a pena o
usuário esperar alguns segundos na primeira vez que abre Análise de
código, em troca de nunca gastar processamento com conteúdo não visto" é
uma escolha de experiência, não só de engenharia. **Minha recomendação
técnica**: fazer essa troca — o custo (espera na primeira abertura daquela
seção específica) é pontual e já tem um padrão de loading state pronto pra
reaproveitar (`ModelDownloadView`/spinner + `GenerationStage`, §16); o
benefício (não gastar ciclos MLX+FM em conteúdo não visto) é recorrente e
cresce com o número de tópicos que o usuário abre mas não pratica análise
de código.

### 14.3 Parâmetros

- **Quantidade inicial**: quiz continua com o `targetEasy/Medium/Hard`
  atual (6/6/6) gerado em background logo após a criação (não muda);
  análise de código passa a ter **quantidade inicial = 0**, gerada só sob
  demanda.
- **Threshold de refill**: mantém o padrão já existente — `replenishAfterSession`
  já repõe até o alvo cheio quando o pool cai abaixo do alvo
  (`TopicRepository.swift:273-293`); não muda.
- **Quando fazer top-up**: mantém — ao fim de cada sessão de quiz/análise
  (`TopicStudyView.replenishAfterSession`, `TopicStudyView.swift:376-383`).
- **Prioridade no `GenerationOrchestrator`**: análise de código sob demanda
  usa prioridade **`.userBlocking`** na primeira geração (o usuário está
  literalmente esperando o botão liberar), e cai para `.nextSession`/`.poolFill`
  nas reposições seguintes (mesmo padrão de prioridade que já existe para
  outros fluxos, só aplicado a um gatilho novo).
- **Comportamento se o usuário pedir antes do background terminar**: já
  existe o padrão certo no código (botão desabilitado com
  `.opacity(0.4)` enquanto o pool está vazio, `TopicStudyView.swift:303-304`)
  — a mudança é que agora esse estado "vazio, aguardando" é o normal na
  PRIMEIRA visita (hoje é raro, só acontece se o background ainda não
  terminou); reforça a importância de §16 (GenerationStage) pra esse
  estado não parecer quebrado.

---

## 15. Generation Scheduling Strategy

### 15.1 O que já existe (não mexer sem motivo)

`GenerationOrchestrator` (`GenerationOrchestrator.swift:25-158`): actor com
`fmQueue`/`mlxQueue` independentes, cada uma com 1 worker serial, 3
prioridades (`userBlocking` < `nextSession` < `poolFill`, ordenação por
`rawValue`), inserção mantendo ordem de prioridade + FIFO dentro da mesma
prioridade, cancelamento de jobs pendentes por prioridade
(`cancelPending`). O design já resolve exatamente o problema que se propõe
a resolver (contenção FM/MLX), com evidência de que funciona (comentários
no próprio arquivo, ausência de `rateLimited`/`concurrentRequests` como
categoria de erro reportada após sua introdução).

### 15.2 Isso deve mudar?

**Não, por default.** `.userBlocking` continua sendo o que a tela está
esperando agora (com D1/D5, isso passa a significar SÓ as 4 chamadas FM
síncronas do §4 — nunca mais nenhuma chamada MLX usa essa prioridade, já
que MLX saiu do caminho síncrono); `.nextSession` continua sendo trabalho
de background para o tópico que o usuário está olhando agora (upgrade de
exemplo, quiz difícil, análise de código); `.poolFill` continua sendo
enchimento de tópicos que o usuário não está olhando. A arquitetura de
filas já modela exatamente os 3 níveis de urgência que a arquitetura
TARGET precisa — não precisa de um 4º nível nem de mudar o mecanismo.

### 15.3 A arquitetura deve permanecer `1 worker FM + 1 worker MLX`?

**Sim, por default — sem mudar.** Mas o documento é explicitamente
convidado a considerar concorrência FM > 1 para `.poolFill`; a resposta é:
**não implementar sem o experimento abaixo rodar primeiro.**

### 15.4 Experimento (descrito, NÃO implementado)

**Objetivo**: determinar se o Foundation Models aceita ≥2 sessões
`LanguageModelSession` concorrentes sem erro, e se aceitar, se o
throughput agregado melhora o suficiente para justificar a complexidade.

**Desenho do experimento**:
1. Numa build de debug isolada (não no `GenerationOrchestrator` de
   produção), disparar N `LanguageModelSession(...).respond(to:...)`
   simultâneas (`Task` paralelas, sem passar pela fila) para N = 2, 3, 4.
2. Registrar, por N: taxa de erro `concurrentRequests`/`rateLimited`
   (`LanguageModelSession.GenerationError`, já tratado em
   `StudyGeneratorError.describe`, `StudyGenerator.swift:39-65` — não
   precisa de código novo pra RECONHECER o erro, só pra provocá-lo de
   propósito), tempo total até todas completarem vs. o mesmo N de chamadas
   rodando em série (o baseline atual).
3. Repetir em pelo menos 10 rodadas por N (chamadas de sistema como essa
   costumam ter comportamento não-determinístico sob carga).

**Critério de decisão**:
- Se taxa de erro para N=2 for materialmente >0% em uso realista (ex. >5%
  das tentativas), **não implementar** — ficar com serial.
- Se taxa de erro for ~0% E o tempo total melhorar de forma proporcional
  (não apenas marginal) em relação à execução serial, considerar elevar
  **só a fila `.poolFill`** para profundidade 2 (nunca `.userBlocking`, que
  já não usa mais MLX de qualquer forma nem tem motivo pra arriscar
  contenção no FM).
- Se melhorar mas com taxa de erro não-trivial, considerar profundidade 2
  com retry automático em caso de `concurrentRequests` (voltando pra fila
  serial como fallback) — mas isso adiciona complexidade real; só vale se
  o ganho for grande.

**Por que não fazer isso já**: não há dado de que a fila FM serial seja
hoje um gargalo relevante DEPOIS de D1+D3 reduzirem o volume de chamadas
pela metade (§6) — otimizar concorrência antes de saber se ainda é preciso
seria adivinhar o que dava pra medir (violação direta do princípio final
do pedido).

---

## 16. Perceived Performance

### 16.1 `GenerationStage`

```swift
// Novo, provavelmente em StudyGenerator.swift ou um arquivo próprio
// Observável (@Observable, mesmo padrão já usado em MLXService.loadState,
// MLXService.swift:76-84) — TopicStudyView lê isso diretamente, sem
// polling.
enum GenerationStage: Equatable {
    case idle
    case indexing                    // ensureReady() em andamento (raro,
                                      // só em cache MISS de embeddings —
                                      // ver §18, isso NÃO bloqueia mais a
                                      // tela, mas ainda pode aparecer se o
                                      // usuário abrir a tela de RAG debug)
    case generatingSummary
    case generatingQuizEasy
    case generatingQuizMedium
    case generatingCodeExample       // FM-only, síncrono (D1)
    case ready                       // FASE 1 persistida, tela mostrável
    case upgradingCodeExample        // background (D1/§5, passos 4-8)
    case generatingHardQuiz          // background
    case generatingCodeAnalysis      // background (só se disparado —
                                      // generate-on-first-open, §14)
    case backgroundComplete
    case failed(step: String)
}
```

Os estados batem 1:1 com os pontos onde `TopicRepository.timed`
(`TopicRepository.swift:262-266`) já delimita etapas — **não é um design
novo do zero**, é dar nome observável a fronteiras que o código já tem
instrumentadas em texto (`print`).

### 16.2 Renderização progressiva

**Mudança de modelo de persistência**: de "1 escrita atômica no final"
para "2 fases":

```swift
// TopicRepository.swift — assinatura aproximada, NÃO implementação completa

/// FASE 1: persiste o mínimo mostrável (resumo, quiz fácil/média, exemplo
/// FM-only) e retorna — TopicStudyView já pode sair de isLoading aqui.
private func generateAndPersistPhase1(topic: String) async throws -> StudyTopic

/// FASE 2 (background, chamada internamente após a Fase 1 retornar,
/// nunca aguardada pelo caminho síncrono): roda o restante (§5, §6, §14) e
/// aplica PATCHES incrementais no StudyTopic já persistido.
private func runBackgroundUpgrade(topicID: PersistentIdentifier, ...) async

/// Novo — aplica o resultado do upgrade de exemplo de código (§5, passo 8)
/// num StudyTopic já persistido, sem recriar o objeto.
func applyCodeExampleUpgrade(topicID: PersistentIdentifier, example: ExplainedCodeExample) async
```

A UI já observa `StudyTopic` via SwiftData (`@Query`,
`StudyHomeView.swift:19`) — o mesmo mecanismo reativo cobre um `StudyTopic`
específico sendo editado por um `ModelContext` de background, desde que a
View leia as propriedades diretamente (não capture uma cópia estática) —
`TopicStudyView` já guarda `@State private var topic: StudyTopic?`
(`TopicStudyView.swift:36`), que é uma REFERÊNCIA a um objeto `@Model`; um
save num `ModelContext` diferente que edita o MESMO objeto persistente
dispara re-render, seguindo o mesmo padrão que `TopicRepositoryTestView`
já demonstra funcionar para pool growth
(`TopicRepositoryTestView.swift:21-23`, comentário explícito: "reflete
automaticamente saves feitos pelo ModelContext de background").

### 16.3 Loading granular / skeleton

Onde faz sentido: a `loadingState` de `TopicStudyView`
(`TopicStudyView.swift:77-98`) troca o texto fixo "Gerando conteúdo de
'\(topicName)'..." por um texto derivado de `GenerationStage` (ex.:
"Gerando resumo...", "Preparando quiz..."). **Skeleton (placeholder de
layout) não é necessário aqui** — como a Fase 1 é rápida o suficiente pra
ser tratada como "loading" único e não progressivo por dentro de si mesma
(4 chamadas FM sequenciais, sem pontos naturais de renderização parcial
ÚTIL antes da Fase 1 completar — mostrar só o resumo sem saber se o quiz
carregou é um estado intermediário que não ajuda muito mais que um
spinner com texto), o ganho real de percepção vem de: (a) a Fase 1 ser bem
mais curta que o fluxo completo de hoje (D1 tirando MLX do caminho), e (b)
o texto do spinner mudar (`GenerationStage`) em vez de ficar estático.
Introduzir skeleton screens seria complexidade sem ganho perceptível
adicional nesse ponto específico.

### 16.4 Disponibilidade parcial

Depois da Fase 1: resumo/pontos-chave/exemplo básico e quiz
fácil/média disponíveis; quiz difícil e análise de código com estado
"ainda gerando" — já existe o padrão visual (`TopicStudyView.swift:294-304`,
botão desabilitado com opacidade reduzida) — só falta o texto de
`GenerationStage` acompanhar (§16.1).

### 16.5 Tratamento de erro parcial

Hoje, se `generateAndPersist` falhar em QUALQUER etapa, a tela inteira cai
em `errorState` (`TopicStudyView.swift:100-114`) — com a Fase 1/2, um erro
na Fase 2 (background) **não deve** derrubar a tela, que já está
mostrando conteúdo válido da Fase 1. Proposta: erros de Fase 2 só
atualizam `GenerationStage` para `.failed(step:)` sem limpar `topic` —
a `articleContent` continua renderizada normalmente, só o
indicador de "crescendo em background" (`TopicStudyView.swift:157-164`,
já existe) muda para um estado de aviso silencioso, sem bloquear nada. Erro
na Fase 1 (as 4 chamadas FM síncronas) continua caindo no `errorState`
atual — não muda, porque aí realmente não há conteúdo mostrável.

### 16.6 Atualização do exemplo em background (UX)

Já coberto em detalhe no gatilho de reversão de D1 (§5.2) — resumo: o
patch acontece de forma reativa via SwiftData; se testes de usuário
mostrarem que isso é estranho, a mitigação (aplicar só na próxima abertura)
já está desenhada e pronta pra aplicar sem redesenhar nada.

### 16.7 Mudanças necessárias por arquivo (visão resumida — detalhe completo em §22)

- `TopicStudyView.swift`: ler `GenerationStage` em vez de texto fixo;
  tratar erro de Fase 2 sem derrubar a tela.
- `TopicRepository.swift`: dividir `generateAndPersist` em Fase 1/Fase 2;
  novo método `applyCodeExampleUpgrade`.
- `StudyGenerator.swift`: `generateCodeExample` deixa de ser "MLX com
  fallback FM" e vira duas funções — a versão FM-only (síncrona, chamada
  na Fase 1) e a versão de upgrade MLX→crítica→formatação (chamada só na
  Fase 2).
- `StudyTopic` (`Persistence.swift`): nenhuma mudança de schema
  necessária — os campos já existem (`codeExample`,
  `walkthroughSnippets/Explanations`); a Fase 2 só faz `UPDATE` neles.

---

## 17. RAG — decisão

### 17.1 Avaliação das opções do pedido

- **A — manter arquitetura híbrida completa** (sem mudar nada): mantém
  complexidade sem uso real em produção (F11/F25), mas sem custo de
  performance hoje (dataset pequeno).
- **B — mantê-la, mas remover do caminho crítico**: já é quase verdade
  para GERAÇÃO (`chunks(forExactTopic:)` já não usa embedding), mas
  **não** é verdade para ABERTURA DE TELA (`ensureReady()` ainda bloqueia
  — F12).
- **C — simplificar para lookup exato enquanto o dataset for curado**:
  deletaria/desativaria `hybridSearch`, stopwords, threshold adaptativo —
  perderia a capacidade de recomendação de próximo tópico
  (`StudyResultView.resolveRecommendedTopic`) e a única ferramenta de
  debug de qualidade de retrieval (`RAGTestView`) que existe.
- **D — outra**: não identifiquei uma quarta opção genuinamente melhor que
  uma combinação de B (arquitetura) + a decoupling específica do §18.

### 17.2 Escolha: **B**, com a implementação específica do §18

**Por quê**: a arquitetura híbrida (`DocumentIndex.hybridSearch`,
`DocumentIndex.swift:150-195`) já é código funcionando, testado (a própria
`RAGTestView` existe pra isso), calibrado com evidência real documentada
nos comentários (pesos ajustados depois de medir baseline de cosseno,
`DocumentIndex.swift:129-149`) — deletar isso (Opção C) seria trocar
trabalho já pago por trabalho futuro de recriar, na hora em que o dataset
crescer de novo (já foi 21 tópicos, `PlaceholderDocs.swift:8-17`, pode
voltar a ser). Manter tudo (Opção A) sem tirar do caminho de ABERTURA de
tela deixaria o achado F12 sem solução. B é o meio-termo correto: preserva
o investimento, resolve o único ponto onde RAG ainda tem efeito
mensurável hoje (abertura de tela via `ensureReady`, não geração).

**Considerando crescimento futuro do dataset**: se o dataset voltar a
crescer (21+ tópicos), a arquitetura híbrida preservada por B volta a ter
uso real potencial (`hybridSearch` pode voltar a ser exercitado se a busca
livre for reintroduzida, decisão de produto separada) sem precisar
reescrever nada — essa é exatamente a razão de não escolher C.

---

## 18. Embeddings / `ensureReady` — desacoplamento

### 18.1 Lifecycle atual (problema)

```text
Raw chunks available:     depois de DocumentIndex.buildIndex() completar
                           (mesmo que só precise dos embeddings pro
                           caminho FUZZY, que a geração normal não usa)
Embedding index ready:    mesmo momento — os dois são hoje UM evento só
```

### 18.2 Lifecycle proposto

```text
Raw chunks available:     IMEDIATO — PlaceholderDocs.rawChunks já é uma
                           constante estática (PlaceholderDocs.swift:60),
                           sem I/O nem processamento assíncrono
Embedding index ready:    quando DocumentIndex.ensureReady() completar,
                           como hoje — mas NINGUÉM no caminho de abertura
                           de tela espera por isso mais
```

### 18.3 Implementação (assinaturas aproximadas)

```swift
// DocumentIndex.swift

/// NOVO: acesso síncrono aos chunks crus (topic+text, SEM embedding),
/// direto do dataset estático — não depende de ensureReady().
static func rawChunks(forExactTopic topic: String) -> [(topic: String, text: String)] {
    PlaceholderDocs.rawChunks
        .filter { $0.topic == topic }
        .map { (topic: $0.topic, text: $0.text) }
}
```

```swift
// StudyGenerator.swift — retrieveContext deixa de depender do
// DocumentIndex estar "ready" quando o caminho é o exato:

func retrieveContext(for topic: String, topK: Int = 3) async -> String {
    // Caminho exato: NÃO precisa de ensureReady() — dado estático.
    let exact = DocumentIndex.rawChunks(forExactTopic: topic)
    if !exact.isEmpty {
        return exact.prefix(topK).map(\.text).joined(separator: "\n\n")
    }
    // Caminho fuzzy: SÓ AQUI aguarda o índice de embeddings.
    print("⚠️ retrieveContext: nenhum chunk com topic exatamente '\(topic)' — caindo no hybridSearch (fuzzy).")
    try? await documentIndex.ensureReady()
    return (try? await documentIndex.retrieveContext(for: topic, topK: topK)) ?? ""
}
```

```swift
// TopicStudyView.swift — load() não aguarda mais ensureReady() antes de
// construir o repositório:

private func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
        if repository == nil {
            // ensureReady() NÃO é mais aguardado aqui — dispara em paralelo
            // (fire-and-forget, prioridade .utility) só para os casos raros
            // que precisarem do caminho fuzzy mais tarde nesta sessão.
            Task.detached(priority: .utility) { try? await DocumentIndex.shared.ensureReady() }
            let gen = StudyGenerator(documentIndex: documentIndex)
            generator = gen
            repository = TopicRepository(modelContext: modelContext, generator: gen)
        }
        guard let repository else { return }
        topic = try await repository.fetchOrCreate(topic: topicName)
    } catch {
        errorMessage = "Erro ao carregar \"\(topicName)\": \(error.localizedDescription)"
    }
}
```

### 18.4 Efeito colateral a controlar

Se `ensureReady()` ainda estiver rodando (cache MISS raro) no momento em
que `StudyResultView.resolveRecommendedTopic` (caminho fuzzy) precisar
dele, o `try? await documentIndex.ensureReady()` dentro do próprio método
(já existe esse padrão de dedup via `buildTask` compartilhada,
`DocumentIndex.swift:53-67`) garante que ele espera a MESMA Task em vez de
duplicar trabalho — não precisa de nenhuma mudança adicional, o mecanismo
de dedup já cobre esse caso.

---

## 19. Chat Template

### 19.1 API real (confirmada, §0)

```swift
// Libraries/MLXLMCommon/UserInput.swift (fetch direto do commit pinado)
public init(chat: [Chat.Message], processing: Processing = .init(),
            tools: [ToolSpec]? = nil, additionalContext: [String: Any]? = nil)

// Libraries/MLXLMCommon/Chat.swift
public static func system(_ content: String, ...) -> Self
public static func user(_ content: String, ...) -> Self
public static func assistant(_ content: String, ...) -> Self
```

`UserInput(chat:)` é processado por `context.processor.prepare(input:)`
(mesmo ponto de entrada já usado hoje, `MLXService.swift:326`) que, via
`MessageGenerator` (protocolo real, `Chat.swift:60-92`), converte os
`Chat.Message` estruturados no formato de template REAL do modelo
carregado — o mecanismo que hoje é bypassado pela string manual.

### 19.2 Achado confirmado nesta sessão — duplo template

Lendo `UserInput.init(prompt: String, ...)` (`UserInput.swift`, linha
~186-198): **um `prompt: String` isolado é internamente convertido em
`.chat([.user(prompt, images:, videos:)])`** — ou seja, mesmo o
"caminho simples" de string já passa pelo mecanismo de chat/template. O
código atual (`MLXService.swift:321,326`) constrói `fullPrompt` como uma
string ChatML MANUAL completa (`<|im_start|>system\n...<|im_end|>\n<|im_start|>user\n...`)
e passa isso inteiro como o CONTEÚDO de uma única mensagem `.user`. O
processor do modelo então aplica o template REAL por cima disso — o
resultado provável (`HIGHLY LIKELY`, não confirmado em runtime nesta
sessão) é um prompt com marcadores ChatML **aninhados/duplicados**: os
verdadeiros, inseridos pelo template real, envolvendo os literais que o
código escreveu à mão como se fossem texto comum. Isso desperdiça tokens
(marcadores duplicados) e pode confundir o modelo (parece uma conversa
falsa dentro de uma mensagem de usuário).

### 19.3 Migração proposta

```swift
// MLXService.generate — assinatura aproximada da mudança

private func generate(systemPrompt: String, promptContext: String, maxTokens: Int) async throws -> String {
    guard let container = modelContainer else { throw ... }

    let generateParams = GenerateParameters(maxTokens: maxTokens, temperature: 0.3, repetitionPenalty: 1.1)
    let start = Date()

    let stream = try await container.perform { context in
        let userInput = UserInput(chat: [
            .system(systemPrompt),
            .user(promptContext),
        ])
        let input = try await context.processor.prepare(input: userInput)
        return try MLXLMCommon.generate(input: input, cache: /* §7 */ nil, parameters: generateParams, context: context)
    }
    // resto igual (coleta do stream, instrumentação §10)
}
```

Remove inteiramente a string manual `<|im_start|>...` — o template correto
do modelo (Qwen2.5-Coder-Instruct, já suportado pelo `MLXLLM` usado no
projeto) passa a ser aplicado pela biblioteca, uma única vez.

### 19.4 Teste de equivalência (obrigatório antes de remover a string manual)

1. Rodar os 18 prompts do §9 com AMBOS os caminhos (string manual atual vs.
   `UserInput(chat:)` novo) no MESMO modelo.
2. Comparar: (a) contagem de tokens de entrada (`GenerateCompletionInfo.promptTokenCount`,
   API real, §10) — a hipótese é que o caminho novo tem MENOS tokens de
   entrada por eliminar a duplicação; (b) qualidade da saída pela rubrica
   do §9.3 — não deveria piorar, e a hipótese é que pode até melhorar
   (menos ruído de marcadores duplicados confundindo o modelo).
3. **SUCCESS CRITERIA**: tokens de entrada iguais ou menores, qualidade
   igual ou melhor pela rubrica, para os 18 prompts.

### 19.5 Fallback

Se o teste de equivalência mostrar qualquer regressão de qualidade
(hipótese pouco provável, já que estamos removendo ruído, não adicionando),
reverter para a string manual — é uma mudança isolada de uma função
(`MLXService.generate`), fácil de reverter sem afetar nenhuma outra parte
do sistema.

---

## 20. Qualidade do código gerado — defesa em camadas

### 20.1 Camadas propostas

```text
RAG grounding (já existe, chunks(forExactTopic:))
  → generation (FM-only síncrono, D1 — já tem instrução conservadora,
    StudyGenerator.swift:190-193)
  → deterministic checks (NOVO — ver 20.2)
  → optional model critique (MLX, já existe — agora condicional em
    PRIORIDADE, não em execução, D1/§5)
  → schema validation (QuestionValidator, já existe)
  → persistence (SwiftData, já existe)
```

### 20.2 O que PODE ser verificado deterministicamente (sem modelo)

Baseado no `commonCodeMistakesChecklist` já existente
(`StudyGenerator.swift:618-628`), que hoje é só um texto de PROMPT — cada
item avaliado quanto a viabilidade de virar um check de string/regex:

| Erro conhecido (do checklist atual) | Verificável deterministicamente? | Como |
|---|---|---|
| `Button`/`Toggle`/`NavigationLink` sem `action:`/closure | **Sim, parcialmente** | Regex: `Button\("([^"]*)"\)\s*$` ou seguido de `\n\s*[A-Z}]` sem `{` logo após — heurística sintática razoável, não 100% (pode ter falso positivo com multi-linha complexo) |
| `.navigationDestination(for: 1)` (valor em vez de tipo) | **Sim** | Regex: `navigationDestination\(for:\s*\d` (literal numérico) ou `for:\s*"` (literal string) como argumento — tipo válido nunca começa com dígito/aspas |
| `@StateObject` em tipo de valor (`Int`/`Bool`/`String`/`NavigationPath`) | **Sim, parcialmente** | Regex: `@StateObject.*var \w+:\s*(Int|Bool|String|NavigationPath|Double)\b` — cobre os casos citados explicitamente no checklist; não cobre tipos de valor customizados não listados |
| Parâmetro de inicializador inexistente | **Não** | Exige saber a assinatura real do tipo — precisa de conhecimento semântico (modelo ou, no limite, o compilador real — ver 20.4) |
| Walkthrough descrevendo mudança que não está no código | **Não** | Exige comparação semântica texto↔código — tarefa de modelo |
| `looksTruncated` (chaves/parênteses desbalanceados, final suspeito) | **Sim — já existe** | `StudyGenerator.looksTruncated`, `StudyGenerator.swift:479-509` — reusar, não duplicar |

### 20.3 Onde entram no pipeline (D1/§5, passo 3)

```swift
// Novo, StudyGenerator.swift ou um arquivo DeterministicCodeChecks.swift

enum DeterministicCodeChecks {
    struct Result { let passed: Bool; let flags: [String] }

    static func evaluate(_ code: String) -> Result {
        var flags: [String] = []
        if StudyGenerator.looksTruncated(code) { flags.append("truncamento") }
        if Self.hasActionlessControl(code) { flags.append("controle sem action") }
        if Self.hasNavigationDestinationValueLiteral(code) { flags.append("navigationDestination com valor") }
        if Self.hasStateObjectOnValueType(code) { flags.append("StateObject em tipo de valor") }
        return Result(passed: flags.isEmpty, flags: flags)
    }
    // implementações privadas dos regex acima — NÃO escritas aqui, é design
}
```

Usado no passo 3 do fluxo de §5.2: se `evaluate(example.code).passed ==
false`, a prioridade do upgrade MLX/crítica sobe de `.poolFill` para
`.nextSession`. **Importante**: mesmo se `passed == true`, a crítica MLX
ainda roda (só com prioridade menor) — os checks determinísticos NUNCA
substituem a crítica por modelo, só REORDENAM o trabalho, porque a tabela
acima mostra que pelo menos 2 das causas de bug documentadas (parâmetro de
inicializador inexistente, walkthrough dessincronizado) não são
verificáveis sem modelo.

### 20.4 Investigação: `swiftc` real (mencionada no `PLANO_V5.md §3`)

O `PLAN.md`/histórico do projeto já cogitou rodar o compilador Swift real
via `Process` sobre o snippet gerado. Meu parecer: **não fazer agora**.
Motivos: (a) o próprio `PLANO_V5.md` já identificou a dificuldade real
("precisa lidar com imports/contexto de um snippet solto, não é trivial")
— os exemplos gerados são fragmentos (uma `View`/função, não um arquivo
Swift completo e importável), então "compilar de verdade" exigiria
sintetizar um harness (imports, tipos de contexto assumidos) que é, em si,
uma fonte nova de falso-negativo/falso-positivo; (b) o ganho marginal sobre
os checks determinísticos + crítica por modelo já propostos não está
evidenciado — os erros reais documentados no histórico (`Button` sem
action, `navigationDestination` com valor, `@StateObject` mal aplicado)
já são cobertos pela camada de checks do §20.2 OU pela crítica por modelo;
um erro de compilação real que NENHuma das duas camadas pegasse ainda não
foi documentado como tendo acontecido. Revisitar só se, depois de D1-D5
implementados, o histórico de bugs mostrar uma nova classe de erro que as
camadas atuais não cobrem.

---

## 21. Test Strategy

### Unit tests

Funções puras, sem modelo, sem I/O — determinísticas por natureza, testáveis
com `XCTest` convencional:

- `QuestionValidator.sanitizeText/sanitize/isValid` (`QuestionValidator.swift:29-128`)
  — casos: cada resíduo de formatação listado (`residues`,
  `enumerationPatterns`), cada regra de validação (opções duplicadas,
  índice fora do range, enunciado curto/cortado, fallback genérico).
- `StudyGenerator.looksTruncated` (`StudyGenerator.swift:479-509`) — casos:
  balanceamento de chaves/parênteses/colchetes, strings com escape,
  finais suspeitos.
- `DocumentIndex` léxico: `tokens(of:)`, `lexicalOverlap` (privados hoje —
  considerar `internal` para testabilidade, mudança de visibilidade, baixo
  risco) — casos: stopwords filtradas corretamente, overlap calculado
  certo para casos conhecidos.
- `DeterministicCodeChecks` (novo, §20.2) — casos: cada regex com
  exemplos reais dos bugs já documentados no histórico do projeto
  (`Button("Salvar")` sem action, `.navigationDestination(for: 1)`,
  `@StateObject` em `Bool`) como fixtures de teste de regressão.
- `MLXService.generateQuestionDrafts` — parsing do split por
  `itemSeparator` (`MLXService.swift:230-233`) — casos: N itens completos,
  itens vazios/curtos descartados, separador ausente (fallback pra 1 item).
- Chave de cache do §7 (`TopicPromptCache.key`) — determinismo (mesma
  entrada → mesma chave) e sensibilidade a mudança (contexto diferente →
  chave diferente).

### Integration tests

Precisam de `ModelContainer`/`ModelContext` do SwiftData (em memória,
como já usado nas Previews, ex. `ContentView.swift:158-162`,
`inMemory: true`) mas NÃO precisam do modelo real (FM/MLX) — usar dublês
(fakes) que implementam a mesma interface que `StudyGenerator` expõe:

- **Cache HIT/MISS de `TopicRepository.fetchOrCreate`**: dado um
  `StudyTopic` pré-inserido com `sourceDatasetVersion` batendo/não batendo
  com `DatasetVersion.current`, verificar que a geração é ou não disparada
  (usando um `StudyGenerator` fake que registra chamadas).
- **Dedup de geração concorrente** (`inFlightGenerations`,
  `TopicRepository.swift:56,150-167`) — já existe uma validação MANUAL
  disso (`TopicRepositoryTestView.runRaceTest`,
  `TopicRepositoryTestView.swift:265-293`) — portar essa mesma lógica para
  um `XCTestCase` automatizado, disparando `fetchOrCreate` 2x em paralelo
  com um `StudyGenerator` fake e contando quantas vezes o fake foi
  chamado (deveria ser 1, não 2).
- **Geração parcial (Fase 1/Fase 2, §16)**: verificar que depois da Fase 1,
  o `StudyTopic` já tem `summary`/`quizPool` preenchidos mas
  `codeAnalysisPool` vazio (com `generate-on-first-open`, §14); e que o
  patch de Fase 2 atualiza o objeto EXISTENTE (mesmo `persistentModelID`),
  não cria um segundo `StudyTopic`.
- **Pool/top-up**: dado um pool com N itens abaixo do alvo,
  `replenishAfterSession` (com generator fake) preenche até o alvo e para
  exatamente nele (não ultrapassa).
- **Invalidação por `DatasetVersion`**: dado um `StudyTopic` com versão
  antiga, `fetchOrCreate` descarta e regenera — reaproveita o cenário já
  exercitado manualmente pela seção 4 de `TopicRepositoryTestView`
  (`TopicRepositoryTestView.swift:226-237`).

### Model evaluation tests

**Não são unit tests determinísticos** — são o `MLX Model Benchmark Suite`
do §9, rodado como um script/target separado (não faz parte do `xcodebuild
test` normal, porque depende de geração probabilística real e de
download/carga de modelo, que não pertence a um CI rápido). Formato:
rodar os 18 prompts contra o modelo escolhido, aplicar a rubrica do §9.3,
falhar (alertar, não quebrar build) se o veto duro de hallucination (§9.4)
disparar — isso serve como teste de REGRESSÃO DE MODELO (rodar de novo
antes de qualquer troca de modelo ou de versão do `mlx-swift-examples`),
não como gate de todo commit.

**Por que não transformar geração probabilística em unit test
determinístico sem estratégia apropriada** (regra explícita do pedido):
saída de LLM varia entre execuções mesmo com o mesmo prompt (sampling,
`GenerateParameters.temperature`, `MLXService.swift:322`) — um "unit test"
que espera uma string exata de um modelo quebraria por motivos errados
(flakiness, não regressão real). A separação proposta acima (unit tests só
para código determinístico; avaliação de modelo como suite separada com
rubrica e limiares, não asserções de igualdade) é a estratégia apropriada.

---

## 22. File-by-File Changes

### `Services/MLXService.swift`

**Responsabilidade atual**: carga/download do modelo MLX, geração de texto
livre (single e batched), progresso de download, pré-aquecimento.
**Problema**: chat template manual (F5/§19); nenhum reuso de KV cache
(F4/§7); nenhuma instrumentação de tokens reais (F9/§10); nenhum
warm-up de inferência (F24/§12).
**Mudança**: migrar `generate` para `UserInput(chat:)` (§19); adicionar
suporte a `TopicPromptCache`/cache externo (§7); trocar coleta de
`outputText` só por chars para também capturar `GenerateCompletionInfo`
via `case .info` do stream (§10); adicionar warm-up opcional pós-load
(§12).
**Novas estruturas**: `TopicPromptCache`, `MLXPromptCacheStore` (§7).
**Funções alteradas**: `generate(systemPrompt:promptContext:maxTokens:)`
(assinatura pode ganhar um parâmetro opcional `cache: [KVCache]? = nil`);
`performLoad` (dispara warm-up opcional ao final).
**Funções removidas**: nenhuma.
**Funções novas**: `warmUp()` (§12); acesso ao cache de prefixo (via
`MLXPromptCacheStore`, que pode viver aqui ou em arquivo próprio).
**Risco**: Medium (mudança em código crítico de geração; mitigado pelo
teste de equivalência do §19.4 e pelo benchmark do §7.4).
**Teste necessário**: teste de equivalência de template (§19.4);
benchmark de cache (§7.4); unit test do parsing de lote (já existente,
formalizar em §21).

### `Services/StudyGenerator.swift`

**Responsabilidade atual**: toda comunicação com FM e MLX — resumo,
exemplo de código (MLX→FM), quiz (FM ou MLX→FM), análise de código
(MLX→FM), feedback.
**Problema**: `generateCodeExample` força MLX no caminho síncrono (F1/§5);
`formatHardQuestion` sem orçamento explícito nem retry de truncamento
(F8/§13); formatação pós-lote MLX não batched (F3/§6).
**Mudança**: dividir `generateCodeExample` em
`generateCodeExampleFM(topic:context:)` (síncrono, chamado na Fase 1) e
`upgradeCodeExampleViaMLX(topic:context:draftContext:)` (background,
chamado na Fase 2, contém o que hoje é `generateCodeExample` menos o
fallback — o fallback vira desnecessário porque o FM-only já É o caminho
principal); adicionar orçamento+retry em `formatHardQuestion`; converter
`formatHardQuestion`/`formatCodeAnalysisQuestion` pra aceitar lotes
(`formatHardQuestionsBatch(drafts:...) -> [QuizQuestion]`,
`formatCodeAnalysisBatch(drafts:...) -> [CodeAnalysisQuestion]`,
reaproveitando `QuizQuestionBatch`/`CodeAnalysisBatch` já existentes em
`StudyModels.swift`).
**Novas estruturas**: nenhuma (reusa schemas existentes); ver §6.2.2 para
a decisão sobre schema de crítica em lote (texto livre com separador,
sem struct nova, na primeira tentativa).
**Funções alteradas**: `generateCodeExample` (split, acima);
`formatHardQuestion` → `formatHardQuestionsBatch`;
`formatCodeAnalysisQuestion` → `formatCodeAnalysisBatch`;
`critiqueCodeDraft` ganha uma variante em lote
(`critiqueCodeDraftsBatch`).
**Funções removidas**: `generateCodeExampleFromScratch` como "fallback"
deixa de existir como conceito separado — vira a função principal
(renomeada, não removida de fato).
**Funções novas**: `formatHardQuestionsBatch`, `formatCodeAnalysisBatch`,
`critiqueCodeDraftsBatch`, `upgradeCodeExampleViaMLX`.
**Risco**: High (é o arquivo mais central do sistema, 917 linhas, muitas
dependências) — mitigar com PRs pequenos e isolados (§24), nunca uma
reescrita única.
**Teste necessário**: integration tests do §21 com generator fake para
validar que a Fase 1 gera exatamente o subconjunto esperado; unit tests
de `DeterministicCodeChecks`; benchmark de batching (§6, taxa de
rejeição do `QuestionValidator` antes/depois).

### `Services/TopicRepository.swift`

**Responsabilidade atual**: cache/persistência via SwiftData, dedup de
geração concorrente, crescimento de pool em background, top-up
pós-sessão.
**Problema**: `generateAndPersist` é uma escrita atômica única (F14/§16);
`startBackgroundGrowthIfNeeded` sempre enche o pool completo, incluindo
análise de código especulativamente (F16/§14).
**Mudança**: dividir `generateAndPersist` em Fase 1/Fase 2 (§16.2); mudar
`codeAnalysisPool` para `generate-on-first-open` (§14) — remover
`growCodeAnalysis` do disparo automático em `generateAndPersist`, mover
pra um novo gatilho (`ensureCodeAnalysisPool(topicName:)`, chamado quando
o usuário toca o botão de Análise de código pela 1ª vez).
**Novas estruturas**: nenhuma nova entidade SwiftData (schema não muda,
§16.7).
**Funções alteradas**: `generateAndPersist` (split);
`startBackgroundGrowthIfNeeded`/`growPoolInBackground` (não dispara mais
`growCodeAnalysis` automaticamente).
**Funções removidas**: nenhuma.
**Funções novas**: `generateAndPersistPhase1`, `runBackgroundUpgrade`,
`applyCodeExampleUpgrade`, `ensureCodeAnalysisPool(topicName:)` (novo
gatilho sob demanda, §14).
**Risco**: High (mesma razão do `StudyGenerator` — é o orquestrador
central). Mitigar com o mesmo cuidado de PRs pequenos.
**Teste necessário**: integration tests do §21 (Fase1/Fase2, dedup,
top-up, invalidação).

### `Services/GenerationOrchestrator.swift`

**Responsabilidade atual**: fila serial por motor (FM, MLX), 3
prioridades.
**Problema**: nenhum problema confirmado — só uma hipótese não testada
(F22/§15).
**Mudança**: **NENHUMA** por default (D5). Só se o experimento do §15.4
justificar, e mesmo assim, mudança isolada e pequena (não é PR desta
rodada de implementação — fica registrado como possível trabalho futuro
condicional).
**Risco**: N/A (sem mudança planejada).

### `Services/QuestionValidator.swift`

**Responsabilidade atual**: sanitização + validação determinística.
**Problema**: nenhum (F7 — não alterar).
**Mudança**: nenhuma na lógica; talvez expor `internal` em vez de
`private` os helpers de validação usados por unit tests novos (§21) — não
é uma mudança de comportamento.
**Risco**: Low.

### `Services/DocumentIndex.swift`

**Responsabilidade atual**: índice RAG, embeddings, busca híbrida, cache
em disco.
**Problema**: `ensureReady()` acoplado ao caminho de abertura de tela
(F12/§18).
**Mudança**: adicionar `static func rawChunks(forExactTopic:)` (§18.3) —
acesso síncrono aos dados crus, sem depender de `ensureReady()`. Resto do
arquivo não muda (D6).
**Funções novas**: `rawChunks(forExactTopic:)`.
**Risco**: Low (aditivo, não remove nem altera comportamento existente).
**Teste necessário**: unit test simples confirmando que
`rawChunks(forExactTopic:)` devolve os mesmos textos que
`DocumentIndex.shared.chunks(forExactTopic:)` devolveria depois de
`ensureReady()` completar (garante que os dois caminhos ficam
consistentes).

### `Views/TopicStudyView.swift`

**Responsabilidade atual**: tela "artigo" do tópico, orquestra
quiz/análise/resultado.
**Problema**: `load()` aguarda `ensureReady()` desnecessariamente
(F12/§18); loading binário sem granularidade (F13/§16); erro de qualquer
etapa derruba a tela inteira (§16.5).
**Mudança**: `load()` não aguarda mais `ensureReady()` (§18.3); consome
`GenerationStage` em vez de texto fixo (§16.1); trata erro de Fase 2 sem
limpar `topic` (§16.5); novo gatilho pro botão de Análise de código
disparar `ensureCodeAnalysisPool` na 1ª vez (§14).
**Risco**: Medium (é a tela principal do produto).
**Teste necessário**: nenhum automatizado direto (é SwiftUI) — validação
manual guiada, reaproveitando o roteiro de demo já existente em
`GUIA_APRESENTACAO.md`.

### `Services/MLXService.swift` — instrumentação (retomando §10)

Já coberto acima.

### Novo: `Services/GenerationMetrics.swift`

**Responsabilidade**: struct + store de métricas de profiling (§10).
**Risco**: Low (código aditivo, não interfere no fluxo existente).

### Novo: `Services/DeterministicCodeChecks.swift`

**Responsabilidade**: checks estáticos de qualidade de código gerado
(§20.2).
**Risco**: Low (aditivo; usado só para PRIORIZAÇÃO, não bloqueia nada se
tiver falso-negativo).

### `Views/RootTabView.swift`, `ContentView.swift`, `RAGTestView.swift`, `TopicRepositoryTestView.swift`

**Mudança** (F18, prioridade baixa, não faz parte do caminho crítico de
performance): mover as 3 telas de debug para um scheme/target de
desenvolvimento, ou remover conforme os próprios comentários do código já
autorizam (`RAGTestView.swift:9-10`). Tratado como PR isolado de baixa
prioridade (§24, PR 9).

---

## 23. Dependency Graph

```text
Instrumentação (§10, GenerationMetrics)
   ↓
   ├──────────────────────────────────────────────┐
   ↓                                               ↓
Chat template real (§19)                  Desacoplar ensureReady (§18)
[safe win, testa sozinho via §19.4]       [safe win, independente]
   ↓
Model benchmark suite (§9)
[precisa de tokens/TTFT reais — depende de §10]
   ↓
Seleção de modelo (§8)
[KEEP CURRENT por default; 14B só se §9 confirmar sob a topologia TARGET]
   ↓
MLX fora do caminho síncrono (§5, D1)
[maior mudança arquitetural — precisa da Fase 1/2 de persistência, §16]
   ↓
   ├──────────────────────────────────────┐
   ↓                                       ↓
Prompt/KV cache (§7)                Batching de formatação FM (§6)
[só faz sentido DEPOIS que MLX      [independente de §7, mas mais
 virou background — cachear um      valioso depois que §5 mudar a
 caminho que ainda bloqueia a       forma como os lotes MLX disparam
 tela seria otimizar o problema     a formatação em background]
 errado primeiro]
   ↓                                       ↓
   └──────────────────┬────────────────────┘
                       ↓
        Geração sob demanda / pool (§14)
        [depende de §5 porque muda ONDE o gatilho de
         "análise de código" entra no fluxo]
                       ↓
        Perceived performance completa (§16)
        [GenerationStage já pode começar cedo, mas a
         renderização progressiva de verdade depende de
         §5/§16.2 (Fase 1/Fase 2) estar pronta]
                       ↓
        Defesa em camadas / checks determinísticos (§20)
        [o gate de prioridade só faz sentido depois que
         existe uma versão FM-only síncrona (§5) pra avaliar]
                       ↓
        Testes automatizados (§21)
        [cobre tudo acima — mais valioso quanto mais das
         mudanças anteriores já existirem para testar, mas os
         unit tests de funções PURAS (QuestionValidator,
         looksTruncated) podem e devem ser escritos a
         qualquer momento, inclusive antes de tudo]

Independentes de tudo acima (podem rodar em paralelo, a qualquer momento):
   - GPU memory strategy (§11) — só precisa de §10 pra medir
   - Warm-up de inferência (§12) — só precisa de §10 pra medir
   - Correção de formatHardQuestion (F8/§13) — isolado, sem dependência
   - Remoção das telas de debug (F18) — isolado, sem dependência
```

---

## 24. Implementation Sequence

Cada PR abaixo deixa o projeto **compilável e funcional**. Nenhum mistura
refatoração arquitetural + troca de modelo + otimização + UI no mesmo PR.

### PR 1 — Instrumentação (`GenerationMetrics`)
**Arquivos**: novo `Services/GenerationMetrics.swift`; instrumentação
aditiva em `MLXService.swift` (capturar `GenerateCompletionInfo` do
stream), `TopicRepository.swift` (`Self.timed` passa a alimentar a store
além de `print`).
**Resultado**: tokens/TTFT/tokens-por-segundo reais disponíveis para
todas as decisões benchmark-gated seguintes.
**Teste**: rodar um tópico novo manualmente, conferir que o JSON exportado
(§10.4) tem valores plausíveis (não-zero, não-NaN).
**Rollback**: reverter o arquivo novo + as poucas linhas aditivas — zero
risco pro comportamento existente (é só coleta de dados).

### PR 2 — Correção de `formatHardQuestion` (F8)
**Arquivos**: `StudyGenerator.swift:687-693`.
**Resultado**: orçamento de token explícito + retry-curto, paridade com
`formatCodeAnalysisQuestion`.
**Teste**: gerar quiz difícil pros 3 tópicos do dataset, inspecionar
truncamento (manual, ou via `DeterministicCodeChecks`/`looksTruncated` se
PR 8 já estiver mesclado — senão, manual mesmo).
**Rollback**: reverter a função isolada.

### PR 3 — Chat template real (F5/§19)
**Arquivos**: `MLXService.swift` (`generate`).
**Resultado**: `UserInput(chat:)` substitui a string ChatML manual.
**Teste**: teste de equivalência do §19.4 (rodar os 18 prompts do §9 nos
dois caminhos, comparar tokens de entrada e qualidade).
**Rollback**: reverter a função isolada (1 função, mudança pequena e
contida).

### PR 4 — Desacoplar `ensureReady` (F12/§18)
**Arquivos**: `DocumentIndex.swift` (`rawChunks(forExactTopic:)` novo),
`StudyGenerator.swift` (`retrieveContext`), `TopicStudyView.swift`,
`ContentView.swift`, `TopicRepositoryTestView.swift` (mesmos ~3 pontos que
hoje chamam `ensureReady()` antes de construir o repositório).
**Resultado**: abertura de tela não espera mais pelo índice de embeddings
quando o caminho exato resolve.
**Teste**: unit test de paridade (§22, `DocumentIndex`); manual —
confirmar que `RAGTestView`/recomendação de próximo tópico (caminho
fuzzy) continuam funcionando (aguardam `ensureReady()` internamente,
como já documentado em §18.4).
**Rollback**: reverter as poucas chamadas alteradas.

### PR 5 — Model Benchmark Suite (§9) como ferramenta de desenvolvimento
**Arquivos**: novo script/target de avaliação (fora do app principal —
pode ser um target de linha de comando ou uma extensão da
`TopicRepositoryTestView` existente); usa os 18 prompts + rubrica do §9.
**Resultado**: capacidade de rodar o benchmark contra o modelo atual (7B)
e, depois, contra o 14B — dados reais para D2/§8.
**Teste**: o benchmark É o teste — rodar contra o 7B primeiro para
estabelecer baseline.
**Rollback**: é uma ferramenta aditiva, sem risco pro app.

### PR 6 — Fase 1/Fase 2 de persistência (D1, maior mudança) — **dividido em sub-PRs**

#### PR 6a — `generateCodeExampleFM` como caminho principal (sem tocar no upgrade ainda)
**Arquivos**: `StudyGenerator.swift` (renomear/promover
`generateCodeExampleFromScratch`), `TopicRepository.swift`
(`generateAndPersist` chama a versão FM direto, MLX temporariamente
DESABILITADO pro exemplo de código — um passo intermediário deliberado).
**Resultado**: já remove a carga de MLX do caminho síncrono, mesmo antes
do upgrade em background existir — ganho de latência mensurável
isoladamente.
**Teste**: medir (via PR 1) o tempo de abertura de tópico novo
antes/depois — deveria cair de forma visível.
**Rollback**: reverter para chamar a versão MLX→crítica→formatação
síncrona de novo (comportamento atual).

#### PR 6b — Persistência em 2 fases + `GenerationStage`
**Arquivos**: `TopicRepository.swift` (split Fase 1/Fase 2 real, mesmo sem
upgrade de MLX ainda rodando — Fase 2 fica vazia/no-op por enquanto, só a
estrutura), `TopicStudyView.swift` (consome `GenerationStage`).
**Resultado**: estrutura de persistência incremental pronta, percepção de
progresso já melhora (§16.1).
**Teste**: manual — abrir tópico novo, confirmar que o texto de loading
muda por etapa.
**Rollback**: reverter para persistência atômica única.

#### PR 6c — Upgrade de exemplo de código em background (reintroduz MLX)
**Arquivos**: `StudyGenerator.swift` (`upgradeCodeExampleViaMLX`),
`TopicRepository.swift` (`runBackgroundUpgrade`, `applyCodeExampleUpgrade`).
**Resultado**: pipeline MLX→crítica→formatação volta a rodar, agora em
background, com patch reativo.
**Teste**: integration test do §21 (Fase 2 atualiza o objeto existente);
manual — confirmar que o exemplo "melhora" na tela sem duplicar o
`StudyTopic`.
**Rollback**: reverter só este sub-PR mantém 6a+6b (ganho de latência sem
o upgrade — degrada qualidade de volta ao nível "FM-only sempre", pior que
hoje em qualidade mas melhor em latência; é um rollback parcial aceitável
como estado intermediário).

#### PR 6d — Checks determinísticos + prioridade adaptativa (§20, D1 completo)
**Arquivos**: novo `Services/DeterministicCodeChecks.swift`,
`TopicRepository.swift`/`StudyGenerator.swift` (aplicar o gate de
prioridade).
**Resultado**: Estratégia D completa.
**Teste**: unit tests do §21 com os fixtures dos bugs documentados.
**Rollback**: reverter o gate (upgrade sempre roda com prioridade fixa
`.poolFill`) — degrada só a priorização, não a correção.

### PR 7 — Batching de formatação FM (§6)
**Arquivos**: `StudyGenerator.swift` (`formatHardQuestionsBatch`,
`formatCodeAnalysisBatch`, `critiqueCodeDraftsBatch`),
`TopicRepository.swift` (`growDifficulty`/`growCodeAnalysis` chamam as
versões em lote).
**Resultado**: redução de chamadas FM de background descrita em §6.1.
**Teste**: comparar taxa de rejeição do `QuestionValidator`
antes/depois (via PR 1, instrumentação já captura `retryCount`).
**Rollback**: reverter para chamadas individuais (código anterior, não
deletado, só trocado de chamador) — se a taxa de rejeição piorar de forma
significativa.

### PR 8 — Prompt/KV Cache MLX (§7)
**Arquivos**: `MLXService.swift` (`TopicPromptCache`,
`MLXPromptCacheStore`), unificação dos `systemPrompt`s (§7.2.1).
**Resultado**: reuso de prefill entre as 3 chamadas MLX de um tópico.
**Teste**: benchmark do §7.4 (TTFT com/sem cache).
**Rollback**: `cache: nil` (comportamento atual) — 1 linha.

### PR 9 — Geração sob demanda para análise de código (§14, D8)
**Arquivos**: `TopicRepository.swift` (remove `growCodeAnalysis`
automático, adiciona `ensureCodeAnalysisPool`), `TopicStudyView.swift`
(botão de análise de código dispara o novo gatilho).
**Resultado**: elimina geração especulativa da análise de código.
**Teste**: manual — confirmar que abrir um tópico novo NÃO dispara
análise de código até o botão ser tocado; confirmar que tocar o botão
gera com prioridade `.userBlocking` e mostra loading adequado.
**Rollback**: reverter para o disparo automático em `generateAndPersist`.

### PR 10 — Seleção final de modelo (D2/§8, benchmark-gated)
**Arquivos**: `MLXService.swift:44,49` (`modelID`,
`estimatedModelBytes`) — SE o PR 5 (benchmark) + medição sob a topologia
TARGET completa (pós PR 6-9) justificar trocar pra 14B.
**Resultado**: modelo final decidido por dado, não por este documento.
**Teste**: benchmark completo do §9 rodado contra a topologia TARGET.
**Rollback**: reverter a constante — 1 linha, o resto do código já é
agnóstico ao `modelID` (por design, `MLXService.swift:40-44`).

### PR 11 — Testes automatizados (§21)
**Arquivos**: novo target `SwiftStudyCoachTests`, arquivos de teste por
componente (`QuestionValidatorTests.swift`,
`DeterministicCodeChecksTests.swift`, `DocumentIndexTests.swift`,
`TopicRepositoryTests.swift`).
**Resultado**: cobertura de regressão para os bugs já documentados no
histórico.
**Teste**: os próprios testes.
**Rollback**: N/A (aditivo, não afeta o app).

### PR 12 — Limpeza de telas de debug (F18, baixa prioridade)
**Arquivos**: `RootTabView.swift`, `ContentView.swift`,
`RAGTestView.swift`, `TopicRepositoryTestView.swift`.
**Resultado**: navegação de produção limpa.
**Teste**: manual — confirmar que `StudyHomeView`→`TopicStudyView`
continua funcionando sem depender de nada exclusivo dessas telas.
**Rollback**: reverter (as telas voltam pra `RootTabView`).

### PR 13 — GPU memory tuning (§11, benchmark-gated, só se necessário)
**Arquivos**: `MLXService.swift` (`GPU.set(cacheLimit:)` no ponto de
carga do modelo).
**Resultado**: valor de cache calibrado por medição, não chute.
**Teste**: benchmark do §11.3.
**Rollback**: remover a chamada (volta ao default do sistema).

---

## 25. Safe Wins / Benchmark-Gated / Product Decisions

## Safe Wins

Mudanças que podem avançar **independente de benchmark** (baixo risco,
benefício claro por raciocínio de código, não por medição):

- Correção de `formatHardQuestion` (F8, PR 2)
- Migração de chat template (F5, PR 3) — com o teste de equivalência do
  §19.4 como validação de correção, não de performance
- Desacoplar `ensureReady` (F12, PR 4)
- `GenerationMetrics`/instrumentação (PR 1) — é a própria ferramenta de
  medição, não depende de medição prévia
- Mover MLX pro caminho de background (PR 6a) — o raciocínio ("não fazer
  o usuário esperar por um modelo de 7B quando existe um caminho FM-only
  que já funciona") não depende de benchmark pra ser válido; o benchmark
  (PR 1) só quantifica o ganho, não decide SE fazer
- Persistência em 2 fases / `GenerationStage` (PR 6b)
- Limpeza de telas de debug (F18, PR 12)
- Testes automatizados de funções puras (PR 11, parte unit tests)

## Benchmark-Gated Changes

Mudanças que só devem avançar (ou só devem ser DECIDIDAS de uma forma
específica) se os dados justificarem:

- **Batching de formatação FM** (PR 7) — o tamanho de lote (≤4) e a
  fórmula de orçamento são pontos de partida; a decisão de manter/ajustar
  depende da taxa de rejeição medida (§6.2)
- **Prompt/KV cache MLX** (PR 8) — só vale manter se o benchmark do §7.4
  mostrar ganho real de TTFT; a hipótese concorrente (gargalo é decode,
  não prefill) é plausível e só o benchmark decide
- **Seleção final de modelo — 14B vs. 7B** (PR 10) — explicitamente
  gated pelo benchmark do §9 rodado sob a topologia TARGET completa
- **GPU cache/memory limit** (PR 13) — regra explícita da própria
  documentação da API (§11.2): não há valor universal, precisa medir
- **Warm-up de inferência** (§12) — só implementar se a diferença
  1ª-vs-2ª-chamada for mensurável e o custo energético se justificar
- **Concorrência FM > 1** (§15.4) — explicitamente não implementar sem o
  experimento rodar primeiro

## Product Decisions

Mudanças que dependem de escolha de experiência, não só de engenharia
(recomendação técnica dada em cada uma, mas a palavra final é de produto):

- **Geração sob demanda da análise de código** (D8/§14) — troca "nunca
  gastar processamento à toa" por "esperar um pouco na 1ª abertura daquela
  seção específica"; recomendação técnica: fazer a troca (PR 9)
- **Patch reativo do exemplo de código em background** (D1/§5.2) —
  "conteúdo muda sozinho na tela" precisa de validação de UX real, não só
  de engenharia; recomendação técnica: fazer, com o gatilho de reversão
  já desenhado (aplicar só na próxima abertura) se testes de usuário
  mostrarem desconforto
- **Promover 14B a modelo padrão** — mesmo com benchmark favorável, é uma
  decisão de produto no sentido de "vale o download de 8,3GB adicional
  pro usuário final" — recomendação técnica: sim, SE o benchmark
  confirmar qualidade superior sem pressão de memória, porque o download
  já é obrigatório de qualquer forma (o app não funciona sem MLX) e a
  diferença de 4,3GB→8,3GB é secundária comparada ao fato de precisar
  baixar ALGUM modelo grande de qualquer jeito

---

## 26. Definition of Done

```text
Opening latency (tempo até tela mostrável em tópico novo):
  Baseline: medir (PR 1, antes de qualquer mudança de arquitetura)
  Target: redução visível pela eliminação de carga+geração MLX do caminho
          síncrono (PR 6a) — magnitude exata depende do baseline

TTFT (MLX, por chamada de background):
  Baseline: medir (PR 1)
  Target: melhora mensurável nas chamadas 2ª/3ª de um tópico após PR 8
          (cache de prefixo) — se não melhorar, PR 8 é revertido (§7.4)

Tokens/s (MLX):
  Baseline: medir (PR 1) — métrica REAL pela primeira vez (hoje é chars/s)
  Target: sem meta absoluta; usado para comparar modelos candidatos (§9)

Contagem de chamadas FM por tópico novo:
  Baseline: ~23-24 (CONFIRMED por contagem de código, PLAN.md §2.2)
  Target: ~12-13 (CONFIRMED por contagem de código no desenho de §6) —
          essa meta é aritmética sobre o design, não depende de benchmark
          para ser válida como meta; o benchmark mede o TEMPO
          correspondente, não se a contagem bateu

Contagem de chamadas MLX por tópico novo:
  Baseline: ~3 (1 exemplo + drafts de quiz difícil + drafts de análise)
  Target: ~3 (não muda — a redução é de CHAMADAS FM, não MLX; MLX já era
          eficiente em número de chamadas, o problema era ONDE elas
          rodavam, não QUANTAS)

Memória (footprint com modelo MLX carregado):
  Baseline: medir via GPU.snapshot() (§11) — nunca medido antes
  Target: sem regressão ao trocar de 7B para 14B, SE essa troca acontecer
          (PR 10) — critério objetivo: GPU.snapshot() não mostra
          crescimento sustentado de cacheMemory+activeMemory acima do
          memoryLimit reportado por GPU.deviceInfo()

Tempo de geração do pool completo (background):
  Baseline: medir (PR 1)
  Target: redução proporcional à redução de chamadas FM (~45-48%, §6.1),
          ajustada pelo fato de análise de código não rodar mais
          automaticamente (PR 9) — comparação justa precisa considerar
          "pool completo SOB DEMANDA" vs. "pool completo automático" como
          medidas diferentes

Taxa de questão inválida (rejeitada pelo QuestionValidator):
  Baseline: medir (via retryCount em GenerationMetrics, PR 1) — nunca
          quantificado antes, só logado em texto
  Target: não piorar com o batching (PR 7) — se piorar de forma
          significativa, reduzir batch size antes de abandonar (§D3)

Correção de código gerado (ausência de API inventada):
  Baseline: medir via MLX Model Benchmark Suite (§9), prompts 4-7
  Target: veto duro do §9.4 — zero tolerância a hallucination confirmada
          nesses prompts, para QUALQUER modelo considerado

Responsividade de UI (percepção, não tempo):
  Baseline: qualitativo — hoje é "Gerando conteúdo..." fixo por toda a
          duração
  Target: GenerationStage visível mudando por etapa (PR 6b); conteúdo
          útil (resumo) visível antes do fim da geração completa (PR 6a+6b)
```

---

## 27. Plano de rollback

| Mudança | Como detectar regressão | Como voltar | O que preservar | Métricas a comparar |
|---|---|---|---|---|
| Troca de modelo (PR 10) | Benchmark §9 mostra hallucination (veto duro) OU `GPU.snapshot()` mostra pressão de memória sustentada | Reverter `MLXService.modelID`/`estimatedModelBytes` — 1 linha, resto do código é agnóstico ao modelo | Cache de embeddings, pool já gerado com o modelo anterior (não precisa invalidar `DatasetVersion` — o conteúdo persistido não referencia o modelo que gerou) | Score da rubrica §9.3, `GPU.snapshot()` antes/depois |
| Batching (PR 7) | Taxa de rejeição do `QuestionValidator` sobe de forma notável (via `retryCount` em `GenerationMetrics`) | Reverter chamador para as versões individuais (mantidas no código, não deletadas até o batching se provar estável — ver nota abaixo) | Schemas `QuizQuestionBatch`/`CodeAnalysisBatch` (já existiam antes, não são novos) | `retryCount` médio por tópico, antes/depois |
| KV cache (PR 8) | TTFT não melhora OU saída diverge de forma não-trivial no teste de equivalência | `cache: nil` — 1 linha | Nada a preservar (cache é transiente, por sessão) | TTFT da 2ª/3ª chamada MLX por tópico |
| Concorrência FM (§15.4, se algum dia implementada) | Taxa de `concurrentRequests`/`rateLimited` > 0 em produção | Reduzir profundidade da fila `.poolFill` de volta a 1 | Nada (é config de fila, sem estado persistido) | Taxa de erro por categoria (`StudyGeneratorError`) |
| Geração progressiva / patch reativo (PR 6b/6c) | Usuário reporta confusão com conteúdo "trocando" na tela (validação de UX, não métrica automática) | Aplicar upgrade só na PRÓXIMA abertura em vez de patch ao vivo (mudança pequena e já desenhada, §5.2 gatilho de reversão) | Estrutura de persistência em 2 fases (o ganho de latência do PR 6a se mantém mesmo revertendo só o patch ao vivo) | Nenhuma automática — feedback qualitativo |
| Pipeline MLX/FM completo (D1, PR 6 inteiro) | Se, depois de tudo, a qualidade cair de forma inaceitável (o veto duro do §9.4 nunca deveria permitir isso, mas como rede de segurança final) | Reverter PR 6a-6d na ordem inversa — cada sub-PR já tem seu próprio rollback descrito em §24 | `DatasetVersion` NÃO precisa bumpar num rollback de código (o formato persistido de `StudyTopic` não muda, §16.7) | Rubrica de qualidade §9.3 aplicada a uma amostra de tópicos gerados em produção |

**Nota sobre PR 7 (batching)**: recomendo, na implementação real (fora do
escopo deste documento), manter as funções individuais
(`formatHardQuestion`/`formatCodeAnalysisQuestion` originais) no código
como fallback interno por pelo menos 1 ciclo de validação — se um lote
inteiro falhar de forma sistemática, cair para chamadas individuais é uma
degradação graciosa mais barata que reverter o PR inteiro.

---

## 28. Prioridade final

## Final Priority Matrix

| Ordem | Mudança | Performance | Qualidade | Complexidade | Risco | Depende de benchmark? |
|---:|---|---|---|---|---|---|
| 1 | Instrumentação (`GenerationMetrics`) | — (habilita tudo) | — | Small | Baixo | Não |
| 2 | Correção `formatHardQuestion` (F8) | Baixo | Medium | Trivial | Baixo | Não |
| 3 | Chat template real (F5) | Baixo-Médio | Médio (menos ruído no prompt) | Small | Baixo | Não (teste de equivalência, não benchmark de decisão) |
| 4 | Desacoplar `ensureReady` (F12) | Baixo hoje / Médio se dataset crescer | — | Small | Baixo | Não |
| 5 | MLX fora do caminho síncrono (PR 6a) | **Very High** | — (neutro, upgrade ainda cobre qualidade depois) | Medium | Médio | Não para decidir fazer; Sim para quantificar o ganho |
| 6 | Persistência em 2 fases + `GenerationStage` (PR 6b) | — (percepção, não tempo real) | — | Medium | Médio | Não |
| 7 | Upgrade de exemplo em background (PR 6c) | Neutro (não bloqueia, mas ainda consome recursos) | **High** (preserva a defesa contra hallucination) | Medium | Médio | Não |
| 8 | Checks determinísticos + prioridade adaptativa (PR 6d) | Médio (background mais eficiente) | Medium | Medium | Baixo | Não |
| 9 | Batching de formatação FM (PR 7) | **High** | Neutro-a-testar | Medium | Médio | Sim (taxa de rejeição) |
| 10 | Geração sob demanda — análise de código (PR 9) | Medium (menos trabalho especulativo) | — | Small-Medium | Médio (produto) | Não (decisão de produto com recomendação técnica dada) |
| 11 | Prompt/KV cache MLX (PR 8) | Médio-Alto (hipótese) | — | Medium | Médio | Sim (§7.4) |
| 12 | Model Benchmark Suite (PR 5) | — (ferramenta) | — (ferramenta) | Medium | Baixo | É o próprio benchmark |
| 13 | Seleção final de modelo — 14B (PR 10) | Baixo (já é background) | **High** (se confirmado) | Trivial (troca de constante) | Médio | Sim (§9 sob topologia TARGET) |
| 14 | GPU memory tuning (PR 13) | Desconhecido | — | Trivial | Baixo | Sim (§11.3) |
| 15 | Testes automatizados (PR 11) | — | — (confiabilidade) | Medium | Baixo | Não |
| 16 | Limpeza de telas de debug (PR 12) | — | — (manutenção) | Small | Baixo | Não |

## Recommended Final Roadmap

### Stage 1 — Instrumentação e correções sem risco
PRs 1, 2, 3, 4 (§24). Nenhuma depende de benchmark para SER FEITA (§25,
Safe Wins) — o benchmark de PR 1 só passa a existir DEPOIS dessas, pra
quantificar o resto.

### Stage 2 — Remoção de trabalho desnecessário
PR 6a (MLX fora do caminho síncrono — maior ganho de latência do
documento inteiro) + PR 9 (análise de código sob demanda). Ambas removem
trabalho, não o aceleram — consistente com o princípio final do pedido
("não otimizar o que podemos remover").

### Stage 3 — Redução de chamadas / batching
PR 7 (batching de formatação FM).

### Stage 4 — Otimização MLX
PR 8 (prompt/KV cache), PR 13 (GPU memory tuning, se justificado).

### Stage 5 — Modelo MLX
PR 5 (benchmark suite) rodado contra 7B (baseline) e 14B (candidato) sob a
topologia já otimizada pelos Stages 2-4; PR 10 (troca, só se os dados
confirmarem).

### Stage 6 — UX / renderização progressiva
PR 6b (persistência em 2 fases + `GenerationStage` — na prática, esta
pode e deve ser feita em paralelo com o Stage 2, já que PR 6a depende
estruturalmente de PR 6b existir para a Fase 1 ter onde persistir; a
ordem lógica aqui é de PRIORIDADE de valor, não de sequência estrita de
implementação — ver §23 para a ordem de dependência real) + PR 6c
(upgrade em background) + PR 6d (checks determinísticos).

### Stage 7 — Refatoração e testes
PR 11 (testes automatizados) + PR 12 (limpeza de telas de debug).

**Nota final sobre a ordem**: a ordem acima prioriza VALOR (o que mais
importa resolver primeiro), mas a ordem de IMPLEMENTAÇÃO real precisa
respeitar o grafo de dependência do §23 — na prática, isso significa que
PR 6b (Stage 6) precisa ser implementado ANTES ou JUNTO de PR 6a (Stage
2), porque a Fase 1 de PR 6a precisa de um lugar pra persistir
incrementalmente. Recomendo tratar PR 6a+6b como uma unidade de entrega
única na prática (mesmo sendo 2 PRs de review, para manter os diffs
pequenos e revisáveis), apesar de aparecerem em estágios de prioridade
diferentes nesta matriz.


