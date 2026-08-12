//
//  GenerationOrchestrator.swift
//  SwiftStudyCoach
//
//  Plano V3 4.2 — fila serial por motor de geração (Foundation Models e
//  MLX são filas SEPARADAS, e portanto rodam EM PARALELO entre si — é
//  exatamente assim que TopicRepository já usa as duas trilhas hoje), com
//  3 níveis de prioridade: trabalho que o usuário está esperando na tela
//  agora vem sempre antes de trabalho preparando a próxima sessão, que vem
//  sempre antes de enchimento de pool em segundo plano.
//
//  Isso substitui os retries de contenção espalhados pelo StudyGenerator
//  (esperar 2s e tentar de novo quando duas chamadas concorrentes brigam
//  pelo mesmo motor) por uma garantia estrutural: só existe UMA chamada
//  em voo por motor a qualquer momento, então `rateLimited` /
//  `concurrentRequests` deixam de acontecer por design, não por sorte de
//  retry. Também dá um ponto único de cancelamento — jobs enfileirados
//  (ainda não iniciados) de uma prioridade podem ser descartados de uma vez,
//  por exemplo pra priorizar um pedido novo do usuário sobre enchimento de
//  pool antigo que ainda nem começou a rodar.
//

import Foundation

actor GenerationOrchestrator {

    static let shared = GenerationOrchestrator()

    enum Engine {
        case foundationModels
        case mlx
    }

    /// Ordem crescente = prioridade decrescente (userBlocking roda primeiro).
    enum Priority: Int, Comparable {
        case userBlocking = 0   // usuário parado na tela esperando isso agora
        case nextSession = 1    // preparando a próxima sessão (top-up pós-quiz)
        case poolFill = 2       // enchimento de pool em segundo plano, sem pressa

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private final class Job {
        let priority: Priority
        var isCancelled = false
        let run: () async -> Void

        init(priority: Priority, run: @escaping () async -> Void) {
            self.priority = priority
            self.run = run
        }
    }

    private var fmQueue: [Job] = []
    private var mlxQueue: [Job] = []
    private var fmWorkerActive = false
    private var mlxWorkerActive = false

    private init() {}

    // MARK: - API pública

    /// Enfileira `operation` no motor indicado, na prioridade indicada, e
    /// espera sua vez rodar (uma chamada de cada vez por motor). FM e MLX
    /// são filas independentes — uma não bloqueia a outra.
    @discardableResult
    func schedule<T>(
        engine: Engine,
        priority: Priority,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let job = Job(priority: priority) {
                do {
                    let result = try await operation()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            enqueue(job, engine: engine)
        }
    }

    /// Ponto único de cancelamento: descarta jobs de uma prioridade que
    /// AINDA NÃO começaram a rodar (nunca interrompe um job em execução —
    /// isso exigiria suporte a cancelamento cooperativo dentro do próprio
    /// FoundationModels/MLX, que não expõem isso hoje). Útil, por exemplo,
    /// pra abandonar enchimento de pool (`.poolFill`) de tópicos antigos
    /// quando o usuário abre um tópico novo e precisa de geração
    /// user-blocking com prioridade real.
    func cancelPending(priority: Priority) {
        for job in fmQueue where job.priority == priority { job.isCancelled = true }
        for job in mlxQueue where job.priority == priority { job.isCancelled = true }
    }

    // MARK: - Internals

    private func enqueue(_ job: Job, engine: Engine) {
        switch engine {
        case .foundationModels:
            insert(job, into: &fmQueue)
            startFMWorkerIfNeeded()
        case .mlx:
            insert(job, into: &mlxQueue)
            startMLXWorkerIfNeeded()
        }
    }

    /// Insere mantendo a fila ordenada por prioridade (menor rawValue
    /// primeiro), FIFO entre jobs da mesma prioridade — um job
    /// user-blocking enfileirado agora sempre passa na frente de um
    /// pool-fill que já estava esperando, mas nunca na frente de outro
    /// user-blocking que chegou antes dele.
    private func insert(_ job: Job, into queue: inout [Job]) {
        let index = queue.firstIndex { $0.priority.rawValue > job.priority.rawValue } ?? queue.count
        queue.insert(job, at: index)
    }

    /// Prioridade FIXA (.userInitiated) pros workers — `Task { }` sem
    /// prioridade herda a de quem enfileirou o PRIMEIRO job do ciclo, então
    /// um worker acordado por um job de poolFill (task .utility) rodava o
    /// loop inteiro de geração estrangulado pelo QoS baixo — inclusive jobs
    /// user-blocking que entrassem na fila depois (inversão de prioridade).
    /// Era isso que fazia o crescimento em background parecer bem mais
    /// lento que a mesma geração no caminho bloqueante. A URGÊNCIA entre
    /// jobs continua sendo responsabilidade exclusiva da ordenação da fila
    /// (Priority); o QoS de execução é sempre o mesmo.
    private func startFMWorkerIfNeeded() {
        guard !fmWorkerActive else { return }
        fmWorkerActive = true
        Task(priority: .userInitiated) { await runFMWorker() }
    }

    private func startMLXWorkerIfNeeded() {
        guard !mlxWorkerActive else { return }
        mlxWorkerActive = true
        Task(priority: .userInitiated) { await runMLXWorker() }
    }

    private func runFMWorker() async {
        while !fmQueue.isEmpty {
            let job = fmQueue.removeFirst()
            if job.isCancelled { continue }
            await job.run()
        }
        fmWorkerActive = false
    }

    private func runMLXWorker() async {
        while !mlxQueue.isEmpty {
            let job = mlxQueue.removeFirst()
            if job.isCancelled { continue }
            await job.run()
        }
        mlxWorkerActive = false
    }
}
