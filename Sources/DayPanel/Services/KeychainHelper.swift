import Foundation

// File-based secret store. Lives at ~/Library/Application Support/DayPanel/secrets.json
// with mode 0600. Replaces macOS Keychain to avoid the password prompt that appears
// every time the app is re-signed (ad-hoc signatures change between builds).
//
// The file is in the user's home directory, readable only by the user — same security
// posture as Keychain "AfterFirstUnlock" for a single-user macOS install.

enum KeychainHelper {
    private static let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("DayPanel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("secrets.json")
    }()

    private static let queue = DispatchQueue(label: "DayPanel.SecretsStore")

    private static func read() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    private static func write(_ dict: [String: String]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func save(_ value: String, for key: String) {
        queue.sync {
            var d = read()
            d[key] = value
            write(d)
        }
    }

    static func load(for key: String) -> String? {
        queue.sync { read()[key] }
    }

    static func delete(for key: String) {
        queue.sync {
            var d = read()
            d.removeValue(forKey: key)
            write(d)
        }
    }

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
