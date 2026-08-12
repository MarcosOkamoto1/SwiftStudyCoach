# PLAN_11 — MLX Prompt/KV Cache (protótipo + benchmark)

## Objetivo

Implementar um cache de prefixo MLX (`TopicPromptCache`/
`MLXPromptCacheStore`) que reusa o prefill do system prompt + contexto
RAG entre as 3 chamadas MLX de um mesmo tópico (exemplo de código, quiz
difícil, análise de código), evitando reprocessar o mesmo prefixo do zero
3 vezes. Rodar o benchmark de TTFT com/sem cache como parte deste mesmo
plano (implementação e validação andam juntas aqui, por ser reversível
com 1 linha).

## Por que esta etapa existe

`SOLUTIONS_PLAN.md` F4/D4/§7: hoje `MLXService.generate` chama
`MLXLMCommon.generate(input:parameters:context:)` **sem** o parâmetro
`cache:` (`MLXService.swift:327`, confirmado por leitura direta do código
— cada chamada cria um `KVCacheSimple` novo via
`model.newCache(parameters:)` internamente, `TokenIterator.init`,
`Evaluate.swift`) — zero reuso de cache entre chamadas, confirmado com
evidência de código real. Só faz sentido DEPOIS que MLX é background-only
(`PLAN_06`/`PLAN_07`) — cachear um caminho que ainda bloqueia a tela seria
otimizar o problema errado primeiro.

## Estado esperado antes de começar

`PLAN_06` implementado (MLX já rodando só em background). `PLAN_00`
implementado (TTFT real via `GenerateCompletionInfo` necessário para o
benchmark deste plano). Recomendado: `PLAN_03` (chat template) já
implementado — reduz conflito de merge em `MLXService.generate`.

## Dependências

`PLAN_06`, `PLAN_00`.

## Arquivos provavelmente afetados

- `Services/MLXService.swift` (`generate` ganha parâmetro `cache:
  [KVCache]? = nil`; novos tipos `TopicPromptCache`,
  `MLXPromptCacheStore`)
- Unificação dos 3 `systemPrompt`s (exemplo de código, quiz difícil,
  análise de código, hoje ligeiramente diferentes,
  `StudyGenerator.swift:270,542,732`) em um único texto genérico, com a
  instrução específica da tarefa movida para o `promptContext` — ver
  passo 2 abaixo.

## Mudanças a implementar

### 1. `TopicPromptCache` + `MLXPromptCacheStore` (actor)

```swift
// pseudocódigo — assinaturas aproximadas, ver SOLUTIONS_PLAN.md §7.2
struct TopicPromptCache {
    let topicKey: String
    let primedState: [KVCache]
    let prefixTokenCount: Int
}

actor MLXPromptCacheStore {
    private var cached: TopicPromptCache?

    func primed(for topic: String, systemPrompt: String, ragContext: String,
                model: any LanguageModel) async throws -> [KVCache] {
        // ver SOLUTIONS_PLAN.md §7.2 para o corpo completo
    }
}
```

Usa a API real confirmada do `MLXLMCommon`: `KVCache` (protocolo),
`KVCacheSimple`, `makePromptCache(model:parameters:)`. **Mantém só o
ÚLTIMO tópico primed** (`cached: TopicPromptCache?`, um valor só, não um
dicionário) — a fila MLX serial (`GenerationOrchestrator`, D5) já garante
que o crescimento de um tópico roda até o fim antes do próximo
tipicamente começar, então um valor único é suficiente e evita
crescimento de memória com o número de tópicos gerados na sessão.

### 2. Unificar os 3 system prompts

