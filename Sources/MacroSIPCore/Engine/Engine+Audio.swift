internal import CPJSUA
import Foundation

/// Resolves remembered device names to the current PJSIP device indices.
enum AudioDeviceResolver {
    /// Index of the first device called `name` that can capture (`input`) or play.
    /// nil name or no match = nil (system default).
    static func index(of name: String?, in devices: [AudioDevice], input: Bool) -> Int? {
        guard let name, !name.isEmpty else { return nil }
        return devices.first { $0.name == name && (input ? $0.inputChannels > 0 : $0.outputChannels > 0) }?.id
    }

    static func name(of index: Int?, in devices: [AudioDevice], input: Bool) throws -> String? {
        guard let index else { return nil }
        guard let d = devices.first(where: { $0.id == index }),
              input ? d.inputChannels > 0 : d.outputChannels > 0 else {
            throw EngineError.invalidArgument("no \(input ? "input" : "output") audio device \(index)")
        }
        return d.name
    }
}

// MARK: - Ringtone and ringback

extension Engine {
    /// Ringtone while an incoming call rings; ringback while an outgoing call got 180/182
    /// without early media. Idempotent; runs after every call state change.
    func reconcileTones() {
        guard isStarted, PJ.registerThread() else { return }
        var ringingCalls: Set<CallID> = []
        var ringbackNeeded = false
        for slot in CallSnapshot.allSlots() {
            guard let s = CallSnapshot.read(slot) else { continue }
            if !s.isOutgoing && (s.state == .incoming || s.state == .early) {
                ringingCalls.insert(CallID(raw: slot, serial: bridge.record(slot)?.serial ?? s.serial))
            }
            if s.isOutgoing && s.state == .early && (s.lastStatus == 180 || s.lastStatus == 182)
                && s.mediaStatus != .active {
                ringbackNeeded = true
            }
        }
        silencedCalls.formIntersection(ringingCalls)
        ringingCalls.isSubset(of: silencedCalls) ? stopRingtone() : startRingtone()
        ringbackNeeded ? startRingback() : stopRingback()
    }

    /// Stops the ringtone; the calls keep ringing (180) until answered or rejected.
    /// A call that starts ringing later plays the ringtone again.
    public func silenceRingtone() {
        guard isStarted, PJ.registerThread() else { return }
        for slot in CallSnapshot.allSlots() {
            guard let s = CallSnapshot.read(slot), !s.isOutgoing,
                  s.state == .incoming || s.state == .early else { continue }
            silencedCalls.insert(CallID(raw: slot, serial: bridge.record(slot)?.serial ?? s.serial))
        }
        stopRingtone()
    }

    private func startRingtone() {
        guard ringtone == nil else { return }
        do {
            ringtone = try TonePlayer(name: "ringtone", source: ringtoneSource,
                                      deviceID: separateRingtoneDevice())
        } catch {
            PJ.warn(error, "ringtone")
            // A missing/broken WAV or device must not leave the call silent.
            ringtone = try? TonePlayer(name: "ringtone", source: .tone(.ringtone), deviceID: nil)
        }
    }

    func stopRingtone() {
        ringtone?.stop()
        ringtone = nil
    }

    private func startRingback() {
        guard ringback == nil else { return }
        do {
            ringback = try TonePlayer(name: "ringback", source: .tone(.ringback), deviceID: nil)
        } catch {
            PJ.warn(error, "ringback")
        }
    }

    func stopRingback() {
        ringback?.stop()
        ringback = nil
    }

    /// The ringtone device when it differs from the call output, else nil (conference bridge).
    private func separateRingtoneDevice() -> Int? {
        guard !nullAudio,
              let dev = AudioDeviceResolver.index(of: ringtoneDeviceName, in: audioDevices(), input: false)
        else { return nil }
        if let playback = appliedSoundDevices?.playback, playback >= 0, Int(playback) == dev { return nil }
        return dev
    }

    private func restartRingtoneIfPlaying() {
        guard ringtone != nil else { return }
        stopRingtone()
        reconcileTones()
    }
}

// MARK: - Audio devices

extension Engine {
    public func audioDevices() -> [AudioDevice] {
        guard isStarted, PJ.registerThread() else { return [] }
        var entries = [cpjsua_aud_dev_entry](repeating: cpjsua_aud_dev_entry(), count: 64)
        var count = UInt32(entries.count)
        let status = entries.withUnsafeMutableBufferPointer { p -> pj_status_t in
            guard let base = p.baseAddress else { return -1 }
            return cpjsua_aud_devs(base, &count)
        }
        guard status == PJ.success else {
            PJ.warn(status, "enumerate audio devices")
            return []
        }
        return entries.prefix(Int(count)).map {
            AudioDevice(id: Int($0.id), name: PJ.string(tuple: $0.name),
                        inputChannels: Int($0.input_count), outputChannels: Int($0.output_count))
        }
    }

    /// By index from `audioDevices()`; nil = system default. The choice is remembered by
    /// name, so it survives device changes (see `setAudioDevices(inputName:outputName:)`).
    public func setAudioDevices(input: Int?, output: Int?) throws {
        try requireStarted()
        let devices = audioDevices()
        let inName = try AudioDeviceResolver.name(of: input, in: devices, input: true)
        let outName = try AudioDeviceResolver.name(of: output, in: devices, input: false)
        try setAudioDevices(inputName: inName, outputName: outName)
    }

