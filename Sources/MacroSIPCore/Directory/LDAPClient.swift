import CLDAP
import Foundation
import os

/// One LDAP entry: its DN and the values of the requested attributes (keyed by the requested name).
struct LDAPRecord: Sendable, Equatable {
    var dn: String
    var attributes: [String: [String]]

    func first(_ attr: String) -> String? {
        attributes[attr]?.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }
}

/// Synchronous libldap calls (through the CLDAP shim) on a small pool of threads, one connection per request:
/// connect, StartTLS when asked, simple bind, searches, unbind. `Request.timeout` is one deadline for all of
/// that. A request whose task is cancelled before its turn is not started; one in flight finishes its current
/// libldap call (bounded by the deadline) and then stops.
enum LDAPClient {
    struct Endpoint: Sendable, Equatable {
        var uri: String
        var isLDAPS: Bool
        var host: String
    }

    struct Request: Sendable {
        var endpoint: Endpoint
        var startTLS: Bool
        var bindDN: String
        var password: String?
        /// Connect, StartTLS, bind and search together.
        var timeout: TimeInterval
    }

    /// `ldap://host[:port]` from what the user typed: a missing scheme means ldap://, `port` fills a missing
    /// port, a path or query is dropped.
    static func endpoint(server: String, port: Int?) throws -> Endpoint {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw DirectoryError.notConfigured(.emptyServer) }
        if !s.contains("://") { s = "ldap://" + s }
        guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), scheme == "ldap" || scheme == "ldaps",
              let host = c.host, !host.isEmpty else {
            throw DirectoryError.notConfigured(.badLDAPURL)
        }
        let p = c.port ?? port
        let hostPart = host.contains(":") ? "[\(host)]" : host
        return Endpoint(uri: "\(scheme)://\(hostPart)" + (p.map { ":\($0)" } ?? ""), isLDAPS: scheme == "ldaps", host: host)
    }

    /// Two connections at a time: a search while an import runs, never a thread per keystroke.
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.hsmm.macrosip.directory.ldap"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 2
        return q
    }()

    private static let log = Logger(subsystem: "com.hsmm.macrosip", category: "directory")
    private static let tlsWarningShown = OSAllocatedUnfairLock(initialState: false)

    /// Connects and binds, then runs `body` with the session; everything on the LDAP queue. Cancelling the task
    /// while the request waits for a free slot fails it at once with `.cancelled`; once started, the request
    /// stops at its next step.
    static func run<T: Sendable>(_ request: Request, _ body: @escaping @Sendable (LDAPSession) throws -> T) async throws -> T {
        let state = OSAllocatedUnfairLock(initialState: PendingRequest<T>())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                let cancelledAlready = state.withLock { s -> Bool in
                    if s.cancelled { return true }
                    s.continuation = cont
                    return false
                }
                if cancelledAlready { cont.resume(throwing: DirectoryError.cancelled); return }
                queue.addOperation {
                    // Take the continuation: nil means the cancellation handler already answered.
                    guard let cont = state.withLock({ s in defer { s.continuation = nil }; return s.continuation }) else { return }
                    do {
                        let session = try LDAPSession(request, isCancelled: { state.withLock { $0.cancelled } })
                        defer { session.close() }
                        if !session.tlsVerificationSet, tlsWarningShown.withLock({ shown in defer { shown = true }; return !shown }) {
                            log.warning("libldap refused LDAP_OPT_X_TLS_REQUIRE_CERT; its default certificate policy applies")
                        }
                        cont.resume(returning: try body(session))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            let waiting = state.withLock { s -> CheckedContinuation<T, Error>? in
                s.cancelled = true
                defer { s.continuation = nil }
                return s.continuation
            }
            waiting?.resume(throwing: DirectoryError.cancelled)
        }
    }
}

/// A request between `run` and its turn on the queue.
private struct PendingRequest<T: Sendable> {
    var continuation: CheckedContinuation<T, Error>?
    var cancelled = false
}

/// A bound connection. Used on one thread only (inside `LDAPClient.run`). Every step checks the request's
/// deadline and the cancellation flag first.
final class LDAPSession {
    private var conn: OpaquePointer?
    private let deadline: Date
    private let isCancelled: () -> Bool
    private let host: String
    private(set) var tlsVerificationSet = true

