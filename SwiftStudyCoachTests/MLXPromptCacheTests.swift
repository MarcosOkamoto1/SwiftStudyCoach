//
//  MLXPromptCacheTests.swift
//  SwiftStudyCoachTests
//
//  PLAN_11 — testes das partes PURAS do cache de prefixo MLX.
//
//  Escopo, explicitamente: o que dá para testar sem Metal, sem GPU e sem
//  baixar 4,3 GB de pesos. `sharedPrefixLength` e `cacheKey` são funções
//  puras e cobrem o núcleo da CORREÇÃO deste plano — é
//  `sharedPrefixLength` que decide quantos tokens são reaproveitados, e um
//  erro nela é exatamente o bug de "prefixo processado duas vezes" que o
//  desenho original de SOLUTIONS_PLAN.md §7.2 tinha.
//
//  O que NÃO está aqui, e por quê: o teste de equivalência de saída e o de
//  estabilidade do clone (§7.4) precisam do modelo real carregado, então
//  vivem no `PromptCacheBenchmark`, rodado à mão num Mac com o modelo
//  presente. O próprio PLAN_11 já previa isso ("validação
//  manual/instrumentada, não um XCTest determinístico único").
//

import XCTest
@testable import SwiftStudyCoach

final class MLXPromptCacheTests: XCTestCase {

    // MARK: - sharedPrefixLength

    func testSharedPrefixLengthIdenticalSequences() {
        let tokens = [1, 2, 3, 4, 5]
        XCTAssertEqual(MLXPromptCacheStore.sharedPrefixLength(tokens, tokens), 5)
    }

    func testSharedPrefixLengthNoCommonPrefix() {
        XCTAssertEqual(MLXPromptCacheStore.sharedPrefixLength([1, 2, 3], [9, 2, 3]), 0)
    }

    func testSharedPrefixLengthPartialOverlap() {
        // O caso REAL do PLAN_11: system prompt + contexto RAG em comum
        // (aqui, [10, 11, 12]), instrução da tarefa divergindo depois.
        let codeExample = [10, 11, 12, 500, 501]
        let hardQuiz = [10, 11, 12, 700, 701, 702]
        XCTAssertEqual(MLXPromptCacheStore.sharedPrefixLength(codeExample, hardQuiz), 3)
    }

    func testSharedPrefixLengthOneIsPrefixOfOther() {
        // Espelha a diferença real de topK entre as chamadas: o contexto de
        // `topK: 2` é um prefixo do de `topK: 3`
        // (`retrieveContext` usa `.prefix(topK)` sobre a mesma lista), então
        // o prefixo comum tem que ser a sequência curta INTEIRA.
        let shorter = [1, 2, 3]
        let longer = [1, 2, 3, 4, 5]
        XCTAssertEqual(MLXPromptCacheStore.sharedPrefixLength(shorter, longer), 3)
        XCTAssertEqual(MLXPromptCacheStore.sharedPrefixLength(longer, shorter), 3)
    }

    func testSharedPrefixLengthEmptyInputs() {
        XCTAssertEqual(MLXPromptCacheStore.sharedPrefixLength([], []), 0)
        XCTAssertEqual(MLXPromptCacheStore.sharedPrefixLength([], [1, 2]), 0)
        XCTAssertEqual(MLXPromptCacheStore.sharedPrefixLength([1, 2], []), 0)
    }

    func testSharedPrefixLengthDivergesAtFirstToken() {
        XCTAssertEqual(MLXPromptCacheStore.sharedPrefixLength([7, 7, 7], [8, 7, 7]), 0)
    }

    func testSharedPrefixLengthNeverExceedsShorterSequence() {
        // Invariante de segurança: o resultado alimenta `clone(upTo:)` e uma
        // fatia maior que o cache primed seria um índice fora de faixa.
        for (lhs, rhs) in [([1, 2, 3], [1, 2, 3, 4]), ([1], [1, 1, 1]), ([5, 5], [5, 5])] {
            let result = MLXPromptCacheStore.sharedPrefixLength(lhs, rhs)
            XCTAssertLessThanOrEqual(result, min(lhs.count, rhs.count))
        }
    }

    // MARK: - cacheKey

