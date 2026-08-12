# PLAN_11 — notas de implementação e correções ao `SOLUTIONS_PLAN.md` §7

Status: **código implementado, benchmark PENDENTE.** Este plano não pode ser
declarado concluído sem os números de §7.4 — ele próprio diz que, sem ganho
confirmado, o resultado esperado é a reversão documentada.

⚠️ **Nada aqui foi compilado.** A implementação foi feita fora de um
ambiente com Xcode/Metal/pesos do modelo. Toda API do `MLXLMCommon` usada foi
verificada por leitura direta do código-fonte no commit pinado
(`9bff95ca5f0b9e8c021acc4d71a2bbe4a7441631`, mlx-swift-examples v2.29.1),
mas o primeiro `xcodebuild` ainda pode acusar erros de sintaxe/isolamento.

---

## 1. Correção de CORRETUDE no desenho de §7.2

O pseudocódigo de §7.2 clona o cache primed e passa o **prompt completo**
para `generate(input:cache:...)`. Isso produz saída corrompida, não uma
versão mais rápida da mesma saída.

Evidência, de `Libraries/MLXLMCommon/Evaluate.swift` no commit pinado:

```swift
public init(input: LMInput, model: any LanguageModel, cache: [KVCache]? = nil,
            parameters: GenerateParameters) throws {
    self.cache = cache ?? model.newCache(parameters: parameters)
    try prepare(input: input, windowSize: parameters.prefillStepSize)
}

mutating func prepare(input: LMInput, windowSize: Int? = nil) throws {
    switch try model.prepare(input, cache: cache, windowSize: windowSize) { ... }
}
```

`TokenIterator` processa **todos** os tokens do `input` contra o cache que
recebe. Com um cache já contendo os P tokens do prefixo e um `input` de P + S
tokens:

- o prefixo entra no cache duas vezes (offset final = P + P + S);
- `createAttentionMask` usa `cache.first.offset` como deslocamento de
  posição, então as posições ficam deslocadas para todos os tokens.

O `mlx_lm` (Python) evita isso reconstruindo as mensagens só com o turno novo
— ou seja, passando apenas o sufixo ainda não cacheado.

**Implementado:** o prompt completo é tokenizado normalmente; comparamos em
**tokens** com o prefixo já primed (`MLXPromptCacheStore.sharedPrefixLength`);
clonamos o cache fatiado nesse comprimento; e passamos ao `generate` só os
tokens a partir dali.

Comparar em tokens (e não strings) é o que dá robustez: prompts que divergem
antes do esperado apenas reaproveitam menos, nunca reaproveitam errado.

## 2. O clone deixa de ser HYPOTHESIS

§7.2 marcava o clone via `state`/`metaState` como "seguro na prática, não
documentado". Dá para fazer melhor que "na prática". De `KVCache.swift`:

```swift
let reset = if let currentKeys = self.keys,
               (previous + keys.dim(2)) > currentKeys.dim(2) { true }
            else { self.keys == nil }
```

O setter de `state` faz `offset = keys.dim(2)`. Como o clone é montado com
arrays fatiados em **exatamente** `length` posições, ele nasce com
`offset == dim(2)`; logo `previous + n > dim(2)` é sempre verdadeiro no
primeiro `update()`, que portanto cai no ramo `reset` → realoca via
`concatenated` → escreve num array novo. **O array do pai nunca é escrito.**
A segurança vem de uma invariante, não de sorte.

**Corolário:** não usar `trimPromptCache` para encurtar o clone. `trim()` só
faz `offset -= n`, deixando `offset < dim(2)` — e aí o `update()` pode
escrever in-place num array compartilhado com o pai. O encurtamento é feito
**fatiando no momento do clone**, que preserva a invariante.

## 3. O passo `prefillOnly` foi eliminado, não resolvido

§7.2 previa um `prefillOnly(prefix:model:cache:)` e marcava com ⚠️ a dúvida
"`TokenIterator` aceita `maxTokens: 0`?".

O passo é desnecessário. A **1ª chamada MLX do tópico já processa o prefixo**
— basta não descartar o cache dela. Isso remove de uma vez o item que
precisava de protótipo, a passada extra de prefill, e o token amostrado que
teria de ser excluído do prefixo reutilizável (um token gerado não aparece no
início de nenhum prompt seguinte).

Na prática: MISS = a chamada roda normal e **guarda** seu cache; HIT = as
chamadas seguintes clonam esse cache pelo prefixo comum.

## 4. `ragContext` fora da chave do cache (desvio de §7.2.2)

§7.2.2 propunha `SHA256(topic + systemPrompt + ragContext)`. Implementado:
`SHA256(modelID + topic + systemPrompt)`.

Motivo concreto: as 3 chamadas MLX de um tópico **não usam o mesmo contexto
RAG**. O exemplo de código usa `retrieveContext(topK: 2)` e o quiz/análise
usam `topK: 3` (`TopicRepository.swift:260-261`). Com `ragContext` na chave,
as 3 chamadas dariam MISS entre si e o cache nunca seria reusado — a chave de
§7.2.2 desligaria exatamente a otimização que este plano quer medir.

É seguro porque a corretude não depende da chave: depende de
`sharedPrefixLength`, que compara tokens. Como `retrieveContext` monta o texto
com `.prefix(topK)` sobre a mesma lista ordenada, o contexto de `topK: 2` é
literalmente um prefixo do de `topK: 3`.

