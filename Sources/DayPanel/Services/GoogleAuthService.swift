import Foundation
import AppKit
import Network
import CryptoKit

/// OAuth 2.0 client for Google's "Installed App" flow with PKCE.
///
/// Why this exists: Apollo's Calendar integration uses EventKit,
/// which on macOS does NOT allow programmatic attendee insertion.
/// To actually invite people to events the user creates from
/// Apollo (the AI agent's CREATE_EVENT marker, the manual
/// "+ Evento" form), we have to call Google's REST API directly
/// — and that needs an OAuth access token.
///
/// Setup the user must do once:
///   1. Open https://console.cloud.google.com
///   2. Create a project (or pick an existing one)
///   3. Enable "Google Calendar API"
///   4. APIs & Services → Credentials → "+ CREATE CREDENTIALS"
///      → "OAuth client ID" → Application type = "Desktop app"
///   5. Copy the Client ID, paste into Apollo Settings → Google Calendar
///
/// Apollo never sees the user's password — the OAuth flow opens
/// the user's default browser, the user signs in directly with
/// Google, and Google redirects back to a temporary localhost
/// HTTP server Apollo spins up just for that redirect.
/// Not annotated `@MainActor` so it can be a property of the
/// non-actor-isolated `AppState`. The `@Published` mutations
/// hop to the main thread explicitly via `publish(...)` below;
/// the OAuth network work happens off-thread.
final class GoogleAuthService: ObservableObject {

    /// **EMBEDDED OAUTH CREDENTIALS — sourced from a
    /// gitignored `GoogleAuthSecrets.swift` so the actual
    /// values never land in the public tree.**
    ///
    /// Google's Desktop-app OAuth flow requires BOTH a
    /// Client ID and a Client Secret in the token exchange,
    /// even when using PKCE. Per Google's own docs the
    /// "client_secret" for Desktop apps isn't actually
    /// secret (the binary is distributable), but GitHub's
    /// secret scanner still flags it, so we keep it out of
    /// version control.
    ///
    /// First-time setup: copy
    /// `GoogleAuthSecrets.example.swift` to
    /// `GoogleAuthSecrets.swift` and paste the values from
    /// Google Cloud Console (Credentials → OAuth client ID
    /// → Application type: Desktop app). The example file
    /// has the full step-by-step.
    static let embeddedClientId: String = GoogleAuthSecrets.clientId
    /// Empty string disables the connect flow (Settings
    /// card shows "developer setup pending").
    static let embeddedClientSecret: String = GoogleAuthSecrets.clientSecret

    // MARK: - State

    @Published private(set) var isConnected: Bool
    @Published private(set) var connectedEmail: String?
    @Published private(set) var lastError: String?
    @Published private(set) var inProgress: Bool = false

