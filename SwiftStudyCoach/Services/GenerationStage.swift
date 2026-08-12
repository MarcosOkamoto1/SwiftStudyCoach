//
//  GenerationStage.swift
//  SwiftStudyCoach
//
//  PLAN_06 — estado OBSERVÁVEL da geração de um tópico (SOLUTIONS_PLAN.md
//  §16.1). Antes desta mudança a `TopicStudyView` mostrava um texto fixo
//  ("Gerando conteúdo de '<tópico>'...") durante todo o carregamento, sem
//  nenhum sinal de progresso — o usuário não tinha como distinguir "está
//  gerando o resumo" de "travou".
//
//  Os casos batem 1:1 com as fronteiras que `TopicRepository.timed` e
//  `StudyGenerator.timed` JÁ delimitam em `print` — isto aqui não é um
//  design novo, é dar nome observável a etapas que o código já tinha
//  instrumentadas em texto.
//
//  Segue o mesmo padrão de `MLXService.loadState` (`@Observable` +
//  `enum: Equatable`, MLXService.swift:76-84): a View só referencia o valor
//  e reage sozinha, sem polling.
//

import Foundation
import Observation

/// Etapa atual da geração de UM tópico.
///
/// Fase 1 (síncrona, bloqueia a tela): `.indexing` → `.generatingSummary` →
/// `.generatingQuizEasy` → `.generatingQuizMedium` → `.generatingCodeExample`
/// → `.ready`.
/// Fase 2 (background, nunca aguardada pelo caminho síncrono):
/// `.upgradingCodeExample`, `.generatingHardQuiz`,
/// `.generatingCodeAnalysis` → `.backgroundComplete`.
///
/// As trilhas de Fase 2 rodam EM PARALELO, então esses três estágios não
/// formam uma sequência — quem termina publica o próximo estado com
/// `revert(from:to:)`, nunca com `set`, pra não apagar o estágio de uma
/// trilha que ainda está rodando.
///
/// `.failed(step:)` tem significado diferente conforme a fase (§16.5):
/// numa etapa de Fase 1 a tela cai em `errorState` (não há conteúdo
/// mostrável); numa etapa de Fase 2 a tela CONTINUA renderizando o
/// conteúdo válido da Fase 1 e só mostra um aviso silencioso.
enum GenerationStage: Equatable, Sendable {
    case idle
    /// `ensureReady()`/recuperação de contexto RAG em andamento. Raro depois
    /// do PLAN_04 (o caminho de tópico exato é síncrono e não depende dos
    /// embeddings), mas mantido porque o fallback fuzzy ainda existe.
    case indexing
    case generatingSummary
    case generatingQuizEasy
    case generatingQuizMedium
    /// FM-only, síncrono (PLAN_06 / D1) — ZERO MLX.
    case generatingCodeExample
    /// Fase 1 persistida, tela mostrável.
    case ready
    /// Background (PLAN_07) — pipeline MLX→crítica→formatação revisando o
    /// exemplo de código que a tela JÁ está mostrando. Pode durar bastante
    /// (inclui download/carga do modelo de 7B na 1ª execução); o conteúdo da
    /// Fase 1 permanece válido e visível o tempo todo.
    case upgradingCodeExample
    case generatingHardQuiz
    case generatingCodeAnalysis
    case backgroundComplete
    case failed(step: String)

