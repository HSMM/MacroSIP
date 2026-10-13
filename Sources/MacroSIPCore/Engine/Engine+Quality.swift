internal import CPJSUA
import Foundation

/// Speaker and microphone gain of one call (conference bridge levels, 1 = unity).
struct CallVolume: Equatable, Sendable {
    var speaker: Float = 1
    var microphone: Float = 1

    /// 0...2; NaN counts as 1.
    static func clamp(_ v: Float) -> Float {
        v.isNaN ? 1 : min(2, max(0, v))
    }
}

/// What `cpjsua_opus_get_options` reads back (tests, diagnostics).
struct OpusOptionsReadback: Equatable, Sendable {
    var packetLoss: Int
    var paramPacketLoss: Int
    var dtx: Bool
    var plc: Bool
    var fmtp: String
}

// MARK: - Call quality

extension Engine {
    /// Receive-side quality of the call's audio. Loss and jitter cover the window since the
    /// previous `quality(of:)` for this call (poll every ~2 s); the first call for a call (or
    /// after the stream was recreated by a re-INVITE) reports the all-time values. RTT is the
    /// latest RTCP measurement (0 until the first receiver report, ~5 s into the call).
    public func quality(of id: CallID) throws -> CallQuality {
        let slot = try liveSlot(id)
        var st = cpjsua_rtp_stat()
        try PJ.check(cpjsua_call_rtp_stat(slot, &st), "stream statistics")
        let sample = QualitySample(
            rxPackets: Int(st.rx_packets),
            rxLost: Int(st.rx_lost),
            jitterMeanMs: Double(st.rx_jitter_usec_mean) / 1000,
            jitterLastMs: Double(st.rx_jitter_usec_last) / 1000,
            rttMs: st.rtt_samples > 0 ? Double(st.rtt_usec_last) / 1000 : 0
        )
        pruneEndedCallState()
        let codec = CallSnapshot.read(slot)?.codec ?? bridge.record(slot)?.lastCodec
        let quality = CallQualityModel.quality(previous: qualitySamples[id], current: sample, codec: codec)
        qualitySamples[id] = sample
        return quality
    }

    /// Forgets per-call state (volumes, quality samples) of calls that ended.
    func pruneEndedCallState() {
        func live(_ id: CallID) -> Bool { bridge.record(id.raw)?.serial == id.serial }
        callVolumes = callVolumes.filter { live($0.key) }
        qualitySamples = qualitySamples.filter { live($0.key) }
        pruneDTMFGenerators(live: live)
    }
}

// MARK: - Call and ringtone volume

extension Engine {
    /// Per-call gain, 0...2 (1 = unity; values outside are clamped). `speaker` is the level of
    /// the call -> sound device connection (what we hear from the call), `microphone` the level
    /// of the sound device -> call connection (how loud our microphone reaches the call). Both
    /// are connection levels on the conference bridge (`pjsua_conf_connect2` /
    /// `pjmedia_conf_adjust_conn_level`, applied by `reconcileMedia`), so a recording of the call
    /// and the other legs of a conference are not affected. Remembered per call and applied
    /// again whenever the call's connections are made again (hold/resume, re-INVITE, merge,
    /// unmute).
    public func setCallVolume(_ id: CallID, speaker: Float, microphone: Float) throws {
        _ = try liveSlot(id)
        callVolumes[id] = CallVolume(speaker: CallVolume.clamp(speaker), microphone: CallVolume.clamp(microphone))
        reconcileMedia()
    }

    /// Gain a call starts with when the engine first wires it (0...2, clamped). Calls that
    /// already have media keep theirs.
    public func setDefaultCallVolume(speaker: Float, microphone: Float) {
        defaultCallVolume = CallVolume(speaker: CallVolume.clamp(speaker), microphone: CallVolume.clamp(microphone))
    }

    /// Ringtone loudness 0...1 (clamped), applied at once to a ringing ringtone and kept for
    /// later ones; works before `start` too. Both ringtone paths (conference bridge and a
    /// separate ringtone device) scale the samples in the player's gain port. Ringback is
    /// not affected.
    public func setRingtoneVolume(_ volume: Float) {
        ringtoneVolume = volume.isNaN ? 1 : min(1, max(0, volume))
        guard isStarted, PJ.registerThread() else { return }
        ringtone?.setVolume(ringtoneVolume)
    }

