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
        cleanUpStaleRecordings()
        startEventLoop()
        await startEngineAndAccounts()
        #if DEBUG
        if launch.isDemo { await DemoState.run(self) }
        else if let prefix = launch.snapshotPrefix {
            try? await Task.sleep(for: .seconds(launch.snapshotDelay))
            DemoState.snapshot(prefix: prefix)
        }
        #endif
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
            try await engine.start(network: settings.network, codecPriorities: orderedEnabledCodecs)
        } catch {
            guard !isMockEngine else { report(error); return }
            // The real engine is unavailable: fall back to the simulation, and say so.
            showBanner("\(L.bannerEngineFallback) (\(describe(error)))")
            isMockEngine = true
            engine = MockEngine()
            startEventLoop()
            do { try await engine.start(network: settings.network, codecPriorities: orderedEnabledCodecs) }
            catch { report(error); return }
        }
        engineReady = true
        engineAccounts = []
        for cfg in accounts {
            do {
                try await engine.addAccount(cfg, password: vault.password(for: cfg.id) ?? "")
                engineAccounts.insert(cfg.id)
            } catch { report(error) }
        }
        await refreshDevices()
        await applyAudioSelection()
        resetPresence()
        syncPresenceSubscriptions()
        publishMyPresence()
    }

    func shutdown() async {
        await finishRecordingsForQuit()
        eventTask?.cancel()
        await engine.hangupAll()
        await engine.stop()
    }

    // MARK: - Events

    func handle(_ event: EngineEvent) {
        switch event {
        case let .registration(id, state):
            handleRegistration(id, state)
        case let .incomingCall(info):
            upsert(info)
            handleIncoming(info)
        case let .callChanged(info):
            upsert(info)
            if info.state != .incoming { dismissIncomingPresentation(for: info.id) }
            afterCallsChanged()
        case let .callEnded(info, duration):
            handleEnded(info, duration: duration)
        case let .transferStatus(_, code, final):
            if final, code >= 300 { showBanner("Transfer failed (\(code))") }
        case let .buddyPresence(uri, status):
            handlePresence(uri: uri, status: status)
        case .dtmfReceived, .log:
            break
        case .audioDevicesChanged:
            // The engine re-resolves the stored device names itself; only the lists change.
            Task { await refreshDevices() }
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
        registration[id] = state
        switch state {
        case .registered, .failed: registrationTimes[id] = Date()
        default: break
        }
    }

    private func upsert(_ info: CallInfo) {
        if let i = calls.firstIndex(where: { $0.id == info.id }) { calls[i] = info } else { calls.append(info) }
        if info.state != .incoming { clearAutoAnswer(info.id) }
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
        afterCallsChanged()
    }

    private func handleEnded(_ info: CallInfo, duration: TimeInterval) {
        // The engine rejects a fifth call itself (486) without ever announcing it.
        var note: String?
        if !calls.contains(where: { $0.id == info.id }), info.direction == .incoming,
           case .disconnected(486, _) = info.state {
            note = CallLogNote.callLimit
        }
        calls.removeAll { $0.id == info.id }
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
            remoteDisplayName: info.remote.displayName, accountID: info.accountID,
            startedAt: started, duration: direction == .missed ? 0 : duration, note: note)
        do { try callLogStore.append(entry) } catch { report(error) }
        reloadCallLog()
        if tab == .callLog { markLogSeen() }
        dismissIncomingPresentation(for: info.id)
        afterCallsChanged()
    }

    func afterCallsChanged() {
        refreshIncomingPresentation()
        if calls.isEmpty, networkRestartPending { restartEngineForNetwork() }
    }

    // MARK: - Devices and codecs

    func refreshDevices() async {
        devices = await engine.audioDevices()
    }

    /// The stored device names go to the engine as they are; it falls back to the system default
    /// for a missing device and switches back when the device returns.
    func applyAudioSelection() async {
        let a = settings.audio
        do {
            try await engine.setAudioDevices(inputName: a.inputDeviceName, outputName: a.outputDeviceName)
            await engine.setRingtoneDevice(name: a.ringtoneDeviceName)
            if case let .file(url) = a.ringtone { await engine.setRingtoneFile(url) } else { await engine.setRingtoneFile(nil) }
        } catch { report(error) }
    }

    func applyCodecs() {
        let ordered = orderedEnabledCodecs
        guard !ordered.isEmpty else { return }
        run { try await self.engine.setCodecPriorities(ordered) }
    }

    // MARK: - Network settings (need an engine restart)

    func scheduleNetworkRestart() {
        networkRestartTask?.cancel()
        networkRestartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            if self.calls.isEmpty { self.restartEngineForNetwork() } else { self.networkRestartPending = true }
        }
    }

    func restartEngineForNetwork() {
        networkRestartPending = false
        Task {
            engineReady = false
            await engine.stop()
            registration = [:]
            await startEngineAndAccounts()
        }
    }
}
