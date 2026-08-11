//
//  TopicRepository.swift
//  SwiftStudyCoach
//
//  Camada de persistência/orquestração entre a UI e o StudyGenerator.
//  Responsável por: (1) servir um StudyTopic do cache quando possível, sem
//  nenhuma chamada nova ao Foundation Models; (2) gerar e persistir TUDO,
//  de forma síncrona (Plano V4 Fase 1), na primeira visita a um tópico;
//  (3) sortear o quiz a partir do pool já existente; (4) crescimento em
//  background só como rede de segurança (pool incompleto) e top-up
//  pós-sessão (replenishAfterSession).
//

import Foundation
import SwiftData

@MainActor
@Observable
final class TopicRepository {

    private let modelContext: ModelContext
    private let generator: StudyGenerator

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
                    return try await generateAndPersist(topic: topic)
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

        // Plano V3 4.2: o usuário está parado nesta tela esperando — cancela
        // qualquer enchimento de pool (.poolFill) de OUTROS tópicos que
        // ainda não começou a rodar, pra essa geração user-blocking não
        // ficar atrás de trabalho de segundo plano na fila do orchestrator.
        await GenerationOrchestrator.shared.cancelPending(priority: .poolFill)

        // Contexto de documentação recuperado uma única vez e reaproveitado
        // nas chamadas de geração abaixo. Plano V5: dataset caiu pra 3
        // tópicos com no máximo 3 chunks cada — topK 3 pega o tópico
        // INTEIRO sempre (sem cortar chunk fora, como acontecia com o
        // topK 2 antigo — Property Wrappers, por exemplo, perdia o chunk
        // do @Observable, a abordagem moderna). Contexto do exemplo de
        // código também subiu (1 → 2) pra reduzir alucinação.
        let context = await generator.retrieveContext(for: topic, topK: 3)
        let codeContext = await generator.retrieveContext(for: topic, topK: 2)

        // Plano V4 Fase 1 — fluxo 100% SÍNCRONO: gera TUDO em variáveis
        // locais, numa cadeia linear de awaits (sem Trilha A/Trilha B
        // concorrentes), e só insere/salva no SwiftData quando resumo,
        // passo a passo, quiz completo (fácil+média+difícil, nas metas) e
        // análise de código estiverem prontos. A tela de loading
        // (TopicStudyView.isLoading) só libera quando este método retorna
        // — a página só abre com tudo pronto. Se qualquer chamada falhar,
        // o throws propaga antes de tocar no modelContext e nada fica
        // persistido pela metade.
        //
        // Ordem: FM primeiro (resumo + quiz fácil/média — rápido, sem
        // download), e só depois o MLX carrega o modelo e faz, em
        // sequência, passo a passo → quiz difícil → análise de código
        // (cada um via rascunho MLX + formatação FM).
        // Plano V3 3.1 (mantido): todo lote passa pelo QuestionValidator.
        let summary = try await generator.generateSummary(topic: topic, context: context)

        let rawEasy = try await generator.generateQuizBatch(topic: topic, context: context, difficulty: .easy, count: targetEasy)
        let easy = await QuestionValidator.processQuizBatch(rawEasy) {
            try await generator.generateQuizBatch(topic: topic, context: context, difficulty: .easy, count: 1).first
        }
        let rawMedium = try await generator.generateQuizBatch(topic: topic, context: context, difficulty: .medium, count: targetMedium)
        let medium = await QuestionValidator.processQuizBatch(rawMedium) {
            try await generator.generateQuizBatch(topic: topic, context: context, difficulty: .medium, count: 1).first
        }

        // A partir daqui entra o MLX (download do modelo na 1ª execução —
        // a tela de loading mostra o progresso via ModelDownloadView).
        let example = try await generator.generateCodeExample(topic: topic, context: codeContext)

        // Hotfix pós-teste: pedir o alvo inteiro (6) numa chamada só fazia o
        // StudyGenerator completar item a item, SEM limite, sempre que o MLX
        // devolvia menos rascunhos que o pedido num lote (visto com o Qwen
        // 3B em lotes grandes — separador nem sempre respeitado; o 14B atual
        // segue formato com bem mais consistência, mas o padrão de lotes
        // pequenos + desistência é mantido como defesa, sem custo real).
        // generateQuizPool/generateCodeAnalysisPool reintroduzem o mesmo
        // padrão de resiliência que já existia em growDifficulty/
        // growCodeAnalysis (lotes pequenos + desistência após 3 lotes
        // vazios seguidos), mas de forma síncrona — evita a maratona de
        // gerações MLX sequenciais que travava a tela de loading inteira.
        let hard = await generateQuizPool(topic: topic, context: context, difficulty: .hard, target: targetHard)
        let analysis = await generateCodeAnalysisPool(topic: topic, context: context, target: targetCodeAnalysis)

