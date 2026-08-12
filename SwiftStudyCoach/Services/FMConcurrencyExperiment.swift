//
//  FMConcurrencyExperiment.swift
//  SwiftStudyCoach
//
//  PLAN_13 Parte 1 — experimento de concorrência do Foundation Models
//  (SOLUTIONS_PLAN.md §15.4, desenho "descrito, NÃO implementado" — este
//  arquivo é a implementação do EXPERIMENTO, não de concorrência em
//  produção).
//
//  Pergunta que responde: o Foundation Models aceita ≥2 sessões
//  `LanguageModelSession` concorrentes sem erro? E, se aceita, o tempo
//  total melhora o suficiente sobre a execução serial para justificar
//  elevar a profundidade da fila `.poolFill` do `GenerationOrchestrator`
//  além de 1?
//
//  IMPORTANTE — o que este arquivo NÃO faz:
//  - NÃO passa pelo `GenerationOrchestrator` (as chamadas são `Task`
//    paralelas diretas, de propósito: o objetivo é justamente provocar a
//    concorrência que a fila de produção previne por design).
//  - NÃO altera o `GenerationOrchestrator` nem nenhum caminho de produção.
//    Mesmo que o resultado seja favorável, elevar a fila `.poolFill` para
//    profundidade 2 vira um PLANO FUTURO SEPARADO (ver PLAN_13, "O que NÃO
//    alterar") — nunca é implementado junto deste harness.
//  - NÃO grava nada na `GenerationMetricsStore`: as chamadas do experimento
//    não são geração de produto (não têm um `taskType` honesto) e
//    poluiriam o `summary()` da store. O harness mantém os próprios
//    registros e exporta o próprio JSON, no mesmo padrão de
//    `GPUCacheLimitSweep`/`ModelBenchmarkSuite`.
//
//  Puramente ferramenta de desenvolvimento: só é instanciado pela
//  `TopicRepositoryTestView` (tela de debug), nunca por caminho de produção.
//

import Foundation
import Observation
import FoundationModels

// MARK: - Resultado de UMA rodada (serial + concorrente para o mesmo N)

struct FMConcurrencyRound: Codable {
    /// Ordem de execução desta rodada — alternada entre rodadas para o
    /// aquecimento térmico/de cache não beneficiar sistematicamente a
    /// variante que roda por segundo.
    let concurrentRanFirst: Bool
    /// Tempo total das N chamadas em SÉRIE (baseline atual de produção:
    /// é o que a fila serial do orchestrator faz hoje).
    let serialTotalMs: Double
    /// Tempo até TODAS as N chamadas concorrentes completarem.
    let concurrentTotalMs: Double
    /// Erros `concurrentRequests` + `rateLimited` nas chamadas CONCORRENTES
    /// desta rodada — é a taxa que o critério de decisão do §15.4 usa.
    let concurrencyErrorCount: Int
    /// Qualquer outro erro nas chamadas concorrentes (guardrail, decoding,
    /// contexto etc.) — não conta como "erro de concorrência", mas fica
    /// registrado para leitura honesta do relatório.
    let otherErrorCount: Int
    /// Erros nas chamadas SERIAIS (baseline) — esperado ~0; se aparecer,
    /// a rodada inteira é suspeita (problema ambiente, não concorrência).
    let serialErrorCount: Int
}

// MARK: - Agregado por N

struct FMConcurrencyVariantResult: Codable, Identifiable {
    var id: Int { n }

    let n: Int
    let rounds: [FMConcurrencyRound]

    var totalConcurrentCalls: Int { rounds.count * n }

    /// Taxa de erro de concorrência (concurrentRequests + rateLimited)
    /// sobre todas as chamadas concorrentes desta variante — o número do
    /// primeiro critério de decisão do §15.4.
    var concurrencyErrorRate: Double {
        guard totalConcurrentCalls > 0 else { return 0 }
        let errors = rounds.reduce(0) { $0 + $1.concurrencyErrorCount }
        return Double(errors) / Double(totalConcurrentCalls)
    }

    var otherErrorCount: Int { rounds.reduce(0) { $0 + $1.otherErrorCount } }
    var serialErrorCount: Int { rounds.reduce(0) { $0 + $1.serialErrorCount } }

    var medianSerialMs: Double? { Self.median(rounds.map(\.serialTotalMs)) }
    var medianConcurrentMs: Double? { Self.median(rounds.map(\.concurrentTotalMs)) }

