import Foundation
import os
import Testing
@testable import MacroSIPCore

/// A stand-in for the network: answers each request through `handler` and keeps every request it saw.
final class FakeGoogleHTTP: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    private let state = OSAllocatedUnfairLock<(requests: [URLRequest], handler: Handler)>(initialState: ([], { _ in (404, Data()) }))

    init(_ handler: Handler? = nil) {
        if let handler { state.withLock { $0.handler = handler } }
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }
    func set(_ handler: @escaping Handler) { state.withLock { $0.handler = handler } }
    func reset() { state.withLock { $0.requests = [] } }

    var fetch: GoogleOAuth.Fetch {
        { [self] request in
            let handler = state.withLock { s -> Handler in
                s.requests.append(request)
                return s.handler
            }
            let (code, body) = try handler(request)
            let http = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)
            return (body, http)
        }
    }

    /// Requests whose URL path ends with `suffix`.
    func requests(to suffix: String) -> [URLRequest] { requests.filter { $0.url?.path.hasSuffix(suffix) ?? false } }
}

extension URLRequest {
    var queryValues: [String: String] {
        Dictionary((URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }
    var formValues: [String: String] {
        let body = String(decoding: httpBody ?? Data(), as: UTF8.self)
        return Dictionary(body.split(separator: "&").map { pair -> (String, String) in
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            return (kv[0], kv.count > 1 ? kv[1] : "")
        }, uniquingKeysWith: { a, _ in a })
    }
    var bearer: String? { value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") }
}

func json(_ s: String) -> Data { Data(s.utf8) }

/// An unsigned id token with the given claims (the app reads the payload only).
func fakeIDToken(email: String) -> String {
    let header = GoogleOAuth.PKCE.base64URL(json(#"{"alg":"none"}"#))
    let payload = GoogleOAuth.PKCE.base64URL(json(#"{"iss":"https://accounts.google.com","email":"\#(email)","email_verified":true}"#))
    return header + "." + payload + "."
}

let samplePerson = #"""
{"resourceName": "people/c100", "etag": "x",
 "names": [{"metadata": {"primary": true}, "displayName": "Anna Ivanova", "givenName": "Anna", "familyName": "Ivanova"}],
 "phoneNumbers": [
   {"metadata": {"primary": false}, "value": "+7 495 123-45-67", "canonicalForm": "+74951234567", "type": "work", "formattedType": "Work"},
   {"metadata": {"primary": true}, "value": "+7 916 000-11-22", "type": "mobile"},
   {"value": "  ", "type": "home"},
   {"value": "101", "type": "Reception desk"}
 ],
 "organizations": [{"metadata": {"primary": true}, "name": " Example, Inc. ", "title": "CTO"}],
 "emailAddresses": [{"value": "anna.old@example.com"}, {"metadata": {"primary": true}, "value": "anna@example.com"}],
 "photos": [{"metadata": {"primary": true}, "url": "https://lh3.googleusercontent.com/a/photo=s100", "default": false}]}
"""#

@Suite("Google Contacts")
struct DirectoryGoogleTests {
    let source = DirectorySource(kind: .google, name: "Google")

    // MARK: PKCE and the authorization URL

    @Test func pkceKnownVector() {
        // RFC 7636 appendix B.
        #expect(GoogleOAuth.PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let a = GoogleOAuth.PKCE.randomToken(), b = GoogleOAuth.PKCE.randomToken()
        #expect(a != b && a.count == 43)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(a.allSatisfy { allowed.contains($0) })
        #expect(GoogleOAuth.PKCE.base64URLDecode(GoogleOAuth.PKCE.base64URL(Data([0, 255, 254, 1]))) == Data([0, 255, 254, 1]))
    }

    @Test func authorizationURL() throws {
        let r = GoogleOAuth.AuthorizationRequest(clientID: "cid.apps.googleusercontent.com", redirectURI: "http://127.0.0.1:4321/",
                                                 state: "st", codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let c = try #require(URLComponents(url: r.url, resolvingAgainstBaseURL: false))
        #expect(c.scheme == "https" && c.host == "accounts.google.com" && c.path == "/o/oauth2/v2/auth")
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        #expect(q["client_id"] == "cid.apps.googleusercontent.com")
        #expect(q["redirect_uri"] == "http://127.0.0.1:4321/")
        #expect(q["response_type"] == "code")
        #expect(q["scope"] == "openid email https://www.googleapis.com/auth/contacts.readonly")
        #expect(GoogleOAuth.Configuration.scopes.contains("openid"))          // guarantees an id_token with the e-mail
        #expect(q["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["state"] == "st")
        #expect(q["access_type"] == "offline" && q["prompt"] == "consent")
        #expect(GoogleOAuth.formEncode([("a b", "c&d=e/f~")]) == "a%20b=c%26d%3De%2Ff~")
    }

    @Test func idTokenEmail() {
        #expect(GoogleOAuth.email(fromIDToken: fakeIDToken(email: "me@example.com")) == "me@example.com")
        #expect(GoogleOAuth.email(fromIDToken: "garbage") == nil)
        #expect(GoogleOAuth.email(fromIDToken: "a." + GoogleOAuth.PKCE.base64URL(json(#"{"sub":"1"}"#)) + ".c") == nil)
    }

    // MARK: Loopback redirect

    @Test func redirectRequests() {
        typealias Server = LoopbackRedirectServer
        let ok = Server.handle(request: "GET /?state=xyz&code=4%2FabcDEF HTTP/1.1\r\nHost: 127.0.0.1:1234\r\n\r\n", expectedState: "xyz")
        #expect(ok.code == "4/abcDEF" && ok.error == nil)
        #expect(ok.response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(ok.response.contains("Content-Type: text/html") && ok.response.contains("You can close this window"))
        let body = ok.response.components(separatedBy: "\r\n\r\n")[1]
        #expect(ok.response.contains("Content-Length: \(body.utf8.count)\r\n"))

        let wrongState = Server.handle(request: "GET /?code=abc&state=other HTTP/1.1\r\n\r\n", expectedState: "xyz")
        #expect(wrongState.code == nil && wrongState.error == nil)
        #expect(wrongState.response.hasPrefix("HTTP/1.1 400 "))
        let noState = Server.handle(request: "GET /?code=abc HTTP/1.1\r\n\r\n", expectedState: "xyz")
        #expect(noState.code == nil && noState.error == nil && noState.response.hasPrefix("HTTP/1.1 400 "))
        let notExpecting = Server.handle(request: "GET /?code=abc&state= HTTP/1.1\r\n\r\n", expectedState: "")
        #expect(notExpecting.code == nil)

        let denied = Server.handle(request: "GET /?error=access_denied&state=xyz HTTP/1.1\r\n\r\n", expectedState: "xyz")
        #expect(denied.code == nil && denied.error == .accessDenied && denied.response.hasPrefix("HTTP/1.1 200 "))
        let other = Server.handle(request: "GET /?error=server_error&error_description=Try%20later HTTP/1.1\r\n\r\n", expectedState: "xyz")
        #expect(other.error == .server("Try later"))

        #expect(Server.handle(request: "GET /favicon.ico HTTP/1.1\r\n\r\n", expectedState: "xyz").response.hasPrefix("HTTP/1.1 404 "))
        #expect(Server.handle(request: "GET / HTTP/1.1\r\n\r\n", expectedState: "xyz").response.hasPrefix("HTTP/1.1 404 "))
        #expect(Server.handle(request: "POST /?code=abc&state=xyz HTTP/1.1\r\n\r\n", expectedState: "xyz").response.hasPrefix("HTTP/1.1 405 "))
        #expect(Server.handle(request: "", expectedState: "xyz").code == nil)
    }

    @Test func loopbackServerDeliversTheCode() async throws {
        let server = try await LoopbackRedirectServer.start()
        defer { server.stop() }
        #expect(server.port > 0 && server.redirectURI == "http://127.0.0.1:\(server.port)/")
        server.expect(state: "s1")
        let waiting = Task { try await server.redirect() }
        // A stray request first: refused, the server keeps waiting.
        let (_, stray) = try await URLSession.shared.data(from: URL(string: server.redirectURI + "?code=bad&state=s2")!)
        #expect((stray as? HTTPURLResponse)?.statusCode == 400)
        let (page, response) = try await URLSession.shared.data(from: URL(string: server.redirectURI + "?code=c1&state=s1")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: page, as: UTF8.self).contains("You can close this window"))
        #expect(try await waiting.value == "c1")
    }

    @Test func signInTimesOutAndCancels() async throws {
        let oauth = GoogleOAuth(credentials: .inMemory(), clientID: "cid", fetch: FakeGoogleHTTP().fetch, timeout: 0.3)
        let start = Date()
        await #expect(throws: DirectoryError.timedOut) { try await oauth.signIn(sourceID: UUID()) { _ in } }
        #expect(Date().timeIntervalSince(start) < 3)

        let patient = GoogleOAuth(credentials: .inMemory(), clientID: "cid", fetch: FakeGoogleHTTP().fetch, timeout: 30)
        let task = Task { try await patient.signIn(sourceID: UUID()) { _ in } }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        let result = await task.result
        guard case .failure(let e as DirectoryError) = result else { Issue.record("cancel did not fail with DirectoryError"); return }
        #expect(e == .cancelled)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func signInNeedsAClientID() async {
        let oauth = GoogleOAuth(credentials: .inMemory(), clientID: "", fetch: FakeGoogleHTTP().fetch)
        await #expect(throws: DirectoryError.notConfigured(.googleClientID)) { try await oauth.signIn(sourceID: UUID()) { _ in } }
        #expect(!DirectoryError.notConfigured(.googleClientID).description.isEmpty)
        #expect(DirectoryError.notConfigured(.googleClientID).status == .error(.notConfigured(.googleClientID)))
    }

    // MARK: Token exchange and refresh

    @Test func signInExchangesTheCodeAndStoresTheToken() async throws {
        let http = FakeGoogleHTTP()
        let creds = DirectoryCredentials.inMemory()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let oauth = GoogleOAuth(credentials: creds, clientID: "cid", clientSecret: "shh", fetch: http.fetch, timeout: 10, now: { t0 })
        let seen = OSAllocatedUnfairLock<URL?>(initialState: nil)
        http.set { r in
            guard r.url == GoogleOAuth.Configuration.tokenEndpoint, r.httpMethod == "POST" else { return (404, Data()) }
            let form = r.formValues
            guard form["grant_type"] == "authorization_code", form["code"] == "the-code", form["client_id"] == "cid", form["client_secret"] == "shh",
                  let verifier = form["code_verifier"], let redirect = form["redirect_uri"],
                  let opened = seen.withLock({ $0 }), let q = URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems,
                  q.contains(URLQueryItem(name: "code_challenge", value: GoogleOAuth.PKCE.challenge(for: verifier))),
                  q.contains(URLQueryItem(name: "redirect_uri", value: redirect))
            else { return (400, json(#"{"error":"invalid_request"}"#)) }
            return (200, json(#"{"access_token":"at1","expires_in":3599,"refresh_token":"rt1","scope":"openid https://www.googleapis.com/auth/contacts.readonly email","token_type":"Bearer","id_token":"\#(fakeIDToken(email: "me@example.com"))"}"#))
        }
        let email = try await oauth.signIn(sourceID: source.id) { url in
            seen.withLock { $0 = url }
            // The "browser": follow the redirect straight away.
            let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            let redirect = URL(string: q["redirect_uri"]! + "?state=\(q["state"]!)&code=the-code")!
            Task { _ = try? await URLSession.shared.data(from: redirect) }
        }
        #expect(email == "me@example.com")
        let token = try #require(try creds.googleToken(for: source.id))
        #expect(token.accessToken == "at1" && token.refreshToken == "rt1")
        #expect(token.expiresAt == t0.addingTimeInterval(3599))
        #expect(token.scope?.contains("contacts.readonly") == true)
        #expect(http.requests.count == 1 && http.requests[0].value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(http.requests[0].timeoutInterval == 15)
    }

    @Test func signInWithoutIDTokenAsksPeopleMe() async throws {
        let http = FakeGoogleHTTP()
        let creds = DirectoryCredentials.inMemory()
        let oauth = GoogleOAuth(credentials: creds, clientID: "cid", fetch: http.fetch, timeout: 10)
        http.set { r in
            if r.url == GoogleOAuth.Configuration.tokenEndpoint { return (200, json(#"{"access_token":"at1","expires_in":3599,"refresh_token":"rt1"}"#)) }
            if r.url?.path == "/v1/people/me", r.bearer == "at1" {
                return (200, json(#"{"resourceName":"people/me","emailAddresses":[{"value":"x@example.com"},{"metadata":{"primary":true},"value":"me@example.com"}]}"#))
            }
            return (404, Data())
        }
        let email = try await oauth.signIn(sourceID: source.id) { url in
            let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            let redirect = URL(string: q["redirect_uri"]! + "?state=\(q["state"]!)&code=c")!
            Task { _ = try? await URLSession.shared.data(from: redirect) }
        }
        #expect(email == "me@example.com")
        #expect(http.requests(to: "/people/me").first?.queryValues["personFields"] == "emailAddresses")
    }

    @Test func userRefusalFailsTheSignIn() async throws {
        let oauth = GoogleOAuth(credentials: .inMemory(), clientID: "cid", fetch: FakeGoogleHTTP().fetch, timeout: 10)
        await #expect(throws: DirectoryError.accessDenied) {
            try await oauth.signIn(sourceID: source.id) { url in
                let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
                let redirect = URL(string: q["redirect_uri"]! + "?error=access_denied&state=\(q["state"]!)")!
                Task { _ = try? await URLSession.shared.data(from: redirect) }
            }
        }
    }

    @Test func refreshKeepsTheRefreshTokenAndHandlesInvalidGrant() async throws {
        let http = FakeGoogleHTTP()
        let creds = DirectoryCredentials.inMemory()
        let t0 = Date()
        let oauth = GoogleOAuth(credentials: creds, clientID: "cid", fetch: http.fetch, now: { t0 })
        let old = GoogleToken(accessToken: "old", refreshToken: "rt1", expiresAt: t0.addingTimeInterval(-10), scope: "s")
        try creds.setGoogleToken(old, for: source.id)
        http.set { r in
            let f = r.formValues
            guard f["grant_type"] == "refresh_token", f["refresh_token"] == "rt1", f["client_id"] == "cid", f["client_secret"] == nil else { return (400, Data()) }
            return (200, json(#"{"access_token":"new","expires_in":3600,"token_type":"Bearer"}"#))
        }
        let fresh = try await oauth.refresh(old, sourceID: source.id)
        #expect(fresh == GoogleToken(accessToken: "new", refreshToken: "rt1", expiresAt: t0.addingTimeInterval(3600), scope: "s"))
        #expect(try creds.googleToken(for: source.id) == fresh)

        http.set { _ in (400, json(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#)) }
        await #expect(throws: DirectoryError.signInRequired) { try await oauth.refresh(fresh, sourceID: source.id) }
        #expect(try creds.googleToken(for: source.id) == nil)

        // Without a refresh token there is nothing to renew.
        try creds.setGoogleToken(GoogleToken(accessToken: "x"), for: source.id)
        await #expect(throws: DirectoryError.signInRequired) { try await oauth.refresh(GoogleToken(accessToken: "x"), sourceID: source.id) }
        #expect(try creds.googleToken(for: source.id) == nil)

        // Other token errors keep the token and carry Google's text.
        try creds.setGoogleToken(old, for: source.id)
        http.set { _ in (500, json(#"{"error":"server_error","error_description":"Backend down"}"#)) }
        await #expect(throws: DirectoryError.server("Backend down")) { try await oauth.refresh(old, sourceID: source.id) }
        http.set { _ in (503, Data("<html>".utf8)) }
        await #expect(throws: DirectoryError.http(503)) { try await oauth.refresh(old, sourceID: source.id) }
        #expect(try creds.googleToken(for: source.id) == old)
    }

    // MARK: People API

    private func provider(_ http: FakeGoogleHTTP, token: GoogleToken? = GoogleToken(accessToken: "at", refreshToken: "rt", expiresAt: Date().addingTimeInterval(3600)),
                          indexMaxAge: TimeInterval = 3600, photos: Bool = false, now: @escaping @Sendable () -> Date = { Date() }) throws -> GoogleDirectoryProvider {
        let creds = DirectoryCredentials.inMemory()
        if let token { try creds.setGoogleToken(token, for: source.id) }
        let oauth = GoogleOAuth(credentials: creds, clientID: "cid", fetch: http.fetch, now: now)
        return GoogleDirectoryProvider(source: source, credentials: creds, fetch: http.fetch, oauth: oauth, indexMaxAge: indexMaxAge, importPhotos: photos, now: now)
    }

    @Test func personParsing() throws {
        let p = try GooglePeople.decode(GooglePeople.Person.self, from: json(samplePerson))
        let e = try #require(GooglePeople.entry(p, sourceID: source.id))
        #expect(e.id == "google:people/c100" && e.sourceID == source.id && e.sourceKind == .google)
        #expect(e.displayName == "Anna Ivanova")
        #expect(e.organization == "Example, Inc.")
        #expect(e.email == "anna@example.com")
        #expect(e.photo == nil)
        #expect(e.numbers == [
            PhoneNumber(label: .mobile, value: "+7 916 000-11-22", isDefault: true),    // the primary number comes first
            PhoneNumber(label: .work, value: "+7 495 123-45-67"),
            PhoneNumber(label: .other, value: "101"),                                   // a custom type; the blank one is dropped
        ])
        #expect(e.defaultNumber?.value == "+7 916 000-11-22")
        #expect(GooglePeople.photoURL(p)?.absoluteString == "https://lh3.googleusercontent.com/a/photo=s100")

        #expect(GooglePeople.label("home") == .home && GooglePeople.label("homeFax") == .home)
        #expect(GooglePeople.label("work") == .work && GooglePeople.label("main") == .work && GooglePeople.label("workFax") == .work)
        #expect(GooglePeople.label("mobile") == .mobile && GooglePeople.label("workMobile") == .mobile && GooglePeople.label("googleVoice") == .mobile)
        #expect(GooglePeople.label("other") == .other && GooglePeople.label(nil) == .other && GooglePeople.label("Grandma") == .other)

        // No name: the organization, then the number. No number: skipped. A default photo is not a photo.
        let org = try GooglePeople.decode(GooglePeople.Person.self, from: json(#"{"resourceName":"people/c2","phoneNumbers":[{"value":"500"}],"organizations":[{"name":"Sales"}],"photos":[{"url":"https://x/default","default":true}]}"#))
        #expect(GooglePeople.entry(org, sourceID: source.id)?.displayName == "Sales")
        #expect(GooglePeople.photoURL(org) == nil)
        let bare = try GooglePeople.decode(GooglePeople.Person.self, from: json(#"{"phoneNumbers":[{"value":"600","type":"home"}],"names":[{"givenName":"Bo"}]}"#))
        let b = try #require(GooglePeople.entry(bare, sourceID: source.id))
        #expect(b.displayName == "Bo" && b.id == "google:600" && b.numbers == [PhoneNumber(label: .home, value: "600", isDefault: true)])
        let noNumber = try GooglePeople.decode(GooglePeople.Person.self, from: json(#"{"resourceName":"people/c3","names":[{"displayName":"Nobody"}]}"#))
        #expect(GooglePeople.entry(noNumber, sourceID: source.id) == nil)
        let onlyNumber = try GooglePeople.decode(GooglePeople.Person.self, from: json(#"{"phoneNumbers":[{"value":"700"}]}"#))
        #expect(GooglePeople.entry(onlyNumber, sourceID: source.id)?.displayName == "700")
        #expect(throws: DirectoryError.server("Unexpected answer from the People API")) { try GooglePeople.decode(GooglePeople.Person.self, from: json("not json")) }
    }

    @Test func searchWarmsUpThenAsksSearchContacts() async throws {
        let http = FakeGoogleHTTP()
        http.set { r in
            guard r.url?.path == "/v1/people:searchContacts", r.bearer == "at" else { return (404, Data()) }
            let q = r.queryValues
            if q["query"] == "" { return (200, json("{}")) }
            return (200, json(#"{"results":[{"person":\#(samplePerson)},{"person":{"resourceName":"people/c3","names":[{"displayName":"Nobody"}]}},{"person":{"resourceName":"people/c4","names":[{"displayName":"Anna B"}],"phoneNumbers":[{"value":"102"}]}}]}"#))
        }
        let p = try provider(http)
        let found = try await p.search(" anna ", limit: 5)
        #expect(found.map(\.displayName) == ["Anna Ivanova", "Anna B"])
        let calls = http.requests(to: "people:searchContacts")
        #expect(calls.count == 2)
        #expect(calls[0].queryValues["query"] == "" && calls[0].queryValues["readMask"] == "names")
        #expect(calls[1].queryValues == ["query": "anna", "pageSize": "5", "readMask": GoogleDirectoryProvider.personFields])
        #expect(calls[1].timeoutInterval == 15)
        // The next search of the session skips the warm-up; the page size is capped at 30 and the result at `limit`.
        let one = try await p.search("anna", limit: 1)
        #expect(one.count == 1 && http.requests(to: "people:searchContacts").count == 3)
        _ = try await p.search("anna", limit: 50)
        #expect(http.requests(to: "people:searchContacts").last?.queryValues["pageSize"] == "30")
        #expect(try await p.search("  ", limit: 5).isEmpty)
    }

    @Test func expiringTokenIsRefreshedBeforeTheRequest() async throws {
        let http = FakeGoogleHTTP()
        let t0 = Date()
        let p = try provider(http, token: GoogleToken(accessToken: "stale", refreshToken: "rt", expiresAt: t0.addingTimeInterval(30)), now: { t0 })
        http.set { r in
            if r.url == GoogleOAuth.Configuration.tokenEndpoint {
                return r.formValues["refresh_token"] == "rt" ? (200, json(#"{"access_token":"fresh","expires_in":3600}"#)) : (400, Data())
            }
            guard r.bearer == "fresh" else { return (401, json(#"{"error":{"code":401,"message":"Invalid Credentials","status":"UNAUTHENTICATED"}}"#)) }
            return (200, json(#"{"connections":[],"totalPeople":7}"#))
        }
        #expect(try await p.test() == .connected(entries: 7))
        #expect(http.requests.map { $0.url!.path } == ["/token", "/v1/people/me/connections"])
        #expect(http.requests[1].queryValues == ["personFields": "names", "pageSize": "1"])
    }

    @Test func unauthorizedAnswerRefreshesOnceThenGivesUp() async throws {
        let http = FakeGoogleHTTP()
        let creds = DirectoryCredentials.inMemory()
        try creds.setGoogleToken(GoogleToken(accessToken: "old", refreshToken: "rt"), for: source.id)     // no expiry known
        let oauth = GoogleOAuth(credentials: creds, clientID: "cid", fetch: http.fetch)
        let p = GoogleDirectoryProvider(source: source, credentials: creds, fetch: http.fetch, oauth: oauth, importPhotos: false)
        http.set { r in
            if r.url == GoogleOAuth.Configuration.tokenEndpoint { return (200, json(#"{"access_token":"new","expires_in":3600}"#)) }
            return r.bearer == "new" ? (200, json(#"{"connections":[],"totalPeople":1}"#)) : (401, Data())
        }
        #expect(try await p.test() == .connected(entries: 1))
        #expect(http.requests.map { $0.url!.path } == ["/v1/people/me/connections", "/token", "/v1/people/me/connections"])
        #expect(try creds.googleToken(for: source.id)?.accessToken == "new")

        // Still 401 after a refresh: the token is deleted and the source needs a sign-in (docs/DIRECTORY.md "Tokens").
        http.set { r in r.url == GoogleOAuth.Configuration.tokenEndpoint ? (200, json(#"{"access_token":"newer","expires_in":3600}"#)) : (401, Data()) }
        await #expect(throws: DirectoryError.signInRequired) { try await p.test() }
        #expect(try creds.googleToken(for: source.id) == nil)
        http.reset()
        await #expect(throws: DirectoryError.signInRequired) { try await p.test() }
        #expect(http.requests.isEmpty)                                                  // nothing is sent without a token

        // A revoked refresh token deletes the stored token.
        try creds.setGoogleToken(GoogleToken(accessToken: "old", refreshToken: "rt"), for: source.id)
        http.set { r in r.url == GoogleOAuth.Configuration.tokenEndpoint ? (400, json(#"{"error":"invalid_grant"}"#)) : (401, Data()) }
        await #expect(throws: DirectoryError.signInRequired) { try await p.search("anna", limit: 5) }
        #expect(try creds.googleToken(for: source.id) == nil)
        http.reset()
        await #expect(throws: DirectoryError.signInRequired) { try await p.lookup(number: "101") }
        #expect(http.requests.isEmpty)                                                  // nothing is sent without a token
    }

    @Test func apiErrorsCarryGooglesMessage() async throws {
        let http = FakeGoogleHTTP()
        let p = try provider(http)
        http.set { _ in (403, json(#"{"error":{"code":403,"message":"People API has not been used in project 1 before or it is disabled.","status":"PERMISSION_DENIED"}}"#)) }
        await #expect(throws: DirectoryError.server("People API has not been used in project 1 before or it is disabled.")) { try await p.test() }
        http.set { _ in (429, Data()) }
        await #expect(throws: DirectoryError.http(429)) { try await p.test() }
        http.set { _ in (200, Data("<html>".utf8)) }
        await #expect(throws: DirectoryError.server("Unexpected answer from the People API")) { try await p.test() }
        http.set { _ in throw URLError(.timedOut) }
        await #expect(throws: DirectoryError.timedOut) { try await p.test() }
        let noToken = try provider(http, token: nil)
        await #expect(throws: DirectoryError.signInRequired) { try await noToken.test() }
        await #expect(throws: DirectoryError.signInRequired) { try await noToken.allEntries() }
    }

    @Test func importPagesThroughConnectionsAndFetchesPhotos() async throws {
        let http = FakeGoogleHTTP()
        let photoBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        http.set { r in
            if r.url?.host == "lh3.googleusercontent.com" {
                #expect(r.bearer == nil)
                return r.url?.path == "/a/photo=s100" ? (200, photoBytes) : (404, Data())
            }
            guard r.url?.path == "/v1/people/me/connections" else { return (404, Data()) }
            let q = r.queryValues
            #expect(q["personFields"] == GoogleDirectoryProvider.personFields && q["pageSize"] == "1000")
            switch q["pageToken"] {
            case nil:
                return (200, json(#"{"connections":[\#(samplePerson),{"resourceName":"people/c3","names":[{"displayName":"Nobody"}]}],"nextPageToken":"p2","totalPeople":3,"totalItems":3}"#))
            case "p2":
                return (200, json(#"{"connections":[{"resourceName":"people/c5","names":[{"displayName":"Boris"}],"phoneNumbers":[{"value":"+7 (495) 765-43-21","type":"work"}],"photos":[{"url":"https://lh3.googleusercontent.com/missing","default":false}]}],"totalPeople":3}"#))
            default:
                return (400, Data())
            }
        }
        let p = try provider(http, photos: true)
        let all = try await p.allEntries()
        #expect(all.map(\.displayName) == ["Anna Ivanova", "Boris"])
        #expect(all[0].photo == photoBytes)
        #expect(all[1].photo == nil)                                                    // the photo request failed: no photo
        #expect(http.requests(to: "/connections").count == 2)
        #expect(http.requests.filter { $0.url?.host == "lh3.googleusercontent.com" }.count == 2)
        let contacts = all.map { $0.makeContact(imported: true) }
        #expect(contacts[0].firstName == "Anna" && contacts[0].lastName == "Ivanova" && contacts[0].importedFrom == source.id)

        // The import filled the lookup index: no request for a lookup.
        http.reset()
        #expect(try await p.lookup(number: "sip:84957654321@pbx")?.displayName == "Boris")
        #expect(try await p.lookup(number: "+7 916 000 11 22")?.displayName == "Anna Ivanova")
        #expect(try await p.lookup(number: "999") == nil)
        #expect(http.requests.isEmpty)
    }

    @Test func lookupBuildsTheIndexAndRefreshesItHourly() async throws {
        let http = FakeGoogleHTTP()
        let clock = OSAllocatedUnfairLock(initialState: Date())
        let p = try provider(http, token: GoogleToken(accessToken: "at", refreshToken: "rt"), now: { clock.withLock { $0 } })
        http.set { r in
            guard r.url?.path == "/v1/people/me/connections" else { return (404, Data()) }
            return (200, json(#"{"connections":[\#(samplePerson)]}"#))
        }
        #expect(try await p.lookup(number: "101")?.displayName == "Anna Ivanova")
        #expect(try await p.lookup(number: "+74951234567")?.displayName == "Anna Ivanova")
        #expect(http.requests.count == 1)                                               // one fetch, no photos for the index
        #expect(try await p.lookup(number: "") == nil)

        // An hour later the stale copy still answers while the refresh fails; the failure is not retried on every call.
        clock.withLock { $0 = $0.addingTimeInterval(3601) }
        http.set { _ in (500, Data()) }
        for _ in 0..<20 { #expect(try await p.lookup(number: "101")?.displayName == "Anna Ivanova") }
        for _ in 0..<50 where http.requests.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await p.lookup(number: "101")?.displayName == "Anna Ivanova")
        #expect(http.requests.count == 2)

        // After the pause the refresh is tried again and the new copy takes over.
        clock.withLock { $0 = $0.addingTimeInterval(GoogleDirectoryProvider.retryAfter + 1) }
        http.set { r in
            guard r.url?.path == "/v1/people/me/connections" else { return (404, Data()) }
            return (200, json(#"{"connections":[{"resourceName":"people/c9","names":[{"displayName":"New Person"}],"phoneNumbers":[{"value":"101"}]}]}"#))
        }
        #expect(try await p.lookup(number: "101")?.displayName == "Anna Ivanova")        // the stale copy answers this call
        for _ in 0..<100 {
            if try await p.lookup(number: "101")?.displayName == "New Person" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await p.lookup(number: "101")?.displayName == "New Person")
        #expect(http.requests.count == 3)
    }

    // MARK: Service

    @Test func sourceWithAStoredTokenIsAskedAndSignInConnects() async throws {
        let creds = DirectoryCredentials.inMemory()
        let http = FakeGoogleHTTP()
        let signedIn = DirectorySource(kind: .google, name: "Signed in")
        try creds.setGoogleToken(GoogleToken(accessToken: "at", refreshToken: "rt", expiresAt: Date().addingTimeInterval(3600)), for: signedIn.id)
        let fresh = DirectorySource(kind: .google, name: "Fresh")
        let settings = DirectorySettings(sources: [signedIn, fresh])
        let oauth = GoogleOAuth(credentials: creds, clientID: "cid", fetch: http.fetch, timeout: 10)
        let factory: DirectoryService.ProviderFactory = { s, c in GoogleDirectoryProvider(source: s, credentials: c, fetch: http.fetch, oauth: oauth, importPhotos: false) }
        let service = DirectoryService(settings: settings, credentials: creds, makeProvider: factory, googleOAuth: oauth, searchTimeout: 1)
        var events = service.events.makeAsyncIterator()
        #expect(await events.next() == .sourceStatus(id: fresh.id, status: .signInRequired))
        let statuses = await service.currentStatuses()
        #expect(statuses[signedIn.id] == nil && statuses[fresh.id] == .signInRequired)
        #expect(await service.searchableSources().map(\.id) == [signedIn.id])

        http.set { r in
            if r.url == GoogleOAuth.Configuration.tokenEndpoint {
                return (200, json(#"{"access_token":"at2","expires_in":3599,"refresh_token":"rt2","id_token":"\#(fakeIDToken(email: "fresh@example.com"))"}"#))
            }
            if r.url?.path == "/v1/people:searchContacts" {
                return r.queryValues["query"] == "" ? (200, json("{}")) : (200, json(#"{"results":[{"person":\#(samplePerson)}]}"#))
            }
            return (404, Data())
        }
        let email = try await service.signInGoogle(sourceID: fresh.id) { url in
            let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            let redirect = URL(string: q["redirect_uri"]! + "?state=\(q["state"]!)&code=c")!
            Task { _ = try? await URLSession.shared.data(from: redirect) }
        }
        #expect(email == "fresh@example.com")
        #expect(await events.next() == .sourceStatus(id: fresh.id, status: .connected))
        #expect(try creds.googleToken(for: fresh.id)?.accessToken == "at2")
        #expect(await service.searchableSources().map(\.id) == [signedIn.id, fresh.id])
        let found = await service.search("anna")
        #expect(found.map(\.sourceID) == [signedIn.id, fresh.id])
        #expect(await service.currentStatuses()[signedIn.id] == .connected)

        // Saving the account e-mail does not reset the source.
        var renamed = settings
        renamed.sources[1].google = GoogleConfig(accountEmail: email)
        await service.update(settings: renamed)
        #expect(await service.currentStatuses()[fresh.id] == .connected)

        // A revoked token puts the source back into "Sign in required".
        http.set { r in r.url == GoogleOAuth.Configuration.tokenEndpoint ? (400, json(#"{"error":"invalid_grant"}"#)) : (401, Data()) }
        _ = await service.search("anna")
        #expect(await service.currentStatuses()[fresh.id] == .signInRequired)
        #expect(try creds.googleToken(for: fresh.id) == nil)
        #expect(await service.searchableSources().isEmpty)

        // A sign-in for a source that is still a draft stores the token only.
        let draft = UUID()
        http.set { r in r.url == GoogleOAuth.Configuration.tokenEndpoint ? (200, json(#"{"access_token":"d","expires_in":10,"id_token":"\#(fakeIDToken(email: "d@example.com"))"}"#)) : (404, Data()) }
        let draftEmail = try await service.signInGoogle(sourceID: draft) { url in
            let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            Task { _ = try? await URLSession.shared.data(from: URL(string: q["redirect_uri"]! + "?state=\(q["state"]!)&code=c")!) }
        }
        #expect(draftEmail == "d@example.com")
        #expect(try creds.googleToken(for: draft) != nil)
        #expect(await service.currentStatuses()[draft] == nil)
    }

    @Test func signInWithoutClientIDThroughTheService() async {
        let google = DirectorySource(kind: .google, name: "Google")
        let service = DirectoryService(settings: DirectorySettings(sources: [google]), credentials: .inMemory())
        #expect(await service.currentStatuses()[google.id] == .signInRequired)
        await #expect(throws: DirectoryError.notConfigured(.googleClientID)) { try await service.signInGoogle(sourceID: google.id) { _ in } }
        #expect(await service.currentStatuses()[google.id] == .signInRequired)
    }

    @Test func inMemoryCredentials() throws {
        let creds = DirectoryCredentials.inMemory()
        let id = UUID()
        #expect(try creds.googleToken(for: id) == nil && (try creds.ldapPassword(for: id)) == nil)
        try creds.setGoogleToken(GoogleToken(accessToken: "a"), for: id)
        try creds.setLDAPPassword("pw", for: id)
        let copy = creds
        #expect(try copy.googleToken(for: id)?.accessToken == "a" && (try copy.ldapPassword(for: id)) == "pw")
        #expect(try creds.overriding(ldapPassword: "typed", for: id).ldapPassword(for: id) == "typed")
        try creds.setLDAPPassword("", for: id)
        #expect(try creds.ldapPassword(for: id) == nil)
        try creds.deleteAll(for: id)
        #expect(try creds.googleToken(for: id) == nil)
    }
}
