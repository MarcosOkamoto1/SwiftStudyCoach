//
//  TopicRepository.swift
//  SwiftStudyCoach
//
//  Camada de persistência/orquestração entre a UI e o StudyGenerator.
//  Responsável por: (1) servir um StudyTopic do cache quando possível, sem
//  nenhuma chamada nova ao Foundation Models; (2) na primeira visita a um
//  tópico, gerar e persistir em DUAS FASES (ver abaixo); (3) sortear o quiz
//  a partir do pool já existente; (4) crescimento em background como rede de
//  segurança (pool incompleto) e top-up pós-sessão (replenishAfterSession).
//
//  PLAN_06 — persistência em 2 fases (SOLUTIONS_PLAN.md §16.2), no lugar da
//  escrita atômica única que existia antes:
//
//    FASE 1 (síncrona, bloqueia a tela) — generateAndPersistPhase1:
//      resumo + quiz fácil + quiz média + exemplo de código FM-only.
//      4 chamadas Foundation Models, ZERO MLX, ZERO carga de modelo de 7B.
//      Persiste um StudyTopic VÁLIDO e retorna — a tela já pode aparecer.
//
//    FASE 2 (background, disparada logo depois, NUNCA aguardada) — startPhase2:
//      (a) upgrade do exemplo de código via MLX — REAL desde o PLAN_07;
//      (b) crescimento de pool já existente (difícil + análise de código).
//      Aplica PATCHES no StudyTopic JÁ PERSISTIDO (mesmo persistentModelID),
//      nunca cria um segundo objeto. Erro aqui não derruba a tela (§16.5).
//
//  PLAN_07 — a trilha (a) deixou de ser no-op: `runBackgroundUpgrade` roda o
//  pipeline MLX→crítica→formatação completo (Estratégia D, §5.2 passos 4-8)
//  e `applyCodeExampleUpgrade` aplica o resultado como UPDATE no objeto que
//  a tela já está mostrando — só se ele for estruturalmente válido E de fato
//  diferente do exemplo FM-only da Fase 1. Nenhum StudyTopic novo é criado
//  em nenhum caminho: o patch localiza o objeto por `PersistentIdentifier`,
//  o mesmo padrão que o crescimento de pool já usava.
//
//  Antes disto, o V6 gerava o exemplo de código na "trilha MLX" em paralelo
//  com o resumo/quiz, mas ainda DENTRO do caminho bloqueante: toda abertura
//  de tópico novo esperava a carga + geração do modelo de 7B (F1, o gargalo
//  #1 do SOLUTIONS_PLAN.md).
//

import Foundation
import SwiftData

enum TopicRepositoryError: LocalizedError {
    /// A Task de geração terminou sem lançar erro, mas o fetch local não
    /// achou o StudyTopic persistido pro tópico — defensivo, não deveria
    /// acontecer na prática (a Fase 1 sempre persiste antes de retornar),
    /// mas evita um crash silencioso se acontecer.
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
    /// inteira em paralelo (visto ao vivo: o print de entrada da geração —
    /// hoje "generateAndPersistPhase1 CHAMADO" — aparecendo duas vezes pro
    /// mesmo tópico) — as duas competiam pela mesma fila do
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
    // PLAN_10: alvo do pool de análise de código quando ele É gerado — mas
    // não é mais gerado especulativamente na criação do tópico (alvo `0`
    // nessa chamada específica, ver `startPhase2`). Este valor só entra em
    // jogo em `ensureCodeAnalysisPool` (1º toque no botão) e nos top-ups
    // subsequentes de um pool já iniciado.
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
                // PLAN_06: cache HIT é equivalente a "Fase 1 já concluída" —
                // a tela é mostrável de imediato. Se o crescimento de pool for
                // retomado logo abaixo, ele sobrescreve com o estágio próprio.
                GenerationStageStore.shared.set(.ready, for: topic)

