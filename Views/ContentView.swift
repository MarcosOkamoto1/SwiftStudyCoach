//
//  ContentView.swift
//  SwiftStudyCoach
//
//  Tela mínima para validar persistência (SwiftData) + pool de quiz.
//  Sem design ainda — isso é só pra confirmar que:
//  - a 1ª visita a um tópico gera e persiste tudo
//  - a 2ª visita (mesma versão de dataset) é instantânea, sem chamar o modelo
//  - o quiz é sorteado do pool já existente, sem gerar nada na hora
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var documentIndex = DocumentIndex()
    @State private var generator: StudyGenerator?
    @State private var repository: TopicRepository?

    @State private var topic: String = "Optionals"
    @State private var studyTopic: StudyTopic?
    @State private var sampledQuiz: [PersistedQuizQuestion] = []

    @State private var isLoading = false
    @State private var isIndexing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Status do modelo") {
                    if let generator {
                        Text(generator.checkAvailability())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if isIndexing {
                        ProgressView("Indexando documentação...")
                    }
                }

                Section("Tópico de Swift") {
                    TextField("Ex: Optionals, async/await, Generics", text: $topic)

                    Button {
                        Task { await loadTopic() }
                    } label: {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("Carregar tópico (cache ou gerar)")
                        }
                    }
                    .disabled(topic.isEmpty || isLoading || repository == nil)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                if let studyTopic {
                    Section("Resumo") {
                        Text(studyTopic.summary)
                        Text("dataset: \(studyTopic.sourceDatasetVersion)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Section("Pontos-chave") {
                        ForEach(studyTopic.keyPoints, id: \.self) { point in
                            Label(point, systemImage: "checkmark.circle")
                        }
                    }

                    Section("Exemplo de código") {
                        Text(studyTopic.codeExample)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    Section("Flashcards (\(studyTopic.flashcards.count))") {
                        ForEach(studyTopic.flashcards) { card in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(card.question).bold()
                                Text(card.answer).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section("Pool de quiz") {
                        Text("Total no pool: \(studyTopic.quizPool.count) / 40")
                        Text("Gerando em background: \(studyTopic.isGeneratingPool ? "sim" : "não")")
                            .foregroundStyle(.secondary)

                        Button("Sortear quiz (3 fácil + 4 média + 3 difícil)") {
                            sampleQuiz()
                        }
                        .disabled(studyTopic.quizPool.isEmpty)

                        ForEach(Array(sampledQuiz.enumerated()), id: \.offset) { _, question in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("[\(question.difficulty)] \(question.question)")
                                    .bold()
                                Text(question.options.joined(separator: "  •  "))
                                    .font(.caption)
                            }
                        }
                    }

                    Section("Debug") {
                        Button("Simular atualização de dataset (invalidar cache)") {
                            // Só pra validar o critério de aceite de versionamento
                            // sem precisar mudar código e recompilar.
                            studyTopic.sourceDatasetVersion = "debug-invalidated"
                            try? modelContext.save()
                        }
                    }
                }
            }
            .navigationTitle("Swift Study Coach")
            .task {
                await setup()
            }
        }
    }

    private func setup() async {
        guard generator == nil else { return }
        isIndexing = true
        do {
            try await documentIndex.buildIndex()
            let generator = StudyGenerator(documentIndex: documentIndex)
            self.generator = generator
            self.repository = TopicRepository(modelContext: modelContext, generator: generator)
        } catch {
            errorMessage = "Erro ao indexar documentação: \(error.localizedDescription)"
        }
        isIndexing = false
    }

    private func loadTopic() async {
        guard let repository else { return }
        isLoading = true
        errorMessage = nil
        sampledQuiz = []
        defer { isLoading = false }

        do {
            studyTopic = try await repository.fetchOrCreate(topic: topic)
        } catch {
            errorMessage = "Erro ao gerar: \(error.localizedDescription)"
        }
    }

    private func sampleQuiz() {
        guard let studyTopic, let repository else { return }
        sampledQuiz = repository.sampleQuiz(from: studyTopic)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [
            StudyTopic.self,
            PersistedFlashcard.self,
            PersistedQuizQuestion.self,
            PersistedCodeAnalysisQuestion.self
        ], inMemory: true)
}
