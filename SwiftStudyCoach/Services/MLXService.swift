//
//  MLXService.swift
//  SwiftStudyCoach
//
//  Created by Geovana Cena de Albuquerque on 05/08/26.
//
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Serviço responsável por carregar o modelo local via MLX e gerar rascunhos de perguntas difíceis
final class MLXService {
    static let shared = MLXService()
    
    private var modelContainer: ModelContainer?
    private var isLoaded = false
    
    private init() {}
    
    /// Carrega o modelo especialista em código na memória do Mac
    func loadModel() async throws {
        guard !isLoaded else { return }
        
        // Usamos o modelo padrão do Qwen2.5-Coder 7B Instruct da comunidade MLX
        let modelConfiguration = ModelConfiguration(id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit")
        
        print("Carregando modelo MLX na memória unificada do Mac...")
        self.modelContainer = try await LLMModelFactory.shared.loadContainer(configuration: modelConfiguration)
        self.isLoaded = true
        print("Modelo MLX carregado com sucesso!")
    }
    
    /// Gera um rascunho de pergunta difícil de código com base no texto do RAG
    func generateQuestionDraft(promptContext: String) async throws -> String {
        guard let container = modelContainer else {
            throw NSError(domain: "MLXService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Modelo MLX não carregado."])
        }
        
        let systemPrompt = "Você é um especialista em Swift. Gere uma pergunta difícil de análise de código em texto puro."
        let fullPrompt = "<|im_start|>system\n\(systemPrompt)<|im_end|>\n<|im_start|>user\nContexto da documentação:\n\(promptContext)\n\nCrie uma pergunta desafiadora de múltipla escolha sobre esse assunto.<|im_end|>\n<|im_start|>assistant\n"
        
        let generateParams = GenerateParameters(temperature: 0.3)
        
        let stream = try await container.perform { context in
            let input = try await context.processor.prepare(input: .init(prompt: fullPrompt))
            return try generate(input: input, parameters: generateParams, context: context)
        }
        
        // Acumula os pedaços do texto gerado no stream
        // Acumula os pedaços de texto vindos da IA
            var outputText = ""
            for try await generation in stream {
                if let chunk = generation.chunk {
                    outputText.append(chunk)
                }
            }
            
            return outputText
        }
        
        
}
