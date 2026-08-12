//
//  DocumentIndexLexicalTests.swift
//  SwiftStudyCoachTests
//
//  Unit tests for DocumentIndex lexical functions: tokens(of:) and lexicalOverlap.
//  Tests stopword filtering, token extraction, and overlap calculation.
//

import XCTest
@testable import SwiftStudyCoach

final class DocumentIndexLexicalTests: XCTestCase {

    // MARK: - tokens(of:) Tests

    func testTokensBasicExtraction() {
        let tokens = DocumentIndex.tokens(of: "property wrapper state swift")
        XCTAssertEqual(tokens, Set(["property", "wrapper", "state", "swift"]))
    }

    func testTokensFiltersStopwords() {
        // Common Portuguese stopwords should be filtered
        let tokens = DocumentIndex.tokens(of: "que é um property wrapper para usar com state")
        // "que", "é", "um", "para", "com" are stopwords
        XCTAssertEqual(tokens, Set(["property", "wrapper", "state", "usar"]))
    }

    func testTokensIgnoresCaseAndDiacritics() {
        let tokens = DocumentIndex.tokens(of: "Açúcar açúcar ACUCAR acucar")
        XCTAssertEqual(tokens, Set(["acucar"]))
    }

    func testTokensIgnoresShortTokens() {
        // Tokens <= 2 chars should be filtered
        let tokens = DocumentIndex.tokens(of: "a to be or in is it at")
        XCTAssertEqual(tokens, Set([]))  // All are 2 chars or less
    }

    func testTokensFiltersShortAndStopwords() {
        let tokens = DocumentIndex.tokens(of: "the big property")
        // "the" (3 chars, in stopwords?), "big" (3 chars, keep), "property" (keep)
        XCTAssertTrue(tokens.contains("big"))
        XCTAssertTrue(tokens.contains("property"))
    }

    func testTokensHandlesPunctuation() {
        let tokens = DocumentIndex.tokens(of: "property-wrapper @State (binding) [array]")
        // Punctuation should be stripped
        let hasProperty = tokens.contains("property")
        let hasWrapper = tokens.contains("wrapper")
        let hasState = tokens.contains("state")
        let hasBinding = tokens.contains("binding")
        let hasArray = tokens.contains("array")
        XCTAssertTrue(hasProperty && hasWrapper && hasState && hasBinding && hasArray)
    }

    func testTokensEmptyString() {
        let tokens = DocumentIndex.tokens(of: "")
        XCTAssertEqual(tokens, Set([]))
    }

    func testTokensOnlyStopwords() {
        let tokens = DocumentIndex.tokens(of: "que é um para com de do da")
        XCTAssertEqual(tokens, Set([]))
    }

    func testTokensOnlyShortWords() {
        let tokens = DocumentIndex.tokens(of: "a to be or in is it at")
        XCTAssertEqual(tokens, Set([]))
    }

    func testTokensMultipleSpaces() {
        let tokens = DocumentIndex.tokens(of: "property    wrapper    state")
        XCTAssertEqual(tokens, Set(["property", "wrapper", "state"]))
    }

    func testTokensNewlines() {
        let tokens = DocumentIndex.tokens(of: "property\nwrapper\nstate")
        XCTAssertEqual(tokens, Set(["property", "wrapper", "state"]))
    }

    func testTokensTabsAndMixedWhitespace() {
        let tokens = DocumentIndex.tokens(of: "property\t\twrapper\n\nstate  ")
        XCTAssertEqual(tokens, Set(["property", "wrapper", "state"]))
    }

    func testTokensNumbersInText() {
        let tokens = DocumentIndex.tokens(of: "swift 3.0 version property wrapper")
        XCTAssertTrue(tokens.contains("swift"))
        XCTAssertTrue(tokens.contains("property"))
        XCTAssertTrue(tokens.contains("wrapper"))
        // Numbers should be extracted too if > 2 chars
    }

