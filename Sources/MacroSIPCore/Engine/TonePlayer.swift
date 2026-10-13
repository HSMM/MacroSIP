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

/// One audio source played either into a conference bridge slot (by default 0, the speaker)
/// or straight to a separate sound device (ringtone device differs from the call output).
/// The source is wrapped in a gain port (`cpjsua_gain_port_create`), so its volume can change
/// while it plays on either path. Engine-actor confined: create, use and stop only from the Engine.
/// Used for the ringtone, ringback, the call-waiting tone (slot 0) and in-band DTMF (a call's slot).
final class TonePlayer {
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

    convenience init(name: String, source: RingtoneSource, deviceID: Int?, volume: Float = 1) throws {
        try self.init(name: name, deviceID: deviceID, volume: volume) { pool in
            var src: UnsafeMutablePointer<pjmedia_port>?
            switch source {
            case let .tone(t):
                try PJ.check(cpjsua_tonegen_create(pool, UInt32(t.freq1), UInt32(t.freq2),
                                                   UInt32(t.onMs), UInt32(t.offMs), &src),
                             "\(name): tone generator")
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
            PJ.warn(pjmedia_port_destroy(port), "destroy tone port")
            self.port = nil
        }
        if let pool {                       // only when the gain port was never created
            pj_pool_release(pool)
            self.pool = nil
        }
    }

    deinit { stop() }
}
