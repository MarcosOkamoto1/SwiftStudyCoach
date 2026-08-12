//
//  PromptCacheBenchmark.swift
//  SwiftStudyCoach
//
//  PLAN_11 / SOLUTIONS_PLAN.md §7.4 — o benchmark que decide se o cache de
//  prefixo MLX FICA ou é REVERTIDO.
//
//  O plano é explícito quanto a isto: "Se o benchmark não confirmar ganho, o
//  resultado esperado é a REVERSÃO documentada, não a manutenção de uma
//  otimização sem efeito comprovado." Este arquivo existe para que essa
//  decisão seja tomada com número, não com intuição — inclusive porque a
//  hipótese concorrente (o gargalo real é decode, não prefill, já que o
//  contexto RAG de hoje é pequeno) é plausível.
//
//  PROTOCOLO
//  ─────────
//  Para cada tópico, as 3 chamadas MLX reais de um tópico, NA ORDEM em que a
//  app as faz (exemplo de código → quiz difícil → análise de código), duas
//  vezes:
//
//    Fase A — `isPromptCacheEnabled = false` (comportamento pré-PLAN_11)
//    Fase B — `isPromptCacheEnabled = true`  (cache de prefixo ligado)
//
//  E compara:
//    - TTFT da 2ª e 3ª chamada, A vs. B → é o ganho que o plano promete;
//    - TTFT da 1ª chamada, A vs. B → deve ficar ~igual (a 1ª chamada é o
//      MISS que paga o priming; se ela REGREDIR, o cache está cobrando caro
//      por algo que ainda não entregou);
//    - o texto gerado, A vs. B → o teste de equivalência de saída.
//
//  Roda com `temperature: 0` (ver `MLXService.temperatureOverride`): sem
//  isso, o amostrador sozinho já faria os textos divergirem e o teste de
//  equivalência não significaria nada.
//
//  Ferramenta de desenvolvimento, no mesmo espírito de `ModelBenchmarkSuite`:
//  não é chamada por nenhum caminho de produção, não persiste nada sozinha,
//  e o relatório é `Codable` para poder ser colado num PR.
//

import Foundation
import Observation

// MARK: - Modelo do relatório

/// Uma chamada MLX medida (uma das 3 de um tópico, numa das 2 fases).
struct PromptCacheCallMeasurement: Sendable, Codable {
    /// 0 = exemplo de código, 1 = quiz difícil, 2 = análise de código.
    let callIndex: Int
    let label: String
    let timeToFirstTokenMs: Double?
    let totalTimeMs: Double
    let promptTokenCount: Int?
    /// Tokens de prefixo que vieram do cache (0 na fase sem cache).
    let cachedPrefixTokenCount: Int?
    let cacheState: String
    let outputText: String
    let errorMessage: String?
}

/// Resultado das 3 chamadas de um tópico, nas duas fases.
struct PromptCacheTopicResult: Sendable, Codable {
    let topic: String
    let withoutCache: [PromptCacheCallMeasurement]
    let withCache: [PromptCacheCallMeasurement]

    /// Variação de TTFT por chamada, em % (negativo = ficou mais rápido com
    /// cache). `nil` onde faltar TTFT dos dois lados.
    var ttftDeltaPercent: [Double?] {
        zip(withoutCache, withCache).map { off, on in
            guard let base = off.timeToFirstTokenMs, let cached = on.timeToFirstTokenMs, base > 0 else { return nil }
            return (cached - base) / base * 100
        }
    }

    /// Teste de equivalência de saída, por chamada.
    ///
    /// Não exige igualdade byte a byte como veredito final: mesmo com
    /// `ArgMaxSampler`, reduções em GPU não são bit-exatas quando o mesmo
    /// resultado é computado por caminhos diferentes (que é exatamente o que
    /// o cache faz — o prefixo passa a vir de um prefill anterior). Um
    /// desempate por um logit muito próximo pode legitimamente trocar um
    /// token e, dali em diante, o texto diverge.
    ///
    /// Por isso o sinal reportado é ONDE os textos divergem: divergir no fim
    /// é ruído numérico esperado; divergir logo no começo é o cache montando
    /// um contexto errado — que é o caso de ROLLBACK descrito em §7.4.
    var outputAgreement: [PromptCacheOutputAgreement] {
        zip(withoutCache, withCache).map { off, on in
            PromptCacheOutputAgreement(without: off.outputText, with: on.outputText)
        }
    }
}

