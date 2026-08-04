//
//  RAGTestView.swift
//  SwiftStudyCoach
//
//  Tela TEMPORÁRIA só para validar o pipeline de RAG hoje.
//  Não precisa ficar bonita — é só pra confirmar que a busca traz
//  o chunk certo pra cada query antes de integrar com o Foundation Models.
//
//  Depois que validar, pode apagar essa view ou deixá-la escondida
//  atrás de um menu de debug.
//

import SwiftUI

struct RAGTestView: View {
    @State private var index = DocumentIndex()
    @State private var query: String = "o que é optional binding"
    @State private var results: [(chunk: DocChunk, similarity: Double)] = []
    @State private var errorMessage: String?
    @State private var debugMode: Bool = true

    var body: some View {
        Form {
            Section("Índice") {
                if index.isIndexing {
                    ProgressView("Indexando \(PlaceholderDocs.rawChunks.count) chunks...")
                } else if index.isReady {
                    Text("✅ \(index.chunks.count) chunks indexados")
                } else {
                    Button("Construir índice") {
                        Task { await buildIndex() }
                    }
                }
            }

            Section("Query de teste") {
                TextField("Ex: o que é optional binding", text: $query)
                Toggle("Modo debug (sem threshold)", isOn: $debugMode)
                Button("Buscar") {
                    Task { await runSearch() }
                }
                .disabled(!index.isReady || query.isEmpty)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            if !results.isEmpty {
                Section("Resultados (mais similar primeiro)") {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(result.chunk.topic).bold()
                                Spacer()
                                Text(String(format: "%.2f", result.similarity))
                                    .foregroundStyle(.secondary)
                            }
                            Text(result.chunk.text)
                                .font(.caption)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("RAG — Teste")
        .task {
            if !index.isReady {
                await buildIndex()
            }
        }
    }

    private func buildIndex() async {
        errorMessage = nil
        do {
            try await index.buildIndex()
        } catch {
            errorMessage = "Erro ao indexar: \(error.localizedDescription)"
        }
    }

    private func runSearch() async {
        errorMessage = nil
        do {
            let threshold: Double? = debugMode ? nil : 0.50
            results = try await index.search(
                query: query,
                minimumSimilarity: threshold
            )
            if results.isEmpty {
                errorMessage = "Nenhum resultado acima do threshold de similaridade — tente reduzir minimumSimilarity ou reformular a query."
            }
        } catch {
            errorMessage = "Erro na busca: \(error.localizedDescription)"
        }
    }
}

#Preview {
    RAGTestView()
}
