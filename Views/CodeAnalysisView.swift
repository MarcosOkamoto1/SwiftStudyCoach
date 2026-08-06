//
//  CodeAnalysisView.swift
//  SwiftStudyCoach
//
//  Parte 7 — snippet com destaque de sintaxe (CodeBlockView, reaproveitando
//  o estilo do protótipo HTML) + 5 alternativas, feedback imediato.
//

import SwiftUI

struct CodeAnalysisView: View {
    let topicName: String
    let questions: [PersistedCodeAnalysisQuestion]
    var onFinish: ([AnsweredQuestion]) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var selectedOption: Int?
    @State private var answers: [AnsweredQuestion] = []

    var body: some View {
        DSScreen {
            VStack(spacing: 0) {
                header

                if questions.isEmpty {
                    Spacer()
                    Text("Nenhuma pergunta de análise de código disponível.")
                        .font(DS.Fonts.body(15))
                        .foregroundStyle(DS.Colors.mist)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            if let question = currentQuestion {
                                CodeBlockView(
                                    label: "trecho pra analisar",
                                    code: question.codeSnippet,
                                    dotColor: DS.Colors.cyan
                                )
                                Text(question.question)
                                    .font(DS.Fonts.display(19))
                                    .foregroundStyle(DS.Colors.foam)

                                optionsList(question)

                                if let selectedOption {
                                    feedbackCard(question: question, selected: selectedOption)
                                }
                            }
                        }
                        .padding(24)
                    }

                    footer
                }
            }
        }
    }

    private var currentQuestion: PersistedCodeAnalysisQuestion? {
        questions.indices.contains(index) ? questions[index] : nil
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack {
                Button {
                    onFinish(answers)
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(DS.Colors.mist)
                }
                Spacer()
                Text(topicName.uppercased())
                    .font(DS.Fonts.mono(11))
                    .tracking(1.2)
                    .foregroundStyle(DS.Colors.mistDim)
                Spacer()
                Text(questions.isEmpty ? "" : "\(index + 1) de \(questions.count)")
                    .font(DS.Fonts.mono(11))
                    .foregroundStyle(DS.Colors.mist)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)

            ProgressBar(progress: questions.isEmpty ? 0 : Double(index + 1) / Double(questions.count))
        }
    }

    private func optionsList(_ question: PersistedCodeAnalysisQuestion) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
                OptionRow(
                    text: option,
                    state: state(for: optionIndex, correctIndex: question.correctOptionIndex)
                )
                .onTapGesture {
                    guard selectedOption == nil else { return }
                    select(optionIndex, question: question)
                }
            }
        }
    }

    private func state(for optionIndex: Int, correctIndex: Int) -> OptionRow.State {
        guard let selectedOption else { return .idle }
        if optionIndex == correctIndex { return .correct }
        if optionIndex == selectedOption { return .incorrect }
        return .disabled
    }

    private func feedbackCard(question: PersistedCodeAnalysisQuestion, selected: Int) -> some View {
        let correct = selected == question.correctOptionIndex

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(correct ? DS.Colors.sage : DS.Colors.orchid)
                Text(correct ? "Correto" : "Incorreto")
                    .font(DS.Fonts.mono(12))
                    .foregroundStyle(correct ? DS.Colors.sage : DS.Colors.orchid)
            }
            Text(question.explanation)
                .font(DS.Fonts.body(15))
                .foregroundStyle(DS.Colors.mist)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.slate)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke((correct ? DS.Colors.sage : DS.Colors.orchid).opacity(0.4), lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack {
            Text(answers.isEmpty ? "" : "acertos: \(answers.filter(\.isCorrect).count) / \(answers.count)")
                .font(DS.Fonts.mono(11))
                .foregroundStyle(DS.Colors.mistDim)

            Spacer()

            Button {
                advance()
            } label: {
                Text(index == questions.count - 1 ? "Finalizar" : "Próxima")
            }
            .buttonStyle(DSButtonStyle(accent: DS.Colors.violet, filled: true))
            .frame(maxWidth: 220)
            .disabled(selectedOption == nil)
            .opacity(selectedOption == nil ? 0.4 : 1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(DS.Colors.ink)
        .overlay(Rectangle().fill(DS.Colors.hairlineSoft).frame(height: 1), alignment: .top)
    }

    private func select(_ optionIndex: Int, question: PersistedCodeAnalysisQuestion) {
        withAnimation(.easeOut(duration: 0.2)) {
            selectedOption = optionIndex
        }
        answers.append(
            AnsweredQuestion(
                questionText: question.question,
                selectedOptionIndex: optionIndex,
                correctOptionIndex: question.correctOptionIndex,
                explanation: question.explanation,
                difficulty: nil
            )
        )
    }

    private func advance() {
        if index == questions.count - 1 {
            onFinish(answers)
            dismiss()
            return
        }
        selectedOption = nil
        index += 1
    }
}

#Preview {
    CodeAnalysisView(
        topicName: "Actors",
        questions: [
            PersistedCodeAnalysisQuestion(
                codeSnippet: "actor Contador {\n    var valor = 0\n    func incrementar() { valor += 1 }\n}",
                question: "O que acontece se duas tasks chamarem incrementar() ao mesmo tempo?",
                options: ["Executam em fila, uma por vez", "Corrida de dados", "Erro de compilação", "Deadlock", "Nada, o valor final é indefinido"],
                correctOptionIndex: 0,
                explanation: "O actor serializa o acesso — cada chamada espera a anterior terminar."
            )
        ]
    )
}
