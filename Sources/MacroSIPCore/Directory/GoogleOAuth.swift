import CryptoKit
import Foundation
import Network
import os

/// Sign-in with Google for a Google Contacts source (docs/DIRECTORY.md, "Google Contacts"): the OAuth 2.0
/// authorization code flow for a desktop client with PKCE (RFC 7636, S256) and a loopback redirect
/// (RFC 8252 § 7.3). `signIn` listens on `http://127.0.0.1:<ephemeral port>/`, hands the authorization URL
/// to the caller (the app opens the browser), waits for the redirect, exchanges the code for tokens, stores
/// them with `DirectoryCredentials.setGoogleToken` and returns the account e-mail. `refresh` renews an
/// access token; on `invalid_grant` (access revoked, refresh token expired) the token is deleted and
/// `.signInRequired` is thrown, so Settings shows the sign-in group again.
public struct GoogleOAuth: Sendable {
    public typealias Fetch = URLDirectoryProvider.Fetch

    /// The OAuth client of the product's Google Cloud project.
    ///
    /// Before release the owner fills in `clientID` (and `clientSecret` when Google issued one) with the
    /// credentials of an OAuth client of type "Desktop app" from Google Cloud › APIs & Services › Credentials,
    /// in a project with the People API enabled. A desktop client secret is not confidential (RFC 8252 § 8.5);
    /// PKCE protects the exchange. While `clientID` is empty `signIn` fails with
    /// `DirectoryError.notConfigured(.googleClientID)`.
    public struct Configuration: Sendable {
        public static let clientID = ""
        public static let clientSecret: String? = nil
        /// Read-only contacts plus the account e-mail: `openid` makes Google return an id token, `email` puts
        /// the address in it.
        public static let scopes = ["openid", "email", "https://www.googleapis.com/auth/contacts.readonly"]
        public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
        public static let peopleEndpoint = URL(string: "https://people.googleapis.com/v1/")!
        /// Whether this build can sign in at all.
        public static var isConfigured: Bool { !clientID.isEmpty }
    }

    public let credentials: DirectoryCredentials
    let clientID: String
    let clientSecret: String?
    let fetch: Fetch
    /// How long `signIn` waits for the browser.
    let timeout: TimeInterval
    let now: @Sendable () -> Date
    let authorizationEndpoint: URL
    let tokenEndpoint: URL

    public init(credentials: DirectoryCredentials, clientID: String = Configuration.clientID,
                clientSecret: String? = Configuration.clientSecret, fetch: Fetch? = nil, timeout: TimeInterval = 120,
                now: @escaping @Sendable () -> Date = { Date() },
                authorizationEndpoint: URL = Configuration.authorizationEndpoint, tokenEndpoint: URL = Configuration.tokenEndpoint) {
        self.credentials = credentials
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.fetch = fetch ?? URLDirectoryProvider.urlSessionFetch
        self.timeout = timeout
        self.now = now
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
    }

    // MARK: Sign-in

    /// Runs the browser sign-in for the source and returns the account e-mail (empty when Google did not
    /// tell). `openURL` receives the authorization URL once; the caller opens it in the default browser.
    /// Waits at most `timeout` (2 minutes) for the redirect and stops at once when the task is cancelled.
    public func signIn(sourceID: UUID, openURL: @Sendable (URL) -> Void) async throws -> String {
        guard !clientID.isEmpty else { throw DirectoryError.notConfigured(.googleClientID) }
        do {
            let server = try await LoopbackRedirectServer.start()
            defer { server.stop() }
            let request = AuthorizationRequest(clientID: clientID, redirectURI: server.redirectURI, endpoint: authorizationEndpoint)
            server.expect(state: request.state)
            openURL(request.url)
            let code = try await Self.withTimeout(timeout) { try await server.redirect() }
            let response = try await exchange(code: code, request: request)
            try credentials.setGoogleToken(response.token, for: sourceID)
            if let email = response.idToken.flatMap(Self.email(fromIDToken:)) { return email }
            return (try? await accountEmail(accessToken: response.token.accessToken)) ?? ""
        } catch {
            throw DirectoryError.from(error)
        }
    }

