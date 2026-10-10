internal import CPJSUA
import Foundation

/// What plays while an incoming call rings.
public enum RingtoneSource: Equatable, Sendable {
    /// Generated with pjmedia_tonegen (used until a bundled WAV exists).
    case tone(Tone)
    /// A WAV file played in a loop with pjmedia_wav_player_port.
    case wavFile(URL)
}

public struct Tone: Equatable, Sendable {
    public var freq1: Int
    public var freq2: Int
    public var onMs: Int
    public var offMs: Int

    public init(freq1: Int, freq2: Int, onMs: Int, offMs: Int) {
        self.freq1 = freq1
        self.freq2 = freq2
        self.onMs = onMs
        self.offMs = offMs
    }

    /// Ringtone: 440+480 Hz, 2 s on / 4 s off.
    public static let ringtone = Tone(freq1: 440, freq2: 480, onMs: 2000, offMs: 4000)
    /// Ringback while the far end rings without early media: 425 Hz, 1 s on / 4 s off.
    public static let ringback = Tone(freq1: 425, freq2: 0, onMs: 1000, offMs: 4000)
}

/// One looping audio source played either into the conference bridge's speaker slot (0)
/// or straight to a separate sound device (ringtone device differs from the call output).
/// Engine-actor confined: create, use and stop only from the Engine.
final class TonePlayer {
    private var pool: UnsafeMutablePointer<pj_pool_t>?
    private var port: UnsafeMutablePointer<pjmedia_port>?
    private var slot: pjsua_conf_port_id = PJ.invalidID
    private var soundPort: OpaquePointer?

    init(name: String, source: RingtoneSource, deviceID: Int?) throws {
        guard let pool = pjsua_pool_create(name, 1000, 1000) else {
            throw EngineError.pjsip(status: -1, message: "\(name): cannot create pool")
        }
        self.pool = pool
        do {
            var port: UnsafeMutablePointer<pjmedia_port>?
            switch source {
            case let .tone(t):
                try PJ.check(cpjsua_tonegen_create(pool, UInt32(t.freq1), UInt32(t.freq2),
                                                   UInt32(t.onMs), UInt32(t.offMs), &port),
                             "\(name): tone generator")
            case let .wavFile(url):
                try PJ.check(url.path.withCString { cpjsua_wav_loop_create(pool, $0, &port) },
                             "\(name): WAV player \(url.lastPathComponent)")
            }
            guard let port else { throw EngineError.pjsip(status: -1, message: "\(name): no port") }
            self.port = port

            if let deviceID {
                var snd: OpaquePointer?
                try PJ.check(cpjsua_snd_port_play(pool, Int32(deviceID), port, &snd),
                             "\(name): open sound device \(deviceID)")
                soundPort = snd
            } else {
                var slot: pjsua_conf_port_id = PJ.invalidID
                try PJ.check(pjsua_conf_add_port(pool, port, &slot), "\(name): add to conference")
                self.slot = slot
                try PJ.check(pjsua_conf_connect(slot, 0), "\(name): connect to speaker")
            }
        } catch {
            stop()
            throw error
        }
    }

    /// Releases everything; safe to call twice. Same order as pjsua_player_destroy.
    func stop() {
        guard pool != nil else { return }
        PJ.registerThread()
        if let soundPort {
            cpjsua_snd_port_close(soundPort)
            self.soundPort = nil
        }
        if slot != PJ.invalidID {
            PJ.warn(pjsua_conf_remove_port(slot), "remove tone port")
            slot = PJ.invalidID
        }
        if let port {
            PJ.warn(pjmedia_port_destroy(port), "destroy tone port")
            self.port = nil
        }
        if let pool {
            pj_pool_release(pool)
            self.pool = nil
        }
    }

    deinit { stop() }
}
