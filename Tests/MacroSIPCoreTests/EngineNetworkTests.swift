import Foundation
import os
import Testing
@testable import MacroSIPCore

// Network resilience (docs/ENGINE.md "Network resilience"): REGISTER retry with backoff,
// network change handling (re-REGISTER, re-INVITE), offline calls, the media watchdog,
// sleep and wake.

// MARK: - helpers

/// A SIP server on 127.0.0.1 (one UDP socket) for the network tests: a registrar whose
/// answers can be switched (200, 403, or none at all) and a callee that answers INVITE with
/// 200 and a PCMU SDP but never sends RTP (optionally RTCP receiver reports, as a peer with
/// silence suppression or a voicemail recording does). Initial INVITEs can be left ringing
/// (100 + 180, no final answer); re-INVITEs (To with a tag) get `reinviteStatus`: a status
/// line, "drop" (no answer at all) or "trying" (100 Trying only; a CANCEL then gets 200 and
/// the INVITE 487). OPTIONS get `optionsStatus`.
final class NetworkStub: Sendable {
    enum RegisterMode: Sendable { case ok, forbidden, silent }

    struct Register: Sendable {
        var at: Date
        var cseq: String
        var unregister: Bool
        /// The top Via header value ("SIP/2.0/UDP 127.0.0.1:5060;rport;branch=...").
        var via: String = ""
    }

    struct Stats: Sendable {
        var registers: [Register] = []
        var invites = 0
        var reinvites = 0
        var cancels = 0
        var options = 0
        var byes = 0
        /// Bodies of INFO requests (DTMF over SIP INFO: "Signal=5\r\nDuration=...").
        var infos: [String] = []
        /// Status lines of responses to requests the stub sent itself (`sendInvite`).
        var responses: [String] = []
    }

    struct Modes: Sendable {
        var register = RegisterMode.ok
        var ringOnly = false
        var reinvite = "200 OK"
        var options = "200 OK"
        var sendRTCP = false
    }

    let port: UInt16
    private let rtpPort: UInt16
    private let fd: Int32
    private let rtpFD: Int32
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    private let mode = OSAllocatedUnfairLock(initialState: Modes())
    private let stats = OSAllocatedUnfairLock(initialState: Stats())
    /// Where the caller wants RTCP (its SDP's RTP port + 1), from the latest offer.
    private let rtcpTarget = OSAllocatedUnfairLock(initialState: UInt16(0))
    /// Header lines of a re-INVITE left at 100 Trying (to answer 487 after a CANCEL).
    private let pendingInvite = OSAllocatedUnfairLock(initialState: (echoed: [String](), to: "", from: sockaddr_in()))

    init() throws {
        (fd, port) = try NetworkStub.bindUDP(timeoutMs: 100)
        (rtpFD, rtpPort) = try NetworkStub.bindUDP(timeoutMs: 0)
        Thread.detachNewThread { [self] in self.serve() }
        Thread.detachNewThread { [self] in self.rtcpLoop() }
    }

    var registerMode: RegisterMode {
        get { mode.withLock { $0.register } }
        set { mode.withLock { $0.register = newValue } }
    }

    var reinviteStatus: String {
        get { mode.withLock { $0.reinvite } }
        set { mode.withLock { $0.reinvite = newValue } }
    }

    var optionsStatus: String {
        get { mode.withLock { $0.options } }
        set { mode.withLock { $0.options = newValue } }
    }

    var ringOnly: Bool {
        get { mode.withLock { $0.ringOnly } }
        set { mode.withLock { $0.ringOnly = newValue } }
    }

    var sendRTCP: Bool {
        get { mode.withLock { $0.sendRTCP } }
        set { mode.withLock { $0.sendRTCP = newValue } }
    }

    var snapshot: Stats { stats.withLock { $0 } }

    /// REGISTER requests with a new CSeq (retransmissions left out), in order.
    var registers: [Register] {
        var seen: Set<String> = []
        return snapshot.registers.filter { seen.insert($0.cseq).inserted }
    }

    func stop() { stopped.withLock { $0 = true } }

