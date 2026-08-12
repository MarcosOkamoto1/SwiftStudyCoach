//
//  MLXWarmupAnalyzer.swift
//  SwiftStudyCoach
//
//  PLAN_13 Parte 2 — MEDIÇÃO (não implementação) do custo da 1ª chamada
//  MLX de uma sessão do app vs. a 2ª/3ª (SOLUTIONS_PLAN.md §12.2:
//  `HYPOTHESIS` de compilação/JIT de kernels Metal na 1ª inferência — não
//  confirmável sem medir).
//
//  Este arquivo NÃO implementa `warmUp()`. Ele só LÊ os `GenerationMetrics`
//  que o PLAN_00 já coleta (a instrumentação necessária já existe — nenhuma
//  nova foi adicionada) e:
//    1. extrai da sessão ATUAL do app a comparação 1ª chamada
//       (`isColdStart == true`) vs. as chamadas seguintes;
//    2. PERSISTE esse registro em Documents/ (acumulando entre sessões),
//       porque uma única sessão é uma amostra de tamanho 1 — o plano pede
//       "rodar várias sessões (reiniciar o app entre medições)";
//    3. agrega os registros acumulados e aplica o critério de decisão do
//       PLAN_13 ("diferença pequena → não implementar; grande e mensurável
//       → implementar warmUp() conforme §12.3").
//
//  ⚠️ Como comparar de forma HONESTA (por que não usar TTFT bruto):
//  - O TTFT (`promptTime`) bruto depende do TAMANHO do prompt, e prompts de
//    tarefas diferentes têm tamanhos diferentes.
//  - O PLAN_11 confunde ainda mais: a 2ª chamada de um tópico tende a ser
//    um cache HIT de prefixo, então o `promptTokenCount` dela conta só o
//    SUFIXO — TTFT menor na 2ª chamada seria em parte o cache, não o
//    warm-up.
//  Por isso a métrica de comparação é THROUGHPUT, não tempo absoluto:
//    - prefill: `inputTokenCount / promptTime` (tokens de prompt realmente
//      processados por segundo — num HIT, ambos os lados da divisão se
//      referem só ao sufixo, então a razão continua justa);
//    - decode: `tokensPerSecond` (já normalizado pela própria lib).
//  Se a 1ª chamada paga compilação de kernels Metal, isso aparece como
//  throughput menor NELA, independente do tamanho do prompt.
//
//  Puramente ferramenta de desenvolvimento, só usada pela
//  TopicRepositoryTestView — nenhum caminho de produção depende disto.
//

import Foundation
import Observation

// MARK: - Registro de UMA sessão do app

struct MLXWarmupSessionRecord: Codable, Identifiable {
    let id: UUID
    let recordedAt: Date
    let modelID: String

    // 1ª chamada MLX de geração da sessão (isColdStart == true)
    let coldPrefillTokensPerSecond: Double?
    let coldDecodeTokensPerSecond: Double?
    let coldTimeToFirstTokenMs: Double?
    let coldPromptCacheState: String
    let coldTaskType: String

    // 2ª/3ª chamadas (mediana, até 3 chamadas seguintes)
    let warmCallCount: Int
    let warmMedianPrefillTokensPerSecond: Double?
    let warmMedianDecodeTokensPerSecond: Double?
    let warmMedianTimeToFirstTokenMs: Double?

    /// Razão quente/frio do throughput de prefill (>1 = a 1ª chamada foi
    /// mais lenta que as seguintes; ex.: 1.4 = as chamadas quentes
    /// processam prompt 40% mais rápido que a fria).
    var prefillWarmupRatio: Double? {
        guard let cold = coldPrefillTokensPerSecond, cold > 0,
              let warm = warmMedianPrefillTokensPerSecond else { return nil }
        return warm / cold
    }

    var decodeWarmupRatio: Double? {
        guard let cold = coldDecodeTokensPerSecond, cold > 0,
              let warm = warmMedianDecodeTokensPerSecond else { return nil }
        return warm / cold
    }

