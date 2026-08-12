//
//  MLXPromptCache.swift
//  SwiftStudyCoach
//
//  PLAN_11 — cache de prefixo (prompt/KV cache) MLX reusado entre as 3
//  chamadas MLX de um mesmo tópico (exemplo de código, quiz difícil,
//  análise de código).
//
//  MOTIVAÇÃO (F4/D4, §7): `MLXService.generate` chamava
//  `MLXLMCommon.generate(input:parameters:context:)` sem o parâmetro
//  `cache:`. Como `TokenIterator.init` faz
//  `self.cache = cache ?? model.newCache(parameters: parameters)`, cada
//  chamada criava um `KVCacheSimple` novo e reprocessava o system prompt +
//  contexto RAG do zero — 3 vezes por tópico.
//
//  ─────────────────────────────────────────────────────────────────────
//  CORREÇÃO IMPORTANTE AO DESENHO DE `SOLUTIONS_PLAN.md` §7.2
//  ─────────────────────────────────────────────────────────────────────
//  O pseudocódigo do §7.2 clonava o cache primed e passava o prompt
//  COMPLETO para `generate(input:cache:...)`. Isso está INCORRETO, e a
//  leitura do código pinado (`Evaluate.swift`, commit `9bff95ca…`) mostra
//  por quê: `TokenIterator.init` chama `prepare(input:windowSize:)`, que
//  chama `model.prepare(input, cache: cache, windowSize:)` e processa
//  TODOS os tokens do `input` contra o cache recebido. Se o cache já
//  contém os P tokens do prefixo e passamos o prompt inteiro (P + S
//  tokens), o resultado é:
//
//    - o prefixo entra no cache DUAS vezes (offset final = P + P + S);
//    - `createAttentionMask` usa `cache.first.offset` como deslocamento,
//      então as posições ficam todas erradas.
//
//  Ou seja: não seria "mais rápido com o mesmo resultado", seria SAÍDA
//  CORROMPIDA. O `mlx_lm` (Python) evita isso passando apenas o SUFIXO
//  ainda não cacheado. É o que fazemos aqui:
//
//    1. tokenizamos o prompt COMPLETO normalmente (mesmo caminho de
//       template do PLAN_03 — `UserInput(chat:)`);
//    2. calculamos o maior prefixo COMUM em TOKENS entre o prompt novo e
//       o prefixo já primed (`sharedPrefixLength`);
//    3. clonamos o cache primed FATIADO exatamente nesse comprimento;
//    4. passamos para `generate` só os tokens a partir dali.
//
//  Trabalhar em tokens (e não em strings) é o que torna isso robusto: não
//  dependemos de os prompts baterem byte a byte, nem de fronteiras de BPE.
//  Se dois prompts divergem antes do esperado, o prefixo comum só fica
//  menor — nunca incorreto. É também por isso que o `ragContext` NÃO entra
//  na chave do cache (ver `cacheKey`): a corretude vem da comparação de
//  tokens, não da igualdade da chave.
//
//  ─────────────────────────────────────────────────────────────────────
//  POR QUE O CLONE É SEGURO (o §7.2 marcava isto como HYPOTHESIS)
//  ─────────────────────────────────────────────────────────────────────
//  O §7.2 dizia que clonar via `state`/`metaState` é "seguro na prática,
//  mas não documentado". Lendo `KVCache.swift` no commit pinado dá para
//  fazer melhor que "na prática" — dá para argumentar pela fonte:
//
//  `KVCacheSimple` guarda `keys`/`values` com folga (aloca em passos de
//  `step = 256`), e `update()` decide assim:
//
//      let reset = if let currentKeys = self.keys,
//                     (previous + keys.dim(2)) > currentKeys.dim(2) { true }
//                  else { self.keys == nil }
//
//  …e SÓ escreve in-place (`self.keys?[.ellipsis, previous ..< offset, 0...] = keys`)
//  DEPOIS de, no caso `reset`, ter trocado `self.keys` por um array novo
//  vindo de `concatenated(...)`.
//
//  O clone abaixo monta o novo cache com arrays fatiados em EXATAMENTE
//  `length` posições, e o setter de `state` faz `offset = keys.dim(2)`.
//  Logo, no clone, `previous == dim(2)` desde o início, e qualquer
//  `update()` cai obrigatoriamente no ramo `reset` → realoca via
//  `concatenated` → escreve no array NOVO. O array do pai nunca é
//  escrito. A segurança vem da invariante `offset == dim(2)`, não de
//  sorte.
//
//  Corolário importante: NÃO usar `trimPromptCache` no clone. `trim()` só
//  faz `offset -= n`, deixando `offset < dim(2)` — e aí `reset` pode ser
//  `false` e o `update()` escreveria in-place num array possivelmente
//  compartilhado com o pai, corrompendo o cache primed. O "trim" aqui é
//  feito FATIANDO no momento do clone, que preserva a invariante.
//

import Foundation
import CryptoKit
import MLX
import MLXLMCommon