    init(_ r: LDAPClient.Request, isCancelled: @escaping () -> Bool = { false }) throws {
        deadline = Date().addingTimeInterval(max(0.001, min(r.timeout, 600)))
        self.isCancelled = isCancelled
        host = r.endpoint.host
        var c: OpaquePointer?
        let rc = cldap_open(r.endpoint.uri, try remainingMS(), &c)
        guard rc == Int32(CLDAP_SUCCESS), let c else { throw Self.error(rc, nil, host: host) }
        conn = c
        tlsVerificationSet = cldap_tls_verification_set(c) == 1
        if r.startTLS && !r.endpoint.isLDAPS {
            cldap_set_timeout(c, try remainingMS())
            let rc = cldap_start_tls(c)
            guard rc == Int32(CLDAP_SUCCESS) else { throw failure(rc, during: "StartTLS") }
        }
        cldap_set_timeout(c, try remainingMS())
        let bind = r.password ?? ""
        let rc2 = cldap_simple_bind(c, r.bindDN, bind)
        guard rc2 == Int32(CLDAP_SUCCESS) else { throw failure(rc2, during: nil) }
    }

    /// Milliseconds left before the deadline; throws when it passed or the caller gave up.
    private func remainingMS() throws -> Int32 {
        if isCancelled() { throw DirectoryError.cancelled }
        let ms = deadline.timeIntervalSinceNow * 1000
        guard ms >= 1 else { throw DirectoryError.timedOut }
        return Int32(min(ms, 600_000))
    }

    func close() {
        if let conn { cldap_close(conn) }
        conn = nil
    }

    deinit { close() }

    /// Entries of a search, within what is left of the deadline. Size and time limits keep what arrived.
    func search(base: String, scope: Int32, filter: String, attributes: [String], sizeLimit: Int) throws -> [LDAPRecord] {
        guard let conn else { throw DirectoryError.notConnected }
        let ms = try remainingMS()
        let cAttrs: [UnsafeMutablePointer<CChar>?] = attributes.map { strdup($0) } + [nil]
        defer { for p in cAttrs { free(p) } }
        var count: Int32 = 0
        let rc = cAttrs.withUnsafeBufferPointer { buf -> Int32 in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { attrs in
                cldap_search(conn, base, scope, filter, attrs, Int32(clamping: sizeLimit), ms, &count)
            }
        }
        let partial = rc == cldap_rc_sizelimit_exceeded() || rc == cldap_rc_timelimit_exceeded()
        guard rc == Int32(CLDAP_SUCCESS) || partial else { throw failure(rc, during: nil) }
        var out: [LDAPRecord] = []
        while cldap_next_entry(conn) == 1 {
            var dn = ""
            if let p = cldap_entry_dn(conn) { dn = String(cString: p); cldap_free(p) }
            var attrs: [String: [String]] = [:]
            for a in attributes where a != "1.1" {
                var vals: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                let n = cldap_entry_values(conn, a, &vals)
                guard n > 0, let vals else { continue }
                attrs[a] = (0..<Int(n)).compactMap { vals[$0].map { String(cString: $0) } }
                cldap_free_values(vals, n)
            }
            out.append(LDAPRecord(dn: dn, attributes: attrs))
        }
        return out
    }

    private func failure(_ rc: Int32, during: String?) -> DirectoryError {
        var diag: String?
        if let conn, let p = cldap_diagnostic(conn) { diag = String(cString: p); cldap_free(p) }
        let e = Self.error(rc, diag, host: host)
        if let during, case .server(let text) = e { return .server("\(during): \(text)") }
        return e
    }

    static func error(_ rc: Int32, _ diagnostic: String?, host: String) -> DirectoryError {
        if rc == cldap_rc_timeout() || rc == cldap_rc_timelimit_exceeded() { return .timedOut }
        if rc == cldap_rc_server_down() || rc == cldap_rc_connect_error() { return .cannotConnect(host: host) }
        if rc == cldap_rc_invalid_credentials() { return .invalidCredentials }
        var text = String(cString: cldap_error_string(rc))
        if let d = diagnostic, !d.isEmpty { text += " (\(d))" }
        return .server(text)
    }
}
