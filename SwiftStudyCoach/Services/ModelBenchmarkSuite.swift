//
//  ModelBenchmarkSuite.swift
//  SwiftStudyCoach
//
//  PLAN_05 — Ferramenta de avaliação de modelo MLX (SOLUTIONS_PLAN.md §9).
//  Runner + rubrica ponderada + veto duro + relatório exportável.
//
//  Puramente de ferramenta de desenvolvimento: NÃO é chamado por nenhum
//  caminho de produção (StudyGenerator, TopicRepository etc.) — só pela
//  UI de disparo isolada em TopicRepositoryTestView (ver seção "6) Model
//  Benchmark Suite" lá). Não altera MLXService.modelID nem nenhum arquivo
//  de produção; só CONSOME `MLXService.shared` e `StudyGenerator` como já
//  existem hoje.
//
//  Este plano NÃO decide trocar de modelo — isso é PLAN_14, que roda esta
//  MESMA suíte sob a topologia TARGET completa. Este arquivo só estabelece
//  a ferramenta + a baseline do 7B atual.
//

import Foundation
import Observation

// MARK: - Rubrica (§9.3)

/// Pontuação de UM prompt, preenchida por revisão humana do texto gerado
/// (ver PLAN_05: "API real" e "grounding" tipicamente precisam de revisão
/// humana — não são checáveis por regex de forma confiável). Os campos são
/// preenchidos DEPOIS que o runner já capturou o output bruto + as métricas
/// mecânicas (tokens/TTFT/tokens-por-segundo, via `GenerationMetrics`).
struct BenchmarkRubricScore: Codable, Equatable {
    /// Pesos exatos de SOLUTIONS_PLAN.md §9.3 — derivados da arquitetura
    /// TARGET (MLX em background). Ver nota no próprio §9.3: se a
    /// Estratégia D for revertida, os pesos de latência/memória devem subir
    /// e os de qualidade/grounding devem cair — não são universais.
    static let weights = (
        apiReal: 30,
        instructionFollowing: 25,
        grounding: 20,
        swiftCorrectness: 15,
        latency: 7,
        memory: 3
    )
    static let maxPossibleTotal = weights.apiReal + weights.instructionFollowing + weights.grounding
        + weights.swiftCorrectness + weights.latency + weights.memory // = 100

    /// API real (sem hallucination) — peso 30.
    var apiReal: Int
    /// Instruction following (formato/separador) — peso 25.
    var instructionFollowing: Int
    /// Grounding (adherence ao RAG, sem inventar além do contexto) — peso 20.
    var grounding: Int
    /// Correção Swift (compilaria) — peso 15.
    var swiftCorrectness: Int
    /// Latência (TTFT + tokens/s) — peso 7.
    var latency: Int
    /// Memória — peso 3.
    var memory: Int
    /// Marcado pelo revisor humano quando a resposta contém ≥1 API
    /// inventada. Só é relevante para o veto duro de §9.4 quando o prompt
    /// pertence à faixa 4-7 (ver `BenchmarkPromptSpec.isHardVetoPrompt` e
    /// `BenchmarkModelReport.hasHardVeto`).
    var hasInventedAPI: Bool = false

    init(apiReal: Int = 0, instructionFollowing: Int = 0, grounding: Int = 0, swiftCorrectness: Int = 0, latency: Int = 0, memory: Int = 0, hasInventedAPI: Bool = false) {
        self.apiReal = apiReal
        self.instructionFollowing = instructionFollowing
        self.grounding = grounding
        self.swiftCorrectness = swiftCorrectness
        self.latency = latency
        self.memory = memory
        self.hasInventedAPI = hasInventedAPI
    }

    private func clamp(_ value: Int, max upper: Int) -> Int { min(max(value, 0), upper) }

    /// Soma ponderada — cada campo é clampado ao próprio peso máximo antes
    /// de somar (defesa contra entrada inválida vinda da UI de revisão).
    var weightedTotal: Int {
        clamp(apiReal, max: Self.weights.apiReal)
            + clamp(instructionFollowing, max: Self.weights.instructionFollowing)
            + clamp(grounding, max: Self.weights.grounding)
            + clamp(swiftCorrectness, max: Self.weights.swiftCorrectness)
            + clamp(latency, max: Self.weights.latency)
            + clamp(memory, max: Self.weights.memory)
    }
}

