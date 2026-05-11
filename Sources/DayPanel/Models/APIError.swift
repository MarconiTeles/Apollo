import Foundation

/// Semantic classification of errors that come back from
/// Apollo's API calls (currently just ClickUp; Google Calendar
/// would slot in here too). Replaces blanket
/// `catch { print + notify .error }` with codepaths that can
/// react to the *kind* of failure — re-auth for 401, retry-with-
/// delay for 429, exponential backoff for 5xx, queue-for-later
/// for connectivity drops, etc.
///
/// Map raw `URLError` / HTTP status codes into one of these via
/// `APIError.classify(_:response:)` at the boundary of every
/// API method, so the rest of the app sees only this typed
/// taxonomy.
enum APIError: Error, Equatable {

    /// Caller hasn't configured credentials yet (no token in
    /// Keychain, no list selected, no Google account linked).
    /// UI should route to the Settings tab that resolves the
    /// missing piece.
    case notConfigured

    /// Network unreachable, DNS failure, request timed out, TLS
    /// handshake error — anything that prevented the request
    /// from completing a round-trip. Queue the mutation and
    /// retry when `NetworkMonitor.isOnline` flips back to true.
    case offline(underlying: URLError?)

    /// Server-side authentication failure (401 / 403). The token
    /// has expired or been revoked. UI should surface a "Re-
    /// conectar ClickUp" affordance that re-runs the OAuth flow.
    case unauthorized

    /// ClickUp / Google rate limit (429). Carries the suggested
    /// retry delay if the server provided `Retry-After`. The
    /// offline queue uses this to back off without dropping the
    /// mutation.
    case rateLimited(retryAfterSeconds: TimeInterval?)

    /// 5xx — upstream is having a bad time. Worth a retry; if it
    /// persists past a few attempts, surface a banner.
    case serverError(statusCode: Int)

    /// Generic 4xx that doesn't fit the cases above (validation,
    /// not found, conflict). The status code + a server-provided
    /// message (if parseable) get bubbled so the recovery sheet
    /// can show what went wrong.
    case clientError(statusCode: Int, message: String?)

    /// Successful HTTP response but the body didn't parse / was
    /// shaped differently than expected. Usually means ClickUp
    /// changed an endpoint and we haven't caught up — surface to
    /// the user as "atualize o Apollo".
    case decoding(underlying: Error)

    // MARK: - Equatable

    static func == (lhs: APIError, rhs: APIError) -> Bool {
        switch (lhs, rhs) {
        case (.notConfigured, .notConfigured),
             (.unauthorized,  .unauthorized):
            return true
        case (.offline, .offline):
            return true
        case (.rateLimited(let a), .rateLimited(let b)):
            return a == b
        case (.serverError(let a), .serverError(let b)):
            return a == b
        case (.clientError(let aCode, let aMsg),
              .clientError(let bCode, let bMsg)):
            return aCode == bCode && aMsg == bMsg
        case (.decoding, .decoding):
            return true
        default:
            return false
        }
    }
}

// MARK: - Classification

extension APIError {

    /// True iff retrying later (after either a backoff or a
    /// network-back signal) has a meaningful chance of succeeding.
    /// `notConfigured` / `unauthorized` / `clientError(400/404/etc)`
    /// won't fix themselves with time — the user has to act.
    var isTransient: Bool {
        switch self {
        case .offline, .rateLimited, .serverError:
            return true
        case .notConfigured, .unauthorized, .clientError, .decoding:
            return false
        }
    }

    /// Human-readable headline for a toast / banner. Kept short
    /// (≤ 28 chars) so it fits the in-app toast width without
    /// wrapping.
    var userFacingTitle: String {
        switch self {
        case .notConfigured:    return "Configure o ClickUp"
        case .offline:          return "Sem conexão"
        case .unauthorized:     return "Sessão expirou"
        case .rateLimited:      return "Limite de requisições"
        case .serverError:      return "Servidor instável"
        case .clientError:      return "Erro na operação"
        case .decoding:         return "Atualize o Apollo"
        }
    }

    /// One-line explainer for the recovery toast / sheet.
    var userFacingMessage: String {
        switch self {
        case .notConfigured:
            return "Vá em Configurações → ClickUp pra conectar."
        case .offline:
            return "A mudança fica na fila e roda quando a internet voltar."
        case .unauthorized:
            return "Reconecte sua conta do ClickUp nas configurações."
        case .rateLimited(let retry):
            if let r = retry {
                return "Tentando de novo em \(Int(r))s."
            }
            return "Aguarde um momento e tente de novo."
        case .serverError(let code):
            return "ClickUp respondeu \(code). Vamos repetir."
        case .clientError(_, let msg):
            return msg ?? "A operação foi rejeitada."
        case .decoding:
            return "O formato da resposta mudou — atualize o app."
        }
    }

    /// Suggested label for the action button on the recovery
    /// banner. Returns `nil` when there's no actionable button
    /// (offline errors just retry themselves; the user doesn't
    /// need to click anything).
    var actionLabel: String? {
        switch self {
        case .unauthorized:     return "Reconectar"
        case .notConfigured:    return "Configurar"
        case .serverError,
             .clientError:      return "Tentar de novo"
        case .offline,
             .rateLimited,
             .decoding:         return nil
        }
    }
}

// MARK: - Factory from URL machinery

extension APIError {

    /// Inspect a `(Data, URLResponse)` tuple plus an optional
    /// thrown URLError and classify into the typed taxonomy.
    /// Call this from every API method's response-handling
    /// codepath; it normalises the messy mix of `URLError` codes
    /// and HTTP status conventions into one switchable enum.
    static func classify(response: URLResponse?,
                         data: Data?,
                         thrown: Error?) -> APIError? {
        if let urlErr = thrown as? URLError {
            switch urlErr.code {
            case .notConnectedToInternet,
                 .networkConnectionLost,
                 .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed:
                return .offline(underlying: urlErr)
            default:
                return .offline(underlying: urlErr)
            }
        }
        if let thrown {
            // Anything else thrown (JSONDecoder, our own internal
            // sanity-check) → decoding bucket.
            return .decoding(underlying: thrown)
        }
        guard let http = response as? HTTPURLResponse else {
            return nil
        }
        switch http.statusCode {
        case 200..<300:
            return nil
        case 401, 403:
            return .unauthorized
        case 429:
            // ClickUp sets `X-RateLimit-Reset` (epoch seconds) on
            // 429s; also honour the standard `Retry-After` header.
            let retry = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
            return .rateLimited(retryAfterSeconds: retry)
        case 400..<500:
            // Try to surface the server's own error string.
            let msg = data.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }?["err"] as? String
            return .clientError(statusCode: http.statusCode, message: msg)
        case 500...:
            return .serverError(statusCode: http.statusCode)
        default:
            return .serverError(statusCode: http.statusCode)
        }
    }
}
