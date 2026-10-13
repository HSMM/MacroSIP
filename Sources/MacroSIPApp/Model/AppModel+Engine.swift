import SwiftUI
import AppKit
import MacroSIPCore

extension AppModel {
    var orderedEnabledCodecs: [String] {
        settings.codecOrder.filter { settings.enabledCodecs.contains($0) }
    }

    // MARK: - Lifecycle

    /// Starts the engine, registers every account, applies audio settings.
    func bootstrap() async {
        AppLog.app.info("\(Product.name) \(AppInfo.versionLine) started, macOS \(ProcessInfo.processInfo.operatingSystemVersionString), PJSIP log level \(launch.logLevel)")
        syncLoginItemStatus()
        migrateLegacyPrefs()
        restoreDND()
        startDirectory()
        cleanUpStaleRecordings()
        startEventLoop()
        startQualityPolling()
        headsetButtonsEnabled = settings.audio.headsetButtons
        startHeadsetButtons()
        await startEngineAndAccounts()
        #if DEBUG
        if launch.isDemo { await DemoState.run(self) }
        else if let prefix = launch.snapshotPrefix {
            try? await Task.sleep(for: .seconds(launch.snapshotDelay))
            DemoState.snapshot(prefix: prefix)
        }
        #endif
    }

    /// Before 26.1 the ringtone volume was kept in the app's defaults (the engine ignored it); it now lives in the settings.
    func migrateLegacyPrefs() {
        guard let old = prefs.object(forKey: "ringtoneVolume") as? Double else { return }
        prefs.removeObject(forKey: "ringtoneVolume")
        updateSettings { $0.audio.ringtoneVolume = Float(min(max(old, 0), 1)) }
    }

    private func startEventLoop() {
        eventTask?.cancel()
        let stream = engine.events
        eventTask = Task { @MainActor [weak self] in
            for await event in stream { self?.handle(event) }
        }
    }

    func startEngineAndAccounts() async {
        do {
            try await engine.start(network: settings.network, codecPriorities: orderedEnabledCodecs, codecOptions: settings.codecOptions, callOptions: effectiveCallOptions)
        } catch {
            guard !isMockEngine else { report(error); return }
            // The real engine is unavailable: fall back to the simulation, and say so.
            showBanner("\(L.bannerEngineFallback) (\(describe(error)))")
            isMockEngine = true
            engine = MockEngine()
            startEventLoop()
            do { try await engine.start(network: settings.network, codecPriorities: orderedEnabledCodecs, codecOptions: settings.codecOptions, callOptions: effectiveCallOptions) }
            catch { report(error); return }
        }
        await refreshDevices()          // before any device event can be treated as news
        engineReady = true
        networkOnline = await engine.networkState() == .online
        engineAccounts = []
        for cfg in accounts where cfg.enabled {
            do {
                try await engine.addAccount(cfg, password: vault.password(for: cfg.id) ?? "")
                engineAccounts.insert(cfg.id)
            } catch { report(error) }
        }
        await applyAudioSelection()
        applyVolumes()
        await applyHoldMusic()
        applyRecordingNotice()
        await refreshVoicemail()
        resetPresence()
        syncPresenceSubscriptions()
        publishMyPresence()
    }

