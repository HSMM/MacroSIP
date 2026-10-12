import Foundation
import MacroSIPCore

/// Self-test steps after the conference: incoming calls, blind and attended transfer (both
/// pjsua phones driven through their telnet CLIs), DTMF over SIP INFO and calls of a
/// registered account (both against `SIPStub`).
extension SelfTest {
    struct Context {
        let engine: Engine
        let recorder: Recorder
        let account: AccountConfig
        let options: Options
    }

    // MARK: - incoming calls

    /// pjsua #1 calls us through its CLI: answer, two-way RTP for 2 s, hang up from the engine
    /// (pjsua must be left without a call, i.e. it got the BYE); a second call is rejected with 486.
    static func incomingCalls(_ c: Context, cli: UInt16, step: (String) -> Void) async throws {
        let port = await c.engine.localPort(of: .udp)
        let uri = "sip:selftest@127.0.0.1:\(port)"
        let number = userPart(c.options.target)

        var mark = c.recorder.events.count
        _ = try await pjsuaCLI("call new \(uri)", port: cli)
        let incoming = try await waitForEvent(c.recorder, since: mark, "incomingCall", timeout: 5) { e -> CallInfo? in
            if case let .incomingCall(info) = e { return info }
            return nil
        }
        guard incoming.state == .incoming, incoming.direction == .incoming, incoming.remote.number == number else {
            throw Failure(description: "incomingCall: \(describe(incoming)), expected number \(number)")
        }
        step("incoming call (pjsua CLI 'call new \(uri)'): \(incoming.id) from \(incoming.remote.uri), number \(incoming.remote.number)")

        try await c.engine.answer(incoming.id)
        let answered = try await waitFor(c.engine, incoming.id, "incoming call connected", timeout: 5) {
            $0.state == .connected && $0.codec != nil
        }
        try await Task.sleep(for: .milliseconds(300))
        let s = try await c.engine.mediaStats(incoming.id)
        try await Task.sleep(for: .seconds(2))
        let e = try await c.engine.mediaStats(incoming.id)
        guard e.rxPackets - s.rxPackets > 50, e.txPackets - s.txPackets > 50 else {
            throw Failure(description: "incoming call RTP in 2 s: rx +\(e.rxPackets - s.rxPackets), tx +\(e.txPackets - s.txPackets)")
        }
        step("answered: codec \(answered.codec ?? "-"), 2 s of RTP rx +\(e.rxPackets - s.rxPackets) tx +\(e.txPackets - s.txPackets)")

        // Hold and resume back to back: the resume meets the hold re-INVITE in flight and is
        // sent once it completes; the call must end up connected with RTP from the phone.
        let mark2 = c.recorder.events.count
        try await c.engine.setHold(incoming.id, true)
        try await c.engine.setHold(incoming.id, false)
        try await Task.sleep(for: .seconds(1))
        let settled = try await waitFor(c.engine, incoming.id, "connected after hold + resume", timeout: 5) {
            $0.state == .connected && !$0.isOnHold
        }
        let h1 = try await c.engine.mediaStats(incoming.id)
        try await Task.sleep(for: .seconds(1))
        let h2 = try await c.engine.mediaStats(incoming.id)
        guard h2.rxPackets - h1.rxPackets > 30 else {
            throw Failure(description: "no RTP after hold + resume: rx +\(h2.rxPackets - h1.rxPackets) in 1 s")
        }
        let lastChange = c.recorder.events.dropFirst(mark2).reversed().lazy.compactMap { e -> CallInfo? in
            if case let .callChanged(info) = e, info.id == incoming.id { return info }
            return nil
        }.first
        guard let lastChange, lastChange.state == .connected, !lastChange.isOnHold else {
            throw Failure(description: "last callChanged after hold + resume: \(lastChange.map { describe($0) } ?? "none")")
        }
        let deferred = c.recorder.events.dropFirst(mark2).contains {
            if case let .log(_, text) = $0 { return text.contains("waits for the re-INVITE in progress") }
            return false
        }
        step("hold + resume back to back\(deferred ? " (resume deferred until the hold re-INVITE completed)" : ""): "
             + "\(describe(settled.state)), RTP rx +\(h2.rxPackets - h1.rxPackets) in 1 s")

        try await c.engine.hangup(incoming.id)
        let ended = try await waitForEnd(c.recorder, incoming.id, timeout: 5)
        _ = try await waitForCLI(cli, "no call left after our BYE", timeout: 5) { activeCalls($0) == 0 }
        step("hung up by the engine: callEnded \(describe(ended.0.state)), \(String(format: "%.1f", ended.1)) s; "
             + "pjsua 'call list': 0 active calls")

        mark = c.recorder.events.count
        _ = try await pjsuaCLI("call new \(uri)", port: cli)
        let second = try await waitForEvent(c.recorder, since: mark, "second incomingCall", timeout: 5) { e -> CallInfo? in
            if case let .incomingCall(info) = e { return info }
            return nil
        }
        try await c.engine.reject(second.id, code: 486)
        let rejected = try await waitForEnd(c.recorder, second.id, timeout: 5)
        guard case .disconnected(486, _) = rejected.0.state, rejected.1 == 0 else {
            throw Failure(description: "rejected call ended as \(describe(rejected.0)), duration \(rejected.1)")
        }
        _ = try await waitForCLI(cli, "no call left after 486", timeout: 5) { activeCalls($0) == 0 }
        step("second incoming call \(second.id) rejected: callEnded \(describe(rejected.0.state)); pjsua has no call left")
    }

