internal import CPJSUA
import Foundation

/// What rings for an incoming call (`Engine.setRingtone`).
public enum RingtoneSource: Equatable, Sendable {
    /// One of the generated melodies (`BuiltInRingtone.tone`).
    case builtIn(BuiltInRingtone)
    /// A WAV the engine plays as it is (16-bit PCM, one or two channels, any rate:
    /// `AudioFileToWAV.isPlayableWAV`), in a loop. Other formats go through `RingtoneFile` first.
    case file(URL)

    /// The source of a built-in choice; nil for a file, which needs `RingtoneFile.prepare` first.
    public init?(_ choice: RingtoneChoice) {
        guard case let .builtIn(melody) = choice else { return nil }
        self = .builtIn(melody)
    }
}

/// A generated tone pattern played in a loop: up to `maxSteps` steps (the tone generator's queue),
/// each one or two frequencies for `onMs`, then `offMs` of silence.
public struct Tone: Hashable, Sendable {
    public struct Step: Hashable, Sendable {
        public var freq1: Int
        public var freq2: Int
        public var onMs: Int
        public var offMs: Int
        /// Peak amplitude; 0 = the generator's default (`Tone.defaultVolume`).
        public var volume: Int

        public init(freq1: Int, freq2: Int = 0, onMs: Int, offMs: Int, volume: Int = 0) {
            self.freq1 = freq1
            self.freq2 = freq2
            self.onMs = onMs
            self.offMs = offMs
            self.volume = volume
        }
    }

    public var steps: [Step]

    public init(steps: [Step]) { self.steps = steps }

    /// One step: a single cadence such as the classic ringtone or the ringback.
    public init(freq1: Int, freq2: Int, onMs: Int, offMs: Int) {
        self.init(steps: [Step(freq1: freq1, freq2: freq2, onMs: onMs, offMs: offMs)])
    }

    /// The generator's queue (`PJMEDIA_TONEGEN_MAX_DIGITS`).
    public static let maxSteps = 32
    /// What a step with volume 0 plays at (`PJMEDIA_TONEGEN_VOLUME`, about -8.5 dBFS).
    public static let defaultVolume = 12288

    /// Length of one loop in milliseconds.
    public var loopMs: Int { steps.reduce(0) { $0 + $1.onMs + $1.offMs } }
    /// From the start of a loop to the end of its last sound (the loop without its final pause).
    public var soundingMs: Int { loopMs - (steps.last?.offMs ?? 0) }

    /// Classic ringtone: 440+480 Hz, 2 s on / 4 s off (6 s loop).
    public static let ringtone = Tone(freq1: 440, freq2: 480, onMs: 2000, offMs: 4000)
    /// Digital ringtone: "beep-beep" twice on two high notes (1320 and 1760 Hz, about E6 and A6,
    /// 100 ms each), then 1.8 s of silence (2.5 s loop), at about -12 dBFS.
    public static let ringtoneDigital = Tone(steps: [
        Step(freq1: 1320, onMs: 100, offMs: 40, volume: 8000),
        Step(freq1: 1760, onMs: 100, offMs: 200, volume: 8000),
        Step(freq1: 1320, onMs: 100, offMs: 40, volume: 8000),
        Step(freq1: 1760, onMs: 100, offMs: 1820, volume: 8000),
    ])
    /// Soft ringtone: three low notes falling slowly (G4 392 Hz, E4 330 Hz, C4 262 Hz; 0.5,
    /// 0.5 and 0.9 s), then 3.3 s of silence (5.5 s loop), at about -15 dBFS.
    public static let ringtoneSoft = Tone(steps: [
        Step(freq1: 392, onMs: 500, offMs: 150, volume: 6000),
        Step(freq1: 330, onMs: 500, offMs: 150, volume: 6000),
        Step(freq1: 262, onMs: 900, offMs: 3300, volume: 6000),
    ])
    /// Ringback while the far end rings without early media: 425 Hz, 1 s on / 4 s off.
    public static let ringback = Tone(freq1: 425, freq2: 0, onMs: 1000, offMs: 4000)

    /// The steps as the tone generator takes them.
    var descriptors: [pjmedia_tone_desc] {
        steps.map {
            pjmedia_tone_desc(freq1: Int16(clamping: $0.freq1), freq2: Int16(clamping: $0.freq2),
                              on_msec: Int16(clamping: $0.onMs), off_msec: Int16(clamping: $0.offMs),
                              volume: Int16(clamping: $0.volume), flags: 0)
        }
    }
}

