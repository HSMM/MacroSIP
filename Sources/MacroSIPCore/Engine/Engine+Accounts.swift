internal import CPJSUA
import Foundation

extension Engine {
    /// Adds the account to pjsua and registers it when `cfg.registers`. Atomic: if the
    /// account cannot be added or its registration cannot be started, nothing remains.
    public func addAccount(_ cfg: AccountConfig, password: String) throws {
        try requireStarted()
        guard accounts[cfg.id] == nil else {
            throw EngineError.invalidArgument("account \(cfg.id.raw) is already added")
        }
        let settings = try accountSettings(cfg, password: password)
        var index = PJ.invalidID
        try AccountMapping.withPJConfig(settings) { p in
            // Never register inside pjsua_acc_add: the callbacks need the index mapping first.
            p.pointee.register_on_acc_add = 0
            try PJ.check(pjsua_acc_add(p, cfg.isDefaultOutgoing ? 1 : 0, &index), "pjsua_acc_add")
        }
        accounts[cfg.id] = AccountEntry(index: index, config: cfg, password: password,
                                        wantsRegistration: cfg.registers)
        bridge.setAccount(index, cfg.id, registrationInterval: cfg.registrationInterval,
                          proxy: SignallingSource.proxy(cfg.outboundProxy, transport: cfg.transport))
        bridge.setWantsRegistration(index, cfg.registers)
        bridge.setRegistration(cfg.id, .unregistered, force: true)
        warnIfUnverifiedTLS(cfg)
        // pjsua starts accounts offline; the first PUBLISH (after registering) says available.
        if cfg.publishPresence {
            do { try applyPresence(.available, index: index) } catch { PJ.warn(error, "initial presence") }
        }
        guard cfg.registers else { return }
        do {
            try applyRegistration(cfg.id, true)
        } catch {
            PJ.warn(pjsua_acc_del(index), "remove account after failed registration start")
            bridge.removeAccount(index)
            accounts[cfg.id] = nil
            throw error
        }
    }

    /// `password == nil` keeps the current one. The new configuration is always applied;
    /// a failing un-REGISTER of the old one is only logged. Re-registers when `cfg.registers`.
    public func updateAccount(_ cfg: AccountConfig, password: String?) throws {
        try requireStarted()
        guard var entry = accounts[cfg.id] else { throw EngineError.unknownAccount(cfg.id) }
        let pw = password ?? entry.password
        let settings = try accountSettings(cfg, password: pw)
        // New settings start a new series of attempts.
        cancelRegistrationRetry(cfg.id)
        bridge.resetRetryAttempts(cfg.id)
        entry.wantsRegistration = cfg.registers
        accounts[cfg.id]?.wantsRegistration = cfg.registers
        bridge.setWantsRegistration(entry.index, cfg.registers)
        if !cfg.registers && bridge.registration(of: cfg.id) != .unregistered {
            do {
                try applyRegistration(cfg.id, false)
            } catch {
                PJ.warn(error, "unregister before modifying account")
            }
        }
        try AccountMapping.withPJConfig(settings) { p in
            // We decide about (re-)registration below, not pjsua_acc_modify.
            p.pointee.disable_reg_on_modify = 1
            try PJ.check(pjsua_acc_modify(entry.index, p), "pjsua_acc_modify")
        }
        if cfg.isDefaultOutgoing {
            PJ.warn(pjsua_acc_set_default(entry.index), "set default account")
        }
        let serverChanged = entry.config.registrarURI != cfg.registrarURI
            || entry.config.outboundProxy != cfg.outboundProxy || entry.config.transport != cfg.transport
        entry.config = cfg
        entry.password = pw
        accounts[cfg.id] = entry
        bridge.setAccount(entry.index, cfg.id, registrationInterval: cfg.registrationInterval,
                          proxy: SignallingSource.proxy(cfg.outboundProxy, transport: cfg.transport))
        // Another server: trust its INVITEs only after it accepted a REGISTER.
        if serverChanged { bridge.setRegistrarSource(entry.index, nil) }
        warnIfUnverifiedTLS(cfg)
        // Switching publishing off makes pjsua un-PUBLISH and go offline; switching it back
        // on must not publish "offline": re-apply the last status.
        if cfg.publishPresence {
            do { try applyPresence(entry.presence, index: entry.index) } catch { PJ.warn(error, "presence") }
        }
        // A SUBSCRIBE that failed with the old settings would wait 300 s for pjsua's retry.
        refreshPresenceSubscriptions(accountIndex: entry.index)
        if cfg.registers {
            try applyRegistration(cfg.id, true)
        }
    }

