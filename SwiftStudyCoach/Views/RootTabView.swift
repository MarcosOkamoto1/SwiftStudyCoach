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
        // Plano V3 4.3: no launch, se o modelo MLX já estiver em cache
        // local (checagem só com FileManager, sem rede), carrega ele em
        // background — assim a 1ª pergunta difícil não paga o custo de
        // carga. Sem cache, não faz nada (sem download não-solicitado).
        .task { MLXService.shared.prewarmIfCached() }
    }
}

#Preview {
    RootTabView()
        .modelContainer(for: [
            StudyTopic.self,
            PersistedQuizQuestion.self,
            PersistedCodeAnalysisQuestion.self
        ])
}
