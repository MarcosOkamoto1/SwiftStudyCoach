//
//  MLXService.swift
//  SwiftStudyCoach
//
//  Created by Geovana Cena de Albuquerque on 05/08/26.
//
//  Melhorias desta versão (Plano V6 — diagnóstico de latência):
//  - VOLTA pro Qwen2.5-Coder-7B-Instruct-4bit (~4,3 GB). O Qwen3-Coder MoE
//    30B-A3B-4bit (~17,2 GB) não cabia de forma saudável na máquina-alvo:
//    o macOS limita a memória wired da GPU a ~75% da RAM unificada (~18 GB
//    num Mac de 24 GB), e 17,2 GB de pesos + KV cache + ativações + app +
//    Foundation Models + sistema estouravam isso — swap/pressão de memória
//    derrubava a geração de dezenas de tokens/s pra poucos. O 7B denso
//    elimina o swap, corta o download de 17,2 GB → 4,3 GB e carrega na RAM
//    em segundos em vez de minutos.
//  - Pasta local de override restaurada, agora DERIVADA do modelID
//    (~/mlx-models/<repo-em-minúsculas>): se os pesos foram baixados
//    manualmente via `hf download` (bem mais rápido que o downloader do
//    swift-transformers), o app carrega direto deles, sem rede. Se a pasta
//    não existir, cai automaticamente pro download normal do Hugging Face
//    na primeira execução (a ModelDownloadView mostra o progresso).
//  - Progresso de download real (fração + velocidade + ETA) exposto de
//    forma observável — ver ModelDownloadView.
//  - Geração de rascunhos em LOTE (generateQuestionDrafts): um único
//    prefill do prompt para N itens, em vez de um prefill por item.
//  - Instrumentação de tempo: loadModel e generate logam duração (e
//    chars/s na geração) pra diagnosticar onde o tempo é gasto.
//

import Foundation
import Observation
import MLX
import MLXLLM
import MLXLMCommon

@Observable
final class MLXService {
    static let shared = MLXService()

    /// ID do modelo no Hugging Face (mlx-community). Constante separada de
    /// propósito: facilita A/B com outros tamanhos da linha Qwen2.5-Coder
    /// (1.5B/3B/14B) ou com o Qwen3-Coder MoE 30B-A3B (testado e revertido —
    /// ver comentário do cabeçalho do arquivo: não cabia na RAM sem swap).
    static let modelID = "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"

    /// Tamanho aproximado do download (usado pra estimar MB e velocidade —
    /// o progress do Hub reporta fração, não bytes). ~4,3 GB na página do
    /// modelo no Hugging Face.
    static let estimatedModelBytes: Int64 = 4_300_000_000

    /// Linha separadora usada nos prompts/parse de geração em lote.
    static let itemSeparator = "====="

    /// PLAN_11 — liga/desliga o cache de prefixo MLX.
    ///
    /// Este é o ROLLBACK do plano, na forma de 1 linha: com `false`, o
    /// `cache:` passado a `MLXLMCommon.generate` volta a ser `nil` e o
    /// comportamento é EXATAMENTE o de antes do PLAN_11 (cada chamada cria
    /// seu próprio `KVCacheSimple`). Também é o interruptor que o
    /// `PromptCacheBenchmark` usa para medir o mesmo prompt com e sem
    /// cache.
    ///
    /// `nonisolated(unsafe)`: é uma alavanca de diagnóstico/benchmark,
    /// escrita só pelo benchmark (que roda serialmente) e lida pelo caminho
    /// de geração. Não vale a pena um `actor` para um `Bool` de rollback.
    nonisolated(unsafe) static var isPromptCacheEnabled = true

    /// PLAN_11 — system prompt ÚNICO para as 3 tarefas de rascunho MLX.
    ///
    /// §7.2.1 recomendava a opção (a): unificar os 3 system prompts, que
    /// hoje diferem em uma frase ("Gere um código de exemplo…" vs. "Gere
    /// perguntas técnicas difíceis…" vs. "Gere trechos de código e
    /// perguntas de análise…"), e mover a instrução ESPECÍFICA da tarefa
    /// para o `promptContext` — que já é o texto que muda a cada chamada.
    /// Assim o prefixo cacheável cobre o system prompt INTEIRO, não só o
    /// pedaço até a primeira palavra divergente.
    static let draftSystemPrompt =
        "Você é um especialista em Swift, ajudando a gerar material de estudo sobre um tópico específico. Responda sempre em texto puro, sem markdown e sem JSON, usando apenas APIs reais."

