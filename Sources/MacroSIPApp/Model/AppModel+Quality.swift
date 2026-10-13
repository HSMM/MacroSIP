import AppKit
import Foundation
import MacroSIPCore

// Call quality (SCREENS.md 4.1 "Quality" chip), call volume and following new audio devices.

// MARK: - Quality

/// The metric that makes a connection poor, with its value (loss in %, jitter and RTT in ms, MOS).
struct PoorReason: Equatable {
    enum Kind: Equatable { case loss, jitter, rtt, mos }
    var kind: Kind
    var value: Double

    /// The worst metric: each one is measured against the level where speech starts to suffer
    /// (5 % loss, 60 ms jitter, 400 ms round trip). When none of them is past it, the MOS score is named.
    init(_ q: CallQuality) {
        let scores: [(Kind, Double, Double)] = [
            (.loss, q.lossPercent, q.lossPercent / 5),
            (.jitter, q.jitterMs, q.jitterMs / 60),
            (.rtt, q.rttMs, q.rttMs / 400),
        ]
        if let worst = scores.max(by: { $0.2 < $1.2 }), worst.2 >= 1 {
            kind = worst.0; value = worst.1
        } else {
            kind = .mos; value = q.mos
        }
    }

    var text: String {
        switch kind {
        case .loss: return L.callPoorLoss(L.unitPercent(L.number(value)))
        case .jitter: return L.callPoorJitter(L.unitMs(L.number(value)))
        case .rtt: return L.callPoorRTT(L.unitMs(L.number(value)))
        case .mos: return L.callPoorMOS(L.number(value))
        }
    }
}

extension CallQuality {
    /// Bars lit in the signal icon: 4 good, 3 or 2 fair, 1 poor.
    var bars: Int {
        switch level {
        case .good: return 4
        case .fair: return mos >= 3.6 ? 3 : 2
        case .poor: return 1
        }
    }

    /// "Loss 0.5 % · Jitter 12 ms · RTT 48 ms · MOS 4.3"
    var detailsText: String {
        L.callQualityDetails(loss: L.unitPercent(L.number(lossPercent)), jitter: L.unitMs(L.number(jitterMs)),
                             rtt: rttMs > 0 ? L.unitMs(L.number(rttMs)) : "–", mos: L.number(mos))
    }

    var levelText: String {
        switch level {
        case .good: return L.callQualityGood
        case .fair: return L.callQualityFair
        case .poor: return L.callQualityPoor
        }
    }
}

/// Decides when the "Poor connection" banner shows: a call has to stay `.poor` for `poorDelay`
/// seconds. One good sample does not end a poor spell (nor hide the banner): it takes `cleanSamples`
/// non-poor samples in a row, so a connection that flickers does not make the banner flicker.
struct QualityMonitor {
    static let poorDelay: TimeInterval = 6
    static let cleanSamples = 2
    private var poorSince: [CallID: Date] = [:]
    private var cleanStreak: [CallID: Int] = [:]
    private var shown: [CallID: PoorReason] = [:]

    /// The reason to show a banner for, or nil.
    mutating func record(_ q: CallQuality, for id: CallID, at now: Date = Date()) -> PoorReason? {
        if q.level == .poor {
            cleanStreak[id] = nil
            let since = poorSince[id] ?? now
            poorSince[id] = since
            let reason = now.timeIntervalSince(since) >= Self.poorDelay ? PoorReason(q) : nil
            shown[id] = reason
            return reason
        }
        guard poorSince[id] != nil else { return nil }
        let streak = (cleanStreak[id] ?? 0) + 1
        if streak >= Self.cleanSamples { forget(id); return nil }
        cleanStreak[id] = streak
        return shown[id]
    }

    mutating func forget(_ id: CallID) {
        poorSince[id] = nil; cleanStreak[id] = nil; shown[id] = nil
    }
}

extension AppModel {
    static let qualityInterval: Duration = .seconds(2)

