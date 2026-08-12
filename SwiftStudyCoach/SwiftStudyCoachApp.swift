//
//  SwiftStudyCoachApp.swift
//  SwiftStudyCoach
//

import SwiftUI
import SwiftData

@main
struct SwiftStudyCoachApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(for: [
            StudyTopic.self,
            PersistedQuizQuestion.self,
            PersistedCodeAnalysisQuestion.self
        ])
    }
}
