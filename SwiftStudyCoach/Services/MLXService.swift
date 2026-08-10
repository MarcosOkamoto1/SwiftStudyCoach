//
//  MLXService.swift
//  SwiftStudyCoach
//
//  Created by Geovana Cena de Albuquerque on 05/08/26.
//
import Foundation
import Observation
import MLX
import MLXLLM
import MLXLMCommon


@Observable
final class MLXService {
    static let shared = MLXService()

    /// Estado observável do carregamento/download do modelo MLX. A UI
    /// (ex: TopicStudyView) observa isso pra mostrar um indicador
    /// específico de "baixando modelo" na primeira execução, em vez de
    /// deixar a tela parada em silêncio.
    enum LoadState: Equatable {
        case idle
        case downloading
        case ready
        case failed(String)
    }

    private(set) var loadState: LoadState = .idle

    private var modelContainer: ModelContainer?
    private var isLoaded = false

    private init() {}

    func loadModel() async throws {
        guard !isLoaded else {
            loadState = .ready
            return
        }

        loadState = .downloading
        let modelConfiguration = ModelConfiguration(id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit")

        print("Carregando modelo MLX na memória unificada do Mac...")
        do {
            self.modelContainer = try await LLMModelFactory.shared.loadContainer(configuration: modelConfiguration)
            self.isLoaded = true
            loadState = .ready
            print("Modelo MLX carregado com sucesso!")
        } catch {
            loadState = .failed(error.localizedDescription)
            throw error
        }
    }
    
    func generateQuestionDraft(systemPrompt: String, promptContext: String) async throws -> String {
        guard let container = modelContainer else {
            throw NSError(domain: "MLXService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Modelo MLX não carregado."])
        }

        let fullPrompt = "<|im_start|>system\n\(systemPrompt)<|im_end|>\n<|im_start|>user\n\(promptContext)<|im_end|>\n<|im_start|>assistant\n"
        let generateParams = GenerateParameters(maxTokens: 350, temperature: 0.3)
        let stream = try await container.perform { context in
            let input = try await context.processor.prepare(input: .init(prompt: fullPrompt))
            return try generate(input: input, parameters: generateParams, context: context)
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
