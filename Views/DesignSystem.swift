//
//  DesignSystem.swift
//  SwiftStudyCoach
//
//  Paleta, tipografia e componentes reaproveitados do protótipo HTML
//  (reading-interface.html) — Parte 7.
//
//  Nota sobre fontes: Fraunces / Source Serif 4 / JetBrains Mono são fontes
//  do Google Fonts, não vêm com o iOS. `Font.custom` cai de volta pro
//  fallback informado automaticamente se a fonte não estiver instalada, mas
//  pra bater 100% com o protótipo é preciso baixar os .ttf e registrar no
//  Info.plist (chave "Fonts provided by application") + adicionar ao target.
//  Ver checklist no fim do arquivo.
//

import SwiftUI

// MARK: - Cores

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

enum DS {

    enum Colors {
        static let ink = Color(hex: "0D0F17")           // fundo principal
        static let void = Color(hex: "08090E")
        static let slate = Color(hex: "151827")         // cards/widgets
        static let panel = Color(hex: "1B1F30")         // bloco de código
        static let hairline = Color(hex: "262B3D")      // bordas
        static let hairlineSoft = Color.white.opacity(0.06)
        static let foam = Color(hex: "EDEAF4")          // texto principal
        static let mist = Color(hex: "9296AC")          // texto secundário
        static let mistDim = Color(hex: "5D6178")       // texto terciário/metadados
        static let violet = Color(hex: "A78BFA")        // destaque primário
        static let violetDim = Color(hex: "7C6BB0")
        static let violetGlow = Color(hex: "A78BFA").opacity(0.18)
        static let orchid = Color(hex: "E28FC4")        // avisos / erro do quiz
        static let cyan = Color(hex: "74D3C4")          // tipos / info
        static let sage = Color(hex: "9AC98B")          // sucesso / correto

        // Cores por dificuldade (decisão de design consistente com a
        // paleta de "term" do protótipo: sage=seguro, cyan=neutro, orchid=alerta).
        static func difficulty(_ d: Difficulty) -> Color {
            switch d {
            case .easy: return sage
            case .medium: return cyan
            case .hard: return orchid
            }
        }
    }

    enum Fonts {
        /// Títulos — Fraunces no protótipo.
        static func display(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
            .custom("Fraunces", size: size, relativeTo: .title).weight(weight)
        }
        /// Corpo de texto — Source Serif 4 no protótipo.
        static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .custom("Source Serif 4", size: size, relativeTo: .body).weight(weight)
        }
        /// Metadados/código — JetBrains Mono no protótipo.
        static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .custom("JetBrainsMono-Regular", size: size)
                .weight(weight)
        }
    }
}

// MARK: - Pill (tag de dificuldade/categoria)

struct PillView: View {
    let text: String
    var color: Color = DS.Colors.mist
    var borderColor: Color? = nil

    var body: some View {
        Text(text)
            .font(DS.Fonts.mono(11))
            .tracking(0.3)
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .stroke(borderColor ?? DS.Colors.hairline, lineWidth: 1)
            )
    }
}

// MARK: - Botão base do app (usa a paleta escura)

struct DSButtonStyle: ButtonStyle {
    var accent: Color = DS.Colors.violet
    var filled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Fonts.mono(13))
            .foregroundStyle(filled ? DS.Colors.ink : accent)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(filled ? accent : DS.Colors.slate)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(filled ? .clear : DS.Colors.hairline, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Container de tela escura padrão

struct DSScreen<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            DS.Colors.ink.ignoresSafeArea()
            content
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Checklist de setup de fontes (não é código, é lembrete)
//
// 1. Baixar as 3 famílias no Google Fonts:
//    Fraunces, Source Serif 4, JetBrains Mono.
// 2. Arrastar os arquivos .ttf pro target no Xcode (marcar "Copy items if needed").
// 3. Info.plist → adicionar chave "Fonts provided by application" (UIAppFonts)
//    listando cada arquivo .ttf.
// 4. Rodar `po UIFont.familyNames.sorted()` no debugger, ou print(), pra
//    confirmar o nome exato registrado por família antes de ajustar os
//    nomes usados em `DS.Fonts` acima (o nome do arquivo nem sempre bate
//    com o nome interno da fonte).
// Até isso ser feito, os componentes caem no fallback do sistema
// automaticamente (sem crash), então o app funciona igual, só sem a
// tipografia exata do protótipo.