/// Um cache MLX já "primed" com o prefixo comum de um tópico.
///
/// `@unchecked Sendable`: `KVCacheSimple` é uma classe mutável e não
/// `Sendable`. A segurança aqui não vem do tipo, vem do protocolo de uso, e
/// é estreita de propósito:
///
///   - a fila serial do motor MLX (`GenerationOrchestrator`, D5) garante uma
///     única geração MLX em voo por vez;
///   - este objeto é tratado como IMUTÁVEL depois de criado: ninguém chama
///     `update()` nele. Ele só é lido por `clone(upTo:)`, que constrói
///     instâncias novas.
///
/// Se alguma dessas duas condições deixar de valer, este `@unchecked` deixa
/// de ser justificável — é por isso que está escrito aqui e não escondido.
///
/// `nonisolated` no tipo: o projeto usa
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, então TODO tipo nasce
/// isolado no MainActor a menos que diga o contrário. Este aqui é
/// manipulado dentro do closure `@Sendable` de `ModelContainer.perform`,
/// que roda fora do MainActor de propósito (é o ponto inteiro do PLAN_06:
/// MLX não bloqueia a tela). Sem o `nonisolated`, `clone(upTo:)` seria uma
/// chamada cross-actor no meio do caminho quente de geração. É o mesmo
/// motivo dos `nonisolated static func` de `TopicRepository` e do
/// `nonisolated static let rawChunks` de `PlaceholderDocs`.
nonisolated final class TopicPromptCache: @unchecked Sendable {

    /// Identifica o tópico + system prompt que este cache representa.
    let key: String

    /// Tokens do prefixo, na ordem — a base da comparação de prefixo comum.
    let prefixTokens: [Int]

    /// Um `KVCacheSimple` por camada do modelo.
    let caches: [KVCacheSimple]

    /// Quantos tokens deste cache são REUTILIZÁVEIS.
    ///
    /// Distinto de `caches[i].offset` de propósito, e a diferença importa.
    /// Este cache é preenchido pela 1ª geração real do tópico (o MISS), então
    /// quando ela termina o `offset` vale `prompt + tokens gerados`. Só os
    /// `prefixTokens.count` primeiros são tokens de PROMPT; o resto é texto
    /// que o modelo produziu, que não aparece no início de nenhuma chamada
    /// seguinte.
    ///
    /// Reaproveitar além deste limite seria montar um contexto que o próximo
    /// prompt não tem — exatamente a classe de erro silencioso que este
    /// plano precisa evitar. `clone(upTo:)` recusa qualquer `length` acima
    /// deste valor.
    var reusableTokenCount: Int { prefixTokens.count }

    init(key: String, prefixTokens: [Int], caches: [KVCacheSimple]) {
        self.key = key
        self.prefixTokens = prefixTokens
        self.caches = caches
    }

    /// Clona o estado primed, fatiado em `length` tokens, pronto para ser
    /// entregue a `MLXLMCommon.generate(input:cache:parameters:context:)`.
    ///
    /// Devolve `nil` se `length` for inválido — o chamador então segue sem
    /// cache (comportamento idêntico ao de antes do PLAN_11), que é sempre
    /// uma degradação segura.
    func clone(upTo length: Int) -> [KVCache]? {
        guard length > 0, length <= reusableTokenCount else { return nil }

        var copies: [KVCache] = []
        copies.reserveCapacity(caches.count)

        for original in caches {
            let state = original.state
            // `KVCacheSimple.state` é sempre [keys, values]; vazio só se o
            // cache nunca foi usado (aí não há nada a reaproveitar).
            guard state.count == 2 else { return nil }

            // Guarda contra um cache mais CURTO do que os `prefixTokens`
            // dizem. Hoje isso não acontece, mas há um caminho concreto que
            // o criaria: se o PLAN_12 ligar `GenerateParameters.kvBits`,
            // `maybeQuantizeKVCache` passa a SUBSTITUIR os elementos do
            // array de cache do `TokenIterator` por `QuantizedKVCache`
            // durante a geração. As instâncias `KVCacheSimple` que este
            // objeto guarda parariam de ser atualizadas a partir dali, e
            // ficariam com menos tokens do que `prefixTokens` promete.
            //
            // Nesse caso o certo é NÃO reaproveitar: devolver `nil` faz o
            // chamador gerar sem cache, com a saída correta. É a degradação
            // segura — o contrário (fatiar um cache curto demais e seguir em
            // frente) seria um erro silencioso de conteúdo.
            guard state[0].dim(2) >= length, state[1].dim(2) >= length else { return nil }

            // Fatiar em `length` é o que garante `offset == dim(2)` no
            // clone — ver a nota sobre segurança do clone no topo do
            // arquivo. Mesmo padrão de indexação usado pelo próprio
            // `KVCacheSimple` (`keys[.ellipsis, ..<offset, 0...]`).
            let copy = KVCacheSimple()
            copy.state = [
                state[0][.ellipsis, ..<length, 0...],
                state[1][.ellipsis, ..<length, 0...],
            ]
            // `metaState` de `KVCacheSimple` é sempre `[]` (e o setter dá
            // `fatalError` se receber não-vazio), então não há nada a
            // copiar. Escrito explicitamente para deixar claro que a
            // omissão é intencional, não esquecimento.
            copies.append(copy)
        }

        return copies
    }
}