`modelID` entra na chave porque estado de KV cache de um modelo não significa
nada em outro (relevante para o A/B do PLAN_14).

## 5. Reordenação dos prompts (além da unificação de §7.2.1)

§7.2.1 pedia unificar os 3 system prompts. Feito
(`MLXService.draftSystemPrompt`), mas **não bastava**: o contexto RAG vive no
`promptContext`, e o prefixo reaproveitável é, por definição, um prefixo.

Com a instrução da tarefa na frente (como era), os prompts divergiam na
primeira linha e não sobrava prefixo além do system prompt. Os 3 prompts
foram reordenados para `contexto RAG → instrução da tarefa`, via
`StudyGenerator.mlxContextBlock(topic:context:)` — uma função só, para que
uma vírgula de diferença entre chamadas não corte o prefixo comum.

O texto das instruções não mudou, só a posição.

## 6. Determinismo para o teste de equivalência de §7.4

§7.4 pede comparar o texto gerado com e sem cache, esperando "idêntico ou
equivalente". Com a temperatura de produção (0.3),
`GenerateParameters.sampler()` devolve um `CategoricalSampler` com
`RandomState` própria: **duas execuções do mesmo prompt, sem cache nenhum, já
divergem.** O teste mediria o amostrador, não o cache.

Adicionado `temperatureOverride` (só o benchmark usa; produção segue em 0.3).
Com `temperature: 0` o sampler é `ArgMaxSampler`, determinístico.

Mesmo assim, o veredito não exige igualdade byte a byte: reduções em GPU não
são bit-exatas quando o mesmo valor é computado por caminhos diferentes — que
é literalmente o que o cache faz. O relatório reporta **onde** os textos
divergem: divergir no fim é ruído numérico esperado; divergir cedo é o cache
montando contexto errado, que é o critério de rollback.

---

## Como rodar o benchmark (precisa do seu Mac)

`PromptCacheBenchmark` implementa o protocolo de §7.4: por tópico, as 3
chamadas na ordem real da app, em duas fases (sem cache / com cache),
comparando TTFT e saída.

```swift
let benchmark = PromptCacheBenchmark(studyGenerator: studyGenerator)
await benchmark.run()          // usa PlaceholderDocs.allTopics()
benchmark.exportLastReport()   // JSON em Documents/
```

Ainda não há botão de UI — é ligar a partir de uma das telas de teste
existentes (mesmo padrão de `ModelBenchmarkSuite`), ou chamar de um
`.task { }` temporário.

`report.verdict` já aplica o SUCCESS CRITERIA de §7.4 automaticamente:

| Condição | Veredito |
|---|---|
| alguma saída diverge cedo (< 50% de prefixo comum) | ❌ ROLLBACK, independente do tempo |
| TTFT das chamadas 2ª/3ª cai ≥ 10% (mediana) | ✅ MANTER |
| queda < 10% | ⚠️ INCONCLUSIVO → §7.4 manda reverter |
| TTFT piora | ❌ ROLLBACK |

**Rollback:** `MLXService.isPromptCacheEnabled = false` (1 linha). Devolve o
comportamento pré-PLAN_11 por inteiro. A unificação de prompts e a
reordenação podem ficar independentemente — são neutras sem o cache.

## Hipótese concorrente, explicitada

O próprio plano registra que o gargalo real pode ser **decode, não prefill**,
já que o contexto RAG de hoje é pequeno. Se for o caso, o benchmark vai
mostrar queda de TTFT abaixo de 10% e o resultado correto é reverter. O sinal
que separa os dois cenários está instrumentado:
`GenerationMetrics.cachedPrefixTokenCount` (quantos tokens vieram do cache)
contra `timeToFirstTokenMs`. Muitos tokens reaproveitados **e** TTFT
praticamente igual = o prefill nunca foi o problema.

## Arquivos tocados

| Arquivo | Mudança |
|---|---|
| `Services/MLXPromptCache.swift` | **novo** — `TopicPromptCache`, `MLXPromptCacheStore`, `sharedPrefixLength`, `cacheKey` |
| `Services/PromptCacheBenchmark.swift` | **novo** — benchmark de §7.4 |
| `Services/MLXService.swift` | flag de rollback, system prompt unificado, cache no `generate`, `temperatureOverride` |
| `Services/StudyGenerator.swift` | `mlxContextBlock`, 3 prompts reordenados, 3 system prompts unificados, `cacheTopic` |
| `Services/GenerationMetrics.swift` | `cachedPrefixTokenCount` (aditivo); `promptCacheState` agora é populado |
| `SwiftStudyCoachTests/MLXPromptCacheTests.swift` | **novo** — testes das funções puras |

## Verificação pendente (na ordem)

1. `xcodebuild` — nada foi compilado. Suspeitos prováveis: `nonisolated` em
   declaração de tipo (`TopicPromptCache`, `PreparedGeneration`) e o subscript
   `input.text.tokens[reusable...]`.
2. `MLXPromptCacheTests` — funções puras, roda sem Metal.
3. Rodar a app e confirmar nos logs a sequência esperada por tópico:
   1 × `MISS` seguido de `HIT` com contagem de tokens reaproveitados > 0.
   **Se todas as 3 chamadas derem MISS, o ganho é zero** e o prefixo comum
   não está se formando — investigar antes de rodar o benchmark.
4. `PromptCacheBenchmark` → decisão manter/reverter.