// MARK: - Resultado por prompt

struct BenchmarkPromptResult: Identifiable, Codable {
    var id: Int { promptID }

    let promptID: Int
    let category: String
    let summary: String
    let ragTopic: String?
    let ragContextChars: Int
    let rawOutput: String
    /// Não-nil se a chamada ao MLX falhou para este prompt — a suíte NÃO
    /// aborta os demais prompts por causa de uma falha pontual (mesmo
    /// padrão defensivo usado em `StudyGenerator.formatHardQuestion`/
    /// `formatCodeAnalysisQuestion`, que nunca lançam, só degradam).
    let errorMessage: String?
    /// Métricas mecânicas reais (tokens, TTFT, tokens/s, tempo total) —
    /// via `GenerationMetrics`/`PLAN_00`, correlacionadas por diff do
    /// snapshot da `GenerationMetricsStore` antes/depois desta chamada.
    let metrics: GenerationMetrics?
    /// Pontuação da rubrica — `nil` até um revisor humano avaliar o
    /// `rawOutput` (ver `ModelBenchmarkSuite.setRubric`).
    var rubric: BenchmarkRubricScore?

    /// true para os prompts 4-7 (identificação de API inexistente / bug
    /// semântico) — os que alimentam o veto duro de §9.4.
    var isHardVetoPrompt: Bool { (4...7).contains(promptID) }
}

// MARK: - Relatório de UM modelo

struct BenchmarkModelReport: Codable {
    let modelID: String
    let generatedAt: Date
    var results: [BenchmarkPromptResult]

    var promptsExecuted: Int { results.filter { $0.errorMessage == nil }.count }
    var promptsFailed: Int { results.filter { $0.errorMessage != nil }.count }

    /// Só conta prompts já pontuados manualmente — a rubrica exige revisão
    /// humana (ver PLAN_05), então o score total só fica definitivo depois
    /// dessa etapa.
    var scoredPromptsCount: Int { results.filter { $0.rubric != nil }.count }
    var totalScore: Int { results.compactMap { $0.rubric?.weightedTotal }.reduce(0, +) }
    var maxPossibleScore: Int { scoredPromptsCount * BenchmarkRubricScore.maxPossibleTotal }
    var isFullyScored: Bool { scoredPromptsCount == results.count && !results.isEmpty }

    /// Veto duro (§9.4): true se QUALQUER prompt 4-7 foi marcado pelo
    /// revisor com `hasInventedAPI == true`. Independe do score total —
    /// aplicado na hora de RANQUEAR relatórios de vários modelos (ver
    /// `BenchmarkRanking.rank`), não altera `totalScore` em si.
    var hasHardVeto: Bool {
        results.contains { $0.isHardVetoPrompt && ($0.rubric?.hasInventedAPI == true) }
    }
}

// MARK: - Ranking entre modelos (§9.4)

/// Compara relatórios de modelos DIFERENTES (ex.: 7B vs. 14B, em PLAN_14).
/// Não decide nada sozinho — só implementa a regra determinística de §9.4
/// para que a decisão não dependa de julgamento ad-hoc.
enum BenchmarkRanking {

    /// Ordena do melhor pro pior: 1º critério é o veto duro (qualquer
    /// relatório com `hasHardVeto == true` fica DEPOIS de qualquer
    /// relatório sem veto, não importa o score); 2º critério (desempate,
    /// ou quando nenhum/ambos têm veto) é `totalScore` ponderado,
    /// decrescente. Nunca ordena só por tokens/s — essa é a regra
    /// explícita de §9.4 ("não escolher só por tokens/s").
    static func rank(_ reports: [BenchmarkModelReport]) -> [BenchmarkModelReport] {
        reports.sorted { a, b in
            if a.hasHardVeto != b.hasHardVeto {
                return !a.hasHardVeto // sem veto sempre vem antes de com veto
            }
            return a.totalScore > b.totalScore
        }
    }