/// Quanto dois textos coincidem, e a partir de onde divergem.
struct PromptCacheOutputAgreement: Sendable, Codable {
    let identical: Bool
    /// Caracteres iniciais em comum.
    let commonPrefixChars: Int
    /// Fração do texto de referência coberta pelo prefixo comum (0...1).
    let commonPrefixRatio: Double
    let withoutChars: Int
    let withChars: Int

    init(without: String, with: String) {
        let a = Array(without)
        let b = Array(with)
        var index = 0
        while index < min(a.count, b.count), a[index] == b[index] { index += 1 }
        self.commonPrefixChars = index
        self.identical = without == with
        self.commonPrefixRatio = a.isEmpty ? 0 : Double(index) / Double(a.count)
        self.withoutChars = a.count
        self.withChars = b.count
    }

    /// Leitura pronta do veredito de §7.4 para esta chamada.
    var verdict: String {
        if identical { return "idêntico" }
        if commonPrefixRatio >= 0.9 { return "equivalente (diverge só no fim — provável ruído numérico)" }
        if commonPrefixRatio >= 0.5 { return "⚠️ diverge no meio — investigar" }
        return "❌ diverge cedo — critério de ROLLBACK (§7.4)"
    }
}

struct PromptCacheBenchmarkReport: Sendable, Codable {
    let modelID: String
    let generatedAt: Date
    let results: [PromptCacheTopicResult]

    /// Mediana da variação de TTFT das chamadas 2 e 3 (as que o cache deveria
    /// acelerar). A 1ª chamada fica de fora de propósito: ela é o MISS que
    /// paga o priming, não tem ganho a mostrar.
    var medianTTFTDeltaPercentForCachedCalls: Double? {
        let deltas = results
            .flatMap { $0.ttftDeltaPercent.enumerated().compactMap { $0.offset >= 1 ? $0.element : nil } }
            .compactMap { $0 }
            .sorted()
        guard !deltas.isEmpty else { return nil }
        return deltas[deltas.count / 2]
    }

    /// Veredito automático contra o SUCCESS CRITERIA de §7.4 (queda de TTFT
    /// > 10% nas chamadas 2ª/3ª, sem regressão de qualidade).
    ///
    /// Deliberadamente conservador: qualquer divergência precoce de saída
    /// derruba o veredito INDEPENDENTE do ganho de tempo. Um cache rápido e
    /// errado é pior que nenhum cache.
    var verdict: String {
        let earlyDivergence = results.flatMap(\.outputAgreement).contains { $0.commonPrefixRatio < 0.5 }
        if earlyDivergence {
            return "❌ ROLLBACK — pelo menos uma saída divergiu cedo demais; o ganho de tempo não importa se o contexto está errado."
        }
        guard let median = medianTTFTDeltaPercentForCachedCalls else {
            return "⚠️ INCONCLUSIVO — não houve TTFT suficiente para comparar (o modelo emitiu GenerateCompletionInfo?)."
        }
        if median <= -10 {
            return String(format: "✅ MANTER — TTFT das chamadas 2ª/3ª caiu %.1f%% (mediana), acima do corte de 10%% de §7.4.", -median)
        }
        if median < 0 {
            return String(format: "⚠️ INCONCLUSIVO — queda de só %.1f%% (mediana), abaixo do corte de 10%%. Provável confirmação da hipótese concorrente: o gargalo é decode, não prefill. §7.4 manda REVERTER neste caso.", -median)
        }
        return String(format: "❌ ROLLBACK — TTFT PIOROU %.1f%% (mediana) com o cache ligado.", median)
    }
}

// MARK: - Suíte

@Observable
@MainActor
final class PromptCacheBenchmark {

    private(set) var isRunning = false
    private(set) var progressLog: [String] = []
    private(set) var lastReport: PromptCacheBenchmarkReport?

    private let studyGenerator: StudyGenerator

    init(studyGenerator: StudyGenerator) {
        self.studyGenerator = studyGenerator
    }

    /// Uma das 3 chamadas MLX de um tópico, montada com o MESMO bloco de
    /// contexto compartilhado da produção (`StudyGenerator.mlxContextBlock`).
    ///
    /// Isso não é detalhe: se o benchmark montasse os prompts do seu próprio
    /// jeito, ele mediria o prefixo comum de prompts que não existem no app.
    private struct Call {
        let label: String
        let taskType: GenerationMetrics.TaskType
        let promptContext: String
        let topK: Int
    }