    /// Runs `body` for at most `seconds`; the body is cancelled when the time is up or the caller gives up.
    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw DirectoryError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw DirectoryError.cancelled }
            return first
        }
    }

    // MARK: Authorization request

    /// The URL the browser opens and the secrets that go with it.
    public struct AuthorizationRequest: Sendable, Equatable {
        public let url: URL
        public let redirectURI: String
        public let state: String
        public let codeVerifier: String

        public init(clientID: String, redirectURI: String, scopes: [String] = Configuration.scopes,
                    state: String = PKCE.randomToken(), codeVerifier: String = PKCE.randomToken(),
                    endpoint: URL = Configuration.authorizationEndpoint) {
            self.redirectURI = redirectURI
            self.state = state
            self.codeVerifier = codeVerifier
            var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            c.queryItems = [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
                URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: codeVerifier)),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent"),
            ]
            url = c.url!
        }
    }

    /// RFC 7636: a random verifier and its S256 challenge.
    public enum PKCE {
        /// 32 random bytes, base64url without padding (43 characters).
        public static func randomToken() -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            var rng = SystemRandomNumberGenerator()
            for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max, using: &rng) }
            return base64URL(Data(bytes))
        }

        public static func challenge(for verifier: String) -> String {
            base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }

        static func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        static func base64URLDecode(_ s: String) -> Data? {
            var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while t.count % 4 != 0 { t += "=" }
            return Data(base64Encoded: t)
        }
    }

    // MARK: Tokens

    struct TokenResponse: Sendable {
        var token: GoogleToken
        var idToken: String?
    }

    func exchange(code: String, request: AuthorizationRequest) async throws -> TokenResponse {
        try await post([
            ("code", code), ("client_id", clientID), ("redirect_uri", request.redirectURI),
            ("grant_type", "authorization_code"), ("code_verifier", request.codeVerifier),
        ], keeping: nil)
    }

    /// A new access token for `token`. Deletes the token and throws `.signInRequired` when Google answers
    /// `invalid_grant` or the token has no refresh token.
    public func refresh(_ token: GoogleToken, sourceID: UUID) async throws -> GoogleToken {
        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
            try? credentials.setGoogleToken(nil, for: sourceID)
            throw DirectoryError.signInRequired
        }
        do {
            let fresh = try await post([
                ("client_id", clientID), ("refresh_token", refreshToken), ("grant_type", "refresh_token"),
            ], keeping: token).token
            try credentials.setGoogleToken(fresh, for: sourceID)
            return fresh
        } catch DirectoryError.signInRequired {
            try? credentials.setGoogleToken(nil, for: sourceID)
            throw DirectoryError.signInRequired
        } catch {
            throw DirectoryError.from(error)
        }
    }

    private struct TokenJSON: Decodable {
        var access_token: String?
        var expires_in: Double?
        var refresh_token: String?
        var scope: String?
        var id_token: String?
        var error: String?
        var error_description: String?
    }

    /// One request to the token endpoint. `keeping` is the previous token whose refresh token and scope are
    /// kept when the answer has none (a refresh answer usually has no refresh token).
    private func post(_ form: [(String, String)], keeping previous: GoogleToken?) async throws -> TokenResponse {
        var fields = form
        if let clientSecret, !clientSecret.isEmpty { fields.append(("client_secret", clientSecret)) }
        var r = URLRequest(url: tokenEndpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = Data(Self.formEncode(fields).utf8)
        let (data, http) = try await fetch(r)
        let json = try? JSONDecoder().decode(TokenJSON.self, from: data)
        if let http, !(200..<300).contains(http.statusCode) {
            if json?.error == "invalid_grant" { throw DirectoryError.signInRequired }
            if let text = json?.error_description ?? json?.error, !text.isEmpty { throw DirectoryError.server(text) }
            throw DirectoryError.http(http.statusCode)
        }
        guard let json, let access = json.access_token, !access.isEmpty else {
            throw DirectoryError.server("Unexpected answer from the Google token endpoint")
        }
        let token = GoogleToken(accessToken: access,
                                refreshToken: json.refresh_token ?? previous?.refreshToken,
                                expiresAt: json.expires_in.map { now().addingTimeInterval($0) },
                                scope: json.scope ?? previous?.scope)
        return TokenResponse(token: token, idToken: json.id_token)
    }

    static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { k, v in
            (k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k) + "=" + (v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)
        }.joined(separator: "&")
    }

    // MARK: Account e-mail

    /// The `email` claim of an OpenID Connect id token. The token comes straight from Google over TLS and is
    /// used for display only, so the signature is not checked.
    public static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let payload = PKCE.base64URLDecode(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let email = json["email"] as? String, !email.isEmpty else { return nil }
        return email
    }

    /// `people/me` for the primary e-mail, when the id token did not carry one.
    func accountEmail(accessToken: String) async throws -> String? {
        var c = URLComponents(url: Configuration.peopleEndpoint.appendingPathComponent("people/me"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "personFields", value: "emailAddresses")]
        var r = URLRequest(url: c.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        r.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        let (data, http) = try await fetch(r)
        if let http, !(200..<300).contains(http.statusCode) { throw DirectoryError.http(http.statusCode) }
        return GooglePeople.primaryEmail(try GooglePeople.decode(GooglePeople.Person.self, from: data))
    }
}

