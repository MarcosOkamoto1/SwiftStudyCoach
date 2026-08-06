//
//  CodeBlockView.swift
//  SwiftStudyCoach
//
//  Reaproveita o estilo visual de `.code-block` do protótipo HTML: painel
//  com fundo `panel`, label superior com pontinho colorido, e um highlight
//  de sintaxe simples (baseado em tokens, não é um parser Swift de
//  verdade) — suficiente pra deixar o snippet legível.
//

import SwiftUI
import Foundation

struct CodeBlockView: View {
    let label: String
    let code: String
    var dotColor: Color = DS.Colors.cyan

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                Text(label.uppercased())
                    .font(DS.Fonts.mono(10.5))
                    .tracking(1.2)
                    .foregroundStyle(DS.Colors.mistDim)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(SyntaxHighlighter.highlight(code))
                    .font(DS.Fonts.mono(13.5))
                    .lineSpacing(6)
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DS.Colors.hairline, lineWidth: 1)
        )
    }
}

/// Highlighter de sintaxe bem simples, feito só pra deixar os snippets
/// curtos (5-15 linhas) gerados pelo Foundation Models legíveis — não
/// lida com todos os casos do Swift real (ex: strings multi-linha,
/// comentários de bloco `/* */`, interpolação aninhada).
enum SyntaxHighlighter {

    private static let keywords: Set<String> = [
        "actor", "class", "struct", "enum", "protocol", "extension",
        "func", "var", "let", "if", "else", "guard", "return", "for",
        "in", "while", "switch", "case", "default", "break", "continue",
        "private", "public", "internal", "fileprivate", "static", "final",
        "await", "async", "try", "catch", "throw", "throws", "import",
        "self", "Self", "nil", "true", "false", "init", "deinit",
        "inout", "mutating", "some", "any", "where", "as", "is"
    ]

    private static let types: Set<String> = [
        "Int", "String", "Double", "Float", "Bool", "Array", "Dictionary",
        "Set", "Optional", "Void", "Any", "AnyObject", "Character", "Data"
    ]

    /// Cada token é classificado independentemente; regex captura, nessa
    /// ordem de prioridade: comentário até o fim da linha, string entre
    /// aspas, identificador (palavra), ou um único caractere qualquer.
    // `.` não casa quebra de linha por padrão (sem .dotMatchesLineSeparators)
    // — por isso `\n` precisa ser uma alternativa explícita, senão as
    // quebras de linha do snippet somem no resultado (tudo vira uma linha só).
    private static let tokenPattern = #"//.*$|"(?:[^"\\]|\\.)*"|[A-Za-z_][A-Za-z0-9_]*|\n|."#

    static func highlight(_ code: String) -> AttributedString {
        guard let regex = try? NSRegularExpression(pattern: tokenPattern, options: [.anchorsMatchLines]) else {
            return AttributedString(code)
        }

        var result = AttributedString()
        let nsCode = code as NSString
        let matches = regex.matches(in: code, options: [], range: NSRange(location: 0, length: nsCode.length))
        let tokens = matches.map { nsCode.substring(with: $0.range) }

        for (index, token) in tokens.enumerated() {
            // Lookahead simples: identificador seguido de "(" (ignorando
            // espaços) é tratado como chamada de função/nome de função.
            var nextNonSpace: String? = nil
            var lookahead = index + 1
            while lookahead < tokens.count {
                let candidate = tokens[lookahead]
                if candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                    lookahead += 1
                    continue
                }
                nextNonSpace = candidate
                break
            }
            result += coloredPiece(for: token, isFollowedByParen: nextNonSpace == "(")
        }

        return result
    }

    private static func coloredPiece(for token: String, isFollowedByParen: Bool) -> AttributedString {
        var piece = AttributedString(token)
        piece.font = DS.Fonts.mono(13.5)

        if token.hasPrefix("//") {
            piece.foregroundColor = DS.Colors.mistDim
            piece.font = DS.Fonts.mono(13.5).italic()
        } else if token.hasPrefix("\"") {
            piece.foregroundColor = DS.Colors.sage
        } else if keywords.contains(token) {
            piece.foregroundColor = DS.Colors.violet
        } else if types.contains(token) || (token.first?.isUppercase == true && token.count > 1) {
            piece.foregroundColor = DS.Colors.cyan
        } else if (token.first?.isLetter == true || token.first == "_") && isFollowedByParen {
            piece.foregroundColor = DS.Colors.orchid
        } else {
            piece.foregroundColor = DS.Colors.mist
        }

        return piece
    }
}
