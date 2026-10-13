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

/// Chooses the echo canceller for a device selection (pure; tested).
enum AudioProcessingPolicy {
    /// VoiceProcessingIO when echo cancellation is on and both the input and the output are
    /// the system default (not selected, selected but absent, or selected and equal to the
    /// current default); otherwise the software canceller on the effective devices.
    static func mode(echoCancellation: Bool, inputName: String?, outputName: String?, devices: [AudioDevice],
                     defaultInput: String?, defaultOutput: String?) -> AudioProcessingMode {
        guard echoCancellation else { return .echoCancellationOff }
        func pick(_ name: String?, _ def: String?, input: Bool) -> (isDefault: Bool, name: String) {
            let selected = AudioDeviceResolver.index(of: name, in: devices, input: input)
            let defaultIndex = AudioDeviceResolver.index(of: def, in: devices, input: input)
            let isDefault = selected == nil || selected == defaultIndex
            let effective = isDefault ? (def ?? "System default") : (name ?? "")
            return (isDefault, effective)
        }
        let i = pick(inputName, defaultInput, input: true)
        let o = pick(outputName, defaultOutput, input: false)
        if i.isDefault && o.isDefault { return .systemVoiceProcessing }
        return .softwareEchoCanceller(input: i.name, output: o.name)
    }

    static func describe(_ mode: AudioProcessingMode) -> String {
        switch mode {
        case .systemVoiceProcessing: return "VoiceProcessingIO"
        case let .softwareEchoCanceller(input, output): return "software echo canceller on \(input) / \(output)"
        case .echoCancellationOff: return "echo cancellation off"
        }
    }
}

// MARK: - Ringtone and ringback

extension Engine {
    /// Ringtone while an incoming call rings; ringback while an outgoing call got 180/182
    /// without early media. With `IncomingWhileOnCall.callWaiting`, an incoming call that rings
    /// while another call is connected (not on local hold) gets the call-waiting tone in the
    /// speaker instead of the ringtone. Idempotent; runs after every call state change.
    func reconcileTones() {
        guard isStarted, PJ.registerThread() else { return }
        var ringingCalls: Set<CallID> = []
        var ringbackNeeded = false
        var talking = false
        for slot in CallSnapshot.allSlots() {
            guard let s = CallSnapshot.read(slot) else { continue }
            if !s.isOutgoing && (s.state == .incoming || s.state == .early) {
                ringingCalls.insert(CallID(raw: slot, serial: bridge.record(slot)?.serial ?? s.serial))
            }
            if s.isOutgoing && s.state == .early && (s.lastStatus == 180 || s.lastStatus == 182)
                && s.mediaStatus != .active {
                ringbackNeeded = true
            }
            if s.state == .confirmed && s.mediaStatus != .localHold && bridge.record(slot)?.localHold != true {
                talking = true
            }
        }
        silencedCalls.formIntersection(ringingCalls)
        let audible = !ringingCalls.isSubset(of: silencedCalls)
        let waiting = audible && talking && callOptions.incomingWhileOnCall == .callWaiting
        audible && !waiting ? startRingtone() : stopRingtone()
        waiting ? startCallWaitingTone() : stopCallWaitingTone()
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
        stopCallWaitingTone()
    }