    func testTokensSpecialCharacters() {
        let tokens = DocumentIndex.tokens(of: "property@wrapper #state $value")
        // @ # $ should be stripped, leaving just the words
        XCTAssertTrue(tokens.contains("property"))
        XCTAssertTrue(tokens.contains("wrapper"))
        XCTAssertTrue(tokens.contains("state"))
        XCTAssertTrue(tokens.contains("value"))
    }

    // MARK: - lexicalOverlap Tests

    func testLexicalOverlapPerfectMatch() {
        let queryTokens = Set(["property", "wrapper"])
        let overlap = DocumentIndex.lexicalOverlap(queryTokens: queryTokens, text: "property wrapper state")
        XCTAssertEqual(overlap, 1.0)  // Both terms present: 2/2
    }

    func testLexicalOverlapNoMatch() {
        let queryTokens = Set(["property", "wrapper"])
        let overlap = DocumentIndex.lexicalOverlap(queryTokens: queryTokens, text: "async await coroutine")
        XCTAssertEqual(overlap, 0.0)  // No terms match: 0/2
    }

    func testLexicalOverlapPartialMatch() {
        let queryTokens = Set(["property", "wrapper", "state"])
        let overlap = DocumentIndex.lexicalOverlap(queryTokens: queryTokens, text: "property wrapper binding")
        XCTAssertEqual(overlap, 2.0 / 3.0)  // 2 out of 3 terms: property, wrapper
    }

    func testLexicalOverlapSingleMatch() {
        let queryTokens = Set(["property", "wrapper", "state"])
        let overlap = DocumentIndex.lexicalOverlap(queryTokens: queryTokens, text: "property observer pattern")
        XCTAssertEqual(overlap, 1.0 / 3.0)  // Only "property" matches
    }

    func testLexicalOverlapEmptyQuery() {
        let queryTokens = Set<String>()
        let overlap = DocumentIndex.lexicalOverlap(queryTokens: queryTokens, text: "property wrapper state")
        XCTAssertEqual(overlap, 0.0)  // Empty query returns 0
    }

    func testLexicalOverlapEmptyText() {
        let queryTokens = Set(["property", "wrapper"])
        let overlap = DocumentIndex.lexicalOverlap(queryTokens: queryTokens, text: "")
        XCTAssertEqual(overlap, 0.0)  // Empty text has no tokens, no matches
    }

    func testLexicalOverlapCaseInsensitive() {
        let queryTokens = Set(["PROPERTY", "WRAPPER"])
        let overlap = DocumentIndex.lexicalOverlap(queryTokens: queryTokens, text: "property wrapper state")
        XCTAssertEqual(overlap, 1.0)  // Case insensitive, so matches
    }

    func testLexicalOverlapDiacriticsInsensitive() {
        let queryTokens = Set(["acucar", "sal"])
        let overlap = DocumentIndex.lexicalOverlap(queryTokens: queryTokens, text: "Açúcar e sal são condimentos")
        // Both "açúcar" and "sal" should match when diacritics are ignored
        XCTAssertEqual(overlap, 1.0)  // Both match
    }

    func testLexicalOverlapIgnoresStopwords() {
        // Query with stopwords (these get filtered by tokens())
        let queryTokens = Set(["property", "wrapper"])
        // Text with stopwords that might match differently
        let overlap = DocumentIndex.lexicalOverlap(queryTokens: queryTokens, text: "que property é wrapper para usar")
        XCTAssertEqual(overlap, 1.0)  // Still finds both terms despite stopwords
    }

    func testLexicalOverlapMultipleSameToken() {
        let queryTokens = Set(["property"])  // Only one unique token (sets remove duplicates)
        let overlap = DocumentIndex.lexicalOverlap(queryTokens: queryTokens, text: "property property property")
        XCTAssertEqual(overlap, 1.0)  // Single token present once: 1/1
    }

    func testLexicalOverlapLongQuery() {
        let queryTokens = Set(["swift", "property", "wrapper", "state", "binding", "reactive"])
        let overlap = DocumentIndex.lexicalOverlap(queryTokens: queryTokens, text: "swift property wrapper")
        XCTAssertEqual(overlap, 3.0 / 6.0)  // 3 out of 6 terms match
    }