extension BuiltInRingtone {
    /// The pattern the engine generates for this melody.
    public var tone: Tone {
        switch self {
        case .classic: return .ringtone
        case .digital: return .ringtoneDigital
        case .soft: return .ringtoneSoft
        }
    }
}

extension RingtoneSource {
    /// What the ringtone player is made from.
    var playerSource: TonePlayer.Source {
        switch self {
        case let .builtIn(melody): return .tone(melody.tone)
        case let .file(url): return .wavFile(url)
        }
    }

    /// Played on the call output when the source or the separate device cannot be opened: the
    /// chosen melody, Classic for a file.
    var fallbackTone: Tone {
        if case let .builtIn(melody) = self { return melody.tone }
        return .ringtone
    }

    /// Length of a preview (`Engine.previewRingtone`): one ring of a melody and half a second
    /// after it; a file plays for `Engine.ringtonePreviewFileSeconds`.
    var previewSeconds: Double {
        switch self {
        case let .builtIn(melody): return Double(melody.tone.soundingMs + 500) / 1000
        case .file: return Engine.ringtonePreviewFileSeconds
        }
    }
}

/// One audio source played either into a conference bridge slot (by default 0, the speaker)
/// or straight to a separate sound device (ringtone device differs from the call output).
/// The source is wrapped in a gain port (`cpjsua_gain_port_create`), so its volume can change
/// while it plays on either path. Engine-actor confined: create, use and stop only from the Engine.
/// Used for the ringtone, ringback, the call-waiting tone (slot 0) and in-band DTMF (a call's slot).
final class TonePlayer {
    /// A generated pattern or a WAV file, looped.
    enum Source: Equatable {
        case tone(Tone)
        /// Played with `cpjsua_wav_loop_create` (16-bit PCM).
        case wavFile(URL)
    }


    /// Owned by `port` once the gain port exists (released when the bridge lets go of it).
    private var pool: UnsafeMutablePointer<pj_pool_t>?
    /// The gain port (owns the tone generator / WAV player).
    private var port: UnsafeMutablePointer<pjmedia_port>?
    /// The wrapped source (a tone generator or WAV player); owned by `port`, nil once stopped.
    private(set) var source: UnsafeMutablePointer<pjmedia_port>?
    private(set) var slot: pjsua_conf_port_id = PJ.invalidID
    /// The bridge slot the player transmits to (nil on a separate sound device).
    let sink: pjsua_conf_port_id?
    /// Every slot requested through `init` and `setSinks` (bridge path only).
    private var requestedSinks: Set<pjsua_conf_port_id> = []
    private var soundPort: OpaquePointer?

    convenience init(name: String, source: Source, deviceID: Int?, volume: Float = 1) throws {
        try self.init(name: name, deviceID: deviceID, volume: volume) { pool in
            var src: UnsafeMutablePointer<pjmedia_port>?
            switch source {
            case let .tone(t):
                let tones = t.descriptors
                try tones.withUnsafeBufferPointer { buf in
                    try PJ.check(cpjsua_tone_sequence_create(pool, buf.baseAddress, UInt32(buf.count), &src),
                                 "\(name): tone generator")
                }
            case let .wavFile(url):
                try PJ.check(url.path.withCString { cpjsua_wav_loop_create(pool, $0, &src) },
                             "\(name): WAV player \(url.lastPathComponent)")
            }
            guard let src else { throw EngineError.pjsip(status: -1, message: "\(name): no port") }
            return src
        }
    }

    /// `makeSource` creates the source port from the player's pool. `deviceID` set: played on
    /// that sound device; nil: added to the bridge and connected to `sink`.
    init(name: String, deviceID: Int?, volume: Float = 1, sink: pjsua_conf_port_id = 0,
         makeSource: (UnsafeMutablePointer<pj_pool_t>) throws -> UnsafeMutablePointer<pjmedia_port>) throws {
        self.sink = deviceID == nil ? sink : nil
        guard let pool = pjsua_pool_create(name, 1000, 1000) else {
            throw EngineError.pjsip(status: -1, message: "\(name): cannot create pool")
        }
        self.pool = pool
        do {
            let src = try makeSource(pool)
            var port: UnsafeMutablePointer<pjmedia_port>?
            let status = cpjsua_gain_port_create(pool, src, volume, &port)
            guard status == PJ.success, let port else {
                PJ.warn(pjmedia_port_destroy(src), "destroy \(name) source")
                throw status == PJ.success ? EngineError.pjsip(status: -1, message: "\(name): no gain port")
                                           : PJ.error(status, "\(name): gain port")
            }
            self.port = port
            self.source = src
            self.pool = nil                 // the gain port releases it in its on_destroy

            if let deviceID {
                var snd: OpaquePointer?
                try PJ.check(cpjsua_snd_port_play(pool, Int32(deviceID), port, &snd),
                             "\(name): open sound device \(deviceID)")
                soundPort = snd
            } else {
                var slot: pjsua_conf_port_id = PJ.invalidID
                try PJ.check(pjsua_conf_add_port(pool, port, &slot), "\(name): add to conference")
                self.slot = slot
                try PJ.check(pjsua_conf_connect(slot, sink), "\(name): connect to slot \(sink)")
                requestedSinks = [sink]
            }
        } catch {
            stop()
            throw error
        }
    }