    /// Ganho mediano serial/concorrente (>1 = concorrente foi mais rápido).
    /// Mediana das razões POR RODADA (não razão das medianas): rodadas são
    /// pareadas de propósito (mesmas condições térmicas/de carga), e a
    /// razão pareada é mais robusta a deriva ao longo do experimento.
    var medianSpeedup: Double? {
        Self.median(rounds.compactMap { round in
            round.concurrentTotalMs > 0 ? round.serialTotalMs / round.concurrentTotalMs : nil
        })
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    var summaryLine: String {
        let errorPct = String(format: "%.1f%%", concurrencyErrorRate * 100)
        let serial = medianSerialMs.map { String(format: "%.1fs", $0 / 1000) } ?? "n/d"
        let concurrent = medianConcurrentMs.map { String(format: "%.1fs", $0 / 1000) } ?? "n/d"
        let speedup = medianSpeedup.map { String(format: "%.2fx", $0) } ?? "n/d"
        return "N=\(n): erro concorrência \(errorPct) (\(totalConcurrentCalls) chamadas) · serial \(serial) vs concorrente \(concurrent) (mediana) · speedup \(speedup) · outros erros \(otherErrorCount)"
    }
}

// MARK: - Relatório

struct FMConcurrencyReport: Codable {
    let generatedAt: Date
    let roundsPerVariant: Int
    let variants: [FMConcurrencyVariantResult]

    /// Aplica MECANICAMENTE o critério de decisão do §15.4 sobre N=2 (é o N
    /// que decide — N=3/4 são contexto). Os limiares numéricos são
    /// interpretações documentadas dos termos do plano: ">5%" é literal do
    /// plano; "~0%" lido como ≤1%; "proporcional (não apenas marginal)"
    /// lido como speedup mediano ≥1.5x para N=2 (metade do teto teórico de
    /// 2x). A decisão FINAL é humana e vai registrada em
    /// plans/PLAN_13_DECISION.md — isto é só a leitura sugerida do dado.
    var recommendation: String {
        guard let n2 = variants.first(where: { $0.n == 2 }), !n2.rounds.isEmpty else {
            return "Sem dados para N=2 — rode o experimento antes de decidir."
        }
        let errorRate = n2.concurrencyErrorRate
        let speedup = n2.medianSpeedup ?? 0

        if errorRate > 0.05 {
            return "NÃO implementar concorrência FM>1 (critério 1 do §15.4): taxa de erro de concorrência para N=2 foi \(String(format: "%.1f%%", errorRate * 100)) (>5%). Manter a fila serial e encerrar aqui."
        }
        if errorRate <= 0.01 && speedup >= 1.5 {
            return "Dado FAVORÁVEL (critério 2 do §15.4): erro ~0% e speedup \(String(format: "%.2fx", speedup)) para N=2. Registrar como PLANO FUTURO separado a elevação da fila .poolFill para profundidade 2 — NÃO implementar neste plano."
        }
        if speedup >= 1.15 {
            return "Resultado MISTO (critério 3 do §15.4): speedup \(String(format: "%.2fx", speedup)) com taxa de erro não-trivial (\(String(format: "%.1f%%", errorRate * 100))). Profundidade 2 + retry automático só vale se o ganho for grande — este ganho provavelmente não justifica a complexidade."
        }
        return "NÃO implementar: ganho marginal (speedup \(String(format: "%.2fx", speedup)) para N=2) — mesmo sem erros, não é a melhora 'proporcional' que o §15.4 exige. Manter serial."
    }
}

// MARK: - Runner

/// Dispara N `LanguageModelSession(...).respond(to:...)` simultâneas (Task
/// paralelas, SEM passar pela fila) para N = 2, 3, 4, e compara com as
/// mesmas N chamadas em série. `rounds` rodadas por N (≥10 recomendado pelo
/// plano — comportamento sob carga é não-determinístico).
@Observable
final class FMConcurrencyExperiment {

    static let variantNs = [2, 3, 4]
    static let defaultRounds = 10

    private(set) var isRunning = false
    private(set) var progressLog: [String] = []
    private(set) var lastReport: FMConcurrencyReport?

    /// Prompts realistas e DISTINTOS entre as N chamadas de uma rodada
    /// (chamadas idênticas em paralelo seriam um caso irrealisticamente
    /// favorável a qualquer cache interno do sistema). Os 3 primeiros usam
    /// os tópicos reais do dataset com o contexto RAG real
    /// (`DocumentIndex.rawChunks(forExactTopic:)`, síncrono, sem depender
    /// de `ensureReady`); o 4º simula o fallback sem contexto — os dois
    /// formatos que `generateSummary` produz em produção.
    private static let experimentTopics = ["NavigationStack", "Property Wrappers", "async/await", "Closures em Swift"]

