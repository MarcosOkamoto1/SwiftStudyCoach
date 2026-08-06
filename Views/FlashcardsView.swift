//
//  FlashcardsView.swift
//  SwiftStudyCoach
//
//  Parte 7 — navegação entre flashcards com "virar" (pergunta → resposta),
//  progresso e paleta escura do protótipo HTML.
//

import SwiftUI

struct FlashcardsView: View {
    let topicName: String
    let flashcards: [PersistedFlashcard]

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var isFlipped = false

    // Ângulos das duas faces do card, animados em dois estágios (0→90 e
    // 90→0) em vez de uma rotação única 0→180 — rotacionar o texto direto
    // até 180° o deixa espelhado (de trás pra frente) na segunda metade da
    // animação. Girando cada face só até 90° e trocando nesse ponto, o
    // texto nunca passa pelo ângulo onde ficaria espelhado.
    @State private var frontDegrees = 0.0
    @State private var backDegrees = -90.0

    var body: some View {
        DSScreen {
            VStack(spacing: 0) {
                header

                if flashcards.isEmpty {
                    Spacer()
                    Text("Nenhum flashcard disponível pra esse tópico ainda.")
                        .font(DS.Fonts.body(15))
                        .foregroundStyle(DS.Colors.mist)
                    Spacer()
                } else {
                    Spacer()
                    card
                        .padding(.horizontal, 28)
                    Spacer()
                    controls
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack {
                Button {
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
                Text(flashcards.isEmpty ? "" : "\(index + 1) / \(flashcards.count)")
                    .font(DS.Fonts.mono(11))
                    .foregroundStyle(DS.Colors.mist)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)

            ProgressBar(progress: flashcards.isEmpty ? 0 : Double(index + 1) / Double(flashcards.count))
        }
    }

    private var card: some View {
        let current = flashcards[index]

        return ZStack {
            cardFace(label: "PERGUNTA", labelColor: DS.Colors.violet, text: current.question)
                .rotation3DEffect(.degrees(frontDegrees), axis: (x: 0, y: 1, z: 0))
                .opacity(isFlipped ? 0 : 1)

            cardFace(label: "RESPOSTA", labelColor: DS.Colors.sage, text: current.answer)
                .rotation3DEffect(.degrees(backDegrees), axis: (x: 0, y: 1, z: 0))
                .opacity(isFlipped ? 1 : 0)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .onTapGesture { flip() }
    }

    private func cardFace(label: String, labelColor: Color, text: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(DS.Colors.slate)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(DS.Colors.hairline, lineWidth: 1)
                )

            VStack(spacing: 18) {
                Text(label)
                    .font(DS.Fonts.mono(10.5))
                    .tracking(1.4)
                    .foregroundStyle(labelColor)

                ScrollView {
                    Text(text)
                        .font(DS.Fonts.display(22))
                        .foregroundStyle(DS.Colors.foam)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }

                Text("toque pra virar")
                    .font(DS.Fonts.mono(10.5))
                    .foregroundStyle(DS.Colors.mistDim)
            }
            .padding(28)
        }
    }

    private func flip() {
        let half = 0.2
        if !isFlipped {
            withAnimation(.easeIn(duration: half)) { frontDegrees = 90 }
            withAnimation(.easeOut(duration: half).delay(half)) { backDegrees = 0 }
        } else {
            withAnimation(.easeIn(duration: half)) { backDegrees = -90 }
            withAnimation(.easeOut(duration: half).delay(half)) { frontDegrees = 0 }
        }
        // Troca qual face fica visível exatamente na metade — antes disso
        // a face nova ainda está de "costas" (90°/-90°), então trocar a
        // opacidade nesse instante não revela texto espelhado.
        DispatchQueue.main.asyncAfter(deadline: .now() + half) {
            isFlipped.toggle()
        }
    }

    private func resetFlip() {
        frontDegrees = 0
        backDegrees = -90
        isFlipped = false
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button {
                goTo(index - 1)
            } label: {
                Label("Anterior", systemImage: "chevron.left")
            }
            .buttonStyle(DSButtonStyle())
            .disabled(index == 0)
            .opacity(index == 0 ? 0.4 : 1)

            Button {
                goTo(index + 1)
            } label: {
                Label(index == flashcards.count - 1 ? "Concluir" : "Próximo", systemImage: "chevron.right")
            }
            .buttonStyle(DSButtonStyle(accent: DS.Colors.violet, filled: true))
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
        .padding(.top, 20)
    }

    private func goTo(_ newIndex: Int) {
        guard newIndex >= 0 else { return }
        if newIndex >= flashcards.count {
            dismiss()
            return
        }
        resetFlip()
        index = newIndex
    }
}

/// Barra de progresso fina, no estilo `.progress-track` / `.progress-fill`
/// do protótipo HTML — reaproveitada nas telas de Quiz e Análise de Código.
struct ProgressBar: View {
    let progress: Double // 0...1

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(DS.Colors.hairlineSoft)
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [DS.Colors.violetDim, DS.Colors.violet],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(4, proxy.size.width * min(1, max(0, progress))))
                    .animation(.easeOut(duration: 0.2), value: progress)
            }
        }
        .frame(height: 2)
    }
}

#Preview {
    FlashcardsView(
        topicName: "Actors",
        flashcards: [
            PersistedFlashcard(question: "O que é um actor?", answer: "Um tipo de referência que serializa acesso ao seu estado mutável."),
            PersistedFlashcard(question: "O que é uma data race?", answer: "Duas threads escrevendo no mesmo endereço de memória sem coordenação.")
        ]
    )
}