    /// `true` enquanto a Fase 1 ainda não terminou — nesse intervalo a tela
    /// está em `isLoading` e não há nada de útil pra renderizar.
    var isPhase1: Bool {
        switch self {
        case .idle, .indexing, .generatingSummary, .generatingQuizEasy,
             .generatingQuizMedium, .generatingCodeExample:
            return true
        case .ready, .upgradingCodeExample, .generatingHardQuiz,
             .generatingCodeAnalysis, .backgroundComplete, .failed:
            return false
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// Texto do spinner da `TopicStudyView` durante a Fase 1 (§16.3 — o ganho
    /// de percepção vem daqui + da Fase 1 ser curta, não de skeleton screens,
    /// que foram descartados explicitamente).
    func loadingText(topicName: String) -> String {
        switch self {
        case .idle:
            return "Preparando \"\(topicName)\"..."
        case .indexing:
            return "Buscando a documentação de \"\(topicName)\"..."
        case .generatingSummary:
            return "Gerando o resumo de \"\(topicName)\"..."
        case .generatingQuizEasy:
            return "Preparando as perguntas fáceis..."
        case .generatingQuizMedium:
            return "Preparando as perguntas de nível médio..."
        case .generatingCodeExample:
            return "Escrevendo o exemplo de código..."
        case .ready, .upgradingCodeExample, .generatingHardQuiz,
             .generatingCodeAnalysis, .backgroundComplete:
            return "Abrindo \"\(topicName)\"..."
        case .failed(let step):
            return "Falha ao gerar \(step)."
        }
    }

    /// Texto do indicador compacto que aparece JUNTO do artigo já
    /// renderizado (§16.4) — `nil` quando não há nada acontecendo em
    /// background que valha comunicar.
    var backgroundText: String? {
        switch self {
        case .upgradingCodeExample:
            return "revisando o exemplo de código"
        case .generatingHardQuiz:
            return "gerando perguntas difíceis"
        case .generatingCodeAnalysis:
            return "gerando análise de código"
        case .failed(let step):
            // §16.5: aviso silencioso, nunca um errorState — o conteúdo da
            // Fase 1 continua válido e visível.
            return "não foi possível concluir \(step)"
        case .idle, .indexing, .generatingSummary, .generatingQuizEasy,
             .generatingQuizMedium, .generatingCodeExample, .ready,
             .backgroundComplete:
            return nil
        }
    }
}

/// Guarda o `GenerationStage` corrente POR NOME DE TÓPICO.
///
/// É um dicionário (e não um único valor global) de propósito: o
/// crescimento de pool em background de um tópico pode estar rodando
/// enquanto o usuário abre OUTRO tópico — com um valor único, o background
/// de um sobrescreveria o loading do outro e a tela mostraria texto errado.
///
/// Segue exatamente o formato de `MLXService` (`@Observable final class` +
/// `static let shared`, sem isolamento de ator): a View lê direto no `body`
/// e o Observation cuida do re-render. As escritas vindas de background
/// passam por `update(_:for:)`, que faz o hop pro MainActor — é lá que a
/// mutação de fato acontece, que é o que o SwiftUI espera.
@Observable
final class GenerationStageStore {

    static let shared = GenerationStageStore()

    private(set) var stages: [String: GenerationStage] = [:]

    private init() {}

    func stage(for topicName: String) -> GenerationStage {
        stages[topicName] ?? .idle
    }

    /// Chamada direto pelo `TopicRepository` (que já é `@MainActor`) durante
    /// a Fase 1. Para código de background, use `update(_:for:)`.
    func set(_ stage: GenerationStage, for topicName: String) {
        guard stages[topicName] != stage else { return }
        stages[topicName] = stage
        // Mesmo hábito de log com prefixo emoji do resto do projeto
        // (SOLUTIONS_PLAN.md §9.3) — aditivo ao estado observável.
        print("🎬 [GenerationStage] '\(topicName)' → \(stage)")
    }

    /// Troca `expected` por `replacement` SÓ se a etapa corrente ainda for
    /// `expected` — evita que uma trilha de Fase 2 que terminou apague o
    /// estágio que OUTRA trilha (rodando em paralelo) já publicou.
    func revert(from expected: GenerationStage, to replacement: GenerationStage, for topicName: String) {
        guard stage(for: topicName) == expected else { return }
        set(replacement, for: topicName)
    }

    /// Ponto de entrada para as trilhas de Fase 2 (`Task.detached` /
    /// `nonisolated static` do `TopicRepository`), que rodam fora do
    /// MainActor.
    static func update(_ stage: GenerationStage, for topicName: String) {
        Task { @MainActor in
            shared.set(stage, for: topicName)
        }
    }
}
