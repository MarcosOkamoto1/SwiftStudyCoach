//
//  StudyGenerator.swift
//  SwiftStudyCoach
//
//  Encapsula a comunicação com o Foundation Models framework.
//  Hoje (04/08): só gera o resumo de um tópico fixo, sem RAG ainda —
//  o objetivo é validar que o pipeline básico funciona de ponta a ponta.
//

import Foundation
import FoundationModels

enum StudyGeneratorError: Error {
    case modelUnavailable(String)
    case generationFailed(Error)
}

@Observable
final class StudyGenerator {

    /// Verifica se o modelo de sistema está disponível neste device.
    /// Sempre cheque isso antes de tentar gerar — o modelo pode estar
    /// indisponível (Apple Intelligence desligado, device não suportado,
    /// modelo ainda baixando, etc.)
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

    /// Gera um resumo estruturado para um tópico de Swift.
    /// Por enquanto sem contexto de RAG — isso entra no dia 06/08.
    func generateSummary(topic: String) async throws -> TopicSummary {
        let model = SystemLanguageModel.default

        guard case .available = model.availability else {
            throw StudyGeneratorError.modelUnavailable("Modelo indisponível neste device/simulador")
        }

        let instructions = """
        Você é um assistente educacional especializado em Swift e nos frameworks da Apple.
        Responda sempre em português.
        Baseie-se apenas em fatos técnicos corretos sobre a linguagem Swift.
        Se não tiver certeza sobre algum detalhe de API, seja conservador e não invente
        nomes de métodos, parâmetros ou comportamentos.
        """

        let session = LanguageModelSession(model: model, instructions: instructions)

        let prompt = """
        Tópico: \(topic)

        Gere um resumo estruturado desse tópico de Swift para um desenvolvedor
        iniciante/intermediário, incluindo pontos-chave e um exemplo de código curto.
        """

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
}
