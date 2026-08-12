//
//  TopicRepositoryTestView.swift
//  SwiftStudyCoach
//
//  Tela TEMPORÁRIA de teste manual para a Parte 5 (validação do fluxo
//  completo em runtime). Exercita TopicRepository de ponta a ponta:
//  fetchOrCreate, sampleQuiz, crescimento do pool em background,
//  invalidação de cache por DatasetVersion e proteção contra geração
//  duplicada.
//
//  Não é UI final — é só instrumentação pra rodar o checklist de
//  PARTE-5-validacao-fluxo-completo.md. Pode apagar depois de validar.
//

#if DEBUG
import SwiftUI
import SwiftData

struct TopicRepositoryTestView: View {
    @Environment(\.modelContext) private var modelContext

    // @Query reflete automaticamente saves feitos pelo ModelContext de
    // background do TopicRepository — não precisa de polling manual pra
    // ver o pool crescer na tela.
    @Query(sort: \StudyTopic.createdAt, order: .reverse) private var allTopics: [StudyTopic]

    private let documentIndex = DocumentIndex.shared
    @State private var generator: StudyGenerator?
    @State private var repository: TopicRepository?
    @State private var isSettingUp = false
    @State private var setupError: String?

    // PLAN_05 — Model Benchmark Suite. Lógica isolada em
    // Services/ModelBenchmarkSuite.swift + Services/BenchmarkPrompts.swift;
    // esta view só dispara e exibe (ver "Implementação detalhada" do
    // PLAN_05 — opção (b), isolada pra sobreviver à limpeza de PLAN_17).
    @State private var benchmarkSuite: ModelBenchmarkSuite?
    @State private var benchmarkExportPath: String?
    @State private var rubricDrafts: [Int: BenchmarkRubricScore] = [:]

    // PLAN_12 — GPU cacheLimit sweep. Lógica isolada em
    // Services/GPUCacheLimitSweep.swift, reaproveita ModelBenchmarkSuite.
    @State private var cacheLimitSweep: GPUCacheLimitSweep?
    @State private var cacheLimitSweepExportPath: String?

    // PLAN_13 Parte 1 — experimento de concorrência FM (§15.4). Isolado em
    // Services/FMConcurrencyExperiment.swift; não passa pelo orchestrator
    // nem toca produção. Não depende do generator/repository — pode ser
    // criado direto.
    @State private var fmConcurrency = FMConcurrencyExperiment()
    @State private var fmConcurrencyExportPath: String?

    // PLAN_13 Parte 2 — análise 1ª-vs-2ª/3ª chamada MLX (§12.2), lendo a
    // GenerationMetricsStore do PLAN_00 e acumulando amostras entre sessões
    // do app em Documents/. Só medição — warmUp() não existe.
    @State private var warmupAnalyzer = MLXWarmupAnalyzer()

    @State private var topicName: String = "NavigationStack"
    @State private var isLoading = false
    @State private var loadErrorMessage: String?
    @State private var loadedTopicID: PersistentIdentifier?
    @State private var lastLoadDuration: TimeInterval?

    @State private var sampleA: [PersistedQuizQuestion] = []
    @State private var sampleB: [PersistedQuizQuestion] = []
    @State private var log: [String] = []

    @State private var raceTestTopicName: String = "Property Wrappers"
    @State private var raceTestResult: String?
    @State private var raceTestRunning = false

    private var loadedTopic: StudyTopic? {
        guard let loadedTopicID else { return nil }
        return allTopics.first { $0.persistentModelID == loadedTopicID }
    }

    var body: some View {
        NavigationStack {
            Form {
                setupSection
                loadTopicSection
                if let loadedTopic {
                    poolStatusSection(loadedTopic)
                    sampleQuizSection(loadedTopic)
                }
                datasetVersionSection
                raceConditionSection
                benchmarkSection
                cacheLimitSweepSection
                fmConcurrencySection
                mlxWarmupSection
                logSection
                allTopicsSection
            }
            .navigationTitle("Teste — Fluxo completo")
            .task { await setup() }
        }
    }

    // MARK: - Setup

