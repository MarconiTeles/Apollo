import Foundation
import AppKit
import Combine

/// One-button connection flow for the Groq API key — same pattern
/// Apollo uses for ClickUp:
///
///   1. Open `https://console.groq.com/keys` in the browser.
///   2. Poll the clipboard for ~2 min watching for a string that
///      matches Groq's key format (`gsk_…` ≥ 50 chars).
///   3. When the user clicks "Copy" next to a freshly-generated
///      key, Apollo detects it, saves to Keychain, surfaces a
///      "✓ Conectado" confirmation.
///
/// The user never opens Settings, never pastes anything, never
/// types a key. The whole flow is "click button → click Copy in
/// the browser tab → done".
final class GroqAuthManager: ObservableObject {

    @Published var isConnected:       Bool   = false
    @Published var connectionError:   String?
    @Published var isWaitingForToken: Bool   = false

    private var pollingTask: Task<Void, Never>?

    init() {
        refreshConnectedState()
    }

    /// Re-reads the Keychain so the published `isConnected` mirror
    /// catches up with whatever's actually stored. Called on launch
    /// and after any save/delete.
    func refreshConnectedState() {
        let stored = KeychainHelper.load(for: KeychainHelper.Keys.groqApiKey) ?? ""
        isConnected = stored.count >= 30 && stored.hasPrefix("gsk_")
    }

    // MARK: - One-button connection flow

    func startConnection() {
        connectionError   = nil
        isWaitingForToken = true

        NSWorkspace.shared.open(URL(string: "https://console.groq.com/keys")!)

        pollingTask?.cancel()
        let pasteboard    = NSPasteboard.general
        let startingCount = pasteboard.changeCount

        pollingTask = Task { [weak self] in
            var lastCount = startingCount

            // 240 × 0.5s = 120s window. Plenty of time for the
            // user to log in, hit "Create API Key", name it and
            // press Copy.
            for _ in 0..<240 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }

                let currentCount = pasteboard.changeCount
                if currentCount != lastCount {
                    lastCount = currentCount
                    if let raw = pasteboard.string(forType: .string) {
                        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        if Self.isPlausibleGroqKey(candidate) {
                            await self?.completeConnection(token: candidate)
                            return
                        }
                    }
                }
            }

            // Timed out — user never copied a key.
            await MainActor.run {
                guard let self else { return }
                if self.isWaitingForToken {
                    self.isWaitingForToken = false
                    self.connectionError = "Tempo esgotado. Clique em Conectar e copie a chave no console do Groq."
                }
            }
        }
    }

    func cancelConnection() {
        pollingTask?.cancel()
        pollingTask       = nil
        isWaitingForToken = false
        connectionError   = nil
    }

    func disconnect() {
        cancelConnection()
        KeychainHelper.delete(for: KeychainHelper.Keys.groqApiKey)
        isConnected = false
    }

    // MARK: - Internals

    @MainActor
    private func completeConnection(token: String) {
        KeychainHelper.save(token, for: KeychainHelper.Keys.groqApiKey)
        isWaitingForToken = false
        connectionError   = nil
        isConnected       = true
    }

    /// Groq keys begin with `gsk_` and are typically ~56 chars of
    /// `[a-zA-Z0-9_]`. We accept anything ≥ 30 chars to be tolerant
    /// of future format tweaks.
    private static func isPlausibleGroqKey(_ s: String) -> Bool {
        guard s.hasPrefix("gsk_"), s.count >= 30 else { return false }
        // Reject obvious copy-paste of full sentences with the
        // prefix embedded — must consist entirely of identifier
        // characters.
        return s.allSatisfy { ch in
            ch.isLetter || ch.isNumber || ch == "_" || ch == "-"
        }
    }
}
