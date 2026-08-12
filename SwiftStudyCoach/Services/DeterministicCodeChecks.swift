//
//  DeterministicCodeChecks.swift
//  SwiftStudyCoach
//
//  PLAN_08 — Estratégia D, elemento de C combinado com B (SOLUTIONS_PLAN.md
//  F30/§20/D1, parte final): checks estáticos/regex baratos sobre o exemplo
//  de código FM-only da Fase 1, usados para decidir a PRIORIDADE (nunca a
//  EXECUÇÃO) do upgrade MLX que `PLAN_07` já enfileira em background.
//
//  Se algum check aqui falhar, quem chama (`TopicRepository.startPhase2`)
//  sobe a prioridade do upgrade de `.poolFill` para `.nextSession` — mais
//  cedo na fila do `GenerationOrchestrator`, mas NUNCA pulando a crítica
//  MLX. Pelo menos 2 causas de bug já documentadas (parâmetro de
//  inicializador inexistente, walkthrough dessincronizado do código —
//  SOLUTIONS_PLAN.md §20.2) não são verificáveis sem modelo: um gate que
//  PULASSE a crítica quando estes checks passarem seria uma regressão de
//  segurança não autorizada por este plano. `DeterministicCodeChecks` só
//  reordena fila, nunca substitui a crítica por heurística.
//
//  Deliberadamente NÃO usa `swiftc` real via `Process` (decisão explícita,
//  SOLUTIONS_PLAN.md §20.4): sintetizar um harness de compilação para
//  fragmentos soltos tem dificuldade real e ganho marginal não evidenciado
//  sobre checks + crítica já propostos.
//

import Foundation

enum DeterministicCodeChecks {

    struct Result {
        let passed: Bool
        let flags: [String]
    }

    /// Roda todos os checks determinísticos sobre `code` (o exemplo FM-only
    /// da Fase 1) e devolve o resultado agregado. `passed == true` só
    /// significa "nenhum check barato pegou nada" — não é uma garantia de
    /// correção (ver comentário do arquivo).
    static func evaluate(_ code: String) -> Result {
        var flags: [String] = []
        if StudyGenerator.looksTruncated(code) { flags.append("truncamento") }
        if hasActionlessControl(code) { flags.append("controle sem action") }
        if hasNavigationDestinationValueLiteral(code) { flags.append("navigationDestination com valor") }
        if hasStateObjectOnValueType(code) { flags.append("StateObject em tipo de valor") }
        return Result(passed: flags.isEmpty, flags: flags)
    }

    // MARK: - Checks individuais

    /// `Button`/`Toggle`/`NavigationLink` sem `action:`/closure. Heurística
    /// sintática (não é um parser real de Swift): procura a chamada do
    /// controle e verifica se ela é imediatamente seguida por `{` (trailing
    /// closure) ou contém `action:`/`isOn:`/`destination:`/`value:` dentro
    /// dos parênteses. Pode ter falso positivo com multi-linha incomum —
    /// aceitável para uma heurística barata que só decide prioridade.
    static func hasActionlessControl(_ code: String) -> Bool {
        let controls = ["Button", "Toggle", "NavigationLink"]
        for control in controls {
            guard let regex = try? NSRegularExpression(pattern: "\\b\(control)\\s*\\(") else { continue }
            let nsCode = code as NSString
            let matches = regex.matches(in: code, range: NSRange(location: 0, length: nsCode.length))
            for match in matches {
                guard let callRange = matchingParenRange(in: nsCode, openParenEnd: match.range.location + match.range.length - 1) else {
                    continue
                }
                let callArgs = nsCode.substring(with: callRange)
                let hasActionKeyword = ["action:", "isOn:", "destination:", "value:", "role:", "systemImage:"].contains { callArgs.contains($0) }
                if hasActionKeyword { continue }

                // Sem palavra-chave de ação dentro dos parênteses: só é
                // "sem ação" de verdade se também não houver um trailing
                // closure `{ ... }` logo depois do `)`.
                let afterParen = callRange.location + callRange.length
                var cursor = afterParen
                while cursor < nsCode.length, nsCode.substring(with: NSRange(location: cursor, length: 1)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cursor += 1
                }
                let hasTrailingClosure = cursor < nsCode.length && nsCode.substring(with: NSRange(location: cursor, length: 1)) == "{"
                if !hasTrailingClosure {
                    return true
                }
            }
        }
        return false
    }

