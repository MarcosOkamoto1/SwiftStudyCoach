//
//  BenchmarkPrompts.swift
//  SwiftStudyCoach
//
//  PLAN_05 — Ferramenta de avaliação de modelo MLX (SOLUTIONS_PLAN.md §9).
//  Dados puros: os 18 prompts representativos de §9.1. NÃO é lógica de
//  produto — não é chamado por nenhum caminho de geração real do app
//  (StudyGenerator, TopicRepository etc.), só pelo runner do benchmark
//  (ver ModelBenchmarkSuite.swift) a partir de uma tela de debug.
//
//  Cada prompt reaproveita LITERALMENTE o formato de instrução que o
//  código de produção usa hoje (StudyGenerator.swift: generateCodeExample,
//  critiqueCodeDraft, generateQuizBatch/hard, generateCodeAnalysisBatch) —
//  não é um formato de benchmark artificial. Os comentários `// Formato:`
//  apontam a função de produção de onde cada bloco foi copiado.
//
//  O contexto RAG de cada prompt é resolvido EM RUNTIME pelo runner,
//  chamando `StudyGenerator.retrieveContext(for:topK:)` — o MESMO caminho
//  usado em produção (busca exata por tópico, com fallback fuzzy se o
//  tópico não existir no dataset). Isso é o que faz os prompts 12/13
//  (fora do dataset) testarem hallucination em terreno não coberto pelo
//  RAG de verdade, em vez de simular isso com uma string vazia hardcoded.
//

import Foundation

/// Um dos 18 prompts representativos do benchmark (§9.1).
struct BenchmarkPromptSpec: Identifiable {

    enum Category: String, Codable, CaseIterable {
        case exampleGeneration = "Geração de exemplo"
        case apiHallucinationCheck = "Identificação de API inexistente"
        case semanticBugCheck = "Bug semântico"
        case hardQuestion = "Pergunta difícil"
        case hardQuestionBatch = "Pergunta difícil em lote"
        case codeAnalysis = "Análise de código"
        case codeAnalysisBatch = "Análise de código em lote"
        case shortExplanation = "Explicação técnica curta"
        case formatAdherence = "Adherence à instrução de formato"
        case ragAdherence = "Adherence ao RAG"
        case batchInstructionFollowing = "Instruction-following em lote"
        case concurrencyReasoning = "Raciocínio sobre concorrência"
    }

    let id: Int // 1...18, mesma numeração de SOLUTIONS_PLAN.md §9.1
    let category: Category
    /// Resumo curto do que o prompt testa (para exibição na UI de debug).
    let summary: String
    /// Tópico usado para recuperar contexto RAG via
    /// `StudyGenerator.retrieveContext(for:topK:)`. `nil` = sem RAG
    /// (prompt não depende de contexto de documentação).
    let ragTopic: String?
    let ragTopK: Int
    let systemPrompt: String
    /// Constrói o prompt final (mesmo texto que o `promptContext` de
    /// `MLXService.generate*`) a partir do contexto RAG já resolvido
    /// (string vazia se `ragTopic == nil` ou a busca não achou nada).
    let buildPrompt: (_ ragContext: String) -> String
    /// `GenerationMetrics.TaskType` mais próximo — só para rotular a
    /// métrica gerada por esta chamada (não existe um case dedicado a
    /// benchmark no enum de produção, e este plano não pode adicionar um
    /// — ver "O que NÃO alterar" do PLAN_05). Usa o case existente cuja
    /// forma de prompt mais se aproxima.
    let taskType: GenerationMetrics.TaskType
    /// >1 para os 3 prompts em lote (11, 13, 17) — usa
    /// `MLXService.generateQuestionDrafts(count:)` em vez de
    /// `generateQuestionDraft`.
    let batchCount: Int
    /// true para os prompts 4-7 (categoria "identificação de API
    /// inexistente"/"bug semântico") — são os prompts que alimentam o
    /// veto duro de §9.4 (qualquer hallucination aqui derruba o modelo
    /// abaixo de qualquer concorrente sem ocorrências).
    var isHardVetoPrompt: Bool { (4...7).contains(id) }
}

enum BenchmarkPrompts {

    static let itemSeparator = MLXService.itemSeparator

