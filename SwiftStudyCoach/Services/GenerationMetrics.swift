//
//  GenerationMetrics.swift
//  SwiftStudyCoach
//
//  PLAN_00 — Instrumentação real de geração (tokens, TTFT, tokens/s, tempo
//  total, retries, estado de cache), substituindo a métrica de "chars/s"
//  (F9) e a instrumentação só-`print` (F23) por dados estruturados.
//
//  Puramente de profiling técnico — não é analytics de produto, não sai do
//  device, não é persistido além da sessão de desenvolvimento (a menos que
//  explicitamente exportado via `GenerationMetricsStore.exportToDocuments`).
//
//  Este arquivo é estritamente ADITIVO: nenhum `print` existente no projeto
//  foi removido em função dele — a store complementa o console, não o
//  substitui (ver SOLUTIONS_PLAN.md §10.3).
//

import Foundation

struct GenerationMetrics: Sendable, Codable, Identifiable {

    enum Engine: String, Codable, Sendable {
        case foundationModels, mlx
    }

    enum TaskType: String, Codable, Sendable {
        case summary, easyQuiz, mediumQuiz, hardQuizDraft, hardQuizFormat,
             codeExampleDraft, codeExampleCritique, codeExampleFormat,
             codeAnalysisDraft, codeAnalysisCritique, codeAnalysisFormat,
             feedback, embeddingIndex

        /// Não faz parte da lista original de `SOLUTIONS_PLAN.md` §10.1 (que
        /// cobre só taskTypes de GERAÇÃO) — adicionado porque a tabela de
        /// instrumentação (§10.2) pede explicitamente para o carregamento do
        /// modelo MLX (`MLXService.performLoad`) também virar um
        /// `GenerationMetrics`, e não existia nenhum case que coubesse. É
        /// puramente aditivo: não renomeia nem remove nenhum case existente.
        case modelLoad
    }

    /// hit/miss/notApplicable — hoje sempre `notApplicable` para chamadas de
    /// geração pura, já que não existe cache de prefixo ainda (ver
    /// PLAN_11). `DocumentIndex.buildIndex` é quem de fato usa hit/miss,
    /// para o cache de embeddings em disco.
    enum CacheState: String, Codable, Sendable {
        case hit, miss, notApplicable
    }

    let id: UUID
    let timestamp: Date
    let engine: Engine
    let taskType: TaskType
    let topic: String
    /// `MLXService.modelID` para chamadas MLX, `"system"` para Foundation
    /// Models (modelo de sistema, sem ID de repositório).
    let modelID: String
    /// `true` se esta chamada envolveu um `loadModel()`/`performLoad()`
    /// (pesos ainda não residentes na RAM) — para chamadas de `generate`,
    /// hoje sempre `false`, já que `loadModel()` é chamado separadamente
    /// pelo chamador antes de `generate` (ver `MLXService.generate`).
    let isColdStart: Bool
    /// MLX: `GenerateCompletionInfo.promptTokenCount` (real).
    /// Foundation Models: `Needs runtime measurement` — o framework fechado
    /// não expõe contagem de tokens na API pública (não verificado nesta
    /// sessão, fonte fechada); fica `nil` por enquanto (ver SOLUTIONS_PLAN.md
    /// §10.2).
    let inputTokenCount: Int?
    /// Idem, para `GenerateCompletionInfo.generationTokenCount`.
    let outputTokenCount: Int?
    /// Só MLX — `GenerateCompletionInfo.promptTime` (tempo até o 1º token).
    let timeToFirstTokenMs: Double?
    /// `GenerateCompletionInfo.generateTime` (tempo de decodificação do
    /// restante dos tokens).
    let decodeTimeMs: Double?
    let totalTimeMs: Double
    /// `GenerateCompletionInfo.tokensPerSecond` (real, já pronto pela API do
    /// mlx-swift-examples) — substitui diretamente a métrica de "chars/s"
    /// (F9) que existia antes.
    let tokensPerSecond: Double?
    let retryCount: Int
    let ragContextChars: Int
    let ragChunkCount: Int
    /// 1 se não for uma chamada em lote.
    let batchSize: Int
    let promptCacheState: CacheState
    /// `GPU.snapshot()` antes/depois — deixados `nil` por enquanto, só
    /// entram no PLAN_12 (MLX Memory Strategy).
    let memoryBeforeBytes: Int?
    let memoryAfterBytes: Int?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        engine: Engine,
        taskType: TaskType,
        topic: String,
        modelID: String,
        isColdStart: Bool = false,
        inputTokenCount: Int? = nil,
        outputTokenCount: Int? = nil,
        timeToFirstTokenMs: Double? = nil,
        decodeTimeMs: Double? = nil,
        totalTimeMs: Double,
        tokensPerSecond: Double? = nil,
        retryCount: Int = 0,
        ragContextChars: Int = 0,
        ragChunkCount: Int = 0,
        batchSize: Int = 1,
        promptCacheState: CacheState = .notApplicable,
        memoryBeforeBytes: Int? = nil,
        memoryAfterBytes: Int? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.engine = engine
        self.taskType = taskType
        self.topic = topic
        self.modelID = modelID
        self.isColdStart = isColdStart
        self.inputTokenCount = inputTokenCount
        self.outputTokenCount = outputTokenCount
        self.timeToFirstTokenMs = timeToFirstTokenMs
        self.decodeTimeMs = decodeTimeMs
        self.totalTimeMs = totalTimeMs
        self.tokensPerSecond = tokensPerSecond
        self.retryCount = retryCount
        self.ragContextChars = ragContextChars
        self.ragChunkCount = ragChunkCount
        self.batchSize = batchSize
        self.promptCacheState = promptCacheState
        self.memoryBeforeBytes = memoryBeforeBytes
        self.memoryAfterBytes = memoryAfterBytes
    }
}

