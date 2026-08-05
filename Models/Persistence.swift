//
//  Persistence.swift
//  SwiftStudyCoach
//
//  Entidades SwiftData persistidas. Os @Generable em StudyModels.swift
//  (Flashcard, QuizQuestion, CodeAnalysisQuestion) são os DTOs de saída
//  do Foundation Models — as classes @Model abaixo é que ficam salvas em
//  disco, com um mapeamento simples campo a campo entre os dois.
//

import Foundation
import SwiftData

/// Versão do dataset de documentação usado para gerar o conteúdo.
/// Trocar esse valor invalida automaticamente todo o cache existente —
/// ver `TopicRepository.fetchOrCreate`.
enum DatasetVersion {
    static let current = "placeholder-v1"  // trocar para "apple-docs-v1" quando substituir o conteúdo
}

@Model
final class StudyTopic {
    var name: String                   // ex: "Optionals"
    var summary: String
    var keyPoints: [String]
    var codeExample: String
    var createdAt: Date
    var sourceDatasetVersion: String   // invalida cache antigo quando muda
    var isGeneratingPool: Bool = false // evita disparar geração em background em duplicidade

    @Relationship(deleteRule: .cascade)
    var flashcards: [PersistedFlashcard]

    @Relationship(deleteRule: .cascade)
    var quizPool: [PersistedQuizQuestion]

    @Relationship(deleteRule: .cascade)
    var codeAnalysisPool: [PersistedCodeAnalysisQuestion]

    init(name: String, summary: String, keyPoints: [String], codeExample: String) {
        self.name = name
        self.summary = summary
        self.keyPoints = keyPoints
        self.codeExample = codeExample
        self.createdAt = .now
        self.sourceDatasetVersion = DatasetVersion.current
        self.isGeneratingPool = false
        self.flashcards = []
        self.quizPool = []
        self.codeAnalysisPool = []
    }
}

@Model
final class PersistedFlashcard {
    var question: String
    var answer: String

    init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }

    convenience init(from dto: Flashcard) {
        self.init(question: dto.question, answer: dto.answer)
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