    /// By device name (as stored in AppSettings); nil or an absent device = system default.
    /// Re-resolved after every device change. Devices open on demand (no immediate
    /// microphone access). With `nullAudio` the names are remembered but not applied.
    public func setAudioDevices(inputName: String?, outputName: String?) throws {
        try requireStarted()
        inputDeviceName = inputName
        outputDeviceName = outputName
        try applySoundDevices(throwing: true)
    }

    /// nil = ring on the call output device. Remembered by name.
    public func setRingtoneDevice(_ id: Int?) {
        guard isStarted, PJ.registerThread() else { return }
        do {
            setRingtoneDevice(name: try AudioDeviceResolver.name(of: id, in: audioDevices(), input: false))
        } catch {
            PJ.warn(error, "ringtone device")
        }
    }

    /// nil or an absent device = ring on the call output device.
    public func setRingtoneDevice(name: String?) {
        ringtoneDeviceName = name
        restartRingtoneIfPlaying()
    }

    /// nil = the generated tone. Hook for the bundled ringtone WAV.
    public func setRingtoneFile(_ url: URL?) {
        ringtoneSource = url.map { .wavFile($0) } ?? .tone(.ringtone)
        restartRingtoneIfPlaying()
    }

    /// Microphone level 0...1 as seen by the conference bridge (slot 0). The sound device
    /// opens on demand, so this is 0 unless a call (or tone) keeps the device open.
    public func inputLevel() -> Float {
        guard isStarted, PJ.registerThread() else { return 0 }
        var tx: UInt32 = 0
        var rx: UInt32 = 0
        guard pjsua_conf_get_signal_level(0, &tx, &rx) == PJ.success else { return 0 }
        return Float(min(rx, 255)) / 255
    }

    /// Resolves the remembered names to current indices and selects them in PJSIP when
    /// they changed. A remembered device that is gone falls back to the system default.
    func applySoundDevices(throwing: Bool = false) throws {
        guard isStarted, PJ.registerThread() else { return }
        let devices = audioDevices()
        let capture = AudioDeviceResolver.index(of: inputDeviceName, in: devices, input: true)
            .map(Int32.init) ?? PJMEDIA_AUD_DEFAULT_CAPTURE_DEV
        let playback = AudioDeviceResolver.index(of: outputDeviceName, in: devices, input: false)
            .map(Int32.init) ?? PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV
        for (name, input) in [(inputDeviceName, true), (outputDeviceName, false)] {
            if let name, AudioDeviceResolver.index(of: name, in: devices, input: input) == nil {
                PJ.warn(EngineError.invalidArgument("audio device \"\(name)\" not present"),
                        "using the system default \(input ? "input" : "output")")
            }
        }
        if nullAudio { return }
        if let applied = appliedSoundDevices, applied.capture == capture, applied.playback == playback { return }
        let status = cpjsua_set_snd_devs(capture, playback)
        if status == PJ.success {
            appliedSoundDevices = (capture, playback)
        } else if throwing {
            throw PJ.error(status, "select audio devices")
        } else {
            PJ.warn(status, "select audio devices")
        }
    }

    /// Non-throwing variant for start-up and device changes.
    func applySoundDevices() {
        do { try applySoundDevices(throwing: false) } catch { PJ.warn(error, "select audio devices") }
    }

    func handleAudioDevicesChanged() {
        guard isStarted, PJ.registerThread() else { return }
        PJ.warn(pjmedia_aud_dev_refresh(), "audio device refresh")
        // Indices may have shifted: re-resolve the remembered names.
        appliedSoundDevices = nil
        applySoundDevices()
        restartRingtoneIfPlaying()
        emit(.audioDevicesChanged)
    }
}

// MARK: - Codecs

extension Engine {
    /// All codecs, highest priority first. Priority 0 = disabled.
    public func codecs() -> [CodecInfo] {
        guard isStarted, PJ.registerThread() else { return [] }
        do {
            return try codecList()
        } catch {
            PJ.warn(error, "list codecs")
            return []
        }
    }

    /// Listed codecs get descending priorities (first = highest); unlisted codecs are
    /// disabled; unknown names are ignored. If no listed name is known, nothing changes.
    /// An empty list restores `defaultCodecOrder`.
    public func setCodecPriorities(_ ordered: [String]) throws {
        try requireStarted()
        try applyCodecPriorities(ordered)
    }

    func codecList() throws -> [CodecInfo] {
        var entries = [cpjsua_codec_entry](repeating: cpjsua_codec_entry(), count: 32)
        var count = UInt32(entries.count)
        let status = entries.withUnsafeMutableBufferPointer { p -> pj_status_t in
            guard let base = p.baseAddress else { return -1 }
            return cpjsua_codecs(base, &count)
        }
        try PJ.check(status, "pjsua_enum_codecs")
        return entries.prefix(Int(count))
            .map { CodecInfo(id: PJ.string(tuple: $0.id), priority: UInt8(clamping: $0.priority)) }
            .sorted { $0.priority > $1.priority }
    }

    func applyCodecPriorities(_ requested: [String]) throws {
        let ordered = requested.isEmpty ? Engine.defaultCodecOrder : requested
        let available = try codecList().map(\.id)
        let plan = CodecMapping.plan(requested: ordered, available: available)
        guard plan.contains(where: { $0.priority > 0 }) else {
            PJ.warn(EngineError.invalidArgument("codec list \(ordered) has no known codec"), "codec priorities unchanged")
            return
        }
        let arena = CStringArena()
        try withExtendedLifetime(arena) {
            for item in plan {
                var id = arena.pj(item.id)
                try PJ.check(pjsua_codec_set_priority(&id, item.priority), "codec priority \(item.id)")
            }
        }
    }
}
