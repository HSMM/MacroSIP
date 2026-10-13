internal import CPJSUA
import Foundation

/// Tone sequences of the UI sounds (`Engine.playEventSound`) and of the audio test tone
/// (`Engine.playTestTone`). Every event sound is one to three beeps under 400 ms.
enum EventSounds {
    /// About -15 dBFS.
    static let volume: Int16 = 6000
    /// DTMF tone of a dial pad key.
    static let keyPressMs: UInt32 = 120

    static func tone(_ hz: Int16, on: Int16, off: Int16) -> pjmedia_tone_desc {
        pjmedia_tone_desc(freq1: hz, freq2: 0, on_msec: on, off_msec: off, volume: volume, flags: 0)
    }

    /// nil for `.keyPress` (a DTMF digit, played by the generator's digit map).
    static func sequence(for event: SoundEvent) -> [pjmedia_tone_desc]? {
        switch event {
        case .callConnected: return [tone(660, on: 80, off: 40), tone(880, on: 120, off: 0)]
        case .callEnded: return [tone(660, on: 80, off: 40), tone(440, on: 160, off: 0)]
        case .voicemail: return [tone(880, on: 70, off: 30), tone(880, on: 70, off: 30), tone(1175, on: 120, off: 0)]
        case .error: return [tone(330, on: 120, off: 60), tone(330, on: 120, off: 0)]
        case .keyPress: return nil
        }
    }

    /// Length of a sound in milliseconds.
    static func duration(of event: SoundEvent) -> Int {
        guard let seq = sequence(for: event) else { return Int(keyPressMs) }
        return seq.reduce(0) { $0 + Int($1.on_msec) + Int($1.off_msec) }
    }

    /// The audio test: two notes (660 and 880 Hz), repeated while the test runs.
    static func testTone() -> [pjmedia_tone_desc] {
        [tone(660, on: 250, off: 100), tone(880, on: 250, off: 450)]
    }

    static let digits = Set("0123456789*#ABCDabcd")
}

extension Engine {
    /// Plays a short UI sound on the call output (conference slot 0): never sent to a call,
    /// never recorded. Each call makes its own short-lived player, so sounds may overlap.
    /// `.keyPress(digit)` plays the DTMF tone pair of 0-9, *, #, A-D for 120 ms;
    /// another character throws `.invalidArgument`.
    public func playEventSound(_ event: SoundEvent) throws {
        try requireStarted()
        var digit: String?
        if case let .keyPress(d) = event {
            guard EventSounds.digits.contains(d) else { throw EngineError.invalidArgument("sound for key \"\(d)\"") }
            digit = String(d).lowercased()          // the generator's digit map is lower case
        }
        let player = try TonePlayer(name: "sound", deviceID: nil, sink: 0) { pool in
            var src: UnsafeMutablePointer<pjmedia_port>?
            try PJ.check(cpjsua_dtmf_generator_create(pool, &src), "sound generator")
            guard let src else { throw EngineError.pjsip(status: -1, message: "sound: no port") }
            return src
        }
        guard let source = player.source else {
            player.stop()
            throw EngineError.pjsip(status: -1, message: "sound: no generator")
        }
        do {
            if let digit {
                try PJ.check(digit.withCString { cpjsua_dtmf_generator_play(source, $0, EventSounds.keyPressMs, 0) }, "key sound")
            } else if let tones = EventSounds.sequence(for: event) {
                try tones.withUnsafeBufferPointer { buf in
                    try PJ.check(cpjsua_tone_sequence_play_once(source, buf.baseAddress, UInt32(buf.count)), "sound")
                }
            }
        } catch {
            player.stop()
            throw error
        }
        let token = nextEventSoundID
        nextEventSoundID += 1
        eventSounds[token] = player
        let ms = EventSounds.duration(of: event) + 150
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
            await self?.finishEventSound(token)
        }
    }

    private func finishEventSound(_ token: UInt64) {
        eventSounds.removeValue(forKey: token)?.stop()
    }

    func stopAllEventSounds() {
        for player in eventSounds.values { player.stop() }
        eventSounds = [:]
    }

    /// Plays a repeating two-note tone for `seconds` (0.2...30) on `outputDevice` (a name
    /// from `audioDevices()`) or, with nil, on the call output device. A running test tone
    /// is replaced. A device name that is not present throws `.invalidArgument`; with null
    /// audio the name is ignored. The named device is opened on its own, like a separate
    /// ringtone device, unless it is the call output device already.
    public func playTestTone(outputDevice: String?, seconds: Double) throws {
        try requireStarted()
        stopTestTone()
        var device: Int?
        if let name = outputDevice?.trimmingCharacters(in: .whitespaces), !name.isEmpty, !nullAudio {
            guard let index = AudioDeviceResolver.index(of: name, in: audioDevices(), input: false) else {
                throw EngineError.invalidArgument("no output audio device \"\(name)\"")
            }
            device = index
            if let playback = appliedSoundDevices?.playback, playback >= 0, Int(playback) == index { device = nil }
        }
        let tones = EventSounds.testTone()
        testTone = try TonePlayer(name: "test tone", deviceID: device, sink: 0) { pool in
            var src: UnsafeMutablePointer<pjmedia_port>?
            try tones.withUnsafeBufferPointer { buf in
                try PJ.check(cpjsua_tone_sequence_create(pool, buf.baseAddress, UInt32(buf.count), &src), "test tone")
            }
            guard let src else { throw EngineError.pjsip(status: -1, message: "test tone: no port") }
            return src
        }
        let duration = min(max(seconds.isFinite ? seconds : 1, 0.2), 30)
        let generation = testToneGeneration
        testToneTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await self?.testToneEnded(generation)
        }
    }

    /// Stops the test tone before its time is up (no-op without one).
    public func stopTestTone() {
        testToneGeneration &+= 1
        testToneTask?.cancel()
        testToneTask = nil
        testTone?.stop()
        testTone = nil
    }

    /// The timer of the tone started as `generation`; a replaced tone's timer leaves the current one alone.
    private func testToneEnded(_ generation: UInt64) {
        guard generation == testToneGeneration else { return }
        stopTestTone()
    }

    // MARK: test hooks

    /// The running test tone's bridge slot (nil on a separate device) and the level the bridge
    /// last received from it; nil without a test tone (tests).
    func testToneState() -> (slot: pjsua_conf_port_id?, level: Int)? {
        guard isStarted, PJ.registerThread(), let testTone else { return nil }
        guard testTone.slot != PJ.invalidID else { return (nil, 0) }
        var tx: UInt32 = 0, rx: UInt32 = 0
        guard pjsua_conf_get_signal_level(testTone.slot, &tx, &rx) == PJ.success else { return (testTone.slot, 0) }
        return (testTone.slot, Int(rx))
    }

    /// Event sounds still playing (tests).
    func eventSoundCount() -> Int { eventSounds.count }
}
