internal import CPJSUA
import Foundation
import os

extension Engine {
    /// Adds the account to pjsua and registers it when `cfg.registers`. Atomic: if the
    /// account cannot be added or its registration cannot be started, nothing remains.
    public func addAccount(_ cfg: AccountConfig, password: String) throws {
        try requireStarted()
        guard accounts[cfg.id] == nil else {
            throw EngineError.invalidArgument("account \(cfg.id.raw) is already added")
        }
        let family = try decideFamily(cfg)
        let settings = try accountSettings(cfg, password: password, family: family)
        var index = PJ.invalidID
        try AccountMapping.withPJConfig(settings) { p in
            // Never register inside pjsua_acc_add: the callbacks need the index mapping first.
            p.pointee.register_on_acc_add = 0
            try PJ.check(pjsua_acc_add(p, cfg.isDefaultOutgoing ? 1 : 0, &index), "pjsua_acc_add")
        }
        accounts[cfg.id] = AccountEntry(index: index, config: cfg, password: password, family: family,
                                        wantsRegistration: cfg.registers)
        logFamily(cfg, family)
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
        var family = try decideFamily(cfg)
        // Never move an account with a call to the other family: the call's dialog would keep its
        // peer and lose its transport. The move waits for the calls (`runDeferredMoves`).
        var deferred: (family: IPFamily, reason: String)?
        if family != entry.family, accountHasCalls(entry.index) {
            deferred = (family, "settings changed")
            family = entry.family
            emit(.log(level: 3, "engine: account \(cfg.uri): move to \(deferred!.family) waits for its calls"))
        }
        let settings = try accountSettings(cfg, password: pw, family: family)
        let moving = family != entry.family
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
        // A move to the other family destroys the registration session without an un-REGISTER
        // (disable_reg_on_modify); remove the old binding first, so it does not stay at the registrar.
        let unregisterFirst = moving && cfg.registers && hasBinding(cfg.id)
        if unregisterFirst { unregisterBeforeMove(entry) }
        defer { if unregisterFirst { bridge.setIgnoringUnregister(entry.index, false) } }
        try AccountMapping.withPJConfig(settings) { p in
            // We decide about (re-)registration below, not pjsua_acc_modify.
            p.pointee.disable_reg_on_modify = 1
            try PJ.check(pjsua_acc_modify(entry.index, p), "pjsua_acc_modify")
        }
        cpjsua_acc_set_sdp_nat_rewrite(entry.index, settings.sdpNATRewrite ? 1 : 0)
        if moving { cpjsua_acc_end_mwi_after_move(entry.index) }
        if cfg.isDefaultOutgoing {
            PJ.warn(pjsua_acc_set_default(entry.index), "set default account")
        }
        let serverChanged = entry.config.registrarURI != cfg.registrarURI
            || entry.config.outboundProxy != cfg.outboundProxy || entry.config.transport != cfg.transport
            || entry.family != family
        if entry.family != family || entry.config.ipProtocol != cfg.ipProtocol { logFamily(cfg, family) }
        entry.config = cfg
        entry.password = pw
        entry.family = family
        entry.pendingMove = deferred
        entry.familySticky = false
        entry.familyFallbackTried = false
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
        // A SUBSCRIBE that failed with the old settings would wait 300 s for pjsua's retry; after a
        // move every subscription is made anew on the new transport.
        if moving { resubscribePresence(accountIndex: entry.index) }
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

    func accountSettings(_ cfg: AccountConfig, password: String, family: IPFamily) throws -> PJAccountSettings {
        let settings = try AccountMapping.settings(for: cfg, password: password, network: network,
                                                   transports: transports, bindAddress: bindAddress, family: family)
        // pjsua_acc_add does not validate reg_uri; a bad one would only fail later.
        try verifyURI(settings.idURI, "account URI")
        try verifyURI(settings.regURI, "registrar")
        for proxy in settings.proxies { try verifyURI(proxy, "outbound proxy") }
        return settings
    }

    /// DNS SRV is in effect: pjsua has a resolver and looks up SRV records of hosts without a port.
    var srvInEffect: Bool { !dnsServers.isEmpty }

    /// The account's IP family (`IPFamilyPolicy`). Throws `.invalidArgument` when IPv4 only or IPv6 only
    /// contradicts the server's IP literal: such an account could never register. A host name that is
    /// not resolved within `familyLookupTimeout` counts as unresolved (IPv4).
    func decideFamily(_ cfg: AccountConfig) throws -> IPFamily {
        if let literal = IPFamilyPolicy.conflict(in: cfg) {
            let host = IPFamilyPolicy.firstHop(of: cfg).host
            throw EngineError.invalidArgument("server \(host) is an \(literal) address but the account is set to "
                                              + "\(literal == .ipv6 ? "IPv4" : "IPv6") only")
        }
        return IPFamilyPolicy.decide(cfg, available: transports.families(for: cfg), srv: srvInEffect) { host in
            lookupFamilies([host])[host] ?? []
        }
    }

    /// The families of each host name, looked up concurrently off the engine queue (each host once) and
    /// waited for at most `familyLookupTimeout` in all. A host missing from the result did not answer in
    /// time; its lookup goes on and is discarded. Up to N lookups thus block the engine for one limit at
    /// most, not N in a row.
    func lookupFamilies(_ hosts: [String]) -> [String: [IPFamily]] {
        let unique = Array(Set(hosts.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return [:] }
        let results = OSAllocatedUnfairLock(initialState: [String: [IPFamily]]())
        let group = DispatchGroup()
        let resolve = resolveFamilies
        for host in unique {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let families = resolve(host)
                results.withLock { $0[host] = families }
                group.leave()
            }
        }
        let limit = familyLookupTimeout.components
        let seconds = Double(limit.seconds) + Double(limit.attoseconds) / 1e18
        if group.wait(timeout: .now() + seconds) == .timedOut {
            emit(.log(level: 3, "engine: address lookup of \(unique.joined(separator: ", ")) not finished within \(seconds) s"))
        }
        return results.withLock { $0 }
    }

    private func logFamily(_ cfg: AccountConfig, _ family: IPFamily) {
        let how = cfg.ipProtocol == .auto ? "auto" : "\(cfg.ipProtocol.rawValue) only"
        emit(.log(level: 4, "engine: account \(cfg.uri): \(family) (\(how), server \(IPFamilyPolicy.firstHop(of: cfg).host))"))
    }

    /// The registrar holds a binding of the account (last REGISTER answered 2xx).
    func hasBinding(_ id: AccountID) -> Bool {
        if case .registered = bridge.registration(of: id) { return true }
        return false
    }

    /// The account has a call in any state (ringing, connecting, connected, held).
    func accountHasCalls(_ index: pjsua_acc_id) -> Bool {
        CallSnapshot.allSlots().contains { slot in
            guard let snap = CallSnapshot.read(slot) else { return false }
            return snap.accIndex == index && snap.state != .disconnected
        }
    }

    /// Sends the un-REGISTER of the account's current binding (Expires 0 on the old family) and marks
    /// its result as no state of the account (the session is destroyed by the move right after, which
    /// keeps the request going but drops its callback).
    func unregisterBeforeMove(_ entry: AccountEntry) {
        bridge.setIgnoringUnregister(entry.index, true)
        PJ.warn(pjsua_acc_set_registration(entry.index, 0), "account \(entry.config.uri): un-REGISTER before the move")
    }

    /// Moves the account to `family`'s transport: the old binding is un-REGISTERed, the account is
    /// `pjsua_acc_modify`d without a REGISTER (`disable_reg_on_modify`), `allow_sdp_nat_rewrite` is set
    /// (pjsua_acc_modify does not copy it), the MWI and presence subscriptions are made anew (their
    /// dialogs keep the old transport), and the registrar's INVITEs are trusted again only after it
    /// accepted a REGISTER. `register`: send that REGISTER now (outside a network-change round, which
    /// registers the account itself). An account with a call is not moved: the move waits for the
    /// calls to end (`runDeferredMoves`). Returns true when the account moved.
    @discardableResult
    func moveAccount(_ id: AccountID, to family: IPFamily, reason: String, register: Bool) -> Bool {
        guard isStarted, PJ.registerThread(), var entry = accounts[id] else { return false }
        guard entry.family != family else {
            entry.pendingMove = nil
            accounts[id] = entry
            return false
        }
        if accountHasCalls(entry.index) {
            if entry.pendingMove?.family != family {
                emit(.log(level: 3, "engine: account \(entry.config.uri): move to \(family) (\(reason)) waits for its calls"))
            }
            entry.pendingMove = (family, reason)
            accounts[id] = entry
            return false
        }
        let settings: PJAccountSettings
        do {
            settings = try accountSettings(entry.config, password: entry.password, family: family)
        } catch {
            PJ.warn(error, "account \(entry.config.uri): move to \(family)")
            return false
        }
        let unregisterFirst = hasBinding(id)
        if unregisterFirst { unregisterBeforeMove(entry) }
        defer { if unregisterFirst { bridge.setIgnoringUnregister(entry.index, false) } }
        do {
            try AccountMapping.withPJConfig(settings) { p in
                p.pointee.disable_reg_on_modify = 1
                try PJ.check(pjsua_acc_modify(entry.index, p), "pjsua_acc_modify")
            }
        } catch {
            PJ.warn(error, "account \(entry.config.uri): move to \(family)")
            return false
        }
        cpjsua_acc_set_sdp_nat_rewrite(entry.index, settings.sdpNATRewrite ? 1 : 0)
        cpjsua_acc_end_mwi_after_move(entry.index)
        emit(.log(level: 3, "engine: account \(entry.config.uri): server now reached over \(family) "
                 + "(was \(entry.family), \(reason))"))
        entry.family = family
        entry.pendingMove = nil
        accounts[id] = entry
        bridge.setRegistrarSource(entry.index, nil)
        resubscribePresence(accountIndex: entry.index)
        if register, entry.wantsRegistration, !sleeping, networkStatus == .online, ipChange == nil {
            do { try applyRegistration(id, true) } catch { PJ.warn(error, "account \(entry.config.uri): REGISTER after the move") }
        }
        return true
    }

    /// Decides the family of Auto accounts with a host name again (network change, REGISTER retry,
    /// IPv6 appearing) and moves those whose family changed. Each host is looked up once, all of them
    /// together within `familyLookupTimeout`; an account whose lookup failed or did not finish keeps
    /// its family (during a network change DNS often fails for a moment). Sticky accounts (Auto moved
    /// them after a REGISTER got no answer) are left alone; the caller clears that at a network change.
    func refreshAccountFamilies(_ ids: [AccountID], reason: String, register: Bool) {
        guard isStarted, PJ.registerThread() else { return }
        let srv = srvInEffect
        let candidates = ids.compactMap { id -> (AccountID, AccountEntry, String)? in
            guard let entry = accounts[id], !entry.familySticky,
                  IPFamilyPolicy.followsResolver(entry.config, srv: srv) else { return nil }
            return (id, entry, IPFamilyPolicy.firstHop(of: entry.config).host)
        }
        guard !candidates.isEmpty else { return }
        let resolved = lookupFamilies(candidates.map(\.2))
        for (id, entry, host) in candidates {
            guard let families = resolved[host], !families.isEmpty else { continue }
            let family = IPFamilyPolicy.decide(entry.config, available: transports.families(for: entry.config),
                                               srv: srv) { _ in families }
            moveAccount(id, to: family, reason: reason, register: register)
        }
    }

    /// Moves that waited for an account's calls, once its calls have ended (watchdog tick).
    func runDeferredMoves() {
        guard isStarted, ipChange == nil else { return }
        for (id, entry) in accounts {
            guard let move = entry.pendingMove, !accountHasCalls(entry.index) else { continue }
            accounts[id]?.pendingMove = nil
            moveAccount(id, to: move.family, reason: "\(move.reason), after the calls ended", register: true)
        }
    }

    /// Presence subscriptions of buddies watched through this account, anew (after a move).
    func resubscribePresence(accountIndex index: pjsua_acc_id) {
        guard isStarted, PJ.registerThread() else { return }
        for (key, buddy) in buddies.sorted(by: { $0.key < $1.key }) {
            let account = key.withCString { p -> pjsua_acc_id in
                var uri = cpjsua_str(p)
                return pjsua_acc_find_for_outgoing(&uri)
            }
            guard account == index else { continue }
            PJ.warn(cpjsua_buddy_resubscribe(buddy.id), "resubscribe presence of \(key)")
        }
    }

    // MARK: test hooks

    func transportIDsForTests() -> TransportIDs { transports }

    func accountFamilyForTests(_ id: AccountID) -> IPFamily? { accounts[id]?.family }

    func setFamilyResolverForTests(_ resolve: @escaping @Sendable (String) -> [IPFamily]) {
        resolveFamilies = resolve
    }

    func setFamilyLookupTimeoutForTests(_ limit: Duration) {
        familyLookupTimeout = limit
    }

    func setIPv6AddressAssignedForTests(_ assigned: @escaping @Sendable (String) -> Bool) {
        ipv6AddressAssigned = assigned
    }

    /// The account's pjsua_acc_config as pjsua holds it now (pjsua_acc_get_config).
    func liveAccountSettingsForTests(_ id: AccountID) -> PJAccountSettings? {
        guard isStarted, PJ.registerThread(), let entry = accounts[id],
              let pool = pjsua_pool_create("acc-read", 1024, 1024) else { return nil }
        defer { pj_pool_release(pool) }
        let cfg = UnsafeMutablePointer<pjsua_acc_config>.allocate(capacity: 1)
        cfg.initialize(to: pjsua_acc_config())
        defer {
            cfg.deinitialize(count: 1)
            cfg.deallocate()
        }
        guard pjsua_acc_get_config(entry.index, pool, cfg) == PJ.success else { return nil }
        return AccountMapping.readBack(cfg)
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
