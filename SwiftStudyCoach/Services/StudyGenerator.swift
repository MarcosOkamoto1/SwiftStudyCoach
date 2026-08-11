//
//  StudyGenerator.swift
//  SwiftStudyCoach
//
//  Encapsula a comunicação com o Foundation Models framework, com
//  grounding via RAG (DocumentIndex).
//
//  Melhorias desta versão:
//  - StudyGeneratorError agora é LocalizedError e carrega a ETAPA que
//    falhou + o erro real do Foundation Models (antes a UI só mostrava
//    "error 1" genérico, impossível de diagnosticar).
//  - Retry com degradação: contexto excedeu a janela → refaz com contexto
//    reduzido; decodingFailure → 1 retry; rateLimited → espera 2s e refaz.
//  - O exemplo de código saiu do TopicSummary e virou uma chamada
//    DEDICADA (generateCodeExample), com orçamento de tokens próprio —
//    era o último campo do schema e o primeiro a ser truncado.
//  - Perguntas difíceis (MLX) agora são geradas em LOTE: um único prefill
//    do prompt para N rascunhos, em vez de um prefill por pergunta.
//

import Foundation
import FoundationModels

enum StudyGeneratorError: LocalizedError {
    case modelUnavailable(String)
    case generationFailed(step: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason):
            return reason
        case .generationFailed(let step, let underlying):
            return "Falha ao gerar \(step): \(Self.describe(underlying))"
        }
    }

    /// Traduz o erro real do Foundation Models numa mensagem diagnosticável
    /// em português — é isso que aparece na UI e nos logs.
    static func describe(_ error: Error) -> String {
        if let genError = error as? LanguageModelSession.GenerationError {
            switch genError {
            case .exceededContextWindowSize:
                return "o contexto enviado excedeu a janela do modelo (tente novamente — o app reduz o contexto automaticamente)."
            case .guardrailViolation:
                return "o pedido foi bloqueado pelos filtros de segurança do sistema."
            case .decodingFailure:
                return "a resposta não pôde ser decodificada no formato esperado (possível truncamento)."
            case .rateLimited:
                return "limite de requisições do sistema atingido — aguarde alguns segundos."
            case .assetsUnavailable:
                return "os recursos do modelo não estão disponíveis (Apple Intelligence ainda baixando ou desativado em Ajustes)."
            case .concurrentRequests:
                return "requisições simultâneas na mesma sessão do modelo."
            case .refusal:
                return "o modelo recusou o pedido."
            case .unsupportedLanguageOrLocale:
                return "idioma/região não suportado pelo modelo."
            case .unsupportedGuide:
                return "o schema de geração pedido não é suportado."
            default:
                return String(describing: genError)
            }
        }
        return error.localizedDescription
    }
}

@Observable
final class StudyGenerator {

    /// Índice RAG injetado — construído uma vez (ex: no início da tela)
    /// e reutilizado em todas as gerações.
    private let documentIndex: DocumentIndex

    init(documentIndex: DocumentIndex) {
        self.documentIndex = documentIndex
    }

    /// Recupera o contexto de documentação para um tópico uma única vez,
    /// para ser reutilizado em múltiplas chamadas de geração (resumo,
    /// lotes de quiz, análise de código) sem repetir a busca RAG.
    ///
    /// Plano V4 Fase 4: todo caminho de geração interno já sabe o NOME
    /// EXATO do tópico, então usa primeiro a busca determinística por
    /// igualdade de `chunk.topic` — zero chance de contaminação
    /// cross-topic. Só cai no hybridSearch (fuzzy) se o tópico não
    /// existir literalmente no dataset (defesa; não deveria acontecer,
    /// já que a home deriva os tópicos do próprio dataset).
    func retrieveContext(for topic: String, topK: Int = 3) async -> String {
        let exact = documentIndex.chunks(forExactTopic: topic)
        if !exact.isEmpty {
            return exact.prefix(topK).map(\.text).joined(separator: "\n\n")
        }
        print("⚠️ retrieveContext: nenhum chunk com topic exatamente '\(topic)' — caindo no hybridSearch (fuzzy).")
        return (try? await documentIndex.retrieveContext(for: topic, topK: topK)) ?? ""
    }

