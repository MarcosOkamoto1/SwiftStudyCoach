//
//  StudyGeneratorPureFunctionsTests.swift
//  SwiftStudyCoachTests
//
//  Unit tests for StudyGenerator.looksTruncated covering balanced delimiters,
//  escape sequences, and suspicious line endings.
//

import XCTest
@testable import SwiftStudyCoach

final class StudyGeneratorPureFunctionsTests: XCTestCase {

    // MARK: - looksTruncated: Empty and Whitespace Tests

    func testLooksTruncatedEmptyString() {
        XCTAssertTrue(StudyGenerator.looksTruncated(""))
    }

    func testLooksTruncatedOnlyWhitespace() {
        XCTAssertTrue(StudyGenerator.looksTruncated("   "))
        XCTAssertTrue(StudyGenerator.looksTruncated("\n\n"))
        XCTAssertTrue(StudyGenerator.looksTruncated("\t\t"))
    }

    // MARK: - looksTruncated: Balanced Delimiters Tests

    func testLooksTruncatedBalancedBraces() {
        let code = "func test() {\n    print(\"hello\")\n}"
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedUnbalancedBraces() {
        let code = "func test() {\n    print(\"hello\")"
        XCTAssertTrue(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedUnbalancedBracesExtra() {
        let code = "func test() {\n    print(\"hello\")\n}}"
        XCTAssertTrue(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedBalancedParentheses() {
        let code = "let x = (1 + 2) * 3"
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedUnbalancedParentheses() {
        let code = "let x = (1 + 2 * 3"
        XCTAssertTrue(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedBalancedBrackets() {
        let code = "let arr = [1, 2, 3]"
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedUnbalancedBrackets() {
        let code = "let arr = [1, 2, 3"
        XCTAssertTrue(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedMixedBalancedDelimiters() {
        let code = "let dict = [\"key\": (1, 2, 3)]"
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedMixedUnbalancedDelimiters() {
        let code = "let dict = [\"key\": (1, 2, 3]"  // Bracket closed instead of paren
        XCTAssertTrue(StudyGenerator.looksTruncated(code))
    }

    // MARK: - looksTruncated: String Escape Sequences Tests

    func testLooksTruncatedIgnoresDelimitersInStrings() {
        let code = "let str = \"This { has } brackets [and] (parens\""
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedEscapedQuoteInString() {
        let code = "let str = \"This has \\\" escaped quote\""
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedStringWithUnmatchedDelimiters() {
        let code = "let str = \"This { has unmatched\""
        XCTAssertFalse(StudyGenerator.looksTruncated(code))  // Inside string, doesn't count
    }

    func testLooksTruncatedBackslashBeforeQuote() {
        let code = "let str = \"Path: C:\\\\ backup\""
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedStringNotClosed() {
        let code = "let str = \"This string is not closed"
        XCTAssertTrue(StudyGenerator.looksTruncated(code))  // String toggle makes it think } is in string
    }

    // MARK: - looksTruncated: Suspicious Line Endings Tests

    func testLooksTruncatedEndingWithComma() {
        let code = "let x = [\n    1,\n    2,"
        XCTAssertTrue(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedEndingWithOpenBrace() {
        let code = "if true {"
        XCTAssertTrue(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedEndingWithOpenParen() {
        let code = "func test("
        XCTAssertTrue(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedEndingWithOpenBracket() {
        let code = "let arr = ["
        XCTAssertTrue(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedEndingWithEquals() {
        let code = "let x ="
        XCTAssertTrue(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedEndingWithPlusOperator() {
        let code = "let result = a +"
        XCTAssertTrue(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedEndingWithMinusOperator() {
        let code = "let difference = a -"
        XCTAssertTrue(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedEndingWithMultiplyOperator() {
        let code = "let product = a *"
        XCTAssertTrue(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedEndingWithDivideOperator() {
        let code = "let quotient = a /"
        XCTAssertTrue(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedEndingWithColon() {
        let code = "let dict: [String: Int] ="
        XCTAssertTrue(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedEndingWithLogicalAnd() {
        let code = "if a && b &&"
        XCTAssertTrue(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedEndingWithLogicalOr() {
        let code = "if a || b ||"
        XCTAssertTrue(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedEndingWithArrow() {
        let code = "func test() ->"
        XCTAssertTrue(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedEndingWithDot() {
        let code = "let value = someObject."
        XCTAssertTrue(StudyGenerator.looksTruncated(code))
    }

    // MARK: - looksTruncated: Valid Complete Code Tests

    func testLooksTruncatedCompleteSimpleAssignment() {
        let code = "let x = 42"
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedCompleteIfStatement() {
        let code = "if condition {\n    doSomething()\n}"
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedCompleteForLoop() {
        let code = "for i in 0..<10 {\n    print(i)\n}"
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedCompleteArrayLiteral() {
        let code = "let numbers = [1, 2, 3, 4, 5]"
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedCompleteDictionaryLiteral() {
        let code = "let dict = [\"a\": 1, \"b\": 2]"
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedCompleteClosureDefinition() {
        let code = "let closure = { x in x * 2 }"
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedCompleteMultilineFunctionDefinition() {
        let code = "func add(_ a: Int, _ b: Int) -> Int {\n    return a + b\n}"
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedCompleteExtension() {
        let code = "extension String {\n    func reversed() -> String {\n        return String(self.reversed())\n    }\n}"
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedCompleteGuardStatement() {
        let code = "guard let value = optional else { return }"
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedCompleteEnumDefinition() {
        let code = "enum Color {\n    case red\n    case green\n    case blue\n}"
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    // MARK: - looksTruncated: Whitespace Trimming Tests

    func testLooksTruncatedTrimsLeadingWhitespace() {
        let code = "   let x = 1"
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedTrimsTrailingWhitespace() {
        let code = "let x = 1   "
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedTrimsAllWhitespace() {
        let code = "   let x = 1   "
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedTrimsNewlines() {
        let code = "\n\nlet x = 1\n\n"
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    // MARK: - looksTruncated: Complex Real-World Examples Tests

    func testLooksTruncatedRealWorldCompleteSwiftUI() {
        let code = """
        struct ContentView: View {
            @State private var text = ""

            var body: some View {
                VStack {
                    TextField("Enter text", text: $text)
                    Text(text)
                }
            }
        }
        """
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedRealWorldTruncatedSwiftUI() {
        let code = """
        struct ContentView: View {
            @State private var text = ""

            var body: some View {
                VStack {
                    TextField("Enter text", text:
        """
        XCTAssertTrue(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedRealWorldCompleteAsync() {
        let code = """
        async func fetchData() -> String {
            let url = URL(string: "https://example.com")!
            let (data, _) = try await URLSession.shared.data(from: url)
            return String(data: data, encoding: .utf8) ?? "Error"
        }
        """
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedRealWorldTruncatedAsync() {
        let code = """
        async func fetchData() -> String {
            let url = URL(string: "https://example.com")!
            let (data, _) = try await URLSession.shared.data(from:
        """
        XCTAssertTrue(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedComplexStringWithQuotes() {
        let code = """
        let sql = \"\"\"
        SELECT * FROM users
        WHERE name = 'John'
        AND age > 18
        \"\"\"
        """
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }

    func testLooksTruncatedCompleteGenericFunction() {
        let code = """
        func map<T, U>(_ value: T, transform: (T) -> U) -> U {
            return transform(value)
        }
        """
        XCTAssertFalse(StudyGenerator.looksTruncated(code))
    }
}