        let studyTopic = StudyTopic(
            name: topic,
            summary: summary.summary,
            keyPoints: summary.keyPoints,
            codeExample: example.code,
            walkthroughSnippets: example.walkthrough.map(\.snippet),
            walkthroughExplanations: example.walkthrough.map(\.explanation)
        )
        studyTopic.quizPool = (easy + medium + hard).map { PersistedQuizQuestion(from: $0) }
        studyTopic.codeAnalysisPool = analysis.map { PersistedCodeAnalysisQuestion(from: $0) }

        modelContext.insert(studyTopic)
        try modelContext.save()

        // Plano V4 Fase 1: NENHUM crescimento em background no caminho de
        // criação inicial — o pool já nasce completo (nas metas). O
        // startBackgroundGrowthIfNeeded continua existindo só como rede de
        // segurança pra pool incompleto (validador descartou itens, app
        // fechado no meio — ver fetchOrCreate) e pro top-up pós-sessão
        // (replenishAfterSession), que roda depois que o usuário já fechou
        // a sessão, não durante o carregamento de nenhuma tela.
        return studyTopic
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

    /// Gera o pool de UMA dificuldade em lotes pequenos (≤3), com o mesmo
    /// padrão de resiliência de `growDifficulty` (validador por lote +
    /// desistência após 3 lotes vazios seguidos), mas de forma síncrona —
    /// usado no caminho de criação inicial (Fase 1) pra quiz difícil, que
    /// passa pelo MLX. Nunca lança: se um lote falhar (erro do MLX/modelo
    /// indisponível) ou a desistência for atingida, retorna o que já tiver
    /// juntado — um pool abaixo do alvo aqui não é fatal, porque
    /// `fetchOrCreate` detecta o pool incompleto na próxima visita e
    /// completa em background (Fase 4-safe, sem travar a UI).
    private func generateQuizPool(topic: String, context: String, difficulty: Difficulty, target: Int) async -> [QuizQuestion] {
        var results: [QuizQuestion] = []
        var consecutiveEmptyBatches = 0

        while results.count < target {
            let batchSize = min(3, target - results.count)
            do {
                let raw = try await generator.generateQuizBatch(topic: topic, context: context, difficulty: difficulty, count: batchSize)
                let batch = await QuestionValidator.processQuizBatch(raw) {
                    try await self.generator.generateQuizBatch(topic: topic, context: context, difficulty: difficulty, count: 1).first
                }
                if batch.isEmpty {
                    consecutiveEmptyBatches += 1
                    if consecutiveEmptyBatches >= 3 {
                        print("❌ TopicRepository: 3 lotes seguidos de '\(difficulty.rawValue)' descartados pelo validador pra '\(topic)' — seguindo com \(results.count)/\(target) (top-up completa depois).")
                        break
                    }
                    continue
                }
                consecutiveEmptyBatches = 0
                results.append(contentsOf: batch)
            } catch {
                print("⚠️ TopicRepository: erro ao gerar lote '\(difficulty.rawValue)' pra '\(topic)': \(StudyGeneratorError.describe(error)) — seguindo com \(results.count)/\(target).")
                break
            }
        }
        return results
    }

    /// Equivalente a `generateQuizPool`, mas pro pool de análise de código.
    private func generateCodeAnalysisPool(topic: String, context: String, target: Int) async -> [CodeAnalysisQuestion] {
        var results: [CodeAnalysisQuestion] = []
        var consecutiveEmptyBatches = 0

        while results.count < target {
            let batchSize = min(3, target - results.count)
            do {
                let raw = try await generator.generateCodeAnalysisBatch(topic: topic, context: context, count: batchSize)
                let batch = await QuestionValidator.processCodeAnalysisBatch(raw) {
                    try await self.generator.generateCodeAnalysisBatch(topic: topic, context: context, count: 1).first
                }
                if batch.isEmpty {
                    consecutiveEmptyBatches += 1
                    if consecutiveEmptyBatches >= 3 {
                        print("❌ TopicRepository: 3 lotes seguidos de análise de código descartados pelo validador pra '\(topic)' — seguindo com \(results.count)/\(target) (top-up completa depois).")
                        break
                    }
                    continue
                }
                consecutiveEmptyBatches = 0
                results.append(contentsOf: batch)
            } catch {
                print("⚠️ TopicRepository: erro ao gerar lote de análise de código pra '\(topic)': \(StudyGeneratorError.describe(error)) — seguindo com \(results.count)/\(target).")
                break
            }
        }
        return results
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

        Task.detached(priority: .background) {
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
            let batch = await QuestionValidator.processQuizBatch(rawBatch) {
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
            let batch = await QuestionValidator.processCodeAnalysisBatch(rawBatch) {
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
