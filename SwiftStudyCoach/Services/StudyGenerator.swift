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
    // Struct para decodificar o quiz do MLX
    
    private struct MLXQuizAnalysisDTO: Decodable {
        let codeSnippet: String
        let question: String
        let options: [String]
        let correctOptionIndex: Int
        let explanation: String
    }

    func generateQuizBatch(topic: String, context: String, difficulty: Difficulty, count: Int) async throws -> [QuizQuestion] {
        
        // 🔀 SE FOR DIFÍCIL: Processa via MLX Local com formato JSON
        if difficulty == .hard {
            try await MLXService.shared.loadModel()
            
            let ragContext = context.isEmpty ? ((try? await documentIndex.retrieveContext(for: topic, topK: 3)) ?? "") : context
            
            // Alterado para pedir JSON assim como no quiz de código
            let mlxPrompt = """
            Você é um especialista em Swift. Crie UMA pergunta técnica de múltipla escolha de nível AVANÇADO sobre '\(topic)'.

            [Contexto RAG]:
            \(ragContext.isEmpty ? "Conhecimento geral sobre Swift." : ragContext)

            [Instruções de Saída]:
            Retorne APENAS um objeto JSON válido (sem textos em volta) exatamente neste formato:
            {
              "question": "Apenas o enunciado da pergunta sem listar alternativas aqui",
              "options": ["Opção A", "Opção B", "Opção C", "Opção D"],
              "correctOptionIndex": 0,
              "explanation": "Explicação técnica detalhada da resposta."
            }
            """
            
            let rawDraft = try await MLXService.shared.generateQuestionDraft(promptContext: mlxPrompt)
            
            // 1. Limpeza de marcadores de código Markdown
            var cleanJSON = rawDraft
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```swift", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            if let firstBrace = cleanJSON.firstIndex(of: "{"),
               let lastBrace = cleanJSON.lastIndex(of: "}") {
                cleanJSON = String(cleanJSON[firstBrace...lastBrace])
            }
            
            // 2. Tenta fazer o parse do JSON do MLX
            if let jsonData = cleanJSON.data(using: .utf8),
               let dto = try? JSONDecoder().decode(MLXQuizAnalysisDTO.self, from: jsonData),
               dto.options.count >= 4 {
                
                let hardQuestion = QuizQuestion(
                    difficulty: difficulty,
                    question: dto.question,
                    options: Array(dto.options.prefix(4)),
                    correctOptionIndex: dto.correctOptionIndex < 4 ? dto.correctOptionIndex : 0,
                    explanation: dto.explanation
                )
                return [hardQuestion]
                
            } else {
                // 3. Fallback de segurança se o JSON falhar
                let fallbackQuestion = QuizQuestion(
                    difficulty: difficulty,
                    question: "Qual é o comportamento esperado ao trabalhar com concorrência avançada e isolamento de estado em \(topic)?",
                    options: [
                        "Executa com sucesso garantindo o isolamento de estado do ator",
                        "Gera um erro de compilação por violação de regras de Concurrency",
                        "Provoca uma condição de corrida (data race) em tempo de execução",
                        "Causa um vazamento de memória devido a referência circular"
                    ],
                    correctOptionIndex: 0,
                    explanation: "Pergunta avançada sobre isolamento de estado em Swift."
                )
                return [fallbackQuestion]
            }
        }
        
        // Usar o Foundation Model para Fácil e Média...
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



    /// Gera um lote de perguntas de análise de código (100% dinâmico via MLX + JSON structured output)
    func generateCodeAnalysisBatch(topic: String, context: String, count: Int = 5) async throws -> [CodeAnalysisQuestion] {
        try await MLXService.shared.loadModel()
        
        let ragContext = context.isEmpty ? ((try? await documentIndex.retrieveContext(for: topic, topK: 3)) ?? "") : context

        let prompt = """
        Você é um especialista em Swift. Crie UMA pergunta técnica de análise de código sobre '\(topic)'.

        [Contexto RAG]:
        \(ragContext.isEmpty ? "Conhecimento geral sobre Swift e Apple Frameworks." : ragContext)

        [Instruções de Saída]:
        Retorne APENAS um objeto JSON válido (sem texto antes ou depois, sem explicações) com exatamente este formato:
        {
          "codeSnippet": "código Swift de 5 a 10 linhas em uma única string com \\n para quebras de linha",
          "question": "Pergunta sobre o comportamento do código",
          "options": ["Opção A", "Opção B", "Opção C", "Opção D"],
          "correctOptionIndex": 0,
          "explanation": "Explicação clara do porquê a opção correta é a certa e o que o código faz."
        }
        """

        do {
            var questionsBatch: [CodeAnalysisQuestion] = []
            let targetCount = count > 0 ? count : 5
            
            for index in 0..<targetCount {
                let rawDraft = try await MLXService.shared.generateQuestionDraft(promptContext: prompt)
                
                // 1. Limpeza de marcadores Markdown (```json ... ```)
                var cleanJSON = rawDraft
                    .replacingOccurrences(of: "```json", with: "")
                    .replacingOccurrences(of: "```swift", with: "")
                    .replacingOccurrences(of: "```", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Extrai o bloco de JSON se o modelo colocou texto em volta
                if let firstBrace = cleanJSON.firstIndex(of: "{"),
                   let lastBrace = cleanJSON.lastIndex(of: "}") {
                    cleanJSON = String(cleanJSON[firstBrace...lastBrace])
                }
                
                // 2. Tenta fazer o parse do JSON retornado pelo MLX
                if let jsonData = cleanJSON.data(using: .utf8),
                   let dto = try? JSONDecoder().decode(MLXQuizAnalysisDTO.self, from: jsonData),
                   dto.options.count >= 4 {
                    
                    let questionFromMLX = CodeAnalysisQuestion(
                        codeSnippet: dto.codeSnippet,
                        question: dto.question,
                        options: Array(dto.options.prefix(4)), // Garante 4 alternativas
                        correctOptionIndex: dto.correctOptionIndex < 4 ? dto.correctOptionIndex : 0,
                        explanation: dto.explanation
                    )
                    questionsBatch.append(questionFromMLX)
                    
                } else {
                    // 3. Fallback de Segurança caso o MLX gere um JSON malformado
                    let fallbackQuestion = CodeAnalysisQuestion(
                        codeSnippet: """
                        import SwiftUI

                        struct \(topic.replacingOccurrences(of: " ", with: ""))Demo\(index + 1): View {
                            @State private var count = 0
                            var body: some View {
                                Button("Incrementar: \\(count)") { count += 1 }
                            }
                        }
                        """,
                        question: "Analisando o código Swift acima sobre '\(topic)', qual é o comportamento do estado ao clicar no botão?",
                        options: [
                            "O estado é atualizado e a interface re-renderiza exibindo o novo valor.",
                            "Ocorre um erro de compilação por tentar mutar um estado imutável.",
                            "Causa uma condição de corrida (data race) em tempo de execução.",
                            "O botão é desativado após o primeiro clique."
                        ],
                        correctOptionIndex: 0,
                        explanation: "Propriedades marcadas com @State em SwiftUI são gerenciadas pelo framework. Quando o valor muda, a View invalida seu corpo e re-renderiza o componente com o estado atualizado."
                    )
                    questionsBatch.append(fallbackQuestion)
                }
            }

            return questionsBatch
            
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