    /// Mesmas instructions do `generateSummary` de produção — o experimento
    /// deve medir a carga real, não um prompt de brinquedo (mesmo princípio
    /// do §12.3 contra warm-up com prompt "fake").
    ///
    /// `nonisolated`: o projeto usa `SWIFT_DEFAULT_ACTOR_ISOLATION =
    /// MainActor` (ver comentários em MLXService), e esta constante é lida
    /// por `singleCall`, que roda em child tasks FORA do MainActor.
    private nonisolated static let instructions = """
    Você é um assistente educacional especializado em Swift e nos frameworks da Apple.
    Responda sempre em português.
    Baseie-se PRINCIPALMENTE no contexto de documentação fornecido abaixo.
    Se o contexto não cobrir algum detalhe, seja conservador e não invente
    nomes de métodos, parâmetros ou comportamentos que não estão no contexto.
    """

    private static func prompt(forCallIndex index: Int) -> String {
        let topic = experimentTopics[index % experimentTopics.count]
        let context = DocumentIndex.rawChunks(forExactTopic: topic)
            .map(\.text)
            .joined(separator: "\n\n")

        if context.isEmpty {
            return """
            Tópico: \(topic)

            Gere um resumo estruturado desse tópico de Swift para um desenvolvedor
            iniciante/intermediário, incluindo pontos-chave.
            """
        }
        return """
        Tópico: \(topic)

        Contexto da documentação oficial (use isso como base principal):
        \(context)

        Gere um resumo estruturado desse tópico de Swift para um desenvolvedor
        iniciante/intermediário, incluindo pontos-chave.
        """
    }

    // MARK: - Execução

    @discardableResult
    func run(rounds: Int = FMConcurrencyExperiment.defaultRounds) async -> FMConcurrencyReport? {
        guard case .available = SystemLanguageModel.default.availability else {
            log("❌ Foundation Models indisponível neste device — experimento abortado.")
            return nil
        }

        isRunning = true
        progressLog.removeAll()
        defer { isRunning = false }

        log("▶️ Experimento §15.4 — N=\(Self.variantNs.map(String.init).joined(separator: ",")) · \(rounds) rodadas por N. Total ≈ \(Self.variantNs.reduce(0) { $0 + 2 * $1 * rounds }) chamadas FM — pode levar bastante tempo.")

        var variants: [FMConcurrencyVariantResult] = []
        for n in Self.variantNs {
            variants.append(await runVariant(n: n, rounds: rounds))
        }

        let report = FMConcurrencyReport(generatedAt: Date(), roundsPerVariant: rounds, variants: variants)
        lastReport = report
        log("🏁 Concluído. \(report.recommendation)")
        return report
    }

    private func runVariant(n: Int, rounds: Int) async -> FMConcurrencyVariantResult {
        log("── N=\(n) ──")
        var results: [FMConcurrencyRound] = []

        for round in 0..<rounds {
            // Alterna a ordem serial/concorrente entre rodadas — sem isso, a
            // variante que roda sempre por segundo herdaria sistematicamente
            // caches/térmica da primeira.
            let concurrentFirst = round % 2 == 1

            let serial: (totalMs: Double, errors: Int, concurrencyErrors: Int)
            let concurrent: (totalMs: Double, errors: Int, concurrencyErrors: Int)

            if concurrentFirst {
                concurrent = await runConcurrent(n: n)
                serial = await runSerial(n: n)
            } else {
                serial = await runSerial(n: n)
                concurrent = await runConcurrent(n: n)
            }

            let roundResult = FMConcurrencyRound(
                concurrentRanFirst: concurrentFirst,
                serialTotalMs: serial.totalMs,
                concurrentTotalMs: concurrent.totalMs,
                concurrencyErrorCount: concurrent.concurrencyErrors,
                otherErrorCount: concurrent.errors,
                serialErrorCount: serial.errors + serial.concurrencyErrors
            )
            results.append(roundResult)

            log("  rodada \(round + 1)/\(rounds): serial \(String(format: "%.1fs", serial.totalMs / 1000)) · concorrente \(String(format: "%.1fs", concurrent.totalMs / 1000)) · erros concorrência \(concurrent.concurrencyErrors)/\(n)")
        }

        let variant = FMConcurrencyVariantResult(n: n, rounds: results)
        log("  \(variant.summaryLine)")
        return variant
    }

