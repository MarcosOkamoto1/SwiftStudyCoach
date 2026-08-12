//
//  QuestionValidatorTests.swift
//  SwiftStudyCoachTests
//
//  Unit tests for QuestionValidator.sanitizeText, sanitize, and isValid
//  covering formatters residues, enumeration patterns, and validation rules.
//

import XCTest
@testable import SwiftStudyCoach

final class QuestionValidatorTests: XCTestCase {

    // MARK: - sanitizeText Tests

    func testSanitizeRemovesCodeFences() {
        XCTAssertEqual(QuestionValidator.sanitizeText("```swift\nlet x = 1\n```"), "let x = 1")
        XCTAssertEqual(QuestionValidator.sanitizeText("```json\n{}\n```"), "{}")
        XCTAssertEqual(QuestionValidator.sanitizeText("```\ncode\n```"), "code")
    }

    func testSanitizeRemovesLabelResidue() {
        XCTAssertEqual(QuestionValidator.sanitizeText("PERGUNTA: Qual é a resposta?"), "Qual é a resposta?")
        XCTAssertEqual(QuestionValidator.sanitizeText("RESPOSTA CORRETA: @State"), "@State")
        XCTAssertEqual(QuestionValidator.sanitizeText("CODIGO: let x = 1"), "let x = 1")
        XCTAssertEqual(QuestionValidator.sanitizeText("CÓDIGO: var y = 2"), "var y = 2")
    }

    func testSanitizeRemovesEnumerationPatterns() {
        // Numeric patterns
        XCTAssertEqual(QuestionValidator.sanitizeText("1) Primeira opção"), "Primeira opção")
        XCTAssertEqual(QuestionValidator.sanitizeText("2. Segunda opção"), "Segunda opção")

        // Letter patterns
        XCTAssertEqual(QuestionValidator.sanitizeText("a) Alternativa A"), "Alternativa A")
        XCTAssertEqual(QuestionValidator.sanitizeText("b. Alternativa B"), "Alternativa B")
        XCTAssertEqual(QuestionValidator.sanitizeText("d) Quarta opção"), "Quarta opção")

        // "Alternativa X" patterns
        XCTAssertEqual(QuestionValidator.sanitizeText("Alternativa 1: Primeira"), "Primeira")
        XCTAssertEqual(QuestionValidator.sanitizeText("Alternativa A - Segunda"), "Segunda")
    }

    func testSanitizeTrimsWhitespace() {
        XCTAssertEqual(QuestionValidator.sanitizeText("   texto com espaços   "), "texto com espaços")
        XCTAssertEqual(QuestionValidator.sanitizeText("\n\ntexto\n\n"), "texto")
        XCTAssertEqual(QuestionValidator.sanitizeText("\ttabbed text\t"), "tabbed text")
    }

    func testSanitizeMultipleResidueLayers() {
        let input = "   ```swift\nPERGUNTA: 1) Qual é @State?\n```   "
        let expected = "Qual é @State?"
        XCTAssertEqual(QuestionValidator.sanitizeText(input), expected)
    }

    func testSanitizePreservesContentNumbers() {
        // Numbers in the middle of content should NOT be removed
        XCTAssertEqual(QuestionValidator.sanitizeText("Swift tem 3 níveis de access control"), "Swift tem 3 níveis de access control")
        XCTAssertEqual(QuestionValidator.sanitizeText("Os valores 1, 2 e 3 são importantes"), "Os valores 1, 2 e 3 são importantes")
    }

    // MARK: - QuizQuestion Sanitization Tests

    func testSanitizeQuizQuestion() {
        let original = QuizQuestion(
            difficulty: .medium,
            question: "```swift\n1) O que é @State?\n```",
            options: [
                "```\nOp 1\n```",
                "  2. Option 2  ",
                "PERGUNTA: Op 3",
                "Alternativa 4: Op 4"
            ],
            correctOptionIndex: 0,
            explanation: "```\n@State é um property wrapper.\n```"
        )

        let sanitized = QuestionValidator.sanitize(original)

        XCTAssertEqual(sanitized.question, "O que é @State?")
        XCTAssertEqual(sanitized.options[0], "Op 1")
        XCTAssertEqual(sanitized.options[1], "Option 2")
        XCTAssertEqual(sanitized.options[2], "Op 3")
        XCTAssertEqual(sanitized.options[3], "Op 4")
        XCTAssertEqual(sanitized.explanation, "@State é um property wrapper.")
        XCTAssertEqual(sanitized.difficulty, .medium)
        XCTAssertEqual(sanitized.correctOptionIndex, 0)
    }

    // MARK: - CodeAnalysisQuestion Sanitization Tests

