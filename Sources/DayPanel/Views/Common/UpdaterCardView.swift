import SwiftUI
import AppKit

/// The Editorial Calm replacement for Sparkle's stock update windows.
/// Observes `ApolloUpdateDriver.phase` and renders one card per stage of
/// the update lifecycle. All actions route back to Sparkle through the
/// driver's intent methods.
struct UpdaterCardView: View {
    @ObservedObject var driver: ApolloUpdateDriver

    private var popupShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Editorial.popupRadius(14), style: .continuous)
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(width: 460)
        .padding(28)
        .popupGlass(in: popupShape)
        .padding(40)               // room so the soft shadow isn't clipped by the window edge
        .fixedSize()
    }

    // MARK: - Per-phase content

    @ViewBuilder
    private var content: some View {
        switch driver.phase {
        case .idle:
            EmptyView()

        case .checking:
            header(title: "Procurando atualizações", subtitle: "Verificando se há uma nova versão do Apollo…")
            spinnerRow
            buttonRow { secondaryButton("Cancelar") { driver.cancel() } }

        case let .found(version, notes):
            header(title: "Nova versão disponível",
                   subtitle: "Apollo \(version) está pronto para instalar — você tem a \(currentVersion).")
            notesBox(notes)
            buttonRow {
                secondaryButton("Ignorar esta versão") { driver.choose(.skip) }
                Spacer(minLength: 8)
                secondaryButton("Depois") { driver.choose(.dismiss) }
                primaryButton("Baixar em segundo plano") {
                    driver.downloadInBackground()
                }
            }

        case let .downloading(fraction):
            header(title: "Baixando atualização", subtitle: "Buscando a nova versão do Apollo.")
            progressBar(fraction)
            buttonRow { secondaryButton("Cancelar") { driver.cancel() } }

        case let .extracting(fraction):
            header(title: "Preparando", subtitle: "Descompactando e verificando a atualização.")
            progressBar(fraction)
            buttonRow { EmptyView() }

        case .installing:
            header(title: "Instalando", subtitle: "Aplicando a atualização. O Apollo vai reiniciar em instantes.")
            spinnerRow
            buttonRow { EmptyView() }

        case let .readyToRelaunch(version):
            header(title: "Pronto para instalar",
                   subtitle: version.isEmpty
                        ? "A atualização foi baixada. Reinicie para concluir."
                        : "Apollo \(version) foi baixado. Reinicie para concluir.")
            buttonRow {
                secondaryButton("Depois") { driver.choose(.dismiss) }
                primaryButton("Instalar e reiniciar") { driver.choose(.install) }
            }

        case .upToDate:
            header(title: "Tudo em dia", subtitle: "Você já está na versão mais recente do Apollo (\(currentVersion)).")
            buttonRow { primaryButton("OK") { driver.acknowledge() } }

        case let .failed(message):
            header(title: "Falha na atualização", subtitle: message, isError: true)
            buttonRow { primaryButton("OK") { driver.acknowledge() } }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func header(title: String, subtitle: String, isError: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Editorial.serif(20, .medium))
                    .foregroundStyle(isError ? Editorial.accent : Editorial.ink)
                Text(subtitle)
                    .font(Editorial.sans(12.5))
                    .foregroundStyle(Editorial.ink.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 18)
    }

    private func notesBox(_ notes: String) -> some View {
        ScrollView {
            Text(notes.isEmpty ? "Sem notas para esta versão." : notes)
                .font(Editorial.sans(12.5))
                .foregroundStyle(Editorial.ink.opacity(0.82))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(14)
        }
        .frame(height: 150)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Editorial.ink.opacity(0.035))
        )
        .padding(.bottom, 18)
    }

    private var spinnerRow: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
                .tint(Editorial.accent)
            Spacer()
        }
        .padding(.bottom, 18)
    }

    /// `fraction == nil` → indeterminate sweep; otherwise a determinate
    /// cinnabar fill on an ink-tinted track.
    @ViewBuilder
    private func progressBar(_ fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Editorial.ink.opacity(0.08))
                    if let fraction {
                        Capsule()
                            .fill(Editorial.accent)
                            .frame(width: max(6, geo.size.width * CGFloat(fraction)))
                            .animation(.easeOut(duration: 0.2), value: fraction)
                    } else {
                        IndeterminateBar()
                    }
                }
            }
            .frame(height: 6)
            if let fraction {
                Text("\(Int(fraction * 100))%")
                    .font(Editorial.sans(11, .medium))
                    .foregroundStyle(Editorial.ink.opacity(0.5))
            }
        }
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private func buttonRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Editorial.sans(13, .semibold))
                .foregroundStyle(Editorial.paper)
                .padding(.horizontal, 18).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Editorial.ink))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .keyboardShortcut(.return, modifiers: [])
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Editorial.sans(13, .medium))
                .foregroundStyle(Editorial.ink.opacity(0.7))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

/// A small left-to-right sweeping bar for indeterminate progress
/// (download started but no Content-Length yet).
private struct IndeterminateBar: View {
    @State private var phase: CGFloat = 0
    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Editorial.accent)
                .frame(width: geo.size.width * 0.35)
                .offset(x: phase * geo.size.width * 1.35 - geo.size.width * 0.35)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        }
    }
}
