//
//  TopicRepository.swift
//  SwiftStudyCoach
//
//  Camada de persistência/orquestração entre a UI e o StudyGenerator.
//  Responsável por: (1) servir um StudyTopic do cache quando possível, sem
//  nenhuma chamada nova ao Foundation Models; (2) gerar e persistir tudo na
//  primeira visita a um tópico; (3) sortear o quiz a partir do pool já
//  existente; (4) fazer crescer o pool até 40 itens em background, sem
//  travar a UI e sem duplicar geração.
//

import Foundation
import SwiftData

@MainActor
@Observable
final class TopicRepository {

    private let modelContext: ModelContext
    private let generator: StudyGenerator

    // Tamanho alvo do pool de quiz por dificuldade (~40 no total).
    private let targetEasy = 14
    private let targetMedium = 13
    private let targetHard = 13

    init(modelContext: ModelContext, generator: StudyGenerator) {
        self.modelContext = modelContext
        self.generator = generator
    }

    // MARK: - API pública

    /// Busca um StudyTopic já persistido (mesma versão de dataset) ou gera
    /// tudo do zero (resumo, flashcards, lote inicial de quiz/análise de
    /// código) e persiste. Da segunda visita em diante, deve ser instantâneo.
    func fetchOrCreate(topic: String) async throws -> StudyTopic {
        if let existing = try fetchExisting(topic: topic) {
            if existing.sourceDatasetVersion == DatasetVersion.current {
                if existing.quizPool.isEmpty {
                    // Registro quebrado (de uma geração anterior que falhou no
                    // meio do caminho): não confiar cegamente no cache HIT,
                    // apagar e regenerar do zero.
                    print("🟠 fetchOrCreate: '\(topic)' está em cache mas com quizPool vazio — tratando como quebrado, regenerando.")
                    modelContext.delete(existing)
                    try modelContext.save()
                    return try await generateAndPersist(topic: topic)
                }
                print("🟢 fetchOrCreate: cache HIT para '\(topic)' (dataset '\(existing.sourceDatasetVersion)') — nenhuma chamada ao Foundation Models.")
                return existing // cache válido — nenhuma chamada ao Foundation Models
            }
            // Versão do dataset mudou: descarta o cache antigo e regenera.
            print("🟠 fetchOrCreate: cache STALE para '\(topic)' — versão salva '\(existing.sourceDatasetVersion)' != atual '\(DatasetVersion.current)'. Descartando e regenerando.")
            modelContext.delete(existing)
            try modelContext.save()
        } else {
            print("⚪️ fetchOrCreate: nenhum cache para '\(topic)' — gerando do zero.")
        }
        return try await generateAndPersist(topic: topic)
    }

    /// Sorteia 3 fáceis + 4 médias + 3 difíceis do pool já existente —
    /// instantâneo, sem chamar o modelo. Se o pool tiver menos itens que o
    /// necessário numa dificuldade, repete os disponíveis (não trava) e loga
    /// um aviso.
    func sampleQuiz(from topic: StudyTopic) -> [PersistedQuizQuestion] {
        let easyPool = topic.quizPool.filter { $0.difficulty == Difficulty.easy.rawValue }
        let mediumPool = topic.quizPool.filter { $0.difficulty == Difficulty.medium.rawValue }
        let hardPool = topic.quizPool.filter { $0.difficulty == Difficulty.hard.rawValue }

        return sample(from: easyPool, count: 3, label: "easy")
            + sample(from: mediumPool, count: 4, label: "medium")
            + sample(from: hardPool, count: 3, label: "hard")
    }

    // MARK: - Busca / geração inicial

