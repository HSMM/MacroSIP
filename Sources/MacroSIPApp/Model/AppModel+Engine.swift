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
    }

    func shutdown() async {
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
        case .dtmfReceived, .buddyPresence, .log:
            break
        case .audioDevicesChanged:
            Task { await refreshDevices(); await applyAudioSelection() }
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
    }

    private func handleIncoming(_ info: CallInfo) {
        if doNotDisturb {
            run { try await self.engine.reject(info.id, code: 486) }
            return
        }
        if mainWindowIsFrontmost { tab = .dialpad }
        afterCallsChanged()
    }

    private func handleEnded(_ info: CallInfo, duration: TimeInterval) {
        calls.removeAll { $0.id == info.id }
        ringtoneSilenced.remove(info.id)
        if let t = transfer, t.original == info.id || t.consult == info.id { transfer = nil }
        if liveCalls.isEmpty { showKeypad = false; dtmfSent = "" }
        let direction: CallDirection = (info.direction == .incoming && info.startedAt == nil) ? .missed : info.direction
        let started = info.startedAt ?? Date().addingTimeInterval(-duration)
        let entry = CallLogEntry(
            direction: direction, remoteNumber: info.remote.number.isEmpty ? info.remote.uri : info.remote.number,
            remoteDisplayName: info.remote.displayName, accountID: info.accountID,
            startedAt: started, duration: direction == .missed ? 0 : duration)
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

    /// Maps the stored device names to engine ids; a missing device falls back to the system default.
    func applyAudioSelection() async {
        let a = settings.audio
        func id(_ name: String?, input: Bool) -> Int? {
            guard let name else { return nil }
            return devices.first { $0.name == name && (input ? $0.inputChannels > 0 : $0.outputChannels > 0) }?.id
        }
        do {
            try await engine.setAudioDevices(input: id(a.inputDeviceName, input: true),
                                             output: id(a.outputDeviceName, input: false))
            await engine.setRingtoneDevice(id(a.ringtoneDeviceName, input: false))
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
