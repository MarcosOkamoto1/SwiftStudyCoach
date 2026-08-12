//
//  StudyHomeView.swift
//  SwiftStudyCoach
//
//  Parte 7 — ponto de entrada pras telas visuais reais: escolher um tópico
//  curado e abrir o TopicStudyView (artigo + quiz/análise).
//
//  Plano V3 2.1/2.2: a busca livre (TextField) saiu — todo caminho passa
//  pela lista curada, derivada do dataset (PlaceholderDocs.topicsByBlock()),
//  garantindo que o RAG sempre tenha grounding real pro tópico escolhido.
//  Nada aqui é hardcoded: adicionar um chunk novo ao dataset é suficiente
//  pro tópico aparecer sozinho, no bloco certo.
//

import SwiftUI
import SwiftData

struct StudyHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StudyTopic.createdAt, order: .reverse) private var topics: [StudyTopic]

    @State private var navigateTo: String?

    private let track: [TrackSection] = PlaceholderDocs.topicsByBlock()

    var body: some View {
        NavigationStack {
            DSScreen {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SWIFT STUDY COACH")
                                .font(DS.Fonts.mono(11))
                                .tracking(1.4)
                                .foregroundStyle(DS.Colors.cyan)
                            Text("O que vamos estudar hoje?")
                                .font(DS.Fonts.display(28))
                                .foregroundStyle(DS.Colors.foam)
                        }
                        .padding(.top, 20)

                        if !topics.isEmpty {
                            sectionLabel("JÁ ESTUDADOS")
                            VStack(spacing: 8) {
                                ForEach(topics) { topic in
                                    topicRow(topic.name, meta: "\(topic.quizPool.count) no pool de quiz")
                                        .onTapGesture { navigateTo = topic.name }
                                }
                            }
                        }

                        ForEach(track) { entry in
                            sectionLabel("BLOCO \(entry.block.rawValue) — \(entry.block.title.uppercased())")
                            VStack(spacing: 8) {
                                ForEach(entry.topics, id: \.self) { topicName in
                                    topicRow(topicName, meta: nil)
                                        .onTapGesture { navigateTo = topicName }
                                }
                            }
                        }

                        // Botão de debug: marca todos os tópicos cacheados com
                        // uma versão de dataset inválida, forçando regeração na
                        // próxima visita (valida o versionamento sem recompilar).
                        #if DEBUG
                        if !topics.isEmpty {
                            Button {
                                invalidateDataset()
                            } label: {
                                Label("Invalidar dataset (debug)", systemImage: "arrow.clockwise.circle")
                                    .font(DS.Fonts.mono(11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(DS.Colors.orchid)
                            .padding(.top, 12)
                        }
                        #endif
                    }
                    .padding(24)
                }
            }
            .navigationDestination(item: $navigateTo) { name in
                TopicStudyView(topicName: name)
            }
        }
    }

    #if DEBUG
    private func invalidateDataset() {
        for topic in topics {
            topic.sourceDatasetVersion = "debug-invalidated"
        }
        try? modelContext.save()
    }
    #endif

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(DS.Fonts.mono(10.5))
            .tracking(1.2)
            .foregroundStyle(DS.Colors.mistDim)
            .padding(.top, 8)
    }

    private func topicRow(_ name: String, meta: String?) -> some View {
        HStack {
            Circle().fill(DS.Colors.mistDim).frame(width: 6, height: 6)
            Text(name)
                .font(DS.Fonts.body(15))
                .foregroundStyle(DS.Colors.foam)
            Spacer()
            if let meta {
                Text(meta)
                    .font(DS.Fonts.mono(10.5))
                    .foregroundStyle(DS.Colors.mistDim)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.mistDim)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.slate))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DS.Colors.hairline, lineWidth: 1))
    }
}

#Preview {
    StudyHomeView()
        .modelContainer(for: [
            StudyTopic.self,
            PersistedQuizQuestion.self,
            PersistedCodeAnalysisQuestion.self
        ])
}
