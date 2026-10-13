internal import CPJSUA
import Foundation

// Release 26.1 call options (docs/ENGINE.md "Call options"): what a second incoming call does
// (call-waiting tone, window only, busy) and how DTMF is sent.

/// The call-waiting tone: two 440 Hz beeps of 150 ms (100 ms apart) at -20 dBFS, repeated
/// every 10 s, into the speaker slot only.
enum CallWaitingTone {
    static let frequency: Int16 = 440
    static let beepMs: Int16 = 150
    static let gapMs: Int16 = 100
    static let periodMs = 10_000
    /// Peak amplitude for -20 dBFS: 32767 x 10^(-20/20).
    static let amplitude: Int16 = 3277

    /// One period: beep, gap, beep, then silence up to `periodMs`.
    static func sequence(periodMs: Int) -> [pjmedia_tone_desc] {
        let rest = Int16(clamping: max(periodMs - 2 * Int(beepMs) - Int(gapMs), 50))
        func beep(off: Int16) -> pjmedia_tone_desc {
            pjmedia_tone_desc(freq1: frequency, freq2: 0, on_msec: beepMs, off_msec: off,
                              volume: amplitude, flags: 0)
        }
        return [beep(off: gapMs), beep(off: rest)]
    }
}

extension CallOptions {
    /// `knownNumbers` as `knownNumberKey` gives them: what `on_incoming_call` looks up (once
    /// per change instead of once per call).
    func withNormalizedKnownNumbers() -> CallOptions {
        var o = self
        o.knownNumbers = Set(knownNumbers.map(CallOptions.knownNumberKey).filter { !$0.isEmpty })
        return o
    }
}

extension Engine {
    /// In-band DTMF digit timing.
    static let inbandDigitOnMs: UInt32 = 100
    static let inbandDigitOffMs: UInt32 = 50

    /// Applies at once: the next incoming call and the next `sendDTMF` use the new options, and
    /// a ringing call switches between ringtone and call-waiting tone. Allowed before `start`
    /// (`start` then sets the options it is given).
    public func setCallOptions(_ options: CallOptions) {
        callOptions = options
        bridge.setCallOptions(options.withNormalizedKnownNumbers())
        reconcileTones()
    }

    // MARK: call-waiting tone

    func startCallWaitingTone() {
        guard callWaitingTone == nil else { return }
        let tones = CallWaitingTone.sequence(periodMs: callWaitingPeriodMs)
        do {
            callWaitingTone = try TonePlayer(name: "call waiting", deviceID: nil, sink: 0) { pool in
                var src: UnsafeMutablePointer<pjmedia_port>?
                try tones.withUnsafeBufferPointer { buf in
                    try PJ.check(cpjsua_tone_sequence_create(pool, buf.baseAddress, UInt32(buf.count), &src),
                                 "call-waiting tone")
                }
                guard let src else { throw EngineError.pjsip(status: -1, message: "call-waiting tone: no port") }
                return src
            }
        } catch {
            PJ.warn(error, "call-waiting tone")
        }
    }

    func stopCallWaitingTone() {
        callWaitingTone?.stop()
        callWaitingTone = nil
    }

    // MARK: in-band DTMF

    /// Queues `digits` as DTMF tones on a generator that transmits to the call's conference
    /// port only (not the speaker, not recordings). One generator per call, kept while the
    /// call lives, made again when the call's port number changed and reconnected when its
    /// connection is gone (a stream restart may give the new port the same slot number).
    func sendInbandDTMF(_ id: CallID, slot: pjsua_call_id, _ digits: String) throws {
        guard let snap = CallSnapshot.read(slot), snap.confSlot != PJ.invalidID else {
            throw EngineError.unsupported("in-band DTMF: call \(id) has no audio")
        }
        if let old = dtmfGenerators[id], old.sink != snap.confSlot || old.source == nil {
            old.stop()
            dtmfGenerators[id] = nil
        }
        let generator: TonePlayer
        if let existing = dtmfGenerators[id] {
            generator = existing
            guard generator.ensureConnected() else {
                generator.stop()
                dtmfGenerators[id] = nil
                throw EngineError.unsupported("in-band DTMF: cannot connect to call \(id)")
            }
        } else {
            generator = try TonePlayer(name: "dtmf", deviceID: nil, sink: snap.confSlot) { pool in
                var src: UnsafeMutablePointer<pjmedia_port>?
                try PJ.check(cpjsua_dtmf_generator_create(pool, &src), "in-band DTMF generator")
                guard let src else { throw EngineError.pjsip(status: -1, message: "in-band DTMF: no port") }
                return src
            }
            dtmfGenerators[id] = generator
        }
        guard let source = generator.source else { throw EngineError.noSuchCall(id) }
        // The generator's digit map is lower case (a-d).
        try PJ.check(digits.lowercased().withCString {
            cpjsua_dtmf_generator_play(source, $0, Engine.inbandDigitOnMs, Engine.inbandDigitOffMs)
        }, "in-band DTMF")
    }

    /// Generators of calls that ended (from `pruneEndedCallState`).
    func pruneDTMFGenerators(live: (CallID) -> Bool) {
        for (id, generator) in dtmfGenerators where !live(id) {
            generator.stop()
            dtmfGenerators[id] = nil
        }
    }

    func stopAllDTMFGenerators() {
        for generator in dtmfGenerators.values { generator.stop() }
        dtmfGenerators = [:]
    }

    // MARK: test hooks

    /// The call-waiting tone's bridge state: level (0...255) the bridge last received from it,
    /// and the slots it transmits to; nil while it does not play (tests).
    func callWaitingState() -> (level: Int, slot: pjsua_conf_port_id, listeners: Int, toSpeaker: Bool)? {
        guard isStarted, PJ.registerThread(), let tone = callWaitingTone, tone.slot != PJ.invalidID else { return nil }
        var tx: UInt32 = 0, rx: UInt32 = 0
        guard pjsua_conf_get_signal_level(tone.slot, &tx, &rx) == PJ.success else { return nil }
        return (Int(rx), tone.slot, Int(cpjsua_conf_listener_count(tone.slot)),
                cpjsua_conf_is_connected(tone.slot, 0) != 0)
    }

    /// Tests: shorter repeat period of the call-waiting tone (ms; applies to the next tone).
    func setCallWaitingPeriod(ms: Int) {
        callWaitingPeriodMs = ms
    }

    /// Tests: drops the in-band generator's connection to its call, as the removal of the
    /// call's port during a stream restart does.
    func disconnectInbandGenerator(of id: CallID) {
        guard isStarted, PJ.registerThread(), let g = dtmfGenerators[id], g.slot != PJ.invalidID,
              let sink = g.sink else { return }
        PJ.warn(pjsua_conf_disconnect(g.slot, sink), "disconnect DTMF generator")
    }

    /// Tests: whether `id` has an in-band DTMF generator and whether it transmits to the call's port.
    func inbandGenerator(of id: CallID) -> (connected: Bool, listeners: Int)? {
        guard isStarted, PJ.registerThread(), let g = dtmfGenerators[id], g.slot != PJ.invalidID,
              let sink = g.sink else { return nil }
        return (cpjsua_conf_is_connected(g.slot, sink) != 0, Int(cpjsua_conf_listener_count(g.slot)))
    }
}
