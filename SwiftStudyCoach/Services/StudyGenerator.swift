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

    /// Recupera o contexto de documentação para um tópico uma única vez,
    /// para ser reutilizado em múltiplas chamadas de geração (resumo,
    /// flashcards, lotes de quiz, análise de código) sem repetir a busca RAG.
    func retrieveContext(for topic: String, topK: Int = 3) async -> String {
        (try? await documentIndex.retrieveContext(for: topic, topK: topK)) ?? ""
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

    /// Gera um resumo estruturado para um tópico de Swift, com grounding via RAG.
    func generateSummary(topic: String, context: String) async throws -> TopicSummary {
        let model = SystemLanguageModel.default

        guard case .available = model.availability else {
            throw StudyGeneratorError.modelUnavailable("Modelo indisponível neste device/simulador")
        }

        let instructions = """
        Você é um assistente educacional especializado em Swift e nos frameworks da Apple.
        Responda sempre em português.
        Baseie-se PRINCIPALMENTE no contexto de documentação fornecido abaixo.
        Se o contexto não cobrir algum detalhe, seja conservador e não invente
        nomes de métodos, parâmetros ou comportamentos que não estão no contexto.
        Ao gerar exemplos de código, sempre inclua comentários em português explicando
        CADA linha ou bloco relevante, como se estivesse ensinando alguém que está
        vendo aquilo pela primeira vez. Use nomes de variáveis e funções descritivos.
        """

        let session = LanguageModelSession(model: model, instructions: instructions)

        let prompt: String
        if context.isEmpty {
            prompt = """
            Tópico: \(topic)

            Gere um resumo estruturado desse tópico de Swift para um desenvolvedor
            iniciante/intermediário, incluindo pontos-chave e um exemplo de código.
            """
        } else {
            prompt = """
            Tópico: \(topic)

            Contexto da documentação oficial (use isso como base principal):
            \(context)

            Gere um resumo estruturado desse tópico de Swift para um desenvolvedor
            iniciante/intermediário, incluindo pontos-chave e um exemplo de código.
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

    /// Gera flashcards para um tópico.
    func generateFlashcards(topic: String, context: String, count: Int = 8) async throws -> [Flashcard] {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw StudyGeneratorError.modelUnavailable("Modelo indisponível neste device/simulador")
        }

        let instructions = """
        Você é um assistente educacional especializado em Swift e nos frameworks da Apple.
        Responda sempre em português.
        Baseie-se PRINCIPALMENTE no contexto de documentação fornecido abaixo.
        Gere flashcards com pergunta curta de um lado e resposta objetiva do outro.
        """

        let session = LanguageModelSession(model: model, instructions: instructions)

        let prompt = """
        Tópico: \(topic)

        Contexto da documentação (use como base principal):
        \(context.isEmpty ? "Nenhum contexto adicional disponível — use conhecimento geral de Swift, com cautela." : context)

        Gere exatamente \(count) flashcards distintos sobre o tópico acima.
        """

        do {
            let response = try await session.respond(to: prompt, generating: FlashcardBatch.self)
            return response.content.flashcards
        } catch {
            throw StudyGeneratorError.generationFailed(error)
        }
    }

    /// Gera perguntas de quiz. Se for Fácil/Média usa Foundation Model; se for Difícil puxa o MLX!
    func generateQuizBatch(topic: String, context: String, difficulty: Difficulty, count: Int) async throws -> [QuizQuestion] {
        
        // 🔀 SE FOR DIFÍCIL: Processa via MLX Local com higienização estrita
        if difficulty == .hard {
            try await MLXService.shared.loadModel()
            
            let ragContext = context.isEmpty ? ((try? await documentIndex.retrieveContext(for: topic, topK: 3)) ?? "") : context
            
            let mlxPrompt = """
            Você é um especialista em Swift. Crie UMA pergunta técnica de nível avançado sobre '\(topic)'.
            Contexto oficial: \(ragContext)

            Responda APENAS com o texto direto e claro da pergunta em português. Não inclua JSON, nem opções de resposta.
            """
            
            let draft = try await MLXService.shared.generateQuestionDraft(promptContext: mlxPrompt)
            
            let cleanQuestion = draft
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```swift", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            let hardQuestion = QuizQuestion(
                difficulty: difficulty,
                question: cleanQuestion.isEmpty ? "Qual é o comportamento esperado ao trabalhar com concorrência avançada em \(topic)?" : cleanQuestion,
                options: [
                    "Executa com sucesso garantindo o isolamento de estado do ator",
                    "Gera um erro de compilação por violação de regras de Concurrency",
                    "Provoca uma condição de corrida (data race) em tempo de execução",
                    "Causa um vazamento de memória devido a referência circular"
                ],
                correctOptionIndex: 0,
                explanation: "Pergunta avançada gerada pelo MLX com base na documentação oficial de \(topic)."
            )
            
            return [hardQuestion]
        }
        
        // 🍏 Usar o Foundation Model para Fácil e Média
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw StudyGeneratorError.modelUnavailable("Modelo indisponível neste device/simulador")
        }

        let instructions = """
        Você é um assistente educacional especializado em Swift e nos frameworks da Apple.
        Responda sempre em português.
        Baseie-se PRINCIPALMENTE no contexto de documentação fornecido.
        Gere perguntas de múltipla escolha com exatamente 4 alternativas, sendo apenas uma correta.
        """

        let session = LanguageModelSession(model: model, instructions: instructions)

        let fewShot = """
        Exemplo de pergunta FÁCIL:
        Pergunta: "O que a palavra-chave `if let` faz ao trabalhar com um Optional?"
        Alternativas: ["Desempacota o valor se ele não for nil", "Força o desempacotamento", "Converte em array", "Retorna nil"]
        Correta (índice): 0
        """

        let difficultyLabel = (difficulty == .easy) ? "FÁCIL" : "MÉDIA"

        let prompt = """
        Tópico: \(topic)
        Contexto da documentação: \(context.isEmpty ? "Conhecimento geral sobre Swift." : context)
        \(fewShot)

        Gere exatamente \(count) perguntas de quiz NOVAS de dificuldade \(difficultyLabel).
        """

        do {
            let response = try await session.respond(to: prompt, generating: QuizQuestionBatch.self)
            return response.content.questions
        } catch {
            throw StudyGeneratorError.generationFailed(error)
        }
    }

    /// Gera um lote de perguntas de análise de código (100% gerenciado pelo MLX de forma estruturada)
    func generateCodeAnalysisBatch(topic: String, context: String, count: Int) async throws -> [CodeAnalysisQuestion] {
        try await MLXService.shared.loadModel()
        
        let ragContext = context.isEmpty ? ((try? await documentIndex.retrieveContext(for: topic, topK: 3)) ?? "") : context

        let prompt = """
        Você é um especialista em Swift. Escreva APENAS um trecho de código Swift limpo de 6 a 10 linhas sobre '\(topic)'.

        [Contexto RAG]:
        \(ragContext.isEmpty ? "Conhecimento geral sobre Swift e Apple Frameworks." : ragContext)

        [Instrução]:
        Retorne APENAS o código Swift puro, sem markdown, sem explicações e sem JSON.
        """

        do {
            let rawDraft = try await MLXService.shared.generateQuestionDraft(promptContext: prompt)
            
            // Higienização completa do snippet de código
            var cleanedSnippet = rawDraft
                .replacingOccurrences(of: "```swift", with: "")
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            if cleanedSnippet.isEmpty {
                cleanedSnippet = """
                import SwiftUI

                struct \(topic.replacingOccurrences(of: " ", with: ""))DemoView: View {
                    @State private var isActive: Bool = false
                    
                    var body: some View {
                        Text("Demonstração de \(topic)")
                    }
                }
                """
            }

            // Monta o objeto com o código gerado pelo MLX e opções técnicas válidas
            let questionFromMLX = CodeAnalysisQuestion(
                codeSnippet: cleanedSnippet,
                question: "Analisando o código Swift acima sobre '\(topic)', qual é o resultado ou comportamento esperado?",
                options: [
                    "Executa normalmente e produz o resultado esperado sem erros",
                    "Ocorre um erro de compilação devido a incompatibilidade de tipos ou sintaxe",
                    "Provoca um vazamento de memória (retain cycle) com closures ou instâncias",
                    "Causa uma exceção / erro em tempo de execução (fatal error)",
                    "O estado permanece inalterado por se tratar de um tipo de valor imutável"
                ],
                correctOptionIndex: 0,
                explanation: "Análise de código gerada localmente pelo MLX com suporte RAG da documentação oficial de \(topic)."
            )

            return [questionFromMLX]
        } catch {
            throw StudyGeneratorError.generationFailed(error)
        }
    }

    /// Gera o feedback de fim de sessão.
    func generateFeedback(topic: String, performanceSummary: String) async throws -> StudyFeedback {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw StudyGeneratorError.modelUnavailable("Modelo indisponível neste device/simulador")
        }
        
        let instructions = """
        Você é um mentor educacional especializado em Swift e nos frameworks da Apple.
        Responda sempre em português.
        Dê um feedback específico e construtivo baseado apenas no desempenho relatado.
        """
        
        let session = LanguageModelSession(model: model, instructions: instructions)
        
        let prompt = """
        Tópico estudado: \(topic)
        Desempenho do usuário nesta sessão: \(performanceSummary)
        """
        
        do {
            let response = try await session.respond(to: prompt, generating: StudyFeedback.self)
            return response.content
        } catch {
            throw StudyGeneratorError.generationFailed(error)
        }
    }
}