    /// Routes all `@Published` writes through the main thread —
    /// SwiftUI assumes ObservableObject mutations happen on
    /// main, and Combine asserts otherwise in DEBUG.
    private func publish(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    /// `expiresAt` is computed from `expires_in` returned by
    /// Google. We refresh proactively 60s before expiry so a
    /// long-running session never sees a 401.
    private var expiresAt: Date = .distantPast
    private var listener: NWListener?
    private var pkceVerifier: String = ""

    /// Per-flow CSRF token. Generated fresh by `connect()` and
    /// sent to Google as the OAuth `state` parameter; the
    /// localhost redirect listener echoes whatever Google
    /// reflects back, and we MUST refuse any callback whose
    /// `state` value doesn't match this — otherwise an attacker
    /// on the same machine (or a malicious page that knows the
    /// listener port) can race the real callback by hitting
    /// `http://127.0.0.1:PORT/?code=…` with their own code
    /// and trick the app into exchanging it for tokens scoped
    /// to the attacker's account. Cleared after each flow ends.
    private var expectedState: String = ""

    /// `calendar.events` grants both READ and WRITE access
    /// to events on every calendar the user has access to —
    /// including the primary one Apollo lists from. Avoids
    /// the broader `calendar` scope (which also includes
    /// calendar list / settings) that we don't actually need
    /// and that would force every existing user to re-auth.
    private let scope = "https://www.googleapis.com/auth/calendar.events"

    // MARK: - Init

    init() {
        let token = KeychainHelper.load(for: KeychainHelper.Keys.googleAccessToken)
        self.isConnected = (token?.isEmpty == false)
        self.connectedEmail = KeychainHelper.load(for: KeychainHelper.Keys.googleUserEmail)
    }

    /// Returns true iff Apollo was built with an embedded
    /// Client ID. When false, the Settings card surfaces the
    /// "developer setup pending" message instead of the
    /// connect button.
    var hasClientId: Bool {
        !Self.embeddedClientId.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Resolves the active Client ID. Currently always the
    /// baked-in constant, but kept as an indirection in case
    /// we want to support per-build overrides via env var or
    /// Keychain later without rewiring every call site.
    private var clientId: String {
        Self.embeddedClientId.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Public API

    /// Starts the OAuth flow. Spins up a localhost listener on
    /// a free port, opens the system browser pointed at Google's
    /// authorization endpoint, waits for the redirect.
    func connect() async {
        let clientId = self.clientId
        guard !clientId.isEmpty else {
            publish { self.lastError = "Apollo não foi configurado com Client ID embutido. Atualize `GoogleAuthService.embeddedClientId` no código fonte." }
            return
        }
        publish { self.inProgress = true }
        defer { publish { self.inProgress = false } }

        do {
            // PKCE pair — Google requires it for installed apps.
            let verifier = Self.makePKCEVerifier()
            self.pkceVerifier = verifier
            let challenge = Self.pkceChallenge(for: verifier)

            // CSRF token — bound to this flow only. The listener
            // refuses any redirect whose `state` doesn't match.
            let state = Self.makeOAuthState()
            self.expectedState = state

            // Spin up a one-shot localhost listener BEFORE
            // opening the browser so we don't lose the
            // redirect to a race condition.
            let port = try await startLoopbackListener()
            let redirectURI = "http://127.0.0.1:\(port)"

            // Build Google's authorization URL.
            var components = URLComponents(string:
                "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = [
                .init(name: "client_id",             value: clientId),
                .init(name: "redirect_uri",          value: redirectURI),
                .init(name: "response_type",         value: "code"),
                .init(name: "scope",                 value: scope),
                .init(name: "code_challenge",        value: challenge),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "access_type",           value: "offline"),
                .init(name: "prompt",                value: "consent"),
                .init(name: "state",                 value: state),
            ]
            guard let url = components.url else {
                throw AuthError.message("URL de autorização inválida")
            }

            NSWorkspace.shared.open(url)

            // Wait for the redirect — captured by the listener.
            let code = try await waitForCode()
            stopListener()
            // Single-use — flush so a stray late callback can't
            // re-use the same nonce in a subsequent connect.
            self.expectedState = ""

            // Exchange code for tokens.
            try await exchangeCode(
                code: code,
                clientId: clientId,
                redirectURI: redirectURI,
                verifier: verifier
            )
            // Get the user's email so the Settings card can show
            // who's connected.
            try? await fetchUserEmail()
            publish {
                self.isConnected = true
                self.lastError = nil
            }
        } catch {
            stopListener()
            // Don't let a half-finished flow leave the nonce in
            // place — that would let a SECOND attempted flow
            // accept a callback from the first.
            self.expectedState = ""
            let msg = (error as? AuthError)?.message ?? error.localizedDescription
            publish { self.lastError = msg }
        }
    }

    /// Drops the stored tokens. The user can re-connect at any
    /// time from Settings.
    func disconnect() {
        KeychainHelper.delete(for: KeychainHelper.Keys.googleAccessToken)
        KeychainHelper.delete(for: KeychainHelper.Keys.googleRefreshToken)
        KeychainHelper.delete(for: KeychainHelper.Keys.googleUserEmail)
        expiresAt = .distantPast
        publish {
            self.isConnected = false
            self.connectedEmail = nil
        }
    }

    /// Returns a valid access token, refreshing if it's about
    /// to expire. Throws if the user isn't connected and the
    /// caller can't recover.
    func validAccessToken() async throws -> String {
        guard let token = KeychainHelper.load(for: KeychainHelper.Keys.googleAccessToken),
              !token.isEmpty
        else { throw AuthError.notConnected }

        if Date() < expiresAt.addingTimeInterval(-60) {
            return token
        }
        // Refresh — proactive 60s before stamp.
        try await refreshAccessToken()
        guard let fresh = KeychainHelper.load(for: KeychainHelper.Keys.googleAccessToken),
              !fresh.isEmpty
        else { throw AuthError.notConnected }
        return fresh
    }

    // MARK: - Token exchange / refresh

    private func exchangeCode(
        code: String,
        clientId: String,
        redirectURI: String,
        verifier: String
    ) async throws {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded",
                     forHTTPHeaderField: "Content-Type")
        var body = [
            "code":          code,
            "client_id":     clientId,
            "redirect_uri":  redirectURI,
            "grant_type":    "authorization_code",
            "code_verifier": verifier,
        ]
        // Google's Desktop-app token endpoint requires the
        // client_secret even when PKCE is in play. See the
        // doc-comment on `embeddedClientSecret` for the
        // (slightly non-obvious) rationale.
        let secret = Self.embeddedClientSecret.trimmingCharacters(in: .whitespaces)
        if !secret.isEmpty { body["client_secret"] = secret }
        req.httpBody = Self.formEncode(body).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.expect2xx(response, data: data)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let access = json?["access_token"] as? String else {
            throw AuthError.message("Resposta sem access_token")
        }
        KeychainHelper.save(access, for: KeychainHelper.Keys.googleAccessToken)
        if let refresh = json?["refresh_token"] as? String {
            KeychainHelper.save(refresh, for: KeychainHelper.Keys.googleRefreshToken)
        }
        let expiresIn = (json?["expires_in"] as? Double) ?? 3600
        self.expiresAt = Date().addingTimeInterval(expiresIn)
    }

    private func refreshAccessToken() async throws {
        guard let refresh = KeychainHelper.load(for: KeychainHelper.Keys.googleRefreshToken),
              !refresh.isEmpty
        else { throw AuthError.notConnected }
        let clientId = self.clientId
        guard !clientId.isEmpty else { throw AuthError.notConnected }

        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded",
                     forHTTPHeaderField: "Content-Type")
        var body = [
            "refresh_token": refresh,
            "client_id":     clientId,
            "grant_type":    "refresh_token",
        ]
        let secret = Self.embeddedClientSecret.trimmingCharacters(in: .whitespaces)
        if !secret.isEmpty { body["client_secret"] = secret }
        req.httpBody = Self.formEncode(body).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.expect2xx(response, data: data)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let access = json?["access_token"] as? String else {
            throw AuthError.message("Refresh sem access_token")
        }
        KeychainHelper.save(access, for: KeychainHelper.Keys.googleAccessToken)
        let expiresIn = (json?["expires_in"] as? Double) ?? 3600
        self.expiresAt = Date().addingTimeInterval(expiresIn)
    }