    /// O vencedor, ou `nil` se `reports` estiver vazio. Conveniência sobre
    /// `rank(_:)`.
    static func winner(among reports: [BenchmarkModelReport]) -> BenchmarkModelReport? {
        rank(reports).first
    }
}

// MARK: - Runner

/// Executa os 18 prompts de `BenchmarkPrompts.all` contra o modelo MLX
/// atualmente configurado em `MLXService.modelID` (este plano não introduz
/// troca de modelo em runtime — ver "O que NÃO alterar" do PLAN_05; para
/// testar outro `modelID`, troque a constante em `MLXService.swift`
/// manualmente, rode a suíte, e reverta — é exatamente o que PLAN_14 faz
/// sob a topologia TARGET).
@Observable
final class ModelBenchmarkSuite {

    private let studyGenerator: StudyGenerator

    private(set) var isRunning = false
    private(set) var progressLog: [String] = []
    private(set) var lastReport: BenchmarkModelReport?

    init(studyGenerator: StudyGenerator) {
        self.studyGenerator = studyGenerator
    }

    /// Roda os 18 prompts em sequência (não em paralelo — o
    /// `GenerationOrchestrator` já serializa MLX de qualquer forma, e rodar
    /// em sequência aqui deixa o log de progresso legível). Nunca lança:
    /// falhas por prompt ficam registradas em `BenchmarkPromptResult.errorMessage`
    /// e a suíte segue para o próximo prompt.
    @discardableResult
    func run() async -> BenchmarkModelReport {
        isRunning = true
        progressLog.removeAll()
        defer { isRunning = false }

        do {
            try await MLXService.shared.loadModel()
        } catch {
            log("❌ Falha ao carregar o modelo MLX (\(MLXService.modelID)): \(error.localizedDescription) — suíte abortada antes do 1º prompt.")
            let report = BenchmarkModelReport(modelID: MLXService.modelID, generatedAt: Date(), results: [])
            lastReport = report
            return report
        }

        log("🟢 Modelo pronto (\(MLXService.modelID)) — rodando \(BenchmarkPrompts.all.count) prompts.")

        var results: [BenchmarkPromptResult] = []
        for spec in BenchmarkPrompts.all {
            log("▶️ #\(spec.id) [\(spec.category.rawValue)] \(spec.summary)")
            let result = await runOne(spec)
            results.append(result)

            if let metric = result.metrics {
                let tokSummary = metric.tokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "sem tok/s"
                let ttft = metric.timeToFirstTokenMs.map { String(format: "%.0fms TTFT", $0) } ?? "sem TTFT"
                log("   ✅ \(String(format: "%.0fms total", metric.totalTimeMs)) · \(ttft) · \(tokSummary) · in=\(metric.inputTokenCount.map(String.init) ?? "?") out=\(metric.outputTokenCount.map(String.init) ?? "?")")
            } else if let error = result.errorMessage {
                log("   ⚠️ falhou: \(error)")
            } else {
                log("   ⚠️ concluiu sem GenerateCompletionInfo (sem métricas de tokens).")
            }
        }

        let report = BenchmarkModelReport(modelID: MLXService.modelID, generatedAt: Date(), results: results)
        lastReport = report
        log("🏁 Suíte concluída — \(report.promptsExecuted)/\(BenchmarkPrompts.all.count) prompts com sucesso, \(report.promptsFailed) falharam.")
        return report
    }