    private static func bindUDP(timeoutMs: Int) throws -> (Int32, UInt16) {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { throw EngineError.unsupported("socket") }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, len) == 0 && getsockname(sock, $0, &len) == 0
            }
        }
        guard ok else { close(sock); throw EngineError.unsupported("bind") }
        if timeoutMs > 0 {
            var tv = timeval(tv_sec: 0, tv_usec: Int32(timeoutMs * 1000))
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
        return (sock, UInt16(bigEndian: addr.sin_port))
    }

    private func serve() {
        var buf = [UInt8](repeating: 0, count: 65_536)
        while !stopped.withLock({ $0 }) {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fromLen) }
            }
            guard n > 0 else { continue }
            handle(String(decoding: buf[0..<n], as: UTF8.self), from: from)
        }
        close(fd)
        close(rtpFD)
    }

    /// An RTCP receiver report with one report block every 500 ms while `sendRTCP`.
    private func rtcpLoop() {
        while !stopped.withLock({ $0 }) {
            Thread.sleep(forTimeInterval: 0.5)
            let target = rtcpTarget.withLock { $0 }
            guard sendRTCP, target > 0 else { continue }
            var pkt: [UInt8] = [0x81, 201, 0x00, 0x07]                 // V=2, RC=1, RR, 8 words
            pkt += [0x12, 0x34, 0x56, 0x78]                             // sender SSRC
            pkt += [UInt8](repeating: 0, count: 24)                     // report block
            var dest = sockaddr_in()
            dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            dest.sin_family = sa_family_t(AF_INET)
            dest.sin_addr.s_addr = inet_addr("127.0.0.1")
            dest.sin_port = in_port_t(target.bigEndian)
            _ = withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(rtpFD, pkt, pkt.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func handle(_ text: String, from: sockaddr_in) {
        let parts = text.components(separatedBy: "\r\n\r\n")
        let head = parts.first ?? text
        let body = parts.dropFirst().joined(separator: "\r\n\r\n")
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        if requestLine.hasPrefix("SIP/2.0") {
            handleResponse(requestLine, lines: lines, from: from)
            return
        }
        let method = String(requestLine.prefix { $0 != " " })
        guard method != "ACK" else { return }
        var echoed: [String] = []
        var toLine = ""
        var cseq = ""
        var expiresZero = false
        var topVia = ""
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "via", "v":
                echoed.append(line)
                if topVia.isEmpty { topVia = value }
            case "from", "f", "call-id", "i": echoed.append(line)
            case "cseq": echoed.append(line); cseq = value
            case "to", "t": toLine = line
            case "expires": if value == "0" { expiresZero = true }
            case "contact", "m": if value.lowercased().contains("expires=0") { expiresZero = true }
            default: break
            }
        }
        let inDialog = toLine.lowercased().contains("tag=")
        if !inDialog { toLine += ";tag=net-stub-\(UInt32.random(in: 1...UInt32.max))" }

        func reply(_ status: String, extra: [String] = [], body: String = "", echo: [String]? = nil, to: String? = nil) {
            var msg = "SIP/2.0 \(status)\r\n" + (echo ?? echoed).joined(separator: "\r\n") + "\r\n" + (to ?? toLine) + "\r\n"
            for h in extra { msg += h + "\r\n" }
            if !body.isEmpty { msg += "Content-Type: application/sdp\r\n" }
            msg += "Content-Length: \(body.utf8.count)\r\n\r\n" + body
            send(msg, to: from)
        }

        switch method {
        case "REGISTER":
            let entry = Register(at: Date(), cseq: cseq, unregister: expiresZero, via: topVia)
            stats.withLock { $0.registers.append(entry) }
            switch registerMode {
            case .silent: return
            case .forbidden: reply("403 Forbidden")
            case .ok: reply("200 OK", extra: ["Expires: \(entry.unregister ? 0 : 300)"])
            }
        case "INVITE":
            stats.withLock { if inDialog { $0.reinvites += 1 } else { $0.invites += 1 } }
            if let m = body.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("m=audio ") }),
               let port = UInt16(m.split(separator: " ")[1]) {
                rtcpTarget.withLock { $0 = port + 1 }
            }
            if !inDialog && ringOnly {
                reply("100 Trying")
                reply("180 Ringing")
                return
            }
            let status = inDialog ? reinviteStatus : "200 OK"
            if status == "drop" { return }
            if status == "trying" {
                reply("100 Trying")
                let pending = (echoed: echoed, to: toLine, from: from)
                pendingInvite.withLock { $0 = pending }
                return
            }
            guard status.hasPrefix("200") else { reply(status); return }
            let sdp = "v=0\r\no=stub 1 \(Int.random(in: 2...1_000_000)) IN IP4 127.0.0.1\r\ns=stub\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\n"
                + "m=audio \(rtpPort) RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\na=sendrecv\r\n"
            reply("200 OK", extra: ["Contact: <sip:stub@127.0.0.1:\(port)>"], body: sdp)
        case "CANCEL":
            stats.withLock { $0.cancels += 1 }
            reply("200 OK")
            let pending = pendingInvite.withLock { $0 }
            if !pending.echoed.isEmpty {
                let echo = pending.echoed
                reply("487 Request Terminated", echo: echo, to: pending.to)
                pendingInvite.withLock { $0 = ([], "", sockaddr_in()) }
            }
        case "OPTIONS":
            stats.withLock { $0.options += 1 }
            reply(optionsStatus)
        case "BYE":
            stats.withLock { $0.byes += 1 }
            reply("200 OK")
        case "INFO":
            stats.withLock { $0.infos.append(body) }
            reply("200 OK")
        default:
            reply("200 OK")
        }
    }

    /// Sends an INVITE (PCMU offer) from the stub's socket to the engine on 127.0.0.1:`port`,
    /// From `sip:<fromUser>@127.0.0.1` (an empty `fromUser` gives `sip:127.0.0.1`) with
    /// `extraHeaders` ("Privacy: id"). Responses land in `snapshot.responses`; a final
    /// non-2xx is ACKed, a 2xx is ACKed and the call hung up with BYE.
    func sendInvite(toPort port: Int, user: String, fromUser: String, extraHeaders: [String] = []) {
        let callID = "stub-\(UInt32.random(in: 1...UInt32.max))@127.0.0.1"
        let branch = "z9hG4bK-stub-\(UInt32.random(in: 1...UInt32.max))"
        let from = fromUser.isEmpty ? "sip:127.0.0.1" : "sip:\(fromUser)@127.0.0.1"
        let sdp = "v=0\r\no=stub 1 1 IN IP4 127.0.0.1\r\ns=stub\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\n"
            + "m=audio \(rtpPort) RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\na=sendrecv\r\n"
        var msg = "INVITE sip:\(user)@127.0.0.1:\(port) SIP/2.0\r\n"
        msg += "Via: SIP/2.0/UDP 127.0.0.1:\(self.port);branch=\(branch);rport\r\n"
        msg += "Max-Forwards: 70\r\n"
        msg += "From: <\(from)>;tag=stub-from-\(UInt32.random(in: 1...UInt32.max))\r\n"
        msg += "To: <sip:\(user)@127.0.0.1:\(port)>\r\n"
        msg += "Call-ID: \(callID)\r\nCSeq: 1 INVITE\r\n"
        msg += "Contact: <sip:\(fromUser.isEmpty ? "stub" : fromUser)@127.0.0.1:\(self.port)>\r\n"
        for h in extraHeaders { msg += h + "\r\n" }
        msg += "Content-Type: application/sdp\r\nContent-Length: \(sdp.utf8.count)\r\n\r\n" + sdp
        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_addr.s_addr = inet_addr("127.0.0.1")
        dest.sin_port = in_port_t(UInt16(port).bigEndian)
        send(msg, to: dest)
    }

    private func handleResponse(_ statusLine: String, lines: [String], from: sockaddr_in) {
        stats.withLock { $0.responses.append(statusLine) }
        let code = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0
        var via = "", fromH = "", to = "", callID = "", cseq = "", contact = ""
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            switch name {
            case "via", "v": if via.isEmpty { via = line }
            case "from", "f": fromH = line
            case "to", "t": to = line
            case "call-id", "i": callID = line
            case "cseq": cseq = line
            case "contact", "m": contact = line
            default: break
            }
        }
        guard code >= 200, cseq.uppercased().hasSuffix("INVITE") else { return }
        let number = cseq.split(separator: ":").last?.split(separator: " ").first.map(String.init) ?? "1"
        if code >= 300 {
            // ACK of a non-2xx: same branch (hop by hop).
            let ack = "ACK sip:127.0.0.1 SIP/2.0\r\n\(via)\r\nMax-Forwards: 70\r\n\(fromH)\r\n\(to)\r\n\(callID)\r\n"
                + "CSeq: \(number) ACK\r\nContent-Length: 0\r\n\r\n"
            send(ack, to: from)
            return
        }
        var target = "sip:127.0.0.1"
        if let lt = contact.firstIndex(of: "<"), let gt = contact.firstIndex(of: ">") {
            target = String(contact[contact.index(after: lt)..<gt])
        }
        let newVia = "Via: SIP/2.0/UDP 127.0.0.1:\(port);branch=z9hG4bK-stub-\(UInt32.random(in: 1...UInt32.max));rport"
        for (method, n) in [("ACK", number), ("BYE", String((Int(number) ?? 1) + 1))] {
            let req = "\(method) \(target) SIP/2.0\r\n\(newVia)\(method == "BYE" ? "1" : "")\r\nMax-Forwards: 70\r\n\(fromH)\r\n\(to)\r\n"
                + "\(callID)\r\nCSeq: \(n) \(method)\r\nContent-Length: 0\r\n\r\n"
            send(req, to: from)
        }
    }

    private func send(_ text: String, to dest: sockaddr_in) {
        var dest = dest
        let bytes = Array(text.utf8)
        _ = withUnsafePointer(to: &dest) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

/// Engine events with arrival times.
final class TimedEventLog: Sendable {
    private let events = OSAllocatedUnfairLock(initialState: [(Date, EngineEvent)]())
    var all: [(Date, EngineEvent)] { events.withLock { $0 } }

    func consume(_ engine: Engine) -> Task<Void, Never> {
        Task { for await e in engine.events { self.events.withLock { $0.append((Date(), e)) } } }
    }

    func registrations(_ id: AccountID) -> [(Date, RegistrationState)] {
        all.compactMap { t, e in
            if case let .registration(a, st) = e, a == id { return (t, st) }
            return nil
        }
    }

    func calls(_ id: CallID) -> [CallInfo] {
        all.compactMap { _, e in
            switch e {
            case let .callChanged(c) where c.id == id: return c
            case let .incomingCall(c) where c.id == id: return c
            default: return nil
            }
        }
    }

    func ended(_ id: CallID) -> CallInfo? {
        all.lazy.compactMap { _, e -> CallInfo? in
            if case let .callEnded(c, _) = e, c.id == id { return c }
            return nil
        }.first
    }

    func logged(_ needle: String) -> Bool {
        all.contains { _, e in
            if case let .log(_, text) = e { return text.contains(needle) }
            return false
        }
    }

    func network() -> [NetworkState] {
        all.compactMap { _, e in
            if case let .network(st) = e { return st }
            return nil
        }
    }
}

extension RegistrationState {
    var isRegistered: Bool { if case .registered = self { return true }; return false }
}

// MARK: - tests that run pjsua (part of the serialized "Engine (pjsua)" suite)

extension EngineTests {
    /// `.network` is emitted once after start with the first path evaluation: with the real
    /// NWPathMonitor (whatever the host's network is) and without one (assumed online).
    @Test func networkEventAfterStart() async throws {
        for monitored in [true, false] {
            let engine = await makeEngine(monitorNetwork: monitored)
            let log = TimedEventLog()
            let consumer = log.consume(engine)
            try await engine.start(network: Self.network)
            #expect(await waitUntil(timeout: 3) { !log.network().isEmpty })
            try await Task.sleep(for: .milliseconds(300))
            #expect(log.network().count == 1)
            #expect(log.network().last == (await engine.networkState()))
            if !monitored { #expect(log.network() == [.online]) }
            await engine.stop()
            consumer.cancel()
        }
    }

    /// The registrar stops answering: `.reconnecting(1, 2 s)`, the retry 2 s later fails too:
    /// `.reconnecting(2, 4 s)`; once it answers again the next retry registers. No
    /// "registering" in between (the UI keeps showing the countdown).
    @Test func registrationRetriesWithBackoff() async throws {
        let stub = try NetworkStub()
        defer { stub.stop() }
        let engine = await makeEngine()
        await engine.setTestTimings(transactionTimeoutMs: 2000)      // REGISTER gives up after 2 s
        let log = TimedEventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let cfg = AccountConfig(displayName: "B", username: "1001", domain: "127.0.0.1",
                                registrar: "127.0.0.1:\(stub.port)", enabled: true)
        try await engine.addAccount(cfg, password: "pw")
        #expect(await waitUntil { await engine.registrationState(of: cfg.id).isRegistered })

        stub.registerMode = .silent
        let mark = log.all.count
        try await engine.setRegistered(cfg.id, true)               // a refresh that gets no answer
        func states() -> [(Date, RegistrationState)] {
            Array(log.all.dropFirst(mark)).compactMap { t, e in
                if case let .registration(a, st) = e, a == cfg.id { return (t, st) }
                return nil
            }
        }
        func reconnecting(_ n: Int) -> (Date, TimeInterval)? {
            for (t, st) in states() {
                if case let .reconnecting(attempt, next, error) = st, attempt == n {
                    #expect(error.contains("408"), "lastError \(error)")
                    return (t, next)
                }
            }
            return nil
        }
        #expect(await waitUntil(timeout: 5) { reconnecting(1) != nil })
        let first = try #require(reconnecting(1))
        #expect(first.1 == 2)
        #expect(await waitUntil(timeout: 8) { reconnecting(2) != nil })
        let second = try #require(reconnecting(2))
        #expect(second.1 == 4)
        // The retry REGISTER went out about 2 s after the first failure.
        let retry = try #require(stub.registers.first { $0.at > first.0 })
        let gap = retry.at.timeIntervalSince(first.0)
        #expect(gap > 1.5 && gap < 3.5, "retry after \(gap) s")

        stub.registerMode = .ok
        #expect(await waitUntil(timeout: 7) { await engine.registrationState(of: cfg.id).isRegistered })
        let registeredAt = try #require(states().first { $0.1.isRegistered }?.0)
        let wait = registeredAt.timeIntervalSince(second.0)
        #expect(wait > 3 && wait < 6, "registered \(wait) s after attempt 2 failed")
        // Exactly: reconnecting 1, reconnecting 2, registered.
        let kinds = states().map { st -> String in
            switch st.1 {
            case let .reconnecting(n, _, _): return "reconnecting\(n)"
            case .registered: return "registered"
            case .registering: return "registering"
            case .unregistered: return "unregistered"
            case .failed: return "failed"
            }
        }
        #expect(kinds == ["reconnecting1", "reconnecting2", "registered"])
        await engine.stop()
    }

    /// A REGISTER that cannot even be sent (here: sendto to the broadcast address fails at
    /// once, as DNS and sendto do without a network) does not make `addAccount` fail: the
    /// account stays and is retried with backoff.
    @Test func registrationThatCannotBeSentIsRetried() async throws {
        let engine = await makeEngine()
        let log = TimedEventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let cfg = AccountConfig(displayName: "O", username: "1001", domain: "127.0.0.1",
                                registrar: "255.255.255.255:5060", enabled: true)
        try await engine.addAccount(cfg, password: "pw")             // must not throw
        guard case let .reconnecting(1, next, _) = await engine.registrationState(of: cfg.id) else {
            Issue.record("state \(await engine.registrationState(of: cfg.id))")
            await engine.stop()
            return
        }
        #expect(next == 2)
        #expect(await waitUntil(timeout: 4) {
            if case .reconnecting(2, 4, _) = await engine.registrationState(of: cfg.id) { return true }
            return false
        })
        #expect(!log.registrations(cfg.id).contains { if case .failed = $0.1 { return true }; return false })
        try await engine.setRegistered(cfg.id, false)                 // still known to the engine
        #expect(await engine.registrationState(of: cfg.id) == .unregistered)
        await engine.stop()
    }

    /// 403 is a configuration/credentials error: `.failed`, no retry.
    @Test func forbiddenRegistrationIsNotRetried() async throws {
        let stub = try NetworkStub()
        defer { stub.stop() }
        stub.registerMode = .forbidden
        let engine = await makeEngine()
        let log = TimedEventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let cfg = AccountConfig(displayName: "F", username: "1001", domain: "127.0.0.1",
                                registrar: "127.0.0.1:\(stub.port)", enabled: true)
        try await engine.addAccount(cfg, password: "pw")
        let failed = RegistrationState.failed(code: 403, reason: "Forbidden")
        #expect(await waitUntil { await engine.registrationState(of: cfg.id) == failed })
        try await Task.sleep(for: .seconds(3))
        #expect(stub.registers.count == 1)
        #expect(await engine.registrationState(of: cfg.id) == failed)
        #expect(!log.registrations(cfg.id).contains { if case .reconnecting = $0.1 { return true }; return false })
        await engine.stop()
    }

    /// A network change while a registered account has a call: the account re-REGISTERs,
    /// then the call is re-INVITEd (by pjsua, after the REGISTER); `isReconnecting` goes on
    /// and off and the call stays connected.
    @Test func networkChangeReRegistersAndReinvites() async throws {
        let stub = try NetworkStub()
        defer { stub.stop() }
        let engine = await makeEngine()
        await engine.setTestTimings(mediaSilence: 60)                // the stub sends no RTP
        let log = TimedEventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let cfg = AccountConfig(displayName: "N", username: "1001", domain: "127.0.0.1",
                                registrar: "127.0.0.1:\(stub.port)", enabled: true)
        try await engine.addAccount(cfg, password: "pw")
        #expect(await waitUntil { await engine.registrationState(of: cfg.id).isRegistered })
        let id = try await engine.makeCall(to: DialString(uri: "sip:200@127.0.0.1:\(stub.port)", display: "200"),
                                           from: cfg.id)
        #expect(await waitUntil { await engine.calls().first { $0.id == id }?.state == .connected })
        let registersBefore = stub.registers.count

        await engine.simulateNetworkChange()
        #expect(await waitUntil { stub.registers.count > registersBefore && stub.snapshot.reinvites == 1 })
        #expect(await waitUntil {
            let c = await engine.calls().first { $0.id == id }
            return c?.state == .connected && c?.isReconnecting == false && c?.codec != nil
        })
        let flags = log.calls(id).map(\.isReconnecting)
        #expect(flags.contains(true), "isReconnecting was never set")
        #expect(flags.last == false)
        #expect(await engine.registrationState(of: cfg.id).isRegistered)
        #expect(await waitUntil { log.logged("re-INVITE after network change sent") })
        #expect(log.ended(id) == nil)
        try await engine.hangup(id)
        await engine.stop()
    }

    /// Offline: calls stay up and show `isReconnecting`; back online they are re-INVITEd
    /// (by the engine: the loopback account does not register) and RTP flows again.
    @Test func offlineKeepsCallsAndReconnectsWhenBack() async throws {
        let engine = await makeEngine()
        let log = TimedEventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        #expect(await waitUntil(timeout: 3) { !log.network().isEmpty })
        let account = AccountConfig(displayName: "L", username: "loop", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let port = await engine.localPort(of: .udp)
        let out = try await engine.makeCall(to: DialString(uri: "sip:callee@127.0.0.1:\(port)", display: "callee"),
                                            from: account.id)
        func incomingID() -> CallID? {
            log.all.lazy.compactMap { _, e -> CallID? in
                if case let .incomingCall(c) = e { return c.id }
                return nil
            }.first
        }
        #expect(await waitUntil { incomingID() != nil })
        let inc = try #require(incomingID())
        try await engine.answer(inc)
        func call(_ id: CallID) async -> CallInfo? { await engine.calls().first { $0.id == id } }
        #expect(await waitUntil {
            let a = await call(out), b = await call(inc)
            return a?.state == .connected && b?.state == .connected && a?.codec != nil
        })

        await engine.applyPathForTests(NetworkPath(satisfied: false, interface: "", address: "", gateway: ""))
        #expect(await waitUntil { log.network().last == .offline })
        #expect(await engine.networkState() == .offline)
        #expect(await call(out)?.isReconnecting == true)
        #expect(await call(inc)?.isReconnecting == true)
        #expect(await waitUntil { log.calls(out).last?.isReconnecting == true })
        await engine.simulateNetworkChange()                        // no effect while offline
        try await Task.sleep(for: .milliseconds(1500))
        #expect(log.ended(out) == nil && log.ended(inc) == nil)
        #expect(await engine.networkState() == .offline)            // nothing reports "online" by itself
        #expect(log.network().last == .offline)

        await engine.applyPathForTests(NetworkPath(satisfied: true, interface: "en9", address: "10.9.9.9", gateway: "10.9.9.1"))
        #expect(await waitUntil { log.network().last == .online })
        #expect(await waitUntil(timeout: 10) {
            let a = await call(out), b = await call(inc)
            return a?.isReconnecting == false && b?.isReconnecting == false
                && a?.state == .connected && b?.state == .connected
        })
        #expect(await waitUntil { log.logged("re-INVITE after network change sent") })
        #expect(await waitUntil { log.logged("media re-established after network change") })
        let rx1 = try await engine.mediaStats(out).rxPackets
        try await Task.sleep(for: .seconds(1))
        let rx2 = try await engine.mediaStats(out).rxPackets
        #expect(rx2 - rx1 > 30, "RTP after reconnect: \(rx2 - rx1) packets in 1 s")
        #expect(log.ended(out) == nil && log.ended(inc) == nil)
        await engine.stop()
    }

    /// A call whose media stops (RTCP had arrived, then nothing): after the limit the
    /// dialog is probed with OPTIONS; 481 ends it as "connection lost".
    @Test func silentMediaProbedThenEndedAsConnectionLost() async throws {
        let stub = try NetworkStub()
        defer { stub.stop() }
        stub.sendRTCP = true
        stub.optionsStatus = "481 Call/Transaction Does Not Exist"
        let engine = await makeEngine()
        await engine.setTestTimings(mediaSilence: 1, rtcpSilence: 1.5, connectionLost: 3)
        let log = TimedEventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = AccountConfig(displayName: "S", username: "silent", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let id = try await engine.makeCall(to: DialString(uri: "sip:200@127.0.0.1:\(stub.port)", display: "200"),
                                           from: account.id)
        #expect(await waitUntil { log.calls(id).contains { $0.state == .connected } })
        try await Task.sleep(for: .seconds(2))                      // RTCP arrives: the watchdog is armed
        #expect(log.calls(id).allSatisfy { !$0.isReconnecting }, "RTCP flows: not reconnecting")
        stub.sendRTCP = false
        #expect(await waitUntil(timeout: 4) { log.calls(id).contains { $0.isReconnecting } })
        #expect(await waitUntil(timeout: 8) { log.ended(id) != nil })
        #expect(stub.snapshot.options >= 1)
        let ended = try #require(log.ended(id))
        #expect(ended.state == .disconnected(code: 0, reason: Engine.connectionLostReason))
        await engine.stop()
    }

    /// The same silence, but the far end answers the OPTIONS probe: the call stays.
    @Test func silentMediaProbeAnsweredKeepsCall() async throws {
        let stub = try NetworkStub()
        defer { stub.stop() }
        stub.sendRTCP = true
        let engine = await makeEngine()
        await engine.setTestTimings(mediaSilence: 1, rtcpSilence: 1.5, connectionLost: 2)
        let log = TimedEventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = AccountConfig(displayName: "S", username: "probe", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let id = try await engine.makeCall(to: DialString(uri: "sip:200@127.0.0.1:\(stub.port)", display: "200"),
                                           from: account.id)
        #expect(await waitUntil { log.calls(id).contains { $0.state == .connected } })
        try await Task.sleep(for: .seconds(1.5))
        stub.sendRTCP = false
        #expect(await waitUntil(timeout: 6) { stub.snapshot.options >= 1 })
        #expect(await waitUntil { log.logged("OPTIONS probe answered 200; keeping the call") })
        #expect(log.ended(id) == nil)
        #expect(await engine.calls().first { $0.id == id }?.state == .connected)
        await engine.stop()
    }

    /// A peer that sends no RTP at all (silence suppression, a voicemail recording) but RTCP:
    /// not "reconnecting" without a recent network event, and never hung up; a peer without
    /// any RTCP is never hung up either (the watchdog only arms after RTCP was seen).
    @Test func rtpSilenceWithRTCPIsNotReconnecting() async throws {
        let stub = try NetworkStub()
        defer { stub.stop() }
        stub.sendRTCP = true
        let engine = await makeEngine()
        await engine.setTestTimings(mediaSilence: 1, rtcpSilence: 2, networkEventWindow: 0.1, connectionLost: 2)
        let log = TimedEventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = AccountConfig(displayName: "V", username: "vad", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let id = try await engine.makeCall(to: DialString(uri: "sip:200@127.0.0.1:\(stub.port)", display: "200"),
                                           from: account.id)
        #expect(await waitUntil { log.calls(id).contains { $0.state == .connected } })
        try await Task.sleep(for: .seconds(4))
        #expect(log.calls(id).allSatisfy { !$0.isReconnecting })
        #expect(stub.snapshot.options == 0)

        let stub2 = try NetworkStub()                                 // no RTCP at all
        defer { stub2.stop() }
        let id2 = try await engine.makeCall(to: DialString(uri: "sip:201@127.0.0.1:\(stub2.port)", display: "201"),
                                            from: account.id)
        #expect(await waitUntil { log.calls(id2).contains { $0.state == .connected } })
        try await Task.sleep(for: .seconds(4))
        #expect(stub2.snapshot.options == 0)
        #expect(log.ended(id2) == nil)
        await engine.stop()
    }

    /// The far end lost the dialog: 481 to the re-INVITE after a network change ends the call
    /// as "connection lost".
    @Test func reinviteAnswered481EndsCall() async throws {
        let stub = try NetworkStub()
        defer { stub.stop() }
        stub.reinviteStatus = "481 Call/Transaction Does Not Exist"
        let engine = await makeEngine()
        await engine.setTestTimings(mediaSilence: 60)
        let log = TimedEventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = AccountConfig(displayName: "G", username: "gone", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let id = try await engine.makeCall(to: DialString(uri: "sip:200@127.0.0.1:\(stub.port)", display: "200"),
                                           from: account.id)
        #expect(await waitUntil { log.calls(id).contains { $0.state == .connected } })
        await engine.simulateNetworkChange()
        #expect(await waitUntil { log.ended(id) != nil })
        #expect(stub.snapshot.reinvites == 1)
        #expect(log.ended(id)?.state == .disconnected(code: 0, reason: Engine.connectionLostReason))
        await engine.stop()
    }

    /// Sleep un-REGISTERs (Expires 0) and keeps the account; wake registers it again.
    @Test func sleepUnregistersAndWakeRegistersAgain() async throws {
        let stub = try NetworkStub()
        defer { stub.stop() }
        let engine = await makeEngine()
        let log = TimedEventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        #expect(await waitUntil(timeout: 3) { !log.network().isEmpty })
        let cfg = AccountConfig(displayName: "Z", username: "1001", domain: "127.0.0.1",
                                registrar: "127.0.0.1:\(stub.port)", enabled: true)
        try await engine.addAccount(cfg, password: "pw")
        #expect(await waitUntil { await engine.registrationState(of: cfg.id).isRegistered })

        await engine.handleSleep()
        #expect(await waitUntil { stub.registers.last?.unregister == true })
        #expect(await waitUntil { await engine.registrationState(of: cfg.id) == .unregistered })
        let count = stub.registers.count
        await engine.handleWake()
        #expect(await waitUntil(timeout: 5) {
            stub.registers.count > count && stub.registers.last?.unregister == false
        })
        #expect(await waitUntil { await engine.registrationState(of: cfg.id).isRegistered })
        await engine.stop()
    }

    // MARK: rounds: primary route, ringing calls, serialisation, ordering

    /// Only the primary route counts: the same interface/address/gateway (secondary
    /// interfaces are not part of the path) starts nothing; a gateway-only change waits while
    /// an outgoing call rings and runs once it stopped ringing.
    @Test func secondaryChangesIgnoredAndRingingCallPostponesRound() async throws {
        let stub = try NetworkStub()
        defer { stub.stop() }
        let engine = await makeEngine()
        let log = TimedEventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        #expect(await waitUntil(timeout: 3) { !log.network().isEmpty })
        let cfg = AccountConfig(displayName: "P", username: "1001", domain: "127.0.0.1",
                                registrar: "127.0.0.1:\(stub.port)", enabled: true)
        try await engine.addAccount(cfg, password: "pw")
        #expect(await waitUntil { await engine.registrationState(of: cfg.id).isRegistered })
        let base = NetworkPath(satisfied: true, interface: "en0", address: "192.168.1.20", gateway: "192.168.1.1")
        await engine.applyPathForTests(base)                          // a new primary route: one round
        #expect(await waitUntil { await engine.ipChangeStateForTests().running == nil })
        let rounds0 = await engine.ipChangeStateForTests().rounds
        await engine.applyPathForTests(NetworkPath(satisfied: true, interface: "en0", address: "192.168.1.20",
                                                   gateway: "192.168.1.1", summary: "en0 + bridge100 + utun3"))
        #expect(await engine.ipChangeStateForTests().rounds == rounds0)

        stub.ringOnly = true
        let id = try await engine.makeCall(to: DialString(uri: "sip:300@127.0.0.1:\(stub.port)", display: "300"),
                                           from: cfg.id)
        #expect(await waitUntil { log.calls(id).contains { $0.state == .early } })
        let registers = stub.registers.count
        await engine.applyPathForTests(NetworkPath(satisfied: true, interface: "en0", address: "192.168.1.20",
                                                   gateway: "192.168.1.254"))
        #expect(await engine.ipChangeStateForTests().postponed)
        try await Task.sleep(for: .seconds(2.5))
        #expect(await engine.ipChangeStateForTests().rounds == rounds0)
        #expect(log.ended(id) == nil, "the ringing call must survive")
        try await engine.hangup(id)
        #expect(await waitUntil(timeout: 4) { await engine.ipChangeStateForTests().rounds == rounds0 + 1 })
        #expect(await waitUntil { stub.registers.count > registers })
        await engine.stop()
    }

    /// pjsua's behaviour, kept on purpose for a change of the local address: after an
    /// account's re-REGISTER it hangs up that account's unanswered outgoing calls (410).
    @Test func ringingCallOfReRegisteringAccountEndsOnAddressChange() async throws {
        let stub = try NetworkStub()
        defer { stub.stop() }
        let engine = await makeEngine()
        let log = TimedEventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let cfg = AccountConfig(displayName: "R", username: "1001", domain: "127.0.0.1",
                                registrar: "127.0.0.1:\(stub.port)", enabled: true)
        try await engine.addAccount(cfg, password: "pw")
        #expect(await waitUntil { await engine.registrationState(of: cfg.id).isRegistered })
        stub.ringOnly = true
        let id = try await engine.makeCall(to: DialString(uri: "sip:300@127.0.0.1:\(stub.port)", display: "300"),
                                           from: cfg.id)
        #expect(await waitUntil { log.calls(id).contains { $0.state == .early } })
        await engine.simulateNetworkChange()
        #expect(await waitUntil { log.ended(id) != nil })
        if case let .disconnected(code, _)? = log.ended(id)?.state { #expect(code == 410) }
        await engine.stop()
    }

    /// Rounds never overlap: changes during a round (the registrar does not answer, so the
    /// round lasts one transaction timeout) are queued and merged into one more round.
    @Test func networkChangeRoundsAreSerialised() async throws {
        let stub = try NetworkStub()
        defer { stub.stop() }
        let engine = await makeEngine()
        await engine.setTestTimings(transactionTimeoutMs: 2000)
        let log = TimedEventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let cfg = AccountConfig(displayName: "Q", username: "1001", domain: "127.0.0.1",
                                registrar: "127.0.0.1:\(stub.port)", enabled: true)
        try await engine.addAccount(cfg, password: "pw")
        #expect(await waitUntil { await engine.registrationState(of: cfg.id).isRegistered })
        stub.registerMode = .silent
        let rounds0 = await engine.ipChangeStateForTests().rounds
        await engine.simulateNetworkChange()
        await engine.simulateNetworkChange()
        await engine.simulateNetworkChange()
        let during = await engine.ipChangeStateForTests()
        #expect(during.running == rounds0 + 1)
        #expect(during.queued)
        #expect(during.rounds == rounds0 + 1)
        try await Task.sleep(for: .seconds(1))
        #expect(await engine.ipChangeStateForTests().rounds == rounds0 + 1)
        // Round 1 ends when its REGISTER times out (2 s); the queued change runs as round 2.
        #expect(await waitUntil(timeout: 6) { await engine.ipChangeStateForTests().rounds == rounds0 + 2 })
        stub.registerMode = .ok
        #expect(await waitUntil(timeout: 10) { await engine.ipChangeStateForTests().running == nil })
        #expect(await engine.ipChangeStateForTests().rounds == rounds0 + 2)
        #expect(await waitUntil { log.logged("queued behind round") })
        await engine.stop()
    }

    /// The re-INVITE of an older round times out (408) while a newer round wants one: the
    /// call is not ended; the newer round's re-INVITE goes out and settles it.
    @Test func olderRoundReinviteTimeoutSendsFreshOne() async throws {
        let stub = try NetworkStub()
        defer { stub.stop() }
        stub.reinviteStatus = "drop"
        let engine = await makeEngine()
        await engine.setTestTimings(transactionTimeoutMs: 2000, mediaSilence: 60)
        let log = TimedEventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = AccountConfig(displayName: "T", username: "old", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let id = try await engine.makeCall(to: DialString(uri: "sip:200@127.0.0.1:\(stub.port)", display: "200"),
                                           from: account.id)
        #expect(await waitUntil { log.calls(id).contains { $0.state == .connected } })
        await engine.simulateNetworkChange()                        // round 1: re-INVITE gets no answer
        #expect(await waitUntil { stub.snapshot.reinvites >= 1 })
        await engine.simulateNetworkChange()                        // round 2 while it is pending
        // INVITE retransmissions go out at 0.5 and 1.5 s; the transaction times out at 2 s.
        try await Task.sleep(for: .milliseconds(1700))
        stub.reinviteStatus = "200 OK"
        #expect(await waitUntil(timeout: 8) { log.logged("answered 408; sending the one for round") })
        #expect(await waitUntil(timeout: 6) {
            let c = await engine.calls().first { $0.id == id }
            return c?.state == .connected && c?.isReconnecting == false
        })
        #expect(log.ended(id) == nil)
        #expect(stub.snapshot.reinvites >= 2)
        await engine.stop()
    }

    /// A re-INVITE that only ever gets 100 Trying does not leave the call "reconnecting"
    /// forever: after two transaction timeouts it is CANCELled and given up.
    @Test func reinviteStuckAtTryingIsGivenUp() async throws {
        let stub = try NetworkStub()
        defer { stub.stop() }
        stub.reinviteStatus = "trying"
        let engine = await makeEngine()
        await engine.setTestTimings(transactionTimeoutMs: 1000, mediaSilence: 60)
        let log = TimedEventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = AccountConfig(displayName: "T", username: "stuck", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let id = try await engine.makeCall(to: DialString(uri: "sip:200@127.0.0.1:\(stub.port)", display: "200"),
                                           from: account.id)
        #expect(await waitUntil { log.calls(id).contains { $0.state == .connected } })
        await engine.simulateNetworkChange()
        #expect(await waitUntil { log.calls(id).contains { $0.isReconnecting } })
        #expect(await waitUntil(timeout: 12) { log.logged("not settled") })
        #expect(await waitUntil { stub.snapshot.cancels >= 1 })
        #expect(await waitUntil {
            let c = await engine.calls().first { $0.id == id }
            return c?.state == .connected && c?.isReconnecting == false
        })
        try await Task.sleep(for: .seconds(1))
        #expect(log.ended(id) == nil)
        await engine.stop()
    }

    /// Path updates are applied in order: a burst of offline/online reports through the
    /// monitor's stream ending with online leaves the engine online.
    @Test func pathUpdatesAreAppliedInOrder() async throws {
        let engine = await makeEngine()
        let log = TimedEventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        #expect(await waitUntil(timeout: 3) { !log.network().isEmpty })
        await engine.handleWake()                                     // updates applied one by one
        let offline = NetworkPath(satisfied: false, interface: "", address: "", gateway: "")
        let online = NetworkPath(satisfied: true, interface: "en0", address: "192.168.7.7", gateway: "192.168.7.1")
        for _ in 0..<20 {
            await engine.injectPathForTests(offline)
            await engine.injectPathForTests(online)
        }
        #expect(await waitUntil(timeout: 6) { log.network().last == .online })
        try await Task.sleep(for: .seconds(3))                       // past the debounce
        #expect(await engine.networkState() == .online)
        #expect(log.network().last == .online)
        await engine.stop()
    }
}