    // MARK: - transfers

    /// We call pjsua #1 and transfer it to pjsua #2 (REFER): the final NOTIFY is a 2xx, the
    /// engine hangs up its leg and pjsua #2 is in a call with pjsua #1.
    static func blindTransfer(_ c: Context, cli1: UInt16, cli2: UInt16, step: (String) -> Void) async throws {
        let dial = try parse(c.options.target, c.account)
        let dest = try parse(c.options.target2, c.account)
        let id = try await c.engine.makeCall(to: dial, from: c.account.id)
        _ = try await waitFor(c.engine, id, "call to transfer connected", timeout: 10) { $0.state == .connected && $0.codec != nil }

        let mark = c.recorder.events.count
        try await c.engine.blindTransfer(id, to: dest)
        let code = try await waitForTransfer(c.recorder, id, since: mark)
        let ended = try await waitForEnd(c.recorder, id, timeout: 5)
        let (peer1, peer2) = try await phonesConnected(c, cli1: cli1, cli2: cli2)
        step("blind transfer \(id) -> \(dest.uri): final NOTIFY \(code), our leg ended (\(describe(ended.0.state))); "
             + "pjsua 1: \(currentCall(peer1) ?? "-"); pjsua 2: \(currentCall(peer2) ?? "-")")
        try await hangUpPhones(cli1, cli2)
    }

    /// After a transfer: we have no call left and each pjsua phone is in a confirmed call with
    /// the other (pjsua's `call list` shows the peer's URI without port, so the phones need
    /// distinct user parts: the script gives them --id phone1 / phone2).
    static func phonesConnected(_ c: Context, cli1: UInt16, cli2: UInt16) async throws -> (String, String) {
        let left = await c.engine.calls()
        guard left.isEmpty else { throw Failure(description: "calls left after the transfer: \(left.map { describe($0) })") }
        let user1 = "sip:\(userPart(c.options.target))@", user2 = "sip:\(userPart(c.options.target2))@"
        guard user1 != user2 else { throw Failure(description: "--target and --target2 need different user parts") }
        let peer1 = try await waitForCLI(cli1, "pjsua 1 in a call with pjsua 2", timeout: 5) {
            guard activeCalls($0) == 1, let call = currentCall($0) else { return false }
            return call.contains(user2) && call.contains("[CONFIRMED]")
        }
        let peer2 = try await waitForCLI(cli2, "pjsua 2 in a call with pjsua 1", timeout: 5) {
            guard activeCalls($0) == 1, let call = currentCall($0) else { return false }
            return call.contains(user1) && call.contains("[CONFIRMED]")
        }
        return (peer1, peer2)
    }