/// Guarda o ÚLTIMO tópico primed (um valor só, não um dicionário).
///
/// §7.2.3: a fila MLX serial faz o crescimento de um tópico rodar até o fim
/// antes do próximo começar, então um único slot basta — e evita que o
/// consumo de RAM cresça com o número de tópicos gerados na sessão.
actor MLXPromptCacheStore {

    static let shared = MLXPromptCacheStore()

    private var cached: TopicPromptCache?

    private init() {}

    /// Devolve o cache primed se ele for do mesmo tópico/system prompt.
    func cached(matching key: String) -> TopicPromptCache? {
        guard let cached, cached.key == key else { return nil }
        return cached
    }

    /// Substitui o slot único. O cache anterior é liberado aqui (troca de
    /// tópico = descarta o antigo, §7.2.3).
    ///
    /// CUSTO DE MEMÓRIA — o que exatamente fica retido: KV de
    /// `prompt + tokens gerados` da 1ª chamada do tópico, em memória
    /// unificada (são `MLXArray`s). A ordem de grandeza é
    /// `tokens × camadas × 2 (K e V) × kvHeads × headDim × bytes por
    /// elemento`; para o Qwen2.5-Coder-7B em 4-bit, com o contexto RAG de
    /// hoje, isso fica na casa de dezenas de MB — pequeno perto dos ~4,3 GB
    /// de pesos, mas NÃO zero.
    ///
    /// É por isso que o slot é único: um dicionário por tópico faria esse
    /// custo crescer com o número de tópicos abertos na sessão, que é
    /// justamente o cenário de pressão de memória descrito no cabeçalho do
    /// `MLXService` (o motivo de o modelo 30B ter sido revertido). O
    /// `GPU.snapshot()` do PLAN_12, já instrumentado em
    /// `MLXService.generate`, é onde esse número aparece medido de verdade.
    func store(_ primed: TopicPromptCache) {
        cached = primed
    }

    /// Descarta o cache primed. Usado pelo benchmark para forçar um MISS
    /// limpo, e disponível como válvula de escape se a memória apertar.
    func invalidate() {
        cached = nil
    }

    // MARK: - Helpers puros (testáveis sem Metal)
    //
    // `nonisolated`: membros `static` herdam o isolamento padrão do projeto
    // (MainActor) mesmo dentro de um `actor`. Estes dois são chamados de
    // dentro do closure `@Sendable` de `ModelContainer.perform` (fora do
    // MainActor) e dos testes unitários — precisam ser livres de isolamento.
    // São funções puras, então não há o que proteger.

    /// Número de tokens iniciais em comum entre duas sequências.
    ///
    /// É o coração da corretude deste plano: em vez de exigir que os prompts
    /// sejam idênticos, medimos até onde eles realmente coincidem EM TOKENS
    /// e reaproveitamos só isso. Um prompt que diverge cedo simplesmente
    /// reaproveita menos — nunca reaproveita errado.
    nonisolated static func sharedPrefixLength(_ lhs: [Int], _ rhs: [Int]) -> Int {
        let limit = min(lhs.count, rhs.count)
        var index = 0
        while index < limit, lhs[index] == rhs[index] {
            index += 1
        }
        return index
    }

    /// Chave do cache primed.
    ///
    /// DESVIO DELIBERADO de `SOLUTIONS_PLAN.md` §7.2.2, que propunha
    /// `SHA256(topic + systemPrompt + ragContext)`. O `ragContext` fica de
    /// fora por um motivo concreto: as 3 chamadas MLX de um tópico NÃO usam
    /// o mesmo contexto RAG hoje — o exemplo de código usa
    /// `retrieveContext(topK: 2)` e o quiz/análise usam `topK: 3`
    /// (`TopicRepository.swift:260-261`). Com o `ragContext` na chave, as 3
    /// chamadas dariam MISS entre si e o cache nunca seria reusado — ou
    /// seja, a chave do §7.2.2 desligaria exatamente a otimização que o
    /// PLAN_11 quer medir.
    ///
    /// Tirá-lo da chave é seguro porque a corretude não depende da chave:
    /// depende de `sharedPrefixLength`, que compara TOKENS. Se o contexto
    /// mudar (topK diferente, dataset novo), o prefixo comum encolhe
    /// sozinho e o resto é reprocessado normalmente. Como
    /// `retrieveContext` monta o texto com `.prefix(topK)` sobre a mesma
    /// lista ordenada, o contexto de `topK: 2` é literalmente um prefixo do
    /// de `topK: 3` — então o reuso entre as 3 chamadas continua alto.
    ///
    /// Mesmo padrão de hash de `DocumentIndex.hash(of:)`
    /// (`DocumentIndex.swift:325-328`) — SHA256 hex, sem mecanismo novo.
    nonisolated static func cacheKey(topic: String, systemPrompt: String, modelID: String) -> String {
        let joined = "\(modelID)\u{1F}\(topic)\u{1F}\(systemPrompt)"
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