    /// Calls Google's userinfo endpoint to grab the email of
    /// whoever just authorised, purely so the Settings card can
    /// display "conectado como joao@…" instead of an opaque
    /// green dot.
    private func fetchUserEmail() async throws {
        let token = try await validAccessToken()
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let email = json["email"] as? String {
            KeychainHelper.save(email, for: KeychainHelper.Keys.googleUserEmail)
            publish { self.connectedEmail = email }
        }
    }

    // MARK: - Loopback listener

    /// Spins up a one-shot HTTP listener on an OS-chosen free
    /// port. Returns the port so the caller can build the
    /// redirect URI. The listener is bound to the loopback
    /// interface only (127.0.0.1), which avoids macOS firewall
    /// prompts and ensures the browser can always reach it
    /// regardless of network state.
    private var pendingContinuation: CheckedContinuation<String, Error>?

    private func startLoopbackListener() async throws -> Int {
        // Bind explicitly to the loopback interface. Default
        // `NWParameters.tcp` would accept connections on any
        // network interface, which can trip the macOS firewall
        // on first launch (silent block, listener stuck in
        // `.waiting`). Loopback-only avoids that path entirely.
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true

        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            // Connection events MUST be on the same queue we're
            // observing the listener on, otherwise the receive
            // callback can fire before the connection's start
            // has propagated and we silently drop the request.
            connection.start(queue: .main)
            self?.handleConnection(connection)
        }