    func testSanitizeCodeAnalysisQuestion() {
        let original = CodeAnalysisQuestion(
            codeSnippet: "   ```swift\nlet x = 1\n```   ",
            question: "PERGUNTA: O que acontece?",
            options: ["A", "B", "C", "D", "E"],
            correctOptionIndex: 2,
            explanation: "RESPOSTA CORRETA: Nada"
        )

        let sanitized = QuestionValidator.sanitize(original)

        XCTAssertEqual(sanitized.codeSnippet, "let x = 1")
        XCTAssertEqual(sanitized.question, "O que acontece?")
        XCTAssertEqual(sanitized.explanation, "Nada")
        XCTAssertEqual(sanitized.correctOptionIndex, 2)
    }

    // MARK: - isValid Tests for QuizQuestion

    func testValidQuizQuestion() {
        let validQuestion = QuizQuestion(
            difficulty: .easy,
            question: "What is a property wrapper in Swift?",
            options: ["A property wrapper", "A method", "A protocol", "A struct"],
            correctOptionIndex: 0,
            explanation: "Property wrappers are Swift constructs that add logic around properties."
        )
        XCTAssertTrue(QuestionValidator.isValid(validQuestion))
    }

    func testQuizInvalidWrongOptionCount() {
        var question = QuizQuestion(
            difficulty: .easy,
            question: "What is Swift?",
            options: ["A", "B", "C"],  // Only 3 instead of 4
            correctOptionIndex: 0,
            explanation: "Valid explanation here"
        )
        XCTAssertFalse(QuestionValidator.isValid(question))

        question = QuizQuestion(
            difficulty: .easy,
            question: "What is Swift?",
            options: ["A", "B", "C", "D", "E"],  // 5 instead of 4
            correctOptionIndex: 0,
            explanation: "Valid explanation"
        )
        XCTAssertFalse(QuestionValidator.isValid(question))
    }

    func testQuizInvalidCorrectOptionIndexOutOfRange() {
        let question = QuizQuestion(
            difficulty: .easy,
            question: "What is Swift?",
            options: ["A", "B", "C", "D"],
            correctOptionIndex: 4,  // Out of range [0, 3]
            explanation: "Valid explanation"
        )
        XCTAssertFalse(QuestionValidator.isValid(question))
    }

    func testQuizInvalidEmptyOptions() {
        let question = QuizQuestion(
            difficulty: .easy,
            question: "What is Swift?",
            options: ["A", "", "C", "D"],  // Empty option
            correctOptionIndex: 0,
            explanation: "Valid explanation"
        )
        XCTAssertFalse(QuestionValidator.isValid(question))
    }

    func testQuizInvalidDuplicateOptions() {
        let question = QuizQuestion(
            difficulty: .easy,
            question: "What is Swift?",
            options: ["Same", "Different", "Same", "Other"],  // Duplicate "Same"
            correctOptionIndex: 0,
            explanation: "Valid explanation"
        )
        XCTAssertFalse(QuestionValidator.isValid(question))
    }

    func testQuizInvalidDuplicateOptionsNormalized() {
        // Case insensitive, diacritic insensitive check
        let question = QuizQuestion(
            difficulty: .easy,
            question: "What is Swift?",
            options: ["Açúcar", "Different", "acucar", "Other"],  // Duplicates when normalized
            correctOptionIndex: 0,
            explanation: "Valid explanation"
        )
        XCTAssertFalse(QuestionValidator.isValid(question))
    }

    func testQuizInvalidTooShortQuestion() {
        let question = QuizQuestion(
            difficulty: .easy,
            question: "Short",  // Less than 15 chars
            options: ["A", "B", "C", "D"],
            correctOptionIndex: 0,
            explanation: "Valid explanation"
        )
        XCTAssertFalse(QuestionValidator.isValid(question))
    }

    func testQuizInvalidQuestionEndingWithBadCharacter() {
        // Question ends with suspicious character (looks cut off)
        let question = QuizQuestion(
            difficulty: .easy,
            question: "What is a property wrapper in",  // Ends with "in"
            options: ["A", "B", "C", "D"],
            correctOptionIndex: 0,
            explanation: "Valid explanation"
        )
        XCTAssertFalse(QuestionValidator.isValid(question))
    }

    func testQuizInvalidGenericFallbackExplanation() {
        let question = QuizQuestion(
            difficulty: .easy,
            question: "What is a property wrapper in Swift?",
            options: ["A", "B", "C", "D"],
            correctOptionIndex: 0,
            explanation: "Resposta gerada pelo MLX com base na documentação oficial de Swift"
        )
        XCTAssertFalse(QuestionValidator.isValid(question))

        let question2 = QuizQuestion(
            difficulty: .easy,
            question: "What is a property wrapper?",
            options: ["A", "B", "C", "D"],
            correctOptionIndex: 0,
            explanation: "Resposta gerada localmente pelo MLX com suporte RAG da documentação oficial de Swift"
        )
        XCTAssertFalse(QuestionValidator.isValid(question2))
    }

