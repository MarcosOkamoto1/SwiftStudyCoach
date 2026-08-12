//
//  TopicRepository.swift
//  SwiftStudyCoach
//
//  Camada de persistência/orquestração entre a UI e o StudyGenerator.
//  Responsável por: (1) servir um StudyTopic do cache quando possível, sem
//  nenhuma chamada nova ao Foundation Models; (2) na primeira visita a um
//  tópico, gerar e persistir de forma BLOQUEANTE só o que a tela mostra de
//  imediato — resumo, exemplo de código e quiz fácil/média — com as trilhas
//  FM e MLX em PARALELO (Plano V6; o V4 gerava tudo em série e a tela de
//  loading levava vários minutos); difícil e análise de código são gerados
//  em background logo em seguida; (3) sortear o quiz a partir do pool já
//  existente; (4) crescimento em background como rede de segurança (pool
//  incompleto) e top-up pós-sessão (replenishAfterSession).
//

import Foundation
import SwiftData

enum TopicRepositoryError: LocalizedError {
    /// A Task de geração terminou sem lançar erro, mas o fetch local não
    /// achou o StudyTopic persistido pro tópico — defensivo, não deveria
    /// acontecer na prática (generateAndPersist sempre persiste antes de
    /// retornar), mas evita um crash silencioso se acontecer.
    case generationDidNotPersist(topic: String)

    var errorDescription: String? {
        switch self {
        case .generationDidNotPersist(let topic):
            return "A geração de '\(topic)' terminou mas o resultado não foi encontrado no cache local."
        }
    }
}

@MainActor
@Observable
final class TopicRepository {

    private let modelContext: ModelContext
    private let generator: StudyGenerator

    /// Deduplicação de geração em andamento por nome de tópico (Plano V5,
    /// hotfix pós-teste real): sem isso, reabrir/recarregar a tela do MESMO
    /// tópico antes da 1ª geração terminar e persistir fazia fetchOrCreate
    /// checar "sem cache" de novo e disparar uma SEGUNDA geração completa
    /// inteira em paralelo (visto ao vivo: "generateAndPersist CHAMADO"
    /// duas vezes pro mesmo tópico) — as duas competiam pela mesma fila do
    /// GenerationOrchestrator, dobrando o trabalho e parecendo travado.
    /// Mesmo padrão de Task compartilhada já usado em MLXService.loadModel
    /// e DocumentIndex.ensureReady. Guarda só `Void` (não `StudyTopic`) —
    /// `StudyTopic` é um `@Model` do SwiftData, e `PersistentModel`s não são
    /// `Sendable` (erro real do Swift 6 strict concurrency: "Conformance of
    /// StudyTopic to Sendable is unavailable"). A Task só sinaliza
    /// "terminou"; cada chamador refaz o fetch local (MainActor, sem cruzar
    /// isolamento) depois de esperar.
    private var inFlightGenerations: [String: Task<Void, Error>] = [:]

    // Tamanho alvo do pool de quiz por dificuldade (24 no total — Plano V3
    // 1.1: cortado de 53 pra 24, ~2 sessões sem repetição perceptível antes
    // do top-up pós-sessão (ver replenishAfterSession) entrar em ação).
    private let targetEasy = 6
    private let targetMedium = 6
    private let targetHard = 6
    private let targetCodeAnalysis = 6

    init(modelContext: ModelContext, generator: StudyGenerator) {
        self.modelContext = modelContext
        self.generator = generator
    }

    // MARK: - API pública