Os 3 `systemPrompt`s hoje ligeiramente diferentes ("Você é um
especialista em Swift. Gere um código de exemplo..." vs. "...Gere
perguntas técnicas difíceis..." vs. "...Gere trechos de código e
perguntas de análise...") passam a um único texto genérico ("Você é um
especialista em Swift, ajudando a gerar material de estudo sobre um
tópico específico."), com a instrução ESPECÍFICA da tarefa movida para o
`promptContext` (que já é o texto que muda por chamada). Maximiza o
tamanho do prefixo cacheável. Mudança pequena e de baixo risco (3
strings de instrução).

### 3. Prefill-only e chave do cache

`prefillOnly(prefix:model:cache:)`: roda o prefixo pelo modelo sem gerar
texto de saída, só para popular o cache — **⚠️ precisa de protótipo**:
confirmar experimentalmente que `TokenIterator` aceita `maxTokens: 0` sem
erro, ou usar `prefillStepSize` + 1 token descartado como forma prática de
"só prefill" (não confiar em suposição — testar as duas abordagens se a
primeira falhar). Chave: `SHA256(topic + systemPrompt unificado +
ragContext)`, mesmo padrão já usado em `DocumentIndex.hash(of:)`
(`DocumentIndex.swift:287-291`) — não um mecanismo novo.

### 4. Clone-and-discard antes de cada chamada divergente

```swift
private static func clone(_ cache: [KVCache]) -> [KVCache] {
    cache.map { original in
        let copy = KVCacheSimple()
        copy.state = original.state
        copy.metaState = original.metaState
        return copy as KVCache
    }
}
```

**Marcado como HYPOTHESIS/protótipo obrigatório** — não existe um
`.copy()` oficial no protocolo `KVCache`; o padrão de clonar via
`state`/`metaState` é seguro NA PRÁTICA (porque `KVCacheSimple.update()`
sempre realoca/cresce em vez de mutar in-place quando precisa crescer),
mas não é documentado oficialmente pela biblioteca. **Validar
explicitamente em teste antes de confiar em produção** — se o padrão se
mostrar instável (crash, memória descontrolada), acionar o rollback deste
plano.

## O que NÃO alterar nesta etapa

- **Não persistir o cache em disco entre execuções do app**
  (`savePromptCache`/`loadPromptCache`) — descartado conscientemente: o
  cache só vale a pena durante a janela em que os 3 usos MLX de um tópico
  acontecem em sequência (minutos, não sessões); overhead de I/O de
  `.safetensors` provavelmente não se paga para esse caso de uso.
- **Não usar `ChatSession`** — não existe na versão pinada do
  `mlx-swift-examples` (confirmado por fetch, 404 no commit exato).
- **Não usar KV cache quantizado (`kvBits`)** preventivamente — é uma
  otimização de MEMÓRIA, não de latência de prefill; só aplicar se
  `PLAN_12` (GPU memory) mostrar pressão de memória real com o cache de
  prefixo ativo.
- **Não manter um cache por tópico em dicionário** — só o último tópico
  primed, pela razão de memória já explicada.

## Implementação detalhada

Ver `SOLUTIONS_PLAN.md` §7.1 (API real completa, confirmada por fetch do
código-fonte pinado), §7.2 (desenho completo, pseudocódigo do
`TopicPromptCache`/`MLXPromptCacheStore`), §7.2.1 (unificação de system
prompts, com a razão detalhada), §7.2.2 (chave do cache), §7.2.3
(lifecycle completo: quando criar/reutilizar/destruir, ownership,
concorrência, memória, comportamento ao trocar de tópico), §7.3 (o que
NÃO fazer, com razão), §7.4 (protocolo exato do benchmark).

## Instrumentação necessária

`GenerationMetricsStore` de `PLAN_00` já tem o campo `promptCacheState`
(`hit`/`miss`/`notApplicable`) previsto — popular esse campo
corretamente a partir deste plano. Medir `prefixTokenCount` (já previsto
no struct `TopicPromptCache`) para instrumentação.

## Testes

Teste de equivalência de saída: comparar texto gerado com/sem cache para
o mesmo prompt — deveria ser idêntico ou estatisticamente equivalente
(só muda ONDE o prefill é computado, não o conteúdo semântico do prompt).
Teste de estabilidade do clone: gerar múltiplos tópicos em sequência,
confirmar ausência de crash/vazamento de memória por várias iterações
(validação manual/instrumentada, não um `XCTest` determinístico único).

## Benchmark, se aplicável

**SIM — benchmark obrigatório antes de manter esta mudança** (ver
`SOLUTIONS_PLAN.md` §7.4): comparar, para os 3 tópicos do dataset atual,
TTFT da 2ª e 3ª chamada MLX de um mesmo tópico, COM e SEM o cache primed.

## Success Criteria

TTFT da 2ª/3ª chamada cai de forma mensurável (>10%, número de corte a
calibrar depois de ver a variância natural das medições) em relação à 1ª
chamada do mesmo tópico, **sem regressão de qualidade de saída**
(comparação de texto com/sem cache para o mesmo prompt deveria ser
idêntica ou equivalente).

## Rollback

`cache: nil` (comportamento atual) — **1 linha de mudança**. Acionar se a
saída divergir de forma não-trivial no teste de equivalência, ou se o
padrão de clone se mostrar instável (crash, memória descontrolada) em
teste — ambos critérios explícitos do documento-fonte (§7.4).

## Resultado esperado

Reuso de prefill entre as 3 chamadas MLX de um tópico — ganho de TTFT nas
chamadas 2ª/3ª, SE o benchmark confirmar (a hipótese concorrente,
plausível, é que o gargalo real é decode, não prefill, dado que o
contexto RAG hoje é pequeno). Se o benchmark não confirmar ganho, o
resultado esperado é a REVERSÃO documentada, não a manutenção de uma
otimização sem efeito comprovado.

## Commit boundary

Um commit cobrindo o cache + a unificação de system prompts + o
benchmark documentado no PR (resultado incluído, não só o código).

Suggested commit: `perf: add MLX prompt prefix cache across per-topic calls (benchmark-validated)`

## Próximo plano desbloqueado

`PLAN_14` (benchmark decisivo de modelo — parte da topologia TARGET
completa).

## Claude Model Recommendation

Model:
Claude Opus 5 (`claude-opus-5`)

Reasoning level:
High

Why this model:
É a área de maior incerteza técnica do documento inteiro — trabalha
diretamente com internals do `KVCache` do MLX, um padrão de clone não
documentado oficialmente pela biblioteca (`HYPOTHESIS`, precisa de
protótipo), concorrência via `actor`, e uma técnica de "prefill-only" que
pode não ter uma API direta e exigir um workaround. Erros aqui vão de
sutis (degradação de qualidade silenciosa) a graves (crash, corrupção de
estado do cache entre chamadas) — exatamente o perfil de "MLX internals,
KV cache" citado como caso de uso de Opus.
