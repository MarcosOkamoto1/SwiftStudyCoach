//
//  DocumentIndexRawChunksParityTests.swift
//  SwiftStudyCoachTests
//
//  PLAN_04 — garante que o novo caminho síncrono
//  `DocumentIndex.rawChunks(forExactTopic:)` (leitura direta do dataset
//  estático, sem embeddings) devolve exatamente o mesmo conteúdo que
//  `DocumentIndex.chunks(forExactTopic:)` (caminho antigo, que depende de
//  `ensureReady()` ter completado e do índice de embeddings estar
//  construído). Os dois caminhos precisam ficar consistentes: quem chama o
//  caminho síncrono novo (StudyGenerator.retrieveContext) não pode obter um
//  resultado diferente de quem ainda usa o caminho assíncrono antigo
//  (RAGTestView, StudyResultView.resolveRecommendedTopic via hybridSearch).
//

import XCTest
@testable import SwiftStudyCoach

final class DocumentIndexRawChunksParityTests: XCTestCase {

    /// Constrói um índice FRESCO (instância própria, não o `.shared`
    /// compartilhado) para não interferir com outros testes/telas que
    /// dependam do singleton, e para garantir que estamos testando a partir
    /// de um estado conhecido (índice construído do zero a partir do
    /// dataset atual).
    private func buildFreshIndex() async throws -> DocumentIndex {
        let index = DocumentIndex()
        try await index.buildIndex()
        return index
    }

    func testRawChunksMatchesIndexedChunksForEveryTopic() async throws {
        let index = try await buildFreshIndex()

        for topic in PlaceholderDocs.allTopics() {
            let synchronous = DocumentIndex.rawChunks(forExactTopic: topic)
            let indexed = index.chunks(forExactTopic: topic)

            XCTAssertEqual(
                synchronous.map(\.text),
                indexed.map(\.text),
                "Textos devem ser idênticos (mesma ordem) para o tópico '\(topic)'."
            )
            XCTAssertEqual(
                synchronous.map(\.topic),
                indexed.map(\.topic),
                "Nomes de tópico devem ser idênticos para '\(topic)'."
            )
            XCTAssertFalse(synchronous.isEmpty, "Tópico '\(topic)' veio do próprio dataset — não deveria estar vazio.")
        }
    }

    func testRawChunksEmptyForUnknownTopic() {
        let result = DocumentIndex.rawChunks(forExactTopic: "Tópico Que Não Existe No Dataset")
        XCTAssertTrue(result.isEmpty)
    }

    func testRawChunksEmptyForUnknownTopicMatchesIndexedPath() async throws {
        let index = try await buildFreshIndex()
        let topic = "Tópico Que Não Existe No Dataset"

        XCTAssertEqual(DocumentIndex.rawChunks(forExactTopic: topic).count, index.chunks(forExactTopic: topic).count)
    }

    func testRawChunksIsSynchronousAndDoesNotRequireReadyIndex() {
        // Nenhum `ensureReady()`/`buildIndex()` foi chamado aqui — é
        // justamente o ponto do PLAN_04: este caminho não depende do índice
        // de embeddings de forma alguma.
        let result = DocumentIndex.rawChunks(forExactTopic: "NavigationStack")
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result.count, PlaceholderDocs.rawChunks.filter { $0.topic == "NavigationStack" }.count)
    }
}
