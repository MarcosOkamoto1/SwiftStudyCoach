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

    /// hit/miss/notApplicable.
    ///
    /// PLAN_11 preencheu isto para chamadas MLX de geração, que era o campo
    /// deixado reservado aqui pelo PLAN_00:
    ///   - `hit`    — havia um cache de prefixo primed para este tópico e
    ///                pelo menos 1 token foi reaproveitado dele;
    ///   - `miss`   — o cache estava ligado, mas este tópico ainda não
    ///                estava primed (é a chamada que PAGA o priming), ou o
    ///                prefixo comum deu zero;
    ///   - `notApplicable` — cache desligado
    ///                (`MLXService.isPromptCacheEnabled == false`), chamada
    ///                sem chave de cache, ou motor Foundation Models.
    ///
    /// `DocumentIndex.buildIndex` continua usando hit/miss com o outro
    /// sentido (cache de embeddings em disco) — são escopos diferentes,
    /// distinguíveis pelo `taskType`.
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
    /// PLAN_11 — quantos tokens de prefixo vieram do cache primed (0 num
    /// `miss`, `nil` quando o cache não se aplica).
    ///
    /// Precisa existir separado de `inputTokenCount` para o benchmark ser
    /// honesto: num `hit`, o `GenerateCompletionInfo.promptTokenCount`
    /// devolvido pela lib conta só os tokens do SUFIXO que de fato passaram
    /// pelo `TokenIterator` — o prefixo reaproveitado não aparece lá. Sem
    /// este campo, um `hit` pareceria uma queda mágica de tokens de entrada,
    /// e `inputTokenCount + cachedPrefixTokenCount` é que dá o tamanho real
    /// do prompt, comparável com o da execução sem cache.
    let cachedPrefixTokenCount: Int?
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
        cachedPrefixTokenCount: Int? = nil,
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
        self.cachedPrefixTokenCount = cachedPrefixTokenCount
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

