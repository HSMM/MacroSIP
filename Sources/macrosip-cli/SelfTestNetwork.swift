import Foundation
import MacroSIPCore

/// Self-test steps for network resilience (docs/ENGINE.md "Network resilience"): the
/// `.network` event after start and `Engine.simulateNetworkChange()` during a call (re-INVITE,
/// `isReconnecting` on and off, RTP afterwards) and with a registered account (re-REGISTER).
extension SelfTest {
    /// `.network` comes once after start with the first path evaluation.
    static func networkAtStart(_ recorder: Recorder, step: (String) -> Void) async throws {
        let state = try await waitForEvent(recorder, since: 0, "network", timeout: 3) { e -> NetworkState? in
            if case let .network(st) = e { return st }
            return nil
        }
        guard state == .online else { throw Failure(description: "network state after start: offline") }
        step("network: online (first path evaluation after start)")
    }

    /// A simulated network change during a connected call to pjsua: the engine re-INVITEs it
    /// (new media transport, Contact, Via), `isReconnecting` goes on and off again, and RTP
    /// from the phone flows afterwards.
    static func networkChangeDuringCall(_ engine: Engine, _ recorder: Recorder, _ id: CallID,
                                        step: (String) -> Void) async throws {
        let mark = recorder.events.count
        await engine.simulateNetworkChange()
        _ = try await waitForEvent(recorder, since: mark, "callChanged with isReconnecting", timeout: 3) { e -> Bool? in
            if case let .callChanged(c) = e, c.id == id, c.isReconnecting { return true }
            return nil
        }
        let settled = try await waitFor(engine, id, "media back after the network change", timeout: 10) {
            $0.state == .connected && !$0.isReconnecting && $0.codec != nil
        }
        let lines = recorder.events.dropFirst(mark).compactMap { e -> String? in
            if case let .log(_, text) = e { return text }
            return nil
        }
        guard lines.contains(where: { $0.contains("call \(id): re-INVITE after network change sent") }) else {
            throw Failure(description: "no re-INVITE after the simulated network change in the log")
        }
        guard lines.contains(where: { $0.contains("call \(id): media re-established after network change (200)") }) else {
            throw Failure(description: "the re-INVITE after the simulated network change was not answered 200")
        }
        try await Task.sleep(for: .milliseconds(500))
        let a = try await engine.mediaStats(id)
        try await Task.sleep(for: .seconds(1))
        let b = try await engine.mediaStats(id)
        guard b.rxPackets - a.rxPackets > 30, b.txPackets - a.txPackets > 30 else {
            throw Failure(description: "RTP after the network change: rx +\(b.rxPackets - a.rxPackets), "
                          + "tx +\(b.txPackets - a.txPackets) in 1 s")
        }
        step("network change during the call: isReconnecting on/off, re-INVITE answered 200, codec \(settled.codec ?? "-"), "
             + "RTP afterwards rx +\(b.rxPackets - a.rxPackets) tx +\(b.txPackets - a.txPackets) in 1 s")
    }

    /// A simulated network change with a registered account: it REGISTERs again and stays
    /// registered.
    static func networkChangeReRegisters(_ engine: Engine, _ recorder: Recorder, stub: SIPStub,
                                         account: AccountConfig, step: (String) -> Void) async throws {
        let before = stub.stats.registers
        let mark = recorder.events.count
        await engine.simulateNetworkChange()
        let deadline = Date().addingTimeInterval(5)
        while stub.stats.registers <= before, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard stub.stats.registers > before else {
            throw Failure(description: "no REGISTER at the stub after the simulated network change")
        }
        try await Task.sleep(for: .milliseconds(300))
        let reg = await engine.registrationState(of: account.id)
        guard case .registered = reg else {
            throw Failure(description: "registration after the network change: \(describe(reg))")
        }
        let lost = recorder.events.dropFirst(mark).contains { e in
            if case let .registration(a, st) = e, a == account.id, st != reg { return true }
            return false
        }
        guard !lost else { throw Failure(description: "registration left 'registered' during the network change") }
        step("network change with registered \(account.uri): REGISTER at the stub (\(before) -> \(stub.stats.registers)), "
             + "stayed \(describe(reg))")
    }
}