                // Se o pool ficou incompleto (ex: download do MLX falhou ou o
                // app foi fechado no meio do crescimento), retoma o
                // crescimento em background — antes, um pool incompleto
                // ficava travado pra sempre no cache HIT.
                let quizTarget = targetEasy + targetMedium + targetHard
                // PLAN_10: análise de código só conta como "pool incompleto"
                // se já tiver sido INICIADA (pool não-vazio) — pool vazio
                // agora é o estado normal até o usuário tocar o botão pela
                // 1ª vez (ensureCodeAnalysisPool), não mais "geração
                // interrompida" pedindo retomada automática.
                let codeAnalysisIncomplete = !existing.codeAnalysisPool.isEmpty && existing.codeAnalysisPool.count < targetCodeAnalysis
                if existing.quizPool.count < quizTarget || codeAnalysisIncomplete {
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

    /// Envolve a Fase 1 (`generateAndPersistPhase1`) com deduplicação por tópico (ver
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
                _ = try await generateAndPersistPhase1(topic: topic)
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

    // MARK: - FASE 1 (síncrona — 4 chamadas FM, ZERO MLX)

    /// PLAN_06 / SOLUTIONS_PLAN.md §16.2 — gera e persiste o MÍNIMO
    /// MOSTRÁVEL de um tópico novo e retorna: resumo, quiz fácil, quiz
    /// média e exemplo de código FM-only. São 4 chamadas ao Foundation
    /// Models, em série, e **nenhuma** chamada ao MLX — nem geração, nem
    /// `loadModel()`.
    ///
    /// É a mudança de latência mais importante do plano: antes, o exemplo de
    /// código rodava aqui pelo pipeline MLX→crítica→formatação, então toda
    /// abertura de tópico novo pagava a carga + geração de um modelo de 7B
    /// no relógio do usuário (F1). O `async let` que colocava essa trilha em
    /// paralelo com a trilha FM ajudava, mas não resolvia: o caminho
    /// bloqueante ainda AGUARDAVA o MLX terminar antes de persistir.
    ///
    /// O que era feito depois (difícil, análise de código) e o que passou a
    /// ser feito depois (upgrade MLX do exemplo) vão para a Fase 2, disparada
    /// em `startPhase2` e nunca aguardada por este caminho.
    ///
    /// As 4 chamadas são SEQUENCIAIS de propósito: a fila serial do
    /// `GenerationOrchestrator` já garante uma chamada FM em voo por vez, então
    /// paralelizá-las não daria ganho nenhum — só embaralharia a ordem das
    /// etapas reportadas em `GenerationStage`.
    private func generateAndPersistPhase1(topic: String) async throws -> StudyTopic {
        // TEMP DEBUG (checklist Parte 5, item 4): confirma que esse método só
        // roda na primeira visita a um tópico. Se aparecer de novo numa
        // segunda visita ao MESMO tópico (mesma DatasetVersion), é bug de cache.
        print("🔵 generateAndPersistPhase1 CHAMADO para '\(topic)' — isso deveria acontecer só na 1ª visita (ou após trocar DatasetVersion.current).")

        // Plano V3 4.2: o usuário está parado nesta tela esperando — cancela
        // qualquer enchimento de pool (.poolFill) de OUTROS tópicos que
        // ainda não começou a rodar, pra essa geração user-blocking não
        // ficar atrás de trabalho de segundo plano na fila do orchestrator.
        await GenerationOrchestrator.shared.cancelPending(priority: .poolFill)

        let totalStart = Date()
        let stages = GenerationStageStore.shared
        let generator = self.generator

        do {
            // Contexto de documentação recuperado uma única vez e reaproveitado
            // nas chamadas de geração abaixo. Plano V5: dataset caiu pra 3
            // tópicos com no máximo 3 chunks cada — topK 3 pega o tópico
            // INTEIRO sempre (sem cortar chunk fora, como acontecia com o
            // topK 2 antigo — Property Wrappers, por exemplo, perdia o chunk
            // do @Observable, a abordagem moderna). Contexto do exemplo de
            // código também subiu (1 → 2) pra reduzir alucinação.
            //
            // PLAN_04: para tópico exato isto é síncrono e não toca no índice
            // de embeddings — `.indexing` aqui é praticamente instantâneo e só
            // fica visível no fallback fuzzy.
            stages.set(.indexing, for: topic)
            let context = await generator.retrieveContext(for: topic, topK: 3)
            let codeContext = await generator.retrieveContext(for: topic, topK: 2)

            stages.set(.generatingSummary, for: topic)
            let summary = try await Self.timed("resumo", topic: topic) {
                try await generator.generateSummary(topic: topic, context: context)
            }

            // Plano V3 3.1 (mantido): todo lote passa pelo QuestionValidator.
            stages.set(.generatingQuizEasy, for: topic)
            let easy = try await Self.timed("quiz fácil (\(targetEasy) + validação)", topic: topic) {
                let raw = try await generator.generateQuizBatch(topic: topic, context: context, difficulty: .easy, count: self.targetEasy)
                return await QuestionValidator.processQuizBatch(raw, topic: topic, taskType: .easyQuiz) {
                    try await generator.generateQuizBatch(topic: topic, context: context, difficulty: .easy, count: 1).first
                }
            }

            stages.set(.generatingQuizMedium, for: topic)
            let medium = try await Self.timed("quiz média (\(targetMedium) + validação)", topic: topic) {
                let raw = try await generator.generateQuizBatch(topic: topic, context: context, difficulty: .medium, count: self.targetMedium)
                return await QuestionValidator.processQuizBatch(raw, topic: topic, taskType: .mediumQuiz) {
                    try await generator.generateQuizBatch(topic: topic, context: context, difficulty: .medium, count: 1).first
                }
            }

            // taskType `nil` de propósito: `StudyGenerator.generateCodeExampleFM`
            // já registra a própria métrica (`.codeExampleFormat`) — registrar
            // de novo aqui duplicaria o dado. Este `timed` existe só pelo print.
            stages.set(.generatingCodeExample, for: topic)
            let example = try await Self.timed("exemplo de código (FM-only, Fase 1)") {
                try await generator.generateCodeExampleFM(topic: topic, context: codeContext)
            }

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

            stages.set(.ready, for: topic)
            // Marco "a tela apareceu" — é a partir DAQUI que o PLAN_07 mede a
            // latência tela→patch (§5.2, evidência pendente). Capturado antes
            // do print pra não contar o custo de I/O do console.
            let phase1CompletedAt = Date()
            print("⏱️ Fase 1 de '\(topic)': tela liberada em \(String(format: "%.1f", phase1CompletedAt.timeIntervalSince(totalStart)))s — sem nenhuma chamada MLX. Fase 2 (upgrade do exemplo + difícil + análise) segue em background.")

            startPhase2(for: studyTopic, topicName: topic, context: context, codeContext: codeContext, phase1CompletedAt: phase1CompletedAt)
            return studyTopic
        } catch {
            // §16.5: erro de FASE 1 continua derrubando a tela pro
            // `errorState` — aqui de fato não há conteúdo mostrável. O
            // `GenerationStage` só registra QUAL etapa quebrou.
            stages.set(.failed(step: Self.failedStep(from: error)), for: topic)
            throw error
        }
    }

    /// Extrai o nome da etapa de um `StudyGeneratorError.generationFailed`
    /// (que já carrega essa informação) para alimentar `.failed(step:)`.
    private static func failedStep(from error: Error) -> String {
        if let generatorError = error as? StudyGeneratorError,
           case .generationFailed(let step, _) = generatorError {
            return step
        }
        return "conteúdo do tópico"
    }

    // MARK: - FASE 2 (background — nunca aguardada pelo caminho síncrono)

    /// Dispara tudo que NÃO precisa estar pronto pra tela aparecer.
    /// Deliberadamente não-`async` e sem valor de retorno: não existe forma
    /// de a Fase 1 acidentalmente aguardar isto.
    ///
    /// (a) upgrade do exemplo de código via MLX (PLAN_07 — pipeline real:
    ///     rascunho MLX → crítica FM → formatação FM → patch);
    /// (b) crescimento do pool que já existia (difícil + análise de código),
    ///     com prioridade `.nextSession` — o usuário está na tela do tópico e
    ///     pode iniciar um quiz em breve, então é mais urgente que um
    ///     `.poolFill` genérico, mas ainda atrás de qualquer geração
    ///     user-blocking de outro tópico.
    private func startPhase2(for studyTopic: StudyTopic, topicName: String, context: String, codeContext: String, phase1CompletedAt: Date) {
        let topicID = studyTopic.persistentModelID
        let container = modelContext.container
        let generator = self.generator

        // (a) — PLAN_08: prioridade decidida pelos checks determinísticos
        // baratos (regex/sintático) sobre o exemplo FM-only que a Fase 1
        // acabou de persistir. Isto NUNCA decide SE o upgrade roda — ele
        // sempre roda, para 100% dos tópicos (a crítica MLX é quem
        // efetivamente pega os erros semânticos que o regex não alcança,
        // ver `DeterministicCodeChecks.swift`); decide só se ele entra na
        // fila do `GenerationOrchestrator` como `.poolFill` (padrão — é uma
        // melhoria de qualidade de algo que já está na tela e já é
        // utilizável, sem pressa) ou `.nextSession` (checks reprovaram —
        // sobe a urgência, mais recursos de background pro tópico com risco
        // heurístico maior).
        let checkResult = DeterministicCodeChecks.evaluate(studyTopic.codeExample)
        Task { await DeterministicCodeChecksStats.shared.record(checkResult, topic: topicName) }
        let upgradePriority: GenerationOrchestrator.Priority = checkResult.passed ? .poolFill : .nextSession

        // ⚠️ A prioridade mais baixa NÃO garante que o upgrade rode depois da
        // trilha (b): as duas trilhas disputam a fila do motor MLX, e o
        // `GenerationOrchestrator` ordena por prioridade mas NUNCA preempta
        // um job já em execução (F7, por design). Se o worker pegar o
        // rascunho do upgrade antes de a trilha (b) enfileirar o dela, o
        // upgrade roda primeiro — observado em execução real (rascunho do
        // upgrade em 17s, rascunho do quiz difícil só depois). A ordem entre
        // as duas trilhas é, portanto, uma CORRIDA, não uma garantia; o que
        // a prioridade garante é só que o upgrade nunca passa na frente de
        // algo user-blocking que chegue enquanto ele ainda está esperando.
        // É mais um motivo pra latência tela→patch ser medida em vez de
        // deduzida.
        Task.detached(priority: .utility) {
            await TopicRepository.runBackgroundUpgrade(
                topicID: topicID,
                container: container,
                generator: generator,
                topicName: topicName,
                codeContext: codeContext,
                priority: upgradePriority,
                phase1CompletedAt: phase1CompletedAt
            )
        }

        // (b) — crescimento do pool de quiz que já existia, sem mudanças de
        // comportamento (batching é PLAN_09). Análise de código NÃO entra
        // mais aqui com o alvo cheio (PLAN_10): o alvo inicial passa a ser 0
        // — o pool só começa a crescer quando `ensureCodeAnalysisPool` for
        // chamado (1º toque no botão em `TopicStudyView`). `0` é só o alvo
        // desta chamada específica (criação do tópico); `growPoolInBackground`
        // ainda tem uma segunda trava (pool vazio → pula a trilha de análise
        // de código) que cobre os outros chamadores (retomada, top-up).
        startBackgroundGrowthIfNeeded(
            for: studyTopic, topicName: topicName, context: context,
            targets: (targetEasy, targetMedium, targetHard, 0),
            priority: .nextSession
        )
    }

    /// Fase 2 (a) — PLAN_07: pede o upgrade do exemplo de código (pipeline
    /// MLX→crítica→formatação, §5.2 passos 4-7) e, se vier um candidato,
    /// entrega pro patch decidir se aplica (passo 8).
    ///
    /// Não lança e não propaga erro: `upgradeCodeExampleViaMLX` não lança por
    /// contrato, e uma falha do pipeline devolve `nil` — a tela continua
    /// mostrando o exemplo FM-only válido da Fase 1 (§16.5). Nenhum caminho
    /// daqui pra baixo cria um `StudyTopic`.
    ///
    /// Roda com App Nap desativado pelo mesmo motivo de `growPoolInBackground`
    /// (ver comentário lá): sem isso, o usuário tirar o foco do app durante o
    /// upgrade — que é justamente o cenário provável, já que o upgrade existe
    /// pra rodar enquanto ele lê o artigo — estrangula o processo e o patch
    /// pode nunca chegar.
    nonisolated private static func runBackgroundUpgrade(
        topicID: PersistentIdentifier,
        container: ModelContainer,
        generator: StudyGenerator,
        topicName: String,
        codeContext: String,
        priority: GenerationOrchestrator.Priority,
        phase1CompletedAt: Date
    ) async {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .automaticTerminationDisabled],
            reason: "Revisando o exemplo de código de '\(topicName)' em background"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        // Hops de MainActor AGUARDADOS (e não `GenerationStageStore.update`,
        // que é fire-and-forget): a ordem entre as transições precisa ser
        // determinística — `.upgradingCodeExample` tem que estar publicado
        // ANTES de qualquer coisa que possa revertê-lo.
        await MainActor.run {
            GenerationStageStore.shared.set(.upgradingCodeExample, for: topicName)
        }

        // `revert` (e não `set`) em todas as saídas: a trilha (b) roda EM
        // PARALELO e pode já ter publicado `.generatingHardQuiz` ou
        // `.generatingCodeAnalysis` quando o upgrade termina — sobrescrever
        // com `.ready` apagaria um estágio que ainda está acontecendo de
        // verdade. Também não pode ficar pendurado em
        // `.upgradingCodeExample`: a tela mostraria "revisando o exemplo de
        // código" para sempre.
        func finishStage() async {
            await MainActor.run {
                GenerationStageStore.shared.revert(from: .upgradingCodeExample, to: .ready, for: topicName)
            }
        }

        guard let upgraded = await generator.upgradeCodeExampleViaMLX(
            topic: topicName,
            context: codeContext,
            priority: priority
        ) else {
            // Pipeline não produziu candidato: MLX indisponível, download do
            // modelo falhou, ou erro de geração em qualquer uma das 3 etapas.
            // Não é erro do ponto de vista do usuário — a Fase 1 continua
            // válida e visível —, então NÃO vira `.failed(step:)` (§16.5).
            print("ℹ️ runBackgroundUpgrade('\(topicName)'): nenhum upgrade a aplicar — exemplo FM-only da Fase 1 mantido.")
            await CodeExampleUpgradeStats.shared.record(
                .notProduced,
                topic: topicName,
                msSincePhase1: Date().timeIntervalSince(phase1CompletedAt) * 1000
            )
            await finishStage()
            return
        }

        let outcome = await TopicRepository.applyCodeExampleUpgrade(
            topicID: topicID,
            container: container,
            example: upgraded,
            topicName: topicName
        )
        await CodeExampleUpgradeStats.shared.record(
            outcome,
            topic: topicName,
            msSincePhase1: Date().timeIntervalSince(phase1CompletedAt) * 1000
        )
        await finishStage()
    }

