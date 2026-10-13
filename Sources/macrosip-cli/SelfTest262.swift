import Foundation
import MacroSIPCore

/// Self-test steps for 26.2 engine work: the deny rules for incoming calls and a GSM call
/// against a pjsua phone (an independent implementation of the codec).
extension SelfTest {
    /// pjsua #1 calls us while "deny everyone" is on: 603 at once (no `.incomingCall`, a log
    /// line); then "numbers not in contacts" with pjsua #1 not among them: 603 again; with
    /// its number known the call rings and we reject it ourselves.
    static func denyIncoming(_ c: Context, cli: UInt16, step: (String) -> Void) async throws {
        let port = await c.engine.localPort(of: .udp)
        let number = userPart(c.options.target)
        var results: [String] = []
        for options in [CallOptions(denyIncoming: .everyone), CallOptions(denyIncoming: .notInContacts, knownNumbers: ["someone-else"])] {
            await c.engine.setCallOptions(options)
            let mark = c.recorder.events.count
            _ = try await pjsuaCLI("call new sip:selftest@127.0.0.1:\(port)", port: cli)
            let denied = try await waitForEvent(c.recorder, since: mark, "callEnded 603 (\(options.denyIncoming))", timeout: 5) { e -> CallInfo? in
                if case let .callEnded(info, _) = e, info.direction == .incoming, info.remote.number == number { return info }
                return nil
            }
            guard case .disconnected(603, _) = denied.state else {
                throw Failure(description: "deny \(options.denyIncoming): call ended as \(describe(denied))")
            }
            let rang = c.recorder.events.dropFirst(mark).contains { if case .incomingCall = $0 { return true }; return false }
            let logged = c.recorder.events.dropFirst(mark).contains {
                if case let .log(_, text) = $0 { return text.contains("denied with 603 Decline") }
                return false
            }
            guard !rang, logged else {
                throw Failure(description: "deny \(options.denyIncoming): incomingCall emitted \(rang), log line \(logged)")
            }
            _ = try await waitForCLI(cli, "pjsua 1 idle after 603", timeout: 5) { activeCalls($0) == 0 }
            results.append("\(options.denyIncoming.rawValue) -> \(describe(denied.state))")
        }

        await c.engine.setCallOptions(CallOptions(denyIncoming: .notInContacts, knownNumbers: [number]))
        let mark = c.recorder.events.count
        _ = try await pjsuaCLI("call new sip:selftest@127.0.0.1:\(port)", port: cli)
        let ringing = try await waitForEvent(c.recorder, since: mark, "incomingCall from a known number", timeout: 5) { e -> CallInfo? in
            if case let .incomingCall(info) = e, info.remote.number == number { return info }
            return nil
        }
        try await c.engine.reject(ringing.id, code: 486)
        _ = try await waitForEnd(c.recorder, ringing.id, timeout: 5)
        _ = try await waitForCLI(cli, "pjsua 1 idle after reject", timeout: 5) { activeCalls($0) == 0 }
        await c.engine.setCallOptions(CallOptions())
        step("deny incoming: \(results.joined(separator: ", ")) at once (no incomingCall, log line); "
             + "a known number (\(number)) rings with notInContacts")
    }

    /// GSM only on our side, pjsua offers everything: the call negotiates GSM/8000 and RTP flows
    /// both ways. The default codec order is restored afterwards.
    static func gsmCall(_ c: Context, step: (String) -> Void) async throws {
        let all = await c.engine.codecs().map(\.id)
        let missing = Engine.optionalCodecs.filter { !all.contains($0) }
        guard missing.isEmpty else { throw Failure(description: "codecs not built: \(missing)") }
        try await c.engine.setCodecPriorities(["GSM/8000/1"])
        let connected: CallInfo
        let stats: CallMediaStats
        do {
            let dial = try parse(c.options.target, c.account)
            let id = try await c.engine.makeCall(to: dial, from: c.account.id)
            connected = try await waitFor(c.engine, id, "GSM call connected", timeout: 10) { $0.state == .connected && $0.codec != nil }
            guard connected.codec?.uppercased() == "GSM/8000" else {
                throw Failure(description: "GSM-only call negotiated \(connected.codec ?? "nothing")")
            }
            try await Task.sleep(for: .seconds(1))
            stats = try await c.engine.mediaStats(id)
            guard stats.rxPackets > 10, stats.txPackets > 10 else {
                throw Failure(description: "GSM call RTP: rx \(stats.rxPackets), tx \(stats.txPackets)")
            }
            try await c.engine.hangup(id)
            _ = try await waitForEnd(c.recorder, id, timeout: 5)
        } catch {
            try? await c.engine.setCodecPriorities(Engine.defaultCodecOrder)
            throw error
        }
        try await c.engine.setCodecPriorities(Engine.defaultCodecOrder)
        step("codecs: \(Engine.optionalCodecs.joined(separator: ", ")) built; GSM-only call to pjsua 1 "
             + "negotiated \(connected.codec ?? "-"), RTP rx \(stats.rxPackets) tx \(stats.txPackets) in 1 s")
    }
}
