//
//  DocumentIndex.swift
//  SwiftStudyCoach
//
//  Pipeline de RAG: indexa os chunks de documentação (gera embeddings uma
//  vez) e permite buscar os chunks mais relevantes para uma query/tópico.
//
//  Usa o pacote NaturalLanguageEmbeddings (MIT), um wrapper fino e testado
//  em cima do NLContextualEmbedding nativo da Apple — 100% on-device,
//  zero rede, zero custo. Ver SETUP.md para instruções de instalação via SPM.
//

import Foundation
import NaturalLanguageEmbeddings
internal import NaturalLanguage

@Observable
final class DocumentIndex {

    private(set) var chunks: [DocChunk] = []
    private(set) var isIndexing = false
    private(set) var isReady = false

    private var service: EmbeddingService?

    /// Indexa o dataset (placeholder ou real) gerando o embedding de cada chunk.
    func buildIndex(from rawChunks: [(topic: String, text: String)] = PlaceholderDocs.rawChunks) async throws {
        isIndexing = true
        defer { isIndexing = false }

        let service = try await EmbeddingService(specific: .script(.latin))
        self.service = service

        var indexed: [DocChunk] = []
        for raw in rawChunks {
            let embedding = try await service.generateEmbeddings(raw.text)
            indexed.append(DocChunk(topic: raw.topic, text: raw.text, embedding: embedding))
        }

        self.chunks = indexed
        self.isReady = true
    }

    /// Busca os top-k chunks mais relevantes para uma query semântica livre
    /// (ex: uma pergunta específica, não o nome exato de um tópico indexado).
    func search(query: String, topK: Int = 3, minimumSimilarity: Double? = 0.50) async throws -> [(chunk: DocChunk, similarity: Double)] {
        guard let service, isReady else {
            throw DocumentIndexError.notReady
        }

        let embeddings = chunks.map { $0.embedding }
        let results = try await service.search(
            query: query,
            in: embeddings,
            minimumSimilarity: minimumSimilarity
        )

        return results
            .prefix(topK)
            .map { (chunks[$0.0], $0.1) }
    }

    /// Busca híbrida: tenta primeiro casar o texto de entrada diretamente
    /// com o campo `topic` de algum chunk (ex: usuário digitou "Optionals"
    /// e existe um chunk com topic == "Optionals"). Isso é mais confiável
    /// do que busca semântica quando o usuário está escolhendo um tópico
    /// já curado, em vez de fazer uma pergunta livre.
    ///
    /// Só cai para busca semântica se não houver match direto de tópico —
    /// isso também deixa o caminho pronto para o modo "tópico livre" (P2),
    /// onde a busca semântica volta a ser o caminho principal.
    func retrieveContext(for query: String, topK: Int = 3) async throws -> String {
        let queryWords = normalizedWords(query)

        let directMatches = chunks.filter { chunk in
            let topicWords = normalizedWords(chunk.topic)
            guard !topicWords.isEmpty else { return false }
            // Match por FRASE/PALAVRA inteira, nunca por substring "colada".
            // Antes disso comparava strings com os espaços removidos usando
            // .contains bidirecional — isso fazia um tópico curto como
            // "Guard" bater erroneamente com qualquer texto que contivesse
            // a sequência de letras "guard" no meio de outra palavra (ex:
            // "guardado", "resguardar", "vanguard"), trazendo o contexto de
            // RAG errado pro tópico sendo estudado.
            if topicWords == queryWords { return true }
            return containsWordSequence(topicWords, in: queryWords)
                || containsWordSequence(queryWords, in: topicWords)
        }

        if !directMatches.isEmpty {
            return directMatches
                .prefix(topK)
                .map { $0.text }
                .joined(separator: "\n\n")
        }

        // Fallback: nenhum tópico bateu diretamente, tenta busca semântica.
        let results = try await search(query: query, topK: topK)
        return results
            .map { $0.chunk.text }
            .joined(separator: "\n\n")
    }

    /// Normaliza removendo acento e case, e quebra em palavras (preservando
    /// os limites entre elas) — para que variações de digitação (ex:
    /// "navigation stack" vs "NavigationStack") batam no mesmo tópico
    /// indexado sem permitir colisões acidentais de substring entre
    /// palavras diferentes.
    private func normalizedWords(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Verifica se `needle` aparece como subsequência CONTÍGUA de palavras
    /// dentro de `haystack` (ex: ["property"] dentro de ["property",
    /// "wrappers"] bate; ["guard"] dentro de ["guardado"] NÃO bate, porque
    /// agora são comparadas palavra a palavra, não caractere a caractere).
    private func containsWordSequence(_ needle: [String], in haystack: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle {
                return true
            }
        }
        return false
    }
}

enum DocumentIndexError: Error {
    case notReady
}

// TODO (mais pra frente, se sobrar tempo):
// Cachear os embeddings gerados (ex: como JSON em Application Support)
// para não precisar reprocessar o dataset toda vez que o app abre.
// Só recalcular se o dataset mudar (ex: comparar um hash do conteúdo).
