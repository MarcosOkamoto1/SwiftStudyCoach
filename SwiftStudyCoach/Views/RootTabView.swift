//
//  RootTabView.swift
//  SwiftStudyCoach
//
//  Raiz de navegação. Em Release só a aba "Estudar" aparece; as telas
//  de debug (Resumo, Fluxo completo, RAG) ficam atrás de #if DEBUG
//  (PLAN_17) para manter a navegação de produção limpa.
//

import SwiftUI
import SwiftData

struct RootTabView: View {
    var body: some View {
        content
            .tint(DS.Colors.violet)
        // Plano V3 4.3: no launch, se o modelo MLX já estiver em cache
        // local (checagem só com FileManager, sem rede), carrega ele em
        // background — assim a 1ª pergunta difícil não paga o custo de
        // carga. Sem cache, não faz nada (sem download não-solicitado).
        .task { MLXService.shared.prewarmIfCached() }
    }

    @ViewBuilder
    private var content: some View {
        // PLAN_17: telas de debug só em builds de desenvolvimento.
        // Em Release não há TabView — StudyHomeView vira a raiz direta,
        // sem barra de abas com item único.
        #if DEBUG
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
        #else
        StudyHomeView()
        #endif
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