    var summaryLine: String {
        let prefill = prefillWarmupRatio.map { String(format: "%.2fx", $0) } ?? "n/d"
        let decode = decodeWarmupRatio.map { String(format: "%.2fx", $0) } ?? "n/d"
        return "fria (\(coldTaskType), cache \(coldPromptCacheState)) vs \(warmCallCount) quente(s) — prefill quente/frio \(prefill) · decode quente/frio \(decode)"
    }
}

// MARK: - Analisador + persistência entre sessões

@Observable
final class MLXWarmupAnalyzer {

    /// Limiar de decisão (interpretação documentada do critério do PLAN_13:
    /// "se a diferença for pequena → não implementar"): warm-up só se
    /// justifica se a 1ª chamada for consistentemente ≥30% mais lenta que
    /// as seguintes (razão mediana ≥1.3) em prefill OU decode, com pelo
    /// menos `minSessions` sessões medidas. A decisão final é humana e vai
    /// registrada em plans/PLAN_13_DECISION.md.
    static let warmupJustifiedRatio = 1.3
    static let minSessions = 5

    private(set) var sessions: [MLXWarmupSessionRecord] = []
    private(set) var statusMessage: String?
    /// Evita registrar a MESMA sessão do app duas vezes (duplicaria a
    /// amostra com dados idênticos).
    private var hasRecordedThisSession = false

    init() {
        sessions = Self.loadSessions()
    }

    // MARK: - Extração da sessão atual (a partir do PLAN_00)

    /// Lê a store do PLAN_00 e monta o registro frio-vs-quente da sessão
    /// ATUAL. Devolve nil se ainda não houve pelo menos 1 chamada fria + 1
    /// quente (ex.: o app ainda não gerou nada via MLX nesta sessão).
    static func currentSessionRecord(from snapshot: [GenerationMetrics]) -> MLXWarmupSessionRecord? {
        // Só chamadas MLX de GERAÇÃO (modelLoad é o warm-up de PESOS, que já
        // existe e não é o que está sendo medido; embeddingIndex não é MLX).
        let mlxCalls = snapshot
            .filter { $0.engine == .mlx && $0.taskType != .modelLoad }
            .sorted { $0.timestamp < $1.timestamp }

        guard let cold = mlxCalls.first(where: { $0.isColdStart }) ?? mlxCalls.first,
              let coldIndex = mlxCalls.firstIndex(where: { $0.id == cold.id })
        else { return nil }

        let warmCalls = Array(mlxCalls.dropFirst(coldIndex + 1).prefix(3))
        guard !warmCalls.isEmpty else { return nil }

        return MLXWarmupSessionRecord(
            id: UUID(),
            recordedAt: Date(),
            modelID: cold.modelID,
            coldPrefillTokensPerSecond: prefillTPS(cold),
            coldDecodeTokensPerSecond: cold.tokensPerSecond,
            coldTimeToFirstTokenMs: cold.timeToFirstTokenMs,
            coldPromptCacheState: cold.promptCacheState.rawValue,
            coldTaskType: cold.taskType.rawValue,
            warmCallCount: warmCalls.count,
            warmMedianPrefillTokensPerSecond: median(warmCalls.compactMap(prefillTPS)),
            warmMedianDecodeTokensPerSecond: median(warmCalls.compactMap(\.tokensPerSecond)),
            warmMedianTimeToFirstTokenMs: median(warmCalls.compactMap(\.timeToFirstTokenMs))
        )
    }