    /// Pasta local opcional com os pesos já baixados manualmente, ex:
    /// `hf download mlx-community/Qwen2.5-Coder-7B-Instruct-4bit --local-dir ~/mlx-models/qwen2.5-coder-7b-instruct-4bit`
    /// O nome da pasta é derivado do `modelID` (repo em minúsculas), então
    /// trocar o modelo pra A/B troca a pasta esperada automaticamente. Se a
    /// pasta existir e tiver pesos de verdade (.safetensors), `performLoad`
    /// carrega direto dela via `ModelConfiguration(directory:)`, sem rede e
    /// sem HubApi; senão, cai pro download normal via `modelID` — não
    /// quebra nada em outra máquina.
    private static var localModelOverrideDirectory: URL? {
        guard let repo = modelID.split(separator: "/").last else { return nil }
        let path = ("~/mlx-models/\(repo.lowercased())" as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        return directoryContainsSafetensors(url) ? url : nil
    }

    /// Estado observável do carregamento/download do modelo MLX. A UI
    /// (ModelDownloadView) observa isso pra mostrar progresso, velocidade
    /// e tempo estimado na primeira execução.
    enum LoadState: Equatable {
        case idle
        case downloading(fraction: Double)
        case loadingIntoMemory   // download concluído, carregando pesos na RAM
        case ready
        case failed(String)
    }

    private(set) var loadState: LoadState = .idle

    /// Velocidade estimada de download (bytes/s) e tempo restante estimado
    /// (segundos) — calculados por janela deslizante das últimas amostras
    /// de progresso, com suavização pra não oscilar.
    private(set) var downloadSpeedBytesPerSecond: Double?
    private(set) var downloadETASeconds: Double?

    private var progressSamples: [(date: Date, fraction: Double)] = []

    private var modelContainer: ModelContainer?
    private var isLoaded = false
    private var loadTask: Task<Void, Error>?

    /// PLAN_00 — vira `false` assim que a 1ª geração real acontece depois de
    /// um `loadModel()`. Usado só para popular `GenerationMetrics.isColdStart`
    /// nas chamadas de `generate` (aproximação de "esta foi a 1ª inferência
    /// depois dos pesos carregarem", relevante para diagnosticar o warm-up
    /// de grafo/kernels Metal citado no PLAN_12 — não é o mesmo sinal que o
    /// `isColdStart` do próprio carregamento dos pesos, ver `performLoad`).
    private var hasGeneratedSinceLoad = false

    private init() {}

    // MARK: - Carregamento / download

    func loadModel() async throws {
        guard !isLoaded else {
            loadState = .ready
            return
        }

        // Dedup: várias chamadas concorrentes (tela + crescimento de pool em
        // background) aguardam o MESMO carregamento em vez de duplicá-lo.
        if let loadTask {
            try await loadTask.value
            return
        }

        // Prioridade fixa: sem ela, a Task herda o QoS de quem chamou
        // primeiro — se o 1º gatilho fosse o pré-aquecimento/crescimento em
        // background (.utility), o download + carga dos pesos inteiros
        // rodavam estrangulados, mesmo que o usuário passasse a esperar.
        let task = Task(priority: .userInitiated) { try await performLoad() }
        loadTask = task
        do {
            try await task.value
        } catch {
            loadTask = nil // permite retry após falha
            throw error
        }
    }

    private func performLoad() async throws {
        loadState = .downloading(fraction: 0)
        progressSamples = [(Date(), 0)]
        downloadSpeedBytesPerSecond = nil
        downloadETASeconds = nil

        let modelConfiguration: ModelConfiguration
        if let localDir = Self.localModelOverrideDirectory {
            print("🟢 MLXService: pesos locais encontrados em \(localDir.path) — carregando direto, sem download.")
            modelConfiguration = ModelConfiguration(directory: localDir)
        } else {
            // Download normal via Hugging Face na 1ª execução (com progresso
            // na ModelDownloadView); depois carrega do cache local.
            modelConfiguration = ModelConfiguration(id: Self.modelID)
        }

        let loadStart = Date()
        print("⏱️ MLXService: carregando modelo (\(Self.modelID))...")
        do {
            self.modelContainer = try await LLMModelFactory.shared.loadContainer(
                configuration: modelConfiguration
            ) { [weak self] progress in
                // O handler é @Sendable e roda fora do MainActor — capturamos
                // só o Double e voltamos pro MainActor pra mutar estado.
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    self?.recordProgress(fraction: fraction)
                }
            }
            self.isLoaded = true
            self.hasGeneratedSinceLoad = false
            loadState = .ready
            downloadSpeedBytesPerSecond = nil
            downloadETASeconds = nil
            let loadElapsedMs = Date().timeIntervalSince(loadStart) * 1000
            print("⏱️ MLXService: modelo pronto em \(String(format: "%.1f", loadElapsedMs / 1000))s (download + carga na RAM).")

            // PLAN_00 §10.2: o carregamento em si (download + carga na RAM)
            // também vira uma métrica — antes só existia o `print` acima.
            let modelID = Self.modelID
            Task {
                await GenerationMetricsStore.shared.record(
                    GenerationMetrics(
                        engine: .mlx,
                        taskType: .modelLoad,
                        topic: "",
                        modelID: modelID,
                        isColdStart: true,
                        totalTimeMs: loadElapsedMs
                    )
                )
            }
        } catch {
            loadState = .failed(error.localizedDescription)
            throw error
        }
    }

