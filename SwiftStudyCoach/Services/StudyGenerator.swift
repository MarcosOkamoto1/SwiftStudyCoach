//
//  StudyGenerator.swift
//  SwiftStudyCoach
//
//  Encapsula a comunicação com o Foundation Models framework, com
//  grounding via RAG (DocumentIndex).
//

import Foundation
import FoundationModels

enum StudyGeneratorError: Error {
    case modelUnavailable(String)
    case generationFailed(Error)
}

@Observable
final class StudyGenerator {

    /// Índice RAG injetado — construído uma vez (ex: no início da tela)
    /// e reutilizado em todas as gerações.
    private let documentIndex: DocumentIndex

    init(documentIndex: DocumentIndex) {
        self.documentIndex = documentIndex
    }

    /// Verifica se o modelo de sistema está disponível neste device.
    func checkAvailability() -> String {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return "Modelo disponível ✅"
        case .unavailable(let reason):
            return "Modelo indisponível: \(reason)"
        @unknown default:
            return "Status desconhecido"
        }
    }

    /// Gera um resumo estruturado para um tópico de Swift, com grounding
    /// via RAG: o tópico é envolvido numa frase-molde antes de virar query
    /// de busca (uma palavra isolada, tipo "Optionals", embedda de forma
    /// menos confiável do que uma frase descritiva completa).
    func generateSummary(topic: String) async throws -> TopicSummary {
        let model = SystemLanguageModel.default

        guard case .available = model.availability else {
            throw StudyGeneratorError.modelUnavailable("Modelo indisponível neste device/simulador")
        }

        // A busca híbrida do DocumentIndex já tenta casar o tópico
        // diretamente antes de cair pra busca semântica — não precisamos
        // mais artificializar a query aqui.
        let context = (try? await documentIndex.retrieveContext(for: topic, topK: 3)) ?? ""

        let instructions = """
        Você é um assistente educacional especializado em Swift e nos frameworks da Apple.
        Responda sempre em português.
        Baseie-se PRINCIPALMENTE no contexto de documentação fornecido abaixo.
        Se o contexto não cobrir algum detalhe, seja conservador e não invente
        nomes de métodos, parâmetros ou comportamentos que não estão no contexto.
        """

        let session = LanguageModelSession(model: model, instructions: instructions)

        let prompt: String
        if context.isEmpty {
            prompt = """
            Tópico: \(topic)

            Gere um resumo estruturado desse tópico de Swift para um desenvolvedor
            iniciante/intermediário, incluindo pontos-chave e um exemplo de código curto.
            """
        } else {
            prompt = """
            Tópico: \(topic)

            Contexto da documentação oficial (use isso como base principal):
            \(context)

            Gere um resumo estruturado desse tópico de Swift para um desenvolvedor
            iniciante/intermediário, incluindo pontos-chave e um exemplo de código curto.
            """
        }

        do {
            let response = try await session.respond(
                to: prompt,
                generating: TopicSummary.self
            )
            return response.content
        } catch {
            throw StudyGeneratorError.generationFailed(error)
        }
    }
    
    // MARK: - MLX Integration (Perguntas Difíceis)
    
    /// Gera um rascunho de pergunta difícil usando o modelo local via MLX (Qwen-Coder)
    func generateAdvancedQuiz(topic: String) async throws -> String {
        // 1. Garante que o motor MLX está carregado na memória
        try await MLXService.shared.loadModel()
        
        // 2. Busca o contexto relevante da documentação via RAG
        let context = (try? await documentIndex.retrieveContext(for: topic, topK: 3)) ?? ""
        
        // 3. Chama o MLXService passando o texto recuperado pelo RAG
        let quizDraft = try await MLXService.shared.generateQuestionDraft(promptContext: context.isEmpty ? topic : context)
        
        return quizDraft
    }
}
