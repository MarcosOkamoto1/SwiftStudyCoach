//
//  Persistence.swift
//  SwiftStudyCoach
//
//  Entidades SwiftData persistidas. Os @Generable em StudyModels.swift
//  (QuizQuestion, CodeAnalysisQuestion) são os DTOs de saída do Foundation
//  Models — as classes @Model abaixo é que ficam salvas em disco, com um
//  mapeamento simples campo a campo entre os dois.
//

import Foundation
import SwiftData

/// Versão do dataset de documentação usado para gerar o conteúdo.
/// Trocar esse valor invalida automaticamente todo o cache existente —
/// ver `TopicRepository.fetchOrCreate`.
enum DatasetVersion {
    // `var` (não `let`) de propósito: permite trocar em runtime a partir da
    // tela de teste (TopicRepositoryTestView) para validar a invalidação de
    // cache sem precisar recompilar o app.
    // v3: exemplo de código agora vem com walkthrough estruturado (gerado em
    // chamada dedicada) — bump invalida tópicos antigos sem walkthrough.
    // v4 (Plano V3): flashcards saíram do schema persistido, e o dataset
    // cresceu de 3 pra 21 tópicos com metadado de bloco — bump invalida os
    // 3 tópicos antigos (gerados sem essas mudanças) de uma vez.
    // v5 (Plano V4 Fase 3): chunks auditados contra a documentação oficial
    // (correções em Guard, Coleções, Property Observers, Protocolos e
    // Generics) — bump invalida tópicos gerados com o texto antigo.
    // v6 (Plano V5): dataset reduzido de 21 pra 3 tópicos (NavigationStack,
    // Property Wrappers, async/await) — bump limpa qualquer tópico dos 18
    // removidos que ainda esteja em cache.
    // v7 (Plano V5, hotfix pós-teste real): reset só do cache de conteúdo
    // gerado (resumo/quiz/exemplo/análise) SEM tocar no modelo MLX já
    // baixado — junta várias mudanças de geração testadas ao vivo: modelo
    // Qwen3-Coder-30B-A3B, dedup de geração concorrente, truncamento
    // corrigido no exemplo de código E na análise de código, quebra de
    // linha garantida no codeSnippet/code, e exemplos priorizando uso
    // prático em vez de reimplementar o mecanismo do zero.
    static var current = "apple-docs-v7"
}

@Model
final class StudyTopic {
    var name: String                   // ex: "Optionals"
    var summary: String
    var keyPoints: [String]
    var codeExample: String

    // Walkthrough do exemplo de código (arrays paralelos: snippet[i] é
    // explicado por explanation[i]). Arrays de String com default = migração
    // leve automática no SwiftData, sem precisar de entidade nova.
    var walkthroughSnippets: [String] = []
    var walkthroughExplanations: [String] = []

    var createdAt: Date
    var sourceDatasetVersion: String   // invalida cache antigo quando muda
    var isGeneratingPool: Bool = false // evita disparar geração em background em duplicidade

    @Relationship(deleteRule: .cascade)
    var quizPool: [PersistedQuizQuestion]

    @Relationship(deleteRule: .cascade)
    var codeAnalysisPool: [PersistedCodeAnalysisQuestion]

    init(
        name: String,
        summary: String,
        keyPoints: [String],
        codeExample: String,
        walkthroughSnippets: [String] = [],
        walkthroughExplanations: [String] = []
    ) {
        self.name = name
        self.summary = summary
        self.keyPoints = keyPoints
        self.codeExample = codeExample
        self.walkthroughSnippets = walkthroughSnippets
        self.walkthroughExplanations = walkthroughExplanations
        self.createdAt = .now
        self.sourceDatasetVersion = DatasetVersion.current
        self.isGeneratingPool = false
        self.quizPool = []
        self.codeAnalysisPool = []
    }
}

@Model
final class PersistedQuizQuestion {
    var difficulty: String   // "easy" | "medium" | "hard"
    var question: String
    var options: [String]
    var correctOptionIndex: Int
    var explanation: String

    init(difficulty: String, question: String, options: [String], correctOptionIndex: Int, explanation: String) {
        self.difficulty = difficulty
        self.question = question
        self.options = options
        self.correctOptionIndex = correctOptionIndex
        self.explanation = explanation
    }

    convenience init(from dto: QuizQuestion) {
        self.init(
            difficulty: dto.difficulty.rawValue,
            question: dto.question,
            options: dto.options,
            correctOptionIndex: dto.correctOptionIndex,
            explanation: dto.explanation
        )
    }
}

@Model
final class PersistedCodeAnalysisQuestion {
    var codeSnippet: String
    var question: String
    var options: [String]    // exatamente 5
    var correctOptionIndex: Int
    var explanation: String

    init(codeSnippet: String, question: String, options: [String], correctOptionIndex: Int, explanation: String) {
        self.codeSnippet = codeSnippet
        self.question = question
        self.options = options
        self.correctOptionIndex = correctOptionIndex
        self.explanation = explanation
    }

    convenience init(from dto: CodeAnalysisQuestion) {
        self.init(
            codeSnippet: dto.codeSnippet,
            question: dto.question,
            options: dto.options,
            correctOptionIndex: dto.correctOptionIndex,
            explanation: dto.explanation
        )
    }
}