    private func startRingtone() {
        guard ringtone == nil else { return }
        ringtoneDevice = separateRingtoneDevice()
        do {
            ringtone = try TonePlayer(name: "ringtone", source: ringtoneSource,
                                      deviceID: ringtoneDevice, volume: ringtoneVolume)
        } catch {
            PJ.warn(error, "ringtone")
            // A missing/broken WAV or device must not leave the call silent.
            ringtone = try? TonePlayer(name: "ringtone", source: .tone(.ringtone), deviceID: nil,
                                       volume: ringtoneVolume)
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
    func separateRingtoneDevice() -> Int? {
        guard !nullAudio,
              let dev = AudioDeviceResolver.index(of: ringtoneDeviceName, in: audioDevices(), input: false)
        else { return nil }
        if let playback = appliedSoundDevices?.playback, playback >= 0, Int(playback) == dev { return nil }
        return dev
    }

    func restartRingtoneIfPlaying() {
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
        let mode = AudioProcessingPolicy.mode(
            echoCancellation: network.echoCancellation, inputName: inputDeviceName, outputName: outputDeviceName,
            devices: devices,
            defaultInput: defaultDeviceNamesOverride.map(\.input) ?? SystemAudioDefaults.deviceName(input: true),
            defaultOutput: defaultDeviceNamesOverride.map(\.output) ?? SystemAudioDefaults.deviceName(input: false))
        if mode != processingMode || !processingModeAnnounced {
            processingMode = mode
            processingModeAnnounced = true
            emit(.log(level: 3, "engine: audio: \(AudioProcessingPolicy.describe(mode))\(nullAudio ? " (null audio: not applied)" : "")"))
        }
        if nullAudio { return }

        // Echo canceller kind first: switching between VoiceProcessingIO and the software
        // canceller needs the sound device to be opened again (mid-call too).
        if case .echoCancellationOff = mode {} else {
            let software = mode != .systemVoiceProcessing
            if appliedSoftwareEC != software {
                try switchEchoCanceller(software: software, capture: capture, playback: playback, throwing: throwing)
                return
            }
        }

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

    /// Sets pjsua's echo canceller options (`PJMEDIA_ECHO_USE_SW_ECHO` or not) and selects the
    /// devices. pjsua reads the options only when it opens the sound device, so an open
    /// device (a call in progress) is closed and opened again with the new options; an idle
    /// one opens with them on the next call. If the reopen fails, the bridge must not stay
    /// without a clock: the system default devices are opened instead, and if that fails too,
    /// the null sound device (calls keep running, silent). The applied state is cleared so the
    /// next device event (or `setAudioDevices`) tries the selection again; a level 1 `.log`
    /// line starting with "engine: audio error:" tells the UI.
    /// `forceOpen` and `open` exist for tests: null audio has no open sound port, and a test
    /// must not open a real device (pjmedia does not range-check device indices, so a made-up
    /// index can open a real device).
    func switchEchoCanceller(software: Bool, capture: Int32, playback: Int32, throwing: Bool,
                             forceOpen: Bool = false,
                             open: (Int32, Int32) -> pj_status_t = { cpjsua_open_snd_devs($0, $1) }) throws {
        let options = UInt32(PJMEDIA_ECHO_WEBRTC.rawValue) | (software ? UInt32(PJMEDIA_ECHO_USE_SW_ECHO.rawValue) : 0)
        // On the null device after an earlier failure, calls still need a real device now.
        let mustOpen = forceOpen || pjsua_snd_is_active() != 0
            || (soundOnNullFallback && cpjsua_active_call_count() > 0)
        if mustOpen { _ = pjsua_set_no_snd_dev() }
        PJ.warn(pjsua_set_ec(Engine.echoTailMs, options), "echo canceller options")   // no open port: config only
        let status = mustOpen ? open(capture, playback) : cpjsua_set_snd_devs(capture, playback)
        if status == PJ.success {
            appliedSoftwareEC = software
            appliedSoundDevices = (capture, playback)
            soundOnNullFallback = false
            if mustOpen {
                emit(.log(level: 4, "engine: sound device reopened for \(software ? "the software echo canceller" : "VoiceProcessingIO")"))
            }
            return
        }
        // Retry the selection on the next device event.
        appliedSoftwareEC = nil
        appliedSoundDevices = nil
        let what = AudioProcessingPolicy.describe(processingMode)
        if mustOpen {
            let defaults = open(PJMEDIA_AUD_DEFAULT_CAPTURE_DEV, PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV)
            if defaults == PJ.success {
                soundOnNullFallback = false
                emit(.log(level: 1, "engine: audio error: cannot open the sound device for \(what) "
                          + "(\(PJ.errorText(status))); using the system default devices until the next device change"))
            } else {
                PJ.warn(pjsua_set_null_snd_dev(), "null sound device after reopen failure")
                soundOnNullFallback = true
                emit(.log(level: 1, "engine: audio error: cannot open the sound device for \(what) "
                          + "(\(PJ.errorText(status))) nor the system default devices (\(PJ.errorText(defaults))); "
                          + "calls are silent until the next device change"))
            }
        } else {
            emit(.log(level: 1, "engine: audio error: cannot select the sound device for \(what) (\(PJ.errorText(status)))"))
        }
        if throwing { throw PJ.error(status, "open audio devices") }
    }

    /// The audio processing calls use with the current device selection: VoiceProcessingIO
    /// on the system default devices, or the WebRTC echo canceller on selected devices.
    /// Re-evaluated on every device selection, device-list and default-device change; with
    /// `nullAudio` it reports the selection but nothing is applied.
    public func audioProcessingMode() -> AudioProcessingMode {
        processingMode
    }

    /// Tests: treat other device names as the system defaults and re-evaluate.
    func overrideDefaultDeviceNames(input: String?, output: String?) {
        defaultDeviceNamesOverride = (input, output)
        applySoundDevices()
    }

    /// Non-throwing variant for start-up and device changes.
    func applySoundDevices() {
        do { try applySoundDevices(throwing: false) } catch { PJ.warn(error, "select audio devices") }
    }

    /// A device came or went (often a virtual one from Zoom/Teams). Indices may have shifted,
    /// so the remembered names are resolved again, but the sound device is reopened only when
    /// the resolved input or output index actually changed: reopening mid-call is a dropout.
    /// CoreAudio reports device-list and default-device changes in bursts (a headset plug-in
    /// gives a list change and two default changes). Events are debounced: the work runs once,
    /// `deviceEventDebounce` after the last event, so the processing mode is resolved once and
    /// the sound device is reopened at most once.
    func audioDevicesEventArrived() {
        deviceEventGeneration &+= 1
        let generation = deviceEventGeneration
        Task { [weak self] in
            try? await Task.sleep(for: Engine.deviceEventDebounce)
            await self?.handleDebouncedDeviceEvent(generation)
        }
    }

    private func handleDebouncedDeviceEvent(_ generation: UInt64) {
        guard generation == deviceEventGeneration else { return }
        handleAudioDevicesChanged()
    }

    func handleAudioDevicesChanged() {
        guard isStarted, PJ.registerThread() else { return }
        PJ.warn(pjmedia_aud_dev_refresh(), "audio device refresh")
        applySoundDevices()                  // no-op while the resolved indices are the same
        if ringtone != nil, separateRingtoneDevice() != ringtoneDevice {
            restartRingtoneIfPlaying()
        }
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
        let list = entries.prefix(Int(count))
            .map { CodecInfo(id: PJ.string(tuple: $0.id), priority: UInt8(clamping: $0.priority)) }
        return CodecMapping.displayOrder(CodecMapping.unique(list))
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
