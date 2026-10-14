import Foundation
import Testing
@testable import MacroSIPCore

// Release 26.1 call options (docs/ENGINE.md "Call options"): single-call mode (486),
// the call-waiting tone, the DTMF method.

/// Largest per-block amplitude of `frequency` in a 16-bit mono WAV (Goertzel over 40 ms blocks).
func wavToneAmplitude(_ url: URL, frequency: Double) throws -> Double {
    let data = try Data(contentsOf: url)
    guard data.count > 44 else { return 0 }
    let rate = Double(UInt32(data[24]) | UInt32(data[25]) << 8 | UInt32(data[26]) << 16 | UInt32(data[27]) << 24)
    var samples: [Double] = []
    samples.reserveCapacity((data.count - 44) / 2)
    var i = 44
    while i + 1 < data.count {
        samples.append(Double(Int16(bitPattern: UInt16(data[i]) | UInt16(data[i + 1]) << 8)))
        i += 2
    }
    let n = Int(rate * 0.04)
    let coeff = 2 * cos(2 * Double.pi * frequency / rate)
    var best = 0.0
    var start = 0
    while start + n <= samples.count {
        var s1 = 0.0, s2 = 0.0
        for k in start..<(start + n) {
            let s0 = samples[k] + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        best = max(best, 2 * power.squareRoot() / Double(n))
        start += n / 2
    }
    return best
}

extension EngineTests {
    struct Loopback {
        let engine: Engine
        let log: EventLog
        let account: AccountConfig
        let port: Int

        func incoming(after count: Int) -> CallInfo? {
            log.all.dropFirst(count).lazy.compactMap { if case let .incomingCall(c) = $0 { return c }; return nil }.first
        }

        func ended(_ pred: (CallInfo) -> Bool) -> CallInfo? {
            for e in log.all { if case let .callEnded(c, _) = e, pred(c) { return c } }
            return nil
        }

        func call(_ id: CallID) async -> CallInfo? { await engine.calls().first { $0.id == id } }

        func dial(_ user: String) async throws -> CallID {
            try await engine.makeCall(to: DialString(uri: "sip:\(user)@127.0.0.1:\(port)", display: user), from: account.id)
        }

        /// Dials ourselves and answers: (calling leg, answering leg), both connected with media.
        func connectedCall(_ user: String) async throws -> (CallID, CallID) {
            let before = log.all.count
            let out = try await dial(user)
            #expect(await waitUntil { incoming(after: before) != nil })
            let inc = try #require(incoming(after: before)).id
            try await engine.answer(inc)
            #expect(await waitUntil {
                let a = await call(out), b = await call(inc)
                return a?.state == .connected && a?.codec != nil && b?.state == .connected && b?.codec != nil
            })
            return (out, inc)
        }
    }

    func startLoopback(_ options: CallOptions) async throws -> (Loopback, Task<Void, Never>) {
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        try await engine.start(network: Self.network, callOptions: options)
        let account = AccountConfig(displayName: "L", username: "loop", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let port = await engine.localPort(of: .udp)
        return (Loopback(engine: engine, log: log, account: account, port: port), consumer)
    }

    /// Busy mode: an incoming call while another call is in progress (here: our own outgoing
    /// call being set up, then a connected call) is answered 486 at once; the UI sees only
    /// `.callEnded(... 486)` and a `.log` line, never `.incomingCall`.
    @Test func busyModeRejectsSecondIncomingCall() async throws {
        let (lb, consumer) = try await startLoopback(CallOptions(incomingWhileOnCall: .busy))
        defer { consumer.cancel() }
        let engine = lb.engine
        func busyEnd(after count: Int) -> CallInfo? {
            lb.log.all.dropFirst(count).lazy.compactMap { e -> CallInfo? in
                if case let .callEnded(c, _) = e, c.direction == .incoming,
                   c.state == .disconnected(code: 486, reason: "Busy Here") { return c }
                return nil
            }.first
        }
        func busyLogs() -> Int {
            lb.log.all.filter { if case let .log(_, t) = $0 { return t.contains("single-call mode") }; return false }.count
        }

        // 1. The loopback INVITE arrives while our own outgoing call is being set up.
        var before = lb.log.all.count
        let out0 = try await lb.dial("first")
        #expect(await waitUntil { busyEnd(after: before) != nil })
        #expect(await waitUntil { lb.ended { $0.id == out0 }?.state == .disconnected(code: 486, reason: "Busy Here") })
        #expect(lb.incoming(after: before) == nil)
        #expect(busyLogs() == 1)

        // 2. Window only: the call rings and is answered.
        await engine.setCallOptions(CallOptions(incomingWhileOnCall: .windowOnly))
        let (out1, inc1) = try await lb.connectedCall("second")

        // 3. Busy again (live): a call while one is connected gets 486.
        await engine.setCallOptions(CallOptions(incomingWhileOnCall: .busy))
        before = lb.log.all.count
        let out2 = try await lb.dial("third")
        #expect(await waitUntil { busyEnd(after: before) != nil })
        #expect(await waitUntil { lb.ended { $0.id == out2 }?.state == .disconnected(code: 486, reason: "Busy Here") })
        #expect(lb.incoming(after: before) == nil)
        #expect(busyLogs() == 2)
        let rejected = try #require(busyEnd(after: before))
        #expect(rejected.remote.number == "loop")
        // The first call is untouched.
        #expect(await lb.call(out1)?.state == .connected)
        #expect(await lb.call(inc1)?.state == .connected)

        try await engine.hangup(out1)
        #expect(await waitUntil { await engine.calls().isEmpty })
        await engine.stop()
    }

    /// Call waiting: while a second incoming call rings during a connected call, a short
    /// double beep plays on the speaker port (and nowhere else) instead of the ringtone; a
    /// recording of the first call stays silent. Window only keeps the ringtone; switching
    /// live swaps the two.
    @Test func callWaitingToneOnSpeakerOnly() async throws {
        let (lb, consumer) = try await startLoopback(CallOptions())      // .callWaiting is the default
        defer { consumer.cancel() }
        let engine = lb.engine
        await engine.setCallWaitingPeriod(ms: 1000)
        let (out1, inc1) = try await lb.connectedCall("first")
        #expect(await engine.callWaitingState() == nil)

        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("first.wav")
        try await engine.startRecording(out1, to: wav)

        var before = lb.log.all.count
        _ = try await lb.dial("second")
        #expect(await waitUntil { lb.incoming(after: before) != nil })
        let inc2 = try #require(lb.incoming(after: before)).id
        // The tone is created, then wired to the speaker: wait for the wiring, not just the player.
        #expect(await waitUntil { if let s = await engine.callWaitingState() { return s.toSpeaker && s.listeners == 1 } else { return false } })
        let state = try #require(await engine.callWaitingState())
        #expect(state.toSpeaker && state.listeners == 1, "\(state)")
        #expect(await waitUntil(timeout: 3) { (await engine.callWaitingState()?.level ?? 0) > 10 })
        #expect(await engine.ringtoneState() == nil)
        // Between the beeps the tone is silent (150 + 100 + 150 ms on, then quiet up to 1 s).
        #expect(await waitUntil(timeout: 3) { await engine.callWaitingState()?.level == 0 })
        try await Task.sleep(for: .milliseconds(1500))

        try await engine.reject(inc2)
        #expect(await waitUntil { await engine.callWaitingState() == nil })
        let files = try await engine.stopRecording(out1)
        let recorded = try #require(files.mixed)
        let rms = try wavRMS(recorded)
        let beep = try wavToneAmplitude(recorded, frequency: 440)
        #expect(rms < 50 && beep < 30, "RMS \(rms), 440 Hz amplitude \(beep)")

        // Window only: the ringtone as before, no call-waiting tone; a live switch swaps them.
        await engine.setCallOptions(CallOptions(incomingWhileOnCall: .windowOnly))
        before = lb.log.all.count
        _ = try await lb.dial("third")
        #expect(await waitUntil { lb.incoming(after: before) != nil })
        let inc3 = try #require(lb.incoming(after: before)).id
        #expect(await waitUntil { await engine.ringtoneState() != nil })
        #expect(await engine.callWaitingState() == nil)
        await engine.setCallOptions(CallOptions(incomingWhileOnCall: .callWaiting))
        #expect(await engine.callWaitingState() != nil)
        #expect(await engine.ringtoneState() == nil)
        // The first call on local hold (both loopback legs, each is "our" call): nobody is
        // talking, so the ringtone rings again.
        try await engine.setHold(out1, true)
        #expect(await waitUntil { await lb.call(out1)?.state == .held })
        try await engine.setHold(inc1, true)
        // inc1's hold may wait for out1's re-INVITE to finish (glare in loopback); give a loaded runner time.
        #expect(await waitUntil(timeout: 15) { await lb.call(inc1)?.state == .held })
        #expect(await waitUntil(timeout: 10) { await engine.ringtoneState() != nil })
        #expect(await engine.callWaitingState() == nil)
        try await engine.setHold(inc1, false)
        #expect(await waitUntil { await lb.call(inc1)?.state == .connected })
        try await engine.setHold(out1, false)
        #expect(await waitUntil { await engine.callWaitingState() != nil })
        #expect(await engine.ringtoneState() == nil)
        // Silencing the incoming call silences the call-waiting tone too.
        await engine.silenceRingtone()
        #expect(await engine.callWaitingState() == nil)
        #expect(await engine.ringtoneState() == nil)
        try await engine.reject(inc3)

        try await engine.hangup(out1)
        #expect(await waitUntil { await engine.calls().isEmpty })
        await engine.stop()
    }

    /// RFC 2833 and SIP INFO reach the other leg as `.dtmfReceived`; in-band DTMF reaches it as
    /// audio (697 + 1209 Hz for "1" in a recording of the far leg) and not as telephone-events.
    @Test func dtmfMethodsOnLoopback() async throws {
        let (lb, consumer) = try await startLoopback(CallOptions(dtmfMethod: .rfc2833))
        defer { consumer.cancel() }
        let engine = lb.engine
        let (out, inc) = try await lb.connectedCall("dtmf")
        func received() -> String {
            String(lb.log.all.compactMap { if case let .dtmfReceived(id, d) = $0, id == inc { return d }; return nil })
        }

        try await engine.sendDTMF(out, "5")
        #expect(await waitUntil { received() == "5" })
        await engine.setCallOptions(CallOptions(dtmfMethod: .sipINFO))
        try await engine.sendDTMF(out, "7")
        #expect(await waitUntil { received() == "57" })
        await engine.setCallOptions(CallOptions(dtmfMethod: .automatic))
        try await engine.sendDTMF(out, "9")
        #expect(await waitUntil { received() == "579" })

        // In-band: the far leg's recording carries the tones of "1" (697 + 1209 Hz).
        await engine.setCallOptions(CallOptions(dtmfMethod: .inband))
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("far.wav")
        try await engine.startRecording(inc, to: wav)
        try await Task.sleep(for: .milliseconds(200))
        try await engine.sendDTMF(out, "1111")
        #expect(await waitUntil {
            let gen = await engine.inbandGenerator(of: out)
            return gen?.connected == true && gen?.listeners == 1
        })
        try await Task.sleep(for: .milliseconds(1200))
        let files = try await engine.stopRecording(inc)
        let far = try #require(files.mixed)
        let low = try wavToneAmplitude(far, frequency: 697)
        let high = try wavToneAmplitude(far, frequency: 1209)
        let others = try [770.0, 852, 941, 1336, 1477].map { try wavToneAmplitude(far, frequency: $0) }.max() ?? 0
        #expect(low > 300 && high > 300, "697 Hz \(low), 1209 Hz \(high)")
        #expect(low > 5 * others && high > 5 * others, "697 Hz \(low), 1209 Hz \(high), other DTMF tones \(others)")
        #expect(received() == "579", "in-band digits must not arrive as telephone-events")

        try await engine.hangup(out)
        #expect(await waitUntil { await engine.calls().isEmpty })
        #expect(await engine.inbandGenerator(of: out) == nil)
        await engine.stop()
    }

    /// Against a callee without telephone-event: automatic and SIP INFO send INFO, RFC 2833
    /// only fails with `.unsupported`, in-band sends no INFO.
    @Test func dtmfMethodsAgainstCalleeWithoutTelephoneEvent() async throws {
        let stub = try NetworkStub()
        defer { stub.stop() }
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = AccountConfig(displayName: "S", username: "dtmf", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let id = try await engine.makeCall(to: DialString(uri: "sip:stub@127.0.0.1:\(stub.port)", display: "stub"),
                                           from: account.id)
        #expect(await waitUntil {
            let c = await engine.calls().first { $0.id == id }
            return c?.state == .connected && c?.codec != nil
        })
        func infos() -> [String] { stub.snapshot.infos }

        try await engine.sendDTMF(id, "5")                       // automatic (the default)
        #expect(await waitUntil { infos().count == 1 })
        #expect(infos().first?.contains("Signal=5") == true)

        await engine.setCallOptions(CallOptions(dtmfMethod: .rfc2833))
        await #expect(throws: EngineError.unsupported("RFC 2833 DTMF: the remote did not offer telephone-event")) {
            try await engine.sendDTMF(id, "6")
        }

        await engine.setCallOptions(CallOptions(dtmfMethod: .sipINFO))
        try await engine.sendDTMF(id, "#")
        #expect(await waitUntil { infos().count == 2 })
        #expect(infos().last?.contains("Signal=#") == true)

        await engine.setCallOptions(CallOptions(dtmfMethod: .inband))
        try await engine.sendDTMF(id, "1")
        #expect(await waitUntil { await engine.inbandGenerator(of: id)?.connected == true })
        try await Task.sleep(for: .milliseconds(300))
        #expect(infos().count == 2)

        try await engine.hangup(id)
        #expect(await waitUntil { await engine.calls().isEmpty })
        await engine.stop()
    }

    /// Do Not Disturb: every incoming INVITE gets 486 before any 180 or tone, live on and off;
    /// calls in progress are not affected.
    @Test func doNotDisturbRejectsIncomingCalls() async throws {
        let (lb, consumer) = try await startLoopback(CallOptions(doNotDisturb: true))
        defer { consumer.cancel() }
        let engine = lb.engine
        func busyEnd(after count: Int) -> CallInfo? {
            lb.log.all.dropFirst(count).lazy.compactMap { e -> CallInfo? in
                if case let .callEnded(c, _) = e, c.direction == .incoming,
                   c.state == .disconnected(code: 486, reason: "Busy Here") { return c }
                return nil
            }.first
        }
        func dndLogs() -> Int {
            lb.log.all.filter { if case let .log(_, t) = $0 { return t.contains("(do not disturb)") }; return false }.count
        }
        func ringing(after count: Int) -> Bool {
            lb.log.all.dropFirst(count).contains { e in
                if case let .callChanged(c) = e, c.direction == .outgoing, c.state == .early { return true }
                return false
            }
        }

        // No call: rejected at once, no 180 reached the caller, nothing rang.
        var before = lb.log.all.count
        let out0 = try await lb.dial("first")
        #expect(await waitUntil { busyEnd(after: before) != nil })
        #expect(await waitUntil { lb.ended { $0.id == out0 }?.state == .disconnected(code: 486, reason: "Busy Here") })
        #expect(lb.incoming(after: before) == nil)
        #expect(!ringing(after: before))
        #expect(await engine.ringtoneState() == nil)
        #expect(dndLogs() == 1)

        // Off (live): calls ring again.
        await engine.setCallOptions(CallOptions(doNotDisturb: false))
        let (out1, inc1) = try await lb.connectedCall("second")

        // On during a call: the call stays, a new one is rejected without a call-waiting tone.
        await engine.setCallWaitingPeriod(ms: 1000)
        await engine.setCallOptions(CallOptions(doNotDisturb: true))
        before = lb.log.all.count
        let out2 = try await lb.dial("third")
        #expect(await waitUntil { busyEnd(after: before) != nil })
        #expect(await waitUntil { lb.ended { $0.id == out2 } != nil })
        #expect(lb.incoming(after: before) == nil)
        #expect(await engine.callWaitingState() == nil)
        #expect(dndLogs() == 2)
        #expect(await lb.call(out1)?.state == .connected)
        #expect(await lb.call(inc1)?.state == .connected)

        try await engine.hangup(out1)
        #expect(await waitUntil { await engine.calls().isEmpty })
        await engine.stop()
    }

    /// In-band DTMF keeps reaching the far leg after hold/resume (the call's port may be made
    /// again, possibly with the same slot number) and after the generator's connection to the
    /// call was dropped; quick successive digits leave a single connection.
    @Test func inbandDTMFAfterHoldResumeAndLostConnection() async throws {
        let (lb, consumer) = try await startLoopback(CallOptions(dtmfMethod: .inband))
        defer { consumer.cancel() }
        let engine = lb.engine
        let (out, inc) = try await lb.connectedCall("inband")
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        /// Records the far leg while "1111" is sent: the 697 + 1209 Hz amplitudes and the
        /// largest amplitude of the other DTMF frequencies.
        func farTones(_ name: String) async throws -> (Double, Double, Double) {
            let wav = dir.appendingPathComponent(name)
            try await engine.startRecording(inc, to: wav)
            try await Task.sleep(for: .milliseconds(200))
            try await engine.sendDTMF(out, "1111")
            try await Task.sleep(for: .milliseconds(1000))
            let far = try #require(try await engine.stopRecording(inc).mixed)
            let others = try [770.0, 852, 941, 1336, 1477].map { try wavToneAmplitude(far, frequency: $0) }.max() ?? 0
            return (try wavToneAmplitude(far, frequency: 697), try wavToneAmplitude(far, frequency: 1209), others)
        }
        func heard(_ t: (Double, Double, Double)) -> Bool {
            t.0 > 300 && t.1 > 300 && t.0 > 5 * t.2 && t.1 > 5 * t.2
        }
        func singlyConnected() async -> Bool {
            let g = await engine.inbandGenerator(of: out)
            return g?.connected == true && g?.listeners == 1
        }

        try await engine.sendDTMF(out, "1")
        try await engine.sendDTMF(out, "1")                      // before the connection shows
        #expect(await waitUntil { await singlyConnected() })
        try await Task.sleep(for: .milliseconds(200))
        #expect(await singlyConnected())

        try await engine.setHold(out, true)
        #expect(await waitUntil { await lb.call(out)?.state == .held })
        try await engine.setHold(out, false)
        #expect(await waitUntil {
            let c = await lb.call(out)
            return c?.state == .connected && c?.codec != nil
        })
        try await Task.sleep(for: .milliseconds(300))
        let afterResume = try await farTones("resume.wav")
        #expect(heard(afterResume), "after hold/resume: \(afterResume)")
        #expect(await singlyConnected())

        await engine.disconnectInbandGenerator(of: out)
        #expect(await waitUntil { await engine.inbandGenerator(of: out)?.connected == false })
        let afterDrop = try await farTones("dropped.wav")
        #expect(heard(afterDrop), "after the connection was dropped: \(afterDrop)")
        #expect(await singlyConnected())

        try await engine.hangup(out)
        #expect(await waitUntil { await engine.calls().isEmpty })
        await engine.stop()
    }

    @Test func callOptionsCoding() throws {
        let decoded = try JSONDecoder().decode(CallOptions.self, from: Data("{}".utf8))
        #expect(decoded == CallOptions(incomingWhileOnCall: .callWaiting, dtmfMethod: .automatic, doNotDisturb: false))
        let dnd = CallOptions(doNotDisturb: true)
        #expect(try JSONDecoder().decode(CallOptions.self, from: JSONEncoder().encode(dnd)) == dnd)
        let unknown = try JSONDecoder().decode(CallOptions.self,
                                               from: Data(#"{"incomingWhileOnCall":"later","dtmfMethod":"inband"}"#.utf8))
        #expect(unknown == CallOptions(incomingWhileOnCall: .callWaiting, dtmfMethod: .inband))
        let busy = CallOptions(incomingWhileOnCall: .busy, dtmfMethod: .sipINFO)
        #expect(try JSONDecoder().decode(CallOptions.self, from: JSONEncoder().encode(busy)) == busy)
        let tones = CallWaitingTone.sequence(periodMs: 10_000)
        #expect(tones.count == 2 && tones.allSatisfy { $0.freq1 == 440 && $0.on_msec == 150 && $0.volume == 3277 })
        #expect(tones.map { Int($0.on_msec) + Int($0.off_msec) }.reduce(0, +) == 10_000)
    }
}
