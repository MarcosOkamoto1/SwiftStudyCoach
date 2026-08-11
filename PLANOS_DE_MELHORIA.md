# Planos de Melhoria — SwiftStudyCoach

Baseado na análise de: `DocumentIndex.swift`, `MLXService.swift`, `StudyGenerator.swift`, `TopicRepository.swift`, `StudyModels.swift`, `TopicStudyView.swift` e `PlaceholderDocs.swift`.

---

## 1. RAG — indexação, procura e busca

**Problemas atuais**
- `TopicStudyView` cria um `DocumentIndex` novo por tela (`@State private var documentIndex = DocumentIndex()`) e chama `buildIndex()` a cada visita — re-embeda todo o dataset toda vez.
- Embeddings gerados sequencialmente (loop `for` com `await` um a um).
- Sem cache em disco (o TODO no fim do arquivo já aponta isso).
- Busca é "tudo ou nada": match exato de tópico OU semântica pura — sem combinação de sinais, sem diversidade nos top-k.

**Plano**
1. **Índice singleton/compartilhado**: injetar um único `DocumentIndex` via `@Environment` (criado no `SwiftStudyCoachApp`), construído uma vez no launch. Remove o rebuild por tela.
2. **Cache de embeddings em disco**: serializar `[DocChunk]` (com embeddings) em Application Support, chaveado por hash do dataset (`DatasetVersion.current` já existe — reutilizar). No launch: hash igual → carrega JSON/binário (ms); diferente → reindexa e regrava.
3. **Indexação paralela**: `withThrowingTaskGroup` para embedar chunks concorrentemente (ganho de ~3-5x na primeira indexação).
4. **Busca híbrida com fusão de score**: em vez de "match direto OU semântica", combinar: score léxico (BM25 simples ou contagem de termos normalizados) + similaridade de cosseno, com Reciprocal Rank Fusion ou soma ponderada (ex.: 0.4 léxico + 0.6 semântico). Match exato de tópico vira apenas um boost, não um curto-circuito.
5. **MMR (Maximal Marginal Relevance)** no top-k: evita retornar 3 chunks quase idênticos do mesmo tópico; maximiza relevância + diversidade — melhora o grounding de flashcards/quiz que hoje recebem contexto redundante.
6. **Metadados nos chunks**: adicionar `source`/`section` ao `DocChunk` para o modelo poder citar a origem e para debug no `RAGTestView`.
7. **Threshold adaptativo**: se nenhum resultado passar de `minimumSimilarity` 0.50, refazer com 0.35 antes de retornar vazio (hoje contexto vazio silencioso → modelo alucina).

---

## 2. MLX — geração mais rápida

**Problemas atuais**
- Qwen2.5-Coder-**7B**-4bit (~4,3 GB) é pesado para gerar rascunhos de texto puro de 350 tokens.
- Cada pergunta difícil = 1 prefill completo do prompt (system + RAG) no loop de `generateQuizBatch` — o prefixo é idêntico e reprocessado a cada iteração.
- Template de chat montado à mão com strings `<|im_start|>`.

**Plano**
1. **Modelo menor para rascunhos**: trocar para `Qwen2.5-Coder-3B-Instruct-4bit` (~1,8 GB) ou `1.5B` (~1 GB). O rascunho é reformatado pelo Foundation Models depois, então perda de qualidade é tolerável; ganho de 2-4x em tokens/s e download muito menor. Deixar o ID do modelo configurável para A/B.
2. **Batch em uma chamada**: gerar N perguntas num único prompt ("Gere 4 perguntas, separadas por `---`") e fazer split — troca N prefills por 1. Maior ganho individual do plano.
3. **Reuso de KV cache do prefixo**: se mantiver o loop, usar o suporte de prompt cache do MLXLMCommon para o prefixo comum (system + contexto RAG), pagando prefill só do sufixo variável.
4. **Usar `ChatSession`/template do tokenizer** em vez de string manual — evita tokens malformados que degradam a geração e simplifica o código.
5. **Pré-aquecimento**: chamar `MLXService.shared.loadModel()` em background no launch do app (fire-and-forget), não na primeira pergunta difícil.
6. **Tuning**: `MLX.GPU.set(cacheLimit:)` adequado ao device; `repetitionPenalty` leve; reduzir `maxTokens` de 350 → 250 (o formato pedido cabe).