    private func recordProgress(fraction: Double) {
        // Ignora callbacks tardios depois de pronto/falha.
        switch loadState {
        case .ready, .failed: return
        default: break
        }

        if fraction >= 1.0 {
            loadState = .loadingIntoMemory
            downloadSpeedBytesPerSecond = nil
            downloadETASeconds = nil
            return
        }

        loadState = .downloading(fraction: fraction)

        progressSamples.append((Date(), fraction))
        if progressSamples.count > 24 {
            progressSamples.removeFirst(progressSamples.count - 24)
        }

        guard let oldest = progressSamples.first, progressSamples.count >= 3 else { return }
        let elapsed = Date().timeIntervalSince(oldest.date)
        let deltaFraction = fraction - oldest.fraction
        guard elapsed > 0.5, deltaFraction > 0 else { return }

        let fractionPerSecond = deltaFraction / elapsed
        let bytesPerSecond = fractionPerSecond * Double(Self.estimatedModelBytes)

        // Média móvel simples pra suavizar a leitura na UI.
        if let previous = downloadSpeedBytesPerSecond {
            downloadSpeedBytesPerSecond = previous * 0.7 + bytesPerSecond * 0.3
        } else {
            downloadSpeedBytesPerSecond = bytesPerSecond
        }
        downloadETASeconds = (1.0 - fraction) / fractionPerSecond
    }

    // MARK: - Geração

    /// Gera UM rascunho de texto livre.
    ///
    /// `topic`/`taskType` (PLAN_00) são só para instrumentação — identificam
    /// a métrica gerada por esta chamada, sem afetar o prompt nem o
    /// resultado.
    /// `cacheTopic` (PLAN_11): quando presente, liga o cache de prefixo para
    /// este tópico — as chamadas seguintes com o MESMO `cacheTopic` e o mesmo
    /// `systemPrompt` reaproveitam o prefill do trecho inicial comum.
    /// Deliberadamente separado de `topic` (que é só instrumentação, e por
    /// isso tem default `""`): ligar cache é uma decisão de comportamento, e
    /// deve ser explícita no chamador.
    func generateQuestionDraft(
        systemPrompt: String,
        promptContext: String,
        topic: String = "",
        taskType: GenerationMetrics.TaskType = .hardQuizDraft,
        cacheTopic: String? = nil,
        temperatureOverride: Float? = nil
    ) async throws -> String {
        try await generate(systemPrompt: systemPrompt, promptContext: promptContext, maxTokens: 350, topic: topic, taskType: taskType, batchSize: 1, cacheTopic: cacheTopic, temperatureOverride: temperatureOverride)
    }