    /// Busca um StudyTopic já persistido (mesma versão de dataset) ou gera
    /// tudo do zero (resumo, exemplo com walkthrough, lote inicial de
    /// quiz/análise de código) e persiste. Da segunda visita em diante,
    /// deve ser instantâneo.
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
                    return try await generateAndPersistDeduped(topic: topic)
                }
                print("🟢 fetchOrCreate: cache HIT para '\(topic)' (dataset '\(existing.sourceDatasetVersion)') — nenhuma chamada ao Foundation Models.")

                // Se o pool ficou incompleto (ex: download do MLX falhou ou o
                // app foi fechado no meio do crescimento), retoma o
                // crescimento em background — antes, um pool incompleto
                // ficava travado pra sempre no cache HIT.
                let quizTarget = targetEasy + targetMedium + targetHard
                if existing.quizPool.count < quizTarget || existing.codeAnalysisPool.count < targetCodeAnalysis {
                    print("🟠 fetchOrCreate: pool incompleto (\(existing.quizPool.count)/\(quizTarget) quiz, \(existing.codeAnalysisPool.count)/\(targetCodeAnalysis) análise) — retomando crescimento em background.")
                    let context = await generator.retrieveContext(for: topic, topK: 3)
                    // Retomada de crescimento interrompido usa o ALVO CHEIO
                    // (não o "piso" da 1ª sessão) — isso é rede de segurança
                    // pra geração que ficou pela metade, não o fluxo normal
                    // de top-up (ver replenishAfterSession, Plano V3 4.1).
                    startBackgroundGrowthIfNeeded(
                        for: existing, topicName: topic, context: context,
                        targets: (targetEasy, targetMedium, targetHard, targetCodeAnalysis),
                        priority: .poolFill
                    )
                }
                return existing // cache válido — nenhuma chamada ao Foundation Models
            }
            // Versão do dataset mudou: descarta o cache antigo e regenera.
            print("🟠 fetchOrCreate: cache STALE para '\(topic)' — versão salva '\(existing.sourceDatasetVersion)' != atual '\(DatasetVersion.current)'. Descartando e regenerando.")
            modelContext.delete(existing)
            try modelContext.save()
        } else {
            print("⚪️ fetchOrCreate: nenhum cache para '\(topic)' — gerando do zero.")
        }
        return try await generateAndPersistDeduped(topic: topic)
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

    /// Envolve `generateAndPersist` com deduplicação por tópico (ver
    /// comentário de `inFlightGenerations`): se já existe uma geração em
    /// andamento pro MESMO nome, a chamada nova aguarda a MESMA Task em vez
    /// de disparar um ciclo completo de geração duplicado. A Task em si só
    /// sinaliza conclusão (`Void`) — depois de esperar, cada chamador refaz
    /// o fetch local do `StudyTopic` já persistido (evita cruzar um
    /// `PersistentModel`, que não é `Sendable`, pela fronteira da Task).
    private func generateAndPersistDeduped(topic: String) async throws -> StudyTopic {
        if let existingTask = inFlightGenerations[topic] {
            print("🟡 fetchOrCreate: geração já em andamento para '\(topic)' — aguardando a MESMA Task em vez de duplicar.")
            try await existingTask.value
        } else {
            let task = Task {
                _ = try await generateAndPersist(topic: topic)
            }
            inFlightGenerations[topic] = task
            defer { inFlightGenerations[topic] = nil }
            try await task.value
        }

        guard let studyTopic = try fetchExisting(topic: topic) else {
            throw TopicRepositoryError.generationDidNotPersist(topic: topic)
        }
        return studyTopic
    }

    private func generateAndPersist(topic: String) async throws -> StudyTopic {
        // TEMP DEBUG (checklist Parte 5, item 4): confirma que esse método só
        // roda na primeira visita a um tópico. Se aparecer de novo numa
        // segunda visita ao MESMO tópico (mesma DatasetVersion), é bug de cache.
        print("🔵 generateAndPersist CHAMADO para '\(topic)' — isso deveria acontecer só na 1ª visita (ou após trocar DatasetVersion.current).")

        // Plano V3 4.2: o usuário está parado nesta tela esperando — cancela
        // qualquer enchimento de pool (.poolFill) de OUTROS tópicos que
        // ainda não começou a rodar, pra essa geração user-blocking não
        // ficar atrás de trabalho de segundo plano na fila do orchestrator.
        await GenerationOrchestrator.shared.cancelPending(priority: .poolFill)

        let totalStart = Date()

        // Contexto de documentação recuperado uma única vez e reaproveitado
        // nas chamadas de geração abaixo. Plano V5: dataset caiu pra 3
        // tópicos com no máximo 3 chunks cada — topK 3 pega o tópico
        // INTEIRO sempre (sem cortar chunk fora, como acontecia com o
        // topK 2 antigo — Property Wrappers, por exemplo, perdia o chunk
        // do @Observable, a abordagem moderna). Contexto do exemplo de
        // código também subiu (1 → 2) pra reduzir alucinação.
        let context = await generator.retrieveContext(for: topic, topK: 3)
        let codeContext = await generator.retrieveContext(for: topic, topK: 2)

        // Plano V6 — o caminho BLOQUEANTE gera só o que a tela mostra de
        // imediato: resumo + quiz fácil/média (trilha FM) e exemplo de
        // código (trilha MLX), com as DUAS trilhas em paralelo via
        // `async let` — o download/carga do modelo MLX (passo mais caro na
        // 1ª execução) acontece ENQUANTO o Foundation Models gera resumo e
        // quiz, em vez de depois. As filas do GenerationOrchestrator já
        // garantem uma chamada por motor por vez, então o paralelismo aqui
        // é seguro por construção.
        //
        // Quiz difícil e análise de código (as etapas MLX-pesadas, que eram
        // ~80% do tempo total do V4) saem do caminho bloqueante e vão pro
        // crescimento em background logo após persistir — a UI já
        // desabilita/anota os botões de sessão conforme o pool cresce.
        // Plano V3 3.1 (mantido): todo lote passa pelo QuestionValidator.
        let generator = self.generator
        // taskType aqui é `nil` de propósito: este `timed` mede o PIPELINE
        // inteiro do exemplo de código (rascunho MLX + crítica FM + formatação
        // FM), que já são instrumentados individualmente dentro de
        // `StudyGenerator` (taskTypes `.codeExampleDraft`/`.codeExampleCritique`/
        // `.codeExampleFormat`) — registrar de novo aqui duplicaria a métrica
        // sob um taskType que não corresponde a nenhuma chamada real.
        async let exampleTask = Self.timed("exemplo de código (trilha MLX)") {
            try await generator.generateCodeExample(topic: topic, context: codeContext)
        }

        let summary = try await Self.timed("resumo", topic: topic) {
            try await generator.generateSummary(topic: topic, context: context)
        }

        let easy = try await Self.timed("quiz fácil (\(targetEasy) + validação)", topic: topic) {
            let raw = try await generator.generateQuizBatch(topic: topic, context: context, difficulty: .easy, count: self.targetEasy)
            return await QuestionValidator.processQuizBatch(raw, topic: topic, taskType: .easyQuiz) {
                try await generator.generateQuizBatch(topic: topic, context: context, difficulty: .easy, count: 1).first
            }
        }
        let medium = try await Self.timed("quiz média (\(targetMedium) + validação)", topic: topic) {
            let raw = try await generator.generateQuizBatch(topic: topic, context: context, difficulty: .medium, count: self.targetMedium)
            return await QuestionValidator.processQuizBatch(raw, topic: topic, taskType: .mediumQuiz) {
                try await generator.generateQuizBatch(topic: topic, context: context, difficulty: .medium, count: 1).first
            }
        }

        let example = try await exampleTask

        let studyTopic = StudyTopic(
            name: topic,
            summary: summary.summary,
            keyPoints: summary.keyPoints,
            codeExample: example.code,
            walkthroughSnippets: example.walkthrough.map(\.snippet),
            walkthroughExplanations: example.walkthrough.map(\.explanation)
        )
        studyTopic.quizPool = (easy + medium).map { PersistedQuizQuestion(from: $0) }
        studyTopic.codeAnalysisPool = []

        modelContext.insert(studyTopic)
        try modelContext.save()

        print("⏱️ generateAndPersist('\(topic)'): tela liberada em \(String(format: "%.1f", Date().timeIntervalSince(totalStart)))s — difícil + análise de código seguem em background.")

        // Difícil + análise de código em background, alvo cheio (também
        // repõe fácil/média se o validador descartou itens). Prioridade
        // .nextSession: o usuário já está na tela do tópico e pode iniciar
        // um quiz em breve — mais urgente que poolFill genérico, mas atrás
        // de qualquer geração user-blocking de outro tópico.
        startBackgroundGrowthIfNeeded(
            for: studyTopic, topicName: topic, context: context,
            targets: (targetEasy, targetMedium, targetHard, targetCodeAnalysis),
            priority: .nextSession
        )
        return studyTopic
    }

    /// Instrumentação (Plano V6, PLAN_00): loga a duração de cada etapa de
    /// geração — é isso que permite ver, no console, onde o tempo realmente
    /// vai — e agora TAMBÉM alimenta a `GenerationMetricsStore` com o mesmo
    /// dado estruturado, além do `print` já existente (aditivo, o `print`
    /// não foi removido).
    private static func timed<T>(
        _ name: String,
        topic: String = "",
        engine: GenerationMetrics.Engine = .foundationModels,
        taskType: GenerationMetrics.TaskType? = nil,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let start = Date()
        defer {
            let elapsedMs = Date().timeIntervalSince(start) * 1000
            print("⏱️ [\(name)] \(String(format: "%.1f", elapsedMs / 1000))s")
            if let taskType {
                Task {
                    await GenerationMetricsStore.shared.record(
                        GenerationMetrics(
                            engine: engine,
                            taskType: taskType,
                            topic: topic,
                            modelID: engine == .mlx ? MLXService.modelID : "system",
                            totalTimeMs: elapsedMs
                        )
                    )
                }
            }
        }
        return try await body()
    }

    /// Plano V3 4.1 — top-up pós-sessão: chamado quando uma sessão de quiz
    /// ou de análise de código termina (ver TopicStudyView), completa o
    /// pool até o alvo cheio (targetEasy/Medium/Hard/CodeAnalysis) — nunca
    /// além disso. É esse o mecanismo que faz o pool crescer com uso real,
    /// em vez de tentar prever tudo já na criação do tópico.
    func replenishAfterSession(topicName: String) async {
        guard let topic = try? fetchExisting(topic: topicName) else { return }
        guard topic.sourceDatasetVersion == DatasetVersion.current else { return }

        let quizTarget = targetEasy + targetMedium + targetHard
        guard topic.quizPool.count < quizTarget || topic.codeAnalysisPool.count < targetCodeAnalysis else {
            return // já no buffer cheio — não gera além dele
        }

        print("🔵 replenishAfterSession: repondo pool de '\(topicName)' até o buffer cheio (\(topic.quizPool.count)/\(quizTarget) quiz, \(topic.codeAnalysisPool.count)/\(targetCodeAnalysis) análise).")
        let context = await generator.retrieveContext(for: topicName, topK: 3)
        // Prioridade .nextSession (Plano V3 4.2): mais urgente que um
        // enchimento de pool genérico, já que está preparando especificamente
        // a PRÓXIMA sessão do usuário nesse tópico — mas ainda atrás de
        // qualquer geração user-blocking em andamento em outro tópico.
        startBackgroundGrowthIfNeeded(
            for: topic, topicName: topicName, context: context,
            targets: (targetEasy, targetMedium, targetHard, targetCodeAnalysis),
            priority: .nextSession
        )
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
    /// da UI. `targets` é explícito (Plano V3 4.1) porque os chamadores
    /// pedem alvos diferentes: piso da 1ª sessão na criação, alvo cheio na
    /// retomada de geração interrompida e no top-up pós-sessão.
    private func startBackgroundGrowthIfNeeded(
        for topic: StudyTopic,
        topicName: String,
        context: String,
        targets: (easy: Int, medium: Int, hard: Int, codeAnalysis: Int),
        priority: GenerationOrchestrator.Priority
    ) {
        guard !topic.isGeneratingPool else { return }
        topic.isGeneratingPool = true
        try? modelContext.save()

        let topicID = topic.persistentModelID
        let container = modelContext.container
        let generator = self.generator

        // .utility, não .background: QoS .background é a primeira vítima do
        // App Nap/throttling do macOS quando o app perde o foco.
        Task.detached(priority: .utility) {
            await TopicRepository.growPoolInBackground(
                topicID: topicID,
                container: container,
                generator: generator,
                topicName: topicName,
                context: context,
                targets: targets,
                priority: priority
            )
        }
    }

    /// Roda fora do MainActor. Sempre reverte `isGeneratingPool` ao final,
    /// mesmo em caso de erro.
    ///
    /// As DUAS trilhas rodam EM PARALELO (antes eram sequenciais e o MLX —
    /// incluindo o download do modelo — só começava depois de ~19 gerações
    /// do Foundation Models):
    ///   Trilha A (Foundation Models): fácil → média
    ///   Trilha B (MLX): download/carga do modelo → difícil → análise de código
    /// Cada trilha usa seu PRÓPRIO ModelContext (nunca compartilhado entre
    /// tasks concorrentes); os appends são de objetos novos e independentes,
    /// então os saves não conflitam.
    nonisolated private static func growPoolInBackground(
        topicID: PersistentIdentifier,
        container: ModelContainer,
        generator: StudyGenerator,
        topicName: String,
        context: String,
        targets: (easy: Int, medium: Int, hard: Int, codeAnalysis: Int),
        priority: GenerationOrchestrator.Priority
    ) async {
        // App Nap (macOS): sem isso, o app perder o foco (ou minimizar a
        // janela) faz o sistema estrangular CPU/timers/I/O do processo e a
        // geração em background praticamente PARA até o app voltar ao foco.
        // `.userInitiatedAllowingIdleSystemSleep` desativa o App Nap durante
        // a atividade, mas ainda permite o Mac dormir normalmente;
        // `.automaticTerminationDisabled` evita o sistema encerrar o app
        // "ocioso" no meio da geração. O endActivity no defer garante que o
        // sistema volta ao comportamento normal ao terminar (sucesso ou erro).
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .automaticTerminationDisabled],
            reason: "Gerando pool de questões de '\(topicName)' em background"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        await withTaskGroup(of: Void.self) { group in

            // Trilha A — Foundation Models (fácil + média)
            group.addTask {
                let fmContext = ModelContext(container)
                func fetchTopic() -> StudyTopic? {
                    fmContext.model(for: topicID) as? StudyTopic
                }
                do {
                    try await growDifficulty(
                        .easy, target: targets.easy,
                        fetchTopic: fetchTopic, backgroundContext: fmContext,
                        generator: generator, topicName: topicName, context: context, priority: priority
                    )
                    try await growDifficulty(
                        .medium, target: targets.medium,
                        fetchTopic: fetchTopic, backgroundContext: fmContext,
                        generator: generator, topicName: topicName, context: context, priority: priority
                    )
                } catch {
                    print("⚠️ TopicRepository: erro ao crescer pool fácil/média em background para '\(topicName)': \(error)")
                }
            }

            // Trilha B — MLX (download começa IMEDIATAMENTE, em paralelo
            // com a trilha A; é o passo mais demorado na primeira execução)
            group.addTask {
                let mlxContext = ModelContext(container)
                func fetchTopic() -> StudyTopic? {
                    mlxContext.model(for: topicID) as? StudyTopic
                }
                do {
                    try await MLXService.shared.loadModel()
                    try await growDifficulty(
                        .hard, target: targets.hard,
                        fetchTopic: fetchTopic, backgroundContext: mlxContext,
                        generator: generator, topicName: topicName, context: context, priority: priority
                    )
                    try await growCodeAnalysis(
                        target: targets.codeAnalysis,
                        fetchTopic: fetchTopic, backgroundContext: mlxContext,
                        generator: generator, topicName: topicName, context: context, priority: priority
                    )
                } catch {
                    print("⚠️ TopicRepository: erro ao crescer pool difícil/análise de código (MLX) em background para '\(topicName)': \(error)")
                }
            }
        }

        // Sucesso ou erro: sempre reverter a flag (context próprio, criado
        // depois que as duas trilhas terminaram).
        let finalContext = ModelContext(container)
        if let topic = finalContext.model(for: topicID) as? StudyTopic {
            topic.isGeneratingPool = false
            try? finalContext.save()
        }
    }

    nonisolated private static func growDifficulty(
        _ difficulty: Difficulty,
        target: Int,
        fetchTopic: () -> StudyTopic?,
        backgroundContext: ModelContext,
        generator: StudyGenerator,
        topicName: String,
        context: String,
        priority: GenerationOrchestrator.Priority
    ) async throws {
        // Trava de segurança: se o QuestionValidator descartar o lote
        // inteiro (sanitização + 1 regeneração ainda inválidas) repetidas
        // vezes seguidas, desiste dessa dificuldade em vez de girar pra
        // sempre sem o pool nunca crescer — o top-up da Fase 4 tenta de novo depois.
        var consecutiveEmptyBatches = 0

        while true {
            guard let topic = fetchTopic() else { return }
            let currentCount = topic.quizPool.filter { $0.difficulty == difficulty.rawValue }.count
            if currentCount >= target { return }

            // Lotes pequenos (3-5), nunca tudo de uma vez.
            let batchSize = min(4, target - currentCount)
            let rawBatch = try await generator.generateQuizBatch(
                topic: topicName,
                context: context,
                difficulty: difficulty,
                count: batchSize,
                priority: priority
            )
            // PLAN_00: taskType aproximado a partir da dificuldade — usado só
            // para identificar de qual pool veio o retryCount registrado,
            // não afeta a validação em si.
            let taskType: GenerationMetrics.TaskType = {
                switch difficulty {
                case .easy: return .easyQuiz
                case .medium: return .mediumQuiz
                case .hard: return .hardQuizDraft
                }
            }()
            let batch = await QuestionValidator.processQuizBatch(rawBatch, topic: topicName, taskType: taskType) {
                try await generator.generateQuizBatch(topic: topicName, context: context, difficulty: difficulty, count: 1, priority: priority).first
            }

            if batch.isEmpty {
                consecutiveEmptyBatches += 1
                if consecutiveEmptyBatches >= 3 {
                    print("❌ TopicRepository: 3 lotes seguidos de '\(difficulty.rawValue)' descartados pelo validador pra '\(topicName)' — desistindo por ora.")
                    return
                }
                continue
            }
            consecutiveEmptyBatches = 0

            guard let topicAgain = fetchTopic() else { return }
            topicAgain.quizPool.append(contentsOf: batch.map { PersistedQuizQuestion(from: $0) })
            try backgroundContext.save()
        }
    }

    /// Faz crescer o pool de análise de código em background — antes desta
    /// mudança, esse pool só era preenchido uma vez (na geração inicial) e
    /// nunca mais crescia. Segue o mesmo padrão de growDifficulty.
    nonisolated private static func growCodeAnalysis(
        target: Int,
        fetchTopic: () -> StudyTopic?,
        backgroundContext: ModelContext,
        generator: StudyGenerator,
        topicName: String,
        context: String,
        priority: GenerationOrchestrator.Priority
    ) async throws {
        var consecutiveEmptyBatches = 0

        while true {
            guard let topic = fetchTopic() else { return }
            let currentCount = topic.codeAnalysisPool.count
            if currentCount >= target { return }

            let batchSize = min(4, target - currentCount)
            let rawBatch = try await generator.generateCodeAnalysisBatch(
                topic: topicName,
                context: context,
                count: batchSize,
                priority: priority
            )
            let batch = await QuestionValidator.processCodeAnalysisBatch(rawBatch, topic: topicName, taskType: .codeAnalysisDraft) {
                try await generator.generateCodeAnalysisBatch(topic: topicName, context: context, count: 1, priority: priority).first
            }

            if batch.isEmpty {
                consecutiveEmptyBatches += 1
                if consecutiveEmptyBatches >= 3 {
                    print("❌ TopicRepository: 3 lotes seguidos de análise de código descartados pelo validador pra '\(topicName)' — desistindo por ora.")
                    return
                }
                continue
            }
            consecutiveEmptyBatches = 0

            guard let topicAgain = fetchTopic() else { return }
            topicAgain.codeAnalysisPool.append(contentsOf: batch.map { PersistedCodeAnalysisQuestion(from: $0) })
            try backgroundContext.save()
        }
    }
}