---

## 3. Foundation Models — código comentado como exemplo explicado

**Problema atual**: as `instructions` pedem comentários, mas o schema não obriga — o modelo frequentemente ignora, e comentário inline não é o mesmo que "exemplo explicado".

**Plano**
1. **Forçar via schema, não via prompt** — trocar `codeExample: String` por uma estrutura que o `@Generable` obriga a preencher:

   ```swift
   @Generable
   struct ExplainedCodeExample {
       @Guide(description: "Código Swift completo do exemplo, 5-15 linhas, sem comentários")
       var code: String

       @Guide(description: "Explicação passo a passo: um item por linha/bloco relevante do código, em português, como se ensinasse alguém vendo pela primeira vez")
       var walkthrough: [CodeStep]
   }

   @Generable
   struct CodeStep {
       @Guide(description: "O trecho exato de código sendo explicado (1-3 linhas)")
       var snippet: String
       @Guide(description: "Explicação didática do que esse trecho faz e por quê")
       var explanation: String
   }
   ```

2. **Renderização**: evoluir `CodeBlockView` para exibir o código inteiro no topo e, abaixo, os passos intercalados (snippet destacado + explicação) — visual de "code walkthrough" tipo tutorial.
3. **Migração**: novos campos em `StudyTopic` (persistir `walkthrough` como JSON encodado ou entidade filha) + `DatasetVersion.current++` para invalidar cache antigo.
4. **Fallback**: se preferir mudança mínima primeiro, reforçar o `@Guide` de `codeExample` com "OBRIGATÓRIO: toda linha precedida de comentário `//` em português" — mas o schema estruturado é a solução confiável.

---

## 4. Foundation Models — exemplo cortado (truncamento)

**Causa**: `codeExample` é o último campo do schema; quando o orçamento de tokens acaba, ele é o primeiro a ser cortado. `maximumResponseTokens: 900` ajuda mas não garante.

**Plano**
1. **Separar em duas chamadas**: `generateSummary` gera só `summary + keyPoints` (orçamento próprio); uma segunda chamada gera apenas o exemplo de código (`ExplainedCodeExample` do item 3) com orçamento dedicado (ex.: 700 tokens). Nenhum campo compete com o código. Uma chamada a mais na 1ª visita é barato — tudo fica cacheado no SwiftData.
2. **Detecção de truncamento**: validar o código gerado (chaves `{}`/parênteses balanceados, não termina em vírgula/operador). Se inválido → retry único com prompt "gere um exemplo MAIS CURTO (máx. 8 linhas)".
3. **Tratar `exceededContextWindowSize`**: capturar `LanguageModelSession.GenerationError.exceededContextWindowSize` e refazer com contexto RAG reduzido (topK 3 → 1). Ver item 5.
4. **Reduzir pressão de entrada**: com match direto de tópico, hoje entram até 3 chunks (~750 palavras) no prompt. Com o item 1 (chamada dedicada ao código), passar topK=2 para o resumo e topK=1 para o exemplo.

---

## 5. Bug da imagem — `StudyGeneratorError error 1` ao carregar NavigationStack

**Diagnóstico**: `error 1` = `StudyGeneratorError.generationFailed` — o Foundation Models lançou um erro durante `generateAndPersist` (resumo, flashcards ou quiz fácil/média) e o erro real foi engolido: `generationFailed(Error)` não é `LocalizedError`, então a UI mostra só "The operation couldn't be completed". Causas prováveis, em ordem: `exceededContextWindowSize` (NavigationStack tem 3 chunks longos que entram inteiros via match direto), `guardrailViolation`, `decodingFailure` (resposta truncada não bate no schema), rate limit do sistema.