    /// Hangs up the account's calls, unregisters and deletes it.
    public func removeAccount(_ id: AccountID) throws {
        try requireStarted()
        guard let entry = accounts[id] else { throw EngineError.unknownAccount(id) }
        for slot in CallSnapshot.allSlots() {
            if let snap = CallSnapshot.read(slot), snap.accIndex == entry.index, snap.state != .disconnected {
                PJ.warn(pjsua_call_hangup(slot, 0, nil, nil), "hang up call \(slot) of removed account")
            }
        }
        try PJ.check(pjsua_acc_del(entry.index), "pjsua_acc_del")
        accounts[id] = nil
        cancelRegistrationRetry(id)
        bridge.removeAccount(entry.index)
    }

    /// Switching off never fails because of the registration's own state: nothing to
    /// unregister counts as done, and a REGISTER in flight is unregistered once it completes.
    public func setRegistered(_ id: AccountID, _ on: Bool) throws {
        try requireStarted()
        guard let entry = accounts[id] else { throw EngineError.unknownAccount(id) }
        accounts[id]?.wantsRegistration = on
        bridge.setWantsRegistration(entry.index, on)
        if on { bridge.resetRetryAttempts(id) }     // explicit request: a fresh series
        if !on && bridge.registration(of: id) == .unregistered && bridge.pendingRegistration(id) == nil {
            cancelRegistrationRetry(id)
            return
        }
        try applyRegistration(id, on)
    }

    public func registrationState(of id: AccountID) -> RegistrationState {
        bridge.registration(of: id)
    }

    // MARK: internals

    func accountSettings(_ cfg: AccountConfig, password: String) throws -> PJAccountSettings {
        let settings = try AccountMapping.settings(for: cfg, password: password, network: network,
                                                   transports: transports, bindAddress: bindAddress)
        // pjsua_acc_add does not validate reg_uri; a bad one would only fail later.
        try verifyURI(settings.idURI, "account URI")
        try verifyURI(settings.regURI, "registrar")
        for proxy in settings.proxies { try verifyURI(proxy, "outbound proxy") }
        return settings
    }

    private func verifyURI(_ uri: String, _ what: String) throws {
        guard pjsua_verify_sip_url(uri) == PJ.success else {
            throw EngineError.invalidArgument("\(what) \"\(uri)\" is not a valid SIP URI")
        }
    }

    private func warnIfUnverifiedTLS(_ cfg: AccountConfig) {
        guard cfg.transport == .tls, !cfg.verifyTLSCertificate else { return }
        let text = "account \(cfg.uri): TLS server certificate verification is OFF (user setting)"
        bridge.engineLogger.notice("\(text, privacy: .public)")
        emit(.log(level: 2, "engine: \(text)"))
    }

    /// One pjsua_acc_set_registration with PJSIP's busy/no-registration cases handled.
    /// `retrying`: a backoff retry; a synchronous failure is left to the caller (it becomes
    /// the next `.reconnecting` attempt instead of `.failed`).
    func applyRegistration(_ id: AccountID, _ on: Bool, retrying: Bool = false) throws {
        guard let entry = accounts[id] else { throw EngineError.unknownAccount(id) }
        cancelRegistrationRetry(id)          // this request supersedes a scheduled retry
        if !on { bridge.resetRetryAttempts(id) }
        let before = bridge.registration(of: id)
        let status = pjsua_acc_set_registration(entry.index, on ? 1 : 0)
        if on, status != PJ.success, case .reconnecting = bridge.registration(of: id),
           bridge.registration(of: id) != before {
            // The REGISTER could not even be sent (no network: DNS or sendto fails at once)
            // and pjsua already reported it through on_reg_state2, which classified it as
            // temporary and scheduled the retry. Not an error of this call: the account stays.
            bridge.setPendingRegistration(id, nil)
            return
        }
        if status == PJ.success {
            bridge.setPendingRegistration(id, nil)   // the latest request wins
            if !on { bridge.setRegistration(id, .unregistered) }
            return
        }
        if status == cpjsua_err_sip_busy() || status == cpjsua_err_pj_busy() {
            // A REGISTER transaction is in flight; repeat the request when it completes
            // (pjOnRegState2). Show the intent now.
            bridge.setPendingRegistration(id, on)
            if on {
                bridge.showRegistering(id)
            } else {
                bridge.setRegistration(id, .unregistered)
            }
            return
        }
        if !on && status == cpjsua_err_invalid_op() {
            // No registration to remove: PJSIP drops it after a failed REGISTER. The
            // auto-retry timer was cancelled by the same call.
            bridge.setPendingRegistration(id, nil)
            bridge.setRegistration(id, .unregistered)
            return
        }
        if on && !retrying {
            bridge.setRegistration(id, .failed(code: 0, reason: PJ.errorText(status)))
        }
        throw PJ.error(status, on ? "register" : "unregister")
    }

    /// Called (asynchronously) when the transaction that made PJSIP answer EBUSY completed.
    func applyPendingRegistration(_ id: AccountID, _ on: Bool) {
        guard isStarted, PJ.registerThread(), accounts[id] != nil else { return }
        do {
            try applyRegistration(id, on)
        } catch {
            PJ.warn(error, on ? "register (deferred)" : "unregister (deferred)")
        }
    }
}