/// Coleta em memória de `GenerationMetrics` durante a sessão do app. Aditiva
/// ao `print` com emoji já usado no projeto — não o substitui.
actor GenerationMetricsStore {
    static let shared = GenerationMetricsStore()

    private var records: [GenerationMetrics] = []

    private init() {}

    func record(_ metric: GenerationMetrics) {
        records.append(metric)
        // Mantém o hábito de log com prefixo emoji já estabelecido no
        // projeto (ver SOLUTIONS_PLAN.md §9.3) — a store é ADITIVA à
        // instrumentação atual, não substitui o console.
        let tokensSuffix = metric.tokensPerSecond.map { " · \(String(format: "%.1f", $0)) tok/s" } ?? ""
        print("📊 [\(metric.taskType.rawValue)/\(metric.engine.rawValue)] \(String(format: "%.0f", metric.totalTimeMs))ms\(tokensSuffix)")
    }

    func snapshot() -> [GenerationMetrics] {
        records
    }

    /// Agregação simples por `taskType` — média/percentil 50, para não
    /// precisar abrir uma planilha só para ler o console.
    func summary() -> [GenerationMetrics.TaskType: (count: Int, avgMs: Double, p50Ms: Double)] {
        var result: [GenerationMetrics.TaskType: (count: Int, avgMs: Double, p50Ms: Double)] = [:]
        let grouped = Dictionary(grouping: records, by: \.taskType)
        for (taskType, items) in grouped {
            let times = items.map(\.totalTimeMs).sorted()
            guard !times.isEmpty else { continue }
            let avg = times.reduce(0, +) / Double(times.count)
            let p50 = times[times.count / 2]
            result[taskType] = (count: items.count, avgMs: avg, p50Ms: p50)
        }
        return result
    }

    /// Serializa todos os registros da sessão em JSON (`Codable`, sem
    /// dependência nova).
    func exportJSON() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(records)) ?? Data()
    }

    /// Escreve o JSON exportado em `Documents/` — mesmo padrão de
    /// `DocumentIndex.cacheURL` — para inspeção manual durante o
    /// desenvolvimento (ex.: a partir de um botão em `TopicRepositoryTestView`).
    @discardableResult
    func exportToDocuments() -> URL? {
        guard let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = base.appendingPathComponent("generation-metrics-\(Int(Date().timeIntervalSince1970)).json")
        let data = exportJSON()
        do {
            try data.write(to: url, options: .atomic)
            print("🟢 GenerationMetricsStore: métricas exportadas para \(url.path) (\(data.count / 1024) KB).")
            return url
        } catch {
            print("⚠️ GenerationMetricsStore: falha ao exportar métricas: \(error)")
            return nil
        }
    }
}