    /// Gera N rascunhos numa ÚNICA chamada ao modelo (um prefill só), com os
    /// itens separados por `Self.itemSeparator`. O prompt chamador é
    /// responsável por pedir os itens separados por essa linha; aqui a
    /// resposta é fatiada e higienizada. Pode devolver menos itens que
    /// `count` — o chamador decide se completa um a um.
    func generateQuestionDrafts(
        systemPrompt: String,
        promptContext: String,
        count: Int,
        topic: String = "",
        taskType: GenerationMetrics.TaskType = .hardQuizDraft,
        cacheTopic: String? = nil
    ) async throws -> [String] {
        guard count > 1 else {
            return [try await generateQuestionDraft(systemPrompt: systemPrompt, promptContext: promptContext, topic: topic, taskType: taskType, cacheTopic: cacheTopic)]
        }

        let output = try await generate(
            systemPrompt: systemPrompt,
            promptContext: promptContext,
            maxTokens: 300 * count + 50,
            topic: topic,
            taskType: taskType,
            batchSize: count,
            cacheTopic: cacheTopic
        )

        let items = output
            .components(separatedBy: Self.itemSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 20 } // descarta sobras/linhas vazias do split

        print("MLX batch: pedidos \(count) rascunhos, obtidos \(items.count).")
        return items
    }

    // MARK: - Pré-aquecimento (Plano V3 4.3)

    /// Verifica, só com FileManager (SEM rede), se os pesos do modelo já
    /// parecem estar baixados no cache local usado pelo `MLXLMCommon`
    /// (`~/Library/Caches/huggingface/models/...`). Heurística conservadora:
    /// só considera "em cache" se encontrar pelo menos um arquivo
    /// `.safetensors` de verdade dentro do diretório esperado — só o
    /// diretório existir (ou só um config.json) não é garantia de download
    /// completo, e um falso positivo aqui dispararia download não
    /// solicitado, exatamente o que este item do plano proíbe.
    ///
    /// ⚠️ Bug corrigido (Plano V5): esta função checava `Documents/...`,
    /// mas `MLXService.performLoad` chama `LLMModelFactory.shared.
    /// loadContainer` SEM passar um `hub:` customizado — então quem baixa de
    /// verdade é o `defaultHubApi` do MLXLMCommon, que usa
    /// `.cachesDirectory`, não `.documentDirectory` (confirmado lendo o
    /// source do MLXLMCommon/Load.swift). Com o path errado, esta função
    /// NUNCA detectava o modelo como já baixado — o pré-aquecimento em
    /// background no launch (`prewarmIfCached`) silenciosamente não fazia
    /// nada mesmo com o modelo 100% baixado (o carregamento normal via
    /// `loadModel()` continuava funcionando, só perdia a otimização).
    ///
    /// Checa 3 layouts candidatos, já que a forma exata como o HubApi
    /// grava o nome da pasta do repo (`org/repo` aninhado, `org--repo`
    /// achatado, ou `org%2Frepo` com a barra percent-encoded por
    /// `URL.appending(component:)`) não está 100% documentada nesta versão.
    static func isModelLikelyCached() -> Bool {
        guard let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return false
        }
        let modelsRoot = cachesDir.appendingPathComponent("huggingface", isDirectory: true).appendingPathComponent("models", isDirectory: true)

        let components = modelID.split(separator: "/").map(String.init)
        guard components.count == 2 else { return false }
        let org = components[0], repo = components[1]

        let candidateDirs = [
            modelsRoot.appendingPathComponent(org, isDirectory: true).appendingPathComponent(repo, isDirectory: true),
            modelsRoot.appendingPathComponent("\(org)--\(repo)", isDirectory: true),
            modelsRoot.appendingPathComponent("\(org)%2F\(repo)", isDirectory: true),
        ]

