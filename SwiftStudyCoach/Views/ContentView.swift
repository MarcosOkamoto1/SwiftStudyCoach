//
//  ContentView.swift
//  SwiftStudyCoach
//
//  Tela mínima de teste para o dia de hoje: digitar um tópico e ver
//  o Foundation Models gerar um resumo estruturado. Sem design ainda —
//  isso é só pra validar o pipeline.
//

import SwiftUI

struct ContentView: View {
    @State private var generator = StudyGenerator()
    @State private var topic: String = "Optionals"
    @State private var result: TopicSummary?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Status do modelo") {
                    Text(generator.checkAvailability())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Tópico de Swift") {
                    TextField("Ex: Optionals, async/await, Generics", text: $topic)

                    Button {
                        Task { await generate() }
                    } label: {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("Gerar resumo")
                        }
                    }
                    .disabled(topic.isEmpty || isLoading)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                if let result {
                    Section("Resumo") {
                        Text(result.summary)
                    }

                    Section("Pontos-chave") {
                        ForEach(result.keyPoints, id: \.self) { point in
                            Label(point, systemImage: "checkmark.circle")
                        }
                    }

                    Section("Exemplo de código") {
                        Text(result.codeExample)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Swift Study Coach")
        }
    }

    private func generate() async {
        isLoading = true
        errorMessage = nil
        result = nil
        defer { isLoading = false }

        do {
            result = try await generator.generateSummary(topic: topic)
        } catch {
            errorMessage = "Erro ao gerar: \(error.localizedDescription)"
        }
    }
}

#Preview {
    ContentView()
}