    /// willSleep: un-REGISTERs and holds the sleep back for up to 2 s (the system lets a willSleep observer
    /// block briefly) so the answers arrive before the Mac stops. The engine never needs the main thread;
    /// the run loop keeps turning so its events (the accounts going unregistered) are handled meanwhile.
    func prepareForSleep() {
        Task { await engine.handleSleep() }
        guard !isMockEngine else { return }
        let registered: () -> Bool = { self.accounts.contains { a in
            if case .registered = self.registration[a.id] ?? .unregistered { return a.enabled && a.registerWithServer }
            return false } }
        let deadline = Date().addingTimeInterval(2)
        while registered(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    func shutdown() async {
        await finishRecordingsForQuit()
        eventTask?.cancel()
        qualityTask?.cancel()
        stopHeadsetButtons()
        await engine.hangupAll()
        await engine.stop()
        AppLog.app.info("quit")
        FileLog.shared?.flush()
    }

    // MARK: - Events

    func handle(_ event: EngineEvent) {
        switch event {
        case let .registration(id, state):
            handleRegistration(id, state)
        case let .incomingCall(info):
            if recordingPlayer.isPlaying { recordingPlayer.toggle() }       // a ringing call interrupts playback
            upsert(info)
            handleIncoming(info)
        case let .callChanged(info):
            let wasEstablished = calls.first { $0.id == info.id }?.isEstablished ?? false
            upsert(info)
            if info.state != .incoming { dismissIncomingPresentation(for: info.id) }
            if info.state == .connected, !wasEstablished { playSound(.callConnected) }
            afterCallsChanged()
        case let .callEnded(info, duration):
            handleEnded(info, duration: duration)
        case let .transferStatus(_, code, final):
            if final, code >= 300 { showBanner("Transfer failed (\(code))") }
        case let .buddyPresence(uri, status, note):
            handlePresence(uri: uri, status: status)
            handleQuickKeyPresence(uri: uri, status: status, note: note)
        case let .log(level, text):
            AppLog.record(engineLevel: level, text)
        case .dtmfReceived:
            break
        case let .network(state):
            let wasOnline = networkOnline
            networkOnline = state == .online
            AppLog.app.info("network \(networkOnline ? "online" : "offline")")
            if wasOnline, !networkOnline { playErrorSound() }
        case .audioDevicesChanged:
            // The engine re-resolves the stored device names itself; a new headset may take over (devicesChanged).
            Task { await devicesChanged() }
        case let .voicemail(id, waiting, new, old):
            handleVoicemail(id, waiting: waiting, new: new, old: old)
        }
    }

    private func handleRegistration(_ id: AccountID, _ state: RegistrationState) {
        if testActive.contains(id) {
            // Temporary account of the editor's Test button: never shown in the lists.
            if let result = Self.testResult(for: state) {
                if let waiter = testWaiters.removeValue(forKey: id) { waiter.resume(returning: result) }
                else { testOutcomes[id] = result }
            }
            return
        }
        guard account(id) != nil else { return }
        let previous = registration[id]
        registration[id] = state
        switch state {
        case .registered, .failed, .reconnecting: registrationTimes[id] = Date()
        default: break
        }
        if case .failed = state, previous != state { playErrorSound() }
    }

    private func upsert(_ info: CallInfo) {
        if let i = calls.firstIndex(where: { $0.id == info.id }) { calls[i] = info } else { calls.append(info) }
        if info.state != .incoming { clearAutoAnswer(info.id) }
        if info.isReconnecting { if reconnectingSince[info.id] == nil { reconnectingSince[info.id] = Date() } }
        else { reconnectingSince[info.id] = nil }
        noteRecordingState(info)
        updateConferenceClock()
    }

    /// The conference timer runs from the moment two legs were merged.
    func updateConferenceClock() {
        if conferenceCalls.count >= 2 { if conferenceSince == nil { conferenceSince = Date() } }
        else if conferenceSince != nil { conferenceSince = nil }
    }

    private func handleIncoming(_ info: CallInfo) {
        if doNotDisturb {
            run { try await self.engine.reject(info.id, code: 486) }
            return
        }
        if mainWindowIsFrontmost { tab = .dialpad }
        armAutoAnswer(for: info)
        lookupIncomingCaller(info)
        if settings.general.bringToFrontOnIncoming { bringMainWindowForward() }
        afterCallsChanged()
    }

    private func handleEnded(_ info: CallInfo, duration: TimeInterval) {
        // The engine rejects a call itself (486) without ever announcing it: a fifth call, or any second
        // call in single-call mode ("Busy").
        var note: String?
        if !calls.contains(where: { $0.id == info.id }), info.direction == .incoming, !doNotDisturb,
           case .disconnected(486, _) = info.state {
            note = (calls.count < 4 && settings.callOptions.incomingWhileOnCall == .busy) ? CallLogNote.busy : CallLogNote.callLimit
        }
        // Turned away by the rule in General › Incoming calls: 603, or 433 for anonymous callers; it never rang.
        if !calls.contains(where: { $0.id == info.id }), info.direction == .incoming, settings.callOptions.denyIncoming != .nobody,
           case let .disconnected(code, _) = info.state, code == 603 || code == 433 {
            note = CallLogNote.denied
        }
        if case let .disconnected(_, reason) = info.state, reason == Engine.connectionLostReason {
            note = CallLogNote.connectionLost
        }
        reconnectingSince[info.id] = nil
        // The ended sound: a call that was connected (or held) at some point; not a missed or declined ringing
        // call, a failed outgoing attempt, or one the engine turned away itself.
        if let shown = calls.first(where: { $0.id == info.id }), shown.isEstablished || info.startedAt != nil { playSound(.callEnded) }
        calls.removeAll { $0.id == info.id }
        dropQuality(info.id)
        clearAutoAnswer(info.id)
        recordingCallEnded(info)
        updateConferenceClock()
        ringtoneSilenced.remove(info.id)
        if let t = transfer, t.original == info.id || t.consult == info.id { transfer = nil }
        if liveCalls.isEmpty { showKeypad = false; dtmfSent = "" }
        let direction: CallDirection = (info.direction == .incoming && info.startedAt == nil) ? .missed : info.direction
        let started = info.startedAt ?? Date().addingTimeInterval(-duration)
        let entry = CallLogEntry(
            direction: direction, remoteNumber: info.remote.number.isEmpty ? info.remote.uri : info.remote.number,
            remoteDisplayName: resolvedRemoteName(info.remote), accountID: info.accountID,
            startedAt: started, duration: direction == .missed ? 0 : duration, note: note)
        do { try callLogStore.append(entry) } catch { report(error) }
        // The recording of this call: already converted, or still being converted (it then finds the entry by call).
        if let url = recordingByCall.removeValue(forKey: info.id) {
            do { try callLogStore.setRecording(url, for: entry.id) } catch { report(error) }
        }
        logEntryByCall[info.id] = entry.id          // a recording still being converted finds its entry (removed when it is saved; the 64 newest are kept)
        reloadCallLog()
        if tab == .callLog { markLogSeen() }
        dismissIncomingPresentation(for: info.id)
        afterCallsChanged()
    }

    func afterCallsChanged() {
        if calls.isEmpty { incomingKeyGuard = false }
        if liveCalls.isEmpty { callVolumeShown = false }
        refreshIncomingPresentation()
        syncHeadsetIndicators()
    }

    // MARK: - Devices and codecs

    func refreshDevices() async {
        devices = await engine.audioDevices()
    }

    /// The stored device names go to the engine as they are; it falls back to the system default
    /// for a missing device and switches back when the device returns.
    func applyAudioSelection() async {
        let a = settings.audio
        let headset = headsetFollow.headset      // a followed headset replaces the configured devices for now
        do {
            try await engine.setAudioDevices(inputName: headset ?? a.inputDeviceName, outputName: headset ?? a.outputDeviceName)
            await engine.setRingtoneDevice(name: a.ringtoneDeviceName)
            if case let .file(url) = a.ringtone { await engine.setRingtoneFile(url) } else { await engine.setRingtoneFile(nil) }
        } catch { report(error) }
    }

    /// Volumes only: the engine keeps them across `setAudioDevices`.
    func applyVolumes() {
        applyRingtoneVolume()
        applyCallVolumes()
    }

    /// What the engine gets: the stored options plus the app's Do Not Disturb state (manual or timed), so the
    /// engine turns calls away before anything rings; the app-side rejection in `handleIncoming` stays as a fallback.
    var effectiveCallOptions: CallOptions {
        var options = settings.callOptions
        options.doNotDisturb = settings.general.doNotDisturb
        options.knownNumbers = knownNumbers
        return options
    }

    /// Every number of every contact, normalised like `Contact.normalize`: what the engine compares a caller with
    /// for "Numbers not in Contacts". Kept out of settings.json (it is derived from contacts.json).
    var knownNumbers: Set<String> {
        Set(contacts.flatMap(\.allNormalizedNumbers))
    }

    /// Whenever contacts change: the engine gets the new set (only when it differs from the last one sent).
    func syncKnownNumbers() {
        let numbers = knownNumbers
        guard numbers != syncedKnownNumbers else { return }
        syncedKnownNumbers = numbers
        if engineReady { applyCallOptions() }
    }

    /// Changes reach the engine one after the other, each with the options current when it runs.
    func applyCallOptions() {
        let previous = callOptionsTask
        callOptionsTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await self.engine.setCallOptions(self.effectiveCallOptions)
        }
    }

    /// At launch: a timed Do Not Disturb that ran out while the app was closed is over; one that is still running goes on.
    func restoreDND() {
        if settings.general.doNotDisturb, let end = settings.general.doNotDisturbUntil, end <= Date() {
            updateSettings { $0.general.doNotDisturb = false }
        }
        armDNDTimer()
    }

    func applyCodecOptions() {
        let options = settings.codecOptions
        run { try await self.engine.setCodecOptions(options) }
    }

    func applyCodecs() {
        let ordered = orderedEnabledCodecs
        guard !ordered.isEmpty else { return }
        run { try await self.engine.setCodecPriorities(ordered) }
    }

    // MARK: - Network settings

    /// A few moments after the last change the engine is asked to apply the network settings. What it cannot
    /// change while running (port range, DNS, local port...) comes back as `.needsRestart`; Settings › Network
    /// then offers "Restart now". The restart itself starts the engine with the stored settings.
    func scheduleNetworkApply() {
        networkRestartTask?.cancel()
        networkRestartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self, self.engineReady else { return }
            do {
                networkRestartNeeded = try await self.engine.applyNetworkSettings(self.settings.network) == .needsRestart
            } catch { self.report(error) }
        }
    }

    /// Stops the engine and starts it again with the stored settings; the accounts register again.
    func restartEngineForNetwork() {
        networkRestartNeeded = false
        networkRestartTask?.cancel()
        Task {
            engineReady = false
            await engine.stop()
            registration = [:]
            voicemail = [:]
            await startEngineAndAccounts()
        }
    }
}