// MARK: - Loopback redirect

/// The one-shot HTTP listener of the sign-in: `http://127.0.0.1:<port>/`. Answers the redirect with a
/// plain "you can close this window" page and hands the authorization code to `redirect()`. A request
/// whose `state` is not the expected one is refused (400) and the listener keeps waiting; anything else
/// (a favicon, a stray probe) gets 404.
final class LoopbackRedirectServer: @unchecked Sendable {
    let port: UInt16
    var redirectURI: String { "http://127.0.0.1:\(port)/" }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.hsmm.macrosip.directory.google-signin")

    private struct State: @unchecked Sendable {
        var expected: String?
        var result: Result<String, DirectoryError>?
        var continuation: CheckedContinuation<String, Error>?
        var cancelled = false
        /// Accepted connections still open; cancelled by `stop()`.
        var connections: [ObjectIdentifier: NWConnection] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> LoopbackRedirectServer {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = false
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "com.hsmm.macrosip.directory.google-signin.start")
        let once = OSAllocatedUnfairLock(initialState: false)
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                listener.stateUpdateHandler = { st in
                    switch st {
                    case .ready: if once.withLock({ let was = $0; $0 = true; return !was }) { cont.resume() }
                    case .failed(let e), .waiting(let e):
                        if once.withLock({ let was = $0; $0 = true; return !was }) { cont.resume(throwing: DirectoryError.server(e.localizedDescription)) }
                    default: break
                    }
                }
                listener.newConnectionHandler = { _ in }
                listener.start(queue: queue)
            }
        } catch {
            listener.stateUpdateHandler = nil
            listener.cancel()
            throw error
        }
        guard let port = listener.port?.rawValue, port != 0 else {
            listener.cancel()
            throw DirectoryError.server("The loopback listener has no port")
        }
        let server = LoopbackRedirectServer(listener: listener, port: port)
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = { [weak server] c in server?.accept(c) }
        return server
    }

    func stop() {
        listener.cancel()
        let (cont, open) = state.withLock { s -> (CheckedContinuation<String, Error>?, [NWConnection]) in
            s.cancelled = true
            defer { s.continuation = nil; s.connections = [:] }
            return (s.continuation, Array(s.connections.values))
        }
        for c in open { c.cancel() }
        cont?.resume(throwing: CancellationError())
    }

    /// The `state` the next redirect must carry.
    func expect(state expected: String) {
        state.withLock { $0.expected = expected }
    }

    /// The authorization code of the redirect. Throws `CancellationError` when the task is cancelled or the
    /// server stopped, the Google error otherwise (`.accessDenied` when the user refused).
    func redirect() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                let ready: Result<String, Error>? = state.withLock { s in
                    if let r = s.result { return r.mapError { $0 as Error } }
                    if s.cancelled { return .failure(CancellationError()) }
                    s.continuation = cont
                    return nil
                }
                if let ready { cont.resume(with: ready) }
            }
        } onCancel: {
            let cont = state.withLock { s -> CheckedContinuation<String, Error>? in
                s.cancelled = true
                defer { s.continuation = nil }
                return s.continuation
            }
            cont?.resume(throwing: CancellationError())
        }
    }

    private func accept(_ c: NWConnection) {
        let stopped = state.withLock { s -> Bool in
            if s.cancelled { return true }
            s.connections[ObjectIdentifier(c)] = c
            return false
        }
        guard !stopped else { c.cancel(); return }
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.forget(c)
            default: break
            }
        }
        c.start(queue: queue)
        receive(c, Data())
    }

    /// The connection is done: it is no longer `stop()`'s business.
    private func forget(_ c: NWConnection) {
        state.withLock { _ = $0.connections.removeValue(forKey: ObjectIdentifier(c)) }
    }

    private func receive(_ c: NWConnection, _ pending: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, error in
            guard let self else { c.cancel(); return }
            var buf = pending
            if let data { buf.append(data) }
            let headersComplete = buf.range(of: Data("\r\n\r\n".utf8)) != nil
            if headersComplete || done || error != nil || buf.count >= 16384 {
                guard !buf.isEmpty else { c.cancel(); return }
                let raw = String(decoding: buf, as: UTF8.self)
                let expected = state.withLock { $0.expected } ?? ""
                let answer = Self.handle(request: raw, expectedState: expected)
                c.send(content: Data(answer.response.utf8), completion: .contentProcessed { _ in c.cancel() })
                self.deliver(answer)
                return
            }
            self.receive(c, buf)
        }
    }

    private func deliver(_ answer: Answer) {
        let outcome: Result<String, DirectoryError>
        if let code = answer.code { outcome = .success(code) }
        else if let error = answer.error { outcome = .failure(error) }
        else { return }
        let cont = state.withLock { s -> CheckedContinuation<String, Error>? in
            guard s.result == nil else { return nil }
            s.result = outcome
            defer { s.continuation = nil }
            return s.continuation
        }
        cont?.resume(with: outcome.mapError { $0 as Error })
    }

    struct Answer: Equatable {
        var response: String
        var code: String?
        var error: DirectoryError?
    }

    /// One HTTP request as text → the HTTP response and what the redirect carried.
    static func handle(request raw: String, expectedState: String) -> Answer {
        let line = raw.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return Answer(response: response(405, "Method not allowed")) }
        guard let target = URLComponents(string: "http://127.0.0.1" + parts[1]), target.path == "/" || target.path.isEmpty else {
            return Answer(response: response(404, "Not found"))
        }
        let query = Dictionary((target.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if let error = query["error"] {
            let reason: DirectoryError = error == "access_denied" ? .accessDenied : .server(query["error_description"] ?? error)
            return Answer(response: response(200, "Sign-in was cancelled. You can close this window and return to MacroSIP."), error: reason)
        }
        guard let code = query["code"], !code.isEmpty else { return Answer(response: response(404, "Not found")) }
        guard !expectedState.isEmpty, query["state"] == expectedState else {
            return Answer(response: response(400, "This sign-in answer does not belong to the current request."))
        }
        return Answer(response: response(200, "Sign-in complete. You can close this window and return to MacroSIP."), code: code)
    }

    private static func response(_ status: Int, _ text: String) -> String {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
        let body = """
        <!doctype html><html><head><meta charset="utf-8"><title>MacroSIP</title></head>\
        <body style="font-family: -apple-system, 'Helvetica Neue', sans-serif; text-align: center; padding: 4em 1em; color: #222">\
        <p style="font-size: 1.2em">\(text)</p></body></html>
        """
        let bytes = body.utf8.count
        return "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" + body
    }
}