    private func fetchExisting(topic: String) throws -> StudyTopic? {
        var descriptor = FetchDescriptor<StudyTopic>(predicate: #Predicate { $0.name == topic })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func generateAndPersist(topic: String) async throws -> StudyTopic {
        // TEMP DEBUG (checklist Parte 5, item 4): confirma que esse método só
        // roda na primeira visita a um tópico. Se aparecer de novo numa
        // segunda visita ao MESMO tópico (mesma DatasetVersion), é bug de cache.
        print("🔵 generateAndPersist CHAMADO para '\(topic)' — isso deveria acontecer só na 1ª visita (ou após trocar DatasetVersion.current).")

        // Contexto de documentação recuperado uma única vez e reaproveitado
        // em todas as chamadas de geração abaixo (resumo, flashcards, lotes
        // de quiz e de análise de código).
        let context = await generator.retrieveContext(for: topic)

        // Gera tudo primeiro em variáveis locais — só insere/salva no
        // SwiftData depois que resumo, flashcards, quiz e análise de código
        // tiverem sido gerados com sucesso. Se qualquer chamada falhar, o
        // throws propaga antes de tocar no modelContext, e nada fica
        // persistido pela metade (o que deixaria o cache "quebrado" HIT
        // permanentemente com quizPool vazio).
        let summary = try await generator.generateSummary(topic: topic, context: context)
        let flashcards = try await generator.generateFlashcards(topic: topic, context: context)

        // Lote inicial síncrono (usuário espera): 5 fácil + 6 média + 4
        // difícil = 15, cada dificuldade numa chamada separada — nunca uma
        // chamada só pedindo 10-15 perguntas variando dificuldade.
        let easy = try await generator.generateQuizBatch(topic: topic, context: context, difficulty: .easy, count: 5)
        let medium = try await generator.generateQuizBatch(topic: topic, context: context, difficulty: .medium, count: 6)
        let hard = try await generator.generateQuizBatch(topic: topic, context: context, difficulty: .hard, count: 4)
        let codeAnalysis = try await generator.generateCodeAnalysisBatch(topic: topic, context: context, count: 4)

        // Só chega aqui (e só insere/salva) se TUDO acima teve sucesso.
        let studyTopic = StudyTopic(
            name: topic,
            summary: summary.summary,
            keyPoints: summary.keyPoints,
            codeExample: summary.codeExample
        )
        studyTopic.flashcards = flashcards.map { PersistedFlashcard(from: $0) }
        studyTopic.quizPool = (easy + medium + hard).map { PersistedQuizQuestion(from: $0) }
        studyTopic.codeAnalysisPool = codeAnalysis.map { PersistedCodeAnalysisQuestion(from: $0) }

        modelContext.insert(studyTopic)
        try modelContext.save()

        startBackgroundGrowthIfNeeded(for: studyTopic, topicName: topic, context: context)

        return studyTopic
    }

    private func sample(from pool: [PersistedQuizQuestion], count: Int, label: String) -> [PersistedQuizQuestion] {
        guard !pool.isEmpty else { return [] }

        if pool.count >= count {
            return Array(pool.shuffled().prefix(count))
        }

        // Pool insuficiente nessa dificuldade: repete itens em vez de travar,
        // e loga um aviso para ajustar o tamanho do pool gerado no futuro.
        print("⚠️ TopicRepository: pool de dificuldade '\(label)' tem apenas \(pool.count) item(ns) (precisa de \(count)) — repetindo itens.")
        var result: [PersistedQuizQuestion] = []
        while result.count < count {
            result.append(contentsOf: pool.shuffled())
        }
        return Array(result.prefix(count))
    }

    // MARK: - Crescimento do pool em background

    /// Marca a flag atômica ANTES de qualquer await longo (evita disparo
    /// duplicado se o usuário reabrir o mesmo tópico rapidamente) e dispara
    /// a geração num Task.detached com um ModelContext próprio, isolado do
    /// da UI.
    private func startBackgroundGrowthIfNeeded(for topic: StudyTopic, topicName: String, context: String) {
        guard !topic.isGeneratingPool else { return }
        topic.isGeneratingPool = true
        try? modelContext.save()

        let topicID = topic.persistentModelID
        let container = modelContext.container
        let generator = self.generator
        let targets = (easy: targetEasy, medium: targetMedium, hard: targetHard)

        Task.detached(priority: .background) {
            await TopicRepository.growPoolInBackground(
                topicID: topicID,
                container: container,
                generator: generator,
                topicName: topicName,
                context: context,
                targets: targets
            )
        }
    }

    /// Roda fora do MainActor, com seu próprio ModelContext — nunca reusa o
    /// context/objetos da UI. Sempre reverte `isGeneratingPool` ao final,
    /// mesmo em caso de erro.
    nonisolated private static func growPoolInBackground(
        topicID: PersistentIdentifier,
        container: ModelContainer,
        generator: StudyGenerator,
        topicName: String,
        context: String,
        targets: (easy: Int, medium: Int, hard: Int)
    ) async {
        let backgroundContext = ModelContext(container)

        func fetchTopic() -> StudyTopic? {
            backgroundContext.model(for: topicID) as? StudyTopic
        }

        do {
            try await growDifficulty(
                .easy, target: targets.easy,
                fetchTopic: fetchTopic, backgroundContext: backgroundContext,
                generator: generator, topicName: topicName, context: context
            )
            try await growDifficulty(
                .medium, target: targets.medium,
                fetchTopic: fetchTopic, backgroundContext: backgroundContext,
                generator: generator, topicName: topicName, context: context
            )
            try await growDifficulty(
                .hard, target: targets.hard,
                fetchTopic: fetchTopic, backgroundContext: backgroundContext,
                generator: generator, topicName: topicName, context: context
            )
        } catch {
            print("⚠️ TopicRepository: erro ao crescer pool em background para '\(topicName)': \(error)")
        }

        // Sucesso ou erro: sempre reverter a flag.
        if let topic = fetchTopic() {
            topic.isGeneratingPool = false
            try? backgroundContext.save()
        }
    }

    nonisolated private static func growDifficulty(
        _ difficulty: Difficulty,
        target: Int,
        fetchTopic: () -> StudyTopic?,
        backgroundContext: ModelContext,
        generator: StudyGenerator,
        topicName: String,
        context: String
    ) async throws {
        while true {
            guard let topic = fetchTopic() else { return }
            let currentCount = topic.quizPool.filter { $0.difficulty == difficulty.rawValue }.count
            if currentCount >= target { return }

            // Lotes pequenos (3-5), nunca tudo de uma vez.
            let batchSize = min(4, target - currentCount)
            let batch = try await generator.generateQuizBatch(
                topic: topicName,
                context: context,
                difficulty: difficulty,
                count: batchSize
            )

            guard let topicAgain = fetchTopic() else { return }
            topicAgain.quizPool.append(contentsOf: batch.map { PersistedQuizQuestion(from: $0) })
            try backgroundContext.save()
        }
    }
}
