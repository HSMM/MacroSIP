internal import CPJSUA
import Foundation

// The IP family of accounts (docs/ENGINE.md "IPv6"): the decision, lookups of host names, and the one
// reconciler that moves accounts between the IPv4 and IPv6 transports. Triggers (a network change,
// IPv6 coming or going, a lookup answer, a REGISTER without any answer, a changed IP protocol) only
// record `AccountEntry.desired`; `reconcileFamilies` alone moves an account, when nothing can be hurt
// by it: no network-change round running, no call on the account, no REGISTER in flight.

/// The family an account should be moved to, recorded for the settings of `generation`.
struct FamilyDesire: Sendable, Equatable {
    var family: IPFamily
    var reason: String
    var generation: UInt64
}

extension Engine {
    /// The first REGISTER of an account whose family depends on a running lookup waits this long at most.
    static let lookupWait: Duration = .seconds(2)
    /// A move waits this long for the answer to the old binding's un-REGISTER, then goes on.
    static let moveUnregisterTimeout: Duration = .seconds(5)

    /// DNS SRV is in effect: pjsua has a resolver and looks up SRV records of hosts without a port.
    var srvInEffect: Bool { !dnsServers.isEmpty }

    // MARK: - decision

    /// The account's family now, without waiting: a literal, a fixed protocol, the only family with a
    /// transport, the SRV case, or a cached lookup decide at once; otherwise a lookup is started
    /// (`lookupStarted`) and the answer is `provisional` (an existing account keeps its family) or what
    /// an unresolved name gives (IPv4). Throws `.invalidArgument` when IPv4 only or IPv6 only
    /// contradicts the server's IP literal: such an account could never register.
    func decideFamily(_ cfg: AccountConfig, provisional: IPFamily? = nil) throws -> (family: IPFamily, lookupStarted: Bool) {
        let host = IPFamilyPolicy.firstHop(of: cfg).host
        if let literal = IPFamilyPolicy.conflict(in: cfg) {
            throw EngineError.invalidArgument("server \(host) is an \(literal) address but the account is set to "
                                              + "\(literal == .ipv6 ? "IPv4" : "IPv6") only")
        }
        let cached = familyLookups.cached(host)
        var needed = false
        let family = IPFamilyPolicy.decide(cfg, available: transports.families(for: cfg), srv: srvInEffect) { _ in
            if let cached { return cached }
            needed = true
            return []
        }
        guard needed else { return (family, false) }
        startLookup(host)
        return (provisional ?? family, true)
    }

    func logFamily(_ cfg: AccountConfig, _ family: IPFamily) {
        let how = cfg.ipProtocol == .auto ? "auto" : "\(cfg.ipProtocol.rawValue) only"
        emit(.log(level: 4, "engine: account \(cfg.uri): \(family) (\(how), server \(IPFamilyPolicy.firstHop(of: cfg).host))"))
    }

    // MARK: - lookups

    /// A lookup of `host` off the engine queue (one in flight per host); the answer comes back through
    /// `familiesResolved`.
    func startLookup(_ host: String) {
        familyLookups.start(host, resolve: resolveFamilies) { [weak self] host, families in
            Task { await self?.familiesResolved(host, families) }
        }
    }

    /// A lookup answered: accounts of that host that wait for it record what it means (a desired family,
    /// or the fallback it allows), and the reconciler runs. A failed lookup ([]) changes no family.
    func familiesResolved(_ host: String, _ families: [IPFamily]) {
        guard isStarted, PJ.registerThread() else { return }
        let srv = srvInEffect
        for id in Array(accounts.keys) {
            guard var entry = accounts[id], IPFamilyPolicy.firstHop(of: entry.config).host == host else { continue }
            if entry.registerDeadline != nil { entry.registerDeadline = .now }     // answered: no more waiting
            let other = entry.family.other
            if entry.fallbackWaitsForLookup {
                entry.fallbackWaitsForLookup = false
                if families.contains(other) { wantFallback(&entry, to: other) }
            } else if !entry.familySticky, !families.isEmpty, IPFamilyPolicy.followsResolver(entry.config, srv: srv) {
                let decided = IPFamilyPolicy.decide(entry.config, available: transports.families(for: entry.config),
                                                    srv: srv) { _ in families }
                entry.desired = decided == entry.family ? nil
                    : FamilyDesire(family: decided, reason: "\(host) resolves to \(decided) first", generation: entry.generation)
            }
            accounts[id] = entry
        }
        reconcileFamilies()
    }

    // MARK: - triggers