    // MARK: - isValid Tests for CodeAnalysisQuestion

    func testValidCodeAnalysisQuestion() {
        let validQuestion = CodeAnalysisQuestion(
            codeSnippet: "let x = 1\nprint(x)",
            question: "What does this code print?",
            options: ["1", "nil", "error", "2", "nothing"],
            correctOptionIndex: 0,
            explanation: "The code prints 1 to the console."
        )
        XCTAssertTrue(QuestionValidator.isValid(validQuestion))
    }

    func testCodeAnalysisInvalidWrongOptionCount() {
        let question = CodeAnalysisQuestion(
            codeSnippet: "let x = 1",
            question: "What is x?",
            options: ["1", "2", "3", "4"],  // Only 4 instead of 5
            correctOptionIndex: 0,
            explanation: "Valid explanation"
        )
        XCTAssertFalse(QuestionValidator.isValid(question))
    }

    func testCodeAnalysisInvalidCorrectOptionIndexOutOfRange() {
        let question = CodeAnalysisQuestion(
            codeSnippet: "let x = 1",
            question: "What is x?",
            options: ["1", "2", "3", "4", "5"],
            correctOptionIndex: 5,  // Out of range [0, 4]
            explanation: "Valid explanation"
        )
        XCTAssertFalse(QuestionValidator.isValid(question))
    }

    func testCodeAnalysisInvalidEmptyCodeSnippet() {
        let question = CodeAnalysisQuestion(
            codeSnippet: "   ",  // Only whitespace
            question: "What does this code do?",
            options: ["A", "B", "C", "D", "E"],
            correctOptionIndex: 0,
            explanation: "Valid explanation"
        )
        XCTAssertFalse(QuestionValidator.isValid(question))
    }

    func testCodeAnalysisInvalidGenericFallbackExplanation() {
        let question = CodeAnalysisQuestion(
            codeSnippet: "let x = 1",
            question: "What does this code do?",
            options: ["A", "B", "C", "D", "E"],
            correctOptionIndex: 0,
            explanation: "Resposta gerada pelo MLX com base na documentação oficial de Swift"
        )
        XCTAssertFalse(QuestionValidator.isValid(question))
    }

    func testCodeAnalysisInvalidTooShortQuestion() {
        let question = CodeAnalysisQuestion(
            codeSnippet: "let x = 1",
            question: "Short?",  // Less than 15 chars
            options: ["A", "B", "C", "D", "E"],
            correctOptionIndex: 0,
            explanation: "Valid explanation"
        )
        XCTAssertFalse(QuestionValidator.isValid(question))
    }

    func testCodeAnalysisInvalidQuestionEndingWithBadCharacter() {
        let question = CodeAnalysisQuestion(
            codeSnippet: "let x = 1",
            question: "What will this code",  // Ends with "code" which is fine, but let's test bad ending
            options: ["A", "B", "C", "D", "E"],
            correctOptionIndex: 0,
            explanation: "Valid explanation"
        )
        // This should be valid since "code" is not a bad ending
        XCTAssertTrue(QuestionValidator.isValid(question))

        // Now test actual bad ending
        let badQuestion = CodeAnalysisQuestion(
            codeSnippet: "let x = 1",
            question: "What about this:",  // Ends with ':'
            options: ["A", "B", "C", "D", "E"],
            correctOptionIndex: 0,
            explanation: "Valid explanation"
        )
        XCTAssertFalse(QuestionValidator.isValid(badQuestion))
    }

    // MARK: - Edge Cases

    func testSanitizeEmptyString() {
        XCTAssertEqual(QuestionValidator.sanitizeText(""), "")
    }

    func testSanitizeOnlyWhitespace() {
        XCTAssertEqual(QuestionValidator.sanitizeText("   \n\t  "), "")
    }

    func testValidQuestionWithPunctuation() {
        let question = QuizQuestion(
            difficulty: .easy,
            question: "What is a property wrapper? It's a useful feature!",  // Valid ending with !
            options: ["A", "B", "C", "D"],
            correctOptionIndex: 0,
            explanation: "A property wrapper is useful."
        )
        XCTAssertTrue(QuestionValidator.isValid(question))
    }

    func testValidQuestionWithAccents() {
        let question = QuizQuestion(
            difficulty: .easy,
            question: "O que é um property wrapper em Swift?",
            options: ["É uma feature", "É um método", "É um protocolo", "É um struct"],
            correctOptionIndex: 0,
            explanation: "Um property wrapper é uma construção do Swift."
        )
        XCTAssertTrue(QuestionValidator.isValid(question))
    }
}