    /// Requested levels of a call's speaker and microphone connections (tests, diagnostics);
    /// nil while the call has no media connection to the sound device. The microphone is the
    /// remembered volume while muted (no connection then).
    func callLevels(of id: CallID) -> CallVolume? {
        guard isStarted, PJ.registerThread(), let snap = CallSnapshot.read(id.raw),
              snap.serial == id.serial, snap.confSlot != PJ.invalidID,
              let speaker = requestedLevels[Wire(src: snap.confSlot, sink: 0)] else { return nil }
        let microphone = requestedLevels[Wire(src: 0, sink: snap.confSlot)] ?? callVolumes[id]?.microphone ?? 1
        return CallVolume(speaker: speaker, microphone: microphone)
    }

    /// Signal level (0...255) the bridge last sent to the sound device (slot 0): the mix of
    /// everything the speaker plays, after the connection levels (tests).
    func speakerSignal() -> Int? {
        guard isStarted, PJ.registerThread() else { return nil }
        var tx: UInt32 = 0, rx: UInt32 = 0
        guard pjsua_conf_get_signal_level(0, &tx, &rx) == PJ.success else { return nil }
        return Int(tx)
    }

    /// Last signal levels (0...255) the bridge measured on a call's port: `rx` = received from
    /// the call, `tx` = mixed for the call (port levels; connection levels are not included
    /// in `rx`) (tests).
    func callSignal(of id: CallID) -> (tx: Int, rx: Int)? {
        guard isStarted, PJ.registerThread(), let snap = CallSnapshot.read(id.raw),
              snap.serial == id.serial, snap.confSlot != PJ.invalidID else { return nil }
        var tx: UInt32 = 0, rx: UInt32 = 0
        guard pjsua_conf_get_signal_level(snap.confSlot, &tx, &rx) == PJ.success else { return nil }
        return (Int(tx), Int(rx))
    }

    /// The ringing ringtone's gain and, on the conference path, the level the bridge last
    /// received from it (0...255); nil while no ringtone plays (tests).
    func ringtoneState() -> (volume: Float, level: Int?)? {
        guard isStarted, PJ.registerThread(), let ringtone, let volume = ringtone.volume else { return nil }
        guard ringtone.slot != PJ.invalidID else { return (volume, nil) }
        var tx: UInt32 = 0, rx: UInt32 = 0
        guard pjsua_conf_get_signal_level(ringtone.slot, &tx, &rx) == PJ.success else { return (volume, nil) }
        return (volume, Int(rx))
    }
}

// MARK: - Codec options

extension Engine {
    /// Opus FEC and DTX for streams created from now on: new calls, and existing calls only
    /// when a later re-INVITE recreates their stream (a call keeps the encoder it was opened
    /// with). FEC on = expected loss 10 % (libopus then adds in-band redundancy, if the remote's
    /// SDP has useinbandfec=1), off = 0 %. DTX = the codec parameter `setting.vad`, which is
    /// Opus-internal DTX (`OPUS_SET_DTX`) and `usedtx=1` in our SDP; PJSIP's own VAD stays off
    /// (`no_vad`). See docs/ENGINE.md "Codec options".
    public func setCodecOptions(_ options: CodecOptions) throws {
        try requireStarted()
        try PJ.check(cpjsua_opus_set_options(options.opusFEC ? 1 : 0, options.opusDTX ? 1 : 0), "Opus options")
        codecOptions = options
    }

    /// At start: a missing Opus codec only logs.
    func applyCodecOptionsAtStart() {
        PJ.warn(cpjsua_opus_set_options(codecOptions.opusFEC ? 1 : 0, codecOptions.opusDTX ? 1 : 0), "Opus options")
    }

    /// The Opus defaults as PJSIP has them now (tests, diagnostics).
    func opusOptions() -> OpusOptionsReadback? {
        guard isStarted, PJ.registerThread() else { return nil }
        var o = cpjsua_opus_options()
        guard cpjsua_opus_get_options(&o) == PJ.success else { return nil }
        return OpusOptionsReadback(packetLoss: Int(o.packet_loss), paramPacketLoss: Int(o.param_packet_loss),
                                   dtx: o.vad != 0, plc: o.plc != 0, fmtp: PJ.string(tuple: o.fmtp))
    }
}