    func testLexicalOverlapLongText() {
        let queryTokens = Set(["property", "wrapper"])
        let longText = """
        Swift property wrappers are a powerful feature introduced in Swift 5.1.
        They provide a way to encapsulate read and write access to properties.
        The @State property wrapper is one of the most commonly used examples,
        especially in SwiftUI where it manages the state of a view.
        You can also create custom property wrappers for your own needs.
        """
        let overlap = DocumentIndex.lexicalOverlap(queryTokens: queryTokens, text: longText)
        XCTAssertEqual(overlap, 1.0)  // Both "property" and "wrapper" are present
    }

    // MARK: - Real-World Integration Tests

    func testLexicalOverlapStateQueryVsStateDoc() {
        // Query: "What is @State?"
        let queryTokens = DocumentIndex.tokens(of: "What is @State?")

        // Text: Documentation about @State
        let stateDoc = """
        @State is a property wrapper that manages local state in SwiftUI views.
        It allows you to store data that SwiftUI observes for changes.
        When the state changes, SwiftUI automatically updates the view.
        """
        let overlap = DocumentIndex.lexicalOverlap(queryTokens: queryTokens, text: stateDoc)
        XCTAssertGreater(overlap, 0.0)  // Should have some overlap with "state"
    }

    func testLexicalOverlapAsyncQueryVsAsyncDoc() {
        let queryTokens = DocumentIndex.tokens(of: "async await functions")

        let asyncDoc = """
        Async/await is a Swift concurrency feature for handling asynchronous operations.
        Functions marked with async can be awaited in other async contexts.
        This provides cleaner syntax than callbacks or closure-based alternatives.
        """
        let overlap = DocumentIndex.lexicalOverlap(queryTokens: queryTokens, text: asyncDoc)
        XCTAssertGreater(overlap, 0.0)  // Should match on "async"
    }

    func testLexicalOverlapNoiseReduction() {
        // Query with common terms that shouldn't bias results
        let queryTokens = Set(["state", "property"])

        // Two documents: one about @State, one about other properties
        let stateSpecificDoc = "property wrapper for state management"
        let genericPropertyDoc = "property access control levels swift"

        let stateOverlap = DocumentIndex.lexicalOverlap(queryTokens: queryTokens, text: stateSpecificDoc)
        let propertyOverlap = DocumentIndex.lexicalOverlap(queryTokens: queryTokens, text: genericPropertyDoc)

        // Both have "property", but stateDoc should have better overlap due to "state"
        XCTAssertGreater(stateOverlap, propertyOverlap)
    }

    func testTokensStopwordList() {
        // Verify that known stopwords are actually filtered
        let knownStopwords = ["que", "de", "da", "do", "para", "com", "sem", "uma", "um"]

        for stopword in knownStopwords {
            let tokens = DocumentIndex.tokens(of: stopword)
            XCTAssertTrue(tokens.isEmpty, "Stopword '\(stopword)' should be filtered")
        }
    }

    func testTokensNonStopwordsSmallerThan3Chars() {
        // Words with 3+ chars that are NOT stopwords should be kept
        let nonStopwordSmall = DocumentIndex.tokens(of: "not yes see dog cat run")
        XCTAssertFalse(nonStopwordSmall.isEmpty)
        XCTAssertTrue(nonStopwordSmall.contains("not"))
        XCTAssertTrue(nonStopwordSmall.contains("see"))
        XCTAssertTrue(nonStopwordSmall.contains("dog"))
    }

    func testLexicalOverlapQuotationMarks() {
        let queryTokens = Set(["swift", "code"])
        let textWithQuotes = "\"Swift code\" is powerful and expressive"
        let overlap = DocumentIndex.lexicalOverlap(queryTokens: queryTokens, text: textWithQuotes)
        XCTAssertEqual(overlap, 1.0)  // Both terms should match
    }
}
