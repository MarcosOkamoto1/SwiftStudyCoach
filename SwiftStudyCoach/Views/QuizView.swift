//
//  QuizView.swift
//  SwiftStudyCoach
//
//  Parte 7 — uma pergunta por vez, seleção de alternativa, feedback
//  imediato certo/errado, progresso ("pergunta X de Y").
//
import SwiftUI

struct QuizView: View {
    let topicName: String
    @State var questions: [PersistedQuizQuestion]
    var onFinish: ([AnsweredQuestion]) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var selectedOption: Int?
    @State private var answers: [AnsweredQuestion] = []
    
    // 🤖 Controle de geração do MLX para a pergunta Difícil
    @State private var isLoadingHardQuestion = false

    var body: some View {
        DSScreen {
            VStack(spacing: 0) {
                header

                if questions.isEmpty {
                    Spacer()
                    Text("Nenhuma pergunta de quiz disponível.")
                        .font(DS.Fonts.body(15))
                        .foregroundStyle(DS.Colors.mist)
                    Spacer()
                } else if isLoadingHardQuestion {
                    // 🔄 Tela de carregamento enquanto o MLX pensa
                    Spacer()
                    VStack(spacing: 16) {
                        ProgressView()
                            .tint(DS.Colors.violet)
                        Text("Gerando desafio Nível DIFÍCIL com MLX local...")
                            .font(DS.Fonts.mono(12))
                            .foregroundStyle(DS.Colors.violet)
                        Text("Buscando contexto na documentação Swift...")
                            .font(DS.Fonts.body(13))
                            .foregroundStyle(DS.Colors.mistDim)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            questionCard
                            optionsList
                            if let selectedOption {
                                feedbackCard(selected: selectedOption)
                            }
                        }
                        .padding(24)
                    }

                    footer
                }
            }
        }
        .onAppear {
            checkAndGenerateHardQuestionIfNeeded()
        }
    }

    private var currentQuestion: PersistedQuizQuestion? {
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
                Text(questions.isEmpty ? "" : "pergunta \(index + 1) de \(questions.count)")
                    .font(DS.Fonts.mono(11))
                    .foregroundStyle(DS.Colors.mist)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)

            ProgressBar(progress: questions.isEmpty ? 0 : Double(index + 1) / Double(questions.count))
        }
    }

    private var questionCard: some View {
        guard let question = currentQuestion else { return AnyView(EmptyView()) }
        let difficulty = Difficulty(rawValue: question.difficulty)

        return AnyView(
            VStack(alignment: .leading, spacing: 14) {
                if let difficulty {
                    PillView(
                        text: difficultyLabel(difficulty),
                        color: DS.Colors.difficulty(difficulty),
                        borderColor: DS.Colors.difficulty(difficulty).opacity(0.35)
                    )
                }
                Text(question.question)
                    .font(DS.Fonts.display(22))
                    .foregroundStyle(DS.Colors.foam)
            }
        )
    }

    private var optionsList: some View {
        guard let question = currentQuestion else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(spacing: 10) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
                    OptionRow(
                        text: option,
                        state: state(for: optionIndex, correctIndex: question.correctOptionIndex)
                    )
                    .onTapGesture {
                        guard selectedOption == nil else { return }
                        select(optionIndex)
                    }
                }
            }
        )
    }

    private func state(for optionIndex: Int, correctIndex: Int) -> OptionRow.State {
        guard let selectedOption else { return .idle }
        if optionIndex == correctIndex { return .correct }
        if optionIndex == selectedOption { return .incorrect }
        return .disabled
    }

    private func feedbackCard(selected: Int) -> some View {
        guard let question = currentQuestion else { return AnyView(EmptyView()) }
        let correct = selected == question.correctOptionIndex

        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
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
                Text(index == questions.count - 1 ? "Finalizar" : "Próxima pergunta")
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

    private func select(_ optionIndex: Int) {
        guard let question = currentQuestion else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            selectedOption = optionIndex
        }
        answers.append(
            AnsweredQuestion(
                questionText: question.question,
                selectedOptionIndex: optionIndex,
                correctOptionIndex: question.correctOptionIndex,
                explanation: question.explanation,
                difficulty: Difficulty(rawValue: question.difficulty)
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
        
        // 🤖 Verifica se a próxima pergunta é a DIFÍCIL para acionar o MLX
        checkAndGenerateHardQuestionIfNeeded()
    }

    // 🤖 LÓGICA AUTOMÁTICA DO MLX
    private func checkAndGenerateHardQuestionIfNeeded() {
        guard let question = currentQuestion, question.difficulty == "hard" else { return }
        
        Task {
            await MainActor.run { isLoadingHardQuestion = true }
            
            do {
                let generator = StudyGenerator(documentIndex: DocumentIndex())
                // Chama o MLX + RAG para gerar a pergunta difícil em tempo real
                let hardDraft = try await generator.generateAdvancedQuiz(topic: topicName)
                
                await MainActor.run {
                    // Atualiza a pergunta atual na lista com o texto gerado pelo MLX
                    if questions.indices.contains(index) {
                        questions[index] = PersistedQuizQuestion(
                            difficulty: "hard",
                            question: hardDraft,
                            options: questions[index].options, // Mantém ou adapta opções
                            correctOptionIndex: questions[index].correctOptionIndex,
                            explanation: "Gerado via MLX com RAG da documentação oficial de \(topicName)."
                        )
                    }
                    isLoadingHardQuestion = false
                }
            } catch {
                await MainActor.run {
                    isLoadingHardQuestion = false
                }
            }
        }
    }

    private func difficultyLabel(_ difficulty: Difficulty) -> String {
        switch difficulty {
        case .easy: return "FÁCIL"
        case .medium: return "MÉDIA"
        case .hard: return "DIFÍCIL"
        }
    }
}
/// Linha de alternativa reaproveitada pelo Quiz.
struct OptionRow: View {
    enum State { case idle, correct, incorrect, disabled }

    let text: String
    let state: State

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 18)
            Text(text)
                .font(DS.Fonts.body(15.5))
                .foregroundStyle(textColor)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .opacity(state == .disabled ? 0.5 : 1)
    }

    private var iconName: String {
        switch state {
        case .idle, .disabled: return "circle"
        case .correct: return "checkmark.circle.fill"
        case .incorrect: return "xmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch state {
        case .idle, .disabled: return DS.Colors.mistDim
        case .correct: return DS.Colors.sage
        case .incorrect: return DS.Colors.orchid
        }
    }

    private var textColor: Color {
        switch state {
        case .idle: return DS.Colors.foam
        case .disabled: return DS.Colors.mist
        case .correct: return DS.Colors.foam
        case .incorrect: return DS.Colors.foam
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .idle, .disabled: return DS.Colors.slate
        case .correct: return DS.Colors.sage.opacity(0.12)
        case .incorrect: return DS.Colors.orchid.opacity(0.12)
        }
    }

    private var borderColor: Color {
        switch state {
        case .idle, .disabled: return DS.Colors.hairline
        case .correct: return DS.Colors.sage.opacity(0.5)
        case .incorrect: return DS.Colors.orchid.opacity(0.5)
        }
    }
}
