import Foundation

/// Stripped-down stand-in for `print()` / `NSLog()` that scrubs
/// known secret-shaped substrings before letting the message
/// reach the system log. macOS Console.app, crash reports, and
/// any kind of "send us your log file" support flow can see
/// `print()` output by default — letting a refresh token or
/// Bearer header land in there is a credential exposure that
/// only takes one careless paste to escalate.
///
/// Drop-in replacements:
///   - `print("[Apollo] failed: \(error)")` → `Log.error("failed: \(error)")`
///   - `NSLog("[Apollo] uploaded %@", url.absoluteString)` → `Log.info("uploaded \(url.absoluteString)")`
///
/// The redactor runs by default in both DEBUG and release. It's
/// fine to extend the pattern list — anything that looks like a
/// credential is in scope.
enum Log {

    /// All patterns we redact, in priority order. Each entry is
    /// a `(NSRegularExpression, replacement)` pair. We compile
    /// once at first use; the array is small enough that linear
    /// scanning per log line is negligible (~µs).
    private static let redactionRules: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            // Authorization headers — "Bearer <token>", optionally
            // surrounded by quotes or punctuation.
            (#"(?i)Bearer\s+[A-Za-z0-9._\-+/=]+"#,
             "Bearer [REDACTED]"),

            // ClickUp personal tokens (`pk_<id>_<rest>`) — fixed
            // prefix + base32-ish body. ClickUp documents these
            // as starting with `pk_`; anything past that is the
            // secret.
            (#"pk_[A-Za-z0-9_\-]{10,}"#,
             "pk_[REDACTED]"),

            // GitHub PATs (`gho_`, `ghp_`, `github_pat_…`).
            (#"gh[opusr]_[A-Za-z0-9_]{20,}"#,
             "gh*_[REDACTED]"),
            (#"github_pat_[A-Za-z0-9_]{20,}"#,
             "github_pat_[REDACTED]"),

            // Google OAuth client secrets — Desktop and Web both
            // share the `GOCSPX-` prefix.
            (#"GOCSPX-[A-Za-z0-9_\-]{15,}"#,
             "GOCSPX-[REDACTED]"),

            // Generic OAuth `access_token=`, `refresh_token=`,
            // `id_token=`, `code=` in URL-encoded / JSON-ish form.
            (#"(?i)(access_token|refresh_token|id_token)["':=\s]+["']?[A-Za-z0-9._\-+/=]{20,}"#,
             "$1=[REDACTED]"),
            (#"(?i)\bcode=[A-Za-z0-9._\-+/=%]{10,}"#,
             "code=[REDACTED]"),

            // Sparkle EdDSA signatures from logs (defense in
            // depth — they're public on the appcast anyway, but
            // grouping them is a nice "do not paste this whole
            // log" cue).
            (#"sparkle:edSignature="[^"]+""#,
             #"sparkle:edSignature="[REDACTED]""#),

            // Sufficiently long base64-ish blobs that look like
            // tokens but didn't match a more specific rule.
            // Conservative threshold (≥ 32 chars) so this
            // doesn't accidentally redact things like JSON ids.
            (#"\b[A-Za-z0-9_\-]{40,}\b"#,
             "[OPAQUE-TOKEN-REDACTED]"),
        ]
        return patterns.compactMap { (pattern, replacement) in
            guard let re = try? NSRegularExpression(pattern: pattern) else {
                return nil
            }
            return (re, replacement)
        }
    }()

    /// Apply every redaction rule to `message`, in order, and
    /// return the scrubbed string. Pure function — safe to call
    /// from anywhere.
    static func redact(_ message: String) -> String {
        var current = message
        let range = NSRange(current.startIndex..., in: current)
        for (re, replacement) in redactionRules {
            current = re.stringByReplacingMatches(
                in: current,
                options: [],
                range: NSRange(current.startIndex..., in: current),
                withTemplate: replacement
            )
            _ = range
        }
        return current
    }

    // MARK: - Public log surface

    /// Informational log — equivalent to the existing
    /// `print("[Apollo] …")` pattern, but redacted.
    static func info(_ message: @autoclosure () -> String,
                     file: String = #fileID,
                     line: Int = #line) {
        emit(level: "info", message: message(), file: file, line: line)
    }

    /// Error log. Same as `info` but emitted to stderr-equivalent
    /// channel so Console.app + crash reports group them as
    /// faults.
    static func error(_ message: @autoclosure () -> String,
                      file: String = #fileID,
                      line: Int = #line) {
        emit(level: "error", message: message(), file: file, line: line)
    }

    private static func emit(level: String,
                             message: String,
                             file: String,
                             line: Int) {
        let scrubbed = redact(message)
        // `NSLog` is the canonical AppKit log channel — it
        // shows up in Console.app under the app's subsystem
        // and lands in crash reports. Apollo doesn't yet wire
        // `os_log` / `Logger` (would need a subsystem id);
        // NSLog is the no-config fallback that already routes
        // to the system log without ceremony.
        NSLog("[Apollo][\(level)] %@ (%@:%d)", scrubbed, file, line)
    }
}