    /// Call pjsua #1, hold, call pjsua #2, REFER #1 with Replaces of the second call: both of
    /// our legs end and the two pjsua phones are connected to each other.
    static func attendedTransfer(_ c: Context, cli1: UInt16, cli2: UInt16, step: (String) -> Void) async throws {
        let dial1 = try parse(c.options.target, c.account)
        let dial2 = try parse(c.options.target2, c.account)
        let id1 = try await c.engine.makeCall(to: dial1, from: c.account.id)
        _ = try await waitFor(c.engine, id1, "first leg connected", timeout: 10) { $0.state == .connected && $0.codec != nil }
        try await c.engine.setHold(id1, true)
        _ = try await waitFor(c.engine, id1, "first leg held", timeout: 5) { $0.state == .held }
        let id2 = try await c.engine.makeCall(to: dial2, from: c.account.id)
        _ = try await waitFor(c.engine, id2, "second leg connected", timeout: 10) { $0.state == .connected && $0.codec != nil }

        let mark = c.recorder.events.count
        try await c.engine.attendedTransfer(id1, replacing: id2)
        let code = try await waitForTransfer(c.recorder, id1, since: mark)
        let end1 = try await waitForEnd(c.recorder, id1, timeout: 5)
        let end2 = try await waitForEnd(c.recorder, id2, timeout: 5)
        let (peer1, peer2) = try await phonesConnected(c, cli1: cli1, cli2: cli2)
        step("attended transfer \(id1) replacing \(id2): final NOTIFY \(code), both legs ended "
             + "(\(describe(end1.0.state)), \(describe(end2.0.state))); pjsua 1: \(currentCall(peer1) ?? "-"); "
             + "pjsua 2: \(currentCall(peer2) ?? "-")")
        try await hangUpPhones(cli1, cli2)
    }

    // MARK: - SIP stub: DTMF over INFO, registered account

    /// The stub answers without telephone-event: `sendDTMF` must fall back to SIP INFO.
    static func dtmfInfo(_ c: Context, stub: SIPStub, step: (String) -> Void) async throws {
        let dial = try parse("sip:ivr@127.0.0.1:\(stub.port)", c.account)
        let id = try await c.engine.makeCall(to: dial, from: c.account.id)
        let info = try await waitFor(c.engine, id, "call to the stub connected", timeout: 10) { $0.state == .connected && $0.codec != nil }
        try await c.engine.sendDTMF(id, "5#")
        let deadline = Date().addingTimeInterval(3)
        var bodies: [String] = []
        while Date() < deadline {
            bodies = stub.stats.infoBodies
            if bodies.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let signals = bodies.compactMap { body in
            body.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("signal=") }
        }
        guard signals == ["Signal=5", "Signal=#"] else {
            throw Failure(description: "INFO DTMF at the stub: \(bodies.count) INFO, signals \(signals)")
        }
        try await c.engine.hangup(id)
        _ = try await waitForEnd(c.recorder, id, timeout: 5)
        step("DTMF \"5#\" to a peer without telephone-event (\(info.codec ?? "-")): sent as SIP INFO (\(signals.joined(separator: ", ")))")
    }

