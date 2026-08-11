//
//  TopicStudyView.swift
//  SwiftStudyCoach
//
//  Parte 7 — tela "artigo" de leitura do tópico (inspirada no protótipo
//  reading-interface.html) que orquestra as telas de estudo (Quiz, Análise
//  de Código) + resultado final, usando o TopicRepository (Parte 4/5) pra
//  cache/persistência e o StudyGenerator (Parte 6) pro feedback final.
//  Plano V3 1.3: flashcards saíram — redundantes com o quiz.
//

import SwiftUI
import SwiftData

private enum ActiveSheet: Identifiable {
    case quiz, codeAnalysis, result
    var id: Int {
        switch self {
        case .quiz: return 1
        case .codeAnalysis: return 2
        case .result: return 3
        }
    }
}

struct TopicStudyView: View {
    let topicName: String

    @Environment(\.modelContext) private var modelContext
    // Índice RAG único do app (embeddings cacheados em disco) — antes cada
    // visita a esta tela criava um índice novo e re-embedava tudo.
    private let documentIndex = DocumentIndex.shared
    @State private var generator: StudyGenerator?
    @State private var repository: TopicRepository?

    @State private var topic: StudyTopic?
    @State private var isLoading = false
    @State private var errorMessage: String?

    @State private var quizBatch: [PersistedQuizQuestion] = []
    @State private var quizAnswers: [AnsweredQuestion] = []
    @State private var codeAnswers: [AnsweredQuestion] = []
    @State private var activeSheet: ActiveSheet?
    // Plano V3 2.5: destino de navegação quando o usuário toca no tópico
    // recomendado na tela de resultado — empilha um novo TopicStudyView na
    // MESMA NavigationStack (a que já existe lá na StudyHomeView).
    @State private var recommendedTopicToOpen: String?