        // `stateUpdateHandler` lets us detect when the listener
        // actually transitions to `.ready` (or fails) — without
        // it the previous code returned the port the moment it
        // was assigned, even if the listener was still in
        // `.waiting` or had failed silently.
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        resumed = true
                        cont.resume(returning: Int(port))
                    }
                case .failed(let error):
                    resumed = true
                    cont.resume(throwing: AuthError.message(
                        "Falha ao abrir porta local: \(error.localizedDescription)"
                    ))
                case .cancelled:
                    if !resumed {
                        resumed = true
                        cont.resume(throwing: AuthError.message("Listener cancelado"))
                    }
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
    }

    private func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            self.pendingContinuation = cont
        }
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        // Wait for the connection to actually become ready
        // before reading. Calling `receive` on a connection
        // still in `.preparing` is documented as supported
        // (NWConnection queues operations) but in practice has
        // produced cases where the receive callback never
        // fires on macOS — explicit state observation here
        // gives us a deterministic moment to start reading.
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.readRequest(on: connection)
            case .failed(let error):
                self.pendingContinuation?.resume(throwing:
                    AuthError.message("Conexão falhou: \(error.localizedDescription)"))
                self.pendingContinuation = nil
                connection.cancel()
            default:
                break
            }
        }
    }

    private func readRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let error = error {
                self.pendingContinuation?.resume(throwing:
                    AuthError.message("Receive falhou: \(error.localizedDescription)"))
                self.pendingContinuation = nil
                connection.cancel()
                return
            }
            guard let data = data,
                  let request = String(data: data, encoding: .utf8)
            else {
                connection.cancel()
                return
            }

            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            // "GET /?code=…&scope=… HTTP/1.1"
            let pathPart = firstLine.components(separatedBy: " ").dropFirst().first ?? ""
            let codeOrError = Self.extractCode(
                from: String(pathPart),
                expectedState: self.expectedState
            )

            // Send a friendly HTML response so the user's
            // browser tab shows a clear "you can close this"
            // message instead of timing out. The connection
            // is only cancelled AFTER the send completes —
            // cancelling earlier would close the socket
            // before the browser finished receiving the
            // bytes, leaving the tab spinning forever.
            let html = """
            <html><head><meta charset='utf-8'><title>Apollo</title></head>
            <body style='font-family:-apple-system,sans-serif;text-align:center;padding:80px;background:#f5f5f7;color:#1d1d1f;'>
            <h2>Apollo IA</h2>
            <p>Conexão com o Google Calendar concluída. Pode fechar esta aba.</p>
            </body></html>
            """
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(html.utf8.count)\r
            Connection: close\r
            \r
            \(html)
            """
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

            // Resume the awaiting `connect()` task with the
            // code (or error). This is what unblocks the
            // OAuth flow to proceed to the token exchange.
            switch codeOrError {
            case .success(let code):
                self.pendingContinuation?.resume(returning: code)
            case .failure(let err):
                self.pendingContinuation?.resume(throwing: err)
            }
            self.pendingContinuation = nil
        }
    }

    /// Parses the redirect path for `code=` or `error=`, AND
    /// enforces that the `state` query parameter matches the
    /// nonce we generated at the start of the flow. Without the
    /// state check, any process on the same machine that knows
    /// (or guesses) the listener port can race a forged
    /// `http://127.0.0.1:PORT/?code=<attacker>` to the listener
    /// and trick the app into exchanging it for tokens scoped
    /// to the attacker's Google account.
    private static func extractCode(from path: String,
                                    expectedState: String) -> Result<String, Error> {
        guard let comp = URLComponents(string: "http://localhost\(path)") else {
            return .failure(AuthError.message("Redirect malformado"))
        }
        if let err = comp.queryItems?.first(where: { $0.name == "error" })?.value {
            return .failure(AuthError.message("Google retornou erro: \(err)"))
        }
        // CSRF: refuse any redirect whose state doesn't match
        // the nonce stored at the start of this flow. Empty
        // `expectedState` means no flow is in progress — also
        // a reject.
        let receivedState = comp.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
        guard !expectedState.isEmpty, receivedState == expectedState else {
            return .failure(AuthError.message(
                "Redirect rejeitado: state inválido (possível ataque CSRF)."
            ))
        }
        if let code = comp.queryItems?.first(where: { $0.name == "code" })?.value {
            return .success(code)
        }
        return .failure(AuthError.message("Redirect sem código"))
    }

    /// 32-byte CSPRNG nonce, URL-safe base64. Same shape +
    /// entropy as the PKCE verifier — Google accepts up to 256
    /// chars on `state`, and 32 random bytes is way past any
    /// practical collision / guessing threshold.
    private static func makeOAuthState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    // MARK: - PKCE helpers

    private static func makePKCEVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func pkceChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncoded()
    }

    // MARK: - Helpers

    private static func formEncode(_ dict: [String: String]) -> String {
        dict.map { k, v in
            let kEnc = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
            let vEnc = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
            return "\(kEnc)=\(vEnc)"
        }.joined(separator: "&")
    }

    private static func expect2xx(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.message("Google \(((response as? HTTPURLResponse)?.statusCode).map(String.init) ?? "?"): \(body.prefix(200))")
        }
    }

    enum AuthError: Error {
        case notConnected
        case message(String)
        var message: String {
            switch self {
            case .notConnected: return "Conta Google não conectada"
            case .message(let m): return m
            }
        }
    }
}

private extension Data {
    /// Base64URL = base64 with `+/` → `-_` and trailing `=` stripped.
    /// Required by RFC 7636 for PKCE.
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
