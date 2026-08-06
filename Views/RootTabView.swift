//
//  RootTabView.swift
//  SwiftStudyCoach
//
//  Raiz temporária de navegação enquanto o app é só telas de teste/debug.
//  Junta as 3 telas existentes numa TabView pra não precisar comentar
//  código pra trocar entre elas.
//

import SwiftUI
import SwiftData

struct RootTabView: View {
    var body: some View {
        TabView {
            StudyHomeView()
                .tabItem { Label("Estudar", systemImage: "book.pages") }

            ContentView()
                .tabItem { Label("Resumo", systemImage: "text.book.closed") }

            TopicRepositoryTestView()
                .tabItem { Label("Fluxo completo", systemImage: "checklist") }

            RAGTestView()
                .tabItem { Label("RAG", systemImage: "magnifyingglass") }
        }
        .tint(DS.Colors.violet)
    }
}

#Preview {
    RootTabView()
        .modelContainer(for: [
            StudyTopic.self,
            PersistedFlashcard.self,
            PersistedQuizQuestion.self,
            PersistedCodeAnalysisQuestion.self
        ])
}
