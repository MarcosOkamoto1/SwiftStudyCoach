//
//  StudySessionResult.swift
//  SwiftStudyCoach
//
//  Tipos compartilhados entre QuizView, CodeAnalysisView e StudyResultView
//  pra carregar o desempenho do usuário numa sessão até a tela final.
//

import Foundation

/// Resultado de uma pergunta respondida (quiz ou análise de código),
/// genérico o bastante pra servir aos dois tipos de pergunta.
struct AnsweredQuestion: Identifiable {
    let id = UUID()
    let questionText: String
    let selectedOptionIndex: Int
    let correctOptionIndex: Int
    let explanation: String
    let difficulty: Difficulty?  // nil para análise de código (não tem dificuldade fixa)

    var isCorrect: Bool { selectedOptionIndex == correctOptionIndex }
}

/// Resumo textual usado como prompt pra `StudyGenerator.generateFeedback` —
/// lista o que foi acertado/errado sem expor toda a UI ao gerador.
extension Array where Element == AnsweredQuestion {
    var scoreText: String {
        let correct = filter(\.isCorrect).count
        return "\(correct) de \(count) corretas"
    }

    func performanceSummary(sectionLabel: String) -> String {
        guard !isEmpty else { return "" }
        var lines = ["\(sectionLabel): \(scoreText)"]
        for item in self {
            let status = item.isCorrect ? "ACERTOU" : "ERROU"
            lines.append("- [\(status)] \(item.questionText)")
        }
        return lines.joined(separator: "\n")
    }
}
