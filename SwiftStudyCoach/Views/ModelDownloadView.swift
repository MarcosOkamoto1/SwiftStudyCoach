//
//  ModelDownloadView.swift
//  SwiftStudyCoach
//
//  Tela de progresso do download do modelo MLX (primeira execução):
//  barra de progresso real, MB baixados, velocidade e tempo restante
//  estimado — em vez do spinner genérico que parecia travado durante
//  um download de ~8,3 GB (Qwen2.5-Coder-14B-4bit).
//
//  Observa MLXService.shared (@Observable) diretamente; qualquer mudança
//  em loadState/velocidade/ETA re-renderiza sozinha.
//

import SwiftUI

struct ModelDownloadView: View {

    /// Modo compacto: banner slim pra ser embutido em outra tela (ex: o
    /// artigo do tópico, enquanto o download acontece em background).
    var compact: Bool = false

    /// Ação opcional de retry (mostrada no estado de falha).
    var onRetry: (() -> Void)? = nil

    private var service: MLXService { MLXService.shared }

    var body: some View {
        if compact {
            compactBody
        } else {
            fullBody
        }
    }

    private var fullBody: some View {
        VStack(spacing: 18) {
            switch service.loadState {
            case .downloading(let fraction):
                downloadingContent(fraction: fraction)
            case .loadingIntoMemory:
                stageContent(
                    icon: "memorychip",
                    title: "Carregando modelo na memória...",
                    subtitle: "Download concluído — preparando os pesos. Leva alguns segundos."
                )
            case .failed(let reason):
                failedContent(reason)
            case .idle, .ready:
                // Estados em que esta tela normalmente não aparece; spinner
                // neutro pra não piscar conteúdo errado numa transição.
                ProgressView().tint(DS.Colors.violet)
            }
        }
        .padding(28)
        .frame(maxWidth: 420)
    }

    // MARK: - Modo compacto (banner)

    @ViewBuilder
    private var compactBody: some View {
        switch service.loadState {
        case .downloading(let fraction):
            compactCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Baixando modelo de IA local", systemImage: "arrow.down.circle")
                            .font(DS.Fonts.body(13, weight: .medium))
                            .foregroundStyle(DS.Colors.foam)
                        Spacer()
                        Text("\(Int(fraction * 100))%")
                            .font(DS.Fonts.mono(11.5))
                            .foregroundStyle(DS.Colors.violet)
                    }
                    ProgressView(value: fraction).tint(DS.Colors.violet)
                    HStack {
                        Text(formatBytes(Int64(fraction * Double(MLXService.estimatedModelBytes))) + " de " + formatBytes(MLXService.estimatedModelBytes))
                        Spacer()
                        if let eta = service.downloadETASeconds {
                            Text("~\(formatDuration(eta)) restantes")
                        }
                    }
                    .font(DS.Fonts.mono(10.5))
                    .foregroundStyle(DS.Colors.mistDim)
                    Text("As perguntas difíceis e a análise de código são liberadas quando o download terminar.")
                        .font(DS.Fonts.body(11.5))
                        .foregroundStyle(DS.Colors.mistDim)
                }
            }
        case .loadingIntoMemory:
            compactCard {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.7).tint(DS.Colors.violet)
                    Text("Download concluído — carregando modelo na memória...")
                        .font(DS.Fonts.body(12.5))
                        .foregroundStyle(DS.Colors.mist)
                }
            }
        case .failed(let reason):
            compactCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Falha ao baixar o modelo local", systemImage: "exclamationmark.triangle")
                        .font(DS.Fonts.body(13, weight: .medium))
                        .foregroundStyle(DS.Colors.orchid)
                    Text(reason)
                        .font(DS.Fonts.body(11.5))
                        .foregroundStyle(DS.Colors.mistDim)
                        .lineLimit(2)
                    if let onRetry {
                        Button("Tentar de novo") { onRetry() }
                            .buttonStyle(DSButtonStyle())
                            .frame(maxWidth: 160)
                    }
                }
            }
        case .idle, .ready:
            EmptyView()
        }
    }

    private func compactCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DS.Colors.slate)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(DS.Colors.hairline, lineWidth: 1)
            )
    }

    // MARK: - Baixando

    private func downloadingContent(fraction: Double) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Circle().fill(DS.Colors.violet).frame(width: 5, height: 5)
                Text("PRIMEIRA EXECUÇÃO")
                    .font(DS.Fonts.mono(10.5))
                    .tracking(1.2)
                    .foregroundStyle(DS.Colors.violet)
            }

            Text("Baixando modelo de IA local")
                .font(DS.Fonts.display(22))
                .foregroundStyle(DS.Colors.foam)

            Text(MLXService.modelID.components(separatedBy: "/").last ?? MLXService.modelID)
                .font(DS.Fonts.mono(11.5))
                .foregroundStyle(DS.Colors.mistDim)

            ProgressView(value: fraction)
                .tint(DS.Colors.violet)

            HStack {
                Text("\(formatBytes(Int64(fraction * Double(MLXService.estimatedModelBytes)))) de \(formatBytes(MLXService.estimatedModelBytes))")
                Spacer()
                Text("\(Int(fraction * 100))%")
            }
            .font(DS.Fonts.mono(11.5))
            .foregroundStyle(DS.Colors.mist)

            HStack {
                if let speed = service.downloadSpeedBytesPerSecond {
                    Label("\(formatBytes(Int64(speed)))/s", systemImage: "arrow.down.circle")
                }
                Spacer()
                if let eta = service.downloadETASeconds {
                    Label("~\(formatDuration(eta)) restantes", systemImage: "clock")
                }
            }
            .font(DS.Fonts.mono(11.5))
            .foregroundStyle(DS.Colors.mistDim)

            Text("O download acontece só uma vez e fica salvo no dispositivo. Prefira uma conexão Wi-Fi.")
                .font(DS.Fonts.body(12.5))
                .foregroundStyle(DS.Colors.mistDim)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
    }

    // MARK: - Estados auxiliares

    private func stageContent(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().tint(DS.Colors.violet)
            Label(title, systemImage: icon)
                .font(DS.Fonts.body(14, weight: .medium))
                .foregroundStyle(DS.Colors.foam)
            Text(subtitle)
                .font(DS.Fonts.body(12.5))
                .foregroundStyle(DS.Colors.mistDim)
                .multilineTextAlignment(.center)
        }
    }

    private func failedContent(_ reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(DS.Colors.orchid)
            Text("Falha ao baixar o modelo MLX")
                .font(DS.Fonts.body(15, weight: .medium))
                .foregroundStyle(DS.Colors.foam)
            Text(reason)
                .font(DS.Fonts.body(12.5))
                .foregroundStyle(DS.Colors.mistDim)
                .multilineTextAlignment(.center)
            if let onRetry {
                Button("Tentar de novo") { onRetry() }
                    .buttonStyle(DSButtonStyle())
                    .frame(maxWidth: 200)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Formatação

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)min"
    }
}

#Preview {
    DSScreen {
        ModelDownloadView()
    }
}
