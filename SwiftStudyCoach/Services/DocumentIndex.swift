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
//  Melhorias desta versão:
//  - `shared`: um único índice pro app todo (antes cada tela criava o seu
//    e re-embedava o dataset inteiro a cada visita).
//  - Cache de embeddings em disco (Application Support), chaveado por hash
//    SHA-256 do dataset: reindexa só quando o conteúdo muda.
//  - Busca híbrida: fusão de score semântico (cosseno) + léxico (overlap de
//    termos) + boost de match de tópico — antes o match de tópico era um
//    curto-circuito "tudo ou nada".
//  - Threshold adaptativo: relaxa o corte antes de devolver contexto vazio
//    (contexto vazio silencioso = modelo alucinando sem grounding).
//

import Foundation
import CryptoKit
import NaturalLanguageEmbeddings
internal import NaturalLanguage

@Observable
final class DocumentIndex {

    /// Índice único do app: construído uma vez (cache em disco torna as
    /// aberturas seguintes quase instantâneas) e compartilhado por todas as
    /// telas via `DocumentIndex.shared`.
    static let shared = DocumentIndex()

    private(set) var chunks: [DocChunk] = []
    private(set) var isIndexing = false
    private(set) var isReady = false

    private var service: EmbeddingService?
    private var buildTask: Task<Void, Error>?

    // MARK: - Construção do índice

    /// Garante que o índice está pronto, construindo-o no máximo UMA vez
    /// mesmo com chamadas concorrentes (várias telas chamando ao mesmo tempo
    /// aguardam o mesmo Task em vez de disparar builds duplicados).
    func ensureReady() async throws {
        if isReady { return }
        if let buildTask {
            try await buildTask.value
            return
        }
        let task = Task { try await buildIndex() }
        buildTask = task
        do {
            try await task.value
        } catch {
            buildTask = nil // permite retry após falha
            throw error
        }
    }

    /// Indexa o dataset (placeholder ou real). Tenta primeiro o cache em
    /// disco; só gera embeddings de verdade se o dataset mudou.
    func buildIndex(from rawChunks: [(topic: String, block: TrackBlock, text: String)] = PlaceholderDocs.rawChunks) async throws {
        isIndexing = true
        defer { isIndexing = false }

        let service = try await EmbeddingService(specific: .script(.latin))
        self.service = service

        let datasetHash = Self.hash(of: rawChunks)

        // 1. Cache HIT: dataset idêntico ao da última indexação → carrega
        //    os embeddings prontos do disco (ms, zero inferência).
        if let cached = Self.loadCache(), cached.datasetHash == datasetHash {
            print("🟢 DocumentIndex: cache de embeddings HIT (\(cached.chunks.count) chunks) — nada a reindexar.")
            self.chunks = cached.chunks
            self.isReady = true
            return
        }

        // 2. Cache MISS: gera os embeddings e persiste pro próximo launch.
        //    (Sequencial de propósito: o NLContextualEmbedding subjacente não
        //    documenta thread-safety; com o cache em disco, este custo é pago
        //    uma única vez por versão do dataset.)
        print("🟠 DocumentIndex: cache de embeddings MISS — indexando \(rawChunks.count) chunks.")
        var indexed: [DocChunk] = []
        for raw in rawChunks {
            let embedding = try await service.generateEmbeddings(raw.text)
            indexed.append(DocChunk(topic: raw.topic, text: raw.text, embedding: embedding))
        }

        self.chunks = indexed
        self.isReady = true
        Self.saveCache(CachedIndex(datasetHash: datasetHash, chunks: indexed))
    }

    // MARK: - Busca

    /// Busca semântica pura (mantida para a tela de debug RAGTestView).
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