        return candidateDirs.contains { directoryContainsSafetensors($0) }
    }

    private static func directoryContainsSafetensors(_ url: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return false
        }
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "safetensors" {
            return true
        }
        return false
    }

    /// Chamado no launch do app (ver RootTabView). Se — e SÓ se — o modelo
    /// já parece estar em cache local, carrega os pesos na RAM em
    /// background, sem esperar o usuário abrir um tópico difícil pela
    /// primeira vez. Sem cache local detectado, não faz absolutamente
    /// nada — nenhum download é disparado por conta própria.
    func prewarmIfCached() {
        // A pasta de override local também conta como "em cache" — sem
        // isso, o pré-aquecimento no launch nunca dispararia no caminho de
        // pesos baixados manualmente.
        guard Self.isModelLikelyCached() || Self.localModelOverrideDirectory != nil else {
            print("⚪️ MLXService: nenhum cache local detectado pro modelo — sem pré-aquecimento (download só sob demanda).")
            return
        }
        print("🟢 MLXService: modelo parece estar em cache local — pré-aquecendo em background.")
        // .utility, não .background: QoS .background é estrangulado pelo
        // macOS (I/O e CPU despriorizados) e deixava a carga dos pesos
        // visivelmente mais lenta do que o necessário.
        Task.detached(priority: .utility) {
            try? await MLXService.shared.loadModel()
        }
    }

    /// Resultado da preparação do prompt dentro de `container.perform` — o
    /// stream em si mais o que precisamos saber sobre o cache de prefixo
    /// para instrumentar (PLAN_11) e para guardar o cache primed DEPOIS que
    /// a geração terminar.
    ///
    /// `nonisolated` + `Sendable`: é construído DENTRO do closure `@Sendable`
    /// de `ModelContainer.perform` (fora do MainActor) e devolvido para o
    /// MainActor. Sem isso ele herdaria o `SWIFT_DEFAULT_ACTOR_ISOLATION =
    /// MainActor` do projeto e não poderia ser criado lá dentro. Todos os
    /// campos são Sendable de fato (`Generation` é `Sendable`; o
    /// `TopicPromptCache` documenta o próprio `@unchecked`).
    private nonisolated struct PreparedGeneration: Sendable {
        let stream: AsyncStream<Generation>
        let cacheState: GenerationMetrics.CacheState
        /// Tokens de prefixo reaproveitados do cache (0 num miss, `nil` se o
        /// cache não se aplica a esta chamada).
        let cachedPrefixTokenCount: Int?
        /// Preenchido só num MISS: o cache que esta chamada acabou de criar,
        /// para ser guardado no store assim que a geração terminar (aí sim
        /// ele contém o prompt inteiro já processado).
        let primedToStore: TopicPromptCache?
    }

    private func generate(
        systemPrompt: String,
        promptContext: String,
        maxTokens: Int,
        topic: String = "",
        taskType: GenerationMetrics.TaskType = .hardQuizDraft,
        batchSize: Int = 1,
        cacheTopic: String? = nil,
        temperatureOverride: Float? = nil
    ) async throws -> String {
        guard let container = modelContainer else {
            throw NSError(domain: "MLXService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Modelo MLX não carregado."])
        }

        // PLAN_11 — `temperatureOverride` existe por causa do TESTE DE
        // EQUIVALÊNCIA exigido por §7.4 ("o texto gerado com e sem cache
        // deveria ser idêntico").
        //
        // Com a temperatura de produção (0.3), `GenerateParameters.sampler()`
        // devolve um `CategoricalSampler`, que carrega o próprio
        // `MLXRandom.RandomState` criado na hora — ou seja, DUAS execuções do
        // mesmo prompt, sem cache nenhum, já produzem textos diferentes. Um
        // teste de equivalência nessas condições mediria o amostrador, não o
        // cache.
        //
        // Com `temperature: 0`, o mesmo `sampler()` devolve `ArgMaxSampler`,
        // que é determinístico — aí uma diferença de texto entre com/sem
        // cache aponta de verdade para o cache. Só o benchmark passa este
        // parâmetro; o caminho de produção continua em 0.3.
        let generateParams = GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperatureOverride ?? 0.3,
            repetitionPenalty: 1.1
        )

        // PLAN_11 — chave do cache de prefixo. `nil` desliga o cache para
        // esta chamada (flag global desligada, ou chamador que não passou
        // `cacheTopic` — ex.: o benchmark de modelos, que quer medir prefill
        // limpo).
        let cacheKey: String? = {
            guard Self.isPromptCacheEnabled, let cacheTopic, !cacheTopic.isEmpty else { return nil }
            return MLXPromptCacheStore.cacheKey(topic: cacheTopic, systemPrompt: systemPrompt, modelID: Self.modelID)
        }()

        // `let` (e não `var`) de propósito: esta variável é capturada pelo
        // closure `@Sendable` de `container.perform` logo abaixo, e capturar
        // uma `var` mutável em código que roda concorrentemente é erro de
        // concorrência no Swift. A inicialização adiada em ramos mantém o
        // valor imutável.
        let existingPrimed: TopicPromptCache?
        if let cacheKey {
            existingPrimed = await MLXPromptCacheStore.shared.cached(matching: cacheKey)
        } else {
            existingPrimed = nil
        }

        // PLAN_00: "1ª geração depois do load" — aproximação de cold start
        // de INFERÊNCIA (compilação de kernels Metal), distinta do cold
        // start de CARREGAMENTO DE PESOS (isColdStart do modelLoad em
        // performLoad). Lida/marcada ANTES da chamada, já que o valor real
        // que nos interessa é "esta chamada aconteceu antes de qualquer
        // outra geração desde o load".
        let isColdStart = !hasGeneratedSinceLoad
        hasGeneratedSinceLoad = true

        // PLAN_12 — `GPU.snapshot()` (API real: `activeMemory`, `cacheMemory`,
        // `peakMemory`, todos em bytes) antes/depois desta geração. Usamos
        // `activeMemory + cacheMemory` como uma única cifra de "memória GPU
        // em uso neste instante" (memória ativa da computação + buffers
        // mantidos no pool de reuso) — é o par de campos que
        // `GenerationMetrics.memoryBeforeBytes`/`memoryAfterBytes` já previa
        // desde o PLAN_00, deixados `nil` até este plano. Não afeta o
        // comportamento de geração em nada — só leitura.
        let memoryBefore = GPU.snapshot()
        let memoryBeforeBytes = memoryBefore.activeMemory + memoryBefore.cacheMemory

        let start = Date()
        let prepared = try await container.perform { context -> PreparedGeneration in
            // PLAN_03: antes disso, o `system`/`user` eram concatenados à mão
            // numa string ChatML (`<|im_start|>...`) e passados como o
            // CONTEÚDO de uma única mensagem `.user` via `UserInput(prompt:)`.
            // Só que `UserInput(prompt:)` internamente já converte essa
            // string em `.chat([.user(prompt, ...)])` — ou seja, o processor
            // do modelo aplicava o template REAL por cima da string ChatML
            // já escrita à mão, duplicando/aninhando marcadores e
            // desperdiçando tokens. `UserInput(chat:)` com `Chat.Message`
            // estruturados deixa a biblioteca aplicar o template do modelo
            // (Qwen2.5-Coder-Instruct) uma única vez, do jeito certo.
            //
            // Teste de equivalência (§19.4) rodado nesta sessão: mesmo tópico
            // ("NavigationStack", codeExampleDraft) — string manual = 977
            // tokens de prompt, UserInput(chat:) = 948 tokens (-29, ~3%),
            // sem regressão perceptível de qualidade na saída. Confirma a
            // hipótese de duplo-template do F5/§19.2.
            let userInput = UserInput(chat: [
                .system(systemPrompt),
                .user(promptContext),
            ])
            let input = try await context.processor.prepare(input: userInput)

            // ── PLAN_11 — cache de prefixo ────────────────────────────────
            // Sem chave (ou com entrada multimodal, que este fluxo não usa),
            // o comportamento é literalmente o de antes: `cache: nil`.
            guard let cacheKey, input.text.mask == nil, input.image == nil, input.video == nil else {
                return PreparedGeneration(
                    stream: try MLXLMCommon.generate(input: input, parameters: generateParams, context: context),
                    cacheState: .notApplicable,
                    cachedPrefixTokenCount: nil,
                    primedToStore: nil
                )
            }

            let fullTokens = input.text.tokens.asArray(Int.self)

            // ── HIT ───────────────────────────────────────────────────────
            // Mede o prefixo comum EM TOKENS com o que já está primed e
            // manda para o modelo só o que sobra. Passar o prompt inteiro
            // aqui seria o bug descrito no topo de MLXPromptCache.swift.
            if let existingPrimed {
                let common = MLXPromptCacheStore.sharedPrefixLength(existingPrimed.prefixTokens, fullTokens)
                // Deixa SEMPRE pelo menos 1 token de sufixo: o
                // `TokenIterator` precisa de algo para processar e para tirar
                // o primeiro logit. Um prompt 100% cacheado (raro, mas
                // possível se a mesma chamada se repetir) viraria um input
                // vazio.
                let reusable = min(common, fullTokens.count - 1)

                if reusable > 0, let clonedCache = existingPrimed.clone(upTo: reusable) {
                    // `LMInput(tokens:)` é o init público usado pela própria
                    // lib (ver o `generate` legado em Evaluate.swift). `mask`
                    // fica nil, o que é correto aqui: o guard acima já provou
                    // que o input original não tinha máscara.
                    let suffix = LMInput(tokens: input.text.tokens[reusable...])
                    let stream = try MLXLMCommon.generate(
                        input: suffix, cache: clonedCache, parameters: generateParams, context: context
                    )
                    return PreparedGeneration(
                        stream: stream,
                        cacheState: .hit,
                        cachedPrefixTokenCount: reusable,
                        primedToStore: nil
                    )
                }
            }

            // ── MISS ──────────────────────────────────────────────────────
            // Esta chamada roda o prompt inteiro, como sempre — mas com um
            // cache NOSSO, que fica guardado depois em vez de ser jogado
            // fora.
            //
            // DESVIO (proposital) de SOLUTIONS_PLAN.md §7.2: o plano previa
            // um passo `prefillOnly(prefix:)` separado, e marcava com ⚠️ a
            // dúvida de "`TokenIterator` aceita `maxTokens: 0`?". Esse passo
            // é desnecessário. A 1ª chamada do tópico JÁ processa o prefixo
            // — basta não descartar o cache dela. Isso elimina de uma vez o
            // item que precisava de protótipo, a passada extra de prefill e
            // o token descartado (que, aliás, teria que ser excluído do
            // prefixo reutilizável, por ser um token AMOSTRADO e não um
            // token de prompt).
            let freshCache = makePromptCache(model: context.model, parameters: generateParams)
            let simpleCaches = freshCache.compactMap { $0 as? KVCacheSimple }

            // `newCache` devolve `KVCacheSimple` quando `maxKVSize == nil`
            // (é o nosso caso — ver `GenerateParameters` acima). Se algum dia
            // deixar de ser (`RotatingKVCache` rotaciona e descarta tokens
            // antigos, então clonar por fatia não faria sentido), a decisão
            // segura é seguir sem cache em vez de clonar um tipo cujo
            // contrato de crescimento não conhecemos.
            guard !freshCache.isEmpty, simpleCaches.count == freshCache.count else {
                print("⚪️ PLAN_11: makePromptCache devolveu um tipo de cache não suportado — seguindo sem cache de prefixo.")
                return PreparedGeneration(
                    stream: try MLXLMCommon.generate(input: input, parameters: generateParams, context: context),
                    cacheState: .notApplicable,
                    cachedPrefixTokenCount: nil,
                    primedToStore: nil
                )
            }

            let stream = try MLXLMCommon.generate(
                input: input, cache: freshCache, parameters: generateParams, context: context
            )
            return PreparedGeneration(
                stream: stream,
                cacheState: .miss,
                cachedPrefixTokenCount: 0,
                // Mesmas instâncias que o `TokenIterator` vai preencher: ao
                // fim da geração elas contêm o prompt inteiro (e mais os
                // tokens gerados, que `clone(upTo:)` nunca alcança porque
                // `reusableTokenCount` é o tamanho do PROMPT).
                primedToStore: TopicPromptCache(key: cacheKey, prefixTokens: fullTokens, caches: simpleCaches)
            )
        }

        var outputText = ""
        var completionInfo: GenerateCompletionInfo?
        for try await generation in prepared.stream {
            switch generation {
            case .chunk(let chunk):
                outputText.append(chunk)
            case .info(let info):
                // PLAN_00 (F9): API real do mlx-swift-examples devolve
                // promptTokenCount/generationTokenCount/promptTime/
                // generateTime/tokensPerSecond prontos — isso substitui
                // diretamente a antiga métrica de "chars/s", que era só uma
                // aproximação (caracteres, não tokens).
                completionInfo = info
            case .toolCall:
                break // sem suporte a tool calls neste fluxo de rascunhos.
            }
        }

        let elapsedMs = Date().timeIntervalSince(start) * 1000

        // PLAN_11 — só agora, com o stream drenado, o cache contém o prompt
        // inteiro processado. Guardar antes disso salvaria um cache pela
        // metade (o `AsyncStream` só roda durante o consumo — mesma razão
        // pela qual o snapshot de memória do PLAN_12 é tirado aqui embaixo).
        if let primed = prepared.primedToStore {
            await MLXPromptCacheStore.shared.store(primed)
        }

        // PLAN_12 — snapshot "depois", mesmo par de campos do "antes" acima.
        // Tirado DEPOIS de drenar o stream (não logo após `container.perform`
        // retornar) porque a geração de fato acontece durante o consumo do
        // `AsyncSequence` — antes disso o snapshot capturaria só o prefill.
        let memoryAfter = GPU.snapshot()
        let memoryAfterBytes = memoryAfter.activeMemory + memoryAfter.cacheMemory

        let memoryDeltaMB = Double(memoryAfterBytes - memoryBeforeBytes) / 1_048_576

        // PLAN_11 — num HIT, `info.promptTokenCount` conta só o SUFIXO que
        // passou pelo TokenIterator. Logar os dois números lado a lado evita
        // ler "o prompt encolheu" onde na verdade é "o prefixo veio do
        // cache".
        let cacheSuffix: String = {
            switch prepared.cacheState {
            case .hit:
                let reused = prepared.cachedPrefixTokenCount ?? 0
                return " · prefixo em cache HIT (\(reused) tokens reaproveitados)"
            case .miss:
                return " · prefixo em cache MISS (primed para as próximas chamadas deste tópico)"
            case .notApplicable:
                return ""
            }
        }()

        if let info = completionInfo {
            print("⏱️ MLXService.generate: \(info.summary().replacingOccurrences(of: "\n", with: " · ")) · GPU Δ\(String(format: "%.1f", memoryDeltaMB))MB (cache=\(memoryAfter.cacheMemory / 1_048_576)MB)\(cacheSuffix)")
        } else {
            // Defensivo: a variante em stream sempre emite `.info` ao
            // terminar (ver Evaluate.swift), mas se por algum motivo não
            // emitir, ainda registramos o tempo total sem os tokens/s.
            print("⏱️ MLXService.generate: \(String(format: "%.1f", elapsedMs / 1000))s, \(outputText.count) chars (sem GenerateCompletionInfo).")
        }

        let metric = GenerationMetrics(
            engine: .mlx,
            taskType: taskType,
            topic: topic,
            modelID: Self.modelID,
            isColdStart: isColdStart,
            inputTokenCount: completionInfo?.promptTokenCount,
            outputTokenCount: completionInfo?.generationTokenCount,
            timeToFirstTokenMs: completionInfo.map { $0.promptTime * 1000 },
            decodeTimeMs: completionInfo.map { $0.generateTime * 1000 },
            totalTimeMs: elapsedMs,
            tokensPerSecond: completionInfo?.tokensPerSecond,
            batchSize: batchSize,
            promptCacheState: prepared.cacheState,
            cachedPrefixTokenCount: prepared.cachedPrefixTokenCount,
            memoryBeforeBytes: memoryBeforeBytes,
            memoryAfterBytes: memoryAfterBytes
        )
        Task { await GenerationMetricsStore.shared.record(metric) }

        return outputText
    }
}
