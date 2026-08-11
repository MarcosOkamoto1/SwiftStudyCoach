//
//  MLXService.swift
//  SwiftStudyCoach
//
//  Created by Geovana Cena de Albuquerque on 05/08/26.
//
//  Melhorias desta versão:
//  - Sobe pro Qwen2.5-Coder-14B-4bit (~8,3 GB): app é exclusivo pra MacBook
//    com 24 GB de RAM unificada, então cabe com folga (pesos + KV cache
//    ficam bem abaixo do limite, sobra RAM pro resto do sistema/Xcode). O
//    14B tem MUITO mais capacidade de seguir instruções complexas (checklist
//    de erros comuns, não inventar API, respeitar itemSeparator em lotes)
//    que o 7B (~4,3 GB, usado numa versão anterior) e o 3B-4bit (~1,7 GB,
//    usado numa versão ainda anterior). Trade-off: download maior e geração
//    mais lenta por item — mitigado pelos lotes pequenos (≤3) com desistência
//    do TopicRepository (Plano V4, hotfix pós-teste).
//  - Progresso de download real (fração + velocidade + ETA) exposto de
//    forma observável — ver ModelDownloadView.
//  - Geração de rascunhos em LOTE (generateQuestionDrafts): um único
//    prefill do prompt para N itens, em vez de um prefill por item.
//

import Foundation
import Observation
import MLX
import MLXLLM
import MLXLMCommon

@Observable
final class MLXService {
    static let shared = MLXService()

    /// ID do modelo no Hugging Face (mlx-community). Constante separada de
    /// propósito: facilita A/B com o 1.5B/3B/7B (menores, mais rápidos,
    /// usados em versões anteriores). App é Mac-only com 24 GB de RAM, então
    /// sobe pro 14B — ver comentário do cabeçalho do arquivo.
    static let modelID = "mlx-community/Qwen2.5-Coder-14B-Instruct-4bit"

    /// Tamanho aproximado do download (usado pra estimar MB e velocidade —
    /// o progress do Hub reporta fração, não bytes). 8,31 GB confirmado na
    /// página do modelo no Hugging Face.
    static let estimatedModelBytes: Int64 = 8_310_000_000

    /// Linha separadora usada nos prompts/parse de geração em lote.
    static let itemSeparator = "====="

    /// Estado observável do carregamento/download do modelo MLX. A UI
    /// (ModelDownloadView) observa isso pra mostrar progresso, velocidade
    /// e tempo estimado na primeira execução.
    enum LoadState: Equatable {
        case idle
        case downloading(fraction: Double)
        case loadingIntoMemory   // download concluído, carregando pesos na RAM
        case ready
        case failed(String)
    }

    private(set) var loadState: LoadState = .idle

    /// Velocidade estimada de download (bytes/s) e tempo restante estimado
    /// (segundos) — calculados por janela deslizante das últimas amostras
    /// de progresso, com suavização pra não oscilar.
    private(set) var downloadSpeedBytesPerSecond: Double?
    private(set) var downloadETASeconds: Double?

    private var progressSamples: [(date: Date, fraction: Double)] = []

    private var modelContainer: ModelContainer?
    private var isLoaded = false
    private var loadTask: Task<Void, Error>?

    private init() {}

    // MARK: - Carregamento / download

    func loadModel() async throws {
        guard !isLoaded else {
            loadState = .ready
            return
        }

        // Dedup: várias chamadas concorrentes (tela + crescimento de pool em
        // background) aguardam o MESMO carregamento em vez de duplicá-lo.
        if let loadTask {
            try await loadTask.value
            return
        }

        let task = Task { try await performLoad() }
        loadTask = task
        do {
            try await task.value
        } catch {
            loadTask = nil // permite retry após falha
            throw error
        }
    }