    /// Throughput de prefill: tokens de prompt realmente processados por
    /// segundo de `promptTime`. Ver o cabeçalho do arquivo para por que
    /// isto (e não TTFT bruto) é a comparação justa sob PLAN_11.
    private static func prefillTPS(_ metric: GenerationMetrics) -> Double? {
        guard let ttftMs = metric.timeToFirstTokenMs, ttftMs > 0,
              let inputTokens = metric.inputTokenCount, inputTokens > 0 else { return nil }
        return Double(inputTokens) / (ttftMs / 1000)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: - Registro (acumula entre sessões do app)

    /// Extrai o registro da sessão atual e o anexa ao arquivo acumulado em
    /// Documents/. Rodar UMA vez por sessão do app, DEPOIS de já ter havido
    /// ≥2 chamadas MLX reais (ex.: depois de abrir um tópico e deixar o
    /// background gerar quiz difícil + análise).
    func recordCurrentSession() async {
        guard !hasRecordedThisSession else {
            statusMessage = "Esta sessão do app já foi registrada — reinicie o app para uma nova amostra."
            return
        }

        let snapshot = await GenerationMetricsStore.shared.snapshot()
        guard let record = Self.currentSessionRecord(from: snapshot) else {
            statusMessage = "Ainda não há 1 chamada MLX fria + ≥1 quente nesta sessão — gere um tópico (com quiz difícil/análise) primeiro."
            return
        }

        sessions.append(record)
        Self.saveSessions(sessions)
        hasRecordedThisSession = true
        statusMessage = "Sessão registrada (\(sessions.count) acumulada(s)): \(record.summaryLine)"
        print("🧪 [MLXWarmup] \(statusMessage ?? "")")
    }

    func clearAllSessions() {
        sessions.removeAll()
        Self.saveSessions(sessions)
        hasRecordedThisSession = false
        statusMessage = "Amostras acumuladas apagadas."
    }

    // MARK: - Agregação + leitura sugerida do critério de decisão

    var aggregateSummary: String {
        // Só sessões do modelo ATUAL — misturar modelos diferentes na mesma
        // mediana não mede nada.
        let relevant = sessions.filter { $0.modelID == MLXService.modelID }
        guard !relevant.isEmpty else {
            return "Nenhuma sessão registrada ainda para \(MLXService.modelID)."
        }

        let prefillRatios = relevant.compactMap(\.prefillWarmupRatio)
        let decodeRatios = relevant.compactMap(\.decodeWarmupRatio)
        let medianPrefill = Self.median(prefillRatios)
        let medianDecode = Self.median(decodeRatios)

        let prefillStr = medianPrefill.map { String(format: "%.2fx", $0) } ?? "n/d"
        let decodeStr = medianDecode.map { String(format: "%.2fx", $0) } ?? "n/d"

        var lines = "\(relevant.count) sessão(ões) · razão quente/frio mediana — prefill \(prefillStr) · decode \(decodeStr)."

        if relevant.count < Self.minSessions {
            lines += " Amostra pequena (<\(Self.minSessions)) — reinicie o app e registre mais sessões antes de decidir."
        } else if let p = medianPrefill, let d = medianDecode, max(p, d) >= Self.warmupJustifiedRatio {
            lines += " Diferença GRANDE (≥\(String(format: "%.0f%%", (Self.warmupJustifiedRatio - 1) * 100))) → warm-up de inferência se justifica: implementar warmUp() conforme §12.3 (prefixo do PLAN_11, após loadModel(), só com pesos em cache, Task.detached .utility)."
        } else {
            lines += " Diferença pequena → NÃO implementar warm-up (critério do PLAN_13): a 1ª chamada já roda em background (D1/D5) e o custo extra não é sentido pelo usuário."
        }
        return lines
    }

    // MARK: - Persistência (Documents/, mesmo padrão dos outros harnesses)

    private static var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("mlx-warmup-sessions.json")
    }

    private static func loadSessions() -> [MLXWarmupSessionRecord] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MLXWarmupSessionRecord].self, from: data)) ?? []
    }

    private static func saveSessions(_ sessions: [MLXWarmupSessionRecord]) {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try (try encoder.encode(sessions)).write(to: url, options: .atomic)
        } catch {
            print("⚠️ MLXWarmupAnalyzer: falha ao salvar sessões: \(error)")
        }
    }
}