    /// N chamadas em SEQUÊNCIA (baseline: é o comportamento da fila serial
    /// de produção, sem o overhead do orchestrator em si — que é
    /// desprezível perto de segundos de geração).
    private func runSerial(n: Int) async -> (totalMs: Double, errors: Int, concurrencyErrors: Int) {
        // Prompts montados AQUI (no MainActor, onde `prompt(forCallIndex:)`
        // e `DocumentIndex.rawChunks` vivem sob a isolação default do
        // projeto) — `singleCall` só recebe a String pronta.
        let prompts = (0..<n).map { Self.prompt(forCallIndex: $0) }
        let start = Date()
        var errors = 0
        var concurrencyErrors = 0
        for (index, prompt) in prompts.enumerated() {
            let outcome = await Self.singleCall(callIndex: index, prompt: prompt)
            errors += outcome.otherError ? 1 : 0
            concurrencyErrors += outcome.concurrencyError ? 1 : 0
        }
        return (Date().timeIntervalSince(start) * 1000, errors, concurrencyErrors)
    }

    /// N chamadas SIMULTÂNEAS, cada uma com a própria `LanguageModelSession`
    /// (Task paralelas — é exatamente o que a fila de produção impede, e o
    /// que o experimento quer provocar de propósito).
    private func runConcurrent(n: Int) async -> (totalMs: Double, errors: Int, concurrencyErrors: Int) {
        let prompts = (0..<n).map { Self.prompt(forCallIndex: $0) }
        let start = Date()
        var errors = 0
        var concurrencyErrors = 0

        await withTaskGroup(of: (concurrencyError: Bool, otherError: Bool).self) { group in
            for (index, prompt) in prompts.enumerated() {
                group.addTask {
                    await Self.singleCall(callIndex: index, prompt: prompt)
                }
            }
            for await outcome in group {
                errors += outcome.otherError ? 1 : 0
                concurrencyErrors += outcome.concurrencyError ? 1 : 0
            }
        }

        return (Date().timeIntervalSince(start) * 1000, errors, concurrencyErrors)
    }

    /// UMA chamada FM realista: sessão nova + respond estruturado no mesmo
    /// formato do `generateSummary` de produção (schema `TopicSummary`,
    /// mesmo orçamento de 750 tokens). `nonisolated`/static: roda dentro de
    /// child tasks do TaskGroup, fora do MainActor.
    private nonisolated static func singleCall(callIndex: Int, prompt: String) async -> (concurrencyError: Bool, otherError: Bool) {
        do {
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            let options = GenerationOptions(maximumResponseTokens: 750)
            _ = try await session.respond(to: prompt, generating: TopicSummary.self, options: options)
            return (false, false)
        } catch {
            // O reconhecimento do erro já existe em produção
            // (StudyGeneratorError.describe) — aqui só o CLASSIFICAMOS para
            // a taxa do critério de decisão. O log usa String(describing:)
            // em vez de describe() porque este contexto é nonisolated e
            // describe() vive sob a isolação MainActor default do projeto —
            // não vale um hop de ator só para formatar um log de debug.
            if let genError = error as? LanguageModelSession.GenerationError {
                switch genError {
                case .concurrentRequests, .rateLimited:
                    print("🧪 [FMConcurrency] chamada \(callIndex): erro de CONCORRÊNCIA — \(String(describing: genError))")
                    return (true, false)
                default:
                    break
                }
            }
            print("🧪 [FMConcurrency] chamada \(callIndex): erro (não-concorrência) — \(String(describing: error))")
            return (false, true)
        }
    }

    private func log(_ line: String) {
        progressLog.append(line)
        print("🧪 [FMConcurrency] \(line)")
    }

    // MARK: - Exportação (mesmo padrão de GPUCacheLimitSweep)

    @discardableResult
    func exportReportToDocuments() -> URL? {
        guard let report = lastReport else {
            print("⚠️ FMConcurrencyExperiment: nenhum relatório pra exportar — rode o experimento primeiro.")
            return nil
        }
        guard let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = base.appendingPathComponent("fm-concurrency-\(Int(Date().timeIntervalSince1970)).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(report)
            try data.write(to: url, options: .atomic)
            print("🟢 FMConcurrencyExperiment: relatório exportado para \(url.path) (\(data.count / 1024) KB).")
            return url
        } catch {
            print("⚠️ FMConcurrencyExperiment: falha ao exportar relatório: \(error)")
            return nil
        }
    }
}