    /// One timer for all calls: asks the engine for the quality of every connected call.
    func startQualityPolling() {
        qualityTask?.cancel()
        qualityTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.qualityInterval)
                guard !Task.isCancelled else { return }
                await self?.pollQuality()
            }
        }
    }

    func pollQuality() async {
        let ids = calls.filter { $0.state == .connected && !$0.isOnHold }.map(\.id)
        for id in ids {
            guard let q = try? await engine.quality(of: id), calls.contains(where: { $0.id == id }) else { continue }
            noteQuality(q, for: id)
        }
        for id in Array(quality.keys) where !ids.contains(id) { dropQuality(id) }
    }

    func noteQuality(_ q: CallQuality, for id: CallID, at now: Date = Date()) {
        quality[id] = q
        let reason = qualityMonitor.record(q, for: id, at: now)
        if poorWarning[id] != reason { poorWarning[id] = reason }
    }

    func dropQuality(_ id: CallID) {
        quality[id] = nil
        poorWarning[id] = nil
        qualityMonitor.forget(id)
    }

    // MARK: - Call volume

    var callVolume: (speaker: Float, microphone: Float) {
        (settings.audio.callSpeakerVolume, settings.audio.callMicrophoneVolume)
    }

    /// Stores the value (it is also the default of new calls); `updateSettings` applies it to the engine.
    func setCallVolume(speaker: Float? = nil, microphone: Float? = nil) {
        updateSettings {
            if let speaker { $0.audio.callSpeakerVolume = Self.clampVolume(speaker) }
            if let microphone { $0.audio.callMicrophoneVolume = Self.clampVolume(microphone) }
        }
    }

    /// Command-Up / Command-Down: speaker volume in steps of 10 %, with a short banner.
    func nudgeSpeakerVolume(by delta: Float) {
        let next = Self.clampVolume(((settings.audio.callSpeakerVolume + delta) * 10).rounded() / 10)
        setCallVolume(speaker: next)
        showBanner(L.bannerSpeakerVolume(L.unitPercent(L.number(Double(next) * 100))), isError: false, seconds: 2)
    }

    /// Command-Up / Command-Down. In a text field that holds text they keep their editing meaning
    /// (start / end of the text); in an empty field (the dial field is usually focused) they change the volume.
    func volumeShortcut(up: Bool) {
        if let text = NSApp.keyWindow?.firstResponder as? NSText, !text.string.isEmpty {
            let move = up ? #selector(NSResponder.moveToBeginningOfDocument(_:)) : #selector(NSResponder.moveToEndOfDocument(_:))
            NSApp.sendAction(move, to: text, from: nil)
            return
        }
        nudgeSpeakerVolume(by: up ? 0.1 : -0.1)
    }

    static func clampVolume(_ v: Float) -> Float { min(max(v, AudioSettings.callVolumeRange.lowerBound), AudioSettings.callVolumeRange.upperBound) }

    func applyCallVolumes() {
        let v = callVolume
        let ids = calls.filter(\.isLive).map(\.id)
        Task {
            await engine.setDefaultCallVolume(speaker: v.speaker, microphone: v.microphone)
            for id in ids { try? await engine.setCallVolume(id, speaker: v.speaker, microphone: v.microphone) }
        }
    }

    func applyRingtoneVolume() {
        let v = settings.audio.ringtoneVolume
        Task { await engine.setRingtoneVolume(v) }
    }

    // MARK: - Following new audio devices

    /// Called when the engine reports a change of the device list: remembers the list and, when the setting is on,
    /// moves calls to a newly connected headset (and back when it is unplugged).
    func devicesChanged() async {
        let current = await engine.audioDevices()
        let previous = devices
        devices = current
        // Only USB and Bluetooth devices with input and output count as headsets.
        var eligible: Set<String> = []
        for d in current where d.inputChannels > 0 && d.outputChannels > 0 {
            if await engine.audioTransport(ofDeviceNamed: d.name).isPhysicalHeadsetLink { eligible.insert(d.name) }
        }
        let a = settings.audio
        let action = headsetFollow.update(previous: previous, current: current, eligible: eligible,
                                          configuredInput: a.inputDeviceName, configuredOutput: a.outputDeviceName,
                                          enabled: a.followNewDevices)
        switch action {
        case .none:
            break
        case let .switchTo(name):
            AppLog.app.info("headset connected, switching audio to \(name)")
            await applyAudioSelection()
            showBanner(L.bannerAudioSwitched(name), isError: false, seconds: 4)
        case .revert:
            AppLog.app.info("headset gone, back to the configured audio devices")
            await applyAudioSelection()
            showBanner(a.outputDeviceName.map(L.bannerAudioBack) ?? L.bannerAudioBackDefault, isError: false, seconds: 4)
        }
    }
}

/// Which headset the calls follow. Only the engine selection changes; `AudioSettings` keeps the
/// configured names, which come back when the headset goes away.
struct HeadsetFollow: Equatable {
    enum Action: Equatable { case none, switchTo(String), revert }
    private(set) var headset: String?

    /// `eligible`: names of the current devices that may be followed (USB or Bluetooth, input and output).
    /// An empty `previous` list means the app has not seen the devices yet: nothing is "new" then.
    mutating func update(previous: [AudioDevice], current: [AudioDevice], eligible: Set<String>, configuredInput: String?,
                         configuredOutput: String?, enabled: Bool) -> Action {
        guard enabled else { return cancel() }
        guard !previous.isEmpty else { return .none }
        let known = Set(previous.map(\.name))
        let appeared = current.first { eligible.contains($0.name) && !known.contains($0.name) }
        if let appeared {
            let alreadyConfigured = configuredInput == appeared.name && configuredOutput == appeared.name
            if alreadyConfigured || appeared.name == headset { return .none }
            headset = appeared.name
            return .switchTo(appeared.name)
        }
        if let h = headset, !current.contains(where: { $0.name == h }) { return cancel() }
        return .none
    }

    /// The user picked a device by hand, or switched the setting off.
    mutating func cancel() -> Action {
        guard headset != nil else { return .none }
        headset = nil
        return .revert
    }
}
