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
    @Guide(description: "Resumo do tópico de Swift em português, entre 180 e 280 palavras, para um dev iniciante/intermediário. Cubra TODOS os conceitos centrais distintos presentes no contexto — não escolha só um e ignore os outros. Se o contexto distinguir uma abordagem antiga de uma moderna/recomendada, explique as duas e deixe claro qual é a recomendada hoje. Baseie-se apenas no contexto fornecido, nunca invente comportamento de API.")
    var summary: String

    @Guide(description: "De 3 a 5 pontos-chave do tópico, cada um em uma frase curta, cobrindo conceitos DIFERENTES entre si (não repita a mesma ideia com outras palavras)")
    var keyPoints: [String]
}

/// Exemplo de código "explicado" — gerado numa chamada DEDICADA (ver
/// StudyGenerator.generateCodeExample), separada do resumo. Dois motivos:
/// 1. Quando codeExample era o último campo do TopicSummary, era o primeiro
///    a ser truncado quando o orçamento de tokens acabava.
/// 2. O schema FORÇA a explicação passo a passo (walkthrough) — instrução de
///    prompt pedindo "comente o código" era frequentemente ignorada.
@Generable
struct ExplainedCodeExample {
    @Guide(description: "Código Swift completo e compilável do exemplo, 5-15 linhas, SEM comentários (a explicação vai no walkthrough). CADA linha do código separada por uma quebra de linha real (\\n) — nunca uma única linha corrida sem formatação.")
    var code: String

    @Guide(description: "Explicação passo a passo do código acima: entre 3 e 5 passos, um por bloco relevante, na ordem em que aparecem, em português, como se ensinasse alguém vendo aquilo pela primeira vez")
    var walkthrough: [CodeStep]
}

@Generable
struct CodeStep {
    @Guide(description: "O trecho exato do código sendo explicado (1-3 linhas, copiado literalmente do campo code)")
    var snippet: String

    @Guide(description: "Explicação didática em português do que esse trecho faz e por quê")
    var explanation: String
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

    @Guide(description: "Exatamente 4 alternativas de resposta, plausíveis entre si, em português. SEM prefixo de letra ou número (nunca 'A)', 'B.', '1)' etc.) — só o texto puro da alternativa, a interface já numera sozinha.")
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
    @Guide(description: "Trecho de código Swift (5-15 linhas) para o usuário analisar. CADA linha separada por uma quebra de linha real (\\n) — nunca uma única linha corrida sem formatação.")
    var codeSnippet: String

    @Guide(description: "Pergunta sobre o comportamento, saída ou problema do trecho de código acima")
    var question: String

    @Guide(description: "Exatamente 5 alternativas de resposta, plausíveis entre si, em português. SEM prefixo de letra ou número (nunca 'A)', 'B.', '1)' etc.) — só o texto puro da alternativa, a interface já numera sozinha.")
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

/// Feedback gerado ao final de uma sessão de estudo (quiz + análise de
/// código), usado pela tela de resultado (Parte 7). Implementação mínima da
/// Parte 6 — só o necessário pra tela final funcionar de ponta a ponta.
@Generable
struct StudyFeedback {
    @Guide(description: "2 a 3 pontos fortes demonstrados pelo usuário nesta sessão, em português, específicos aos acertos observados (não genéricos)")
    var strengths: [String]

    @Guide(description: "2 a 3 pontos fracos ou temas pra revisar, em português, baseados especificamente nos erros cometidos nesta sessão")
    var weaknesses: [String]

    @Guide(description: "Nome curto de um próximo tópico de Swift recomendado, coerente com os erros cometidos")
    var recommendedNextTopic: String

    @Guide(description: "Mensagem geral curta e encorajadora sobre o desempenho, em português, 1-2 frases")
    var overallMessage: String
}