    /// A network change (a round, or IPv6 coming or going): earlier answers no longer hold. Lookups are
    /// dropped and made again, and every Auto account follows the system's order again: a family Auto
    /// fell back to is forgotten, also in the DNS SRV case (back to IPv4 first). `abortMoves`: a round
    /// re-registers every account, so a move whose un-REGISTER was sent starts again after it.
    func familiesNetworkChanged(abortMoves: Bool) {
        familyLookups.invalidate()
        let srv = srvInEffect
        for id in Array(accounts.keys) {
            guard var entry = accounts[id] else { continue }
            if abortMoves, entry.moveUnregisterSent != nil {
                entry.moveUnregisterSent = nil
                entry.moveUnregisterAnswered = false
            }
            entry.familyFallbackTried = false
            entry.fallbackWaitsForLookup = false
            let wasSticky = entry.familySticky
            entry.familySticky = false
            let hop = IPFamilyPolicy.firstHop(of: entry.config)
            if IPFamilyPolicy.followsResolver(entry.config, srv: srv) {
                entry.desired = nil                     // the new lookup decides
                startLookup(hop.host)
            } else if wasSticky {
                // The SRV case: the order is IPv4 first, whatever Auto fell back to.
                let decided = IPFamilyPolicy.decide(entry.config, available: transports.families(for: entry.config),
                                                    srv: srv) { _ in [] }
                entry.desired = decided == entry.family ? nil
                    : FamilyDesire(family: decided, reason: "network change", generation: entry.generation)
            }
            accounts[id] = entry
        }
    }

    /// A REGISTER failed temporarily (`.reconnecting` is out); the backoff retry is scheduled. When it
    /// got no answer at all (`noAnswer`: no response, i.e. a timeout, a refused or broken connection, no
    /// address of the bound family), an Auto account with a host name wants the other family at once:
    /// when the host has an address of it (a cached or a fresh lookup), or DNS SRV is in effect (the SRV
    /// targets are unknown to the engine; the other family is the only chance). Once per series of
    /// failures; the family then stays (`familySticky`) until the next network change. A result of
    /// settings that changed meanwhile (`generation`) is not acted on.
    func registrationRetryNeeded(_ id: AccountID, attempt: Int, after delay: TimeInterval, noAnswer: Bool,
                                 generation: UInt64) {
        scheduleRegistrationRetry(id, attempt: attempt, after: delay)
        guard noAnswer, var entry = accounts[id], entry.generation == generation, entry.wantsRegistration,
              !entry.familyFallbackTried, entry.config.ipProtocol == .auto else { return }
        let hop = IPFamilyPolicy.firstHop(of: entry.config)
        let other = entry.family.other
        guard !hop.host.isEmpty, IPFamilyPolicy.literalFamily(hop.host) == nil,
              transports.id(for: entry.config, family: other) != nil else { return }
        entry.familyFallbackTried = true
        if srvInEffect && hop.port == nil {
            wantFallback(&entry, to: other)
        } else if let cached = familyLookups.cached(hop.host) {
            if cached.contains(other) { wantFallback(&entry, to: other) }
        } else {
            entry.fallbackWaitsForLookup = true
            startLookup(hop.host)
        }
        accounts[id] = entry
        reconcileFamilies()
    }

    private func wantFallback(_ entry: inout AccountEntry, to other: IPFamily) {
        emit(.log(level: 3, "engine: account \(entry.config.uri): no answer over \(entry.family); trying \(other)"))
        entry.familySticky = true
        entry.desired = FamilyDesire(family: other, reason: "no answer over \(entry.family)", generation: entry.generation)
    }

    // MARK: - the reconciler

    /// Brings every account to its desired family, one step at a time; runs on the watchdog tick and
    /// right after the events that matter (a desire recorded, a lookup answered, an un-REGISTER
    /// answered, a round finished). A move starts only when no round runs, the account has no call in
    /// any state and no REGISTER of it is in flight; it un-REGISTERs the old binding and waits for the
    /// answer (at most `moveUnregisterTimeout`) before it moves and registers anew (`finishMove`). The
    /// account shows `.registering` from the start of the move until the new REGISTER is answered.
    func reconcileFamilies() {
        guard isStarted, PJ.registerThread(), ipChange == nil, !sleeping, networkStatus == .online else { return }
        let now = ContinuousClock.now
        for id in Array(accounts.keys) {
            guard let entry = accounts[id] else { continue }
            if let sent = entry.moveUnregisterSent {
                if entry.moveUnregisterAnswered || now - sent >= Engine.moveUnregisterTimeout { finishMove(id) }
                continue
            }
            if let deadline = entry.registerDeadline, now < deadline { continue }
            if let desired = entry.desired, desired.generation == entry.generation, desired.family != entry.family {
                if !accountHasCalls(entry.index), !registrationBusy(entry) {
                    startMove(id)
                    continue
                }
            } else if entry.desired != nil {
                accounts[id]?.desired = nil
            }
            if entry.registerDeadline != nil {
                // No (usable) answer in time, or the move has to wait: register where the account is.
                accounts[id]?.registerDeadline = nil
                if entry.wantsRegistration { register(id) }
            }
        }
    }

