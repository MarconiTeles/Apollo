import Foundation

/// Template for the **gitignored** `GoogleAuthSecrets.swift`.
///
/// First-time setup (per contributor):
///
///   1. Copy this file to `GoogleAuthSecrets.swift` (same directory).
///   2. Open https://console.cloud.google.com → your project.
///   3. APIs & Services → Library → enable "Google Calendar API".
///   4. OAuth consent screen → External → add yourself as Test User.
///      Scope: `.../auth/calendar.events`.
///   5. Credentials → CREATE CREDENTIALS → OAuth client ID →
///      Application type: **Desktop app**.
///   6. Paste both values into the copy of this file (NOT this template).
///
/// Empty strings disable the Google Calendar connect flow — the
/// Settings card will show "developer setup pending" instead.
///
/// **Do not commit your real `GoogleAuthSecrets.swift`.** It is
/// already listed in `.gitignore`.
///
/// Rename the enum to `GoogleAuthSecrets` after copying so the
/// references in `GoogleAuthService.swift` resolve.
enum GoogleAuthSecretsTemplate {
    static let clientId: String = ""
    static let clientSecret: String = ""
}
