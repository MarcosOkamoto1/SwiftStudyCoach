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
//  PLAN_06 — o exemplo de código SAIU do caminho síncrono do MLX:
//  `generateCodeExample` (MLX→crítica→formatação) virou duas funções —
//  `generateCodeExampleFM` (FM-only, síncrona, caminho principal da Fase 1)
//  e `upgradeCodeExampleViaMLX` (background, stub até PLAN_07). O pipeline
//  MLX original ficou PRESERVADO em `legacyGenerateCodeExampleViaMLX`,
//  dormente, como base do PLAN_07 e caminho de rollback.
//
//  PLAN_07 — `upgradeCodeExampleViaMLX` deixou de ser stub: roda o MESMO
//  pipeline MLX→crítica→formatação, agora inteiramente em background
//  (Estratégia D, SOLUTIONS_PLAN.md §5.2 passos 4-8). A parte de rascunho
//  MLX, que era literal dentro de `legacyGenerateCodeExampleViaMLX`, foi
//  extraída para `mlxCodeExampleDraft` e é COMPARTILHADA pelos dois — o
//  prompt continua byte a byte o mesmo, e o legado segue dormente e
//  intacto como caminho de rollback. A diferença de comportamento entre os
//  dois é só o tratamento de falha: o legado cai pro FM-only (fazia
//  sentido quando ele ERA o caminho principal), o upgrade devolve `nil`
//  (regenerar FM-only seria refazer exatamente o que a Fase 1 já
//  persistiu).
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
    ///
    /// PLAN_04: o caminho exato agora usa `DocumentIndex.rawChunks(forExactTopic:)`
    /// — síncrono, direto no dataset estático, SEM depender de `ensureReady()`
    /// (nem do índice de embeddings de forma alguma). Isso desacopla a
    /// abertura de tela do build do índice para o caso comum (tópico exato).
    /// `ensureReady()` só é aguardado no fallback fuzzy abaixo, que de fato
    /// precisa dos embeddings prontos.
    /// PLAN_11 — bloco de contexto RAG compartilhado, IDÊNTICO nas 3 chamadas
    /// MLX de um mesmo tópico (exemplo de código, quiz difícil, análise de
    /// código).
    ///
    /// Duas propriedades importam aqui, e as duas são sobre o cache de
    /// prefixo:
    ///
    /// 1. **Vem primeiro no `promptContext`.** O prefixo reaproveitável é,
    ///    por definição, um prefixo — o cache só cobre tokens até o ponto em
    ///    que os prompts divergem. Com a instrução da tarefa na frente (como
    ///    era antes), a divergência acontecia na PRIMEIRA linha e não sobrava
    ///    prefixo nenhum além do system prompt. Com o contexto na frente, o
    ///    trecho comum passa a ser `system prompt + todo o contexto RAG`, que
    ///    é justamente a parte longa.
    /// 2. **É montado por uma função só.** Se cada chamada montasse o próprio
    ///    cabeçalho, uma vírgula de diferença cortaria o prefixo comum ali.
    ///    Centralizar é o que impede a otimização de se desfazer sozinha na
    ///    próxima edição de prompt.
    ///
    /// O `topic` entra no bloco de propósito: é constante entre as 3 chamadas
    /// do mesmo tópico (não atrapalha o cache) e mantém o prompt legível.
    static func mlxContextBlock(topic: String, context: String) -> String {
        """
        [Contexto oficial sobre '\(topic)']:
        \(context.isEmpty ? "Conhecimento geral sobre Swift e Apple Frameworks." : context)
        """
    }

    func retrieveContext(for topic: String, topK: Int = 3) async -> String {
        let exact = DocumentIndex.rawChunks(forExactTopic: topic)
        if !exact.isEmpty {
            return exact.prefix(topK).map(\.text).joined(separator: "\n\n")
        }
        print("⚠️ retrieveContext: nenhum chunk com topic exatamente '\(topic)' — caindo no hybridSearch (fuzzy).")
        try? await documentIndex.ensureReady()
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

    // MARK: - Instrumentação (PLAN_00)

    /// Cronômetro em torno de UMA chamada ao Foundation Models, no mesmo
    /// padrão de `TopicRepository.timed` — mede o tempo total e alimenta a
    /// `GenerationMetricsStore`, além de manter o `print` de diagnóstico já
    /// usado no resto do projeto. `inputTokenCount`/`outputTokenCount`
    /// ficam `nil`: a API pública do `FoundationModels` (framework fechado)
    /// não expõe contagem de tokens nesta versão — `Needs runtime
    /// measurement` (ver PLAN_00, SOLUTIONS_PLAN.md §10.2).
    private static func timed<T>(
        _ name: String,
        engine: GenerationMetrics.Engine,
        taskType: GenerationMetrics.TaskType,
        topic: String,
        ragContextChars: Int = 0,
        ragChunkCount: Int = 0,
        batchSize: Int = 1,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let start = Date()
        defer {
            let elapsedMs = Date().timeIntervalSince(start) * 1000
            print("⏱️ [\(name)] \(String(format: "%.1f", elapsedMs / 1000))s")
            Task {
                await GenerationMetricsStore.shared.record(
                    GenerationMetrics(
                        engine: engine,
                        taskType: taskType,
                        topic: topic,
                        modelID: engine == .mlx ? MLXService.modelID : "system",
                        totalTimeMs: elapsedMs,
                        ragContextChars: ragContextChars,
                        ragChunkCount: ragChunkCount,
                        batchSize: batchSize
                    )
                )
            }
        }
        return try await body()
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
        return try await Self.timed("resumo do tópico (FM)", engine: .foundationModels, taskType: .summary, topic: topic, ragContextChars: context.count) {
            try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
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
    }

    // MARK: - Exemplo de código explicado (chamada dedicada)

    /// PLAN_06/PLAN_07 — UPGRADE do exemplo de código via MLX, rodado só em
    /// BACKGROUND (Fase 2), nunca no caminho síncrono de abertura de tela.
    ///
    /// PLAN_07 preencheu o stub que o PLAN_06 deixou pronto: aqui roda o
    /// pipeline completo da Estratégia D (SOLUTIONS_PLAN.md §5.2, passos
    /// 4-7) — `loadModel()` → rascunho MLX (texto livre, código +
    /// explicação) → crítica FM (`critiqueCodeDraft`) → formatação FM
    /// (`formatCodeExample`, com retry se truncado). São exatamente os
    /// mesmos prompts que rodavam no caminho síncrono antes do PLAN_06; o
    /// que mudou é QUANDO eles rodam, não O QUE eles pedem. É isso que
    /// preserva a defesa contra alucinação de API documentada em `PLAN.md`
    /// §8.1 sem pagar o custo no relógio do usuário.
    ///
    /// A decisão de APLICAR o resultado (válido? diferente do FM-only?) NÃO
    /// é tomada aqui — é do chamador, `TopicRepository.applyCodeExampleUpgrade`
    /// (§5.2, passo 8). Esta função só produz o candidato.
    ///
    /// A prioridade chega sempre como `.poolFill` neste plano; a prioridade
    /// adaptativa por checks determinísticos é o PLAN_08 (§5.2, passo 3).
    ///
    /// Não lança, por contrato: um upgrade de background que falha nunca
    /// pode derrubar a tela (§16.5) — a ausência de upgrade é representada
    /// por `nil`, e o `StudyTopic` continua com o exemplo FM-only válido da
    /// Fase 1. Também NÃO cai pro `generateCodeExampleFM` em caso de erro
    /// (ao contrário do legado abaixo): isso só regeraria, com gasto de
    /// bateria e mais uma chamada FM, exatamente o que a Fase 1 já
    /// persistiu.
    func upgradeCodeExampleViaMLX(
        topic: String,
        context: String,
        priority: GenerationOrchestrator.Priority = .poolFill
    ) async -> ExplainedCodeExample? {
        do {
            // Passo 4 — dedup interno do MLXService: se a trilha B do
            // crescimento de pool já carregou (ou está carregando) o modelo,
            // isto NÃO dispara um segundo download/carga, só aguarda a mesma
            // Task compartilhada.
            try await MLXService.shared.loadModel()

            // Passo 5 — rascunho MLX (mesmo prompt do caminho síncrono
            // histórico, compartilhado com o legado dormente).
            let draft = try await mlxCodeExampleDraft(topic: topic, context: context, priority: priority)
            print("🔵 [upgrade do exemplo de código] rascunho MLX recebido (\(draft.count) chars) — criticando e formatando via Foundation Models.")

            // Passos 6 e 7 — crítica FM + formatação FM (a crítica acontece
            // DENTRO de formatCodeExample, que já encadeia as duas passadas).
            //
            // O candidato volta CRU de propósito: julgar se ele é válido e se
            // vale substituir o que está na tela é o passo 8, no
            // `TopicRepository`. Manter a decisão num lugar só é o que
            // permite distinguir, na instrumentação, "o pipeline falhou" de
            // "o pipeline produziu algo ruim" — dois problemas diferentes.
            return try await formatCodeExample(draft: draft, topic: topic, context: context, priority: priority)
        } catch {
            // Falha de upgrade é um NÃO-EVENTO pro usuário: a tela segue com
            // o conteúdo válido da Fase 1. Só loga.
            print("⚠️ [upgrade do exemplo de código] pipeline MLX→crítica→formatação falhou para '\(topic)' (\(StudyGeneratorError.describe(error))) — mantendo o exemplo FM-only da Fase 1.")
            return nil
        }
    }

    /// Rascunho MLX do exemplo de código (código + passo a passo em texto
    /// puro). Extraído do corpo de `legacyGenerateCodeExampleViaMLX` no
    /// PLAN_07 para ser COMPARTILHADO com `upgradeCodeExampleViaMLX` — o
    /// prompt não mudou nem uma palavra na extração, de propósito: os dois
    /// caminhos precisam produzir o mesmo tipo de rascunho, e duplicar o
    /// prompt seria garantir que eles divergissem com o tempo.
    ///
    /// Não chama `loadModel()` — quem chama decide quando pagar isso (o
    /// upgrade paga em background; o legado pagava no caminho síncrono).
    private func mlxCodeExampleDraft(
        topic: String,
        context: String,
        priority: GenerationOrchestrator.Priority
    ) async throws -> String {
        // PLAN_11: o bloco de contexto vem PRIMEIRO (e de
        // `mlxContextBlock`, compartilhado com o quiz difícil e a análise de
        // código) para que o prefixo `system prompt + contexto RAG` seja
        // reaproveitável entre as 3 chamadas MLX deste tópico. O texto da
        // instrução da tarefa não mudou — só desceu para depois do contexto.
        let mlxPrompt = """
        \(Self.mlxContextBlock(topic: topic, context: context))

        Escreva UM código Swift de 5-15 linhas, limpo e completo, que ilustre o conceito principal de '\(topic)', e explique-o passo a passo em texto puro.

        IMPORTANTE: use SOMENTE APIs, tipos e modificadores que aparecem no contexto oficial acima \
        ou que você tem certeza absoluta que existem na versão atual de Swift/SwiftUI. NÃO invente \
        nomes de métodos, classes, structs ou modificadores. Se não tiver certeza de que algo existe, \
        prefira uma abordagem mais simples e genérica em vez de arriscar um nome inventado.

        IMPORTANTE (Plano V5): priorize demonstrar o USO PRÁTICO do conceito, exatamente como um \
        desenvolvedor usaria no dia a dia (ex.: usar `@State`/`@Observable` numa View real) — NÃO \
        reimplemente o mecanismo do zero (ex.: criar um property wrapper customizado do zero pra \
        ilustrar 'Property Wrappers') a menos que o contexto oficial acima trate especificamente de \
        criar algo customizado. Prefira sempre o exemplo mais simples e direto de uso real.

        Formato exato da resposta (texto puro, sem markdown, sem JSON):
        CODIGO:
        <código>
        PASSO A PASSO:
        1. <trecho> — <explicação>
        2. <trecho> — <explicação>
        """

        // Fila do motor MLX (paralela à do FM, nunca a mesma) — F7, o
        // GenerationOrchestrator não é tocado por este plano.
        return try await GenerationOrchestrator.shared.schedule(engine: .mlx, priority: priority) {
            try await MLXService.shared.generateQuestionDraft(
                systemPrompt: MLXService.draftSystemPrompt,
                promptContext: mlxPrompt,
                topic: topic,
                taskType: .codeExampleDraft,
                cacheTopic: topic
            )
        }
    }

    /// PLAN_07 (§5.2, passo 8) — validade ESTRUTURAL de um exemplo candidato,
    /// antes de ele virar um patch sobre o `StudyTopic` já persistido.
    ///
    /// Deliberadamente barato e puramente sintático: só barra o que é
    /// obviamente pior que o exemplo FM-only que já está na tela (código
    /// vazio, código truncado, walkthrough vazio ou com passos vazios). NÃO
    /// é o gate determinístico do PLAN_08 (`DeterministicCodeChecks`,
    /// checklist sintático de erros conhecidos decidindo PRIORIDADE) — este
    /// aqui é só a rede que impede um resultado degenerado de substituir um
    /// conteúdo válido.
    ///
    /// `static` e sem dependência de estado: é testável como função pura
    /// (mesmo padrão de `looksTruncated`, já coberta em
    /// `StudyGeneratorPureFunctionsTests`).
    static func isStructurallyValidCodeExample(_ example: ExplainedCodeExample) -> Bool {
        guard !example.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !looksTruncated(example.code) else { return false }
        guard !example.walkthrough.isEmpty else { return false }
        // Um passo sem explicação não ensina nada — e o walkthrough é
        // exatamente o que a tela renderiza ao lado do código.
        return example.walkthrough.allSatisfy {
            !$0.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Pipeline MLX→crítica→formatação do exemplo de código (Plano V4 Fase 2):
    /// o MLX rascunha código + explicação em texto puro, e o Foundation Models
    /// só REFORMATA esse rascunho no schema ExplainedCodeExample.
    ///
    /// PLAN_06: era `generateCodeExample`, o caminho PRINCIPAL e SÍNCRONO de
    /// geração do exemplo — ou seja, toda abertura de tópico novo pagava
    /// carga + geração do modelo de 7B no relógio do usuário (o gargalo #1 do
    /// SOLUTIONS_PLAN.md, F1). Foi PRESERVADO aqui, e não deletado, por dois
    /// motivos: (1) é a base literal do upgrade em background do PLAN_07;
    /// (2) o rollback deste plano é voltar a chamá-lo direto da Fase 1.
    /// Hoje não tem chamador — é código dormente, de propósito.
    ///
    /// PLAN_07: o corpo do rascunho MLX saiu daqui pro `mlxCodeExampleDraft`
    /// compartilhado (mesmo prompt, mesma chamada, mesma fila) — o
    /// comportamento desta função não mudou, incluindo o fallback pro
    /// FM-only, que é o que a distingue do upgrade em background.
    private func legacyGenerateCodeExampleViaMLX(topic: String, context: String, priority: GenerationOrchestrator.Priority = .userBlocking) async throws -> ExplainedCodeExample {
        do {
            try await MLXService.shared.loadModel()

            let draft = try await mlxCodeExampleDraft(topic: topic, context: context, priority: priority)
            print("🔵 [exemplo de código] rascunho MLX recebido (\(draft.count) chars) — formatando via Foundation Models.")
            return try await formatCodeExample(draft: draft, topic: topic, context: context, priority: priority)
        } catch {
            print("⚠️ [exemplo de código] fluxo MLX→FM falhou (\(StudyGeneratorError.describe(error))) — fallback: Foundation Models gerando do zero.")
            return try await generateCodeExampleFM(topic: topic, context: context, priority: priority)
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

        let critique = try await critiqueCodeDraft(draft: cleanDraft, topic: topic, context: context, priority: priority, taskType: .codeExampleCritique)
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

        return try await Self.timed("formatação do exemplo de código (FM)", engine: .foundationModels, taskType: .codeExampleFormat, topic: topic, ragContextChars: context.count) {
            try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
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
    private func critiqueCodeDraft(draft: String, topic: String, context: String, priority: GenerationOrchestrator.Priority, taskType: GenerationMetrics.TaskType) async throws -> String {
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

        return try await Self.timed("crítica do exemplo de código (FM)", engine: .foundationModels, taskType: taskType, topic: topic, ragContextChars: context.count) {
            try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
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
    }

    /// PLAN_06 — CAMINHO PRINCIPAL do exemplo de código: Foundation Models
    /// gera código + walkthrough do zero, numa chamada dedicada. UMA chamada
    /// FM, ZERO MLX, ZERO carga de modelo.
    ///
    /// Era `generateCodeExampleFromScratch`, tratada como fallback raro do
    /// pipeline MLX→crítica→formatação. Foi PROMOVIDA a caminho principal e
    /// passou a ser chamada SEMPRE (não mais condicionalmente) na Fase 1 de
    /// `TopicRepository.generateAndPersistPhase1` — é isso que tira o modelo
    /// de 7B do relógio do usuário (SOLUTIONS_PLAN.md §5.2, passo 1).
    ///
    /// A revisão técnica não desapareceu, só deixou de ser síncrona: ela
    /// volta como upgrade em background em `upgradeCodeExampleViaMLX`
    /// (PLAN_07). O projeto já documentou (PLAN.md §8.1) que FM sozinho
    /// alucina API em código — por isso a crítica continua no desenho, só
    /// que paga pelo relógio do processador, não pelo do usuário.
    func generateCodeExampleFM(topic: String, context: String, priority: GenerationOrchestrator.Priority = .userBlocking) async throws -> ExplainedCodeExample {
        let model = try requireModel()

        let instructions = """
        Você é um assistente educacional especializado em Swift e nos frameworks da Apple.
        Responda sempre em português.
        Baseie-se PRINCIPALMENTE no contexto de documentação fornecido.
        Gere um exemplo de código Swift completo e compilável, e explique-o passo a passo,
        como se estivesse ensinando alguém que vê aquilo pela primeira vez.
        Use nomes de variáveis e funções descritivos.
        Priorize demonstrar o USO PRÁTICO do conceito, como um desenvolvedor usaria no dia a dia,
        em vez de reimplementar o mecanismo por baixo dos panos — a menos que o contexto trate
        especificamente disso.
        """

        return try await Self.timed("exemplo de código (FM-only, Fase 1)", engine: .foundationModels, taskType: .codeExampleFormat, topic: topic, ragContextChars: context.count) {
            try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
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

            // PLAN_11: contexto primeiro, via `mlxContextBlock` (mesmo bloco
            // do exemplo de código e da análise), depois a instrução da
            // tarefa — ver a documentação de `mlxContextBlock`.
            let mlxPrompt = """
            \(Self.mlxContextBlock(topic: topic, context: ragContext))

            Crie \(count) perguntas técnicas de nível avançado sobre '\(topic)', distintas entre si.

            Formato de CADA pergunta (texto puro, sem markdown), separadas pela linha \(MLXService.itemSeparator):
            PERGUNTA: <a pergunta>
            RESPOSTA CORRETA: <explicação do comportamento/resposta certa, 1-2 frases>
            POR QUE OUTRAS RESPOSTAS PARECEM CERTAS MAS NÃO SÃO: <1-2 frases de erros comuns/conceitos que confundem>
            """

            // Plano V3 4.2: chamadas de geração no MLX passam pela fila
            // própria do motor MLX (paralela à do FM, nunca a mesma fila).
            let drafts = try await GenerationOrchestrator.shared.schedule(engine: .mlx, priority: priority) {
                try await MLXService.shared.generateQuestionDrafts(
                    systemPrompt: MLXService.draftSystemPrompt,
                    promptContext: mlxPrompt,
                    count: count,
                    topic: topic,
                    taskType: .hardQuizDraft,
                    cacheTopic: topic
                )
            }

            // PLAN_09: formatação em LOTE — uma única chamada FM formata até
            // N rascunhos de uma vez (reaproveitando QuizQuestionBatch, já
            // usado com sucesso pelo quiz fácil/médio), em vez de N chamadas
            // individuais. `formatHardQuestion` continua existindo e é usada
            // como fallback item a item se o lote falhar ou vier truncado.
            var results = await formatHardQuestionsBatch(drafts: Array(drafts.prefix(count)), topic: topic, difficulty: difficulty, priority: priority)

            // Se o lote veio com menos itens que o pedido (split falhou ou o
            // modelo gerou menos), completa um a um — nunca devolve menos.
            while results.count < count {
                let single = try await GenerationOrchestrator.shared.schedule(engine: .mlx, priority: priority) {
                    try await MLXService.shared.generateQuestionDraft(
                        systemPrompt: MLXService.draftSystemPrompt,
                        promptContext: mlxPrompt.replacingOccurrences(of: "Crie \(count) perguntas técnicas", with: "Crie UMA pergunta técnica"),
                        topic: topic,
                        taskType: .hardQuizDraft,
                        cacheTopic: topic
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
        let taskType: GenerationMetrics.TaskType = (difficulty == .easy) ? .easyQuiz : .mediumQuiz

        return try await Self.timed("quiz \(difficultyLabel.lowercased()) (FM)", engine: .foundationModels, taskType: taskType, topic: topic, ragContextChars: context.count, batchSize: count) {
            try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
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

    /// PLAN_09 (§6.2.1) — formata um LOTE de rascunhos MLX (≤4) em
    /// QuizQuestion numa ÚNICA chamada ao Foundation Models, reaproveitando
    /// o schema `QuizQuestionBatch` (já usado com sucesso pelo quiz
    /// fácil/médio) em vez do schema `QuizQuestion` avulso. Substitui N
    /// chamadas individuais por 1 — o maior contribuinte de chamadas FM de
    /// background por tópico novo (SOLUTIONS_PLAN.md §6.1).
    ///
    /// Fallback gracioso de 2 níveis, por design (SOLUTIONS_PLAN.md §27):
    /// (1) se o lote inteiro falhar ou devolver uma contagem diferente da
    /// esperada — não dá pra confiar no pareamento rascunho↔pergunta nesse
    /// caso — cai para `formatHardQuestion` item a item; (2) se só um item
    /// específico do lote vier truncado, só ESSE item é reformatado
    /// individualmente, sem descartar o lote inteiro.
    ///
    /// `formatHardQuestion` (individual) NÃO foi removida — continua no
    /// código como base dos dois níveis de fallback acima.
    private func formatHardQuestionsBatch(drafts: [String], topic: String, difficulty: Difficulty, priority: GenerationOrchestrator.Priority) async -> [QuizQuestion] {
        let cleanDrafts = drafts.map(Self.sanitizeDraft).filter { !$0.isEmpty }
        guard !cleanDrafts.isEmpty else { return [] }

        // Curto-circuito pra 1 rascunho só: NÃO vale pagar o overhead do
        // schema em array (QuizQuestionBatch) pra formatar um item único —
        // isso é comum na prática quando o split do MLX (itemSeparator)
        // devolve menos rascunhos que o pedido. `formatHardQuestion` usa o
        // schema QuizQuestion avulso, mais leve e já testado pra 1 item —
        // mesmo padrão de curto-circuito de `critiqueCodeDraftsBatch`.
        guard cleanDrafts.count > 1 else {
            return [await formatHardQuestion(draft: cleanDrafts[0], topic: topic, difficulty: difficulty, priority: priority)]
        }

        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            print("⚠️ [lote de perguntas difíceis] Foundation Models indisponível — formatando individualmente.")
            var results: [QuizQuestion] = []
            for draft in cleanDrafts {
                results.append(await formatHardQuestion(draft: draft, topic: topic, difficulty: difficulty, priority: priority))
            }
            return results
        }

        let instructions = """
        Você recebe um LOTE de rascunhos de perguntas técnicas de Swift, cada um já com a resposta correta
        indicada, separados pela linha \(MLXService.itemSeparator).
        Sua tarefa é reformatar CADA rascunho, na MESMA ORDEM, em uma pergunta de múltipla escolha com
        exatamente 4 alternativas plausíveis, sendo apenas uma correta — baseada fielmente no rascunho
        correspondente, sem inventar informação nova.
        As alternativas NUNCA devem ter prefixo de letra ou número (nunca "A)", "B.", "1)" etc., mesmo que o
        rascunho tenha algo parecido) — escreva só o texto puro de cada alternativa.
        Devolva EXATAMENTE \(cleanDrafts.count) perguntas, uma para cada rascunho, na mesma ordem.
        Responda sempre em português.
        """

        let joinedDrafts = cleanDrafts.enumerated()
            .map { "Rascunho \($0.offset + 1):\n\($0.element)" }
            .joined(separator: "\n\(MLXService.itemSeparator)\n")

        let prompt = """
        Rascunhos gerados por outro modelo (\(cleanDrafts.count) itens, separados por \(MLXService.itemSeparator)):
        \(joinedDrafts)

        Reformate CADA rascunho acima em uma pergunta de múltipla escolha de dificuldade \(difficulty.rawValue),
        na mesma ordem, com 4 alternativas plausíveis (não óbvias) cada e a alternativa correta identificada.
        """

        // Mesma fórmula já usada e testada para lotes de QuizQuestion
        // (generateQuizBatch fácil/médio) — 220 tokens/pergunta + 150 de folga.
        let options = GenerationOptions(maximumResponseTokens: 220 * cleanDrafts.count + 150)

        for attempt in 1...2 {
            do {
                let formatted = try await Self.timed("formatação de lote de perguntas difíceis (FM)", engine: .foundationModels, taskType: .hardQuizFormat, topic: topic, batchSize: cleanDrafts.count) {
                    try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
                        let session = LanguageModelSession(model: model, instructions: instructions)
                        return try await session.respond(to: prompt, generating: QuizQuestionBatch.self, options: options)
                    }
                }
                var questions = formatted.content.questions

                // Contagem diferente do esperado: não dá pra confiar no
                // pareamento rascunho↔pergunta — trata como falha de lote e
                // cai pro caminho individual (mais confiável nesse caso).
                guard questions.count == cleanDrafts.count else {
                    print("⚠️ [lote de perguntas difíceis] contagem devolvida (\(questions.count)) != rascunhos (\(cleanDrafts.count)) — formatando individualmente.")
                    break
                }

                // Retry POR ITEM se algum vier truncado — nunca descarta o
                // lote inteiro por causa de 1 item (SOLUTIONS_PLAN.md §6.2.1).
                for index in questions.indices where Self.looksTruncated(questions[index].question) {
                    print("⚠️ [lote de perguntas difíceis] item \(index) parece truncado — retry individual.")
                    questions[index] = await formatHardQuestion(draft: cleanDrafts[index], topic: topic, difficulty: difficulty, priority: priority)
                }
                return questions
            } catch {
                print("⚠️ [lote de perguntas difíceis] formatação em lote falhou (tentativa \(attempt)/2): \(StudyGeneratorError.describe(error))")
                if attempt < 2 { try? await Task.sleep(for: .seconds(1)) }
            }
        }

        // Fallback gracioso (SOLUTIONS_PLAN.md §27): o lote falhou de forma
        // sistemática — cai pra formatação individual, item a item. Mais
        // chamadas que o caminho feliz, mas mais barato que reverter o PR
        // inteiro, e nunca falha o tópico inteiro por causa disso.
        print("⚠️ [lote de perguntas difíceis] lote falhou — caindo para formatação individual (fallback gracioso).")
        var results: [QuizQuestion] = []
        for draft in cleanDrafts {
            results.append(await formatHardQuestion(draft: draft, topic: topic, difficulty: difficulty, priority: priority))
        }
        return results
    }

    /// Formata UM rascunho do MLX numa QuizQuestion via Foundation Models.
    /// Nunca lança: se a formatação falhar, devolve o fallback genérico.
    ///
    /// Plano V5, PLAN_02: adicionado orçamento de token explícito (370 tokens,
    /// fórmula 220*1+150) e detecção de truncamento + retry-curto, trazendo
    /// paridade com formatCodeAnalysisQuestion que já tinha esse padrão correto.
    ///
    /// PLAN_09: continua existindo (não deletada) como base dos dois níveis
    /// de fallback de `formatHardQuestionsBatch` — retry por item truncado e
    /// degradação graciosa se o lote inteiro falhar.
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
        //
        // Plano V5, PLAN_02: adicionado orçamento explícito (220*1+150=370)
        // e detecção de truncamento + retry-curto (mesmo padrão de
        // formatCodeAnalysisQuestion), evitando que a pergunta seja truncada
        // por competição de tokens com explicação ou alternativas.
        for attempt in 1...3 {
            do {
                let options = GenerationOptions(maximumResponseTokens: 370)
                let formatted = try await Self.timed("formatação de pergunta difícil (FM)", engine: .foundationModels, taskType: .hardQuizFormat, topic: topic) {
                    try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
                        let session = LanguageModelSession(model: model, instructions: formatterInstructions)
                        return try await session.respond(to: formatterPrompt, generating: QuizQuestion.self, options: options)
                    }
                }
                if Self.looksTruncated(formatted.content.question) {
                    print("⚠️ [pergunta difícil] pergunta parece truncada — retry pedindo versão mais curta.")
                    let retrySession = LanguageModelSession(model: model, instructions: formatterInstructions)
                    let retryPrompt = formatterPrompt + "\n\nIMPORTANTE: mantenha a pergunta BREVE (máximo 1-2 frases)."
                    let retry = try await Self.timed("formatação de pergunta difícil retry (FM)", engine: .foundationModels, taskType: .hardQuizFormat, topic: topic) {
                        try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
                            try await retrySession.respond(to: retryPrompt, generating: QuizQuestion.self, options: options)
                        }
                    }
                    if !Self.looksTruncated(retry.content.question) {
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

    // MARK: - Análise de código

    /// Gera um lote de perguntas de análise de código (rascunhos MLX em lote
    /// + formatação estruturada via Foundation Models).
    func generateCodeAnalysisBatch(topic: String, context: String, count: Int, priority: GenerationOrchestrator.Priority = .userBlocking) async throws -> [CodeAnalysisQuestion] {
        try await MLXService.shared.loadModel()

        // Plano V4 Fase 4: contexto via busca exata por tópico (nunca fuzzy).
        // Plano V5: topK 3 — ver comentário equivalente em generateQuizBatch.
        let ragContext = await retrieveContext(for: topic, topK: 3)

        // PLAN_11: contexto primeiro, via `mlxContextBlock` — o cabeçalho
        // `[Contexto RAG]` que existia aqui foi substituído pelo bloco
        // compartilhado, senão o prefixo comum com as outras 2 chamadas
        // deste tópico morreria justamente no cabeçalho.
        let mlxPrompt = """
        \(Self.mlxContextBlock(topic: topic, context: ragContext))

        Escreva \(count) trechos de código Swift limpos, de 6 a 10 linhas cada, sobre '\(topic)', e explique o comportamento de cada um. Os trechos devem ser distintos entre si.

        IMPORTANTE: priorize trechos que mostrem o USO PRÁTICO do conceito (como um desenvolvedor
        realmente usaria), não a reimplementação do mecanismo por baixo dos panos.

        Formato de CADA item (texto puro, sem markdown, sem JSON), separados pela linha \(MLXService.itemSeparator):
        CODIGO:
        <o trecho de código Swift>
        COMPORTAMENTO ESPERADO: <o que o código faz / resultado ao executar, 1-2 frases>
        POR QUE OUTRAS RESPOSTAS PARECEM CERTAS MAS NÃO SÃO: <1-2 frases de erros comuns/conceitos que confundem>
        """

        do {
            let drafts = try await GenerationOrchestrator.shared.schedule(engine: .mlx, priority: priority) {
                try await MLXService.shared.generateQuestionDrafts(
                    systemPrompt: MLXService.draftSystemPrompt,
                    promptContext: mlxPrompt,
                    count: count,
                    topic: topic,
                    taskType: .codeAnalysisDraft,
                    cacheTopic: topic
                )
            }

            // PLAN_09: crítica + formatação em LOTE — 2 chamadas FM (1 crítica
            // em lote + 1 formatação em lote) formatam até N rascunhos, em vez
            // de N pares de chamadas (crítica + formatação por item).
            // `formatCodeAnalysisQuestion` continua existindo, usada como
            // fallback item a item pelas duas funções de lote abaixo.
            let batchDrafts = Array(drafts.prefix(count))
            let critiques = await critiqueCodeDraftsBatch(drafts: batchDrafts, topic: topic, context: ragContext, priority: priority, taskType: .codeAnalysisCritique)
            var results = await formatCodeAnalysisBatch(drafts: batchDrafts, critiques: critiques, topic: topic, context: ragContext, priority: priority)

            while results.count < count {
                let single = try await GenerationOrchestrator.shared.schedule(engine: .mlx, priority: priority) {
                    try await MLXService.shared.generateQuestionDraft(
                        systemPrompt: MLXService.draftSystemPrompt,
                        promptContext: mlxPrompt.replacingOccurrences(of: "Escreva \(count) trechos de código Swift limpos", with: "Escreva UM trecho de código Swift limpo"),
                        topic: topic,
                        taskType: .codeAnalysisDraft,
                        cacheTopic: topic
                    )
                }
                results.append(await formatCodeAnalysisQuestion(draft: single, topic: topic, context: ragContext, priority: priority))
            }
            return results
        } catch {
            throw StudyGeneratorError.generationFailed(step: "análise de código (MLX)", underlying: error)
        }
    }

    /// PLAN_09 (§6.2.2) — critica um LOTE de rascunhos de código numa ÚNICA
    /// chamada FM, em vez de uma chamada de crítica por rascunho.
    ///
    /// Diferente de `formatHardQuestionsBatch`/`formatCodeAnalysisBatch`, NÃO
    /// usa um schema `@Generable` novo: pede texto livre com as críticas
    /// separadas por `MLXService.itemSeparator`, na mesma ordem dos
    /// rascunhos — o mesmo padrão de parsing já usado em
    /// `MLXService.generateQuestionDrafts`. Um schema estruturado
    /// (`CritiqueBatch`) só seria criado se esta abordagem se mostrasse
    /// frágil em teste real (SOLUTIONS_PLAN.md §6.2.2) — não foi o caso, e
    /// não foi implementado preventivamente.
    ///
    /// Fallback gracioso: se o split não devolver exatamente `drafts.count`
    /// itens (parsing falhou) ou a chamada em lote lançar, cai para
    /// `critiqueCodeDraft` item a item.
    private func critiqueCodeDraftsBatch(drafts: [String], topic: String, context: String, priority: GenerationOrchestrator.Priority, taskType: GenerationMetrics.TaskType) async -> [String] {
        guard !drafts.isEmpty else { return [] }
        guard drafts.count > 1 else {
            return [(try? await critiqueCodeDraft(draft: drafts[0], topic: topic, context: context, priority: priority, taskType: taskType)) ?? "OK - sem erros"]
        }

        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            var results: [String] = []
            for draft in drafts {
                results.append((try? await critiqueCodeDraft(draft: draft, topic: topic, context: context, priority: priority, taskType: taskType)) ?? "OK - sem erros")
            }
            return results
        }

        let instructions = """
        Você é um revisor de código Swift rigoroso. Você recebe um LOTE de rascunhos de código Swift,
        separados pela linha \(MLXService.itemSeparator). Sua ÚNICA tarefa é apontar erros técnicos REAIS em
        CADA rascunho — não reescreva o código, só liste os problemas de cada um.
        Procure especificamente por: APIs que não existem, uso incorreto de uma API real (ex.: passar um
        valor onde a API espera um TIPO, como em navigationDestination(for:), que exige Tipo.self e não
        um valor literal; ou um parâmetro de inicializador que o tipo não declara), métodos/modificadores
        deprecados, e qualquer contradição com o contexto de documentação oficial fornecido.

        \(Self.commonCodeMistakesChecklist)

        Se não encontrar nenhum erro real num rascunho, responda exatamente "OK - sem erros" pra ele.
        Seja específico (cite o trecho exato) e conciso — no máximo 5 pontos por rascunho.
        Responda sempre em português.

        IMPORTANTE: devolva EXATAMENTE \(drafts.count) críticas, na MESMA ORDEM dos rascunhos, cada uma
        separada pela linha \(MLXService.itemSeparator) — nunca junte duas críticas no mesmo bloco.
        """

        let joinedDrafts = drafts.enumerated()
            .map { "Rascunho \($0.offset + 1):\n\($0.element)" }
            .joined(separator: "\n\(MLXService.itemSeparator)\n")

        let prompt = """
        Contexto da documentação oficial:
        \(context.isEmpty ? "Conhecimento geral de Swift, com cautela." : context)

        Rascunhos de código Swift sobre '\(topic)' (\(drafts.count) itens, separados por \(MLXService.itemSeparator)):
        \(joinedDrafts)

        Liste os erros técnicos reais de CADA rascunho acima (ou "OK - sem erros" pra ele), na mesma ordem,
        separando cada crítica pela linha \(MLXService.itemSeparator).
        """

        // Linear, ponto de partida a calibrar por medição (SOLUTIONS_PLAN.md §6.2.2).
        let options = GenerationOptions(maximumResponseTokens: 350 * drafts.count)

        do {
            let response = try await Self.timed("crítica em lote de análise de código (FM)", engine: .foundationModels, taskType: taskType, topic: topic, ragContextChars: context.count, batchSize: drafts.count) {
                try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
                    let session = LanguageModelSession(model: model, instructions: instructions)
                    return try await session.respond(to: prompt, options: options)
                }
            }
            let items = response.content
                .components(separatedBy: MLXService.itemSeparator)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if items.count == drafts.count {
                return items
            }
            print("⚠️ [crítica em lote de análise de código] contagem devolvida (\(items.count)) != rascunhos (\(drafts.count)) — críticas individuais.")
        } catch {
            print("⚠️ [crítica em lote de análise de código] falhou (\(StudyGeneratorError.describe(error))) — críticas individuais.")
        }

        var results: [String] = []
        for draft in drafts {
            results.append((try? await critiqueCodeDraft(draft: draft, topic: topic, context: context, priority: priority, taskType: taskType)) ?? "OK - sem erros")
        }
        return results
    }

    /// PLAN_09 (§6.2.2) — formata um LOTE de rascunhos de análise de código
    /// (≤4), já com suas críticas pré-computadas (`critiqueCodeDraftsBatch`),
    /// numa ÚNICA chamada ao Foundation Models — reaproveita o schema
    /// `CodeAnalysisBatch` (já existia em `StudyModels.swift`, nunca usado
    /// antes deste plano).
    ///
    /// Mesmo desenho de fallback em 2 níveis de `formatHardQuestionsBatch`:
    /// contagem incorreta ou erro na chamada → cai pra `formatCodeAnalysisQuestion`
    /// item a item (que recalcula a própria crítica); `codeSnippet` truncado
    /// num item específico → só ESSE item é refeito individualmente, sem
    /// descartar o lote inteiro. O risco de truncamento aqui é maior que no
    /// quiz difícil por causa do `codeSnippet` competindo por orçamento
    /// dentro do mesmo item (SOLUTIONS_PLAN.md §6.2.2).
    private func formatCodeAnalysisBatch(drafts: [String], critiques: [String], topic: String, context: String, priority: GenerationOrchestrator.Priority) async -> [CodeAnalysisQuestion] {
        let cleanDrafts = drafts.map(Self.sanitizeDraft)
        guard !cleanDrafts.isEmpty else { return [] }

        // Curto-circuito pra 1 rascunho só (mesmo raciocínio de
        // `formatHardQuestionsBatch`): não vale pagar o overhead do schema em
        // array (CodeAnalysisBatch) pra formatar um item único — comum
        // quando o split do MLX devolve menos rascunhos que o pedido.
        // `formatCodeAnalysisQuestion` recalcula sua própria crítica, mas
        // isso é aceitável só no caso raro de 1 item.
        guard drafts.count > 1 else {
            return [await formatCodeAnalysisQuestion(draft: drafts[0], topic: topic, context: context, priority: priority)]
        }

        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            var results: [CodeAnalysisQuestion] = []
            for draft in drafts {
                results.append(await formatCodeAnalysisQuestion(draft: draft, topic: topic, context: context, priority: priority))
            }
            return results
        }

        let instructions = """
        Você recebe um LOTE de rascunhos, cada um com um trecho de código Swift e a explicação do
        comportamento esperado dele, além de uma REVISÃO TÉCNICA feita por um segundo revisor — separados
        pela linha \(MLXService.itemSeparator), na mesma ordem.
        Sua tarefa é reformatar CADA rascunho, na MESMA ORDEM, numa pergunta de análise de código com
        exatamente 5 alternativas plausíveis, sendo apenas uma correta.
        Se a revisão técnica de um rascunho apontou um erro real no código (API que não existe, sintaxe
        inválida, algo que não compila sem intenção pedagógica), CORRIJA o código no campo codeSnippet
        daquele item antes de formatar — não preserve um erro real só por fidelidade ao rascunho. Se a
        revisão disse que não há erros, preserve o código como está, sem a marcação 'CODIGO:'.
        A alternativa correta e as explicações têm que corresponder exatamente ao comportamento real do
        código já corrigido, não ao rascunho original.
        As alternativas NUNCA devem ter prefixo de letra ou número (nunca "A)", "B.", "1)" etc.) — escreva
        só o texto puro de cada alternativa.
        Devolva EXATAMENTE \(cleanDrafts.count) perguntas, uma para cada rascunho, na mesma ordem.

        \(Self.commonCodeMistakesChecklist)

        Responda sempre em português.
        """

        let joinedItems = cleanDrafts.enumerated().map { index, draft -> String in
            let critique = index < critiques.count ? critiques[index] : "OK - sem erros"
            return "Rascunho \(index + 1):\n\(draft)\nRevisão técnica \(index + 1):\n\(critique)"
        }.joined(separator: "\n\(MLXService.itemSeparator)\n")

        let prompt = """
        Contexto da documentação oficial:
        \(context.isEmpty ? "Conhecimento geral de Swift, com cautela." : context)

        Rascunhos sobre '\(topic)' (\(cleanDrafts.count) itens, com suas revisões técnicas, separados por
        \(MLXService.itemSeparator)):
        \(joinedItems)

        Reformate CADA rascunho acima numa pergunta de análise de código sobre '\(topic)', na mesma ordem,
        com 5 alternativas plausíveis (não óbvias) cada e a alternativa correta identificada, aplicando as
        correções de cada revisão técnica.
        """

        // Ponto de partida a calibrar por medição (SOLUTIONS_PLAN.md §6.2.2) —
        // risco de truncamento maior aqui por causa do codeSnippet em cada item.
        let options = GenerationOptions(maximumResponseTokens: 850 * cleanDrafts.count + 100)

        for attempt in 1...2 {
            do {
                let formatted = try await Self.timed("formatação de lote de análise de código (FM)", engine: .foundationModels, taskType: .codeAnalysisFormat, topic: topic, ragContextChars: context.count, batchSize: cleanDrafts.count) {
                    try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
                        let session = LanguageModelSession(model: model, instructions: instructions)
                        return try await session.respond(to: prompt, generating: CodeAnalysisBatch.self, options: options)
                    }
                }
                var questions = formatted.content.questions

                guard questions.count == cleanDrafts.count else {
                    print("⚠️ [lote de análise de código] contagem devolvida (\(questions.count)) != rascunhos (\(cleanDrafts.count)) — formatando individualmente.")
                    break
                }

                // Retry POR ITEM se algum codeSnippet vier truncado — nunca
                // descarta o lote inteiro por causa de 1 item.
                for index in questions.indices where Self.looksTruncated(questions[index].codeSnippet) {
                    print("⚠️ [lote de análise de código] item \(index) parece truncado — retry individual.")
                    questions[index] = await formatCodeAnalysisQuestion(draft: drafts[index], topic: topic, context: context, priority: priority)
                }
                return questions
            } catch {
                print("⚠️ [lote de análise de código] formatação em lote falhou (tentativa \(attempt)/2): \(StudyGeneratorError.describe(error))")
                if attempt < 2 { try? await Task.sleep(for: .seconds(1)) }
            }
        }

        // Fallback gracioso (SOLUTIONS_PLAN.md §27): cai pra formatação
        // individual, item a item — recalcula a própria crítica por item,
        // mas nunca falha o tópico inteiro por causa de um lote ruim.
        print("⚠️ [lote de análise de código] lote falhou — caindo para formatação individual (fallback gracioso).")
        var results: [CodeAnalysisQuestion] = []
        for draft in drafts {
            results.append(await formatCodeAnalysisQuestion(draft: draft, topic: topic, context: context, priority: priority))
        }
        return results
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
    ///
    /// PLAN_09: continua existindo (não deletada) como base do fallback de
    /// `critiqueCodeDraftsBatch`/`formatCodeAnalysisBatch` — retry por item
    /// truncado e degradação graciosa se o lote inteiro falhar.
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

        let critique = (try? await critiqueCodeDraft(draft: cleanDraft, topic: topic, context: context, priority: priority, taskType: .codeAnalysisCritique)) ?? "OK - sem erros"
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
                let formatted = try await Self.timed("formatação de análise de código (FM)", engine: .foundationModels, taskType: .codeAnalysisFormat, topic: topic, ragContextChars: context.count) {
                    try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
                        let session = LanguageModelSession(model: model, instructions: formatterInstructions)
                        return try await session.respond(to: formatterPrompt, generating: CodeAnalysisQuestion.self, options: options)
                    }
                }
                if Self.looksTruncated(formatted.content.codeSnippet) {
                    print("⚠️ [análise de código] codeSnippet parece truncado — retry pedindo versão mais curta.")
                    let retrySession = LanguageModelSession(model: model, instructions: formatterInstructions)
                    let retryPrompt = formatterPrompt + "\n\nIMPORTANTE: mantenha o codeSnippet com NO MÁXIMO 8 linhas de código."
                    let retry = try await Self.timed("formatação de análise de código retry (FM)", engine: .foundationModels, taskType: .codeAnalysisFormat, topic: topic, ragContextChars: context.count) {
                        try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
                            try await retrySession.respond(to: retryPrompt, generating: CodeAnalysisQuestion.self, options: options)
                        }
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

        return try await Self.timed("feedback da sessão (FM)", engine: .foundationModels, taskType: .feedback, topic: topic) {
            try await GenerationOrchestrator.shared.schedule(engine: .foundationModels, priority: priority) {
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
}
