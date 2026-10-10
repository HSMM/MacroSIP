import Foundation
import MacroSIPCore

/// `macrosip-cli --selftest`: one real call against a second phone (pjsua CLI with
/// --auto-answer 200 on localhost). Exit 0 only when every step passed.
@MainActor
enum SelfTest {
    final class Recorder {
        var events: [EngineEvent] = []
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run(_ options: Options) async -> Int32 {
        let bind = options.bind == "any" ? nil : (options.bind ?? "127.0.0.1")
        let engine = Engine(logLevel: options.logLevel ?? 3, nullAudio: true, bindAddress: bind)
        let recorder = Recorder()
        let printer = Task { @MainActor in
            for await e in engine.events {
                recorder.events.append(e)
                printEvent(e)
            }
        }
        defer { printer.cancel() }

        var summary: [String] = []
        func step(_ s: String) {
            print("\(stamp()) === \(s)")
            summary.append(s)
        }

        do {
            try await engine.start(
                network: NetworkSettings(stunServer: nil, localPort: 0, keepAliveSeconds: 15,
                                         useICE: false, echoCancellation: false),
                codecPriorities: Engine.defaultCodecOrder)
            step("engine started (null audio), SIP UDP \(bind ?? "*"):\(await engine.localPort(of: .udp))")

            let account = AccountConfig(displayName: "selftest", username: "selftest", domain: "127.0.0.1",
                                        enabled: false, isDefaultOutgoing: true)
            try await engine.addAccount(account, password: "unused")
            let reg = await engine.registrationState(of: account.id)
            guard reg == .unregistered else { throw Failure(description: "disabled account state is \(reg)") }
            step("disabled account sip:selftest@127.0.0.1 added (\(describe(reg)))")

            guard let dial = DialString.parse(options.target, account: account) else {
                throw Failure(description: "cannot parse target \(options.target)")
            }
            let id = try await engine.makeCall(to: dial, from: account.id)
            step("calling \(dial.uri) as \(id)")

            let connected = try await waitFor(engine, id, "connected with active media", timeout: 10) {
                $0.state == .connected && $0.codec != nil
            }
            step("connected: codec \(connected.codec ?? "-"), SRTP \(connected.isSecure ? "on" : "off")")

            guard recorder.events.contains(where: {
                if case let .callChanged(c) = $0 { return c.id == id && c.codec != nil }
                return false
            }) else { throw Failure(description: "no callChanged event carried the codec") }

            // Audio must flow both ways before hold, otherwise the hold check proves nothing.
            try await Task.sleep(for: .seconds(1))
            let before = try await engine.mediaStats(id)
            guard before.rxPackets > 0, before.txPackets > 0 else {
                throw Failure(description: "no two-way RTP before hold: rx \(before.rxPackets), tx \(before.txPackets)")
            }
            step("RTP after 1 s: rx \(before.rxPackets) packets, tx \(before.txPackets) packets")

            // Hold for 2 s. The remote answers recvonly, so it stops sending: rx must stall.
            try await engine.setHold(id, true)
            _ = try await waitFor(engine, id, "held", timeout: 5) { $0.state == .held && $0.isOnHold }
            try await Task.sleep(for: .milliseconds(500))
            let rxHoldStart = try await engine.mediaStats(id).rxPackets
            try await Task.sleep(for: .seconds(2))
            let rxHoldEnd = try await engine.mediaStats(id).rxPackets
            let rxDuringHold = max(0, rxHoldEnd - rxHoldStart)
            guard rxDuringHold < 10 else {
                throw Failure(description: "remote kept sending during hold (\(rxDuringHold) packets in 2 s)")
            }
            step("hold: state held, \(rxDuringHold) RTP packets received during 2 s of hold")

            try await engine.setHold(id, false)
            let resumed = try await waitFor(engine, id, "resumed", timeout: 5) {
                $0.state == .connected && !$0.isOnHold && $0.codec != nil
            }
            step("unhold: state \(describe(resumed.state)), codec \(resumed.codec ?? "-")")

            try await engine.sendDTMF(id, "1#")
            step("DTMF \"1#\" sent")

            try await Task.sleep(for: .seconds(3))
            let stats = try await engine.mediaStats(id)
            guard stats.rxPackets > 0, stats.txPackets > 0 else {
                throw Failure(description: "no two-way RTP: rx \(stats.rxPackets), tx \(stats.txPackets)")
            }
            step("RTP after 3 s: rx \(stats.rxPackets) packets (lost \(stats.rxLost)), tx \(stats.txPackets) packets")

            try await engine.hangup(id)
            let ended = try await waitForEnd(recorder, id, timeout: 5)
            step("hung up: callEnded \(describe(ended.0.state)), duration \(String(format: "%.1f", ended.1)) s")

            await engine.stop()
            step("engine stopped")
        } catch {
            print("\(stamp()) SELFTEST FAILED: \(error)")
            await engine.stop()
            return 1
        }

        print("\n==== macrosip-cli selftest PASSED ====")
        for (i, s) in summary.enumerated() { print("  \(i + 1). \(s)") }
        return 0
    }

    /// Polls `engine.calls()` until `condition` holds for the call.
    static func waitFor(_ engine: Engine, _ id: CallID, _ what: String, timeout: Double,
                        _ condition: (CallInfo) -> Bool) async throws -> CallInfo {
        let deadline = Date().addingTimeInterval(timeout)
        var last: CallInfo?
        while Date() < deadline {
            if let c = await engine.calls().first(where: { $0.id == id }) {
                last = c
                if condition(c) { return c }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let state = last.map { describe($0) } ?? "call gone"
        throw Failure(description: "timeout after \(Int(timeout)) s waiting for \(what); last: \(state)")
    }

    static func waitForEnd(_ recorder: Recorder, _ id: CallID, timeout: Double) async throws -> (CallInfo, TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for e in recorder.events {
                if case let .callEnded(c, d) = e, c.id == id { return (c, d) }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure(description: "no callEnded event within \(Int(timeout)) s")
    }
}
