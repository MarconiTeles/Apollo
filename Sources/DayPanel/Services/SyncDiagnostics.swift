import Foundation
import OSLog

/// Sync failures in the unified log with a readable (public) message.
/// `Log.error` goes through `NSLog`, whose arguments the system stores as
/// `<private>` — which made it impossible to tell *which* request failed
/// behind a "Falha na sincronização". Messages are scrubbed by
/// `Log.redact` first, so no token can leak.
///
///     log show --last 30m --predicate 'subsystem == "com.painellunar.app" AND category == "Sync"'
enum SyncDiagnostics {
    private static let logger = Logger(subsystem: "com.painellunar.app", category: "Sync")

    static func failure(_ source: String, _ error: Error) {
        let detail = Log.redact(String(describing: error))
        logger.error("sync failure [\(source, privacy: .public)]: \(detail, privacy: .public)")
    }
}
