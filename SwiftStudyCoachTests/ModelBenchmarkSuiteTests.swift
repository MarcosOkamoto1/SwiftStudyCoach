//
//  ModelBenchmarkSuiteTests.swift
//  SwiftStudyCoachTests
//
//  PLAN_05 — Testa a rubrica ponderada e, principalmente, o VETO DURO de
//  SOLUTIONS_PLAN.md §9.4: qualquer modelo com >=1 ocorrência de API
//  inventada nos prompts 4-7 fica automaticamente abaixo de qualquer
//  modelo sem ocorrências, independente do score total. Isso é a única
//  parte de PLAN_05 que é determinística e testável sem geração real de
//  modelo (a suíte em si — 18 prompts contra o MLX de verdade — é
//  probabilística, ver "Testes" do PLAN_05).
//

import XCTest
@testable import SwiftStudyCoach

final class ModelBenchmarkSuiteTests: XCTestCase {

    // MARK: - Helpers

    /// Constrói um `BenchmarkPromptResult` mínimo, pontuado, pra testes de
    /// ranking — não precisa de output/métricas reais.
    private func scoredResult(promptID: Int, rubric: BenchmarkRubricScore) -> BenchmarkPromptResult {
        BenchmarkPromptResult(
            promptID: promptID,
            category: "teste",
            summary: "teste",
            ragTopic: nil,
            ragContextChars: 0,
            rawOutput: "output de teste",
            errorMessage: nil,
            metrics: nil,
            rubric: rubric
        )
    }

    private func report(modelID: String, results: [BenchmarkPromptResult]) -> BenchmarkModelReport {
        BenchmarkModelReport(modelID: modelID, generatedAt: Date(), results: results)
    }

    private let highScore = BenchmarkRubricScore(apiReal: 30, instructionFollowing: 25, grounding: 20, swiftCorrectness: 15, latency: 7, memory: 3)
    private let lowScore = BenchmarkRubricScore(apiReal: 5, instructionFollowing: 5, grounding: 5, swiftCorrectness: 5, latency: 1, memory: 1)

    // MARK: - BenchmarkRubricScore.weightedTotal

    func testWeightedTotalSumsAllCriteria() {
        let score = BenchmarkRubricScore(apiReal: 30, instructionFollowing: 25, grounding: 20, swiftCorrectness: 15, latency: 7, memory: 3)
        XCTAssertEqual(score.weightedTotal, 100)
    }

    func testWeightedTotalClampsAboveMax() {
        // Entrada inválida (ex.: vinda de um bug na UI) não deve estourar o
        // peso máximo de cada critério.
        let score = BenchmarkRubricScore(apiReal: 999, instructionFollowing: 999, grounding: 999, swiftCorrectness: 999, latency: 999, memory: 999)
        XCTAssertEqual(score.weightedTotal, BenchmarkRubricScore.maxPossibleTotal)
    }

    func testWeightedTotalClampsBelowZero() {
        let score = BenchmarkRubricScore(apiReal: -10, instructionFollowing: -5, grounding: 0, swiftCorrectness: 0, latency: 0, memory: 0)
        XCTAssertEqual(score.weightedTotal, 0)
    }

    // MARK: - BenchmarkModelReport.hasHardVeto

    func testHasHardVetoFalseWhenNoPromptFlagged() {
        let results = (1...18).map { scoredResult(promptID: $0, rubric: highScore) }
        let r = report(modelID: "modelo-limpo", results: results)
        XCTAssertFalse(r.hasHardVeto)
    }

    func testHasHardVetoTrueWhenPrompt4Flagged() {
        var results = (1...18).map { scoredResult(promptID: $0, rubric: highScore) }
        var vetoedRubric = highScore
        vetoedRubric.hasInventedAPI = true
        results[3] = scoredResult(promptID: 4, rubric: vetoedRubric) // prompt #4
        let r = report(modelID: "modelo-com-hallucination", results: results)
        XCTAssertTrue(r.hasHardVeto)
    }

    func testHasHardVetoIgnoresFlagOutsidePromptRange4to7() {
        // hasInventedAPI marcado num prompt FORA da faixa 4-7 (ex.: #10)
        // não deve acionar o veto — só prompts 4-7 alimentam essa regra
        // (§9.4).
        var results = (1...18).map { scoredResult(promptID: $0, rubric: highScore) }
        var flaggedOutsideRange = highScore
        flaggedOutsideRange.hasInventedAPI = true
        results[9] = scoredResult(promptID: 10, rubric: flaggedOutsideRange)
        let r = report(modelID: "modelo-flag-fora-da-faixa", results: results)
        XCTAssertFalse(r.hasHardVeto)
    }

    func testHasHardVetoTrueForEachPromptInHardVetoRange() {
        for vetoPromptID in 4...7 {
            var results = (1...18).map { scoredResult(promptID: $0, rubric: highScore) }
            var vetoedRubric = highScore
            vetoedRubric.hasInventedAPI = true
            results[vetoPromptID - 1] = scoredResult(promptID: vetoPromptID, rubric: vetoedRubric)
            let r = report(modelID: "modelo-\(vetoPromptID)", results: results)
            XCTAssertTrue(r.hasHardVeto, "prompt #\(vetoPromptID) deveria acionar o veto duro")
        }
    }

    // MARK: - BenchmarkRanking.rank — a regra central do §9.4

