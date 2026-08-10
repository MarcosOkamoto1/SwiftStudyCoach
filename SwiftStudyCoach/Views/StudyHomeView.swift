//
//  StudyHomeView.swift
//  SwiftStudyCoach
//
//  Parte 7 — ponto de entrada pras telas visuais reais: digitar/escolher
//  um tópico e abrir o TopicStudyView (artigo + flashcards/quiz/análise).
//

import SwiftUI
import SwiftData

struct StudyHomeView: View {
    @Query(sort: \StudyTopic.createdAt, order: .reverse) private var topics: [StudyTopic]

    @State private var topicName: String = ""
    @State private var navigateTo: String?

    private let suggestions = ["NavigationStack", "Property Wrappers", "Guard"]

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

                        sectionLabel("SUGESTÕES")
                        VStack(spacing: 8) {
                            ForEach(suggestions, id: \.self) { suggestion in
                                topicRow(suggestion, meta: nil)
                                    .onTapGesture { navigateTo = suggestion }
                            }
                        }
                    }
                    .padding(24)
                }
            }
            .navigationDestination(item: $navigateTo) { name in
                TopicStudyView(topicName: name)
            }
        }
    }

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
            PersistedFlashcard.self,
            PersistedQuizQuestion.self,
            PersistedCodeAnalysisQuestion.self
        ])
}
