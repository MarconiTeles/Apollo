import Foundation
import Security

/// Token / API-key storage. As of 1.4.11 this delegates to the
/// real macOS Keychain via `SecItem*` APIs — items are stored
/// under `kSecClassGenericPassword` keyed by a per-key
/// `kSecAttrAccount` value, scoped to this app's bundle id, and
/// only readable once the device is unlocked (and never copied to
/// a backup or iCloud Keychain).
///
/// Migration strategy (1.4.0 … 1.4.10 used plaintext JSON at
/// `~/Library/Application Support/DayPanel/secrets.json` with
/// chmod 0600):
///
///   • `load(for:)` first asks Keychain. If empty, falls back to
///     the legacy JSON. On a successful legacy read, the value
///     is mirrored into Keychain so subsequent loads are fast +
///     authoritative.
///   • `save(_:for:)` writes to BOTH stores. The duplicate write
///     to JSON exists as a belt-and-suspenders fallback because
///     adhoc-signed binaries get a fresh signature on every
///     release build — if a future Sparkle update happens to
///     invalidate the Keychain ACL (the "this is a different app"
///     prompt path), the JSON copy keeps the user logged in
///     instead of forcing a full re-auth.
///   • `delete(for:)` clears both stores.
///
/// Once you ship with a real Developer ID + notarization, the
/// signature stays stable across builds and Keychain becomes the
/// safe single source of truth — flip `writeLegacyMirror` to
/// `false` and delete the JSON file on first launch.
enum KeychainHelper {

    // MARK: - Configuration

    /// `kSecAttrService` for every item we store. Acts as a
    /// namespace inside the user's login Keychain so a future
    /// inspection (`security find-generic-password -s com.painellunar.app.secrets`)
    /// pulls only Apollo's items.
    private static let service = "com.painellunar.app.secrets"

    /// While true, every `save(_:for:)` also writes to the legacy
    /// JSON store. We flipped this to `false` for 1.5.0+: with
    /// Developer ID notarized builds the signature is stable
    /// across releases, so Keychain items keep their ACL across
    /// OTA updates and the JSON fallback is no longer needed.
    /// `load(for:)` still reads the legacy JSON as a one-time
    /// migration path so users coming from <=1.4.12 don't lose
    /// their tokens.
    private static let writeLegacyMirror = false

    // MARK: - Legacy JSON store (still read, optionally written)

    private static let legacyFileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appendingPathComponent("DayPanel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir.appendingPathComponent("secrets.json")
    }()

    private static let legacyQueue = DispatchQueue(label: "DayPanel.SecretsStore.legacy")

    private static func readLegacy() -> [String: String] {
        legacyQueue.sync {
            guard let data = try? Data(contentsOf: legacyFileURL),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data)
            else { return [:] }
            return dict
        }
    }

    private static func writeLegacy(_ dict: [String: String]) {
        legacyQueue.sync {
            guard let data = try? JSONEncoder().encode(dict) else { return }
            try? data.write(to: legacyFileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                    ofItemAtPath: legacyFileURL.path)
        }
    }

    // MARK: - Keychain primitives

    /// Build the lookup query shared by every operation. Adding
    /// `kSecAttrAccount` keys the item; the caller adds the rest
    /// (value-data + accessibility on writes, return + match-limit
    /// on reads).
    private static func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    private static func keychainLoad(_ key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String]  = true
        query[kSecMatchLimit as String]  = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }

    @discardableResult
    private static func keychainSave(_ value: String, for key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // First try to update — most calls are over existing
        // items (token rotation, re-auth) so this is the hot
        // path.
        let query  = baseQuery(for: key)
        let update: [String: Any] = [
            kSecValueData      as String: data,
            // `WhenUnlockedThisDeviceOnly` is the strictest
            // commonly-used class: items are decryptable only
            // when the user has unlocked the Mac at least once
            // this boot, AND they don't migrate to iCloud
            // Keychain or to Time Machine backups. Right
            // posture for an OAuth token — we'd rather force
            // re-login on a stolen drive than leak the token.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist yet — fall through to add.
            var addQuery = query
            addQuery[kSecValueData      as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            return addStatus == errSecSuccess
        }
        return false
    }

    @discardableResult
    private static func keychainDelete(_ key: String) -> Bool {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Public API (call-compatible with the old helper)

    static func save(_ value: String, for key: String) {
        _ = keychainSave(value, for: key)
        if writeLegacyMirror {
            var d = readLegacy()
            d[key] = value
            writeLegacy(d)
        }
    }

    static func load(for key: String) -> String? {
        // Keychain wins. If it returns nil and the legacy file
        // still has the value, this is the first read after the
        // 1.4.11 migration — mirror it into Keychain so future
        // loads bypass the file altogether.
        if let v = keychainLoad(key) { return v }
        if let legacy = readLegacy()[key] {
            _ = keychainSave(legacy, for: key)
            return legacy
        }
        return nil
    }

    static func delete(for key: String) {
        _ = keychainDelete(key)
        var d = readLegacy()
        if d.removeValue(forKey: key) != nil {
            writeLegacy(d)
        }
    }

    // MARK: - Keys (unchanged from previous versions)

    enum Keys {
        static let googleAccessToken  = "dp_google_access_token"
        static let googleRefreshToken = "dp_google_refresh_token"
        static let googleUserEmail    = "dp_google_user_email"
        /// OAuth 2.0 Client ID for the user's own Google Cloud
        /// project. Required by `GoogleAuthService` so we don't
        /// have to bake a shared client ID into the app
        /// binary. The user creates a "Desktop app" credential
        /// in Google Cloud Console and pastes the ID into
        /// Settings → Google Calendar.
        static let googleClientId     = "dp_google_client_id"
        static let clickupToken       = "dp_clickup_token"
        static let clickupListId      = "dp_clickup_list_id"
        static let clickupListName    = "dp_clickup_list_name"
        static let clickupUserName    = "dp_clickup_user_name"
        static let clickupUserId      = "dp_clickup_user_id"   // numeric, stored as string
        static let clickupWorkspace   = "dp_clickup_workspace"
        /// ClickUp team / workspace numeric id (stored as a
        /// string). Needed for the cross-list "My Work" query
        /// (`GET /team/{id}/task?assignees[]=…`). Captured at
        /// connect time alongside the workspace name.
        static let clickupWorkspaceId = "dp_clickup_workspace_id"
        /// Google AI Studio (Gemini) API key. Used by the in-app
        /// AI agent to call models like `gemini-2.0-flash`.
        static let geminiApiKey       = "dp_gemini_api_key"
        /// Groq API key (https://console.groq.com). Used by the
        /// AI agent to call models like `llama-3.3-70b-versatile`.
        static let groqApiKey         = "dp_groq_api_key"
        /// OpenAI API key (https://platform.openai.com). Used by
        /// the AI agent to call GPT-4o / GPT-5 family.
        static let openaiApiKey       = "dp_openai_api_key"
    }
}