    /// An account registered with digest authentication (Asterisk-style 401) calls the stub,
    /// holds and resumes: every INVITE carries an Authorization header and is larger than
    /// PJSIP's UDP size threshold (1300 bytes). PJSIP's RFC 3261 18.1.1 switch to TCP must not
    /// kick in (the account is bound to the UDP transport): no "Unsuitable transport selected
    /// ... will try next server" may be logged.
    static func registeredCalls(_ c: Context, stub: SIPStub, step: (String) -> Void) async throws {
        let account = AccountConfig(displayName: "registered", username: "100", domain: "127.0.0.1:\(stub.port)",
                                    enabled: true, isDefaultOutgoing: false)
        try await c.engine.addAccount(account, password: "selftest-secret")
        let deadline = Date().addingTimeInterval(5)
        var reg = await c.engine.registrationState(of: account.id)
        while Date() < deadline {
            reg = await c.engine.registrationState(of: account.id)
            if case .registered = reg { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard case .registered = reg else { throw Failure(description: "stub registration: \(describe(reg))") }

        let mark = c.recorder.events.count
        let earlierInvites = stub.stats.authorizedInviteSizes.count
        let dial = try parse("sip:200@127.0.0.1:\(stub.port)", account)
        let id = try await c.engine.makeCall(to: dial, from: account.id)
        _ = try await waitFor(c.engine, id, "registered call connected", timeout: 10) { $0.state == .connected && $0.codec != nil }
        try await c.engine.setHold(id, true)
        _ = try await waitFor(c.engine, id, "registered call held", timeout: 5) { $0.state == .held }
        try await c.engine.setHold(id, false)              // back to back: deferred by the engine
        let resumeDeadline = Date().addingTimeInterval(5)
        while stub.stats.authorizedInviteSizes.count < earlierInvites + 3, Date() < resumeDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try await waitFor(c.engine, id, "registered call resumed", timeout: 5) { $0.state == .connected && !$0.isOnHold }
        try await c.engine.hangup(id)
        _ = try await waitForEnd(c.recorder, id, timeout: 5)

        let sizes = Array(stub.stats.authorizedInviteSizes.dropFirst(earlierInvites))
        guard sizes.count == 3, sizes.allSatisfy({ $0 > 1300 }) else {
            throw Failure(description: "authorised INVITEs at the stub: \(sizes) bytes; need 3 above 1300")
        }
        let retries = c.recorder.events.dropFirst(mark).compactMap { e -> String? in
            guard case let .log(_, text) = e,
                  text.contains("ETPNOTSUITABLE") || text.contains("will try next server") else { return nil }
            return text
        }
        guard retries.isEmpty else {
            throw Failure(description: "transport retry logged: \(retries.first ?? "")")
        }
        try await c.engine.removeAccount(account.id)
        step("registered account \(account.uri) (401 -> 200): INVITE + 2 re-INVITEs of \(sizes.map(String.init).joined(separator: "/")) "
             + "bytes over UDP, no 'Unsuitable transport' retry")
    }

    // MARK: - helpers

    static func parse(_ uri: String, _ account: AccountConfig) throws -> DialString {
        guard let dial = DialString.parse(uri, account: account) else { throw Failure(description: "cannot parse \(uri)") }
        return dial
    }

    /// "sip:test@127.0.0.1:5080" -> "test".
    static func userPart(_ uri: String) -> String {
        var s = uri
        if let colon = s.firstIndex(of: ":") { s = String(s[s.index(after: colon)...]) }
        return s.firstIndex(of: "@").map { String(s[..<$0]) } ?? ""
    }

    /// "You have N active call(s)" from pjsua's `call list` (the last one in the output).
    static func activeCalls(_ text: String) -> Int? {
        text.components(separatedBy: "\n").reversed().lazy.compactMap { line -> Int? in
            guard let r = line.range(of: "You have ") else { return nil }
            return Int(line[r.upperBound...].prefix { $0.isNumber })
        }.first
    }

    /// "Current call id=0 to <sip:...> [CONFIRMED]" from pjsua's `call list`.
    static func currentCall(_ text: String) -> String? {
        text.components(separatedBy: "\n").last { $0.contains("Current call id=") }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Polls pjsua's `call list` until `condition` holds; returns the output.
    static func waitForCLI(_ port: UInt16, _ what: String, timeout: Double,
                           _ condition: (String) -> Bool) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            last = try await pjsuaCLI("call list", port: port)
            if condition(last) { return last }
            try await Task.sleep(for: .milliseconds(200))
        }
        let lines = last.components(separatedBy: "\n").filter { $0.contains("You have") || $0.contains("Current call") }
        throw Failure(description: "pjsua CLI \(port): timeout waiting for \(what); last 'call list': \(lines)")
    }

    static func hangUpPhones(_ cli1: UInt16, _ cli2: UInt16) async throws {
        _ = try await pjsuaCLI("call hangup_all", port: cli1)
        _ = try await pjsuaCLI("call hangup_all", port: cli2)
        _ = try await waitForCLI(cli1, "pjsua 1 idle", timeout: 5) { activeCalls($0) == 0 }
        _ = try await waitForCLI(cli2, "pjsua 2 idle", timeout: 5) { activeCalls($0) == 0 }
    }

    static func waitForTransfer(_ recorder: Recorder, _ id: CallID, since: Int) async throws -> Int {
        let code = try await waitForEvent(recorder, since: since, "final transferStatus", timeout: 10) { e -> Int? in
            if case let .transferStatus(cid, code, true) = e, cid == id { return code }
            return nil
        }
        guard (200..<300).contains(code) else { throw Failure(description: "transfer of \(id) failed: final NOTIFY \(code)") }
        return code
    }

    static func waitForEvent<T>(_ recorder: Recorder, since: Int, _ what: String, timeout: Double,
                                _ match: (EngineEvent) -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for e in recorder.events.dropFirst(since) {
                if let value = match(e) { return value }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure(description: "no \(what) event within \(Int(timeout)) s")
    }
}