    func testVetoedModelRanksBelowCleanModelRegardlessOfScore() {
        // Modelo A: score baixo, mas SEM hallucination nos prompts 4-7.
        let cleanResults = (1...18).map { scoredResult(promptID: $0, rubric: lowScore) }
        let cleanModel = report(modelID: "modelo-A-score-baixo-limpo", results: cleanResults)

        // Modelo B: score alto, mas COM hallucination no prompt #5.
        var vetoedResults = (1...18).map { scoredResult(promptID: $0, rubric: highScore) }
        var vetoedRubric = highScore
        vetoedRubric.hasInventedAPI = true
        vetoedResults[4] = scoredResult(promptID: 5, rubric: vetoedRubric)
        let vetoedModel = report(modelID: "modelo-B-score-alto-com-hallucination", results: vetoedResults)

        XCTAssertGreaterThan(vetoedModel.totalScore, cleanModel.totalScore, "pré-condição do teste: B precisa ter score MAIOR que A")
        XCTAssertTrue(vetoedModel.hasHardVeto)
        XCTAssertFalse(cleanModel.hasHardVeto)

        let ranked = BenchmarkRanking.rank([vetoedModel, cleanModel])

        // Apesar do score maior, o modelo com veto (B) deve ficar DEPOIS do
        // modelo limpo (A) — é a regra explícita de §9.4.
        XCTAssertEqual(ranked.first?.modelID, cleanModel.modelID)
        XCTAssertEqual(ranked.last?.modelID, vetoedModel.modelID)
        XCTAssertEqual(BenchmarkRanking.winner(among: [vetoedModel, cleanModel])?.modelID, cleanModel.modelID)
    }

    func testRankingFallsBackToScoreWhenNeitherHasVeto() {
        let lowResults = (1...18).map { scoredResult(promptID: $0, rubric: lowScore) }
        let lowModel = report(modelID: "modelo-baixo", results: lowResults)

        let highResults = (1...18).map { scoredResult(promptID: $0, rubric: highScore) }
        let highModel = report(modelID: "modelo-alto", results: highResults)

        let ranked = BenchmarkRanking.rank([lowModel, highModel])
        XCTAssertEqual(ranked.first?.modelID, highModel.modelID)
    }

    func testRankingFallsBackToScoreWhenBothHaveVeto() {
        var results1 = (1...18).map { scoredResult(promptID: $0, rubric: lowScore) }
        var vetoedLow = lowScore
        vetoedLow.hasInventedAPI = true
        results1[3] = scoredResult(promptID: 4, rubric: vetoedLow)
        let model1 = report(modelID: "ambos-vetados-baixo", results: results1)

        var results2 = (1...18).map { scoredResult(promptID: $0, rubric: highScore) }
        var vetoedHigh = highScore
        vetoedHigh.hasInventedAPI = true
        results2[3] = scoredResult(promptID: 4, rubric: vetoedHigh)
        let model2 = report(modelID: "ambos-vetados-alto", results: results2)

        XCTAssertTrue(model1.hasHardVeto)
        XCTAssertTrue(model2.hasHardVeto)

        // Com os dois vetados, o desempate volta a ser por score.
        let ranked = BenchmarkRanking.rank([model1, model2])
        XCTAssertEqual(ranked.first?.modelID, model2.modelID)
    }

    // MARK: - BenchmarkModelReport contadores auxiliares

    func testIsFullyScoredFalseUntilAllPromptsHaveRubric() {
        var results = (1...18).map { scoredResult(promptID: $0, rubric: highScore) }
        results[0].rubric = nil
        let r = report(modelID: "parcial", results: results)
        XCTAssertFalse(r.isFullyScored)
        XCTAssertEqual(r.scoredPromptsCount, 17)
    }

    func testIsFullyScoredTrueWhenAllPromptsHaveRubric() {
        let results = (1...18).map { scoredResult(promptID: $0, rubric: highScore) }
        let r = report(modelID: "completo", results: results)
        XCTAssertTrue(r.isFullyScored)
        XCTAssertEqual(r.maxPossibleScore, 18 * BenchmarkRubricScore.maxPossibleTotal)
    }

    // MARK: - BenchmarkPrompts.all — sanidade dos dados (§9.1)

    func testAllEighteenPromptsPresentWithUniqueSequentialIDs() {
        let ids = BenchmarkPrompts.all.map(\.id).sorted()
        XCTAssertEqual(ids, Array(1...18))
    }

    func testHardVetoPromptsAreExactlyFourToSeven() {
        let hardVetoIDs = BenchmarkPrompts.all.filter(\.isHardVetoPrompt).map(\.id).sorted()
        XCTAssertEqual(hardVetoIDs, [4, 5, 6, 7])
    }

    func testBatchPromptsHaveCountGreaterThanOne() {
        // Prompts 11, 13, 17 são os únicos em lote, per §9.1.
        let batchIDs = BenchmarkPrompts.all.filter { $0.batchCount > 1 }.map(\.id).sorted()
        XCTAssertEqual(batchIDs, [11, 13, 17])
    }

    func testEveryPromptBuildsNonEmptyText() {
        for spec in BenchmarkPrompts.all {
            let built = spec.buildPrompt("contexto de teste")
            XCTAssertFalse(built.isEmpty, "prompt #\(spec.id) gerou texto vazio")
            XCTAssertFalse(spec.systemPrompt.isEmpty, "prompt #\(spec.id) tem systemPrompt vazio")
        }
    }
}