    private func calls(for topic: String) async -> [Call] {
        // Mesmos topK da produção: exemplo de código usa 2
        // (`TopicRepository.swift:261`), quiz e análise usam 3. A diferença é
        // proposital aqui — é justamente uma das coisas que o cache precisa
        // aguentar sem quebrar (o contexto de topK 2 é prefixo do de topK 3).
        let contextK2 = await studyGenerator.retrieveContext(for: topic, topK: 2)
        let contextK3 = await studyGenerator.retrieveContext(for: topic, topK: 3)

        return [
            Call(
                label: "exemplo de código",
                taskType: .codeExampleDraft,
                promptContext: """
                \(StudyGenerator.mlxContextBlock(topic: topic, context: contextK2))

                Escreva UM código Swift de 5-15 linhas, limpo e completo, que ilustre o conceito principal de '\(topic)', e explique-o passo a passo em texto puro.

                Formato exato da resposta (texto puro, sem markdown, sem JSON):
                CODIGO:
                <código>
                PASSO A PASSO:
                1. <trecho> — <explicação>
                """,
                topK: 2
            ),
            Call(
                label: "quiz difícil",
                taskType: .hardQuizDraft,
                promptContext: """
                \(StudyGenerator.mlxContextBlock(topic: topic, context: contextK3))

                Crie UMA pergunta técnica de nível avançado sobre '\(topic)'.

                Formato (texto puro, sem markdown):
                PERGUNTA: <a pergunta>
                RESPOSTA CORRETA: <explicação, 1-2 frases>
                """,
                topK: 3
            ),
            Call(
                label: "análise de código",
                taskType: .codeAnalysisDraft,
                promptContext: """
                \(StudyGenerator.mlxContextBlock(topic: topic, context: contextK3))

                Escreva UM trecho de código Swift limpo, de 6 a 10 linhas, sobre '\(topic)', e explique o comportamento dele.

                Formato (texto puro, sem markdown, sem JSON):
                CODIGO:
                <o trecho de código Swift>
                COMPORTAMENTO ESPERADO: <o que o código faz, 1-2 frases>
                """,
                topK: 3
            ),
        ]
    }

    /// Roda o protocolo completo. Nunca lança: falhas viram
    /// `errorMessage` na medição e a suíte segue.
    ///
    /// `topics` default = os tópicos do dataset atual (§7.4 pede "os 3
    /// tópicos do dataset atual").
    @discardableResult
    func run(topics: [String]? = nil) async -> PromptCacheBenchmarkReport {
        isRunning = true
        progressLog.removeAll()

        // Restaura a flag no fim aconteça o que acontecer — deixar o app com
        // o cache desligado por causa de um erro no meio do benchmark seria
        // um efeito colateral silencioso e difícil de perceber depois.
        let originalFlag = MLXService.isPromptCacheEnabled
        defer {
            MLXService.isPromptCacheEnabled = originalFlag
            isRunning = false
        }

        do {
            try await MLXService.shared.loadModel()
        } catch {
            log("❌ Falha ao carregar o modelo MLX: \(error.localizedDescription) — benchmark abortado.")
            let report = PromptCacheBenchmarkReport(modelID: MLXService.modelID, generatedAt: Date(), results: [])
            lastReport = report
            return report
        }

        // Mesma fonte de tópicos usada pela trilha da UI
        // (`StudyHomeView`/`StudyResultView`), não uma lista paralela que
        // poderia envelhecer em relação ao dataset.
        let targetTopics = topics ?? PlaceholderDocs.allTopics()
        guard !targetTopics.isEmpty else {
            log("❌ Nenhum tópico disponível no dataset — benchmark abortado.")
            let report = PromptCacheBenchmarkReport(modelID: MLXService.modelID, generatedAt: Date(), results: [])
            lastReport = report
            return report
        }

        log("🟢 Modelo pronto (\(MLXService.modelID)) — \(targetTopics.count) tópico(s) × 3 chamadas × 2 fases.")
        log("ℹ️ temperatura forçada em 0 (ArgMaxSampler) para o teste de equivalência fazer sentido.")

        var results: [PromptCacheTopicResult] = []

        for topic in targetTopics {
            log("▶️ tópico '\(topic)'")
            let topicCalls = await calls(for: topic)

            // ── Fase A: SEM cache ────────────────────────────────────────
            MLXService.isPromptCacheEnabled = false
            await MLXPromptCacheStore.shared.invalidate()
            log("   fase A — sem cache")
            var withoutCache: [PromptCacheCallMeasurement] = []
            for (index, call) in topicCalls.enumerated() {
                let measurement = await measure(call: call, index: index, topic: topic, useCache: false)
                withoutCache.append(measurement)
                logMeasurement(measurement)
            }

            // ── Fase B: COM cache ────────────────────────────────────────
            // `invalidate()` é essencial: sem ele a fase B começaria com o
            // cache da fase A e a 1ª chamada seria um HIT, escondendo
            // exatamente o custo de priming que queremos ver.
            MLXService.isPromptCacheEnabled = true
            await MLXPromptCacheStore.shared.invalidate()
            log("   fase B — com cache de prefixo")
            var withCache: [PromptCacheCallMeasurement] = []
            for (index, call) in topicCalls.enumerated() {
                let measurement = await measure(call: call, index: index, topic: topic, useCache: true)
                withCache.append(measurement)
                logMeasurement(measurement)
            }

            let result = PromptCacheTopicResult(topic: topic, withoutCache: withoutCache, withCache: withCache)
            results.append(result)

            for (index, delta) in result.ttftDeltaPercent.enumerated() {
                let deltaText = delta.map { String(format: "%+.1f%%", $0) } ?? "n/d"
                let agreement = result.outputAgreement[index]
                log("   Δ TTFT chamada \(index + 1) (\(topicCalls[index].label)): \(deltaText) · saída: \(agreement.verdict)")
            }
        }

        let report = PromptCacheBenchmarkReport(modelID: MLXService.modelID, generatedAt: Date(), results: results)
        lastReport = report
        log("🏁 \(report.verdict)")
        return report
    }