    /// `.navigationDestination(for: 1)` / `.navigationDestination(for: "x")`
    /// — a API espera um TIPO (`Int.self`), nunca um literal numérico ou
    /// string. Literal válido nunca começa com dígito ou aspas.
    static func hasNavigationDestinationValueLiteral(_ code: String) -> Bool {
        let pattern = #"navigationDestination\(\s*for:\s*("|\d)"#
        return matches(pattern, in: code)
    }

    /// `@StateObject` sobre um tipo de VALOR conhecido (`Int`, `Bool`,
    /// `String`, `Double`, `NavigationPath`) — esses tipos usam `@State`,
    /// nunca `@StateObject` (que exige `ObservableObject`/`@Observable`).
    static func hasStateObjectOnValueType(_ code: String) -> Bool {
        let pattern = #"@StateObject[^\n]*\bvar\s+\w+\s*:\s*(Int|Bool|String|NavigationPath|Double)\b"#
        return matches(pattern, in: code)
    }

    // MARK: - Helpers

    private static func matches(_ pattern: String, in code: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: (code as NSString).length)
        return regex.firstMatch(in: code, range: range) != nil
    }

    /// Dado o índice do `(` de abertura de uma chamada, devolve o range
    /// (incluindo os parênteses) até o `)` correspondente, respeitando
    /// aninhamento e strings. `nil` se não fechar (código truncado — já
    /// pego por `looksTruncated` separadamente).
    private static func matchingParenRange(in nsCode: NSString, openParenEnd: Int) -> NSRange? {
        var depth = 0
        var inString = false
        var previous: Character = " "
        var index = openParenEnd
        let length = nsCode.length
        while index < length {
            let char = Character(nsCode.substring(with: NSRange(location: index, length: 1)))
            if char == "\"" && previous != "\\" { inString.toggle() }
            if !inString {
                if char == "(" { depth += 1 }
                if char == ")" {
                    depth -= 1
                    if depth == 0 {
                        return NSRange(location: openParenEnd, length: index - openParenEnd + 1)
                    }
                }
            }
            previous = char
            index += 1
        }
        return nil
    }
}

/// PLAN_08 — distribuição, por sessão, dos resultados dos checks
/// determinísticos: quantos tópicos passam limpo vs. disparam algum flag.
/// Útil para calibrar os regex no futuro e entender se a heurística está
/// pegando casos reais. Mesmo padrão in-memory/session-only de
/// `CodeExampleUpgradeStats` (`GenerationMetrics.swift`) — não é analytics
/// de produto, descartado ao fim da sessão.
actor DeterministicCodeChecksStats {

    static let shared = DeterministicCodeChecksStats()

    private(set) var passedCount = 0
    private(set) var failedCount = 0
    private(set) var flagCounts: [String: Int] = [:]

    private init() {}

    func record(_ result: DeterministicCodeChecks.Result, topic: String) {
        if result.passed {
            passedCount += 1
        } else {
            failedCount += 1
            for flag in result.flags { flagCounts[flag, default: 0] += 1 }
        }
        let total = passedCount + failedCount
        let flagsDescription = result.flags.isEmpty ? "nenhum" : result.flags.joined(separator: ", ")
        print("🧪 [checks determinísticos] '\(topic)' → \(result.passed ? "passou" : "reprovou") (flags: \(flagsDescription)) · \(passedCount)/\(total) passaram limpo até agora.")
    }

    func summaryLine() -> String {
        let total = passedCount + failedCount
        guard total > 0 else { return "checks determinísticos — nenhum registro ainda" }
        let flagsPart = flagCounts.isEmpty ? "" : " · flags: " + flagCounts.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        return "checks determinísticos — \(passedCount)/\(total) passaram limpo\(flagsPart)"
    }
}
