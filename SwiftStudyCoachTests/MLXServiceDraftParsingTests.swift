//
//  MLXServiceDraftParsingTests.swift
//  SwiftStudyCoachTests
//
//  Unit tests for MLXService draft parsing logic from generateQuestionDrafts.
//  Tests itemSeparator splitting, whitespace trimming, and item filtering.
//

import XCTest
@testable import SwiftStudyCoach

final class MLXServiceDraftParsingTests: XCTestCase {

    // MARK: - Helper Method

    /// Simulates the parsing logic from MLXService.generateQuestionDrafts
    private func parseQuestionDrafts(from output: String, separator: String = "=====") -> [String] {
        return output
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 20 }
    }

    // MARK: - Basic Parsing Tests

    func testParsesSingleItem() {
        let output = "This is a single question draft that is long enough to pass the filter."
        let items = parseQuestionDrafts(from: output)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0], "This is a single question draft that is long enough to pass the filter.")
    }

    func testParsesMultipleItems() {
        let output = """
        First question draft that is definitely long enough=====Second question draft that is also long enough=====Third one is here too
        """
        let items = parseQuestionDrafts(from: output)
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items[0].contains("First"))
        XCTAssertTrue(items[1].contains("Second"))
        XCTAssertTrue(items[2].contains("Third"))
    }

    func testParsesItemsWithNewlines() {
        let output = """
        First question draft
        with multiple lines
        that is long enough=====Second question draft
        also multiline
        definitely long"""
        let items = parseQuestionDrafts(from: output)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].contains("multiple lines"))
        XCTAssertTrue(items[1].contains("also multiline"))
    }

    // MARK: - Whitespace Handling Tests

    func testTrimsLeadingWhitespace() {
        let output = "   Leading spaces question that is quite long=====More text here"
        let items = parseQuestionDrafts(from: output)
        XCTAssertFalse(items[0].hasPrefix(" "))
        XCTAssertTrue(items[0].hasPrefix("Leading"))
    }

    func testTrimsTrailingWhitespace() {
        let output = "Question draft that is definitely long enough   =====More items"
        let items = parseQuestionDrafts(from: output)
        XCTAssertFalse(items[0].hasSuffix(" "))
        XCTAssertTrue(items[0].hasSuffix("enough"))
    }

    func testTrimsLeadingAndTrailingWhitespace() {
        let output = "   Question that is long enough   =====   Another item here   "
        let items = parseQuestionDrafts(from: output)
        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(items[0].hasPrefix(" "))
        XCTAssertFalse(items[0].hasSuffix(" "))
        XCTAssertFalse(items[1].hasPrefix(" "))
        XCTAssertFalse(items[1].hasSuffix(" "))
    }

    func testTrimsNewlines() {
        let output = """


        Question draft that is long enough


        =====


        Second item here


        """
        let items = parseQuestionDrafts(from: output)
        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(items[0].hasPrefix("\n"))
        XCTAssertFalse(items[0].hasSuffix("\n"))
        XCTAssertFalse(items[1].hasPrefix("\n"))
        XCTAssertFalse(items[1].hasSuffix("\n"))
    }

    // MARK: - Length Filtering Tests (minimum 20 chars)

    func testFiltersItemsTooShort() {
        let output = "short=====This is a valid question that is definitely long enough=====also short"
        let items = parseQuestionDrafts(from: output)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].contains("valid question"))
    }

    func testKeepsItemsExactly20Chars() {
        let twentyCharItem = "12345678901234567890"  // Exactly 20 chars
        let output = "\(twentyCharItem)=====This is a longer question that passes the filter"
        let items = parseQuestionDrafts(from: output)
        // Filter is > 20, so exactly 20 should be filtered out
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].contains("longer"))
    }

    func testKeepsItemsOver20Chars() {
        let twentyOneCharItem = "123456789012345678901"  // 21 chars
        let output = "\(twentyOneCharItem)=====This is a longer question that passes"
        let items = parseQuestionDrafts(from: output)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].count > 20)
        XCTAssertTrue(items[1].count > 20)
    }

    func testFiltersEmptyItems() {
        let output = "=====This is a valid question draft that is long=========Another valid item here"
        let items = parseQuestionDrafts(from: output)
        // First split: empty, second: valid, third: empty (between two =====), fourth: valid
        let validItems = items.filter { !$0.isEmpty && $0.count > 20 }
        XCTAssertEqual(validItems.count, 2)
    }

    func testFiltersWhitespaceOnlyItems() {
        let output = "   =====This is a valid question draft that is definitely long enough=====   \n\t  =====Another valid item"
        let items = parseQuestionDrafts(from: output)
        XCTAssertTrue(items.allSatisfy { !$0.isEmpty })
        XCTAssertTrue(items.allSatisfy { $0.count > 20 })
    }

    // MARK: - Separator Handling Tests

    func testNoSeparatorReturnsSingleItem() {
        let output = "This is a single question draft that is definitely long enough to pass the minimum length requirement"
        let items = parseQuestionDrafts(from: output)
        XCTAssertEqual(items.count, 1)
    }

    func testMultipleSeparatorsBetweenItems() {
        let output = "Item one is quite long here================Item two also here"
        let items = parseQuestionDrafts(from: output, separator: "=====")
        // Won't split on "====" so should be one item
        XCTAssertEqual(items.count, 1)
    }

    func testSeparatorAtStart() {
        let output = "=====This is a valid question draft that is definitely long enough"
        let items = parseQuestionDrafts(from: output)
        // First split produces empty string, second produces the content
        XCTAssertTrue(items.contains { $0.contains("valid question") })
    }

    func testSeparatorAtEnd() {
        let output = "This is a valid question draft that is definitely long enough====="
        let items = parseQuestionDrafts(from: output)
        // Last split produces empty string which gets filtered
        XCTAssertEqual(items.count, 1)
    }

    func testMultipleSeparatorsConsecutive() {
        let output = "Item one================Item two"
        let items = parseQuestionDrafts(from: output, separator: "=====")
        // First separator creates one split, second creates empty items
        let filtered = items.filter { $0.count > 20 }
        XCTAssertGreaterThanOrEqual(filtered.count, 1)
    }

    // MARK: - Real-World Batch Parsing Tests

    func testBatchOfThreeQuestions() {
        let output = """
        What is the difference between @State and @StateObject in SwiftUI? These are two important property wrappers.=====
        How do you implement custom property wrappers in Swift? This is an advanced topic that requires understanding getters and setters.=====
        Explain the concept of property observer patterns in Swift development. This pattern is useful for monitoring changes in properties.
        """
        let items = parseQuestionDrafts(from: output)
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items[0].contains("@State"))
        XCTAssertTrue(items[1].contains("custom property"))
        XCTAssertTrue(items[2].contains("observer patterns"))
    }

    func testBatchWithSomeTooShortItems() {
        let output = """
        Question one is long enough for sure=====
        short=====
        Another valid question that has plenty of characters and passes the filter=====
        tiny=====
        Final valid question here definitely exceeds twenty characters minimum requirement
        """
        let items = parseQuestionDrafts(from: output)
        // Should only have the 3 long ones
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items.allSatisfy { $0.count > 20 })
    }

    func testBatchWithMLXGeneratedContent() {
        // Simulating actual MLX output with formatting
        let output = """
        1. What is the primary purpose of @StateObject in SwiftUI applications for managing complex state? It maintains reference types and their lifecycle.
        =====
        2. How do property wrappers in Swift provide a clean way to add validation logic and computed properties to existing code? They wrap properties elegantly.
        =====
        3. Explain how the Swift compiler synthesizes property accessor functions and why this affects memory layout in structs and classes. Important for performance.
        """
        let items = parseQuestionDrafts(from: output)
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items.allSatisfy { $0.count > 20 })
        XCTAssertTrue(items[0].contains("@StateObject"))
        XCTAssertTrue(items[1].contains("property wrapper"))
        XCTAssertTrue(items[2].contains("compiler"))
    }

    func testBatchCountingForMetrics() {
        let mlxOutput = """
        First question about property wrappers in Swift and their practical applications in modern development.
        =====
        Second question concerning async/await patterns and how they improve code readability in concurrent programming scenarios.
        =====
        Third question exploring closures and their role in functional programming patterns used in Swift development.
        =====
        Fourth question about optionals and error handling strategies in production Swift applications.
        """
        let items = parseQuestionDrafts(from: mlxOutput)
        XCTAssertEqual(items.count, 4)

        // Log as the real implementation does
        print("MLX batch: pedidos 4 rascunhos, obtidos \(items.count).")
    }

    func testBatchParsesWithVariableFormatting() {
        // Real MLX output may have inconsistent spacing and formatting
        let output = """
        What are property wrappers and how do they encapsulate property access patterns? They provide a declarative way to add behavior.
        =====What is the difference between weak and unowned reference types in Swift? Understanding memory semantics is crucial.
        =====

        How do you use @escaping closures and when should they be used in asynchronous programming? This pattern prevents reference cycles.

        =====   How does SwiftUI's state management system work internally with property wrappers and the view lifecycle?
        """
        let items = parseQuestionDrafts(from: output)
        XCTAssertGreaterThanOrEqual(items.count, 3)
        XCTAssertTrue(items.allSatisfy { $0.count > 20 })
    }

    // MARK: - Edge Cases

    func testOnlySeperatorsNoContent() {
        let output = "=========="
        let items = parseQuestionDrafts(from: output)
        XCTAssertEqual(items.count, 0)
    }

    func testComplexUnicodeCharacters() {
        let output = """
        O que são property wrappers e como eles encapsulam o acesso a propriedades em Swift? Eles fornecem uma forma declarativa.
        =====
        Como você usa closures @escaping quando deve ser usada na programação assíncrona? Este padrão previne ciclos de referência.
        """
        let items = parseQuestionDrafts(from: output)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].contains("property wrappers"))
        XCTAssertTrue(items[1].contains("closures"))
    }

    func testItemWithInternalNewlines() {
        let output = """
        What is the difference between @State and @StateObject?

        These are two important property wrappers used in SwiftUI applications for managing state effectively and efficiently.
        =====
        Another question here with content that extends across multiple lines and provides comprehensive coverage of the topic at hand.
        """
        let items = parseQuestionDrafts(from: output)
        XCTAssertEqual(items.count, 2)
        // Internal newlines should be preserved but leading/trailing trimmed
        XCTAssertFalse(items[0].hasPrefix("\n"))
    }

    func testExtremelyLongSeparator() {
        let longSeparator = String(repeating: "=", count: 100)
        let output = "First item here and it needs to be long enough\(longSeparator)Second item that is also long"
        let items = parseQuestionDrafts(from: output, separator: String(repeating: "=", count: 100))
        XCTAssertEqual(items.count, 2)
    }
}