    func testCacheKeyIsStableForSameInputs() {
        let a = MLXPromptCacheStore.cacheKey(topic: "Optionals", systemPrompt: "sys", modelID: "m")
        let b = MLXPromptCacheStore.cacheKey(topic: "Optionals", systemPrompt: "sys", modelID: "m")
        XCTAssertEqual(a, b)
    }

    func testCacheKeyChangesWithTopic() {
        let a = MLXPromptCacheStore.cacheKey(topic: "Optionals", systemPrompt: "sys", modelID: "m")
        let b = MLXPromptCacheStore.cacheKey(topic: "Closures", systemPrompt: "sys", modelID: "m")
        XCTAssertNotEqual(a, b, "Tópicos diferentes têm contexto RAG diferente — reusar o cache entre eles produziria conteúdo errado.")
    }

    func testCacheKeyChangesWithModelID() {
        let a = MLXPromptCacheStore.cacheKey(topic: "Optionals", systemPrompt: "sys", modelID: "qwen-7b")
        let b = MLXPromptCacheStore.cacheKey(topic: "Optionals", systemPrompt: "sys", modelID: "qwen-14b")
        XCTAssertNotEqual(a, b, "Estado de KV cache de um modelo não tem significado nenhum em outro.")
    }

    func testCacheKeyChangesWithSystemPrompt() {
        let a = MLXPromptCacheStore.cacheKey(topic: "Optionals", systemPrompt: "sys A", modelID: "m")
        let b = MLXPromptCacheStore.cacheKey(topic: "Optionals", systemPrompt: "sys B", modelID: "m")
        XCTAssertNotEqual(a, b)
    }

    func testCacheKeyIsSHA256Hex() {
        let key = MLXPromptCacheStore.cacheKey(topic: "Optionals", systemPrompt: "sys", modelID: "m")
        XCTAssertEqual(key.count, 64, "Mesmo formato de `DocumentIndex.hash(of:)` — SHA256 em hex.")
        XCTAssertTrue(key.allSatisfy { $0.isHexDigit })
    }

    /// Separadores existem para que campos diferentes não possam se fundir
    /// numa mesma string e gerar colisão de chave.
    func testCacheKeyFieldsAreNotAmbiguous() {
        let a = MLXPromptCacheStore.cacheKey(topic: "ab", systemPrompt: "c", modelID: "m")
        let b = MLXPromptCacheStore.cacheKey(topic: "a", systemPrompt: "bc", modelID: "m")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Bloco de contexto compartilhado

    /// O ganho do PLAN_11 depende de as 3 chamadas de um tópico começarem
    /// com um texto idêntico. Se alguém editar `mlxContextBlock` de forma a
    /// fazê-lo variar por tarefa, o cache continua CORRETO (a comparação é
    /// por token), mas o ganho vira zero silenciosamente. Este teste é o
    /// alarme para esse caso.
    @MainActor
    func testContextBlockIsIdenticalForSameTopicAndContext() {
        let first = StudyGenerator.mlxContextBlock(topic: "Optionals", context: "conteúdo oficial")
        let second = StudyGenerator.mlxContextBlock(topic: "Optionals", context: "conteúdo oficial")
        XCTAssertEqual(first, second)
    }

    @MainActor
    func testContextBlockFallsBackWhenContextIsEmpty() {
        let block = StudyGenerator.mlxContextBlock(topic: "Optionals", context: "")
        XCTAssertTrue(block.contains("Conhecimento geral sobre Swift"))
    }

    /// O contexto de `topK: 2` é prefixo do de `topK: 3`, então o bloco
    /// montado com o menor tem que ser prefixo do montado com o maior — é
    /// isso que faz o exemplo de código (topK 2) e o quiz (topK 3)
    /// compartilharem prefixo apesar de usarem contextos diferentes.
    @MainActor
    func testContextBlockOfShorterContextIsPrefixOfLonger() {
        let shortContext = "chunk um"
        let longContext = "chunk um\n\nchunk dois"
        let shortBlock = StudyGenerator.mlxContextBlock(topic: "Optionals", context: shortContext)
        let longBlock = StudyGenerator.mlxContextBlock(topic: "Optionals", context: longContext)
        XCTAssertTrue(longBlock.hasPrefix(shortBlock))
    }
}
