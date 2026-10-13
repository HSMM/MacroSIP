import Foundation

/// RTP receive counters of one stream at one moment (from `pjsua_call_get_stream_stat`).
struct QualitySample: Equatable, Sendable {
    var rxPackets: Int
    var rxLost: Int
    var jitterMeanMs: Double
    var jitterLastMs: Double
    /// Latest RTT from RTCP, 0 = none yet.
    var rttMs: Double
}

/// The call quality estimate (docs/ENGINE.md, "Call quality"). Pure functions, tested.
///
/// MOS is a simplified ITU-T G.107 E-model:
/// - R starts from the codec's best-case MOS (Opus and G.722 4.4, G.711 4.1, others 4.1),
///   converted to R with the inverse of the G.107 MOS(R) curve.
/// - Delay impairment Id = 0.024 d + 0.11 (d - 177.3) H(d - 177.3) with the one-way delay
///   d = RTT/2 + 2 x jitter (jitter buffer) + 20 ms (packetisation).
/// - Loss impairment Ie,eff = (95 - Ie) Ppl / (Ppl + Bpl) (random loss, Ie = 0 relative to
///   the codec's base); Bpl = 25.1 for G.711 with PLC (G.113 Appendix I), 20 for Opus and
///   G.722 (no standard value; chosen conservatively), 10 for anything else.
/// - MOS = 1 + 0.035 R + 7e-6 R (R - 60)(100 - R), clamped to 1.0...4.5.
enum CallQualityModel {
    struct CodecProfile: Equatable {
        var baseMOS: Double
        var bpl: Double
    }

    static func profile(codec: String?) -> CodecProfile {
        let name = (codec ?? "").lowercased()
        if name.hasPrefix("opus") || name.hasPrefix("g722") { return CodecProfile(baseMOS: 4.4, bpl: 20) }
        if name.hasPrefix("pcmu") || name.hasPrefix("pcma") { return CodecProfile(baseMOS: 4.1, bpl: 25.1) }
        return CodecProfile(baseMOS: 4.1, bpl: 10)
    }

    /// G.107 R -> MOS.
    static func mos(r: Double) -> Double {
        if r <= 0 { return 1 }
        if r >= 100 { return 4.5 }
        return 1 + 0.035 * r + 7e-6 * r * (r - 60) * (100 - r)
    }

    /// MOS -> R by bisection (MOS(R) rises monotonically on 0...100).
    static func r(mos target: Double) -> Double {
        var lo = 0.0, hi = 100.0
        for _ in 0..<50 {
            let mid = (lo + hi) / 2
            if mos(r: mid) < target { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    static func mos(lossPercent: Double, jitterMs: Double, rttMs: Double, codec: String?) -> Double {
        let p = profile(codec: codec)
        let loss = min(100, max(0, lossPercent))
        let delay = max(0, rttMs) / 2 + 2 * max(0, jitterMs) + 20
        let id = 0.024 * delay + (delay > 177.3 ? 0.11 * (delay - 177.3) : 0)
        let ie = 95 * loss / (loss + p.bpl)
        let value = mos(r: r(mos: p.baseMOS) - id - ie)
        return min(4.5, max(1.0, value))
    }

    static func level(mos: Double) -> QualityLevel {
        mos >= 3.8 ? .good : mos >= 3.0 ? .fair : .poor
    }

    /// Loss and jitter of the window between `previous` and `current`. Without a previous
    /// sample (first call) or when the packet counter went back (the stream was recreated by a
    /// re-INVITE), the all-time values of `current` are used. pjmedia can lower `rxLost` when a
    /// late packet arrives after reordering; that only clamps the window's loss at 0. nil loss
    /// = no packet received or lost in the window (nothing to judge).
    static func window(previous: QualitySample?, current: QualitySample) -> (lossPercent: Double?, jitterMs: Double) {
        if let previous, current.rxPackets >= previous.rxPackets {
            let received = current.rxPackets - previous.rxPackets
            let lost = max(0, current.rxLost - previous.rxLost)
            let expected = received + lost
            return (expected > 0 ? 100 * Double(lost) / Double(expected) : nil, current.jitterLastMs)
        }
        let lost = max(0, current.rxLost)
        let expected = current.rxPackets + lost
        return (expected > 0 ? 100 * Double(lost) / Double(expected) : nil, current.jitterMeanMs)
    }

    /// A window without any packet (no audio arrives: remote stopped sending, network gone, or
    /// the call is held) is reported as poor (MOS 1, 100 % loss); the UI hides quality for held
    /// calls.
    static func quality(previous: QualitySample?, current: QualitySample, codec: String?) -> CallQuality {
        let w = window(previous: previous, current: current)
        guard let loss = w.lossPercent else {
            return CallQuality(lossPercent: 100, jitterMs: w.jitterMs, rttMs: current.rttMs, mos: 1, level: .poor)
        }
        let mos = mos(lossPercent: loss, jitterMs: w.jitterMs, rttMs: current.rttMs, codec: codec)
        return CallQuality(lossPercent: loss, jitterMs: w.jitterMs, rttMs: current.rttMs,
                           mos: mos, level: level(mos: mos))
    }
}
