//
//  QuestionValidator.swift
//  SwiftStudyCoach
//
//  Plano V3 3.1 — aplicado a TODA questão (quiz e análise de código) antes
//  de persistir no pool. Duas responsabilidades separadas:
//
//  - Sanitização: corrige silenciosamente resíduos de formatação que o
//    modelo às vezes deixa (cercas de código, rótulos tipo "PERGUNTA:",
//    prefixos de enumeração nas alternativas).
//  - Validação: rejeita questões estruturalmente quebradas (opções faltando
//    ou duplicadas, índice correto fora do range, enunciado curto/cortado)
//    ou que são, na prática, o fallback genérico de StudyGenerator — esse
//    fallback nunca deve entrar no pool.
//
//  Política de quem chama: 1 regeneração se a questão falhar a validação;
//  se a regeneração também falhar, descarta (o top-up da Fase 4 repõe).
//

import Foundation

enum QuestionValidator {

    // MARK: - Sanitização

    /// Remove resíduos de formatação comuns em respostas de modelo — cercas
    /// de código, rótulos que vazaram do prompt, prefixos de enumeração nas
    /// alternativas — e normaliza espaços nas pontas.
    static func sanitizeText(_ raw: String) -> String {
        var text = raw

        let residues = [
            "```json", "```swift", "```",
            "PERGUNTA:", "RESPOSTA CORRETA:", "CODIGO:", "CÓDIGO:",
        ]
        for residue in residues {
            text = text.replacingOccurrences(of: residue, with: "")
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Prefixos de enumeração no início da string: "1) ", "2. ", "a) ",
        // "Alternativa 1:", "Alternativa A:" — só no INÍCIO, pra não mexer
        // em números que façam parte do conteúdo real.
        let enumerationPatterns = [
            #"^\d+[\)\.]\s+"#,
            #"^[a-dA-D][\)\.]\s+"#,
            #"^Alternativa\s+\S+\s*[:\-]\s*"#,
        ]
        for pattern in enumerationPatterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                text.removeSubrange(range)
                break
            }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sanitize(_ question: QuizQuestion) -> QuizQuestion {
        QuizQuestion(
            difficulty: question.difficulty,
            question: sanitizeText(question.question),
            options: question.options.map(sanitizeText),
            correctOptionIndex: question.correctOptionIndex,
            explanation: sanitizeText(question.explanation)
        )
    }

    static func sanitize(_ question: CodeAnalysisQuestion) -> CodeAnalysisQuestion {
        CodeAnalysisQuestion(
            codeSnippet: question.codeSnippet.trimmingCharacters(in: .whitespacesAndNewlines),
            question: sanitizeText(question.question),
            options: question.options.map(sanitizeText),
            correctOptionIndex: question.correctOptionIndex,
            explanation: sanitizeText(question.explanation)
        )
    }

    // MARK: - Validação

    /// Marcadores fixos usados pelos fallbacks genéricos em StudyGenerator
    /// (formatHardQuestion / formatCodeAnalysisQuestion) — se a explicação
    /// bater com um destes, é o fallback, e fallback nunca entra no pool.
    private static let fallbackExplanationMarkers = [
        "gerada pelo MLX com base na documentação oficial de",
        "gerada localmente pelo MLX com suporte RAG da documentação oficial de",
    ]

    private static func isGenericFallback(explanation: String) -> Bool {
        fallbackExplanationMarkers.contains { explanation.contains($0) }
    }

    /// Enunciado com tamanho mínimo e sem sinal de corte no meio da frase
    /// (reaproveita a mesma heurística barata de StudyGenerator.looksTruncated,
    /// adaptada pra texto de pergunta em vez de código).
    private static func looksCutOff(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 15 else { return true }
        let badEndings: Set<Character> = [",", ":", ";", "-", "(", "["]
        guard let last = trimmed.last else { return true }
        return badEndings.contains(last)
    }

    private static func optionsAreValid(_ options: [String], expectedCount: Int) -> Bool {
        guard options.count == expectedCount else { return false }
        let trimmed = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard trimmed.allSatisfy({ !$0.isEmpty }) else { return false }
        let normalized = trimmed.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
        return Set(normalized).count == expectedCount // todas distintas entre si
    }

    static func isValid(_ question: QuizQuestion) -> Bool {
        guard optionsAreValid(question.options, expectedCount: 4) else { return false }
        guard (0..<4).contains(question.correctOptionIndex) else { return false }
        guard !looksCutOff(question.question) else { return false }
        guard !isGenericFallback(explanation: question.explanation) else { return false }
        return true
    }

    static func isValid(_ question: CodeAnalysisQuestion) -> Bool {
        guard optionsAreValid(question.options, expectedCount: 5) else { return false }
        guard (0..<5).contains(question.correctOptionIndex) else { return false }
        guard !looksCutOff(question.question) else { return false }
        guard !question.codeSnippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !isGenericFallback(explanation: question.explanation) else { return false }
        return true
    }

    // MARK: - Processamento de lote (sanitiza → valida → 1 regeneração → descarta)

    /// Sanitiza e valida um lote de QuizQuestion. Pra cada item inválido,
    /// tenta UMA regeneração via `regenerateOne`; se a regeneração também
    /// falhar (erro ou continua inválida), o item é descartado — nunca
    /// entra no pool. Pode devolver menos itens que `raw.count`.
    ///
    /// `topic`/`taskType` (PLAN_00) são só para instrumentação: ao final do
    /// lote, registra QUANTAS regenerações (`retryCount`) foram disparadas
    /// nesta chamada — pura leitura/contagem, a lógica de validação e
    /// regeneração em si não muda em nada.
    static func processQuizBatch(
        _ raw: [QuizQuestion],
        topic: String = "",
        taskType: GenerationMetrics.TaskType? = nil,
        regenerateOne: () async throws -> QuizQuestion?
    ) async -> [QuizQuestion] {
        var result: [QuizQuestion] = []
        var retryCount = 0
        let start = Date()
        for item in raw {
            let cleaned = sanitize(item)
            if isValid(cleaned) {
                result.append(cleaned)
                continue
            }
            print("⚠️ QuestionValidator: questão de quiz inválida, tentando 1 regeneração...")
            retryCount += 1
            if let retry = try? await regenerateOne() {
                let retryCleaned = sanitize(retry)
                if isValid(retryCleaned) {
                    result.append(retryCleaned)
                    continue
                }
            }
            print("❌ QuestionValidator: questão de quiz descartada após regeneração falhar.")
        }
        if let taskType {
            let elapsedMs = Date().timeIntervalSince(start) * 1000
            Task {
                await GenerationMetricsStore.shared.record(
                    GenerationMetrics(
                        engine: .foundationModels,
                        taskType: taskType,
                        topic: topic,
                        modelID: "system",
                        totalTimeMs: elapsedMs,
                        retryCount: retryCount,
                        batchSize: raw.count
                    )
                )
            }
        }
        return result
    }

    /// Mesma política de `processQuizBatch`, pra CodeAnalysisQuestion.
    static func processCodeAnalysisBatch(
        _ raw: [CodeAnalysisQuestion],
        topic: String = "",
        taskType: GenerationMetrics.TaskType? = nil,
        regenerateOne: () async throws -> CodeAnalysisQuestion?
    ) async -> [CodeAnalysisQuestion] {
        var result: [CodeAnalysisQuestion] = []
        var retryCount = 0
        let start = Date()
        for item in raw {
            let cleaned = sanitize(item)
            if isValid(cleaned) {
                result.append(cleaned)
                continue
            }
            print("⚠️ QuestionValidator: questão de análise de código inválida, tentando 1 regeneração...")
            retryCount += 1
            if let retry = try? await regenerateOne() {
                let retryCleaned = sanitize(retry)
                if isValid(retryCleaned) {
                    result.append(retryCleaned)
                    continue
                }
            }
            print("❌ QuestionValidator: questão de análise de código descartada após regeneração falhar.")
        }
        if let taskType {
            let elapsedMs = Date().timeIntervalSince(start) * 1000
            Task {
                await GenerationMetricsStore.shared.record(
                    GenerationMetrics(
                        engine: .mlx,
                        taskType: taskType,
                        topic: topic,
                        modelID: MLXService.modelID,
                        totalTimeMs: elapsedMs,
                        retryCount: retryCount,
                        batchSize: raw.count
                    )
                )
            }
        }
        return result
    }
}
