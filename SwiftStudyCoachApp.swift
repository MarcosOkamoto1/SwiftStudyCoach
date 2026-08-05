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
            ContentView()
        }
        .modelContainer(for: [
            StudyTopic.self,
            PersistedFlashcard.self,
            PersistedQuizQuestion.self,
            PersistedCodeAnalysisQuestion.self
        ])
    }
}
