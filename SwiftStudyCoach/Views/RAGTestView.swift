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

#if DEBUG
import SwiftUI

struct RAGTestView: View {
    private let index = DocumentIndex.shared
    @State private var query: String = "Property Wrappers"
    @State private var results: [(chunk: DocChunk, similarity: Double)] = []
    @State private var errorMessage: String?
    @State private var debugMode: Bool = true
    /// Plano V5: por padrão testa o MESMO caminho usado em produção
    /// (`hybridSearch` — cosseno + léxico + boost de tópico). Desligar
    /// volta pra busca semântica pura (só cosseno), útil só pra comparar e
    /// entender o quanto o cosseno sozinho é pouco discriminativo nesse
    /// domínio (ver comentário em DocumentIndex.hybridSearch).
    @State private var useHybridSearch: Bool = true

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
                TextField("Ex: Property Wrappers, async/await, NavigationStack", text: $query)
                Toggle("Busca híbrida (produção: cosseno + léxico + boost de tópico)", isOn: $useHybridSearch)
                if !useHybridSearch {
                    Toggle("Modo debug (sem threshold)", isOn: $debugMode)
                }
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
            try await index.ensureReady()
        } catch {
            errorMessage = "Erro ao indexar: \(error.localizedDescription)"
        }
    }

    private func runSearch() async {
        errorMessage = nil
        do {
            if useHybridSearch {
                let ranked = try await index.hybridSearch(query: query, topK: 3)
                results = ranked.map { (chunk: $0.chunk, similarity: $0.score) }
                if results.isEmpty {
                    errorMessage = "Nenhum resultado — hybridSearch não achou nada acima do threshold adaptativo interno (0.45, relaxando pra 0.30 com sinal léxico/tópico)."
                }
            } else {
                let threshold: Double? = debugMode ? nil : 0.50
                results = try await index.search(
                    query: query,
                    minimumSimilarity: threshold
                )
                if results.isEmpty {
                    errorMessage = "Nenhum resultado acima do threshold de similaridade — tente reduzir minimumSimilarity ou reformular a query."
                }
            }
        } catch {
            errorMessage = "Erro na busca: \(error.localizedDescription)"
        }
    }
}

#Preview {
    RAGTestView()
}
#endif // DEBUG
