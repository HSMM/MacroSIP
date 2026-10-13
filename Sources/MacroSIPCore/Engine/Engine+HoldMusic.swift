internal import CPJSUA
import Foundation

/// The built-in hold music: a short two-voice arpeggio in C major (sixteen notes of 320 ms,
/// a 1.6 s rest, about 7.4 s per loop) from one looping tone generator. The upper voice plays
/// the melody, the lower one the root of the bar an octave below; both at a gentle level.
enum HoldMelody {
    static let noteMs: Int16 = 320
    static let gapMs: Int16 = 40
    static let restMs: Int16 = 1600
    /// Peak of each voice: about -16 dBFS (the generator halves the two voices).
    static let volume: Int16 = 5000

    /// (melody, bass) in Hz: C major, F major, G major, C major arpeggios.
    static let notes: [(Int16, Int16)] = [
        (523, 262), (659, 262), (784, 262), (659, 262),     // C5 E5 G5 E5 over C4
        (698, 349), (880, 349), (1047, 349), (880, 349),    // F5 A5 C6 A5 over F4
        (784, 392), (988, 392), (1175, 392), (988, 392),    // G5 B5 D6 B5 over G4
        (1047, 262), (784, 262), (659, 262), (523, 262),    // C6 G5 E5 C5 over C4
    ]

    static func sequence() -> [pjmedia_tone_desc] {
        notes.enumerated().map { i, n in
            pjmedia_tone_desc(freq1: n.0, freq2: n.1, on_msec: noteMs,
                              off_msec: i == notes.count - 1 ? restMs : gapMs, volume: volume, flags: 0)
        }
    }

    /// Total length of one loop in milliseconds.
    static var loopMs: Int {
        notes.count * Int(noteMs) + (notes.count - 1) * Int(gapMs) + Int(restMs)
    }
}

extension Engine {
    /// What the far end hears while a call is on local hold: the built-in melody (default), an
    /// audio file in a loop, or nothing. Stored like the other audio settings (works before
    /// `start`, kept across `stop`/`start`) and applied at once to calls already on hold.
    /// A `.file` WAV with 16-bit PCM samples is played as it is; any other file AVFoundation
    /// reads (M4A, MP3, AIFF, a float WAV) is converted once to a temporary 16 kHz mono WAV
    /// (`AudioFileToWAV`, off the engine queue). Throws `AudioFileToWAV.ConversionError` for
    /// a file that cannot be read; the previous source then stays in effect. A file that
    /// pjmedia refuses when a call is held falls back to the melody with a `.log` line.
    public func setHoldMusic(_ source: HoldMusic) async throws {
        holdMusicGeneration &+= 1
        let generation = holdMusicGeneration
        var wav: URL?
        var temp: URL?
        if case let .file(url) = source {
            if AudioFileToWAV.isPlayableWAV(url) {
                wav = url
            } else {
                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MacroSIP-hold-music-\(UUID().uuidString).wav")
                try await Task.detached(priority: .utility) { try AudioFileToWAV.convert(url, to: out) }.value
                wav = out
                temp = out
            }
        }
        guard generation == holdMusicGeneration else {      // a later call replaced this one
            if let temp { try? FileManager.default.removeItem(at: temp) }
            return
        }
        if let old = holdMusicTempWAV { try? FileManager.default.removeItem(at: old) }
        holdMusic = source
        holdMusicWAV = wav
        holdMusicTempWAV = temp
        // Calls already on hold switch to the new source.
        stopAllHoldMusic()
        reconcileHoldMusic()
    }

    /// Keeps one hold music player per call whose media is on local hold (the re-INVITE is
    /// answered and the stream sends only), connected to that call's conference port and to
    /// nothing else: the far end hears it, the speaker and the recordings do not. Players of
    /// calls that resumed or ended are destroyed; a call whose port was recreated (same slot
    /// number, connection gone) is connected again. Runs at the end of every `reconcileMedia`.
    func reconcileHoldMusic() {
        guard isStarted, PJ.registerThread() else { return }
        var wanted: [CallID: pjsua_conf_port_id] = [:]
        if holdMusic != .off {
            for slot in CallSnapshot.allSlots() {
                guard let snap = CallSnapshot.read(slot), snap.state == .confirmed, snap.mediaStatus == .localHold,
                      snap.confSlot != PJ.invalidID, let rec = bridge.record(slot), rec.serial == snap.serial
                else { continue }
                wanted[CallID(raw: slot, serial: rec.serial)] = snap.confSlot
            }
        }
        for (id, player) in holdMusicPlayers where wanted[id] != player.sink || player.source == nil {
            player.stop()
            holdMusicPlayers[id] = nil
        }
        for (id, port) in wanted {
            if let existing = holdMusicPlayers[id] {
                existing.ensureConnected()
                continue
            }
            do {
                holdMusicPlayers[id] = try makeHoldMusicPlayer(sink: port)
                emit(.log(level: 4, "engine: call \(id): hold music started (\(holdMusicDescription))"))
            } catch {
                PJ.warn(error, "hold music for \(id)")
            }
        }
    }

    private var holdMusicDescription: String {
        switch holdMusic {
        case .builtIn: return "built-in melody"
        case let .file(url): return url.lastPathComponent
        case .off: return "off"
        }
    }

    private func makeHoldMusicPlayer(sink: pjsua_conf_port_id) throws -> TonePlayer {
        if let wav = holdMusicWAV {
            do {
                return try TonePlayer(name: "hold music", deviceID: nil, sink: sink) { pool in
                    var src: UnsafeMutablePointer<pjmedia_port>?
                    try PJ.check(wav.path.withCString { cpjsua_wav_loop_create(pool, $0, &src) },
                                 "hold music file \(wav.lastPathComponent)")
                    guard let src else { throw EngineError.pjsip(status: -1, message: "hold music: no port") }
                    return src
                }
            } catch {
                PJ.warn(error, "hold music file; playing the built-in melody")
            }
        }
        let tones = HoldMelody.sequence()
        return try TonePlayer(name: "hold music", deviceID: nil, sink: sink) { pool in
            var src: UnsafeMutablePointer<pjmedia_port>?
            try tones.withUnsafeBufferPointer { buf in
                try PJ.check(cpjsua_tone_sequence_create(pool, buf.baseAddress, UInt32(buf.count), &src), "hold melody")
            }
            guard let src else { throw EngineError.pjsip(status: -1, message: "hold melody: no port") }
            return src
        }
    }

    func stopAllHoldMusic() {
        for player in holdMusicPlayers.values { player.stop() }
        holdMusicPlayers = [:]
    }

    // MARK: test hooks

    /// The call's hold music player: the slots it transmits to and the level (0...255) the
    /// bridge last received from it; nil while none plays (tests).
    func holdMusicState(of id: CallID) -> (sink: pjsua_conf_port_id, listeners: Int, toSpeaker: Bool, level: Int)? {
        guard isStarted, PJ.registerThread(), let player = holdMusicPlayers[id], player.slot != PJ.invalidID,
              let sink = player.sink else { return nil }
        var tx: UInt32 = 0, rx: UInt32 = 0
        guard pjsua_conf_get_signal_level(player.slot, &tx, &rx) == PJ.success else { return nil }
        return (sink, Int(cpjsua_conf_listener_count(player.slot)), cpjsua_conf_is_connected(player.slot, 0) != 0, Int(rx))
    }

    /// The temporary WAV a converted hold music file is played from (tests).
    func holdMusicTemporaryFile() -> URL? { holdMusicTempWAV }

    /// Calls with a hold music player (tests).
    func holdMusicPlayerCount() -> Int { holdMusicPlayers.count }
}