    /// A REGISTER or un-REGISTER of the account is in flight, or a request waits for one to end.
    private func registrationBusy(_ entry: AccountEntry) -> Bool {
        cpjsua_acc_reg_busy(entry.index) != 0 || bridge.pendingRegistration(entry.config.id) != nil
    }

    private func startMove(_ id: AccountID) {
        guard let entry = accounts[id], let desired = entry.desired else { return }
        cancelRegistrationRetry(id)
        accounts[id]?.registerDeadline = nil
        guard hasBinding(id) else {
            finishMove(id)
            return
        }
        // The old binding must not stay at the registrar: a second Contact makes Kamailio fork calls,
        // and Asterisk with max_contacts=1 and remove_existing=no refuses the new one with 403.
        emit(.log(level: 3, "engine: account \(entry.config.uri): moving to \(desired.family) (\(desired.reason)); "
                 + "un-REGISTER over \(entry.family) first"))
        bridge.setRegistration(id, .registering)
        accounts[id]?.moveUnregisterSent = .now
        accounts[id]?.moveUnregisterAnswered = false
        if pjsua_acc_set_registration(entry.index, 0) != PJ.success { finishMove(id) }
    }

    /// The answer to an un-REGISTER of an account that should stay registered (pjOnRegState2): the
    /// move goes on. Outside a move, a registration requested meanwhile (PJSIP_EBUSY) is sent now.
    func unregisterAnswered(_ id: AccountID, pendingOn: Bool) {
        guard isStarted, PJ.registerThread(), accounts[id] != nil else { return }
        if accounts[id]?.moveUnregisterSent != nil {
            accounts[id]?.moveUnregisterAnswered = true
            reconcileFamilies()
        } else if pendingOn {
            applyPendingRegistration(id, true)
        }
    }

    /// Moves the account to its desired family (the old binding is gone or given up on): the old
    /// registration session is destroyed with `pjsua_acc_modify` (a late answer of it is dropped), the
    /// live config gets `allow_sdp_nat_rewrite` (pjsua_acc_modify does not copy it), the MWI and
    /// presence subscriptions are made anew on the new transport (their dialogs keep the old one), and
    /// the account registers. A failure keeps the desire: the next tick tries again. A move that is no
    /// longer wanted registers the account where it is.
    private func finishMove(_ id: AccountID) {
        guard var entry = accounts[id] else { return }
        entry.moveUnregisterSent = nil
        entry.moveUnregisterAnswered = false
        guard let desired = entry.desired, desired.generation == entry.generation, desired.family != entry.family else {
            entry.desired = nil
            accounts[id] = entry
            if entry.wantsRegistration { register(id) }
            return
        }
        do {
            let settings = try accountSettings(entry.config, password: entry.password, family: desired.family)
            try AccountMapping.withPJConfig(settings) { p in
                p.pointee.disable_reg_on_modify = 1
                try PJ.check(pjsua_acc_modify(entry.index, p), "pjsua_acc_modify")
            }
            cpjsua_acc_set_sdp_nat_rewrite(entry.index, settings.sdpNATRewrite ? 1 : 0)
        } catch {
            PJ.warn(error, "account \(entry.config.uri): move to \(desired.family)")
            accounts[id] = entry
            return
        }
        cpjsua_acc_end_mwi_after_move(entry.index)
        emit(.log(level: 3, "engine: account \(entry.config.uri): server now reached over \(desired.family) "
                 + "(was \(entry.family), \(desired.reason))"))
        entry.family = desired.family
        entry.desired = nil
        entry.generation &+= 1
        accounts[id] = entry
        bridge.setAccountGeneration(entry.index, entry.generation)
        bridge.setRegistrarSource(entry.index, nil)
        resubscribePresence(accountIndex: entry.index)
        if entry.wantsRegistration { register(id) }
    }

    /// REGISTER now, shown as `.registering` until the answer.
    private func register(_ id: AccountID) {
        bridge.setRegistration(id, .registering)
        do { try applyRegistration(id, true) } catch { PJ.warn(error, "register") }
    }

    // MARK: - helpers

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

    // MARK: - test hooks

    func transportIDsForTests() -> TransportIDs { transports }

    func accountFamilyForTests(_ id: AccountID) -> IPFamily? { accounts[id]?.family }

    func setFamilyResolverForTests(_ resolve: @escaping @Sendable (String) -> [IPFamily]) {
        resolveFamilies = resolve
        familyLookups.invalidate()
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
}

extension IPFamily {
    var other: IPFamily { self == .ipv4 ? .ipv6 : .ipv4 }
}
