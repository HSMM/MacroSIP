import SwiftUI
import MacroSIPCore

extension AppModel {
    // MARK: - Caller names
    // AccountConfig has no separate caller-ID name yet (docs/ENGINE.md); kept app-side until Core grows one.

    func callerName(for id: AccountID) -> String {
        (prefs.dictionary(forKey: "callerNames") as? [String: String])?[id.raw.uuidString] ?? ""
    }

    func setCallerName(_ name: String, for id: AccountID) {
        var d = (prefs.dictionary(forKey: "callerNames") as? [String: String]) ?? [:]
        d[id.raw.uuidString] = name.isEmpty ? nil : name
        prefs.set(d, forKey: "callerNames")
    }

    // MARK: - Save / delete

    func saveAccount(_ cfg: AccountConfig, password: String, callerName: String) async throws {
        let previous = accounts
        try accountStore.upsert(cfg)
        try vault.set(password, for: cfg.id)
        setCallerName(callerName, for: cfg.id)
        var order = (prefs.stringArray(forKey: "accountOrder") ?? [])
        if !order.contains(cfg.id.raw.uuidString) { order.append(cfg.id.raw.uuidString); prefs.set(order, forKey: "accountOrder") }
        loadStores()
        guard engineReady else { return }
        defer { syncPresenceSubscriptions(); publishMyPresence(only: [cfg.id]) }
        let saved = account(cfg.id) ?? cfg
        if !saved.enabled {
            try await removeFromEngine(saved.id)
            return
        }
        if engineAccounts.contains(cfg.id) {
            try await engine.updateAccount(saved, password: password)
        } else {
            try await engine.addAccount(saved, password: password)
            engineAccounts.insert(cfg.id)
        }
        // The default flag moved: tell the engine about the account that lost it.
        for other in accounts where other.id != cfg.id && engineAccounts.contains(other.id) {
            if previous.first(where: { $0.id == other.id })?.isDefaultOutgoing != other.isDefaultOutgoing {
                try? await engine.updateAccount(other, password: nil)
            }
        }
    }

    // MARK: - Enabled switch (account pop-up)

    /// Switches an account on or off. Off removes it from the engine (un-REGISTER, calls on it end)
    /// and takes it out of the status bar and the outgoing choices; on adds it back and registers.
    /// The store and the UI change at once; the engine follows in order, one change at a time.
    func setAccountEnabled(_ id: AccountID, _ on: Bool) {
        guard var cfg = account(id), cfg.enabled != on else { return }
        cfg.enabled = on
        do { try accountStore.upsert(cfg) } catch { report(error); return }
        loadStores()
        if !on { registration[id] = nil }
        let previous = accountSync
        accountSync = Task { @MainActor in
            await previous?.value
            await self.reconcileEngineAccount(id)
        }
    }

    /// Awaits the engine work queued by `setAccountEnabled`.
    func waitForAccountSync() async { await accountSync?.value }

    /// Brings the engine in line with the stored account: present and registering iff enabled.
    private func reconcileEngineAccount(_ id: AccountID) async {
        guard engineReady else { return }
        do {
            if let cfg = account(id), cfg.enabled {
                if engineAccounts.contains(id) {
                    try await engine.updateAccount(cfg, password: nil)
                } else {
                    try await engine.addAccount(cfg, password: vault.password(for: id) ?? "")
                    engineAccounts.insert(id)
                }
            } else {
                try await removeFromEngine(id)
            }
        } catch { report(error) }
        syncPresenceSubscriptions()
        publishMyPresence(only: [id])
    }

    private func removeFromEngine(_ id: AccountID) async throws {
        guard engineAccounts.contains(id) else { return }
        try await engine.removeAccount(id)
        engineAccounts.remove(id)
        registration[id] = nil
    }

    func deleteAccount(_ id: AccountID) async {
        do {
            if engineAccounts.contains(id) { try await engine.removeAccount(id); engineAccounts.remove(id) }
            try accountStore.remove(id)
            try vault.delete(for: id)
        } catch { report(error) }
        registration[id] = nil
        if settingsSelectedAccount == id { settingsSelectedAccount = nil }
        loadStores()
        syncPresenceSubscriptions()
    }

    func moveAccounts(from: IndexSet, to: Int) {
        accounts.move(fromOffsets: from, toOffset: to)
        prefs.set(accounts.map { $0.id.raw.uuidString }, forKey: "accountOrder")
    }

    func retryRegistration(_ id: AccountID) {
        registration[id] = .registering
        run { try await self.engine.setRegistered(id, true) }
    }

