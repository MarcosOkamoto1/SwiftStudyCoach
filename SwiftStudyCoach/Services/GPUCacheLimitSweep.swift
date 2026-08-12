//
//  GPUCacheLimitSweep.swift
//  SwiftStudyCoach
//
//  PLAN_12 — Calibração de `MLX.GPU.set(cacheLimit:)` por medição real, em
//  vez de um valor fixo "chutado" (ver SOLUTIONS_PLAN.md §11.2, que cita a
//  própria documentação da API MLX: "the optimal cache size varies
//  significantly by workload... The best approach is to experiment with
//  different cache limits and measure performance for your particular
//  workload").
//
//  Reaproveita a suíte de 18 prompts já existente (PLAN_05,
//  `ModelBenchmarkSuite`) — roda ela 3 vezes, uma por valor de `cacheLimit`,
//  e compara `tokensPerSecond` médio (via `GenerateCompletionInfo`, PLAN_00)
//  e `GPU.cacheMemory` de pico por variante.
//
//  IMPORTANTE — o que este arquivo NÃO faz: não escolhe nem aplica
//  automaticamente um `cacheLimit` em `MLXService.performLoad`. A decisão
//  final (SOLUTIONS_PLAN.md §11.3: "o menor valor que não regride
//  tokensPerSecond de forma mensurável") exige rodar isto numa Mac de
//  verdade com GPU MLX e LER o `SweepReport` resultante — não é algo que dá
//  pra fixar sem o dado medido, e "manter o default" é uma conclusão válida
//  do próprio PLAN_12. Depois de rodar e decidir, quem aplicar o valor
//  escolhido adiciona `GPU.set(cacheLimit: <valor medido>)` em
//  `MLXService.performLoad` (antes do `loadContainer`) e referencia o
//  `SweepReport` exportado no commit, conforme o "Commit boundary" do plano.
//
//  Puramente ferramenta de desenvolvimento, mesmo padrão de
//  `ModelBenchmarkSuite`: não é chamada por nenhum caminho de produção.
//

import Foundation
import Observation
import MLX

// MARK: - Resultado de UMA variante de cacheLimit

struct CacheLimitVariantResult: Codable, Identifiable {
    var id: String { label }

    /// Rótulo legível da variante (ex.: "default (sem alterar)", "2MB", "64MB").
    let label: String
    /// `nil` para a variante "default" — não chamamos `GPU.set(cacheLimit:)`
    /// nela, deixamos o comportamento do sistema como está (ver PLAN_12,
    /// "Estado esperado": medir o default É uma das 3 variantes).
    let appliedCacheLimitBytes: Int?

    let promptsExecuted: Int
    let promptsFailed: Int
    /// Média de `tokensPerSecond` (só sobre prompts com `GenerateCompletionInfo`
    /// — prompts que falharam ou não devolveram `.info` não entram na média).
    let avgTokensPerSecond: Double?
    /// `GPU.cacheMemory` (bytes) MEDIDO NO FIM da variante — proxy de pico:
    /// como o cache só cresce até o limite configurado e não é limpo entre
    /// prompts da mesma variante, o valor ao final tende a já refletir o
    /// platô de uso desta variante (mais confiável que amostrar no meio).
    let cacheMemoryBytesAtEnd: Int
    /// `GPU.peakMemory` (bytes) — pico absoluto de memória GPU (ativa + cache)
    /// observado durante toda a variante, via API nativa do MLX.
    let peakMemoryBytes: Int
}

// MARK: - Relatório comparativo das 3 variantes

struct CacheLimitSweepReport: Codable {
    let modelID: String
    let generatedAt: Date
    let variants: [CacheLimitVariantResult]