**Plano**
1. **Tornar o erro diagnosticável** (fazer primeiro — revela a causa real):

   ```swift
   enum StudyGeneratorError: LocalizedError {
       case modelUnavailable(String)
       case generationFailed(step: String, underlying: Error)

       var errorDescription: String? {
           switch self {
           case .modelUnavailable(let r): return r
           case .generationFailed(let step, let e):
               return "Falha na etapa '\(step)': \(describe(e))"
           }
       }
   }
   ```

   com `describe(_:)` fazendo switch sobre `LanguageModelSession.GenerationError` (`.exceededContextWindowSize`, `.guardrailViolation`, `.decodingFailure`, `.assetsUnavailable`, `.rateLimited`...) e mensagens em português. Passar `step:` em cada `catch` do `StudyGenerator` ("resumo", "flashcards", "quiz fácil"...).
2. **Retry com degradação**: em `exceededContextWindowSize` → refazer com topK=1; em `decodingFailure` → 1 retry; em `rateLimited` → aguardar 2s e tentar 1x.
3. **Sessão sempre nova por retry**: garantido hoje (sessão criada por chamada) — manter assim; sessão reutilizada acumula transcript e estoura contexto.
4. **Progresso granular na UI**: o "Tentar de novo" refaz tudo do zero às custas do usuário esperar de novo. Persistir por etapa (resumo salvo → não regenerar no retry) ou ao menos mostrar em qual etapa falhou.
5. **Teste de regressão**: abrir NavigationStack (o tópico com mais chunks) após limpar cache é o cenário que reproduz o bug — validar com ele.

---

## 6. Tela de download do modelo MLX (progresso, tempo estimado)

**Problema atual**: `loadState = .downloading` é binário — sem %, sem velocidade, sem ETA; download de ~4,3 GB parece travado.

**Plano**
1. **Capturar progresso real**: `LLMModelFactory.loadContainer` aceta um `progressHandler: (Progress) -> Void`. Estender o estado:

   ```swift
   enum LoadState: Equatable {
       case idle
       case downloading(fraction: Double, completedBytes: Int64, totalBytes: Int64)
       case loadingIntoMemory   // pós-download, carregando pesos
       case ready
       case failed(String)
   }
   ```

2. **Velocidade e ETA**: no `MLXService`, janela deslizante das últimas ~10 amostras `(bytes, timestamp)` → velocidade média (MB/s) → `ETA = bytesRestantes / velocidade`. Suavizar com média móvel para não oscilar.
3. **`ModelDownloadView` dedicada** (substitui o bloco improvisado no `loadingState` da `TopicStudyView`):
   - Nome do modelo e tamanho total
   - Barra de progresso + "1,2 GB de 4,3 GB (28%)"
   - Velocidade atual e tempo restante estimado ("~6 min restantes")
   - Aviso "download só na primeira vez; use Wi-Fi" e botão Cancelar/Tentar de novo
   - Distinguir fase de download da fase de carga em memória (`loadingIntoMemory`)
4. **Pré-checagens**: espaço em disco livre antes de iniciar; detectar ausência de rede e falhar com mensagem clara em vez de erro genérico.
5. **Download antecipado opcional**: entrada em Ajustes/onboarding "Baixar modelo agora" para o usuário não pagar o download no meio do estudo (combina com o pré-aquecimento do item 2.5).

---

## Ordem sugerida de execução

| # | Item | Esforço | Impacto |
|---|------|---------|---------|
| 1 | 5.1 — erro diagnosticável | Baixo | Alto (destrava o bug real) |
| 2 | 5.2 + 4.3 — retries com degradação | Baixo | Alto |
| 3 | 4.1 — chamada separada p/ código | Baixo | Alto (mata o corte) |
| 4 | 1.1 + 1.2 — índice único + cache em disco | Médio | Alto |
| 5 | 6 — tela de download com progresso | Médio | Alto (UX) |
| 6 | 3 — walkthrough estruturado | Médio | Alto (didática) |
| 7 | 2.1 + 2.2 — modelo menor + batch | Médio | Alto (velocidade) |
| 8 | 1.4-1.7, 2.3-2.6 — refinos de RAG/MLX | Médio | Médio |