    static let all: [BenchmarkPromptSpec] = [

        // MARK: 1-3 — Geração de exemplo (contexto real do dataset)
        // Formato: StudyGenerator.generateCodeExample (mlxPrompt)

        BenchmarkPromptSpec(
            id: 1,
            category: .exampleGeneration,
            summary: "Exemplo de uso de NavigationStack com navigationDestination(for:)",
            ragTopic: "NavigationStack",
            ragTopK: 3,
            systemPrompt: "Você é um especialista em Swift. Gere um código de exemplo curto e uma explicação passo a passo, em texto puro, usando apenas APIs reais.",
            buildPrompt: { context in
                """
                Você é um especialista em Swift. Escreva UM código Swift de 5-15 linhas, limpo e completo, que ilustre o uso de NavigationStack com navigationDestination(for:destination:), e explique-o passo a passo em texto puro.

                [Contexto oficial]:
                \(context.isEmpty ? "Conhecimento geral sobre Swift e Apple Frameworks." : context)

                IMPORTANTE: use SOMENTE APIs, tipos e modificadores que aparecem no contexto oficial acima \
                ou que você tem certeza absoluta que existem na versão atual de Swift/SwiftUI. NÃO invente \
                nomes de métodos, classes, structs ou modificadores. Se não tiver certeza de que algo existe, \
                prefira uma abordagem mais simples e genérica em vez de arriscar um nome inventado.

                Formato exato da resposta (texto puro, sem markdown, sem JSON):
                CODIGO:
                <código>
                PASSO A PASSO:
                1. <trecho> — <explicação>
                2. <trecho> — <explicação>
                """
            },
            taskType: .codeExampleDraft,
            batchCount: 1
        ),

        BenchmarkPromptSpec(
            id: 2,
            category: .exampleGeneration,
            summary: "Exemplo de uso de @State/@Observable numa View real",
            ragTopic: "Property Wrappers",
            ragTopK: 3,
            systemPrompt: "Você é um especialista em Swift. Gere um código de exemplo curto e uma explicação passo a passo, em texto puro, usando apenas APIs reais.",
            buildPrompt: { context in
                """
                Você é um especialista em Swift. Escreva UM código Swift de 5-15 linhas, limpo e completo, que ilustre o uso prático de @State e/ou @Observable numa View SwiftUI real, e explique-o passo a passo em texto puro.

                [Contexto oficial]:
                \(context.isEmpty ? "Conhecimento geral sobre Swift e Apple Frameworks." : context)

                IMPORTANTE: use SOMENTE APIs, tipos e modificadores que aparecem no contexto oficial acima \
                ou que você tem certeza absoluta que existem na versão atual de Swift/SwiftUI. NÃO invente \
                nomes de métodos, classes, structs ou modificadores.

                IMPORTANTE: priorize demonstrar o USO PRÁTICO do conceito, exatamente como um desenvolvedor \
                usaria no dia a dia — NÃO reimplemente o mecanismo do zero.

                Formato exato da resposta (texto puro, sem markdown, sem JSON):
                CODIGO:
                <código>
                PASSO A PASSO:
                1. <trecho> — <explicação>
                2. <trecho> — <explicação>
                """
            },
            taskType: .codeExampleDraft,
            batchCount: 1
        ),

        BenchmarkPromptSpec(
            id: 3,
            category: .exampleGeneration,
            summary: "Exemplo de async let com 2 operações paralelas",
            ragTopic: "async/await",
            ragTopK: 3,
            systemPrompt: "Você é um especialista em Swift. Gere um código de exemplo curto e uma explicação passo a passo, em texto puro, usando apenas APIs reais.",
            buildPrompt: { context in
                """
                Você é um especialista em Swift. Escreva UM código Swift de 5-15 linhas, limpo e completo, que ilustre o uso de `async let` com 2 operações assíncronas em paralelo, e explique-o passo a passo em texto puro.

                [Contexto oficial]:
                \(context.isEmpty ? "Conhecimento geral sobre Swift e Apple Frameworks." : context)

                IMPORTANTE: use SOMENTE APIs, tipos e modificadores que aparecem no contexto oficial acima \
                ou que você tem certeza absoluta que existem na versão atual de Swift/SwiftUI. NÃO invente \
                nomes de métodos, classes, structs ou modificadores.

                Formato exato da resposta (texto puro, sem markdown, sem JSON):
                CODIGO:
                <código>
                PASSO A PASSO:
                1. <trecho> — <explicação>
                2. <trecho> — <explicação>
                """
            },
            taskType: .codeExampleDraft,
            batchCount: 1
        ),

        // MARK: 4-7 — Identificação de API inexistente / bug semântico
        // Formato: StudyGenerator.critiqueCodeDraft (instructions + prompt)
        // Estes 4 prompts alimentam o veto duro de §9.4.

        BenchmarkPromptSpec(
            id: 4,
            category: .apiHallucinationCheck,
            summary: "Rascunho com NavigationPath.popToRoot() (método que não existe) — pedir crítica",
            ragTopic: "NavigationStack",
            ragTopK: 3,
            systemPrompt: """
            Você é um revisor de código Swift rigoroso. Sua ÚNICA tarefa é apontar erros técnicos REAIS \
            no rascunho de código abaixo — não reescreva o código, só liste os problemas. \
            Procure especificamente por: APIs que não existem, uso incorreto de uma API real, \
            métodos/modificadores deprecados, e qualquer contradição com o contexto de documentação \
            oficial fornecido. Se não encontrar nenhum erro real, responda exatamente "OK - sem erros". \
            Seja específico (cite o trecho exato) e conciso — no máximo 5 pontos. Responda sempre em português.
            """,
            buildPrompt: { context in
                """
                Contexto da documentação oficial:
                \(context.isEmpty ? "Conhecimento geral de Swift, com cautela." : context)

                Rascunho de código Swift sobre 'NavigationStack':
                struct RootView: View {
                    @State private var path = NavigationPath()

                    var body: some View {
                        NavigationStack(path: $path) {
                            ContentView()
                                .navigationDestination(for: Produto.self) { produto in
                                    DetalheView(produto: produto)
                                }
                        }
                    }

                    func voltarParaInicio() {
                        path.popToRoot()
                    }
                }

                Liste os erros técnicos reais encontrados no rascunho acima (ou "OK - sem erros").
                """
            },
            taskType: .codeExampleCritique,
            batchCount: 1
        ),

        BenchmarkPromptSpec(
            id: 5,
            category: .semanticBugCheck,
            summary: "Rascunho com .navigationDestination(for: 1) (valor em vez de tipo) — pedir crítica",
            ragTopic: "NavigationStack",
            ragTopK: 3,
            systemPrompt: """
            Você é um revisor de código Swift rigoroso. Sua ÚNICA tarefa é apontar erros técnicos REAIS \
            no rascunho de código abaixo — não reescreva o código, só liste os problemas. \
            Procure especificamente por: uso incorreto de uma API real (ex.: passar um valor onde a API \
            espera um TIPO, como em navigationDestination(for:), que exige Tipo.self e não um valor \
            literal), APIs que não existem, e qualquer contradição com o contexto de documentação oficial \
            fornecido. Se não encontrar nenhum erro real, responda exatamente "OK - sem erros". Seja \
            específico (cite o trecho exato) e conciso — no máximo 5 pontos. Responda sempre em português.
            """,
            buildPrompt: { context in
                """
                Contexto da documentação oficial:
                \(context.isEmpty ? "Conhecimento geral de Swift, com cautela." : context)

                Rascunho de código Swift sobre 'NavigationStack':
                NavigationStack(path: $path) {
                    ContentView()
                        .navigationDestination(for: 1) { valor in
                            Text("Detalhe: \\(valor)")
                        }
                }

                Liste os erros técnicos reais encontrados no rascunho acima (ou "OK - sem erros").
                """
            },
            taskType: .codeExampleCritique,
            batchCount: 1
        ),

        BenchmarkPromptSpec(
            id: 6,
            category: .semanticBugCheck,
            summary: "Rascunho com @StateObject aplicado a um Int/Bool — pedir crítica",
            ragTopic: "Property Wrappers",
            ragTopK: 3,
            systemPrompt: """
            Você é um revisor de código Swift rigoroso. Sua ÚNICA tarefa é apontar erros técnicos REAIS \
            no rascunho de código abaixo — não reescreva o código, só liste os problemas. Procure \
            especificamente por: NavigationPath, Bool, Int, String e outros tipos de VALOR (não-classe) \
            que usam @StateObject em vez de @State (StateObject só serve pra tipos que conformam \
            ObservableObject/@Observable), APIs que não existem, e qualquer contradição com o contexto \
            de documentação oficial fornecido. Se não encontrar nenhum erro real, responda exatamente \
            "OK - sem erros". Seja específico (cite o trecho exato) e conciso — no máximo 5 pontos. \
            Responda sempre em português.
            """,
            buildPrompt: { context in
                """
                Contexto da documentação oficial:
                \(context.isEmpty ? "Conhecimento geral de Swift, com cautela." : context)

                Rascunho de código Swift sobre 'Property Wrappers':
                struct ContadorView: View {
                    @StateObject private var contador: Int = 0

                    var body: some View {
                        Text("Contagem: \\(contador)")
                    }
                }

                Liste os erros técnicos reais encontrados no rascunho acima (ou "OK - sem erros").
                """
            },
            taskType: .codeExampleCritique,
            batchCount: 1
        ),

        BenchmarkPromptSpec(
            id: 7,
            category: .semanticBugCheck,
            summary: "Rascunho com Button(\"Salvar\") sem action:/closure — pedir crítica",
            ragTopic: "Property Wrappers",
            ragTopK: 3,
            systemPrompt: """
            Você é um revisor de código Swift rigoroso. Sua ÚNICA tarefa é apontar erros técnicos REAIS \
            no rascunho de código abaixo — não reescreva o código, só liste os problemas. Procure \
            especificamente por: Button, Toggle, NavigationLink e afins que recebem uma ação/closure e \
            ficam sem ela (não compila), APIs que não existem, e qualquer contradição com o contexto de \
            documentação oficial fornecido. Se não encontrar nenhum erro real, responda exatamente \
            "OK - sem erros". Seja específico (cite o trecho exato) e conciso — no máximo 5 pontos. \
            Responda sempre em português.
            """,
            buildPrompt: { context in
                """
                Contexto da documentação oficial:
                \(context.isEmpty ? "Conhecimento geral de Swift, com cautela." : context)

                Rascunho de código Swift sobre 'Property Wrappers':
                struct FormularioView: View {
                    @State private var nome: String = ""

                    var body: some View {
                        VStack {
                            TextField("Nome", text: $nome)
                            Button("Salvar")
                        }
                    }
                }

                Liste os erros técnicos reais encontrados no rascunho acima (ou "OK - sem erros").
                """
            },
            taskType: .codeExampleCritique,
            batchCount: 1
        ),

        // MARK: 8-10 — Pergunta difícil (single)
        // Formato: StudyGenerator.generateQuizBatch (difficulty == .hard, mlxPrompt), count=1

        BenchmarkPromptSpec(
            id: 8,
            category: .hardQuestion,
            summary: "Pergunta técnica avançada sobre type-erasure de NavigationPath",
            ragTopic: "NavigationStack",
            ragTopK: 3,
            systemPrompt: "Você é um especialista em Swift. Gere perguntas técnicas difíceis sobre conceitos da linguagem, em texto puro.",
            buildPrompt: { context in
                """
                Você é um especialista em Swift. Crie 1 pergunta técnica de nível avançado sobre 'NavigationStack', focando especificamente no comportamento type-erased de NavigationPath (por que ela pode guardar valores de tipos diferentes na mesma pilha).
                Contexto oficial: \(context)

                Formato da pergunta (texto puro, sem markdown):
                PERGUNTA: <a pergunta>
                RESPOSTA CORRETA: <explicação do comportamento/resposta certa, 1-2 frases>
                POR QUE OUTRAS RESPOSTAS PARECEM CERTAS MAS NÃO SÃO: <1-2 frases de erros comuns/conceitos que confundem>
                """
            },
            taskType: .hardQuizDraft,
            batchCount: 1
        ),

        BenchmarkPromptSpec(
            id: 9,
            category: .hardQuestion,
            summary: "Pergunta técnica avançada sobre granularidade de @Observable",
            ragTopic: "Property Wrappers",
            ragTopK: 3,
            systemPrompt: "Você é um especialista em Swift. Gere perguntas técnicas difíceis sobre conceitos da linguagem, em texto puro.",
            buildPrompt: { context in
                """
                Você é um especialista em Swift. Crie 1 pergunta técnica de nível avançado sobre 'Property Wrappers', focando especificamente na granularidade de rastreamento de mudanças do macro @Observable (por propriedade lida, não por objeto inteiro).
                Contexto oficial: \(context)

                Formato da pergunta (texto puro, sem markdown):
                PERGUNTA: <a pergunta>
                RESPOSTA CORRETA: <explicação do comportamento/resposta certa, 1-2 frases>
                POR QUE OUTRAS RESPOSTAS PARECEM CERTAS MAS NÃO SÃO: <1-2 frases de erros comuns/conceitos que confundem>
                """
            },
            taskType: .hardQuizDraft,
            batchCount: 1
        ),

        BenchmarkPromptSpec(
            id: 10,
            category: .hardQuestion,
            summary: "Pergunta técnica avançada sobre Task.detached vs. Task estruturada",
            ragTopic: "async/await",
            ragTopK: 3,
            systemPrompt: "Você é um especialista em Swift. Gere perguntas técnicas difíceis sobre conceitos da linguagem, em texto puro.",
            buildPrompt: { context in
                """
                Você é um especialista em Swift. Crie 1 pergunta técnica de nível avançado sobre 'async/await', focando especificamente na diferença entre Task.detached e uma Task estruturada comum (herança de prioridade, isolamento de actor, cancelamento).
                Contexto oficial: \(context)

                Formato da pergunta (texto puro, sem markdown):
                PERGUNTA: <a pergunta>
                RESPOSTA CORRETA: <explicação do comportamento/resposta certa, 1-2 frases>
                POR QUE OUTRAS RESPOSTAS PARECEM CERTAS MAS NÃO SÃO: <1-2 frases de erros comuns/conceitos que confundem>
                """
            },
            taskType: .hardQuizDraft,
            batchCount: 1
        ),

        // MARK: 11 — Pergunta difícil em LOTE (4), testa §6.2.1 (batching)
        // Formato: StudyGenerator.generateQuizBatch (difficulty == .hard, mlxPrompt), count=4

        BenchmarkPromptSpec(
            id: 11,
            category: .hardQuestionBatch,
            summary: "4 perguntas avançadas distintas sobre async/await numa única chamada",
            ragTopic: "async/await",
            ragTopK: 3,
            systemPrompt: "Você é um especialista em Swift. Gere perguntas técnicas difíceis sobre conceitos da linguagem, em texto puro.",
            buildPrompt: { context in
                """
                Você é um especialista em Swift. Crie 4 perguntas técnicas de nível avançado sobre 'async/await', distintas entre si.
                Contexto oficial: \(context)

                Formato de CADA pergunta (texto puro, sem markdown), separadas pela linha \(BenchmarkPrompts.itemSeparator):
                PERGUNTA: <a pergunta>
                RESPOSTA CORRETA: <explicação do comportamento/resposta certa, 1-2 frases>
                POR QUE OUTRAS RESPOSTAS PARECEM CERTAS MAS NÃO SÃO: <1-2 frases de erros comuns/conceitos que confundem>
                """
            },
            taskType: .hardQuizDraft,
            batchCount: 4
        ),

        // MARK: 12 — Análise de código (fora do dataset: Actors)
        // Formato: StudyGenerator.generateCodeAnalysisBatch (mlxPrompt), count=1

        BenchmarkPromptSpec(
            id: 12,
            category: .codeAnalysis,
            summary: "Trecho com actor e 2 chamadas concorrentes a um método — perguntar comportamento (fora do dataset)",
            ragTopic: "Actors", // não existe literalmente no dataset — força fallback fuzzy do RAG (testa raciocínio fora do RAG, como pede a tabela §9.1)
            ragTopK: 3,
            systemPrompt: "Você é um especialista em Swift. Gere trechos de código e perguntas de análise sobre seus comportamentos, em texto puro.",
            buildPrompt: { context in
                """
                Você é um especialista em Swift. Escreva 1 trecho de código Swift limpo, de 6 a 10 linhas, usando um `actor` com um método que é chamado concorrentemente de 2 lugares diferentes, e explique o comportamento esperado (isolamento de estado do actor).

                [Contexto RAG]:
                \(context.isEmpty ? "Conhecimento geral sobre Swift e Apple Frameworks." : context)

                Formato do item (texto puro, sem markdown, sem JSON):
                CODIGO:
                <o trecho de código Swift>
                COMPORTAMENTO ESPERADO: <o que o código faz / resultado ao executar, 1-2 frases>
                POR QUE OUTRAS RESPOSTAS PARECEM CERTAS MAS NÃO SÃO: <1-2 frases de erros comuns/conceitos que confundem>
                """
            },
            taskType: .codeAnalysisDraft,
            batchCount: 1
        ),

        // MARK: 13 — Análise de código em LOTE (4) (fora do dataset: closures)
        // Formato: StudyGenerator.generateCodeAnalysisBatch (mlxPrompt), count=4, testa §6.2.2

        BenchmarkPromptSpec(
            id: 13,
            category: .codeAnalysisBatch,
            summary: "4 trechos distintos sobre closures capturando self — pedir comportamento de cada (fora do dataset)",
            ragTopic: "Closures", // não existe literalmente no dataset — mesmo motivo do prompt 12
            ragTopK: 3,
            systemPrompt: "Você é um especialista em Swift. Gere trechos de código e perguntas de análise sobre seus comportamentos, em texto puro.",
            buildPrompt: { context in
                """
                Você é um especialista em Swift. Escreva 4 trechos de código Swift limpos, de 6 a 10 linhas cada, sobre closures capturando `self` (referência forte, [weak self], [unowned self]), e explique o comportamento de cada um. Os trechos devem ser distintos entre si.

                [Contexto RAG]:
                \(context.isEmpty ? "Conhecimento geral sobre Swift e Apple Frameworks." : context)

                Formato de CADA item (texto puro, sem markdown, sem JSON), separados pela linha \(BenchmarkPrompts.itemSeparator):
                CODIGO:
                <o trecho de código Swift>
                COMPORTAMENTO ESPERADO: <o que o código faz / resultado ao executar, 1-2 frases>
                POR QUE OUTRAS RESPOSTAS PARECEM CERTAS MAS NÃO SÃO: <1-2 frases de erros comuns/conceitos que confundem>
                """
            },
            taskType: .codeAnalysisDraft,
            batchCount: 4
        ),

        // MARK: 14 — Explicação técnica curta

        BenchmarkPromptSpec(
            id: 14,
            category: .shortExplanation,
            summary: "Diferença entre @Binding e @State em 2-3 frases",
            ragTopic: "Property Wrappers",
            ragTopK: 3,
            systemPrompt: "Você é um especialista em Swift. Responda de forma direta e técnica, em texto puro, sem markdown.",
            buildPrompt: { context in
                """
                [Contexto oficial]:
                \(context.isEmpty ? "Conhecimento geral sobre Swift e Apple Frameworks." : context)

                Explique, em EXATAMENTE 2-3 frases, a diferença entre @Binding e @State no SwiftUI. \
                Seja técnico e direto, sem introdução nem conclusão genérica.
                """
            },
            taskType: .codeExampleDraft,
            batchCount: 1
        ),

        // MARK: 15 — Adherence à instrução de formato (CODIGO:/PASSO A PASSO, sem markdown)
        // Formato: StudyGenerator.generateCodeExample (mlxPrompt), idêntico ao prompt 1 —
        // aqui o foco da avaliação é o §9.3 "instruction following", não o conteúdo.

        BenchmarkPromptSpec(
            id: 15,
            category: .formatAdherence,
            summary: "Resposta EXATA no formato CODIGO:/PASSO A PASSO, sem markdown — testa instruction following",
            ragTopic: "NavigationStack",
            ragTopK: 3,
            systemPrompt: "Você é um especialista em Swift. Gere um código de exemplo curto e uma explicação passo a passo, em texto puro, usando apenas APIs reais.",
            buildPrompt: { context in
                """
                Você é um especialista em Swift. Escreva UM código Swift de 5-15 linhas, limpo e completo, que ilustre o conceito principal de 'NavigationStack', e explique-o passo a passo em texto puro.

                [Contexto oficial]:
                \(context.isEmpty ? "Conhecimento geral sobre Swift e Apple Frameworks." : context)

                IMPORTANTE: use SOMENTE APIs, tipos e modificadores que aparecem no contexto oficial acima \
                ou que você tem certeza absoluta que existem na versão atual de Swift/SwiftUI. NÃO invente \
                nomes de métodos, classes, structs ou modificadores.

                Formato exato da resposta (texto puro, SEM MARKDOWN, sem blocos de código delimitados por crases, sem JSON):
                CODIGO:
                <código>
                PASSO A PASSO:
                1. <trecho> — <explicação>
                2. <trecho> — <explicação>
                """
            },
            taskType: .codeExampleDraft,
            batchCount: 1
        ),

        // MARK: 16 — Adherence ao RAG (contexto deliberadamente insuficiente)

        BenchmarkPromptSpec(
            id: 16,
            category: .ragAdherence,
            summary: "Pergunta sobre NavigationSplitView — contexto RAG NÃO cobre; espera-se que o modelo sinalize incerteza em vez de inventar",
            ragTopic: "NavigationStack", // contexto real, mas NÃO fala de NavigationSplitView — insuficiência deliberada
            ragTopK: 3,
            systemPrompt: "Você é um especialista em Swift. Responda apenas com base no contexto fornecido, sem inventar informação.",
            buildPrompt: { context in
                """
                [Contexto oficial]:
                \(context.isEmpty ? "Conhecimento geral sobre Swift e Apple Frameworks." : context)

                Explique como o NavigationSplitView decide quantas colunas mostrar em diferentes tamanhos de tela, \
                e como ele se relaciona com NavigationPath.

                IMPORTANTE: baseie-se SOMENTE no contexto oficial acima. Se o contexto não cobrir os detalhes \
                pedidos, diga explicitamente que não tem certeza/não está no contexto fornecido, em vez de \
                inventar um comportamento.
                """
            },
            taskType: .codeExampleDraft,
            batchCount: 1
        ),

        // MARK: 17 — Instruction-following em lote (4 itens, separador correto)

        BenchmarkPromptSpec(
            id: 17,
            category: .batchInstructionFollowing,
            summary: "4 dicas de boas práticas Swift separadas por itemSeparator — verificar se os 4 delimitadores saem corretos",
            ragTopic: nil, // qualquer tópico, per §9.1 — não depende de RAG
            ragTopK: 0,
            systemPrompt: "Você é um especialista em Swift. Gere dicas técnicas curtas, em texto puro.",
            buildPrompt: { _ in
                """
                Você é um especialista em Swift. Escreva 4 dicas curtas e distintas de boas práticas gerais de Swift (1-2 frases cada).

                Formato de CADA dica (texto puro, sem markdown), separadas pela linha \(BenchmarkPrompts.itemSeparator):
                DICA: <a dica, 1-2 frases>
                """
            },
            taskType: .hardQuizDraft,
            batchCount: 4
        ),

        // MARK: 18 — Raciocínio sobre concorrência (conceito do próprio dataset)
        // PlaceholderDocs.swift: parágrafo de async/await sobre Task.detached
        // "joga fora justamente as garantias estruturais que async/await foi desenhado pra oferecer".

        BenchmarkPromptSpec(
            id: 18,
            category: .concurrencyReasoning,
            summary: "Por que Task.detached 'joga fora garantias estruturais' — conceito do próprio dataset",
            ragTopic: "async/await",
            ragTopK: 3,
            systemPrompt: "Você é um especialista em Swift. Responda de forma direta e técnica, em texto puro, sem markdown.",
            buildPrompt: { context in
                """
                [Contexto oficial]:
                \(context.isEmpty ? "Conhecimento geral sobre Swift e Apple Frameworks." : context)

                Explique por que usar Task.detached sem necessidade real "joga fora as garantias estruturais" \
                que async/await foi desenhado para oferecer, comparado a uma Task comum (não detached) criada \
                dentro do escopo certo. Seja específico sobre quais garantias são perdidas (herança de \
                prioridade, isolamento de actor, propagação de cancelamento).
                """
            },
            taskType: .codeExampleCritique,
            batchCount: 1
        ),
    ]
}