    var body: some View {
        DSScreen {
            Group {
                if isLoading {
                    loadingState
                } else if let errorMessage {
                    errorState(errorMessage)
                } else if let topic {
                    articleContent(topic)
                } else {
                    Color.clear
                }
            }
        }
        .task { await load() }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
                #if os(macOS)
                .frame(minWidth: 560, minHeight: 640)
                #endif
        }
        .navigationDestination(item: $recommendedTopicToOpen) { name in
            TopicStudyView(topicName: name)
        }
    }

    // MARK: - Carregamento

    private var loadingState: some View {
        Group {
            // MLXService é @Observable — só referenciar `loadState` aqui já
            // faz essa View reagir automaticamente às mudanças. Na primeira
            // execução (download de ~1,7 GB), a ModelDownloadView mostra
            // progresso real, velocidade e tempo restante estimado.
            switch MLXService.shared.loadState {
            case .downloading, .loadingIntoMemory, .failed:
                ModelDownloadView {
                    Task { await load() }
                }
            case .idle, .ready:
                VStack(spacing: 14) {
                    ProgressView().tint(DS.Colors.violet)
                    Text("Gerando conteúdo de \"\(topicName)\"...")
                        .font(DS.Fonts.body(14))
                        .foregroundStyle(DS.Colors.mist)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(DS.Colors.orchid)
            Text(message)
                .font(DS.Fonts.body(14))
                .foregroundStyle(DS.Colors.mist)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Tentar de novo") { Task { await load() } }
                .buttonStyle(DSButtonStyle())
                .frame(maxWidth: 200)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            if repository == nil {
                try await documentIndex.ensureReady()
                let gen = StudyGenerator(documentIndex: documentIndex)
                generator = gen
                repository = TopicRepository(modelContext: modelContext, generator: gen)
            }
            guard let repository else { return }
            topic = try await repository.fetchOrCreate(topic: topicName)
        } catch {
            errorMessage = "Erro ao carregar \"\(topicName)\": \(error.localizedDescription)"
        }
    }

    // MARK: - Conteúdo estilo "artigo" (reaproveita reading-interface.html)

    private func articleContent(_ topic: StudyTopic) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(DS.Colors.cyan).frame(width: 5, height: 5)
                    Text("TÓPICO DE ESTUDO")
                        .font(DS.Fonts.mono(11.5))
                        .tracking(1.2)
                        .foregroundStyle(DS.Colors.cyan)
                }
                .padding(.bottom, 18)

                Text(topic.name)
                    .font(DS.Fonts.display(34))
                    .foregroundStyle(DS.Colors.foam)
                    .padding(.bottom, 20)

                HStack(spacing: 12) {
                    PillView(text: "\(topic.quizPool.count) no pool de quiz", borderColor: DS.Colors.hairline)
                    PillView(text: "\(topic.codeAnalysisPool.count) análise de código", borderColor: DS.Colors.hairline)
                    if topic.isGeneratingPool {
                        HStack(spacing: 5) {
                            ProgressView().scaleEffect(0.6).tint(DS.Colors.violet)
                            Text("crescendo em background")
                                .font(DS.Fonts.mono(10.5))
                                .foregroundStyle(DS.Colors.mistDim)
                        }
                    }
                }
                .padding(.bottom, 32)

                Rectangle()
                    .fill(
                        LinearGradient(colors: [DS.Colors.hairline, .clear], startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(height: 1)
                    .padding(.bottom, 32)

                // Plano V4 Fase 1: na criação inicial o download do MLX
                // acontece DURANTE a tela de loading (fluxo síncrono) — este
                // banner compacto fica só como defesa pra casos raros de
                // download disparado com o artigo visível (retomada de pool
                // incompleto). Some sozinho quando o estado vira .ready.
                ModelDownloadView(compact: true) {
                    Task { await load() }
                }
                .padding(.bottom, 24)

                Text(topic.summary)
                    .font(DS.Fonts.body(18))
                    .foregroundStyle(DS.Colors.foam)
                    .lineSpacing(8)
                    .padding(.bottom, 28)

                if !topic.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(topic.keyPoints, id: \.self) { point in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(DS.Colors.violet)
                                    .padding(.top, 2)
                                Text(point)
                                    .font(DS.Fonts.body(15.5))
                                    .foregroundStyle(DS.Colors.mist)
                            }
                        }
                    }
                    .padding(.bottom, 32)
                }

                if !topic.codeExample.isEmpty {
                    CodeBlockView(label: "exemplo", code: topic.codeExample)
                        .padding(.bottom, topic.walkthroughSnippets.isEmpty ? 32 : 18)
                }

                if !topic.walkthroughSnippets.isEmpty {
                    walkthroughSection(topic)
                        .padding(.bottom, 32)
                }

                actionGrid(topic)
            }
            .padding(28)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
    }

    /// "Code walkthrough": explicação passo a passo do exemplo, gerada de
    /// forma estruturada pelo Foundation Models (snippet[i] ↔ explicação[i]).
    private func walkthroughSection(_ topic: StudyTopic) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(DS.Colors.sage).frame(width: 5, height: 5)
                Text("PASSO A PASSO")
                    .font(DS.Fonts.mono(10.5))
                    .tracking(1.2)
                    .foregroundStyle(DS.Colors.sage)
            }

            ForEach(Array(zip(topic.walkthroughSnippets, topic.walkthroughExplanations).enumerated()), id: \.offset) { index, step in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(DS.Fonts.mono(11))
                            .foregroundStyle(DS.Colors.sage)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(DS.Colors.sage.opacity(0.14)))

                        VStack(alignment: .leading, spacing: 8) {
                            Text(SyntaxHighlighter.highlight(step.0))
                                .font(DS.Fonts.mono(12.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(DS.Colors.panel)
                                )

                            Text(step.1)
                                .font(DS.Fonts.body(14))
                                .foregroundStyle(DS.Colors.mist)
                                .lineSpacing(5)
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DS.Colors.slate)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DS.Colors.hairline, lineWidth: 1)
        )
    }

    private func actionGrid(_ topic: StudyTopic) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PRATICAR")
                .font(DS.Fonts.mono(10.5))
                .tracking(1.2)
                .foregroundStyle(DS.Colors.mistDim)

            VStack(spacing: 10) {
                actionRow(
                    title: "Quiz",
                    subtitle: "3 fácil + 4 média + 3 difícil, sorteadas do pool",
                    icon: "checklist",
                    color: DS.Colors.cyan
                ) {
                    guard let repository else { return }
                    quizBatch = repository.sampleQuiz(from: topic)
                    activeSheet = .quiz
                }
                .disabled(topic.quizPool.isEmpty)
                .opacity(topic.quizPool.isEmpty ? 0.4 : 1)

                actionRow(
                    title: "Análise de código",
                    subtitle: "\(topic.codeAnalysisPool.count) perguntas",
                    icon: "curlybraces",
                    color: DS.Colors.orchid
                ) { activeSheet = .codeAnalysis }
                .disabled(topic.codeAnalysisPool.isEmpty)
                .opacity(topic.codeAnalysisPool.isEmpty ? 0.4 : 1)

                if !quizAnswers.isEmpty || !codeAnswers.isEmpty {
                    actionRow(
                        title: "Ver resultado da sessão",
                        subtitle: "\((quizAnswers + codeAnswers).filter(\.isCorrect).count) / \(quizAnswers.count + codeAnswers.count) corretas até agora",
                        icon: "chart.bar.fill",
                        color: DS.Colors.sage
                    ) { activeSheet = .result }
                }
            }
        }
        .padding(.bottom, 40)
    }

    private func actionRow(title: String, subtitle: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(color.opacity(0.14)).frame(width: 36, height: 36)
                    Image(systemName: icon).foregroundStyle(color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DS.Fonts.body(16, weight: .medium))
                        .foregroundStyle(DS.Colors.foam)
                    Text(subtitle)
                        .font(DS.Fonts.mono(11))
                        .foregroundStyle(DS.Colors.mistDim)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.mistDim)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.slate))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DS.Colors.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .quiz:
            QuizView(topicName: topicName, questions: quizBatch) { answers in
                quizAnswers = answers
                replenishAfterSession()
            }
        case .codeAnalysis:
            if let topic {
                CodeAnalysisView(topicName: topicName, questions: topic.codeAnalysisPool) { answers in
                    codeAnswers = answers
                    replenishAfterSession()
                }
            }
        case .result:
            if let generator {
                StudyResultView(
                    topicName: topicName,
                    quizAnswers: quizAnswers,
                    codeAnswers: codeAnswers,
                    generator: generator,
                    onSelectTopic: { name in recommendedTopicToOpen = name }
                )
            }
        }
    }

    /// Plano V3 4.1 — dispara o top-up do pool quando uma sessão de quiz ou
    /// de análise de código termina (o sheet fecha com respostas). Roda em
    /// background (Task solta, sem bloquear a UI); o TopicRepository já se
    /// protege contra disparo duplicado via `isGeneratingPool`.
    private func replenishAfterSession() {
        guard let repository else { return }
        Task { await repository.replenishAfterSession(topicName: topicName) }
    }
}

#Preview {
    TopicStudyView(topicName: "Actors")
        .modelContainer(for: [
            StudyTopic.self,
            PersistedQuizQuestion.self,
            PersistedCodeAnalysisQuestion.self
        ])
}
