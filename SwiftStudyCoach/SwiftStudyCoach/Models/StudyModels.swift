//
//  StudyModels.swift
//  SwiftStudyCoach
//
//  Schema de saída estruturada usado pelo Foundation Models framework.
//  Cada @Generable vira, na prática, um contrato: o modelo é obrigado
//  a devolver dados nesse formato (nada de parsear texto livre).
//

import FoundationModels

// MARK: - Etapa de hoje (04/08): só o resumo, pra validar o pipeline básico.
// As outras structs (Flashcard, QuizQuestion, CodeAnalysisQuestion, StudyFeedback)
// entram nos próximos dias — deixei comentadas como referência do que vem a seguir.

@Generable
struct TopicSummary {
    @Guide(description: "Resumo do tópico de Swift em português, entre 100 e 150 palavras, para um dev iniciante/intermediário. Baseie-se apenas no contexto fornecido, nunca invente comportamento de API.")
    var summary: String

    @Guide(description: "De 2 a 3 pontos-chave do tópico, cada um em uma frase curta")
    var keyPoints: [String]

    @Guide(description: "Um exemplo de código curto (5-15 linhas), comentado, que ilustra o conceito principal")
    var codeExample: String
}

/*
 Próximos passos (referência, não implementar ainda):

 @Generable
 struct Flashcard {
     var question: String
     var answer: String
 }

 @Generable
 enum Difficulty {
     case easy, medium, hard
 }

 @Generable
 struct QuizQuestion {
     var difficulty: Difficulty
     var question: String
     @Guide(description: "Exatamente 4 alternativas")
     var options: [String]
     var correctOptionIndex: Int
     var explanation: String
 }

 @Generable
 struct CodeAnalysisQuestion {
     var codeSnippet: String
     var question: String
     @Guide(description: "Exatamente 5 alternativas")
     var options: [String]
     var correctOptionIndex: Int
     var explanation: String
 }

 @Generable
 struct StudyFeedback {
     var strengths: [String]
     var weaknesses: [String]
     var recommendedNextTopic: String
     var overallMessage: String
 }
 */
