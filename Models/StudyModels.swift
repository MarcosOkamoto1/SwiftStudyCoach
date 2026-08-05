//
//  StudyModels.swift
//  SwiftStudyCoach
//
//  Schema de saída estruturada usado pelo Foundation Models framework.
//  Cada @Generable vira, na prática, um contrato: o modelo é obrigado
//  a devolver dados nesse formato (nada de parsear texto livre).
//
//  Os "Batch" existem porque pedir um array grande de structs complexas
//  numa chamada só ao modelo on-device é menos confiável — por isso cada
//  batch tem seu container próprio, gerado em lotes pequenos (ver
//  StudyGenerator.generateQuizBatch / generateCodeAnalysisBatch).
//

import FoundationModels

@Generable
struct TopicSummary {
    @Guide(description: "Resumo do tópico de Swift em português, entre 100 e 150 palavras, para um dev iniciante/intermediário. Baseie-se apenas no contexto fornecido, nunca invente comportamento de API.")
    var summary: String

    @Guide(description: "De 2 a 3 pontos-chave do tópico, cada um em uma frase curta")
    var keyPoints: [String]

    @Guide(description: "Um exemplo de código curto (5-15 linhas), comentado, que ilustra o conceito principal")
    var codeExample: String
}

@Generable
struct Flashcard {
    @Guide(description: "Pergunta curta e objetiva sobre um conceito do tópico")
    var question: String

    @Guide(description: "Resposta objetiva e direta à pergunta, 1-2 frases")
    var answer: String
}

@Generable
struct FlashcardBatch {
    var flashcards: [Flashcard]
}

@Generable
enum Difficulty: String, CaseIterable {
    case easy
    case medium
    case hard
}

@Generable
struct QuizQuestion {
    var difficulty: Difficulty

    @Guide(description: "Pergunta de múltipla escolha em português sobre o tópico, no nível de dificuldade indicado. Dificuldade real deve vir do raciocínio exigido, não só do vocabulário usado.")
    var question: String

    @Guide(description: "Exatamente 4 alternativas de resposta, plausíveis entre si, em português")
    var options: [String]

    @Guide(description: "Índice (0 a 3) da alternativa correta dentro de options")
    var correctOptionIndex: Int

    @Guide(description: "Explicação breve de por que a alternativa correta está certa e as outras não")
    var explanation: String
}

@Generable
struct QuizQuestionBatch {
    var questions: [QuizQuestion]
}

@Generable
struct CodeAnalysisQuestion {
    @Guide(description: "Trecho de código Swift (5-15 linhas) para o usuário analisar")
    var codeSnippet: String

    @Guide(description: "Pergunta sobre o comportamento, saída ou problema do trecho de código acima")
    var question: String

    @Guide(description: "Exatamente 5 alternativas de resposta, plausíveis entre si, em português")
    var options: [String]

    @Guide(description: "Índice (0 a 4) da alternativa correta dentro de options")
    var correctOptionIndex: Int

    @Guide(description: "Explicação breve de por que a alternativa correta está certa e as outras não")
    var explanation: String
}

@Generable
struct CodeAnalysisBatch {
    var questions: [CodeAnalysisQuestion]
}

/*
 Próximos passos (referência, não implementar ainda):

 @Generable
 struct StudyFeedback {
     var strengths: [String]
     var weaknesses: [String]
     var recommendedNextTopic: String
     var overallMessage: String
 }
 */