    private func measure(call: Call, index: Int, topic: String, useCache: Bool) async -> PromptCacheCallMeasurement {
        // Mesma técnica de correlação do `ModelBenchmarkSuite`: diff do
        // snapshot da store + filtro por taskType/timestamp, já que
        // `generateQuestionDraft` devolve só o texto.
        let before = await GenerationMetricsStore.shared.snapshot().count
        let callStart = Date()

        do {
            let output = try await MLXService.shared.generateQuestionDraft(
                systemPrompt: MLXService.draftSystemPrompt,
                promptContext: call.promptContext,
                topic: topic,
                taskType: call.taskType,
                cacheTopic: useCache ? topic : nil,
                temperatureOverride: 0
            )

            let after = await GenerationMetricsStore.shared.snapshot()
            let newEntries = after.count > before ? Array(after[before...]) : []
            let metric = newEntries
                .filter { $0.taskType == call.taskType && $0.timestamp >= callStart }
                .last ?? newEntries.last

            return PromptCacheCallMeasurement(
                callIndex: index,
                label: call.label,
                timeToFirstTokenMs: metric?.timeToFirstTokenMs,
                totalTimeMs: metric?.totalTimeMs ?? Date().timeIntervalSince(callStart) * 1000,
                promptTokenCount: metric?.inputTokenCount,
                cachedPrefixTokenCount: metric?.cachedPrefixTokenCount,
                cacheState: metric?.promptCacheState.rawValue ?? "desconhecido",
                outputText: output,
                errorMessage: nil
            )
        } catch {
            return PromptCacheCallMeasurement(
                callIndex: index,
                label: call.label,
                timeToFirstTokenMs: nil,
                totalTimeMs: Date().timeIntervalSince(callStart) * 1000,
                promptTokenCount: nil,
                cachedPrefixTokenCount: nil,
                cacheState: "erro",
                outputText: "",
                errorMessage: error.localizedDescription
            )
        }
    }

    private func logMeasurement(_ measurement: PromptCacheCallMeasurement) {
        if let error = measurement.errorMessage {
            log("      ⚠️ \(measurement.label): falhou — \(error)")
            return
        }
        let ttft = measurement.timeToFirstTokenMs.map { String(format: "%.0fms", $0) } ?? "n/d"
        let reused = measurement.cachedPrefixTokenCount.map { " · \($0) tokens do cache" } ?? ""
        log("      \(measurement.label): TTFT \(ttft) · prompt \(measurement.promptTokenCount.map(String.init) ?? "?") tokens · \(measurement.cacheState)\(reused)")
    }

    /// Exporta o relatório para `Documents/`, mesmo padrão de
    /// `GenerationMetricsStore.exportToDocuments`.
    @discardableResult
    func exportLastReport() -> URL? {
        guard let lastReport,
              let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(lastReport) else { return nil }

        let url = base.appendingPathComponent("prompt-cache-benchmark-\(Int(Date().timeIntervalSince1970)).json")
        do {
            try data.write(to: url, options: .atomic)
            print("🟢 PromptCacheBenchmark: relatório exportado para \(url.path)")
            return url
        } catch {
            print("⚠️ PromptCacheBenchmark: falha ao exportar relatório: \(error)")
            return nil
        }
    }

    private func log(_ line: String) {
        progressLog.append(line)
        print("🧪 [prompt cache] \(line)")
    }
}