    /// Critério de decisão do PLAN_12 (§11.3): dentre as variantes SEM veto
    /// de falha (`promptsFailed == 0`) e com `avgTokensPerSecond` não-nil,
    /// escolhe a de MENOR `appliedCacheLimitBytes` cujo `avgTokensPerSecond`
    /// não fica abaixo do default por mais que `tolerance` (fração, ex. 0.03
    /// = 3%). A variante "default" (appliedCacheLimitBytes == nil) nunca é
    /// "recomendada para aplicar" (não há nada pra aplicar nela — já é o
    /// comportamento atual); ela só serve de baseline de comparação.
    ///
    /// Devolve `nil` se não houver baseline default medida, ou se nenhuma
    /// variante com `cacheLimit` explícito ficar dentro da tolerância — nesse
    /// caso a leitura correta é "manter o default" (conclusão válida,
    /// ver PLAN_12).
    func recommendedVariant(tolerance: Double = 0.03) -> CacheLimitVariantResult? {
        guard let baseline = variants.first(where: { $0.appliedCacheLimitBytes == nil }),
              let baselineTPS = baseline.avgTokensPerSecond, baselineTPS > 0 else {
            return nil
        }

        let candidates = variants
            .filter { $0.appliedCacheLimitBytes != nil && $0.promptsFailed == 0 }
            .compactMap { variant -> (CacheLimitVariantResult, Double)? in
                guard let tps = variant.avgTokensPerSecond else { return nil }
                return (variant, tps)
            }
            .filter { _, tps in tps >= baselineTPS * (1 - tolerance) }
            .sorted { ($0.0.appliedCacheLimitBytes ?? .max) < ($1.0.appliedCacheLimitBytes ?? .max) }

        return candidates.first?.0
    }

    var summaryLine: String {
        let baseline = variants.first(where: { $0.appliedCacheLimitBytes == nil })
        let baselineTPS = baseline?.avgTokensPerSecond.map { String(format: "%.1f", $0) } ?? "n/d"
        if let recommended = recommendedVariant() {
            let mb = Double(recommended.appliedCacheLimitBytes ?? 0) / 1_048_576
            return "PLAN_12: default=\(baselineTPS) tok/s · recomendado: \(recommended.label) (\(String(format: "%.1f", mb))MB) — não regrediu tok/s e reduz cacheMemory."
        } else {
            return "PLAN_12: default=\(baselineTPS) tok/s · nenhuma variante testada ficou dentro da tolerância sem regressão — manter o default (conclusão válida)."
        }
    }
}

// MARK: - Runner

/// Roda a suíte de 18 prompts (`ModelBenchmarkSuite`/PLAN_05) 3 vezes, uma
/// por valor de `cacheLimit`: default (sem alterar), ~2MB (sugestão da
/// própria doc da API MLX) e um valor intermediário (64MB). Sequencial, não
/// paralelo — GPU.set(cacheLimit:) é global ao processo, então rodar em
/// paralelo invalidaria a medição de qualquer variante.
@Observable
final class GPUCacheLimitSweep {

    /// Valores testados por padrão — ver PLAN_12 "Mudanças a implementar #2".
    /// 2MB é o valor citado literalmente pela documentação da API MLX como
    /// "relatively small cache sizes... perform just as well"; 64MB é o
    /// "intermediário" pedido pelo plano. Não são valores mágicos aplicados
    /// automaticamente — são só os 3 pontos de amostra do sweep.
    static let intermediateCacheLimitBytes = 64 * 1_048_576
    static let smallCacheLimitBytes = 2 * 1_048_576

    private let studyGenerator: StudyGenerator

    private(set) var isRunning = false
    private(set) var progressLog: [String] = []
    private(set) var lastReport: CacheLimitSweepReport?

    init(studyGenerator: StudyGenerator) {
        self.studyGenerator = studyGenerator
    }