    /// Aplica o resultado do upgrade num `StudyTopic` JÁ PERSISTIDO. Toda a
    /// lógica (validade, comparação, `UPDATE`) está na variante `static`
    /// logo abaixo — esta é só a porta de entrada a partir do MainActor.
    ///
    /// Assinatura pública pedida por §16.2: o caminho de produção
    /// (`runBackgroundUpgrade`) chama a `static` direto; esta existe para os
    /// integration tests do PLAN_16 poderem aplicar um patch e verificar,
    /// pelo `Outcome` devolvido, que o objeto foi ATUALIZADO em vez de
    /// duplicado — sem reimplementar a lógica no teste.
    @discardableResult
    func applyCodeExampleUpgrade(topicID: PersistentIdentifier, example: ExplainedCodeExample) async -> CodeExampleUpgradeStats.Outcome {
        let name = (modelContext.model(for: topicID) as? StudyTopic)?.name ?? ""
        return await TopicRepository.applyCodeExampleUpgrade(
            topicID: topicID,
            container: modelContext.container,
            example: example,
            topicName: name
        )
    }

    /// PLAN_07 (§5.2, passo 8) — decide se o candidato vira patch e, se sim,
    /// aplica.
    ///
    /// Quatro desfechos possíveis, e NENHUM deles cria objeto novo:
    ///   - inválido (truncado/vazio) → `.discardedInvalid`, nada é salvo, a
    ///     Fase 1 permanece;
    ///   - alvo sumiu ou `save()` falhou → `.saveFailed`, a Fase 1 permanece;
    ///   - válido mas idêntico ao que já está lá → `.unchanged`, e o `save()`
    ///     é PULADO. Isso não é só economia de I/O: salvar campos com valores
    ///     iguais ainda assim notificaria o SwiftData, e o `@Model` observável
    ///     dispararia um re-render da `TopicStudyView` — um "pisca" na tela
    ///     do usuário sem nenhuma mudança de conteúdo para justificá-lo;
    ///   - válido e diferente → `.changed`, `UPDATE` nos campos que já
    ///     existem no schema (`codeExample`, `walkthroughSnippets`,
    ///     `walkthroughExplanations`). É por isso que o plano não precisa de
    ///     migração de schema nem de bump de `DatasetVersion` (§16.7).
    ///
    /// A busca é por `persistentModelID`, então o objeto atualizado é
    /// literalmente o mesmo que a `TopicStudyView` já segura em
    /// `@State private var topic: StudyTopic?` — o save num `ModelContext`
    /// de background dispara o re-render pelo mesmo mecanismo reativo que o
    /// crescimento de pool já usa hoje (`TopicRepositoryTestView.swift:21-23`).
    /// Nunca há um segundo `StudyTopic` para o mesmo tópico.
    nonisolated private static func applyCodeExampleUpgrade(
        topicID: PersistentIdentifier,
        container: ModelContainer,
        example: ExplainedCodeExample,
        topicName: String
    ) async -> CodeExampleUpgradeStats.Outcome {
        guard StudyGenerator.isStructurallyValidCodeExample(example) else {
            print("⚠️ applyCodeExampleUpgrade: upgrade de '\(topicName)' é estruturalmente inválido (código vazio/truncado ou walkthrough incompleto) — descartado, exemplo FM-only da Fase 1 mantido.")
            return .discardedInvalid
        }

        // ModelContext PRÓPRIO (nunca o da UI, nunca compartilhado com outra
        // task concorrente) — mesmo padrão de growPoolInBackground, que já
        // roda com DOIS contextos simultâneos sobre este mesmo StudyTopic.
        // Este é o terceiro, e não conflita com eles porque escreve campos
        // DISJUNTOS: as trilhas de crescimento só fazem append em `quizPool`
        // /`codeAnalysisPool`, e o patch só toca os três atributos escalares
        // do exemplo de código. Nenhum caminho escreve o mesmo campo que
        // outro, então não existe last-write-wins entre eles.
        let patchContext = ModelContext(container)
        guard let topic = patchContext.model(for: topicID) as? StudyTopic else {
            // Objeto sumiu entre a Fase 1 e o fim do upgrade — na prática, o
            // usuário trocou `DatasetVersion.current` (ou um registro
            // quebrado foi apagado por `fetchOrCreate`) enquanto o pipeline
            // rodava. O conteúdo era bom; não há mais onde colocá-lo.
            print("⚠️ applyCodeExampleUpgrade: StudyTopic '\(topicName)' não encontrado (\(topicID)) — patch descartado.")
            return .saveFailed
        }

        let newSnippets = example.walkthrough.map(\.snippet)
        let newExplanations = example.walkthrough.map(\.explanation)

        // Comparação deliberadamente simples (§5.2, passo 8: "não precisa de
        // comparação semântica sofisticada"), só normalizando espaço em
        // branco nas pontas — uma diferença de indentação final não é motivo
        // pra trocar conteúdo debaixo dos olhos de quem está lendo.
        let sameCode = TopicRepository.normalized(topic.codeExample) == TopicRepository.normalized(example.code)
        let sameSnippets = topic.walkthroughSnippets.map(TopicRepository.normalized) == newSnippets.map(TopicRepository.normalized)
        let sameExplanations = topic.walkthroughExplanations.map(TopicRepository.normalized) == newExplanations.map(TopicRepository.normalized)

        guard !(sameCode && sameSnippets && sameExplanations) else {
            print("ℹ️ applyCodeExampleUpgrade: upgrade de '\(topicName)' é idêntico ao exemplo FM-only da Fase 1 — nenhum UPDATE feito (o FM sozinho já estava certo).")
            return .unchanged
        }

        topic.codeExample = example.code
        topic.walkthroughSnippets = newSnippets
        topic.walkthroughExplanations = newExplanations

        do {
            try patchContext.save()
            print("🟢 applyCodeExampleUpgrade: exemplo de código de '\(topicName)' atualizado no objeto existente (\(example.walkthrough.count) passos).")
            return .changed
        } catch {
            print("⚠️ applyCodeExampleUpgrade: falha ao salvar o patch de '\(topicName)': \(error)")
            GenerationStageStore.update(.failed(step: "a revisão do exemplo de código"), for: topicName)
            return .saveFailed
        }
    }