/// PLAN_07 — contagem, por sessão, do que o upgrade de exemplo de código em
/// background efetivamente PRODUZIU.
///
/// Existe para responder a evidência que `SOLUTIONS_PLAN.md` §5.2 lista como
/// pendente para avaliar a própria Estratégia D:
///   1. "com que frequência o upgrade muda alguma coisa?" — se for
///      baixíssima, o valor marginal de rodar a crítica para 100% dos
///      tópicos cai (poderia virar amostragem); se for alta, confirma que
///      ela precisa continuar rodando sempre, só não bloqueando;
///   2. "quanto tempo passa entre a tela aparecer (fim da Fase 1) e o patch
///      chegar?" — se for longo demais, o usuário fecha o tópico antes de
///      ver a melhoria (ainda vale persistir: a próxima visita já vem
///      corrigida pelo cache HIT).
///
/// Deliberadamente FORA do struct `GenerationMetrics`: não é a medição de
/// UMA chamada a um motor (que é o que aquele struct modela), é o desfecho
/// de um pipeline inteiro. O plano permite explicitamente "um contador à
/// parte" quando for mais simples. Mesmo hábito de log com emoji do resto
/// do projeto (§9.3), e igualmente descartado ao fim da sessão.
actor CodeExampleUpgradeStats {

    static let shared = CodeExampleUpgradeStats()

    enum Outcome: String, Sendable, CaseIterable {
        /// O upgrade rodou, era válido e DIFERENTE do FM-only — patch aplicado.
        case changed
        /// O upgrade rodou e era válido, mas idêntico ao FM-only — nenhum
        /// `UPDATE` feito. É o caso "o FM sozinho já estava certo".
        case unchanged
        /// O upgrade rodou mas o resultado era estruturalmente inválido
        /// (truncado/vazio) — descartado, Fase 1 preservada.
        case discardedInvalid
        /// O pipeline não chegou a produzir candidato (MLX indisponível,
        /// erro de rede/geração, download do modelo falhou).
        case notProduced
        /// O candidato era válido, mas não foi possível persistir: o `save()`
        /// do `ModelContext` de background falhou, ou o `StudyTopic` alvo já
        /// não existia mais. Separado de `discardedInvalid` de propósito:
        /// aqui o conteúdo estava bom e o problema é de persistência — se
        /// aparecer, o lugar de investigar é o SwiftData, não os prompts.
        case saveFailed
    }

    private(set) var counts: [Outcome: Int] = [:]
    /// Latência tela→patch, só dos casos em que o patch de fato foi aplicado
    /// (nos outros o número não significa nada — não houve patch).
    private(set) var patchLatenciesMs: [Double] = []

    private init() {}

    func record(_ outcome: Outcome, topic: String, msSincePhase1: Double) {
        counts[outcome, default: 0] += 1
        if outcome == .changed {
            patchLatenciesMs.append(msSincePhase1)
        }
        let total = counts.values.reduce(0, +)
        print("📈 [upgrade do exemplo] '\(topic)' → \(outcome.rawValue) em \(String(format: "%.1f", msSincePhase1 / 1000))s após a tela aparecer · \(counts[.changed] ?? 0)/\(total) mudaram algo até agora.")
    }

    /// Fração de upgrades que mudaram o conteúdo, sobre todos os que
    /// CHEGARAM A PRODUZIR um candidato válido (`changed` + `unchanged`) —
    /// falha de pipeline e resultado inválido não dizem nada sobre "o FM
    /// sozinho estava certo?", então ficam fora do denominador.
    func changeRate() -> Double? {
        let changed = counts[.changed] ?? 0
        let comparable = changed + (counts[.unchanged] ?? 0)
        guard comparable > 0 else { return nil }
        return Double(changed) / Double(comparable)
    }

    /// Latência mediana tela→patch, em segundos. `nil` enquanto nenhum patch
    /// tiver sido aplicado nesta sessão.
    func medianPatchLatencySeconds() -> Double? {
        guard !patchLatenciesMs.isEmpty else { return nil }
        let sorted = patchLatenciesMs.sorted()
        return sorted[sorted.count / 2] / 1000
    }

    func summaryLine() -> String {
        let parts = Outcome.allCases.map { "\($0.rawValue)=\(counts[$0] ?? 0)" }.joined(separator: " · ")
        let rate = changeRate().map { String(format: "%.0f%%", $0 * 100) } ?? "n/d"
        let latency = medianPatchLatencySeconds().map { String(format: "%.1fs", $0) } ?? "n/d"
        return "upgrade do exemplo de código — \(parts) · mudou algo em \(rate) dos candidatos válidos · mediana tela→patch \(latency)"
    }
}

/// PLAN_10 — latência percebida do novo gatilho "sob demanda" do pool de
/// análise de código (`TopicRepository.ensureCodeAnalysisPool`): tempo entre
/// o usuário tocar o botão de "Análise de código" pela 1ª vez e o pool ficar
/// disponível. É o dado que informa se vale a pena a espera (§14.2 — decisão
/// de produto com recomendação técnica dada, não puramente técnica).
///
/// Mesmo padrão de `CodeExampleUpgradeStats`: contador à parte, puramente de
/// profiling, descartado ao fim da sessão.
actor CodeAnalysisOnDemandStats {

    static let shared = CodeAnalysisOnDemandStats()

    private(set) var latenciesMs: [Double] = []

    private init() {}

    func record(topic: String, latencyMs: Double) {
        latenciesMs.append(latencyMs)
        print("📈 [análise de código sob demanda] '\(topic)' → pool disponível \(String(format: "%.1f", latencyMs / 1000))s após o toque no botão.")
    }

    func medianLatencySeconds() -> Double? {
        guard !latenciesMs.isEmpty else { return nil }
        let sorted = latenciesMs.sorted()
        return sorted[sorted.count / 2] / 1000
    }

    func summaryLine() -> String {
        let median = medianLatencySeconds().map { String(format: "%.1fs", $0) } ?? "n/d"
        return "análise de código sob demanda — \(latenciesMs.count) geração(ões) · mediana toque→pool disponível \(median)"
    }
}