    @discardableResult
    func run() async -> CacheLimitSweepReport {
        isRunning = true
        progressLog.removeAll()
        defer { isRunning = false }

        // Guarda o cacheLimit atual pra restaurar no fim — o sweep não deve
        // deixar o processo num estado diferente do que encontrou, mesmo se
        // cancelado/abortado no meio.
        let originalCacheLimit = GPU.cacheLimit

        var variants: [CacheLimitVariantResult] = []

        variants.append(await runVariant(label: "default (sem alterar)", cacheLimitBytes: nil))
        variants.append(await runVariant(label: "~2MB (sugestão da doc MLX)", cacheLimitBytes: Self.smallCacheLimitBytes))
        variants.append(await runVariant(label: "~64MB (intermediário)", cacheLimitBytes: Self.intermediateCacheLimitBytes))

        // Restaura o estado original — GPU.set(cacheLimit:) é global, então
        // sem isso o app continuaria rodando com o último valor testado
        // (64MB) depois do sweep, mudando o comportamento fora do
        // experimento sem ninguém ter decidido isso.
        GPU.set(cacheLimit: originalCacheLimit)

        let report = CacheLimitSweepReport(modelID: MLXService.modelID, generatedAt: Date(), variants: variants)
        lastReport = report
        log("🏁 Sweep concluído. \(report.summaryLine)")
        return report
    }

    private func runVariant(label: String, cacheLimitBytes: Int?) async -> CacheLimitVariantResult {
        log("▶️ Variante: \(label)")

        // GPU.clearCache() antes de cada variante — sem isso, buffers
        // retidos pela variante anterior (com um cacheLimit maior)
        // continuariam contando no `cacheMemory` desta variante, enviesando
        // a comparação entre variantes.
        GPU.clearCache()
        if let cacheLimitBytes {
            GPU.set(cacheLimit: cacheLimitBytes)
        }

        do {
            try await MLXService.shared.loadModel()
        } catch {
            log("   ❌ falha ao carregar o modelo: \(error.localizedDescription) — variante abortada.")
            return CacheLimitVariantResult(
                label: label,
                appliedCacheLimitBytes: cacheLimitBytes,
                promptsExecuted: 0,
                promptsFailed: 0,
                avgTokensPerSecond: nil,
                cacheMemoryBytesAtEnd: GPU.cacheMemory,
                peakMemoryBytes: GPU.peakMemory
            )
        }

        let suite = ModelBenchmarkSuite(studyGenerator: studyGenerator)
        let subReport = await suite.run()
        for line in suite.progressLog {
            progressLog.append("   \(line)")
        }

        let tokRates = subReport.results.compactMap { $0.metrics?.tokensPerSecond }
        let avgTPS = tokRates.isEmpty ? nil : tokRates.reduce(0, +) / Double(tokRates.count)

        let cacheMemoryAtEnd = GPU.cacheMemory
        let peak = GPU.peakMemory

        log("   ✅ \(subReport.promptsExecuted)/\(BenchmarkPrompts.all.count) ok · avg tok/s=\(avgTPS.map { String(format: "%.1f", $0) } ?? "n/d") · cacheMemory=\(cacheMemoryAtEnd / 1_048_576)MB · peak=\(peak / 1_048_576)MB")

        return CacheLimitVariantResult(
            label: label,
            appliedCacheLimitBytes: cacheLimitBytes,
            promptsExecuted: subReport.promptsExecuted,
            promptsFailed: subReport.promptsFailed,
            avgTokensPerSecond: avgTPS,
            cacheMemoryBytesAtEnd: cacheMemoryAtEnd,
            peakMemoryBytes: peak
        )
    }

    private func log(_ line: String) {
        progressLog.append(line)
        print("🧪 [CacheLimitSweep] \(line)")
    }

    // MARK: - Exportação (mesmo padrão de ModelBenchmarkSuite.exportReportToDocuments)

    @discardableResult
    func exportReportToDocuments() -> URL? {
        guard let report = lastReport else {
            print("⚠️ GPUCacheLimitSweep: nenhum relatório pra exportar — rode o sweep primeiro.")
            return nil
        }
        guard let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = base.appendingPathComponent("cachelimit-sweep-\(report.modelID.split(separator: "/").last ?? "model")-\(Int(Date().timeIntervalSince1970)).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(report)
            try data.write(to: url, options: .atomic)
            print("🟢 GPUCacheLimitSweep: relatório exportado para \(url.path) (\(data.count / 1024) KB).")
            return url
        } catch {
            print("⚠️ GPUCacheLimitSweep: falha ao exportar relatório: \(error)")
            return nil
        }
    }
}
