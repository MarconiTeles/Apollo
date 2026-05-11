import Foundation
import AppKit

final class ClickUpAuthService: ObservableObject {
    @Published var isConnected:       Bool   = false
    @Published var workspaceName:     String?
    @Published var userName:          String?
    @Published var userId:            Int?    // ClickUp numeric id of the connected user
    @Published var connectionError:   String?
    @Published var isWaitingForToken: Bool   = false

    var accessToken: String? { KeychainHelper.load(for: KeychainHelper.Keys.clickupToken) }

    private var pollingTask: Task<Void, Never>?

    func checkAuthState() {
        isConnected   = accessToken != nil
        workspaceName = KeychainHelper.load(for: KeychainHelper.Keys.clickupWorkspace)
        userName      = KeychainHelper.load(for: KeychainHelper.Keys.clickupUserName)
        userId        = KeychainHelper.load(for: KeychainHelper.Keys.clickupUserId).flatMap { Int($0) }
    }

    // MARK: - One-button connection flow
    //
    // 1. Opens ClickUp's API-token page in the browser
    // 2. Watches the clipboard for ~2 minutes
    // 3. When the user clicks "Copiar" next to their token (pk_…),
    //    we detect it automatically and connect — no manual paste needed.

    func startConnection() {
        connectionError   = nil
        isWaitingForToken = true

        NSWorkspace.shared.open(URL(string: "https://app.clickup.com/settings/apps")!)

        pollingTask?.cancel()
        let pasteboard    = NSPasteboard.general
        let startingCount = pasteboard.changeCount

        pollingTask = Task { [weak self] in
            var lastCount = startingCount

            for _ in 0..<240 {                       // 240 × 0.5s = 120s window
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }

                let currentCount = pasteboard.changeCount
                if currentCount != lastCount {
                    lastCount = currentCount
                    if let raw = pasteboard.string(forType: .string) {
                        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        if candidate.hasPrefix("pk_") && candidate.count >= 30 {
                            await self?.completeConnection(token: candidate)
                            return
                        }
                    }
                }
            }

            // Timed out — user never copied a token
            await MainActor.run {
                guard let self else { return }
                if self.isWaitingForToken {
                    self.isWaitingForToken = false
                    self.connectionError   = "Tempo esgotado. Tente novamente."
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

    private func completeConnection(token: String) async {
        KeychainHelper.save(token, for: KeychainHelper.Keys.clickupToken)
        await fetchProfile(token: token)
        await MainActor.run { self.isWaitingForToken = false }
    }

    // MARK: - Profile

    private func fetchProfile(token: String) async {
        var uReq = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/user")!)
        uReq.setValue(token, forHTTPHeaderField: "Authorization")
        let uName: String
        var resolvedId: Int?
        if let (uData, _) = try? await URLSession.shared.data(for: uReq),
           let json = try? JSONSerialization.jsonObject(with: uData) as? [String: Any],
           let user = json["user"] as? [String: Any] {
            uName = user["username"] as? String ?? user["email"] as? String ?? "Usuário"
            resolvedId = user["id"] as? Int
        } else {
            uName = "Usuário"
        }
        KeychainHelper.save(uName, for: KeychainHelper.Keys.clickupUserName)
        if let id = resolvedId {
            KeychainHelper.save(String(id), for: KeychainHelper.Keys.clickupUserId)
            await MainActor.run { self.userId = id }
        }

        var wReq = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/team")!)
        wReq.setValue(token, forHTTPHeaderField: "Authorization")
        let wsName: String
        if let (wData, _) = try? await URLSession.shared.data(for: wReq),
           let json  = try? JSONSerialization.jsonObject(with: wData) as? [String: Any],
           let teams = json["teams"] as? [[String: Any]],
           let first = teams.first,
           let name  = first["name"] as? String {
            wsName = name
        } else {
            wsName = "Workspace"
        }
        KeychainHelper.save(wsName, for: KeychainHelper.Keys.clickupWorkspace)

        await MainActor.run {
            self.isConnected   = true
            self.userName      = uName
            self.workspaceName = wsName
        }
    }

    // MARK: - Disconnect

    func disconnect() {
        cancelConnection()
        KeychainHelper.delete(for: KeychainHelper.Keys.clickupToken)
        KeychainHelper.delete(for: KeychainHelper.Keys.clickupListId)
        KeychainHelper.delete(for: KeychainHelper.Keys.clickupUserName)
        KeychainHelper.delete(for: KeychainHelper.Keys.clickupUserId)
        KeychainHelper.delete(for: KeychainHelper.Keys.clickupWorkspace)
        isConnected   = false
        userId        = nil
        workspaceName = nil
        userName      = nil
    }
}