// MARK: - pure parts

@Suite("Network resilience helpers")
struct EngineNetworkHelperTests {
    @Test func registrationRetryClassificationAndBackoff() {
        let ok: Int32 = 0
        let someError: Int32 = 120_065           // any PJ status other than PJ_SUCCESS
        for code in [408, 480, 500, 502, 503, 504] {
            #expect(RegistrationMapping.isTemporary(status: ok, code: code), "\(code)")
        }
        for code in [400, 401, 403, 404, 407, 423, 488, 603] {
            #expect(!RegistrationMapping.isTemporary(status: ok, code: code), "\(code)")
        }
        #expect(RegistrationMapping.isTemporary(status: someError, code: 400))   // refresh could not be sent
        #expect(RegistrationMapping.isTemporary(status: someError, code: 0))
        #expect(!RegistrationMapping.isTemporary(status: someError, code: 401))  // no usable credentials
        #expect(RegistrationMapping.errorText(status: ok, code: 408, reason: "Request Timeout") == "408 Request Timeout")
        #expect(!RegistrationMapping.errorText(status: someError, code: 400, reason: "x").isEmpty)
        #expect((1...8).map { RegistrationBackoff.delay(attempt: $0) } == [2, 4, 8, 16, 32, 60, 60, 60])
    }