    /// Verifica se o modelo de sistema está disponível neste device.
    func checkAvailability() -> String {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return "Modelo disponível ✅"
        case .unavailable(let reason):
            return "Modelo indisponível: \(reason)"
        @unknown default:
            return "Status desconhecido"
        }
    }

    private func requireModel() throws -> SystemLanguageModel {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw StudyGeneratorError.modelUnavailable("Modelo indisponível neste device/simulador")
        }
        return model
    }

    // MARK: - Retry com degradação de contexto

    /// Reduz o contexto RAG pro primeiro chunk apenas (os chunks são
    /// separados por linha em branco em retrieveContext).
    private static func reduceContext(_ context: String) -> String {
        context.components(separatedBy: "\n\n").first ?? ""
    }

    /// Executa `attempt` e, se falhar com um erro conhecido do Foundation
    /// Models, aplica UMA estratégia de recuperação antes de desistir:
    /// - exceededContextWindowSize → refaz com contexto reduzido (e depois vazio)
    /// - decodingFailure → 1 retry simples (sessão nova, resultado não-determinístico)
    /// - rateLimited / concurrentRequests → espera 2s e refaz
    /// Qualquer falha final é embrulhada com a etapa + causa real.
    private func withDiagnostics<T>(
        step: String,
        context: String,
        attempt: (String) async throws -> T
    ) async throws -> T {
        do {
            return try await attempt(context)
        } catch {
            var lastError = error

            if let genError = error as? LanguageModelSession.GenerationError {
                switch genError {
                case .exceededContextWindowSize:
                    let reduced = Self.reduceContext(context)
                    print("⚠️ [\(step)] contexto excedeu a janela — retry com contexto reduzido (\(reduced.count)/\(context.count) chars).")
                    do {
                        return try await attempt(reduced)
                    } catch {
                        lastError = error
                        if !reduced.isEmpty, let recovered = try? await attempt("") {
                            print("⚠️ [\(step)] recuperado com contexto vazio.")
                            return recovered
                        }
                    }

                case .decodingFailure:
                    print("⚠️ [\(step)] decodingFailure — 1 retry.")
                    do { return try await attempt(context) } catch { lastError = error }

                case .rateLimited, .concurrentRequests:
                    print("⚠️ [\(step)] rate limited — aguardando 2s antes do retry.")
                    try? await Task.sleep(for: .seconds(2))
                    do { return try await attempt(context) } catch { lastError = error }

                default:
                    break
                }
            }

            print("❌ [\(step)] falhou: \(StudyGeneratorError.describe(lastError))")
            throw StudyGeneratorError.generationFailed(step: step, underlying: lastError)
        }
    }

    // MARK: - Resumo (sem código — ver generateCodeExample)

    /// Gera um resumo estruturado (resumo + pontos-chave) para um tópico de
    /// Swift, com grounding via RAG. O exemplo de código NÃO faz mais parte
    /// desta chamada — tem chamada e orçamento próprios em
    /// generateCodeExample, pra nunca mais ser truncado por competir com o
    /// resto do schema.
    func generateSummary(topic: String, context: String, priority: GenerationOrchestrator.Priority = .userBlocking) async throws -> TopicSummary {
        let model = try requireModel()

        let instructions = """
        Você é um assistente educacional especializado em Swift e nos frameworks da Apple.
        Responda sempre em português.
        Baseie-se PRINCIPALMENTE no contexto de documentação fornecido abaixo.
        Se o contexto não cobrir algum detalhe, seja conservador e não invente
        nomes de métodos, parâmetros ou comportamentos que não estão no contexto.
        """

        // Plano V3 4.2: toda a operação (incluindo os retries internos de
        // withDiagnostics) roda como UM job serializado na fila do FM —
        // nenhuma outra chamada ao Foundation Models entra no meio.
        return try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
            try await self.withDiagnostics(step: "resumo do tópico", context: context) { ctx in
                let session = LanguageModelSession(model: model, instructions: instructions)

                let prompt: String
                if ctx.isEmpty {
                    prompt = """
                    Tópico: \(topic)

                    Gere um resumo estruturado desse tópico de Swift para um desenvolvedor
                    iniciante/intermediário, incluindo pontos-chave.
                    """
                } else {
                    prompt = """
                    Tópico: \(topic)

                    Contexto da documentação oficial (use isso como base principal):
                    \(ctx)

                    Gere um resumo estruturado desse tópico de Swift para um desenvolvedor
                    iniciante/intermediário, incluindo pontos-chave.
                    """
                }

                // Resumo mais longo (180-280 palavras, Plano V5) + 3-5 pontos-chave
                // precisa de mais orçamento que os 500 tokens antigos (100-150 palavras).
                let options = GenerationOptions(maximumResponseTokens: 750)
                let response = try await session.respond(to: prompt, generating: TopicSummary.self, options: options)
                return response.content
            }
        }
    }

    // MARK: - Exemplo de código explicado (chamada dedicada)

    /// Plano V4 Fase 2 — passo a passo no mesmo padrão MLX→FM que já
    /// existe pra quiz difícil e análise de código: o MLX rascunha código +
    /// explicação em texto puro, e o Foundation Models só REFORMATA esse
    /// rascunho no schema ExplainedCodeExample. Se o MLX estiver
    /// indisponível ou qualquer etapa falhar, cai pro fluxo antigo (FM
    /// gerando do zero) — a criação do tópico nunca trava por causa disso.
    func generateCodeExample(topic: String, context: String, priority: GenerationOrchestrator.Priority = .userBlocking) async throws -> ExplainedCodeExample {
        do {
            try await MLXService.shared.loadModel()

            let mlxPrompt = """
            Você é um especialista em Swift. Escreva UM código Swift de 5-15 linhas, limpo e completo, que ilustre o conceito principal de '\(topic)', e explique-o passo a passo em texto puro.

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

            let draft = try await GenerationOrchestrator.shared.schedule(engine: .mlx, priority: priority) {
                try await MLXService.shared.generateQuestionDraft(
                    systemPrompt: "Você é um especialista em Swift. Gere um código de exemplo curto e uma explicação passo a passo, em texto puro, usando apenas APIs reais.",
                    promptContext: mlxPrompt
                )
            }
            print("🔵 [exemplo de código] rascunho MLX recebido (\(draft.count) chars) — formatando via Foundation Models.")
            return try await formatCodeExample(draft: draft, topic: topic, context: context, priority: priority)
        } catch {
            print("⚠️ [exemplo de código] fluxo MLX→FM falhou (\(StudyGeneratorError.describe(error))) — fallback: Foundation Models gerando do zero.")
            return try await generateCodeExampleFromScratch(topic: topic, context: context, priority: priority)
        }
    }

    /// Reformata o rascunho do MLX (código + passo a passo em texto puro)
    /// no schema ExplainedCodeExample via Foundation Models, reaproveitando
    /// o `looksTruncated` + retry curto que já existia pro exemplo de código.
    ///
    /// Hotfix pós-teste (2ª rodada): a 1ª versão desse método já tentava
    /// corrigir o rascunho contra o contexto RAG numa ÚNICA passada, mas
    /// pedir pra um modelo pequeno criticar tecnicamente E reformatar pro
    /// schema estruturado ao mesmo tempo sobrecarrega ele — testes reais
    /// continuaram mostrando erros de tipo/sintaxe reais passando batido
    /// (ex.: `.navigationDestination(for: 1)` em vez de `for: Int.self`,
    /// `ContentView(selection:)` com um parâmetro que não existe). Agora
    /// vira DUAS passadas: `critiqueCodeDraft` aponta os erros técnicos em
    /// texto livre (tarefa mais estreita, mais fácil pro modelo acertar) e
    /// só DEPOIS `formatCodeExample` reformata pro schema aplicando essa
    /// crítica — o mesmo padrão "critique, depois corrija" que funciona
    /// bem em revisão de código por humanos.
    private func formatCodeExample(draft: String, topic: String, context: String, priority: GenerationOrchestrator.Priority) async throws -> ExplainedCodeExample {
        let cleanDraft = Self.sanitizeDraft(draft)
        guard !cleanDraft.isEmpty else {
            throw StudyGeneratorError.generationFailed(
                step: "formatação do exemplo de código",
                underlying: NSError(domain: "StudyGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "rascunho MLX vazio"])
            )
        }
        let model = try requireModel()

        let critique = try await critiqueCodeDraft(draft: cleanDraft, topic: topic, context: context, priority: priority)
        print("🔵 [exemplo de código] crítica técnica: \(critique.prefix(200))\(critique.count > 200 ? "…" : "")")

        let instructions = """
        Você recebe um rascunho com um código Swift e sua explicação passo a passo, gerado por outro modelo,
        e uma REVISÃO TÉCNICA desse rascunho feita por um segundo revisor, apontando erros reais (ou dizendo
        que não há erros).
        Sua tarefa é reformatar o rascunho num exemplo de código explicado, aplicando TODAS as correções da
        revisão técnica — se a revisão apontou um erro, o código final NÃO PODE conter esse erro. Se a revisão
        disse que não há erros, apenas reformate normalmente.
        Use o contexto de documentação oficial fornecido como fonte de verdade adicional: qualquer API que
        não exista ou contradiga o contexto também deve ser corrigida, mesmo que a revisão não tenha pego.
        Nunca invente um nome de método, tipo ou modificador que você não tem certeza que existe.
        Preserve a intenção didática do rascunho (o conceito que ele tenta ilustrar), mas o resultado final
        precisa ser Swift real e compilável.

        \(Self.commonCodeMistakesChecklist)

        Responda sempre em português.
        """

        return try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
            try await self.withDiagnostics(step: "formatação do exemplo de código", context: context) { ctx in
                let session = LanguageModelSession(model: model, instructions: instructions)

                let prompt = """
                Contexto da documentação oficial (fonte de verdade — corrija o rascunho por isso):
                \(ctx.isEmpty ? "Conhecimento geral de Swift, com cautela." : ctx)

                Rascunho gerado por outro modelo sobre '\(topic)':
                \(cleanDraft)

                Revisão técnica do rascunho acima (aplique TODAS as correções apontadas aqui):
                \(critique)

                Reformate esse rascunho no exemplo de código explicado, com o walkthrough passo a passo,
                já com as correções da revisão aplicadas.
                """

                // Plano V5, hotfix pós-teste: 1100 tokens não bastava pro código
                // + passo a passo de 3-5 etapas em português (mais verboso que
                // inglês em tokens) — visto ao vivo o código cortado mesmo
                // DEPOIS do retry "8 linhas". Subiu o orçamento e o retry agora
                // também pede um walkthrough mais curto, não só código curto,
                // já que os dois competem pelo mesmo orçamento de tokens.
                let options = GenerationOptions(maximumResponseTokens: 1600)
                let response = try await session.respond(to: prompt, generating: ExplainedCodeExample.self, options: options)
                let example = response.content

                if Self.looksTruncated(example.code) {
                    print("⚠️ [formatação do exemplo de código] código parece truncado — retry pedindo versão mais curta.")
                    let retrySession = LanguageModelSession(model: model, instructions: instructions)
                    let retryPrompt = prompt + "\n\nIMPORTANTE: mantenha NO MÁXIMO 8 linhas de código E NO MÁXIMO 3 passos curtos no walkthrough."
                    let retry = try await retrySession.respond(to: retryPrompt, generating: ExplainedCodeExample.self, options: options)
                    if !Self.looksTruncated(retry.content.code) {
                        return retry.content
                    }
                }
                return example
            }
        }
    }

    /// Passada 1 do hotfix de 2 passadas (ver `formatCodeExample`): pede pra
    /// Foundation Models APENAS criticar o rascunho — sem formatar, sem
    /// gerar código novo — comparando contra o contexto oficial. Tarefa
    /// mais estreita que "reformatar + corrigir" ao mesmo tempo, então o
    /// modelo tende a pegar erros de tipo/API mais concretos (ex.:
    /// `.navigationDestination(for:)` esperando um `Tipo.self`, não um
    /// valor). Resposta em texto livre, sem schema (`respond(to:options:)`,
    /// sem `generating:`) — mais barato e não trava numa estrutura rígida
    /// pra uma lista curta de apontamentos.
    private func critiqueCodeDraft(draft: String, topic: String, context: String, priority: GenerationOrchestrator.Priority) async throws -> String {
        let model = try requireModel()

        let instructions = """
        Você é um revisor de código Swift rigoroso. Sua ÚNICA tarefa é apontar erros técnicos REAIS
        no rascunho de código abaixo — não reescreva o código, só liste os problemas.
        Procure especificamente por: APIs que não existem, uso incorreto de uma API real (ex.: passar um
        valor onde a API espera um TIPO, como em navigationDestination(for:), que exige Tipo.self e não
        um valor literal; ou um parâmetro de inicializador que o tipo não declara), métodos/modificadores
        deprecados, e qualquer contradição com o contexto de documentação oficial fornecido.

        \(Self.commonCodeMistakesChecklist)

        Se não encontrar nenhum erro real, responda exatamente "OK - sem erros".
        Seja específico (cite o trecho exato) e conciso — no máximo 5 pontos.
        Responda sempre em português.
        """

        return try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
            try await self.withDiagnostics(step: "crítica do exemplo de código", context: context) { ctx in
                let session = LanguageModelSession(model: model, instructions: instructions)

                let prompt = """
                Contexto da documentação oficial:
                \(ctx.isEmpty ? "Conhecimento geral de Swift, com cautela." : ctx)

                Rascunho de código Swift sobre '\(topic)':
                \(draft)

                Liste os erros técnicos reais encontrados no rascunho acima (ou "OK - sem erros").
                """

                let options = GenerationOptions(maximumResponseTokens: 350)
                let response = try await session.respond(to: prompt, options: options)
                return response.content
            }
        }
    }

    /// Fluxo antigo (pré-V4): Foundation Models gera código + walkthrough do
    /// zero, numa chamada dedicada. Mantido como FALLBACK do caminho MLX→FM.
    private func generateCodeExampleFromScratch(topic: String, context: String, priority: GenerationOrchestrator.Priority = .userBlocking) async throws -> ExplainedCodeExample {
        let model = try requireModel()

        let instructions = """
        Você é um assistente educacional especializado em Swift e nos frameworks da Apple.
        Responda sempre em português.
        Baseie-se PRINCIPALMENTE no contexto de documentação fornecido.
        Gere um exemplo de código Swift completo e compilável, e explique-o passo a passo,
        como se estivesse ensinando alguém que vê aquilo pela primeira vez.
        Use nomes de variáveis e funções descritivos.
        """

        return try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
            try await self.withDiagnostics(step: "exemplo de código", context: context) { ctx in
                let session = LanguageModelSession(model: model, instructions: instructions)

                let prompt = """
                Tópico: \(topic)

                Contexto da documentação oficial:
                \(ctx.isEmpty ? "Conhecimento geral de Swift, com cautela." : ctx)

                Gere UM exemplo de código Swift (5-15 linhas, completo, sem cortes) que
                ilustre o conceito principal do tópico, com a explicação passo a passo.
                """

                // Orçamento dedicado só pro exemplo — nada compete com ele.
                // Precisa ser generoso: o walkthrough REPETE os trechos do código
                // (snippet + explicação por passo), então a resposta é ~2x o
                // tamanho do código em si.
                // Plano V5: mesmo orçamento maior e retry com walkthrough mais
                // curto do formatCodeExample — ver comentário lá.
                let options = GenerationOptions(maximumResponseTokens: 1600)
                let response = try await session.respond(to: prompt, generating: ExplainedCodeExample.self, options: options)
                let example = response.content

                // Detecção de truncamento: se o código parece incompleto
                // (delimitadores desbalanceados / termina "no meio"), tenta UMA
                // vez com um exemplo mais curto antes de aceitar.
                if Self.looksTruncated(example.code) {
                    print("⚠️ [exemplo de código] código parece truncado — retry pedindo exemplo mais curto.")
                    let retrySession = LanguageModelSession(model: model, instructions: instructions)
                    let retryPrompt = prompt + "\n\nIMPORTANTE: o exemplo deve ter NO MÁXIMO 8 linhas de código E NO MÁXIMO 3 passos curtos no walkthrough."
                    let retry = try await retrySession.respond(to: retryPrompt, generating: ExplainedCodeExample.self, options: options)
                    if !Self.looksTruncated(retry.content.code) {
                        return retry.content
                    }
                }
                return example
            }
        }
    }

    /// Heurística barata de truncamento: chaves/parênteses desbalanceados
    /// ou última linha terminando em token que nunca fecha um programa Swift.
    static func looksTruncated(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        var braces = 0, parens = 0, brackets = 0
        var inString = false
        var previous: Character = " "
        for char in trimmed {
            if char == "\"" && previous != "\\" { inString.toggle() }
            if !inString {
                switch char {
                case "{": braces += 1
                case "}": braces -= 1
                case "(": parens += 1
                case ")": parens -= 1
                case "[": brackets += 1
                case "]": brackets -= 1
                default: break
                }
            }
            previous = char
        }
        if braces != 0 || parens != 0 || brackets != 0 { return true }

        let badEndings = [",", "{", "(", "[", "=", "+", "-", "*", "/", ":", "&&", "||", "->", "."]
        if let lastLine = trimmed.components(separatedBy: .newlines).last?.trimmingCharacters(in: .whitespaces),
           badEndings.contains(where: { lastLine.hasSuffix($0) }) {
            return true
        }
        return false
    }

    // MARK: - Quiz

    /// Gera perguntas de quiz. Se for Fácil/Média usa Foundation Model; se for Difícil puxa o MLX!
    func generateQuizBatch(topic: String, context: String, difficulty: Difficulty, count: Int, priority: GenerationOrchestrator.Priority = .userBlocking) async throws -> [QuizQuestion] {

        // 🔀 SE FOR DIFÍCIL: MLX gera os rascunhos EM LOTE (um único prefill
        // pra N perguntas), e o Foundation Models formata cada rascunho no
        // schema QuizQuestion com alternativas reais.
        if difficulty == .hard {
            try await MLXService.shared.loadModel()

            // Plano V4 Fase 4: contexto via busca exata por tópico (nunca fuzzy).
            // Plano V5: topK 3 — dataset atual tem no máximo 3 chunks por tópico,
            // então isso sempre pega o tópico inteiro (sem inconsistência de
            // quanto contexto cada chamada usa).
            let ragContext = await retrieveContext(for: topic, topK: 3)

            let mlxPrompt = """
            Você é um especialista em Swift. Crie \(count) perguntas técnicas de nível avançado sobre '\(topic)', distintas entre si.
            Contexto oficial: \(ragContext)

            Formato de CADA pergunta (texto puro, sem markdown), separadas pela linha \(MLXService.itemSeparator):
            PERGUNTA: <a pergunta>
            RESPOSTA CORRETA: <explicação do comportamento/resposta certa, 1-2 frases>
            POR QUE OUTRAS RESPOSTAS PARECEM CERTAS MAS NÃO SÃO: <1-2 frases de erros comuns/conceitos que confundem>
            """

            // Plano V3 4.2: chamadas de geração no MLX passam pela fila
            // própria do motor MLX (paralela à do FM, nunca a mesma fila).
            let drafts = try await GenerationOrchestrator.shared.schedule(engine: .mlx, priority: priority) {
                try await MLXService.shared.generateQuestionDrafts(
                    systemPrompt: "Você é um especialista em Swift. Gere perguntas técnicas difíceis sobre conceitos da linguagem, em texto puro.",
                    promptContext: mlxPrompt,
                    count: count
                )
            }

            var results: [QuizQuestion] = []
            for draft in drafts.prefix(count) {
                let question = await formatHardQuestion(draft: draft, topic: topic, difficulty: difficulty, priority: priority)
                results.append(question)
            }

            // Se o lote veio com menos itens que o pedido (split falhou ou o
            // modelo gerou menos), completa um a um — nunca devolve menos.
            while results.count < count {
                let single = try await GenerationOrchestrator.shared.schedule(engine: .mlx, priority: priority) {
                    try await MLXService.shared.generateQuestionDraft(
                        systemPrompt: "Você é um especialista em Swift. Gere uma pergunta técnica difícil sobre um conceito da linguagem, em texto puro.",
                        promptContext: mlxPrompt.replacingOccurrences(of: "Crie \(count) perguntas técnicas", with: "Crie UMA pergunta técnica")
                    )
                }
                let question = await formatHardQuestion(draft: single, topic: topic, difficulty: difficulty, priority: priority)
                results.append(question)
            }
            return results
        }

        // 🍏 Usar o Foundation Model para Fácil e Média
        let model = try requireModel()

        let instructions = """
        Você é um assistente educacional especializado em Swift e nos frameworks da Apple.
        Responda sempre em português.
        Baseie-se PRINCIPALMENTE no contexto de documentação fornecido.
        Gere perguntas de múltipla escolha com exatamente 4 alternativas, sendo apenas uma correta.
        As alternativas NUNCA devem ter prefixo de letra ou número (nunca "A)", "B.", "1)" etc.) —
        escreva só o texto puro de cada alternativa, a interface já numera sozinha.
        """

        let fewShot = """
        Exemplo de pergunta FÁCIL:
        Pergunta: "O que a palavra-chave `if let` faz ao trabalhar com um Optional?"
        Alternativas: ["Desempacota o valor se ele não for nil", "Força o desempacotamento", "Converte em array", "Retorna nil"]
        Correta (índice): 0
        """

        let difficultyLabel = (difficulty == .easy) ? "FÁCIL" : "MÉDIA"

        return try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
            try await self.withDiagnostics(step: "quiz \(difficultyLabel.lowercased())", context: context) { ctx in
                let session = LanguageModelSession(model: model, instructions: instructions)

                let prompt = """
                Tópico: \(topic)
                Contexto da documentação: \(ctx.isEmpty ? "Conhecimento geral sobre Swift." : ctx)
                \(fewShot)

                Gere exatamente \(count) perguntas de quiz NOVAS de dificuldade \(difficultyLabel).
                """

                // ~220 tokens por pergunta (enunciado + 4 alternativas +
                // explicação, em português). O teto fixo de 600 era a causa dos
                // decodingFailure: 5-6 perguntas não cabiam e a resposta chegava
                // truncada, quebrando a decodificação do schema.
                let options = GenerationOptions(maximumResponseTokens: 220 * count + 150)
                let response = try await session.respond(to: prompt, generating: QuizQuestionBatch.self, options: options)
                return response.content.questions
            }
        }
    }

    /// Checklist de erros concretos vistos em teste real, reaproveitado nas
    /// instruções de crítica/formatação de código (exemplo E análise) —
    /// pedir "corrija erros" de forma genérica não pegou casos como
    /// `Button("título")` sem action (não compila) ou walkthrough
    /// descrevendo uma mudança que não foi de fato aplicada ao código.
    private static let commonCodeMistakesChecklist = """
    Erros comuns pra verificar item a item antes de aceitar o código:
    - Button, Toggle, NavigationLink e afins que recebem uma ação/closure NUNCA podem ficar sem ela —
      `Button("Título")` sozinho NÃO COMPILA, precisa de `action:` ou closure à direita.
    - `.navigationDestination(for:)` espera um TIPO (ex.: `Int.self`), nunca um valor literal.
    - `NavigationPath`, `Bool`, `Int`, `String` e outros tipos de VALOR (não-classe) usam `@State`, nunca
      `@StateObject` — `@StateObject` só serve pra tipos que conformam `ObservableObject`/`@Observable`.
    - Todo parâmetro de inicializador usado precisa existir de verdade no tipo (não invente).
    - O walkthrough/explicação NUNCA pode descrever uma mudança que não está de fato no código final —
      se a explicação diz que algo foi ajustado, o código tem que refletir exatamente isso.
    """

    /// Limpa marcação de código/JSON que o MLX às vezes deixa no rascunho.
    private static func sanitizeDraft(_ draft: String) -> String {
        draft
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```swift", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Formata UM rascunho do MLX numa QuizQuestion via Foundation Models.
    /// Nunca lança: se a formatação falhar, devolve o fallback genérico.
    private func formatHardQuestion(draft: String, topic: String, difficulty: Difficulty, priority: GenerationOrchestrator.Priority) async -> QuizQuestion {
        let cleanDraft = Self.sanitizeDraft(draft)

        // ⚠️ Fallback genérico — usado APENAS como último recurso, se o
        // Foundation Models estiver indisponível ou falhar ao formatar.
        let fallbackQuestion = QuizQuestion(
            difficulty: difficulty,
            question: cleanDraft.isEmpty ? "Qual é o comportamento esperado ao trabalhar com concorrência avançada em \(topic)?" : cleanDraft,
            options: [
                "Executa com sucesso garantindo o isolamento de estado do ator",
                "Gera um erro de compilação por violação de regras de Concurrency",
                "Provoca uma condição de corrida (data race) em tempo de execução",
                "Causa um vazamento de memória devido a referência circular"
            ],
            correctOptionIndex: 0,
            explanation: "Pergunta avançada gerada pelo MLX com base na documentação oficial de \(topic)."
        )

        let model = SystemLanguageModel.default
        guard !cleanDraft.isEmpty, case .available = model.availability else {
            print("⚠️ Rascunho vazio ou Foundation Models indisponível — usando fallback genérico")
            return fallbackQuestion
        }

        let formatterInstructions = """
        Você recebe um rascunho de pergunta técnica de Swift, já com a resposta correta indicada.
        Sua tarefa é reformatar isso em uma pergunta de múltipla escolha com exatamente 4 alternativas plausíveis,
        sendo apenas uma correta — baseada fielmente no rascunho fornecido, sem inventar informação nova.
        As alternativas NUNCA devem ter prefixo de letra ou número (nunca "A)", "B.", "1)" etc., mesmo que o
        rascunho tenha algo parecido) — escreva só o texto puro de cada alternativa.
        Responda sempre em português.
        """

        let formatterPrompt = """
        Rascunho gerado por outro modelo:
        \(cleanDraft)

        Reformate esse rascunho em uma pergunta de múltipla escolha de dificuldade \(difficulty.rawValue),
        com 4 alternativas plausíveis (não óbvias) e a alternativa correta identificada.
        """

        // Até 3 tentativas com pausa: mantido como rede de segurança pra
        // falhas reais do modelo (guardrail, decoding), não mais pra
        // contenção entre FM/MLX — isso agora é responsabilidade da fila
        // serial do GenerationOrchestrator (Plano V3 4.2), que garante uma
        // única chamada FM em voo por vez.
        for attempt in 1...3 {
            do {
                let formatted = try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
                    let session = LanguageModelSession(model: model, instructions: formatterInstructions)
                    return try await session.respond(to: formatterPrompt, generating: QuizQuestion.self)
                }
                return formatted.content
            } catch {
                print("⚠️ Formatação do rascunho MLX falhou (tentativa \(attempt)/3): \(StudyGeneratorError.describe(error))")
                if attempt < 3 { try? await Task.sleep(for: .seconds(2)) }
            }
        }
        return fallbackQuestion
    }

    // MARK: - Análise de código

    /// Gera um lote de perguntas de análise de código (rascunhos MLX em lote
    /// + formatação estruturada via Foundation Models).
    func generateCodeAnalysisBatch(topic: String, context: String, count: Int, priority: GenerationOrchestrator.Priority = .userBlocking) async throws -> [CodeAnalysisQuestion] {
        try await MLXService.shared.loadModel()

        // Plano V4 Fase 4: contexto via busca exata por tópico (nunca fuzzy).
        // Plano V5: topK 3 — ver comentário equivalente em generateQuizBatch.
        let ragContext = await retrieveContext(for: topic, topK: 3)

        let mlxPrompt = """
        Você é um especialista em Swift. Escreva \(count) trechos de código Swift limpos, de 6 a 10 linhas cada, sobre '\(topic)', e explique o comportamento de cada um. Os trechos devem ser distintos entre si.

        [Contexto RAG]:
        \(ragContext.isEmpty ? "Conhecimento geral sobre Swift e Apple Frameworks." : ragContext)

        Formato de CADA item (texto puro, sem markdown, sem JSON), separados pela linha \(MLXService.itemSeparator):
        CODIGO:
        <o trecho de código Swift>
        COMPORTAMENTO ESPERADO: <o que o código faz / resultado ao executar, 1-2 frases>
        POR QUE OUTRAS RESPOSTAS PARECEM CERTAS MAS NÃO SÃO: <1-2 frases de erros comuns/conceitos que confundem>
        """

        do {
            let drafts = try await GenerationOrchestrator.shared.schedule(engine: .mlx, priority: priority) {
                try await MLXService.shared.generateQuestionDrafts(
                    systemPrompt: "Você é um especialista em Swift. Gere trechos de código e perguntas de análise sobre seus comportamentos, em texto puro.",
                    promptContext: mlxPrompt,
                    count: count
                )
            }

            var results: [CodeAnalysisQuestion] = []
            for draft in drafts.prefix(count) {
                results.append(await formatCodeAnalysisQuestion(draft: draft, topic: topic, context: ragContext, priority: priority))
            }

            while results.count < count {
                let single = try await GenerationOrchestrator.shared.schedule(engine: .mlx, priority: priority) {
                    try await MLXService.shared.generateQuestionDraft(
                        systemPrompt: "Você é um especialista em Swift. Gere um trecho de código e uma pergunta de análise sobre seu comportamento, em texto puro.",
                        promptContext: mlxPrompt.replacingOccurrences(of: "Escreva \(count) trechos de código Swift limpos", with: "Escreva UM trecho de código Swift limpo")
                    )
                }
                results.append(await formatCodeAnalysisQuestion(draft: single, topic: topic, context: ragContext, priority: priority))
            }
            return results
        } catch {
            throw StudyGeneratorError.generationFailed(step: "análise de código (MLX)", underlying: error)
        }
    }

    /// Formata UM rascunho de análise de código do MLX via Foundation Models.
    /// Nunca lança: se a formatação falhar, devolve o fallback genérico.
    ///
    /// Hotfix pós-teste: usava a mesma instrução "preservar fielmente, sem
    /// inventar informação nova" que causava alucinação sem correção no
    /// exemplo de código (ver `formatCodeExample`) — mesmo bug, caminho
    /// diferente, e evidenciado em teste real por uma sessão de análise de
    /// código com 1/6 de acerto. Agora passa pela mesma crítica de 2
    /// passadas (`critiqueCodeDraft`, reaproveitado) antes de formatar.
    private func formatCodeAnalysisQuestion(draft: String, topic: String, context: String, priority: GenerationOrchestrator.Priority) async -> CodeAnalysisQuestion {
        let cleanDraft = Self.sanitizeDraft(draft)

        // Tenta isolar só o código pro snippet do fallback
        var fallbackSnippet = cleanDraft
            .components(separatedBy: "COMPORTAMENTO ESPERADO:").first?
            .replacingOccurrences(of: "CODIGO:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if fallbackSnippet.isEmpty {
            fallbackSnippet = """
            import SwiftUI

            struct \(topic.replacingOccurrences(of: " ", with: ""))DemoView: View {
                @State private var isActive: Bool = false

                var body: some View {
                    Text("Demonstração de \(topic)")
                }
            }
            """
        }

        // ⚠️ Fallback genérico — usado APENAS como último recurso, se o
        // Foundation Models estiver indisponível ou falhar ao formatar.
        let fallbackQuestion = CodeAnalysisQuestion(
            codeSnippet: fallbackSnippet,
            question: "Analisando o código Swift acima sobre '\(topic)', qual é o resultado ou comportamento esperado?",
            options: [
                "Executa normalmente e produz o resultado esperado sem erros",
                "Ocorre um erro de compilação devido a incompatibilidade de tipos ou sintaxe",
                "Provoca um vazamento de memória (retain cycle) com closures ou instâncias",
                "Causa uma exceção / erro em tempo de execução (fatal error)",
                "O estado permanece inalterado por se tratar de um tipo de valor imutável"
            ],
            correctOptionIndex: 0,
            explanation: "Análise de código gerada localmente pelo MLX com suporte RAG da documentação oficial de \(topic)."
        )

        let model = SystemLanguageModel.default
        guard !cleanDraft.isEmpty, case .available = model.availability else {
            print("⚠️ Rascunho vazio ou Foundation Models indisponível — usando fallback genérico")
            return fallbackQuestion
        }

        let critique = (try? await critiqueCodeDraft(draft: cleanDraft, topic: topic, context: context, priority: priority)) ?? "OK - sem erros"
        print("🔵 [análise de código] crítica técnica: \(critique.prefix(200))\(critique.count > 200 ? "…" : "")")

        let formatterInstructions = """
        Você recebe um rascunho com um trecho de código Swift e a explicação do comportamento esperado dele,
        além de uma REVISÃO TÉCNICA feita por um segundo revisor, apontando erros reais (ou dizendo que não há).
        Sua tarefa é reformatar isso em uma pergunta de análise de código com exatamente 5 alternativas plausíveis,
        sendo apenas uma correta.
        Se a revisão técnica apontou um erro real no código (API que não existe, sintaxe inválida, algo que não
        compila sem intenção pedagógica), CORRIJA o código no campo codeSnippet antes de formatar — não preserve
        um erro real só por fidelidade ao rascunho. Se a revisão disse que não há erros, preserve o código como
        está, sem a marcação 'CODIGO:'.
        A alternativa correta e as explicações têm que corresponder exatamente ao comportamento real do código
        já corrigido, não ao rascunho original.
        As alternativas NUNCA devem ter prefixo de letra ou número (nunca "A)", "B.", "1)" etc.) — escreva
        só o texto puro de cada alternativa.

        \(Self.commonCodeMistakesChecklist)

        Responda sempre em português.
        """

        let formatterPrompt = """
        Contexto da documentação oficial:
        \(context.isEmpty ? "Conhecimento geral de Swift, com cautela." : context)

        Rascunho gerado por outro modelo sobre '\(topic)':
        \(cleanDraft)

        Revisão técnica do rascunho acima (aplique as correções apontadas, se houver):
        \(critique)

        Reformate esse rascunho em uma pergunta de análise de código sobre '\(topic)',
        com 5 alternativas plausíveis (não óbvias) e a alternativa correta identificada.
        """

        // Mesmo esquema de retry do formatHardQuestion (ver comentário lá) —
        // rede de segurança pra falhas reais do modelo, já não pra
        // contenção FM/MLX, que a fila do GenerationOrchestrator elimina.
        //
        // Plano V5, hotfix pós-teste: faltava aqui o MESMO
        // looksTruncated + retry-mais-curto que já existia em
        // formatCodeExample — visto ao vivo um codeSnippet cortado no meio
        // (terminando em "NavigationLink(" sem fechar) passando batido.
        // maximumResponseTokens também estava usando o default implícito
        // (sem opções), agora fixado explicitamente com folga.
        for attempt in 1...3 {
            do {
                let options = GenerationOptions(maximumResponseTokens: 900)
                let formatted = try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
                    let session = LanguageModelSession(model: model, instructions: formatterInstructions)
                    return try await session.respond(to: formatterPrompt, generating: CodeAnalysisQuestion.self, options: options)
                }
                if Self.looksTruncated(formatted.content.codeSnippet) {
                    print("⚠️ [análise de código] codeSnippet parece truncado — retry pedindo versão mais curta.")
                    let retrySession = LanguageModelSession(model: model, instructions: formatterInstructions)
                    let retryPrompt = formatterPrompt + "\n\nIMPORTANTE: mantenha o codeSnippet com NO MÁXIMO 8 linhas de código."
                    let retry = try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
                        try await retrySession.respond(to: retryPrompt, generating: CodeAnalysisQuestion.self, options: options)
                    }
                    if !Self.looksTruncated(retry.content.codeSnippet) {
                        return retry.content
                    }
                }
                return formatted.content
            } catch {
                print("⚠️ Formatação do rascunho MLX falhou (tentativa \(attempt)/3): \(StudyGeneratorError.describe(error))")
                if attempt < 3 { try? await Task.sleep(for: .seconds(2)) }
            }
        }
        return fallbackQuestion
    }

    // MARK: - Feedback

    /// Gera o feedback de fim de sessão. `validTopics` (Plano V3 2.5) é a
    /// lista de tópicos que realmente existem no dataset — sem ela, o
    /// modelo às vezes recomenda um `recommendedNextTopic` que não existe
    /// em lugar nenhum do app, um beco sem saída pro usuário.
    func generateFeedback(topic: String, performanceSummary: String, validTopics: [String], priority: GenerationOrchestrator.Priority = .userBlocking) async throws -> StudyFeedback {
        let model = try requireModel()

        let instructions = """
        Você é um mentor educacional especializado em Swift e nos frameworks da Apple.
        Responda sempre em português.
        Dê um feedback específico e construtivo baseado apenas no desempenho relatado.
        """

        return try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
            try await self.withDiagnostics(step: "feedback da sessão", context: "") { _ in
                let session = LanguageModelSession(model: model, instructions: instructions)

                let topicsList = validTopics.isEmpty ? "" : validTopics.joined(separator: ", ")
                let prompt = """
                Tópico estudado: \(topic)
                Desempenho do usuário nesta sessão: \(performanceSummary)
                \(topicsList.isEmpty ? "" : "Para recommendedNextTopic, recomende OBRIGATORIAMENTE um destes tópicos (copie o nome exatamente como está aqui), o que fizer mais sentido dado os erros cometidos: \(topicsList)")
                """

                let options = GenerationOptions(maximumResponseTokens: 600)
                let response = try await session.respond(to: prompt, generating: StudyFeedback.self, options: options)
                return response.content
            }
        }
    }
}
