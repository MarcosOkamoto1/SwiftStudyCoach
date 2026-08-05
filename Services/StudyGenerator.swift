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
            // Fallback: sem contexto recuperado (ex: tópico não indexado ainda).
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

    /// Gera flashcards (pergunta curta + resposta objetiva) para um tópico,
    /// uma única vez — o resultado é persistido e não regenerado em visitas
    /// futuras (ver TopicRepository).
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

        Gere exatamente \(count) flashcards distintos sobre o tópico acima, cobrindo
        conceitos diferentes (evite flashcards repetidos ou que só reformulam a mesma ideia).
        """

        do {
            let response = try await session.respond(to: prompt, generating: FlashcardBatch.self)
            return response.content.flashcards
        } catch {
            throw StudyGeneratorError.generationFailed(error)
        }
    }

    /// Gera um lote de perguntas de quiz de UMA ÚNICA dificuldade por vez.
    /// Nunca pedimos um array grande (10-15) variando dificuldade numa
    /// chamada só — arrays grandes em @Generable ficam menos confiáveis e o
    /// contexto do modelo on-device é limitado. Cada chamada aqui deve pedir
    /// no máximo ~5 perguntas.
    func generateQuizBatch(topic: String, context: String, difficulty: Difficulty, count: Int) async throws -> [QuizQuestion] {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw StudyGeneratorError.modelUnavailable("Modelo indisponível neste device/simulador")
        }

        let instructions = """
        Você é um assistente educacional especializado em Swift e nos frameworks da Apple.
        Responda sempre em português.
        Baseie-se PRINCIPALMENTE no contexto de documentação fornecido.
        Gere perguntas de múltipla escolha com exatamente 4 alternativas, sendo
        apenas uma correta.
        """

        let session = LanguageModelSession(model: model, instructions: instructions)

        // Few-shot obrigatório: 1 exemplo de pergunta fácil + 1 de pergunta
        // difícil de verdade, para ancorar a escala de dificuldade real
        // (não só vocabulário difícil) — reduz variância entre gerações.
        let fewShot = """
        Exemplo de pergunta FÁCIL (dificuldade real baixa, não precisa de raciocínio):
        Pergunta: "O que a palavra-chave `if let` faz ao trabalhar com um Optional?"
        Alternativas: ["Desempacota o valor se ele não for nil, atribuindo a uma constante local", "Força o desempacotamento e trava o app se for nil", "Converte o Optional em um array", "Ignora o valor e sempre retorna nil"]
        Correta (índice): 0

        Exemplo de pergunta DIFÍCIL (de verdade — exige seguir o comportamento do código, não só decorar termos):
        Pergunta: "Dado o código abaixo, qual o valor final de `resultado`?
        ```
        var valores: [Int?] = [1, nil, 3]
        let resultado = valores.compactMap { $0 }.reduce(0, +)
        ```"
        Alternativas: ["4, porque compactMap remove os nils antes do reduce somar", "nil, porque a soma falha ao encontrar um nil", "3, porque reduce para no primeiro nil", "Erro de compilação, porque reduce não aceita array de Optionals"]
        Correta (índice): 0
        """

        let difficultyLabel: String
        switch difficulty {
        case .easy: difficultyLabel = "FÁCIL"
        case .medium: difficultyLabel = "MÉDIA"
        case .hard: difficultyLabel = "DIFÍCIL de verdade (exige raciocínio sobre o comportamento do código/conceito, não só vocabulário difícil)"
        }

        let prompt = """
        Tópico: \(topic)

        Contexto da documentação (use como base principal):
        \(context.isEmpty ? "Nenhum contexto adicional disponível — use conhecimento geral de Swift, com cautela." : context)

        \(fewShot)

        Gere exatamente \(count) perguntas de quiz de múltipla escolha NOVAS sobre o
        tópico acima (não repita as perguntas de exemplo). TODAS as \(count) perguntas
        devem ser de dificuldade \(difficultyLabel), com o campo difficulty igual a
        "\(difficulty.rawValue)". Cada pergunta deve ter exatamente 4 alternativas.
        """

        do {
            let response = try await session.respond(to: prompt, generating: QuizQuestionBatch.self)
            return response.content.questions
        } catch {
            throw StudyGeneratorError.generationFailed(error)
        }
    }

    /// Gera um lote de perguntas de análise de código (trecho + pergunta sobre
    /// comportamento/saída). Mesma lógica de lote pequeno + few-shot do quiz.
    func generateCodeAnalysisBatch(topic: String, context: String, count: Int) async throws -> [CodeAnalysisQuestion] {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw StudyGeneratorError.modelUnavailable("Modelo indisponível neste device/simulador")
        }

        let instructions = """
        Você é um assistente educacional especializado em Swift e nos frameworks da Apple.
        Responda sempre em português.
        Baseie-se PRINCIPALMENTE no contexto de documentação fornecido.
        Gere perguntas de análise de código: um trecho de código Swift seguido de
        uma pergunta de múltipla escolha com exatamente 5 alternativas, sendo
        apenas uma correta.
        """

        let session = LanguageModelSession(model: model, instructions: instructions)

        let fewShot = """
        Exemplo de pergunta FÁCIL de análise de código:
        Código:
        ```
        let nome: String? = "Ana"
        print(nome ?? "desconhecido")
        ```
        Pergunta: "O que é impresso no console?"
        Alternativas: ["Ana", "desconhecido", "nil", "Optional(\\"Ana\\")", "Erro de compilação"]
        Correta (índice): 0

        Exemplo de pergunta DIFÍCIL de verdade de análise de código:
        Código:
        ```
        func dobra(_ valores: inout [Int]) {
            for i in 0..<valores.count {
                valores[i] *= 2
            }
        }
        var numeros = [1, 2, 3]
        dobra(&numeros)
        ```
        Pergunta: "Qual o valor final de `numeros` depois de chamar `dobra`?"
        Alternativas: ["[2, 4, 6], porque inout modifica o array original in-place", "[1, 2, 3], porque arrays são passados por valor e a função não afeta o original", "Erro de compilação, porque arrays não podem ser inout", "[2, 4, 6, 1, 2, 3], porque o array é concatenado", "nil, porque a função não retorna nada"]
        Correta (índice): 0
        """

        let prompt = """
        Tópico: \(topic)

        Contexto da documentação (use como base principal):
        \(context.isEmpty ? "Nenhum contexto adicional disponível — use conhecimento geral de Swift, com cautela." : context)

        \(fewShot)

        Gere exatamente \(count) perguntas de análise de código NOVAS sobre o tópico
        acima (não repita os exemplos). Cada uma com um trecho de código diferente
        (5-15 linhas) e exatamente 5 alternativas de resposta.
        """

        do {
            let response = try await session.respond(to: prompt, generating: CodeAnalysisBatch.self)
            return response.content.questions
        } catch {
            throw StudyGeneratorError.generationFailed(error)
        }
    }
}
