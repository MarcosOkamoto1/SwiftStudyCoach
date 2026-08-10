//
//  TopicStudyView.swift
//  SwiftStudyCoach
//
//  Parte 7 — tela "artigo" de leitura do tópico (inspirada no protótipo
//  reading-interface.html) que orquestra as 3 telas de estudo (Flashcards,
//  Quiz, Análise de Código) + resultado final, usando o TopicRepository
//  (Parte 4/5) pra cache/persistência e o StudyGenerator (Parte 6) pro
//  feedback final.
//

import SwiftUI
import SwiftData

private enum ActiveSheet: Identifiable {
    case flashcards, quiz, codeAnalysis, result
    var id: Int {
        switch self {
        case .flashcards: return 0
        case .quiz: return 1
        case .codeAnalysis: return 2
        case .result: return 3
        }
    }
}

struct TopicStudyView: View {
    let topicName: String

    @Environment(\.modelContext) private var modelContext
    @State private var documentIndex = DocumentIndex()
    @State private var generator: StudyGenerator?
    @State private var repository: TopicRepository?

    @State private var topic: StudyTopic?
    @State private var isLoading = false
    @State private var errorMessage: String?

    @State private var quizBatch: [PersistedQuizQuestion] = []
    @State private var quizAnswers: [AnsweredQuestion] = []
    @State private var codeAnswers: [AnsweredQuestion] = []
    @State private var activeSheet: ActiveSheet?

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
    }

    // MARK: - Carregamento

    private var loadingState: some View {
        Group {
            // MLXService é @Observable — só referenciar `loadState` aqui já
            // faz essa View reagir automaticamente às mudanças, sem @State
            // extra. Isso cobre o caso de primeira execução, quando o
            // download do modelo (alguns GB) pode levar bastante tempo e,
            // sem esse indicador específico, a tela pareceria travada.
            if MLXService.shared.loadState == .downloading {
                VStack(spacing: 12) {
                    ProgressView().tint(DS.Colors.violet)
                    Text("Baixando modelo MLX (só na primeira vez — alguns minutos)")
                        .font(DS.Fonts.body(13))
                        .foregroundStyle(DS.Colors.mistDim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            } else if case .failed(let reason) = MLXService.shared.loadState {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(DS.Colors.orchid)
                    Text("Falha ao baixar o modelo MLX: \(reason)")
                        .font(DS.Fonts.body(13))
                        .foregroundStyle(DS.Colors.mistDim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            } else {
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
                try await documentIndex.buildIndex()
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
                    PillView(text: "\(topic.flashcards.count) flashcards", borderColor: DS.Colors.hairline)
                    PillView(text: "\(topic.quizPool.count) no pool de quiz", borderColor: DS.Colors.hairline)
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
                        .padding(.bottom, 32)
                }

                actionGrid(topic)
            }
            .padding(28)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
    }

    private func actionGrid(_ topic: StudyTopic) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PRATICAR")
                .font(DS.Fonts.mono(10.5))
                .tracking(1.2)
                .foregroundStyle(DS.Colors.mistDim)

            VStack(spacing: 10) {
                actionRow(
                    title: "Flashcards",
                    subtitle: "\(topic.flashcards.count) cards",
                    icon: "rectangle.on.rectangle",
                    color: DS.Colors.violet
                ) { activeSheet = .flashcards }

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
        case .flashcards:
            if let topic {
                FlashcardsView(topicName: topic.name, flashcards: topic.flashcards)
            }
        case .quiz:
            QuizView(topicName: topicName, questions: quizBatch) { answers in
                quizAnswers = answers
            }
        case .codeAnalysis:
            if let topic {
                CodeAnalysisView(topicName: topicName, questions: topic.codeAnalysisPool) { answers in
                    codeAnswers = answers
                }
            }
        case .result:
            if let generator {
                StudyResultView(
                    topicName: topicName,
                    quizAnswers: quizAnswers,
                    codeAnswers: codeAnswers,
                    generator: generator
                )
            }
        }
    }
}

#Preview {
    TopicStudyView(topicName: "Actors")
        .modelContainer(for: [
            StudyTopic.self,
            PersistedFlashcard.self,
            PersistedQuizQuestion.self,
            PersistedCodeAnalysisQuestion.self
        ])
}