    /// Connects the player to its sink slot again when that connection is gone (PJSIP drops a
    /// port's connections when the port is removed, and may give the same slot number to the
    /// port that replaces it). Connections are applied on the next audio frame, so call it only
    /// for a player that has been playing for a while. false when connecting failed.
    @discardableResult
    func ensureConnected() -> Bool {
        guard slot != PJ.invalidID, let sink else { return true }
        guard cpjsua_conf_is_connected(slot, sink) == 0 else { return true }
        let status = pjsua_conf_connect(slot, sink)
        PJ.warn(status, "reconnect tone port \(slot) -> \(sink)")
        return status == PJ.success
    }

    /// Makes the player transmit to exactly `desired` (several sinks: the recording notice
    /// goes to the call, the speaker and the recorders). Connections no longer wanted are
    /// disconnected; wanted ones are connected when they were never requested or when PJSIP
    /// does not list them any more (the port they led to was replaced). Bridge path only.
    func setSinks(_ desired: Set<pjsua_conf_port_id>) {
        guard slot != PJ.invalidID else { return }
        let applied = appliedSinks()
        for s in requestedSinks.union(applied) where !desired.contains(s) {
            PJ.warn(pjsua_conf_disconnect(slot, s), "disconnect tone port \(slot) -> \(s)")
        }
        for s in desired.sorted() where !requestedSinks.contains(s) || !applied.contains(s) {
            PJ.warn(pjsua_conf_connect(slot, s), "connect tone port \(slot) -> \(s)")
        }
        requestedSinks = desired
    }

    /// The slots PJSIP currently lists as listeners of the player (applied, not queued).
    func appliedSinks() -> Set<pjsua_conf_port_id> {
        guard slot != PJ.invalidID else { return [] }
        var ids = [pjsua_conf_port_id](repeating: PJ.invalidID, count: 64)
        let n = ids.withUnsafeMutableBufferPointer { p -> UInt32 in
            guard let base = p.baseAddress else { return 0 }
            return cpjsua_conf_listeners(slot, base, UInt32(p.count))
        }
        return Set(ids.prefix(Int(n)))
    }

    /// 0 = silent, 1 = as generated / recorded (values up to 2 amplify).
    func setVolume(_ volume: Float) {
        guard let port else { return }
        cpjsua_gain_port_set(port, volume)
    }

    /// Applied gain; nil once stopped (tests).
    var volume: Float? {
        port.map { cpjsua_gain_port_get($0) }
    }

    /// Releases everything; safe to call twice. The sound port is closed (synchronous) or the
    /// conference port removed first; the gain port then destroys the source and releases the
    /// pool when the bridge drops its last reference (PJSIP 2.17 removes ports on the next frame).
    func stop() {
        guard port != nil || pool != nil else { return }
        PJ.registerThread()
        if let soundPort {
            cpjsua_snd_port_close(soundPort)
            self.soundPort = nil
        }
        if slot != PJ.invalidID {
            PJ.warn(pjsua_conf_remove_port(slot), "remove tone port")
            slot = PJ.invalidID
        }
        source = nil
        if let port {
            // PJ_EGONE: ours was the last reference (the bridge had already dropped its own on
            // a frame between the remove and this call) and the port is gone now, as intended.
            let status = pjmedia_port_destroy(port)
            if status != PJ.gone { PJ.warn(status, "destroy tone port") }
            self.port = nil
        }
        if let pool {                       // only when the gain port was never created
            pj_pool_release(pool)
            self.pool = nil
        }
    }

    deinit { stop() }
}
