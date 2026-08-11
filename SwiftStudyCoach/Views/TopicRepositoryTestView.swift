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

    @State private var topicName: String = "Guard"
    @State private var isLoading = false
    @State private var loadErrorMessage: String?
    @State private var loadedTopicID: PersistentIdentifier?
    @State private var lastLoadDuration: TimeInterval?

    @State private var sampleA: [PersistedQuizQuestion] = []
    @State private var sampleB: [PersistedQuizQuestion] = []
    @State private var log: [String] = []

    @State private var raceTestTopicName: String = "Protocolos"
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
        } catch {
            setupError = "Erro no setup: \(error.localizedDescription)"
        }
    }

    // MARK: - Item 1, 5, 6: gerar/carregar tópico (cache hit vs miss)

    private var loadTopicSection: some View {
        Section("1) Gerar / carregar tópico (checklist itens 1, 5, 6)") {
            TextField("Tópico (ex: Guard, Optionals, async/await)", text: $topicName)

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

            Text("Dica: aperte 2x seguidas pro MESMO tópico. A 2ª deve ser quase instantânea e o console NÃO deve mostrar '🔵 generateAndPersist CHAMADO' de novo — só '🟢 cache HIT'.")
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
            Text("Feche o app de verdade (não só a tela) e reabra pra validar o item 5 do checklist — o mesmo tópico deve carregar instantâneo e sem novo '🔵 generateAndPersist CHAMADO' no console.")
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
