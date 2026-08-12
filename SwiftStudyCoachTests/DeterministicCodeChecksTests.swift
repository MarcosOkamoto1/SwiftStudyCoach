//
//  DeterministicCodeChecksTests.swift
//  SwiftStudyCoachTests
//
//  PLAN_08 — fixtures reais dos bugs já documentados no histórico do
//  projeto: Button sem action, navigationDestination com valor literal,
//  StateObject em tipo de valor. Cada um deve disparar o flag
//  correspondente. Também cobre casos negativos (código correto não deve
//  disparar nenhum flag) para evitar falsos positivos excessivos.
//

import XCTest
@testable import SwiftStudyCoach

final class DeterministicCodeChecksTests: XCTestCase {

    // MARK: - hasActionlessControl

    func testButtonWithoutActionIsFlagged() {
        let code = """
        struct ContentView: View {
            var body: some View {
                Button("Salvar")
            }
        }
        """
        XCTAssertTrue(DeterministicCodeChecks.hasActionlessControl(code))
        let result = DeterministicCodeChecks.evaluate(code)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.flags.contains("controle sem action"))
    }

    func testButtonWithActionKeywordIsNotFlagged() {
        let code = """
        struct ContentView: View {
            var body: some View {
                Button("Salvar", action: { save() })
            }
        }
        """
        XCTAssertFalse(DeterministicCodeChecks.hasActionlessControl(code))
    }

    func testButtonWithTrailingClosureIsNotFlagged() {
        let code = """
        struct ContentView: View {
            var body: some View {
                Button("Salvar") {
                    save()
                }
            }
        }
        """
        XCTAssertFalse(DeterministicCodeChecks.hasActionlessControl(code))
    }

    func testToggleWithIsOnKeywordIsNotFlagged() {
        let code = """
        struct ContentView: View {
            @State private var isOn = false
            var body: some View {
                Toggle("Ativo", isOn: $isOn)
            }
        }
        """
        XCTAssertFalse(DeterministicCodeChecks.hasActionlessControl(code))
    }

    func testNavigationLinkWithDestinationKeywordIsNotFlagged() {
        let code = """
        struct ContentView: View {
            var body: some View {
                NavigationLink("Detalhe", destination: DetailView())
            }
        }
        """
        XCTAssertFalse(DeterministicCodeChecks.hasActionlessControl(code))
    }

    // MARK: - hasNavigationDestinationValueLiteral

    func testNavigationDestinationWithNumericLiteralIsFlagged() {
        let code = """
        struct ContentView: View {
            var body: some View {
                NavigationStack {
                    Text("Olá")
                        .navigationDestination(for: 1) { _ in DetailView() }
                }
            }
        }
        """
        XCTAssertTrue(DeterministicCodeChecks.hasNavigationDestinationValueLiteral(code))
        let result = DeterministicCodeChecks.evaluate(code)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.flags.contains("navigationDestination com valor"))
    }

    func testNavigationDestinationWithStringLiteralIsFlagged() {
        let code = """
        .navigationDestination(for: "item") { _ in DetailView() }
        """
        XCTAssertTrue(DeterministicCodeChecks.hasNavigationDestinationValueLiteral(code))
    }

    func testNavigationDestinationWithTypeIsNotFlagged() {
        let code = """
        struct ContentView: View {
            var body: some View {
                NavigationStack {
                    Text("Olá")
                        .navigationDestination(for: Int.self) { value in DetailView(value: value) }
                }
            }
        }
        """
        XCTAssertFalse(DeterministicCodeChecks.hasNavigationDestinationValueLiteral(code))
    }

    // MARK: - hasStateObjectOnValueType

    func testStateObjectOnBoolIsFlagged() {
        let code = """
        struct ContentView: View {
            @StateObject private var isActive: Bool = false
            var body: some View {
                Text("\\(isActive)")
            }
        }
        """
        XCTAssertTrue(DeterministicCodeChecks.hasStateObjectOnValueType(code))
        let result = DeterministicCodeChecks.evaluate(code)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.flags.contains("StateObject em tipo de valor"))
    }

    func testStateObjectOnNavigationPathIsFlagged() {
        let code = """
        @StateObject var path: NavigationPath = NavigationPath()
        """
        XCTAssertTrue(DeterministicCodeChecks.hasStateObjectOnValueType(code))
    }

    func testStateObjectOnObservableClassIsNotFlagged() {
        let code = """
        final class ViewModel: ObservableObject {
            @Published var count = 0
        }

        struct ContentView: View {
            @StateObject private var viewModel = ViewModel()
            var body: some View {
                Text("\\(viewModel.count)")
            }
        }
        """
        XCTAssertFalse(DeterministicCodeChecks.hasStateObjectOnValueType(code))
    }

    func testStateOnValueTypeIsNotFlagged() {
        let code = """
        struct ContentView: View {
            @State private var isActive: Bool = false
            var body: some View {
                Text("\\(isActive)")
            }
        }
        """
        XCTAssertFalse(DeterministicCodeChecks.hasStateObjectOnValueType(code))
    }

    // MARK: - evaluate: casos negativos (código correto, nenhum flag)

    func testCorrectCodeProducesNoFlags() {
        let code = """
        struct CounterView: View {
            @State private var count: Int = 0

            var body: some View {
                VStack {
                    Text("Contagem: \\(count)")
                    Button("Incrementar") {
                        count += 1
                    }
                    NavigationStack {
                        NavigationLink("Detalhe", value: count)
                            .navigationDestination(for: Int.self) { value in
                                Text("Valor: \\(value)")
                            }
                    }
                }
            }
        }
        """
        let result = DeterministicCodeChecks.evaluate(code)
        XCTAssertTrue(result.passed, "esperava nenhum flag, recebeu: \(result.flags)")
        XCTAssertTrue(result.flags.isEmpty)
    }

    func testTruncatedCodeIsFlaggedViaLooksTruncated() {
        let code = "func test() {\n    print(\"hello\")"
        let result = DeterministicCodeChecks.evaluate(code)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.flags.contains("truncamento"))
    }
}
