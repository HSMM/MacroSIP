import Foundation
import MacroSIPCore

/// Self-test steps for the 26.1 call options: Do Not Disturb and single-call mode (486 for an
/// incoming call) against the pjsua phones, and the DTMF method selection against `SIPStub`.
extension SelfTest {
    /// We are in a call with pjsua #2; in single-call mode pjsua #1's call to us is answered
    /// 486 at once: no `.incomingCall`, a `.callEnded` with 486 and a `.log` line, pjsua #1
    /// is left without a call and our call keeps running.
    static func singleCallMode(_ c: Context, cli: UInt16, step: (String) -> Void) async throws {
        let dial = try parse(c.options.target2, c.account)
        let id = try await c.engine.makeCall(to: dial, from: c.account.id)
        _ = try await waitFor(c.engine, id, "call to pjsua 2 connected", timeout: 10) { $0.state == .connected && $0.codec != nil }

        await c.engine.setCallOptions(CallOptions(incomingWhileOnCall: .busy))
        let port = await c.engine.localPort(of: .udp)
        let number = userPart(c.options.target)
        let mark = c.recorder.events.count
        _ = try await pjsuaCLI("call new sip:selftest@127.0.0.1:\(port)", port: cli)
        let rejected = try await waitForEvent(c.recorder, since: mark, "callEnded 486 of the second call", timeout: 5) { e -> CallInfo? in
            if case let .callEnded(info, _) = e, info.direction == .incoming, info.remote.number == number { return info }
            return nil
        }
        guard case .disconnected(486, _) = rejected.state else {
            throw Failure(description: "second call in single-call mode ended as \(describe(rejected))")
        }
        let rang = c.recorder.events.dropFirst(mark).contains { if case .incomingCall = $0 { return true }; return false }
        let logged = c.recorder.events.dropFirst(mark).contains {
            if case let .log(_, text) = $0 { return text.contains("single-call mode") }
            return false
        }
        guard !rang, logged else {
            throw Failure(description: "single-call mode: incomingCall emitted \(rang), log line \(logged)")
        }
        _ = try await waitForCLI(cli, "pjsua 1 idle after 486", timeout: 5) { activeCalls($0) == 0 }
        let first = await c.engine.calls().first { $0.id == id }
        guard first?.state == .connected else {
            throw Failure(description: "first call after the 486: \(first.map { describe($0) } ?? "gone")")
        }
        await c.engine.setCallOptions(CallOptions())
        try await c.engine.hangup(id)
        _ = try await waitForEnd(c.recorder, id, timeout: 5)
        step("single-call mode: pjsua 1's call during our call to pjsua 2 got \(describe(rejected.state)) at once "
             + "(no incomingCall, log line written); pjsua 1 idle, our call stayed connected")
    }

    /// Do Not Disturb with no call in progress: pjsua #1's call is answered 486 at once (no
    /// `.incomingCall`, a `.log` line), pjsua #1 is left without a call.
    static func doNotDisturb(_ c: Context, cli: UInt16, step: (String) -> Void) async throws {
        await c.engine.setCallOptions(CallOptions(doNotDisturb: true))
        let port = await c.engine.localPort(of: .udp)
        let number = userPart(c.options.target)
        let mark = c.recorder.events.count
        _ = try await pjsuaCLI("call new sip:selftest@127.0.0.1:\(port)", port: cli)
        let rejected = try await waitForEvent(c.recorder, since: mark, "callEnded 486 in Do Not Disturb", timeout: 5) { e -> CallInfo? in
            if case let .callEnded(info, _) = e, info.direction == .incoming, info.remote.number == number { return info }
            return nil
        }
        guard case .disconnected(486, _) = rejected.state else {
            throw Failure(description: "call in Do Not Disturb ended as \(describe(rejected))")
        }
        let rang = c.recorder.events.dropFirst(mark).contains { if case .incomingCall = $0 { return true }; return false }
        let logged = c.recorder.events.dropFirst(mark).contains {
            if case let .log(_, text) = $0 { return text.contains("(do not disturb)") }
            return false
        }
        guard !rang, logged else {
            throw Failure(description: "Do Not Disturb: incomingCall emitted \(rang), log line \(logged)")
        }
        _ = try await waitForCLI(cli, "pjsua 1 idle after 486", timeout: 5) { activeCalls($0) == 0 }
        await c.engine.setCallOptions(CallOptions())
        step("Do Not Disturb: pjsua 1's call got \(describe(rejected.state)) at once (no incomingCall, log line written); pjsua 1 idle")
    }

    /// The stub offers no telephone-event: RFC 2833 only fails with `.unsupported`, SIP INFO
    /// only sends INFO, in-band sends no INFO.
    static func dtmfMethods(_ c: Context, stub: SIPStub, step: (String) -> Void) async throws {
        let dial = try parse("sip:ivr@127.0.0.1:\(stub.port)", c.account)
        let id = try await c.engine.makeCall(to: dial, from: c.account.id)
        _ = try await waitFor(c.engine, id, "call to the stub connected", timeout: 10) { $0.state == .connected && $0.codec != nil }
        let earlier = stub.stats.infoBodies.count

        await c.engine.setCallOptions(CallOptions(dtmfMethod: .rfc2833))
        do {
            try await c.engine.sendDTMF(id, "3")
            throw Failure(description: "RFC 2833 only to a peer without telephone-event did not fail")
        } catch EngineError.unsupported {
        }

        await c.engine.setCallOptions(CallOptions(dtmfMethod: .sipINFO))
        try await c.engine.sendDTMF(id, "7")
        let deadline = Date().addingTimeInterval(3)
        while stub.stats.infoBodies.count < earlier + 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        await c.engine.setCallOptions(CallOptions(dtmfMethod: .inband))
        try await c.engine.sendDTMF(id, "1")
        try await Task.sleep(for: .milliseconds(500))
        let bodies = Array(stub.stats.infoBodies.dropFirst(earlier))
        guard bodies.count == 1, bodies[0].contains("Signal=7") else {
            throw Failure(description: "DTMF methods at the stub: INFO bodies \(bodies)")
        }
        await c.engine.setCallOptions(CallOptions())
        try await c.engine.hangup(id)
        _ = try await waitForEnd(c.recorder, id, timeout: 5)
        step("DTMF methods: RFC 2833 only -> unsupported (no telephone-event), SIP INFO only -> one INFO (Signal=7), "
             + "in-band -> no INFO")
    }
}