    /// Busca híbrida com fusão de score:
    ///   score = 0.6 * cosseno + 0.4 * overlap léxico + boost de tópico (0.25)
    /// O match direto de tópico (ex: usuário digitou "Optionals" e existe um
    /// chunk topic == "Optionals") vira um BOOST em vez de curto-circuito —
    /// assim um chunk de outro tópico muito relevante ainda pode competir, e
    /// variações de digitação continuam favorecendo o tópico certo.
    func hybridSearch(query: String, topK: Int = 3) async throws -> [(chunk: DocChunk, score: Double)] {
        guard let service, isReady else {
            throw DocumentIndexError.notReady
        }

        let embeddings = chunks.map { $0.embedding }
        let semantic = try await service.search(query: query, in: embeddings, minimumSimilarity: nil)
        var similarityByIndex: [Int: Double] = [:]
        for (index, similarity) in semantic {
            similarityByIndex[index] = similarity
        }

        let queryTokens = Self.tokens(of: query)
        let normalizedQuery = normalize(query)

        var scored: [(chunk: DocChunk, score: Double, lexical: Double, topicBoost: Double)] = []
        for (index, chunk) in chunks.enumerated() {
            let cosine = similarityByIndex[index] ?? 0
            let lexical = Self.lexicalOverlap(queryTokens: queryTokens, text: chunk.text)

            let normalizedTopic = normalize(chunk.topic)
            let topicMatches = normalizedTopic == normalizedQuery
                || normalizedTopic.contains(normalizedQuery)
                || normalizedQuery.contains(normalizedTopic)
            let topicBoost: Double = topicMatches ? 0.25 : 0

            scored.append((chunk, 0.6 * cosine + 0.4 * lexical + topicBoost, lexical, topicBoost))
        }
        scored.sort { $0.score > $1.score }

        // Threshold adaptativo: corte "bom" primeiro; se nada passar, relaxa
        // antes de devolver vazio — grounding fraco ainda é melhor que nenhum.
        let strong = scored.filter { $0.score >= 0.45 }
        if !strong.isEmpty {
            return Array(strong.prefix(topK)).map { ($0.chunk, $0.score) }
        }

        // Plano V3 3.2 — gate de contexto com sinal duplo: o corte relaxado
        // só aceita um chunk se ele tiver TAMBÉM sinal léxico (overlap > 0)
        // ou boost de tópico ativo — semântica sozinha, sem nenhum termo
        // batendo e sem o tópico coincidir, é o perfil clássico de falso
        // positivo entre textos do mesmo domínio (contexto errado é pior
        // que contexto vazio).
        let relaxed = scored.filter { $0.score >= 0.30 && ($0.lexical > 0 || $0.topicBoost > 0) }
        return Array(relaxed.prefix(topK)).map { ($0.chunk, $0.score) }
    }

    // MARK: - Caminho determinístico (Plano V4 Fase 4)

    /// Busca chunks por IGUALDADE EXATA de `chunk.topic` — sem embedding,
    /// sem ranking, sem chance de contaminação cross-topic. É o caminho
    /// usado por 100% das gerações internas (StudyGenerator.retrieveContext),
    /// onde quem chama já sabe o nome exato do tópico. O `hybridSearch`
    /// fica reservado aos usos que de fato NÃO sabem o tópico de antemão:
    /// StudyResultView.resolveRecommendedTopic e a tela de debug RAGTestView.
    ///
    /// Causa raiz que isto corrige: tratar o nome exato do tópico como query
    /// fuzzy fazia chunks de OUTROS tópicos (que mencionam o nome de
    /// passagem, como cross-referência) empatarem em overlap léxico perfeito
    /// e roubarem vagas do topK — ex.: chunks de Property Wrappers/Guard
    /// aparecendo numa consulta por "Optionals".
    func chunks(forExactTopic topic: String) -> [DocChunk] {
        chunks.filter { $0.topic == topic }
    }

    /// Recupera o contexto concatenado dos top-k chunks para grounding.
    /// ⚠️ Caminho FUZZY — só para queries de texto livre. Geração interna
    /// (tópico exato conhecido) deve usar `chunks(forExactTopic:)`.
    func retrieveContext(for query: String, topK: Int = 3) async throws -> String {
        let ranked = try await hybridSearch(query: query, topK: topK)
        return ranked
            .map { $0.chunk.text }
            .joined(separator: "\n\n")
    }

    // MARK: - Normalização / léxico

    /// Normaliza removendo acento, case e espaços, para que variações de
    /// digitação (ex: "navigation stack" vs "NavigationStack") batam no
    /// mesmo tópico indexado.
    private func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
    }

    private static func tokens(of text: String) -> Set<String> {
        Set(
            text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
        )
    }

    /// Fração dos termos da query presentes no texto do chunk (0...1).
    private static func lexicalOverlap(queryTokens: Set<String>, text: String) -> Double {
        guard !queryTokens.isEmpty else { return 0 }
        let textTokens = tokens(of: text)
        let hits = queryTokens.intersection(textTokens).count
        return Double(hits) / Double(queryTokens.count)
    }

    // MARK: - Cache em disco

    private struct CachedIndex: Codable {
        let datasetHash: String
        let chunks: [DocChunk]
    }

    private static var cacheURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("SwiftStudyCoach", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("rag-index-cache.json")
    }

    private static func hash(of rawChunks: [(topic: String, block: TrackBlock, text: String)]) -> String {
        let joined = rawChunks.map { "\($0.topic)\u{1F}\($0.text)" }.joined(separator: "\u{1E}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func loadCache() -> CachedIndex? {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(CachedIndex.self, from: data)
        else { return nil }
        return cached
    }

    private static func saveCache(_ cache: CachedIndex) {
        guard let url = cacheURL else { return }
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: url, options: .atomic)
            print("🟢 DocumentIndex: cache de embeddings salvo (\(data.count / 1024) KB).")
        } catch {
            print("⚠️ DocumentIndex: falha ao salvar cache de embeddings: \(error)")
        }
    }
}

enum DocumentIndexError: Error {
    case notReady
}
