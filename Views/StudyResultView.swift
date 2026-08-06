//
//  StudyResultView.swift
//  SwiftStudyCoach
//
//  Parte 7 — tela de resultado final: mostra o placar da sessão (quiz +
//  análise de código) e o StudyFeedback (Parte 6, implementação mínima)
//  gerado sob demanda pelo Foundation Models.
//

import SwiftUI

struct StudyResultView: View {
    let topicName: String
    let quizAnswers: [AnsweredQuestion]
    let codeAnswers: [AnsweredQuestion]
    let generator: StudyGenerator

    @Environment(\.dismiss) private var dismiss
    @State private var feedback: StudyFeedback?
    @State private var isGeneratingFeedback = false
    @State private var feedbackError: String?

    private var allAnswers: [AnsweredQuestion] { quizAnswers + codeAnswers }
    private var totalCorrect: Int { allAnswers.filter(\.isCorrect).count }
    private var totalCount: Int { allAnswers.count }
    private var scorePercent: Double {
        totalCount == 0 ? 0 : Double(totalCorrect) / Double(totalCount)
    }

    var body: some View {
        DSScreen {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header
                    scoreCard
                    breakdown
                    feedbackSection
                    closeButton
                }
                .padding(24)
            }
        }
        .task { await generateFeedbackIfNeeded() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SESSÃO CONCLUÍDA")
                .font(DS.Fonts.mono(11))
                .tracking(1.4)
                .foregroundStyle(DS.Colors.cyan)
            Text(topicName)
                .font(DS.Fonts.display(30))
                .foregroundStyle(DS.Colors.foam)
        }
        .padding(.top, 12)
    }

    private var scoreCard: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(totalCorrect) / \(totalCount)")
                    .font(DS.Fonts.display(38))
                    .foregroundStyle(scoreColor)
                Text("respostas corretas")
                    .font(DS.Fonts.mono(11))
                    .foregroundStyle(DS.Colors.mistDim)
            }
            Spacer()
            ZStack {
                Circle()
                    .stroke(DS.Colors.hairline, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: scorePercent)
                    .stroke(scoreColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(scorePercent * 100))%")
                    .font(DS.Fonts.mono(13))
                    .foregroundStyle(DS.Colors.foam)
            }
            .frame(width: 64, height: 64)
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.Colors.slate))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DS.Colors.hairline, lineWidth: 1))
    }

    private var scoreColor: Color {
        if scorePercent >= 0.8 { return DS.Colors.sage }
        if scorePercent >= 0.5 { return DS.Colors.cyan }
        return DS.Colors.orchid
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DETALHAMENTO")
                .font(DS.Fonts.mono(10.5))
                .tracking(1.2)
                .foregroundStyle(DS.Colors.mistDim)

            if !quizAnswers.isEmpty {
                breakdownRow(label: "Quiz", answers: quizAnswers)
            }
            if !codeAnswers.isEmpty {
                breakdownRow(label: "Análise de código", answers: codeAnswers)
            }
        }
    }

    private func breakdownRow(label: String, answers: [AnsweredQuestion]) -> some View {
        HStack {
            Text(label)
                .font(DS.Fonts.body(15))
                .foregroundStyle(DS.Colors.foam)
            Spacer()
            Text("\(answers.filter(\.isCorrect).count) / \(answers.count)")
                .font(DS.Fonts.mono(13))
                .foregroundStyle(DS.Colors.mist)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Colors.slate))
    }

    @ViewBuilder
    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("FEEDBACK")
                .font(DS.Fonts.mono(10.5))
                .tracking(1.2)
                .foregroundStyle(DS.Colors.mistDim)

            if isGeneratingFeedback {
                HStack(spacing: 10) {
                    ProgressView().tint(DS.Colors.violet)
                    Text("Gerando feedback personalizado...")
                        .font(DS.Fonts.body(14))
                        .foregroundStyle(DS.Colors.mist)
                }
            } else if let feedbackError {
                VStack(alignment: .leading, spacing: 10) {
                    Text(feedbackError)
                        .font(DS.Fonts.body(14))
                        .foregroundStyle(DS.Colors.orchid)
                    Button("Tentar de novo") {
                        Task { await generateFeedbackIfNeeded(force: true) }
                    }
                    .buttonStyle(DSButtonStyle())
                }
            } else if let feedback {
                feedbackCard(feedback)
            } else if totalCount == 0 {
                Text("Sem perguntas respondidas nesta sessão — sem feedback pra gerar.")
                    .font(DS.Fonts.body(14))
                    .foregroundStyle(DS.Colors.mistDim)
            }
        }
    }

    private func feedbackCard(_ feedback: StudyFeedback) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(feedback.overallMessage)
                .font(DS.Fonts.display(18))
                .foregroundStyle(DS.Colors.foam)

            if !feedback.strengths.isEmpty {
                feedbackList(title: "PONTOS FORTES", items: feedback.strengths, color: DS.Colors.sage)
            }
            if !feedback.weaknesses.isEmpty {
                feedbackList(title: "PRA REVISAR", items: feedback.weaknesses, color: DS.Colors.orchid)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("PRÓXIMO TÓPICO SUGERIDO")
                    .font(DS.Fonts.mono(10))
                    .tracking(1.1)
                    .foregroundStyle(DS.Colors.mistDim)
                Text(feedback.recommendedNextTopic)
                    .font(DS.Fonts.body(15.5))
                    .foregroundStyle(DS.Colors.violet)
            }
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.Colors.slate))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DS.Colors.hairline, lineWidth: 1))
    }

    private func feedbackList(title: String, items: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(DS.Fonts.mono(10))
                .tracking(1.1)
                .foregroundStyle(color)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(color).frame(width: 5, height: 5).padding(.top, 6)
                    Text(item)
                        .font(DS.Fonts.body(14.5))
                        .foregroundStyle(DS.Colors.mist)
                }
            }
        }
    }

    private var closeButton: some View {
        Button("Concluir") { dismiss() }
            .buttonStyle(DSButtonStyle(accent: DS.Colors.violet, filled: true))
            .padding(.top, 8)
            .padding(.bottom, 24)
    }

    private func generateFeedbackIfNeeded(force: Bool = false) async {
        guard force || (feedback == nil && !isGeneratingFeedback) else { return }
        guard totalCount > 0 else { return }

        isGeneratingFeedback = true
        feedbackError = nil
        defer { isGeneratingFeedback = false }

        var summary = ""
        if !quizAnswers.isEmpty { summary += quizAnswers.performanceSummary(sectionLabel: "Quiz") + "\n\n" }
        if !codeAnswers.isEmpty { summary += codeAnswers.performanceSummary(sectionLabel: "Análise de código") }

        do {
            feedback = try await generator.generateFeedback(topic: topicName, performanceSummary: summary)
        } catch {
            feedbackError = "Não foi possível gerar o feedback: \(error.localizedDescription)"
        }
    }
}

#Preview {
    StudyResultView(
        topicName: "Actors",
        quizAnswers: [],
        codeAnswers: [],
        generator: StudyGenerator(documentIndex: DocumentIndex())
    )
}