    /// Normalização mínima usada só na comparação "mudou algo?" acima —
    /// nunca no que é persistido (o texto salvo é o do modelo, intacto).
    nonisolated private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        // PLAN_10: só considera análise de código "precisando de top-up" se
        // o pool já tiver sido iniciado — senão todo fim de sessão de QUIZ
        // (que também chama isto) disparava geração de análise de código
        // que o usuário nunca pediu para ver.
        let codeAnalysisNeedsTopUp = !topic.codeAnalysisPool.isEmpty && topic.codeAnalysisPool.count < targetCodeAnalysis
        guard topic.quizPool.count < quizTarget || codeAnalysisNeedsTopUp else {
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

    // MARK: - Análise de código sob demanda (PLAN_10)

    /// PLAN_10 / `SOLUTIONS_PLAN.md` §14 — geração sob demanda do pool de
    /// análise de código: fica atrás de um botão em `TopicStudyView` (ao
    /// contrário do quiz, ação primária de "Praticar"), então deixou de ser
    /// gerado especulativamente junto com o resto do pool na criação do
    /// tópico (D8). É chamado no 1º toque no botão; a View reage ao
    /// `GenerationStage.generatingCodeAnalysis` enquanto isso roda
    /// (`backgroundStatusBadge` + botão desabilitado/opaco).
    ///
    /// Sem efeito (retorna cedo) se: o dataset mudou (cache stale — este
    /// pool é regenerado do zero na próxima `fetchOrCreate` de qualquer
    /// forma), o pool já tem itens (já foi gerado antes — top-up é
    /// `replenishAfterSession`, sem mudança), ou já existe uma geração em
    /// andamento pra este tópico (2º toque rápido no mesmo botão antes do
    /// 1º terminar).
    ///
    /// Prioridade `.userBlocking` — mesma usada em outros fluxos síncronos
    /// (Fase 1) — porque o usuário está literalmente parado nesta tela
    /// esperando o botão liberar; diferente do top-up pós-sessão
    /// (`replenishAfterSession`, `.nextSession`) e do enchimento genérico de
    /// pool (`.poolFill`), que seguem sem mudança.
    func ensureCodeAnalysisPool(topicName: String) async {
        guard let topic = try? fetchExisting(topic: topicName) else { return }
        guard topic.sourceDatasetVersion == DatasetVersion.current else { return }
        guard topic.codeAnalysisPool.isEmpty else { return }

        let stages = GenerationStageStore.shared
        guard stages.stage(for: topicName) != .generatingCodeAnalysis else {
            print("🟡 ensureCodeAnalysisPool: geração já em andamento para '\(topicName)' — ignorando novo toque.")
            return
        }

        print("🔵 ensureCodeAnalysisPool: 1º toque no botão de análise de código para '\(topicName)' — gerando sob demanda (.userBlocking).")
        let startedAt = Date()
        stages.set(.generatingCodeAnalysis, for: topicName)

        let context = await generator.retrieveContext(for: topicName, topK: 3)
        let topicID = topic.persistentModelID
        let mainContext = modelContext
        let generator = self.generator

        do {
            try await TopicRepository.growCodeAnalysis(
                target: targetCodeAnalysis,
                fetchTopic: { mainContext.model(for: topicID) as? StudyTopic },
                backgroundContext: mainContext,
                generator: generator,
                topicName: topicName,
                context: context,
                priority: .userBlocking
            )
        } catch {
            print("⚠️ ensureCodeAnalysisPool: erro ao gerar análise de código sob demanda para '\(topicName)': \(error)")
            stages.set(.failed(step: "a análise de código"), for: topicName)
        }

        let elapsedMs = Date().timeIntervalSince(startedAt) * 1000
        await CodeAnalysisOnDemandStats.shared.record(topic: topicName, latencyMs: elapsedMs)

        // Se deu erro, a linha acima já trocou pra `.failed(step:)` — o
        // `revert` abaixo só age se a etapa ainda for `.generatingCodeAnalysis`
        // (guard interno de `revert`), então não sobrescreve uma falha real.
        stages.revert(from: .generatingCodeAnalysis, to: .ready, for: topicName)
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
                    // §16.5: erro de Fase 2 NUNCA derruba a tela — vira só um
                    // aviso silencioso via GenerationStage.
                    await MainActor.run {
                        GenerationStageStore.shared.set(.failed(step: "a reposição do quiz fácil/média"), for: topicName)
                    }
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
                    // PLAN_06: este é agora o ÚNICO `loadModel()` do fluxo de
                    // abertura de um tópico novo — e ele roda com o artigo já
                    // na tela, não antes dela.
                    try await MLXService.shared.loadModel()
                    await MainActor.run {
                        GenerationStageStore.shared.set(.generatingHardQuiz, for: topicName)
                    }
                    try await growDifficulty(
                        .hard, target: targets.hard,
                        fetchTopic: fetchTopic, backgroundContext: mlxContext,
                        generator: generator, topicName: topicName, context: context, priority: priority
                    )
                    // PLAN_10: análise de código não cresce mais aqui
                    // especulativamente. Só entra nesta trilha automática de
                    // background se o pool JÁ tiver sido iniciado pelo
                    // usuário via `ensureCodeAnalysisPool` (1º toque no
                    // botão) — aí sim isto é o top-up normal (retomada de
                    // geração interrompida ou pós-sessão via
                    // `replenishAfterSession`), comportamento que não mudou.
                    // Pool vazio = tópico nunca teve o botão tocado = nada a
                    // fazer aqui.
                    //
                    // A checagem de `.generatingCodeAnalysis` é uma segunda
                    // trava (além do `isEmpty`): sem ela, um top-up disparado
                    // por `replenishAfterSession` enquanto `ensureCodeAnalysisPool`
                    // AINDA está gerando o 1º lote (pool já não-vazio, mas
                    // com o loop de `ensureCodeAnalysisPool` ainda em voo)
                    // faria DOIS `growCodeAnalysis` concorrentes escreverem
                    // no MESMO array `codeAnalysisPool` com dois
                    // `ModelContext` diferentes — quebra a premissa de "um
                    // escritor por pool" que o resto do arquivo documenta.
                    let alreadyGeneratingCodeAnalysis = await MainActor.run {
                        GenerationStageStore.shared.stage(for: topicName) == .generatingCodeAnalysis
                    }
                    if let topic = fetchTopic(), !topic.codeAnalysisPool.isEmpty, !alreadyGeneratingCodeAnalysis {
                        await MainActor.run {
                            GenerationStageStore.shared.set(.generatingCodeAnalysis, for: topicName)
                        }
                        try await growCodeAnalysis(
                            target: targets.codeAnalysis,
                            fetchTopic: fetchTopic, backgroundContext: mlxContext,
                            generator: generator, topicName: topicName, context: context, priority: priority
                        )
                    }
                } catch {
                    print("⚠️ TopicRepository: erro ao crescer pool difícil/análise de código (MLX) em background para '\(topicName)': \(error)")
                    await MainActor.run {
                        GenerationStageStore.shared.set(.failed(step: "o quiz difícil / a análise de código"), for: topicName)
                    }
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

        // PLAN_06: só marca `.backgroundComplete` se nenhuma das trilhas
        // registrou falha — senão o aviso silencioso de `.failed(step:)`
        // (§16.5) seria apagado por um estado de sucesso que não aconteceu.
        //
        // PLAN_07: e também não marca se o upgrade do exemplo de código
        // (trilha (a), independente desta) ainda estiver rodando — o
        // background NÃO está completo nesse caso. Sem esta guarda o
        // indicador "revisando o exemplo de código" sumiria da tela antes do
        // patch chegar, e o exemplo mudaria sozinho sem nenhum aviso prévio
        // — exatamente o efeito que o gatilho de reversão de §5.2 quer
        // evitar. Qual das duas trilhas termina primeiro é uma corrida (ver
        // comentário em `startPhase2`), então a guarda precisa existir nos
        // dois sentidos: esta protege o caso "o crescimento acabou antes",
        // e o `revert(from:)` de `runBackgroundUpgrade` protege o inverso.
        await MainActor.run {
            let stages = GenerationStageStore.shared
            let current = stages.stage(for: topicName)
            guard !current.isFailure, current != .upgradingCodeExample else { return }
            stages.set(.backgroundComplete, for: topicName)
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
