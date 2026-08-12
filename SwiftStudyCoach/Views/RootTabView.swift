//
//  RootTabView.swift
//  SwiftStudyCoach
//
//  Raiz de navegação do app. As telas de teste/debug (resumo mínimo,
//  fluxo completo e busca RAG) foram usadas só durante o desenvolvimento
//  e já saíram do app — a StudyHomeView é o ponto de entrada real.
//

import SwiftUI
import SwiftData

struct RootTabView: View {
    var body: some View {
        StudyHomeView()
            .tint(DS.Colors.violet)
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