    private func performLoad() async throws {
        loadState = .downloading(fraction: 0)
        progressSamples = [(Date(), 0)]
        downloadSpeedBytesPerSecond = nil
        downloadETASeconds = nil

        let modelConfiguration = ModelConfiguration(id: Self.modelID)

        print("Carregando modelo MLX (\(Self.modelID))...")
        do {
            self.modelContainer = try await LLMModelFactory.shared.loadContainer(
                configuration: modelConfiguration
            ) { [weak self] progress in
                // O handler é @Sendable e roda fora do MainActor — capturamos
                // só o Double e voltamos pro MainActor pra mutar estado.
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    self?.recordProgress(fraction: fraction)
                }
            }
            self.isLoaded = true
            loadState = .ready
            downloadSpeedBytesPerSecond = nil
            downloadETASeconds = nil
            print("Modelo MLX carregado com sucesso!")
        } catch {
            loadState = .failed(error.localizedDescription)
            throw error
        }
    }

    private func recordProgress(fraction: Double) {
        // Ignora callbacks tardios depois de pronto/falha.
        switch loadState {
        case .ready, .failed: return
        default: break
        }

        if fraction >= 1.0 {
            loadState = .loadingIntoMemory
            downloadSpeedBytesPerSecond = nil
            downloadETASeconds = nil
            return
        }

        loadState = .downloading(fraction: fraction)

        progressSamples.append((Date(), fraction))
        if progressSamples.count > 24 {
            progressSamples.removeFirst(progressSamples.count - 24)
        }

        guard let oldest = progressSamples.first, progressSamples.count >= 3 else { return }
        let elapsed = Date().timeIntervalSince(oldest.date)
        let deltaFraction = fraction - oldest.fraction
        guard elapsed > 0.5, deltaFraction > 0 else { return }

        let fractionPerSecond = deltaFraction / elapsed
        let bytesPerSecond = fractionPerSecond * Double(Self.estimatedModelBytes)

        // Média móvel simples pra suavizar a leitura na UI.
        if let previous = downloadSpeedBytesPerSecond {
            downloadSpeedBytesPerSecond = previous * 0.7 + bytesPerSecond * 0.3
        } else {
            downloadSpeedBytesPerSecond = bytesPerSecond
        }
        downloadETASeconds = (1.0 - fraction) / fractionPerSecond
    }

    // MARK: - Geração

    /// Gera UM rascunho de texto livre.
    func generateQuestionDraft(systemPrompt: String, promptContext: String) async throws -> String {
        try await generate(systemPrompt: systemPrompt, promptContext: promptContext, maxTokens: 350)
    }

    /// Gera N rascunhos numa ÚNICA chamada ao modelo (um prefill só), com os
    /// itens separados por `Self.itemSeparator`. O prompt chamador é
    /// responsável por pedir os itens separados por essa linha; aqui a
    /// resposta é fatiada e higienizada. Pode devolver menos itens que
    /// `count` — o chamador decide se completa um a um.
    func generateQuestionDrafts(systemPrompt: String, promptContext: String, count: Int) async throws -> [String] {
        guard count > 1 else {
            return [try await generateQuestionDraft(systemPrompt: systemPrompt, promptContext: promptContext)]
        }

        let output = try await generate(
            systemPrompt: systemPrompt,
            promptContext: promptContext,
            maxTokens: 300 * count + 50
        )

        let items = output
            .components(separatedBy: Self.itemSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 20 } // descarta sobras/linhas vazias do split

        print("MLX batch: pedidos \(count) rascunhos, obtidos \(items.count).")
        return items
    }

    // MARK: - Pré-aquecimento (Plano V3 4.3)

    /// Verifica, só com FileManager (SEM rede), se os pesos do modelo já
    /// parecem estar baixados no cache local do swift-transformers
    /// (`Documents/huggingface/models/...`, ver HubApi). Heurística
    /// conservadora: só considera "em cache" se encontrar pelo menos um
    /// arquivo `.safetensors` de verdade dentro do diretório esperado —
    /// só o diretório existir (ou só um config.json) não é garantia de
    /// download completo, e um falso positivo aqui dispararia download
    /// não solicitado, exatamente o que este item do plano proíbe.
    /// Checa tanto o layout aninhado (`models/<org>/<repo>`) quanto o
    /// layout achatado ao estilo Python (`models/<org>--<repo>`), já que
    /// a documentação do swift-transformers não fixa qual dos dois é
    /// usado em toda versão.
    static func isModelLikelyCached() -> Bool {
        guard let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return false
        }
        let modelsRoot = documentsDir.appendingPathComponent("huggingface", isDirectory: true).appendingPathComponent("models", isDirectory: true)

        let components = modelID.split(separator: "/").map(String.init)
        guard components.count == 2 else { return false }
        let org = components[0], repo = components[1]

        let candidateDirs = [
            modelsRoot.appendingPathComponent(org, isDirectory: true).appendingPathComponent(repo, isDirectory: true),
            modelsRoot.appendingPathComponent("\(org)--\(repo)", isDirectory: true),
        ]

        return candidateDirs.contains { directoryContainsSafetensors($0) }
    }

    private static func directoryContainsSafetensors(_ url: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return false
        }
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "safetensors" {
            return true
        }
        return false
    }

    /// Chamado no launch do app (ver RootTabView). Se — e SÓ se — o modelo
    /// já parece estar em cache local, carrega os pesos na RAM em
    /// background, sem esperar o usuário abrir um tópico difícil pela
    /// primeira vez. Sem cache local detectado, não faz absolutamente
    /// nada — nenhum download é disparado por conta própria.
    func prewarmIfCached() {
        guard Self.isModelLikelyCached() else {
            print("⚪️ MLXService: nenhum cache local detectado pro modelo — sem pré-aquecimento (download só sob demanda).")
            return
        }
        print("🟢 MLXService: modelo parece estar em cache local — pré-aquecendo em background.")
        Task.detached(priority: .background) {
            try? await MLXService.shared.loadModel()
        }
    }

    private func generate(systemPrompt: String, promptContext: String, maxTokens: Int) async throws -> String {
        guard let container = modelContainer else {
            throw NSError(domain: "MLXService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Modelo MLX não carregado."])
        }

        let fullPrompt = "<|im_start|>system\n\(systemPrompt)<|im_end|>\n<|im_start|>user\n\(promptContext)<|im_end|>\n<|im_start|>assistant\n"
        let generateParams = GenerateParameters(maxTokens: maxTokens, temperature: 0.3, repetitionPenalty: 1.1)
        let stream = try await container.perform { context in
            let input = try await context.processor.prepare(input: .init(prompt: fullPrompt))
            return try MLXLMCommon.generate(input: input, parameters: generateParams, context: context)
        }

        var outputText = ""
        for try await generation in stream {
            if let chunk = generation.chunk {
                outputText.append(chunk)
            }
        }

        return outputText
    }
}