    @Test func primaryRouteComparison() {
        let a = NetworkPath(satisfied: true, interface: "en0", address: "192.168.1.20", gateway: "192.168.1.1")
        var b = a
        b.summary = "en0, bridge100, utun4"                           // secondary interfaces: not compared
        #expect(!a.routeDiffers(from: b) && !a.primaryDiffers(from: b))
        b.gateway = "192.168.1.254"
        #expect(a.routeDiffers(from: b) && !a.primaryDiffers(from: b))
        b = a
        b.address = "10.0.0.5"
        #expect(a.primaryDiffers(from: b))
        b = a
        b.interface = "utun4"                                          // a full-tunnel VPN took the route
        #expect(a.primaryDiffers(from: b))
    }

    @Test func permanentTransportFailures() {
        let ok: Int32 = 0
        let tls = RegistrationMapping.permanentTransportTexts.first ?? "certificate"
        #expect(!RegistrationMapping.isTemporary(status: ok, code: 503, reason: tls, onlineStable: false))
        #expect(!RegistrationMapping.isTemporary(status: ok, code: 503, reason: "SSL certificate verify failed",
                                                 onlineStable: false))
        let dns = RegistrationMapping.resolveTexts[0]
        #expect(RegistrationMapping.isTemporary(status: ok, code: 502, reason: dns, onlineStable: false))
        #expect(!RegistrationMapping.isTemporary(status: ok, code: 502, reason: dns, onlineStable: true))
        #expect(RegistrationMapping.isTemporary(status: ok, code: 408, reason: "Request Timeout", onlineStable: true))
    }

    @Test func connectionLostAndReconnectingInCallInfo() {
        func snap(_ state: InviteState, status: Int = 0, text: String = "") -> CallSnapshot {
            CallSnapshot(slot: 1, accIndex: 0, isOutgoing: true, state: state, lastStatus: status,
                         lastStatusText: text, remoteInfo: "<sip:1@x>", sipCallID: "c", mediaStatus: .active,
                         confSlot: 2, connectDuration: 0, serial: 9, codec: "PCMU/8000", isSecure: false)
        }
        var rec = CallRecord(serial: 9, accountID: .unknown, direction: .outgoing, announced: true)
        rec.reconnecting = true
        #expect(EngineBridge.makeInfo(snap(.confirmed), rec).isReconnecting)
        #expect(!EngineBridge.makeInfo(snap(.early), rec).isReconnecting)
        let lost = CallState.disconnected(code: 0, reason: Engine.connectionLostReason)
        #expect(Engine.connectionLostReason == "connection lost")
        // A normal hang-up while reconnecting keeps its code.
        #expect(EngineBridge.makeInfo(snap(.disconnected, status: 200, text: "Normal call clearing"), rec).state
                == .disconnected(code: 200, reason: "Normal call clearing"))
        // 481 / 408 to the re-INVITE after a network change.
        rec.reinviteInFlight = 1
        #expect(EngineBridge.makeInfo(snap(.disconnected, status: 481, text: "Call Does Not Exist"), rec).state == lost)
        #expect(EngineBridge.makeInfo(snap(.disconnected, status: 408, text: "Request Timeout"), rec).state == lost)
        // 481 / 408 to the watchdog's OPTIONS probe.
        rec.reinviteInFlight = nil
        rec.probing = true
        #expect(EngineBridge.makeInfo(snap(.disconnected, status: 481, text: "Call Does Not Exist"), rec).state == lost)
        // Ended by the engine.
        rec.probing = false
        rec.connectionLost = true
        #expect(EngineBridge.makeInfo(snap(.disconnected, status: 200, text: "Normal call clearing"), rec).state == lost)
    }

    @Test func pjsuaAccountSettingsForNetworkChanges() throws {
        let account = AccountConfig(displayName: "U", username: "1001", domain: "sip.example.com")
        let s = try AccountMapping.settings(for: account, password: "", network: .default,
                                            transports: TransportIDs(udp: 0))
        let back = AccountMapping.withPJConfig(s) { AccountMapping.readBack($0) }
        for x in [s, back] {
            #expect(x.regRetryInterval == 0)                    // the engine retries, not pjsua
            #expect(!x.dropCallsOnRegFail)
            #expect(!x.ipChangeHangupCalls)
            #expect(x.ipChangeReinviteFlags != 0)
        }
    }
}
