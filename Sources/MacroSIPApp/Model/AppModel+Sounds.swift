import AppKit
import MacroSIPCore

/// Hold music, the recording notice tone, the voicemail indicator (MWI), the audio test and the
/// short UI sounds (docs/ENGINE.md "Hold music", "Recording notice tone", "Voicemail indicator",
/// "Audio test", "Sound events"). The engine plays what it is asked; the settings decide here.
extension AppModel {
    // MARK: - Hold music and notice tone

    /// `audio.holdMusic` reaches the engine; a file the engine cannot read keeps the previous source and
    /// shows its reason under the Hold music group (and in a banner).
    func applyHoldMusic() async {
        let source = settings.audio.holdMusic
        do {
            try await engine.setHoldMusic(source)
            holdMusicError = nil
        } catch {
            let reason = describe(error)
            holdMusicError = reason
            AppLog.app.error("hold music: \(reason)")
            showBanner(L.audioHoldMusicError(reason))
        }
    }

    func applyRecordingNotice() {
        let r = settings.recording
        Task { await engine.setRecordingNotice(enabled: r.noticeTone, intervalSeconds: r.noticeToneIntervalSeconds) }
    }

    // MARK: - Audio test

    /// Settings › Audio "Test": two notes for 2 s on the chosen speaker (nil = system default = the call output).
    /// A chosen speaker that is not connected right now plays on the system default instead of failing.
    func playTestTone() {
        let chosen = settings.audio.outputDeviceName
        run {
            let present = await self.engine.audioDevices()
            let device = chosen.flatMap { name in present.contains { $0.name == name && $0.outputChannels > 0 } ? name : nil }
            try await self.engine.playTestTone(outputDevice: device, seconds: 2)
        }
    }

    // MARK: - Sound events

    /// Plays `event` when the matching switch in Settings › Audio › Sound events is on.
    func playSound(_ event: SoundEvent) {
        let s = settings.audio.soundEvents
        let wanted: Bool
        switch event {
        case .callConnected, .callEnded: wanted = s.callEvents
        case .keyPress: wanted = s.keyPress
        case .voicemail: wanted = s.voicemail
        case .error: wanted = s.error
        }
        guard wanted, engineReady else { return }
        Task { [engine] in
            do { try await engine.playEventSound(event) } catch { AppLog.app.error("event sound: \(describe(error))") }
        }
    }

    /// Registration failed or the network went away: one `.error` sound, at most once every 10 s.
    func playErrorSound() {
        let now = Date()
        if let last = lastErrorSoundAt, now.timeIntervalSince(last) < 10 { return }
        lastErrorSoundAt = now
        playSound(.error)
    }

    /// A dial pad key outside a call: the digit goes into the number field and its DTMF tone is heard
    /// when "Dial pad key presses" is on. During a call the key pad sends DTMF instead (screen 4.2).
    func dialPadPressed(_ text: String) {
        dialText.append(text)
        guard activeCall == nil, text.count == 1, let digit = text.first, "0123456789*#".contains(digit) else { return }
        playSound(.keyPress(digit))
    }

    // MARK: - Voicemail (MWI)

    /// New messages over every account (the status bar badge).
    var voicemailNewCount: Int { voicemail.values.filter(\.waiting).reduce(0) { $0 + $1.new } }
    var voicemailWaiting: Bool { voicemail.values.contains(where: \.waiting) }

    /// Enabled accounts with a voicemail number, in account order (the menu bar items).
    var voicemailAccounts: [AccountConfig] {
        enabledAccounts.filter { !($0.voicemailNumber ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// `.voicemail(id, waiting:, new:, old:)`: the indicator of that account; a first or larger count of new
    /// messages plays the voicemail sound.
    func handleVoicemail(_ id: AccountID, waiting: Bool, new: Int, old: Int) {
        guard account(id) != nil else { return }
        let previous = voicemail[id]
        voicemail[id] = VoicemailState(waiting: waiting, new: new, old: old)
        AppLog.app.info("voicemail \(accountName(id)): \(waiting ? "waiting" : "none"), \(new) new, \(old) old")
        if waiting, new > 0, new > (previous?.new ?? 0) { playSound(.voicemail) }
    }

    /// After the engine started: the indicators it already knows (an unsolicited NOTIFY may have arrived).
    func refreshVoicemail() async {
        var states: [AccountID: VoicemailState] = [:]
        for cfg in accounts where cfg.enabled {
            if let s = await engine.voicemailState(for: cfg.id) { states[cfg.id] = s }
        }
        voicemail = states
    }

    /// Calls the account's voicemail number through that account (menu bar item, status bar badge).
    func callVoicemail(for id: AccountID) {
        guard let acct = account(id), let number = acct.voicemailNumber?.trimmingCharacters(in: .whitespaces), !number.isEmpty else { return }
        placeCall(to: number, account: id)
    }

    /// The badge: the first account with messages waiting and a number, else the first with a number.
    func callVoicemailFromBadge() {
        let list = voicemailAccounts
        guard let target = list.first(where: { voicemail[$0.id]?.waiting == true }) ?? list.first else { return }
        callVoicemail(for: target.id)
    }
}