    // MARK: - Test button

    static func testResult(for state: RegistrationState) -> AccountTestResult? {
        switch state {
        case .registered: return .success(ms: 0)
        case let .failed(code, reason): return .failed(code: code, reason: reason)
        case .registering, .unregistered: return nil
        }
    }

    /// Adds a temporary account, waits up to 10 s for its registration result, removes it again.
    func testAccount(_ cfg: AccountConfig, password: String) async -> AccountTestResult {
        guard engineReady else { return .error("The SIP engine is not running.") }
        var temp = cfg
        temp.id = AccountID()
        temp.enabled = true
        temp.registerWithServer = true
        temp.isDefaultOutgoing = false
        let id = temp.id
        let started = Date()
        testActive.insert(id)
        defer { testActive.remove(id); testOutcomes[id] = nil }
        do { try await engine.addAccount(temp, password: password) }
        catch { return .error(describe(error)) }

        var result: AccountTestResult
        if let early = testOutcomes[id] {
            result = early
        } else {
            result = await withCheckedContinuation { (cont: CheckedContinuation<AccountTestResult, Never>) in
                testWaiters[id] = cont
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(10))
                    if let c = self.testWaiters.removeValue(forKey: id) { c.resume(returning: .timeout) }
                }
            }
        }
        try? await engine.removeAccount(id)
        if case .success = result { result = .success(ms: Int(Date().timeIntervalSince(started) * 1000)) }
        return result
    }

    // MARK: - Settings

    /// Applies a settings change, persists it and runs the side effects of what changed.
    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        let old = settings
        var new = old
        mutate(&new)
        // Do Not Disturb and the published status move together.
        // The status from before DND is remembered and comes back when DND goes off (Away stays Away).
        if new.general.doNotDisturb != old.general.doNotDisturb {
            if new.general.doNotDisturb {
                if old.general.presenceStatus != .dnd { prefs.set(old.general.presenceStatus.rawValue, forKey: "presenceBeforeDND") }
                new.general.presenceStatus = .dnd
            } else if new.general.presenceStatus == .dnd {
                let before = prefs.string(forKey: "presenceBeforeDND").flatMap(PresenceStatus.init(rawValue:))
                new.general.presenceStatus = (before == .away) ? .away : .available
            }
        }
        guard new != old else { return }
        settings = new
        do { try settingsStore.save(new) } catch { report(error) }
        if new.general.showDockIcon != old.general.showDockIcon { applyActivationPolicy() }
        if new.general.launchAtLogin != old.general.launchAtLogin { applyLaunchAtLogin() }
        if new.codecOrder != old.codecOrder || new.enabledCodecs != old.enabledCodecs { applyCodecs() }
        if new.network != old.network { scheduleNetworkRestart() }
        if new.recording.folder != old.recording.folder || new.recording.folderBookmark != old.recording.folderBookmark {
            refreshRecordingFolder()
        }
        if new.audio != old.audio { Task { await applyAudioSelection() } }
        let published: (AppSettings) -> PresenceStatus = { $0.general.doNotDisturb ? .dnd : $0.general.presenceStatus }
        if published(new) != published(old) { publishMyPresence() }
    }

    func binding<T: Sendable>(_ keyPath: WritableKeyPath<AppSettings, T> & Sendable) -> Binding<T> {
        Binding(
            get: { MainActor.assumeIsolated { self.settings[keyPath: keyPath] } },
            set: { v in MainActor.assumeIsolated { self.updateSettings { $0[keyPath: keyPath] = v } } })
    }

    // MARK: - Call log "seen"

    func markLogSeen() {
        seenLogAt = Date()
        prefs.set(seenLogAt, forKey: "seenLogAt")
    }

    func clearCallLog() {
        do { try callLogStore.clear() } catch { report(error) }
        reloadCallLog()
    }

    func deleteLogEntry(_ id: UUID) {
        do { try callLogStore.remove(id) } catch { report(error) }
        reloadCallLog()
    }

    // MARK: - Contacts

    func saveContact(_ c: Contact) {
        do { try contactStore.upsert(c) } catch { report(error) }
        loadStores()
        syncPresenceSubscriptions()
    }

    func deleteContact(_ id: UUID) {
        do { try contactStore.remove(id) } catch { report(error) }
        loadStores()
        syncPresenceSubscriptions()
    }

    func suggestions(for text: String, limit: Int = 5) -> [Contact] {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return Array(contactStore.search(q).sorted { $0.name < $1.name }.prefix(limit))
    }
}