    private func runOne(_ spec: BenchmarkPromptSpec) async -> BenchmarkPromptResult {
        let context: String
        if let topic = spec.ragTopic {
            context = await studyGenerator.retrieveContext(for: topic, topK: spec.ragTopK)
        } else {
            context = ""
        }
        let prompt = spec.buildPrompt(context)

        // Diff do snapshot da GenerationMetricsStore antes/depois — é assim
        // que correlacionamos a métrica real (PLAN_00) gerada DENTRO de
        // `MLXService.generate` com este prompt específico, já que
        // `generateQuestionDraft`/`generateQuestionDrafts` não devolvem a
        // métrica pro chamador (só o texto). Guardamos o timestamp de
        // início também: se outra parte do app (ex.: crescimento de pool
        // em background do TopicRepository, se a tela de teste estiver com
        // um tópico aberto) registrar uma métrica MLX intercalada durante a
        // suíte, o índice puro `before`/`after` poderia apontar pra métrica
        // errada — o filtro por `taskType` + `timestamp >= callStart`
        // abaixo resolve isso na prática (dev tool: não precisa ser
        // 100% à prova de concorrência arbitrária, só robusto ao caso
        // comum de crescimento de pool em background).
        let before = await GenerationMetricsStore.shared.snapshot().count
        let callStart = Date()

        do {
            let rawOutput: String
            if spec.batchCount > 1 {
                let items = try await MLXService.shared.generateQuestionDrafts(
                    systemPrompt: spec.systemPrompt,
                    promptContext: prompt,
                    count: spec.batchCount,
                    topic: spec.ragTopic ?? "benchmark",
                    taskType: spec.taskType
                )
                rawOutput = items.enumerated()
                    .map { "[item \($0.offset + 1)/\(spec.batchCount)]\n\($0.element)" }
                    .joined(separator: "\n\n\(BenchmarkPrompts.itemSeparator)\n\n")
            } else {
                rawOutput = try await MLXService.shared.generateQuestionDraft(
                    systemPrompt: spec.systemPrompt,
                    promptContext: prompt,
                    topic: spec.ragTopic ?? "benchmark",
                    taskType: spec.taskType
                )
            }

            let after = await GenerationMetricsStore.shared.snapshot()
            let newEntries = after.count > before ? Array(after[before...]) : []
            // Preferência: entrada nova com o MESMO taskType desta chamada,
            // registrada depois do início da chamada — a mais recente,
            // se houver mais de uma (caso raro de 2 chamadas MLX do mesmo
            // taskType intercaladas). Fallback: qualquer entrada nova
            // (garante que ainda capturamos algo mesmo se o taskType não
            // bater por algum motivo inesperado).
            let metric: GenerationMetrics? = newEntries
                .filter { $0.taskType == spec.taskType && $0.timestamp >= callStart }
                .last ?? newEntries.last

            return BenchmarkPromptResult(
                promptID: spec.id,
                category: spec.category.rawValue,
                summary: spec.summary,
                ragTopic: spec.ragTopic,
                ragContextChars: context.count,
                rawOutput: rawOutput,
                errorMessage: nil,
                metrics: metric,
                rubric: nil
            )
        } catch {
            return BenchmarkPromptResult(
                promptID: spec.id,
                category: spec.category.rawValue,
                summary: spec.summary,
                ragTopic: spec.ragTopic,
                ragContextChars: context.count,
                rawOutput: "",
                errorMessage: error.localizedDescription,
                metrics: nil,
                rubric: nil
            )
        }
    }

    private func log(_ line: String) {
        progressLog.append(line)
        print("🧪 [Benchmark] \(line)")
    }

    // MARK: - Rubrica manual (preenchida via UI, depois de ler o rawOutput)

    func setRubric(_ rubric: BenchmarkRubricScore, forPromptID id: Int) {
        guard var report = lastReport, let idx = report.results.firstIndex(where: { $0.promptID == id }) else { return }
        report.results[idx].rubric = rubric
        lastReport = report
    }

    // MARK: - Exportação (reaproveita o padrão de GenerationMetricsStore.exportToDocuments)

    @discardableResult
    func exportReportToDocuments() -> URL? {
        guard let report = lastReport else {
            print("⚠️ ModelBenchmarkSuite: nenhum relatório pra exportar — rode a suíte primeiro.")
            return nil
        }
        guard let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = base.appendingPathComponent("benchmark-report-\(report.modelID.split(separator: "/").last ?? "model")-\(Int(Date().timeIntervalSince1970)).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(report)
            try data.write(to: url, options: .atomic)
            print("🟢 ModelBenchmarkSuite: relatório exportado para \(url.path) (\(data.count / 1024) KB).")
            return url
        } catch {
            print("⚠️ ModelBenchmarkSuite: falha ao exportar relatório: \(error)")
            return nil
        }
    }
}
