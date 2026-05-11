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

    func checkAuthState() {
        isConnected   = accessToken != nil
        workspaceName = KeychainHelper.load(for: KeychainHelper.Keys.clickupWorkspace)
        userName      = KeychainHelper.load(for: KeychainHelper.Keys.clickupUserName)
        userId        = KeychainHelper.load(for: KeychainHelper.Keys.clickupUserId).flatMap { Int($0) }
    }

    // MARK: - Connection flow
    //
    // Previously this method polled `NSPasteboard.general` every
    // 0.5s for 2 minutes hunting for a `pk_…` string. That was a
    // security smell on two axes:
    //
    //   1. ANY string copied during the polling window that
    //      matched the prefix would be silently consumed and
    //      saved as the user's token — including a malicious
    //      `pk_…` placed in the clipboard by another app /
    //      webpage with a different user's credentials, or even
    //      attacker-chosen "tokens" used to phish.
    //   2. Pasteboard polling is opaque to the user — they have
    //      no idea Apollo is reading their clipboard.
    //
    // The new flow is explicit:
    //
    //   - `startConnection()` opens ClickUp's tokens page and
    //     flips `isWaitingForToken = true`. That's it — no
    //     background polling, no clipboard reads.
    //   - The Settings UI surfaces a paste field while
    //     `isWaitingForToken` is true. User pastes the token and
    //     hits Confirm, which calls `submitToken(_:)`.
    //   - `submitToken` validates the prefix + length, saves to
    //     Keychain, fetches the profile, and clears the waiting
    //     state.

    func startConnection() {
        connectionError   = nil
        isWaitingForToken = true
        NSWorkspace.shared.open(URL(string: "https://app.clickup.com/settings/apps")!)
    }

    func cancelConnection() {
        isWaitingForToken = false
        connectionError   = nil
    }

    /// Called by the Settings paste field's Confirm button.
    /// Validates the token shape before saving so a typo or a
    /// wrong-pasted-string doesn't end up in the Keychain.
    /// Returns `true` on a structurally valid token; `false`
    /// surfaces an inline `connectionError`.
    @discardableResult
    func submitToken(_ raw: String) -> Bool {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // ClickUp personal tokens always start with `pk_` and
        // are typically ~50 chars (prefix + workspace id +
        // random suffix). 30 chars is a generous lower bound.
        guard candidate.hasPrefix("pk_"), candidate.count >= 30 else {
            connectionError = "Token inválido. Tem que começar com 'pk_'."
            return false
        }
        connectionError = nil
        Task { await self.completeConnection(token: candidate) }
        return true
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
