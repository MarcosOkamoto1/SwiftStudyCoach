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

        // Orçamento generoso de tokens: resumo (~100-150 palavras) + 2-3
        // pontos-chave + exemplo de código (5-15 linhas comentado) cabem
        // folgados aqui. Como codeExample é o último campo gerado, é o mais
        // afetado quando o orçamento padrão do framework não é suficiente.
        let options = GenerationOptions(maximumResponseTokens: 900)

        do {
            let response = try await session.respond(
                to: prompt,
                generating: TopicSummary.self,
                options: options
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

        // Defensivo: mesmo teto generoso do resumo, para evitar truncamento
        // quando `count` for alto e a resposta ficar longa.
        let options = GenerationOptions(maximumResponseTokens: 600)

        do {
            let response = try await session.respond(to: prompt, generating: FlashcardBatch.self, options: options)
            return response.content.flashcards
        } catch {
            throw StudyGeneratorError.generationFailed(error)
        }
    }

    /// Gera perguntas de quiz. Se for Fácil/Média usa Foundation Model; se for Difícil puxa o MLX!
    func generateQuizBatch(topic: String, context: String, difficulty: Difficulty, count: Int) async throws -> [QuizQuestion] {
        
        // 🔀 SE FOR DIFÍCIL: MLX gera o rascunho (texto livre), Foundation Models
        // formata no schema QuizQuestion com alternativas reais baseadas no rascunho.
        if difficulty == .hard {
            try await MLXService.shared.loadModel()

            let ragContext = (try? await documentIndex.retrieveContext(for: topic, topK: 1)) ?? ""

            // Respeita `count`: gera UM item por vez (rascunho MLX + formatação
            // Foundation Models) em loop sequencial, em vez de sempre devolver
            // uma única pergunta. Ver generateSingleHardQuestion abaixo.
            var results: [QuizQuestion] = []
            for _ in 0..<count {
                let question = try await generateSingleHardQuestion(topic: topic, ragContext: ragContext, difficulty: difficulty)
                results.append(question)
            }
            return results
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

        // Defensivo: mesmo teto generoso do resumo, para evitar truncamento
        // quando `count` for alto e a resposta ficar longa.
        let options = GenerationOptions(maximumResponseTokens: 600)

        do {
            let response = try await session.respond(to: prompt, generating: QuizQuestionBatch.self, options: options)
            return response.content.questions
        } catch {
            throw StudyGeneratorError.generationFailed(error)
        }
    }

    /// Extrai a lógica de UMA pergunta difícil (rascunho MLX + formatação FM)
    /// pra uma função separada, chamada em loop por generateQuizBatch — assim
    /// o parâmetro `count` é respeitado em vez de sempre gerar 1 item.
    private func generateSingleHardQuestion(topic: String, ragContext: String, difficulty: Difficulty) async throws -> QuizQuestion {
        let mlxPrompt = """
        Você é um especialista em Swift. Crie UMA pergunta técnica de nível avançado sobre '\(topic)'.
        Contexto oficial: \(ragContext)

        Formato da resposta (texto puro, sem markdown):
        PERGUNTA: <a pergunta>
        RESPOSTA CORRETA: <explicação do comportamento/resposta certa, 1-2 frases>
        POR QUE OUTRAS RESPOSTAS PARECEM CERTAS MAS NÃO SÃO: <1-2 frases de erros comuns/conceitos que confundem>
        """

        let draft = try await MLXService.shared.generateQuestionDraft(
            systemPrompt: "Você é um especialista em Swift. Gere uma pergunta técnica difícil sobre um conceito da linguagem, em texto puro.",
            promptContext: mlxPrompt
        )

        let cleanDraft = draft
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```swift", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // ⚠️ Fallback genérico — usado APENAS como último recurso, se o
        // Foundation Models estiver indisponível ou falhar ao formatar.
        let fallbackQuestion = QuizQuestion(
            difficulty: difficulty,
            question: cleanDraft.isEmpty ? "Qual é o comportamento esperado ao trabalhar com concorrência avançada em \(topic)?" : cleanDraft,
            options: [
                "Executa com sucesso garantindo o isolamento de estado do ator",
                "Gera um erro de compilação por violação de regras de Concurrency",
                "Provoca uma condição de corrida (data race) em tempo de execução",
                "Causa um vazamento de memória devido a referência circular"
            ],
            correctOptionIndex: 0,
            explanation: "Pergunta avançada gerada pelo MLX com base na documentação oficial de \(topic)."
        )

        let model = SystemLanguageModel.default
        guard !cleanDraft.isEmpty, case .available = model.availability else {
            print("⚠️ Rascunho vazio ou Foundation Models indisponível — usando fallback genérico")
            return fallbackQuestion
        }

        let formatterInstructions = """
        Você recebe um rascunho de pergunta técnica de Swift, já com a resposta correta indicada.
        Sua tarefa é reformatar isso em uma pergunta de múltipla escolha com exatamente 4 alternativas plausíveis,
        sendo apenas uma correta — baseada fielmente no rascunho fornecido, sem inventar informação nova.
        Responda sempre em português.
        """

        let formatterSession = LanguageModelSession(model: model, instructions: formatterInstructions)

        let formatterPrompt = """
        Rascunho gerado por outro modelo:
        \(cleanDraft)

        Reformate esse rascunho em uma pergunta de múltipla escolha de dificuldade \(difficulty.rawValue),
        com 4 alternativas plausíveis (não óbvias) e a alternativa correta identificada.
        """

        do {
            let formatted = try await formatterSession.respond(to: formatterPrompt, generating: QuizQuestion.self)
            return formatted.content
        } catch {
            print("⚠️ Foundation Models falhou ao formatar rascunho do MLX: \(error)")
            return fallbackQuestion
        }
    }

    /// Gera um lote de perguntas de análise de código (100% gerenciado pelo MLX de forma estruturada)
    func generateCodeAnalysisBatch(topic: String, context: String, count: Int) async throws -> [CodeAnalysisQuestion] {
        try await MLXService.shared.loadModel()

        let ragContext = (try? await documentIndex.retrieveContext(for: topic, topK: 1)) ?? ""

        // Respeita `count`: gera UM item por vez (rascunho MLX + formatação
        // Foundation Models) em loop sequencial, em vez de sempre devolver
        // uma única pergunta. Ver generateSingleCodeAnalysisQuestion abaixo.
        var results: [CodeAnalysisQuestion] = []
        for _ in 0..<count {
            let question = try await generateSingleCodeAnalysisQuestion(topic: topic, ragContext: ragContext)
            results.append(question)
        }
        return results
    }

    /// Extrai a lógica de UMA análise de código (rascunho MLX + formatação FM)
    /// pra uma função separada, chamada em loop por generateCodeAnalysisBatch —
    /// assim o parâmetro `count` é respeitado em vez de sempre gerar 1 item.
    private func generateSingleCodeAnalysisQuestion(topic: String, ragContext: String) async throws -> CodeAnalysisQuestion {
        let prompt = """
        Você é um especialista em Swift. Escreva um trecho de código Swift limpo de 6 a 10 linhas sobre '\(topic)' e explique seu comportamento.

        [Contexto RAG]:
        \(ragContext.isEmpty ? "Conhecimento geral sobre Swift e Apple Frameworks." : ragContext)

        Formato da resposta (texto puro, sem markdown, sem JSON):
        CODIGO:
        <o trecho de código Swift>
        COMPORTAMENTO ESPERADO: <o que o código faz / resultado ao executar, 1-2 frases>
        POR QUE OUTRAS RESPOSTAS PARECEM CERTAS MAS NÃO SÃO: <1-2 frases de erros comuns/conceitos que confundem>
        """

        do {
            let rawDraft = try await MLXService.shared.generateQuestionDraft(
                systemPrompt: "Você é um especialista em Swift. Gere um trecho de código e uma pergunta de análise sobre seu comportamento, em texto puro.",
                promptContext: prompt
            )

            // Higienização do rascunho (código + explicação do comportamento)
            let cleanDraft = rawDraft
                .replacingOccurrences(of: "```swift", with: "")
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Tenta isolar só o código pro snippet do fallback
            var fallbackSnippet = cleanDraft
                .components(separatedBy: "COMPORTAMENTO ESPERADO:").first?
                .replacingOccurrences(of: "CODIGO:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if fallbackSnippet.isEmpty {
                fallbackSnippet = """
                import SwiftUI

                struct \(topic.replacingOccurrences(of: " ", with: ""))DemoView: View {
                    @State private var isActive: Bool = false

                    var body: some View {
                        Text("Demonstração de \(topic)")
                    }
                }
                """
            }

            // ⚠️ Fallback genérico — usado APENAS como último recurso, se o
            // Foundation Models estiver indisponível ou falhar ao formatar.
            let fallbackQuestion = CodeAnalysisQuestion(
                codeSnippet: fallbackSnippet,
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

            let model = SystemLanguageModel.default
            guard !cleanDraft.isEmpty, case .available = model.availability else {
                print("⚠️ Rascunho vazio ou Foundation Models indisponível — usando fallback genérico")
                return fallbackQuestion
            }

            let formatterInstructions = """
            Você recebe um rascunho com um trecho de código Swift e a explicação do comportamento esperado dele.
            Sua tarefa é reformatar isso em uma pergunta de análise de código com exatamente 5 alternativas plausíveis,
            sendo apenas uma correta — baseada fielmente no rascunho fornecido, sem inventar informação nova.
            Preserve o código do rascunho exatamente como está no campo codeSnippet, sem a marcação 'CODIGO:'.
            Responda sempre em português.
            """

            let formatterSession = LanguageModelSession(model: model, instructions: formatterInstructions)

            let formatterPrompt = """
            Rascunho gerado por outro modelo:
            \(cleanDraft)

            Reformate esse rascunho em uma pergunta de análise de código sobre '\(topic)',
            com 5 alternativas plausíveis (não óbvias) e a alternativa correta identificada.
            """

            do {
                let formatted = try await formatterSession.respond(to: formatterPrompt, generating: CodeAnalysisQuestion.self)
                return formatted.content
            } catch {
                print("⚠️ Foundation Models falhou ao formatar rascunho do MLX: \(error)")
                return fallbackQuestion
            }
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
        
        // Defensivo: mesmo teto generoso do resumo, para evitar truncamento.
        let options = GenerationOptions(maximumResponseTokens: 600)

        do {
            let response = try await session.respond(to: prompt, generating: StudyFeedback.self, options: options)
            return response.content
        } catch {
            throw StudyGeneratorError.generationFailed(error)
        }
    }
}