    private var setupSection: some View {
        Section("Setup") {
            if isSettingUp {
                ProgressView("Indexando documentação e preparando o modelo...")
            } else if let setupError {
                Text(setupError).foregroundStyle(.red)
            } else if repository != nil {
                Text("✅ Pronto — \(documentIndex.chunks.count) chunks indexados").font(.caption)
                if let generator {
                    Text(generator.checkAvailability()).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func setup() async {
        guard repository == nil, !isSettingUp else { return }
        isSettingUp = true
        defer { isSettingUp = false }
        do {
            try await documentIndex.ensureReady()
            let gen = StudyGenerator(documentIndex: documentIndex)
            generator = gen
            repository = TopicRepository(modelContext: modelContext, generator: gen)
            benchmarkSuite = ModelBenchmarkSuite(studyGenerator: gen)
            cacheLimitSweep = GPUCacheLimitSweep(studyGenerator: gen)
        } catch {
            setupError = "Erro no setup: \(error.localizedDescription)"
        }
    }

    // MARK: - Item 1, 5, 6: gerar/carregar tópico (cache hit vs miss)

    private var loadTopicSection: some View {
        Section("1) Gerar / carregar tópico (checklist itens 1, 5, 6)") {
            TextField("Tópico (ex: NavigationStack, Property Wrappers, async/await)", text: $topicName)

            Button {
                Task { await loadTopic() }
            } label: {
                if isLoading {
                    ProgressView()
                } else {
                    Text("fetchOrCreate(topic:)")
                }
            }
            .disabled(topicName.isEmpty || isLoading || repository == nil)

            if let lastLoadDuration {
                Text(String(format: "Duração: %.2fs — %@", lastLoadDuration, lastLoadDuration < 0.3 ? "instantâneo (cache HIT esperado)" : "gerou de novo (esperado só na 1ª vez ou após trocar DatasetVersion)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let loadErrorMessage {
                Text(loadErrorMessage).foregroundStyle(.red)
            }

            Text("Dica: aperte 2x seguidas pro MESMO tópico. A 2ª deve ser quase instantânea e o console NÃO deve mostrar '🔵 generateAndPersistPhase1 CHAMADO' de novo — só '🟢 cache HIT'.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func loadTopic() async {
        guard let repository else { return }
        isLoading = true
        loadErrorMessage = nil
        defer { isLoading = false }

        let start = Date()
        do {
            let topic = try await repository.fetchOrCreate(topic: topicName)
            lastLoadDuration = Date().timeIntervalSince(start)
            loadedTopicID = topic.persistentModelID
            appendLog("Carregado '\(topic.name)' em \(String(format: "%.2f", lastLoadDuration ?? 0))s — resumo \(topic.summary.isEmpty ? "VAZIO ⚠️" : "OK (\(topic.summary.count) chars)"), \(topic.quizPool.count) quiz, \(topic.codeAnalysisPool.count) análise de código.")
        } catch {
            loadErrorMessage = "Erro: \(error.localizedDescription)"
            appendLog("❌ Erro ao carregar '\(topicName)': \(error.localizedDescription)")
        }
    }

    // MARK: - Item 2, 7: status do pool + crescimento em background

    private func poolStatusSection(_ topic: StudyTopic) -> some View {
        let easy = topic.quizPool.filter { $0.difficulty == Difficulty.easy.rawValue }.count
        let medium = topic.quizPool.filter { $0.difficulty == Difficulty.medium.rawValue }.count
        let hard = topic.quizPool.filter { $0.difficulty == Difficulty.hard.rawValue }.count
        let total = topic.quizPool.count

        return Section("2) Pool de quiz em background (checklist item 2)") {
            LabeledContent("Fácil", value: "\(easy) / 6")
            LabeledContent("Média", value: "\(medium) / 6")
            LabeledContent("Difícil", value: "\(hard) / 6")
            LabeledContent("Total", value: "\(total) / 24")
            LabeledContent("Análise de código", value: "\(topic.codeAnalysisPool.count) / 6")

            HStack {
                Circle()
                    .fill(topic.isGeneratingPool ? .orange : .green)
                    .frame(width: 8, height: 8)
                Text(topic.isGeneratingPool ? "isGeneratingPool = true (crescendo em background...)" : "isGeneratingPool = false (parado)")
                    .font(.caption)
            }

            Text("Deixe essa tela aberta alguns segundos — os números acima devem subir sozinhos até chegar perto de 40, sem você apertar nada (a @Query reflete os saves do background context automaticamente).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Item 3, 4: sampleQuiz varia entre chamadas e respeita 3/4/3

    private func sampleQuizSection(_ topic: StudyTopic) -> some View {
        Section("3) sampleQuiz — variação e proporção 3/4/3 (checklist itens 3, 4)") {
            Button("Sortear quiz (chamada A)") {
                guard let repository else { return }
                sampleA = repository.sampleQuiz(from: topic)
                appendLog("Sorteio A: \(describe(sampleA))")
            }
            Button("Sortear quiz de novo (chamada B)") {
                guard let repository else { return }
                sampleB = repository.sampleQuiz(from: topic)
                appendLog("Sorteio B: \(describe(sampleB))")
            }

            if !sampleA.isEmpty && !sampleB.isEmpty {
                let sameOrder = sampleA.map(\.persistentModelID) == sampleB.map(\.persistentModelID)
                Text(sameOrder ? "⚠️ A e B vieram na MESMA ordem/conjunto — rode de novo pra confirmar (pool pequeno pode coincidir)." : "✅ A e B vieram diferentes — sorteio está variando.")
                    .font(.caption)
                    .foregroundStyle(sameOrder ? .orange : .green)
            }

            if !sampleA.isEmpty {
                let counts = countByDifficulty(sampleA)
                Text("Contagem A — fácil: \(counts.easy), média: \(counts.medium), difícil: \(counts.hard) — esperado 3/4/3")
                    .font(.caption)
                    .foregroundStyle(counts == (3, 4, 3) ? .green : .red)
            }
        }
    }

    private func describe(_ sample: [PersistedQuizQuestion]) -> String {
        sample.map { "\($0.difficulty[$0.difficulty.startIndex]):\($0.question.prefix(20))" }.joined(separator: " | ")
    }

    private func countByDifficulty(_ sample: [PersistedQuizQuestion]) -> (easy: Int, medium: Int, hard: Int) {
        (
            sample.filter { $0.difficulty == Difficulty.easy.rawValue }.count,
            sample.filter { $0.difficulty == Difficulty.medium.rawValue }.count,
            sample.filter { $0.difficulty == Difficulty.hard.rawValue }.count
        )
    }

    // MARK: - Item 6: trocar DatasetVersion e confirmar regeneração

    private var datasetVersionSection: some View {
        Section("4) Invalidação por DatasetVersion (checklist item 6)") {
            Text("Versão atual: \(DatasetVersion.current)").font(.caption).monospaced()
            Button("Trocar DatasetVersion.current (simula dataset novo)") {
                DatasetVersion.current = "test-v-\(Int(Date().timeIntervalSince1970))"
                appendLog("DatasetVersion.current alterada para '\(DatasetVersion.current)'.")
            }
            Text("Depois de trocar, chame 'fetchOrCreate' de novo pro MESMO tópico acima (seção 1). Deve regenerar (duração alta, log '🟠 cache STALE'), não reaproveitar o pool antigo.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Item 7: reabrir 2x rápido não duplica geração

    private var raceConditionSection: some View {
        Section("5) Reabrir 2x rápido não deve duplicar geração (checklist item 7)") {
            TextField("Tópico NOVO (ainda não gerado)", text: $raceTestTopicName)
            Button {
                Task { await runRaceTest() }
            } label: {
                if raceTestRunning {
                    ProgressView()
                } else {
                    Text("Disparar fetchOrCreate 2x em paralelo")
                }
            }
            .disabled(raceTestRunning || repository == nil || raceTestTopicName.isEmpty)

            if let raceTestResult {
                Text(raceTestResult).font(.caption)
            }

            Text("Use um nome de tópico que você ainda não gerou. Testa a janela entre checar o cache e persistir — se aparecerem 2 StudyTopic com o mesmo nome, é uma condição de corrida real (reporte esse resultado).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func runRaceTest() async {
        guard let repository else { return }
        raceTestRunning = true
        defer { raceTestRunning = false }

        let name = raceTestTopicName
        appendLog("Disparando 2x fetchOrCreate('\(name)') em paralelo...")

        async let first = repository.fetchOrCreate(topic: name)
        async let second = repository.fetchOrCreate(topic: name)

        do {
            _ = try await (first, second)
        } catch {
            appendLog("❌ Erro na chamada em paralelo: \(error.localizedDescription)")
        }

        // Recontagem direta no ModelContext, fora da @Query (que pode
        // demorar um ciclo de UI pra atualizar).
        let descriptor = FetchDescriptor<StudyTopic>(predicate: #Predicate { $0.name == name })
        let matches = (try? modelContext.fetch(descriptor)) ?? []

        if matches.count > 1 {
            raceTestResult = "⚠️ \(matches.count) StudyTopic criados para '\(name)' — geração duplicada confirmada."
        } else {
            raceTestResult = "✅ Só 1 StudyTopic para '\(name)'."
        }
        appendLog(raceTestResult ?? "")
    }

    // MARK: - 6) PLAN_05 — Model Benchmark Suite (18 prompts + rubrica)

    private var benchmarkSection: some View {
        Section("6) Model Benchmark Suite (PLAN_05) — 18 prompts + rubrica") {
            Text("Modelo atual: \(MLXService.modelID)").font(.caption).monospaced()

            Button {
                Task { await runBenchmark() }
            } label: {
                if benchmarkSuite?.isRunning == true {
                    ProgressView("Rodando 18 prompts...")
                } else {
                    Text("Rodar suíte de benchmark")
                }
            }
            .disabled(benchmarkSuite == nil || benchmarkSuite?.isRunning == true)

            if let suite = benchmarkSuite, !suite.progressLog.isEmpty {
                DisclosureGroup("Log de execução (\(suite.progressLog.count) linhas)") {
                    ForEach(Array(suite.progressLog.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2).monospaced()
                    }
                }
            }

            if let report = benchmarkSuite?.lastReport {
                benchmarkReportSummary(report)
                ForEach(report.results) { result in
                    benchmarkResultRow(result)
                }

                Button("Exportar relatório JSON (Documents/)") {
                    benchmarkExportPath = benchmarkSuite?.exportReportToDocuments()?.path
                }
                .disabled(!report.isFullyScored)

                if !report.isFullyScored {
                    Text("Pontue todos os \(report.results.count) prompts (rubrica abaixo de cada um) antes de exportar — o score total só é definitivo depois da revisão humana de 'API real'/'grounding' (PLAN_05).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let benchmarkExportPath {
                    Text("Exportado em: \(benchmarkExportPath)").font(.caption2).foregroundStyle(.green)
                }
            }

            Text("Prompts e rubrica em Services/BenchmarkPrompts.swift e Services/ModelBenchmarkSuite.swift (SOLUTIONS_PLAN.md §9). Pontue cada resposta lendo o texto bruto gerado — 'API real' e 'grounding' exigem revisão humana, não são checáveis por regex confiável.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func runBenchmark() async {
        guard let benchmarkSuite else { return }
        rubricDrafts.removeAll()
        benchmarkExportPath = nil
        _ = await benchmarkSuite.run()
    }

    // MARK: - 7) PLAN_12 — GPU cacheLimit sweep

    /// Roda a suíte de 18 prompts 3x (default, ~2MB, ~64MB de cacheLimit) e
    /// compara tokensPerSecond médio + GPU.cacheMemory por variante. Não
    /// aplica nenhum cacheLimit em produção sozinho — só mede e recomenda
    /// (ver comentário de cabeçalho de GPUCacheLimitSweep.swift).
    private var cacheLimitSweepSection: some View {
        Section("7) GPU cacheLimit sweep (PLAN_12) — 3 variantes × 18 prompts") {
            Text("Testa: default (sem alterar), ~2MB, ~64MB. Roda a suíte inteira 3x — pode levar vários minutos.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button {
                Task { await runCacheLimitSweep() }
            } label: {
                if cacheLimitSweep?.isRunning == true {
                    ProgressView("Rodando sweep (3 variantes)...")
                } else {
                    Text("Rodar sweep de cacheLimit")
                }
            }
            .disabled(cacheLimitSweep == nil || cacheLimitSweep?.isRunning == true)

            if let sweep = cacheLimitSweep, !sweep.progressLog.isEmpty {
                DisclosureGroup("Log de execução (\(sweep.progressLog.count) linhas)") {
                    ForEach(Array(sweep.progressLog.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2).monospaced()
                    }
                }
            }

            if let report = cacheLimitSweep?.lastReport {
                Text(report.summaryLine)
                    .font(.caption)
                    .foregroundStyle(.primary)

                ForEach(report.variants) { variant in
                    cacheLimitVariantRow(variant)
                }

                Button("Exportar relatório JSON (Documents/)") {
                    cacheLimitSweepExportPath = cacheLimitSweep?.exportReportToDocuments()?.path
                }

                if let cacheLimitSweepExportPath {
                    Text("Exportado em: \(cacheLimitSweepExportPath)").font(.caption2).foregroundStyle(.green)
                }

                Text("Decisão final (PLAN_12 §11.3): menor cacheLimit testado que não regride tok/s em relação ao default. Se nenhuma variante ficar dentro da tolerância, manter o default é uma conclusão válida — não aplica nada automaticamente aqui, ver GPUCacheLimitSweep.swift.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func runCacheLimitSweep() async {
        guard let cacheLimitSweep else { return }
        cacheLimitSweepExportPath = nil
        _ = await cacheLimitSweep.run()
    }

    private func cacheLimitVariantRow(_ variant: CacheLimitVariantResult) -> some View {
        let mb = variant.appliedCacheLimitBytes.map { String(format: "%.1fMB aplicado", Double($0) / 1_048_576) } ?? "default do sistema"
        let tps = variant.avgTokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "sem tok/s"
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(variant.label) — \(mb)").font(.caption).bold()
            Text("\(variant.promptsExecuted) ok / \(variant.promptsFailed) falharam · \(tps) · cacheMemory=\(variant.cacheMemoryBytesAtEnd / 1_048_576)MB · peak=\(variant.peakMemoryBytes / 1_048_576)MB")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func benchmarkReportSummary(_ report: BenchmarkModelReport) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(report.promptsExecuted)/\(BenchmarkPrompts.all.count) prompts com sucesso · \(report.scoredPromptsCount)/\(report.results.count) pontuados")
                .font(.caption)
            Text("Score total (pontuados): \(report.totalScore)/\(report.maxPossibleScore) · potencial se todos pontuados: \(report.results.count * BenchmarkRubricScore.maxPossibleTotal)")
                .font(.caption)
            Text(report.hasHardVeto ? "🚫 VETO DURO ativo — hallucination detectada nos prompts 4-7 (§9.4)." : "✅ Sem veto duro — nenhuma hallucination marcada nos prompts 4-7.")
                .font(.caption)
                .foregroundStyle(report.hasHardVeto ? .red : .green)
        }
    }

    private func benchmarkResultRow(_ result: BenchmarkPromptResult) -> some View {
        DisclosureGroup("#\(result.promptID) [\(result.category)] \(result.summary)") {
            if let error = result.errorMessage {
                Text("❌ \(error)").font(.caption).foregroundStyle(.red)
            } else {
                if let metrics = result.metrics {
                    Text(describeMetrics(metrics)).font(.caption2).foregroundStyle(.secondary)
                }
                Text(result.rawOutput.isEmpty ? "(sem output)" : result.rawOutput)
                    .font(.caption2)
                    .monospaced()
                    .textSelection(.enabled)

                benchmarkRubricEditor(for: result)
            }
        }
    }

    /// Editor manual da rubrica (§9.3) — stepper por critério + toggle do
    /// veto duro (só relevante/exibido pra prompts 4-7, `isHardVetoPrompt`).
    private func benchmarkRubricEditor(for result: BenchmarkPromptResult) -> some View {
        let binding = Binding<BenchmarkRubricScore>(
            get: { rubricDrafts[result.promptID] ?? result.rubric ?? BenchmarkRubricScore() },
            set: { rubricDrafts[result.promptID] = $0 }
        )

        return VStack(alignment: .leading, spacing: 4) {
            Divider()
            Stepper("API real: \(binding.wrappedValue.apiReal)/30", value: Binding(get: { binding.wrappedValue.apiReal }, set: { binding.wrappedValue.apiReal = $0 }), in: 0...30)
            Stepper("Instruction following: \(binding.wrappedValue.instructionFollowing)/25", value: Binding(get: { binding.wrappedValue.instructionFollowing }, set: { binding.wrappedValue.instructionFollowing = $0 }), in: 0...25)
            Stepper("Grounding: \(binding.wrappedValue.grounding)/20", value: Binding(get: { binding.wrappedValue.grounding }, set: { binding.wrappedValue.grounding = $0 }), in: 0...20)
            Stepper("Correção Swift: \(binding.wrappedValue.swiftCorrectness)/15", value: Binding(get: { binding.wrappedValue.swiftCorrectness }, set: { binding.wrappedValue.swiftCorrectness = $0 }), in: 0...15)
            Stepper("Latência: \(binding.wrappedValue.latency)/7", value: Binding(get: { binding.wrappedValue.latency }, set: { binding.wrappedValue.latency = $0 }), in: 0...7)
            Stepper("Memória: \(binding.wrappedValue.memory)/3", value: Binding(get: { binding.wrappedValue.memory }, set: { binding.wrappedValue.memory = $0 }), in: 0...3)

            if result.isHardVetoPrompt {
                Toggle("⚠️ API inventada nesta resposta (alimenta o veto duro §9.4)", isOn: Binding(get: { binding.wrappedValue.hasInventedAPI }, set: { binding.wrappedValue.hasInventedAPI = $0 }))
                    .font(.caption)
            }

            Button("Salvar pontuação (\(binding.wrappedValue.weightedTotal)/100)") {
                benchmarkSuite?.setRubric(binding.wrappedValue, forPromptID: result.promptID)
            }
            .font(.caption)
        }
    }

    /// Monta a linha de métricas mecânicas (§9.2) exibida sob cada
    /// resultado — `GenerationMetrics` (PLAN_00) não tem um `summary()`
    /// próprio (só `GenerateCompletionInfo.summary()`, interno ao
    /// `MLXService`), então formata aqui os campos já capturados.
    private func describeMetrics(_ metrics: GenerationMetrics) -> String {
        let ttft = metrics.timeToFirstTokenMs.map { String(format: "%.0fms TTFT", $0) } ?? "TTFT: ?"
        let toksec = metrics.tokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "tok/s: ?"
        let inTok = metrics.inputTokenCount.map(String.init) ?? "?"
        let outTok = metrics.outputTokenCount.map(String.init) ?? "?"
        return "\(String(format: "%.0fms total", metrics.totalTimeMs)) · \(ttft) · \(toksec) · in=\(inTok) out=\(outTok) tokens · lote=\(metrics.batchSize)"
    }

    // MARK: - 8) PLAN_13 Parte 1 — concorrência FM (§15.4)

    /// Dispara N LanguageModelSession.respond simultâneas (N=2,3,4), 10
    /// rodadas por N, comparando com o mesmo N em série. NÃO passa pelo
    /// GenerationOrchestrator (o objetivo é provocar a concorrência que a
    /// fila previne). Só mede — a decisão vai pra plans/PLAN_13_DECISION.md.
    private var fmConcurrencySection: some View {
        Section("8) Concorrência FM (PLAN_13 Parte 1) — N=2,3,4 × 10 rodadas") {
            Text("≈180 chamadas FM no total (serial + concorrente) — deixe o device na tomada e conte com vários minutos. Rode SEM geração de pool em andamento (a fila de produção competiria pelo FM e contaminaria o baseline serial).")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button {
                Task { await runFMConcurrency() }
            } label: {
                if fmConcurrency.isRunning {
                    ProgressView("Rodando experimento...")
                } else {
                    Text("Rodar experimento de concorrência FM")
                }
            }
            .disabled(fmConcurrency.isRunning)

            if !fmConcurrency.progressLog.isEmpty {
                DisclosureGroup("Log de execução (\(fmConcurrency.progressLog.count) linhas)") {
                    ForEach(Array(fmConcurrency.progressLog.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2).monospaced()
                    }
                }
            }

            if let report = fmConcurrency.lastReport {
                ForEach(report.variants) { variant in
                    Text(variant.summaryLine).font(.caption2).monospaced()
                }
                Text(report.recommendation)
                    .font(.caption)

                Button("Exportar relatório JSON (Documents/)") {
                    fmConcurrencyExportPath = fmConcurrency.exportReportToDocuments()?.path
                }
                if let fmConcurrencyExportPath {
                    Text("Exportado em: \(fmConcurrencyExportPath)").font(.caption2).foregroundStyle(.green)
                }

                Text("Registre a decisão em plans/PLAN_13_DECISION.md. Mesmo com resultado favorável, elevar .poolFill pra profundidade 2 é um PLANO FUTURO separado — nada de produção muda neste plano.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func runFMConcurrency() async {
        fmConcurrencyExportPath = nil
        _ = await fmConcurrency.run()
    }

    // MARK: - 9) PLAN_13 Parte 2 — warm-up MLX (medição 1ª vs 2ª/3ª chamada)

    /// Lê a GenerationMetricsStore (PLAN_00) e registra a comparação
    /// fria-vs-quente da sessão ATUAL num arquivo acumulado entre sessões.
    /// Protocolo: reiniciar o app, gerar um tópico (deixar quiz difícil +
    /// análise rodarem em background = ≥3 chamadas MLX), apertar o botão,
    /// repetir ≥5 sessões.
    private var mlxWarmupSection: some View {
        Section("9) Warm-up MLX (PLAN_13 Parte 2) — 1ª vs 2ª/3ª chamada") {
            Text("Protocolo: reinicie o app → gere 1 tópico e espere o background (≥2 chamadas MLX depois da 1ª) → toque abaixo → repita em ≥\(MLXWarmupAnalyzer.minSessions) sessões. Compara THROUGHPUT (prefill tok/s e decode tok/s), não TTFT bruto — ver cabeçalho de MLXWarmupAnalyzer.swift (PLAN_11 confunde TTFT).")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button("Registrar sessão atual (fria vs quentes)") {
                Task { await warmupAnalyzer.recordCurrentSession() }
            }

            if let status = warmupAnalyzer.statusMessage {
                Text(status).font(.caption2)
            }

            Text(warmupAnalyzer.aggregateSummary)
                .font(.caption)

            if !warmupAnalyzer.sessions.isEmpty {
                DisclosureGroup("Sessões acumuladas (\(warmupAnalyzer.sessions.count))") {
                    ForEach(warmupAnalyzer.sessions) { session in
                        Text("\(session.recordedAt.formatted(date: .abbreviated, time: .shortened)) — \(session.summaryLine)")
                            .font(.caption2)
                            .monospaced()
                    }
                    Button("Apagar amostras acumuladas", role: .destructive) {
                        warmupAnalyzer.clearAllSessions()
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: - Log e lista de tópicos persistidos

    private func appendLog(_ line: String) {
        log.append(line)
        print("📋 [TesteRepo] \(line)")
    }

    private var logSection: some View {
        Section("Log da sessão") {
            if log.isEmpty {
                Text("Nada ainda.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(log.enumerated().reversed()), id: \.offset) { _, line in
                    Text(line).font(.caption2)
                }
            }
        }
    }

    private var allTopicsSection: some View {
        Section("Tópicos persistidos (pra testar 'fechar e reabrir o app')") {
            if allTopics.isEmpty {
                Text("Nenhum ainda.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(allTopics) { topic in
                    VStack(alignment: .leading) {
                        Text(topic.name).bold()
                        Text("versão: \(topic.sourceDatasetVersion) · quiz: \(topic.quizPool.count) · gerando: \(topic.isGeneratingPool ? "sim" : "não")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete(perform: deleteTopics)
            }
            Text("Feche o app de verdade (não só a tela) e reabra pra validar o item 5 do checklist — o mesmo tópico deve carregar instantâneo e sem novo '🔵 generateAndPersistPhase1 CHAMADO' no console.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func deleteTopics(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(allTopics[index])
        }
        try? modelContext.save()
    }
}

#Preview {
    TopicRepositoryTestView()
        .modelContainer(for: [
            StudyTopic.self,
            PersistedQuizQuestion.self,
            PersistedCodeAnalysisQuestion.self
        ])
}
#endif // DEBUG
