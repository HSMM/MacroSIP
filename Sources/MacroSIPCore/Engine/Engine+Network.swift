internal import CPJSUA
import Foundation

// Network resilience (docs/ENGINE.md "Network resilience"): path monitoring, IP change
// handling with re-REGISTER and re-INVITE, REGISTER retry with backoff, the media watchdog,
// sleep and wake.

extension Engine {
    /// `.callEnded` reason of a call whose media did not come back: `.disconnected(code: 0,
    /// reason: "connection lost")` (the far end lost the dialog: 481, or no answer to the
    /// re-INVITE after a network change or to the watchdog's OPTIONS probe).
    public static let connectionLostReason = "connection lost"

    /// The path an engine without a network monitor reports (`Engine(monitorNetwork: false)`).
    static let unmonitoredPath = NetworkPath(satisfied: true, interface: "lo0", address: "127.0.0.1", gateway: "",
                                             summary: "network not monitored (assumed online)")

    /// Path updates closer together than this are handled once, with the last path.
    static let pathDebounce: Duration = .milliseconds(2500)
    /// pjsua_handle_ip_change: delay before a failed listener restart is tried again (ms).
    static let listenerRestartDelayMs: UInt32 = 100
    /// A change that only waits for a ringing outgoing call runs anyway after this.
    static let postponeLimit: Duration = .seconds(90)

    /// A request for a network-change round.
    struct IPChangeRequest {
        var reason: String
        /// Also re-register accounts whose registration failed permanently (wake).
        var registerFailed: Bool
        /// The local address or interface changed: run at once even while an outgoing call
        /// rings (it cannot survive anyway). Otherwise the round waits for the call.
        var primary: Bool
        var since: ContinuousClock.Instant = .now

        func merged(with newer: IPChangeRequest) -> IPChangeRequest {
            IPChangeRequest(reason: newer.reason, registerFailed: registerFailed || newer.registerFailed,
                            primary: primary || newer.primary, since: since)
        }
    }

    /// One `pjsua_handle_ip_change` run. Rounds never overlap.
    struct IPChange {
        var round: UInt64
        /// Confirmed calls when it started: each gets a re-INVITE (from pjsua after its
        /// account's re-REGISTER, or from the engine when pjsua did not send one).
        var calls: [CallID]
        /// pjsua account indices asked to re-REGISTER whose answer has not come yet.
        var accountsPending: Set<Int32>
    }

    /// Per-call RTP/RTCP counters for the media watchdog (ContinuousClock: Date jumps).
    struct MediaWatch {
        var rx: Int
        var rtcp: Int
        var rxChanged: ContinuousClock.Instant
        var rtcpChanged: ContinuousClock.Instant
        var activityChanged: ContinuousClock.Instant
        /// At least one RTCP report arrived on this stream: only then can silence end it.
        var rtcpSeen = false
    }

    // MARK: - public API

    /// `.online` until the first path evaluation after `start` says otherwise.
    public func networkState() -> NetworkState {
        networkStatus
    }

    /// For NSWorkspace.didWakeNotification: evaluates the network path afresh and, when
    /// online, re-registers every account that should be registered (also failed ones,
    /// regardless of the retry backoff) and re-INVITEs the calls. Offline: that happens
    /// when the path comes back.
    public func handleWake() {
        guard isStarted, PJ.registerThread() else { return }
        emit(.log(level: 3, "engine: wake: checking the network, re-registering"))
        sleeping = false
        cancelRegistrationRetries()
        bridge.resetAllRetryAttempts()
        let now = ContinuousClock.now
        for key in Array(mediaWatch.keys) {
            mediaWatch[key]?.rxChanged = now
            mediaWatch[key]?.rtcpChanged = now
            mediaWatch[key]?.activityChanged = now
        }
        lastNetworkEvent = now
        wakePending = true
        startPathMonitor()
        if !monitorNetwork {
            // The fresh evaluation is the path last applied (tests may have injected offline).
            evaluatePath(lastEvaluatedPath ?? Engine.unmonitoredPath)
            return
        }
        let generation = pathGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.wakeFallback(generation)
        }
    }

    /// For NSWorkspace.willSleepNotification: un-REGISTERs every registered account
    /// (Expires 0) so the PBX stops sending calls to a sleeping Mac. Accounts stay
    /// configured and are registered again by `handleWake`. Calls are left alone.
    public func handleSleep() {
        guard isStarted, PJ.registerThread() else { return }
        sleeping = true
        wakePending = false
        pathDebounce?.cancel()
        pathDebounce = nil
        postponedIPChange = nil
        cancelRegistrationRetries()
        bridge.resetAllRetryAttempts()
        var count = 0
        for (id, entry) in accounts where entry.wantsRegistration {
            if bridge.registration(of: id) == .unregistered && bridge.pendingRegistration(id) == nil { continue }
            do {
                try applyRegistration(id, false)
                count += 1
            } catch {
                PJ.warn(error, "account \(entry.config.uri): un-REGISTER before sleep")
            }
        }
        emit(.log(level: 3, "engine: sleep: un-REGISTERed \(count) account(s)"))
    }

    /// Test hook: handles the path as changed with a new local address (listener restart,
    /// re-REGISTER, re-INVITE), exactly as after a real change while online, so it does not
    /// wait for a ringing outgoing call. No effect while offline or asleep.
    public func simulateNetworkChange() {
        guard isStarted else { return }
        emit(.log(level: 3, "engine: simulated network change"))
        guard networkStatus == .online, !sleeping else { return }
        requestIPChange(IPChangeRequest(reason: "simulated", registerFailed: false, primary: true))
    }

    // MARK: - path monitoring

    func startNetworkMonitoring() {
        networkStatus = .online
        networkAnnounced = false
        handledPath = nil
        lastEvaluatedPath = nil
        lastNetworkEvent = nil
        sleeping = false
        wakePending = false
        bridge.setOnline(true)
        startPathMonitor()
        startWatchdog()
        if !monitorNetwork {
            // No real monitor: the fixed online path is applied right here (not through the
            // stream), so nothing can report "online" later on its own.
            evaluatePath(Engine.unmonitoredPath)
            return
        }
        let generation = pathGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.announceIfSilent(generation)
        }
    }

    func stopNetworkMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
        pathConsumer?.cancel()
        pathConsumer = nil
        pathGeneration += 1
        pathDebounce?.cancel()
        pathDebounce = nil
        pendingPath = nil
        watchdog?.cancel()
        watchdog = nil
        ipChangeTimer?.cancel()
        ipChangeTimer = nil
        ipChange = nil
        queuedIPChange = nil
        postponedIPChange = nil
        cancelRegistrationRetries()
        cancelReinviteTasks()
        mediaWatch = [:]
        reinviteAttempts = [:]
        reinviteSince = [:]
        networkStatus = .online
        networkAnnounced = false
        sleeping = false
        wakePending = false
    }

    /// A new NWPathMonitor; its updates are applied strictly in order by one consumer.
    func startPathMonitor() {
        pathMonitor?.cancel()
        pathConsumer?.cancel()
        pathGeneration += 1
        let generation = pathGeneration
        let monitor = NetworkPathMonitor(live: monitorNetwork)
        pathMonitor = monitor
        pathConsumer = Task { [weak self] in
            for await path in monitor.paths {
                guard let self else { return }
                await self.pathUpdated(path, generation: generation)
            }
        }
    }

    func pathUpdated(_ path: NetworkPath, generation: UInt64) {
        guard isStarted, generation == pathGeneration else { return }
        // The first evaluation after start and every one while a wake is pending are applied
        // at once (in order); later ones are debounced (an interface change is a burst).
        if !networkAnnounced || wakePending {
            pathDebounce?.cancel()
            pathDebounce = nil
            pendingPath = nil
            evaluatePath(path)
            return
        }
        pendingPath = path
        pathDebounce?.cancel()
        pathDebounce = Task { [weak self] in
            try? await Task.sleep(for: Engine.pathDebounce)
            guard !Task.isCancelled else { return }
            await self?.debouncedPathFired(generation)
        }
    }

    private func debouncedPathFired(_ generation: UInt64) {
        guard generation == pathGeneration else { return }
        pathDebounce = nil
        guard let path = pendingPath else { return }
        pendingPath = nil
        evaluatePath(path)
    }

    /// Applies a path: announces online/offline changes, and while online starts a round
    /// when the primary route changed (or after offline or wake). Secondary interfaces
    /// coming and going change nothing.
    func evaluatePath(_ path: NetworkPath) {
        // Reached from the path consumer task after a suspension: the actor may resume on a
        // GCD thread pjlib does not know yet (requestIPChange/refreshReconnecting call pjsua).
        guard isStarted, PJ.registerThread() else { return }
        lastEvaluatedPath = path
        let new: NetworkState = path.satisfied ? .online : .offline
        let old = networkStatus
        let first = !networkAnnounced
        let wake = wakePending
        if new == .online { wakePending = false }   // offline at wake: keep waiting for the network
        if first || new != old {
            networkStatus = new
            networkAnnounced = true
            bridge.setOnline(new == .online)
            if !first { lastNetworkEvent = .now }
            emit(.log(level: 3, "engine: network \(new == .online ? "online" : "offline"): \(path.summary)"))
            emit(.network(new))
        }
        defer { refreshReconnecting() }
        guard new == .online else { return }
        let previous = handledPath
        var path = path
        if path.address.isEmpty {
            // Satisfied but no default route (the 192.0.2.1 lookup failed: a host without a
            // default route, or a moment during a change): keep the address we had and treat
            // it as unchanged rather than as a new primary route.
            let kept = previous?.address ?? ""
            emit(.log(level: 3, "engine: network path without a default route; keeping address \(kept.isEmpty ? "unknown" : kept)"))
            path.address = kept
        }
        handledPath = path
        guard !sleeping, !first else { return }
        if previous.map({ path.routeDiffers(from: $0) }) ?? true || old == .offline || wake {
            refreshSystemNameservers()
        }
        let primary = previous.map { path.primaryDiffers(from: $0) } ?? true
        if wake {
            requestIPChange(IPChangeRequest(reason: "wake", registerFailed: true, primary: primary))
        } else if old == .offline {
            requestIPChange(IPChangeRequest(reason: "network back", registerFailed: false, primary: primary))
        } else if let previous, path.routeDiffers(from: previous) {
            emit(.log(level: 3, "engine: network route changed: \(previous.summary) -> \(path.summary)"))
            requestIPChange(IPChangeRequest(reason: "route changed", registerFailed: false, primary: primary))
        }
    }

    private func announceIfSilent(_ generation: UInt64) {
        guard isStarted, generation == pathGeneration, !networkAnnounced else { return }
        networkAnnounced = true
        emit(.log(level: 2, "engine: no network path report; assuming online"))
        emit(.network(networkStatus))
    }

    private func wakeFallback(_ generation: UInt64) {
        guard isStarted, generation == pathGeneration, wakePending, !sleeping, networkStatus == .online else { return }
        wakePending = false
        emit(.log(level: 2, "engine: wake: no network path report; re-registering anyway"))
        requestIPChange(IPChangeRequest(reason: "wake", registerFailed: true, primary: false))
    }

    /// Tests: applies this path at once, as if NWPathMonitor reported it (no debounce).
    func applyPathForTests(_ path: NetworkPath) {
        evaluatePath(path)
    }

    /// Tests: feeds a path through the monitor's ordered stream (debounced like a real one).
    func injectPathForTests(_ path: NetworkPath) {
        pathMonitor?.inject(path)
    }

    // MARK: - IP change rounds

    /// Starts a round now, or queues it behind the running one, or postpones it while an
    /// outgoing call rings and the local address did not change.
    func requestIPChange(_ request: IPChangeRequest) {
        guard isStarted, PJ.registerThread() else { return }
        lastNetworkEvent = .now
        if ipChange != nil {
            queuedIPChange = queuedIPChange.map { $0.merged(with: request) } ?? request
            emit(.log(level: 3, "engine: network change (\(request.reason)) queued behind round \(ipChangeRound)"))
            return
        }
        var request = postponedIPChange.map { $0.merged(with: request) } ?? request
        if !request.primary, outgoingCallRinging(), ContinuousClock.now - request.since < Engine.postponeLimit {
            if postponedIPChange == nil {
                emit(.log(level: 3, "engine: network change (\(request.reason)) waits for the ringing outgoing call"))
            }
            postponedIPChange = request
            return
        }
        postponedIPChange = nil
        request.since = .now
        performIPChange(request)
    }

    /// An outgoing call that is not answered yet: pjsua hangs those up (410) after an
    /// account's re-REGISTER.
    func outgoingCallRinging() -> Bool {
        guard PJ.registerThread() else { return false }
        return CallSnapshot.allSlots().contains { slot in
            guard let snap = CallSnapshot.read(slot), snap.isOutgoing else { return false }
            return [.null, .calling, .early, .connecting].contains(snap.state)
        }
    }

    /// pjsua_handle_ip_change: TCP/TLS connections closed, listeners restarted (only when
    /// bound to all interfaces: a restart rebinds to 0.0.0.0, which would undo
    /// `bindAddress`), accounts that should be registered re-REGISTER (new Contact), then
    /// pjsua re-INVITEs their confirmed calls (REINIT_MEDIA | UPDATE_CONTACT | UPDATE_VIA)
    /// and hangs up their unconfirmed outgoing calls (410). Calls pjsua leaves out are
    /// re-INVITEd by the engine when pjsua reports completion.
    func performIPChange(_ request: IPChangeRequest) {
        guard isStarted, PJ.registerThread(), ipChange == nil else { return }
        ipChangeRound += 1
        let round = ipChangeRound
        bridge.beginIPChangeRound(round)
        cancelReinviteTasks()
        reinviteAttempts = [:]

        var calls: [CallID] = []
        let now = ContinuousClock.now
        for slot in CallSnapshot.allSlots() {
            guard let snap = CallSnapshot.read(slot), snap.state == .confirmed,
                  let rec = bridge.record(slot), rec.serial == snap.serial else { continue }
            let id = CallID(raw: slot, serial: rec.serial)
            calls.append(id)
            if !rec.reinvitePending { reinviteSince[id] = now }
            bridge.updateCall(snap, mode: .updateOnly, mutate: { $0.reinviteWanted = round })
        }

        var pending: Set<Int32> = []
        for (id, entry) in accounts {
            let state = bridge.registration(of: id)
            var again = entry.wantsRegistration && !sleeping
            if case .failed = state, !request.registerFailed { again = false }
            if again { pending.insert(entry.index) }
            cpjsua_acc_prepare_ip_change(entry.index, again ? 1 : 0)
        }
        ipChange = IPChange(round: round, calls: calls, accountsPending: pending)
        emit(.log(level: 3, "engine: network change (\(request.reason)), round \(round): re-REGISTER "
                 + "\(pending.count) account(s), re-INVITE \(calls.count) call(s)"))
        // Set before pjsua sees it, so pjsua does not schedule its own timer that clears it
        // one transaction timeout later (our re-INVITEs may still be running then).
        setKeepInvAfterTimeout(true)
        refreshReconnecting()

        let status = cpjsua_handle_ip_change(bindAddress == nil ? 1 : 0, Engine.listenerRestartDelayMs, 1)
        if status != PJ.success {
            PJ.warn(status, "pjsua_handle_ip_change")
            ipChangeCompleted(round: round)
            return
        }
        // Safety net: pjsua completes after the slowest REGISTER (at most one transaction
        // timeout); never wrap up earlier, a late completion would close the next round.
        ipChangeTimer?.cancel()
        let limit = Duration.milliseconds(Int(transactionTimeoutMs) + 5000)
        ipChangeTimer = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            await self?.ipChangeTimedOut(round)
        }
    }

    private func ipChangeTimedOut(_ round: UInt64) {
        guard let change = ipChange, change.round == round else { return }
        emit(.log(level: 2, "engine: network change round \(round): no completion report from pjsua; "
                 + "re-INVITEing the remaining calls"))
        ipChangeCompleted(round: round)
    }

    /// pjsua answered the re-REGISTER of an account in this round.
    func ipChangeAccountAnswered(_ index: Int32, round: UInt64) {
        guard ipChange?.round == round else { return }
        ipChange?.accountsPending.remove(index)
    }

    /// pjsua finished the round (PJSUA_IP_CHANGE_OP_COMPLETED): re-INVITE the calls it did
    /// not re-INVITE itself, then run a queued or postponed change.
    func ipChangeCompleted(round: UInt64) {
        guard isStarted, PJ.registerThread(), let change = ipChange, change.round == round else { return }
        ipChange = nil
        ipChangeTimer?.cancel()
        ipChangeTimer = nil
        let byPJSUA = bridge.ipChangeReinvited()
        var own = 0
        for id in change.calls where !byPJSUA.contains(id.serial) {
            // Its account's REGISTER is still running: pjsua re-INVITEs it after the answer;
            // a second re-INVITE now would reinitialise the media twice.
            if let snap = CallSnapshot.read(id.raw), snap.serial == id.serial,
               change.accountsPending.contains(snap.accIndex) { continue }
            own += 1
            sendIPChangeReinvite(id)
        }
        emit(.log(level: 3, "engine: network change round \(round) handled: \(change.calls.count - own) call(s) "
                 + "left to pjsua, \(own) re-INVITEd by the engine"))
        refreshReconnecting()
        if let next = queuedIPChange {
            queuedIPChange = nil
            requestIPChange(next)
        }
    }

    /// Re-INVITE with a new media transport, Contact and Via for the round the call wants.
    /// A transaction in flight (hold, the remote's re-INVITE, an older round's re-INVITE) is
    /// waited for in 250 ms steps for up to one transaction timeout.
    func sendIPChangeReinvite(_ id: CallID, busyTries: Int = 0) {
        reinviteTasks[id] = nil
        guard isStarted, PJ.registerThread(), let slot = try? liveSlot(id),
              let snap = CallSnapshot.read(slot), snap.state == .confirmed,
              let rec = bridge.record(slot), let round = rec.reinviteWanted else { return }
        guard networkStatus == .online, !sleeping else { return }   // the next change sends it
        let previous = rec.reinviteInFlight
        // Marked before the call: the answer can arrive (loopback) before pjsua returns.
        bridge.updateCall(snap, mode: .updateOnly, mutate: { $0.reinviteInFlight = round })
        let status = cpjsua_call_reinvite_ip_change(slot)
        if status == PJ.success {
            emit(.log(level: 3, "engine: call \(id): re-INVITE after network change sent"))
            return
        }
        bridge.updateCall(snap, mode: .updateOnly, mutate: { $0.reinviteInFlight = previous })
        let maxTries = max(4, Int(transactionTimeoutMs) / 250)
        if isInviteBusy(status, slot), busyTries < maxTries {
            scheduleReinvite(id, after: .milliseconds(250), busyTries: busyTries + 1)
            return
        }
        PJ.warn(status, "call \(id): re-INVITE after network change")
        reinviteDone(id)
    }

    private func scheduleReinvite(_ id: CallID, after delay: Duration, busyTries: Int = 0) {
        reinviteTasks[id]?.cancel()
        reinviteTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.sendIPChangeReinvite(id, busyTries: busyTries)
        }
    }

    func cancelReinviteTasks() {
        for task in reinviteTasks.values { task.cancel() }
        reinviteTasks = [:]
    }

    /// Nothing more to do for this call's re-INVITE.
    private func reinviteDone(_ id: CallID) {
        PJ.registerThread()
        reinviteTasks.removeValue(forKey: id)?.cancel()
        reinviteAttempts[id] = nil
        reinviteSince[id] = nil
        if let snap = CallSnapshot.read(id.raw), snap.serial == id.serial {
            bridge.updateCall(snap, mode: .updateOnly, mutate: {
                $0.reinviteWanted = nil
                $0.reinviteInFlight = nil
            })
        }
        refreshReconnecting()
    }

    /// Final response to an INVITE of a call that needs a re-INVITE after a network change.
    /// `sentRound`: the round of the re-INVITE this answers (nil: not attributable, e.g. a
    /// hold re-INVITE sent before the change).
    func reinviteFinished(_ id: CallID, code: Int, sentRound: UInt64?) {
        guard isStarted, PJ.registerThread(), let slot = try? liveSlot(id),
              let snap = CallSnapshot.read(slot), let rec = bridge.record(slot) else { return }   // 481: PJSIP ended it
        defer { refreshReconnecting() }
        guard let wanted = rec.reinviteWanted else { return }
        guard let sentRound else {
            // An answer that may be pjsua's re-INVITE, reported before pjsua told us it sent it.
            if code / 100 == 2, ipChange?.round == wanted {
                emit(.log(level: 3, "engine: call \(id): media re-established after network change (\(code))"))
                reinviteDone(id)
            }
            return
        }
        if sentRound < wanted {
            // An older round's re-INVITE: whatever it got (even 408), the call needs the
            // current round's one with the current addresses.
            emit(.log(level: 3, "engine: call \(id): re-INVITE of round \(sentRound) answered \(code); "
                     + "sending the one for round \(wanted)"))
            sendIPChangeReinvite(id)
            return
        }
        if code / 100 == 2 {
            emit(.log(level: 3, "engine: call \(id): media re-established after network change (\(code))"))
            reinviteDone(id)
            if mediaWatch[id] != nil {
                let now = ContinuousClock.now
                mediaWatch[id]?.rxChanged = now
                mediaWatch[id]?.rtcpChanged = now
                mediaWatch[id]?.activityChanged = now
            }
            return
        }
        if networkStatus == .offline || sleeping { return }   // the next change sends it again
        if code == 481 || code == 408 {
            endConnectionLost(id, why: "re-INVITE after network change answered \(code)")
            return
        }
        // 491 (both ends re-INVITEd at once), 5xx...: try again a few times, then leave it to
        // the media watchdog. RFC 3261 14.1 after a 491: the dialog's caller waits 2.1-4 s,
        // the callee 0-2 s, so two ends that collided do not collide again.
        let tries = (reinviteAttempts[id] ?? 0) + 1
        reinviteAttempts[id] = tries
        if tries < 5 {
            let delay = snap.isOutgoing ? Double.random(in: 2.1...4) : Double.random(in: 0...2)
            emit(.log(level: 3, "engine: call \(id): re-INVITE after network change answered \(code); "
                     + "retrying in \(String(format: "%.1f", delay)) s"))
            scheduleReinvite(id, after: .milliseconds(Int(delay * 1000)))
        } else {
            bridge.warn("call \(id): re-INVITE after network change answered \(code); giving up")
            reinviteDone(id)
        }
    }

    /// Re-INVITEs that never settle (a server that answers 100 Trying and nothing else, or a
    /// pjsua re-INVITE that never went out) are given up after two transaction timeouts:
    /// the pending re-INVITE is CANCELled and the media watchdog decides.
    private func expireStaleReinvites(_ now: ContinuousClock.Instant) {
        let limit = Duration.milliseconds(2 * Int(transactionTimeoutMs) + 5000)
        for (id, since) in reinviteSince where now - since > limit {
            if ipChange?.calls.contains(id) == true { continue }      // its round is still running
            bridge.warn("call \(id): re-INVITE after network change not settled after \(limit); giving up")
            if (try? liveSlot(id)) != nil, bridge.record(id.raw)?.reinviteInFlight != nil {
                PJ.warn(cpjsua_call_cancel_reinvite(id.raw), "call \(id): CANCEL the re-INVITE")
            }
            reinviteDone(id)
        }
    }

    /// keep_inv_after_tsx_timeout while a round runs or any call waits for its re-INVITE, so
    /// a re-INVITE that times out does not end the call inside PJSIP (the engine decides).
    func updateKeepInvAfterTimeout() {
        guard isStarted, PJ.registerThread() else { return }
        var pending = ipChange != nil
        if !pending {
            pending = CallSnapshot.allSlots().contains { bridge.record($0)?.reinvitePending == true }
        }
        setKeepInvAfterTimeout(pending)
    }

    private func setKeepInvAfterTimeout(_ on: Bool) {
        guard on != keepInvApplied else { return }
        keepInvApplied = on
        cpjsua_set_keep_inv_after_tsx_timeout(on ? 1 : 0)
    }

    /// Hangs up a call whose media is gone; its `.callEnded` carries `connectionLostReason`.
    func endConnectionLost(_ id: CallID, why: String) {
        guard let slot = try? liveSlot(id), let snap = CallSnapshot.read(slot) else { return }
        bridge.warn("call \(id): \(why); ending it (\(Engine.connectionLostReason))")
        bridge.updateCall(snap, mode: .updateOnly, mutate: { $0.connectionLost = true })
        mediaWatch[id] = nil
        reinviteTasks.removeValue(forKey: id)?.cancel()
        PJ.warn(pjsua_call_hangup(slot, 0, nil, nil), "hang up call \(id) after connection loss")
        reconcileTones()
    }

    // MARK: - isReconnecting and the media watchdog

    /// Recomputes `CallInfo.isReconnecting` for every call and announces changes.
    func refreshReconnecting() {
        guard isStarted, PJ.registerThread() else { return }
        let now = ContinuousClock.now
        for slot in CallSnapshot.allSlots() {
            guard let snap = CallSnapshot.read(slot), snap.state != .disconnected,
                  let rec = bridge.record(slot), rec.serial == snap.serial else { continue }
            let id = CallID(raw: slot, serial: rec.serial)
            let want = snap.state == .confirmed
                && (networkStatus == .offline || rec.reinvitePending || mediaSilent(id, now))
            guard want != rec.reconnecting else { continue }
            bridge.updateCall(snap, mode: .updateOnly, mutate: { $0.reconnecting = want }, event: { info, r in
                r.announced ? .callChanged(info) : nil
            })
            emit(.log(level: 4, "engine: call \(id): \(want ? "reconnecting" : "media flowing again")"))
        }
        updateKeepInvAfterTimeout()
    }

    /// No RTP for `mediaSilenceThreshold`, and either a network event happened recently or
    /// RTCP is silent too. A peer with silence suppression (or a voicemail recording, which
    /// sends no RTP at all) keeps sending RTCP and is not "reconnecting".
    func mediaSilent(_ id: CallID, _ now: ContinuousClock.Instant) -> Bool {
        guard networkStatus == .online, !sleeping, let w = mediaWatch[id] else { return false }
        guard now - w.rxChanged > .seconds(mediaSilenceThreshold) else { return false }
        if let event = lastNetworkEvent, now - event < .seconds(networkEventWindow) { return true }
        return now - w.rtcpChanged > .seconds(rtcpSilenceThreshold)
    }

    func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.watchdogTick()
            }
        }
    }

    /// Every second: RTP and RTCP counters of each connected call with active media. No RTP
    /// and no RTCP for `connectionLostTimeout` while online, on a stream that has had RTCP,
    /// sends an in-dialog OPTIONS; the call ends only when that gets 408 or 481. Hold,
    /// remote hold, offline and sleep pause the clocks. Also runs a postponed network change
    /// once no outgoing call rings, and gives up re-INVITEs that never settle.
    func watchdogTick() {
        guard isStarted, PJ.registerThread() else { return }
        let now = ContinuousClock.now
        var live: Set<CallID> = []
        for slot in CallSnapshot.allSlots() {
            guard let snap = CallSnapshot.read(slot), snap.state == .confirmed,
                  let rec = bridge.record(slot), rec.serial == snap.serial else { continue }
            let id = CallID(raw: slot, serial: rec.serial)
            live.insert(id)
            var st = cpjsua_rtp_stat()
            let ok = cpjsua_call_rtp_stat(slot, &st) == PJ.success
            let rx = ok ? Int(st.rx_packets) : 0
            let rtcp = ok ? Int(st.rtcp_rx_reports) : 0
            var w = mediaWatch[id] ?? MediaWatch(rx: rx, rtcp: rtcp, rxChanged: now, rtcpChanged: now, activityChanged: now)
            if rx < w.rx || rtcp < w.rtcp { w.rtcpSeen = false }       // a new stream (re-INVITE)
            let paused = !ok || snap.mediaStatus != .active || networkStatus == .offline || sleeping
            if paused || rx != w.rx { w.rxChanged = now }
            if paused || rtcp != w.rtcp { w.rtcpChanged = now }
            if paused || rx != w.rx || rtcp != w.rtcp { w.activityChanged = now }
            if rtcp > 0 { w.rtcpSeen = true }
            w.rx = rx
            w.rtcp = rtcp
            if w.rtcpSeen, !rec.probing, now - w.activityChanged >= .seconds(connectionLostTimeout) {
                probe(id, snap)
                w.activityChanged = now       // the probe's answer decides; next probe one period later
            }
            mediaWatch[id] = w
        }
        for key in Array(mediaWatch.keys) where !live.contains(key) { mediaWatch[key] = nil }
        for key in Array(reinviteAttempts.keys) where !live.contains(key) { reinviteAttempts[key] = nil }
        for key in Array(reinviteSince.keys) where !live.contains(key) { reinviteSince[key] = nil }
        expireStaleReinvites(now)
        if let postponed = postponedIPChange, ipChange == nil, !outgoingCallRinging()
            || now - postponed.since >= Engine.postponeLimit {
            postponedIPChange = nil
            requestIPChange(postponed)
        }
        refreshReconnecting()
    }

    /// In-dialog OPTIONS: does the far end still know this call?
    private func probe(_ id: CallID, _ snap: CallSnapshot) {
        emit(.log(level: 3, "engine: call \(id): no RTP or RTCP for \(Int(connectionLostTimeout)) s; probing with OPTIONS"))
        bridge.updateCall(snap, mode: .updateOnly, mutate: { $0.probing = true })
        let status = cpjsua_call_send_options(id.raw)
        if status != PJ.success {
            PJ.warn(status, "call \(id): OPTIONS probe")
            bridge.updateCall(snap, mode: .updateOnly, mutate: { $0.probing = false })
        }
    }

    /// The watchdog's OPTIONS got an answer: 408/481 = the dialog is gone; anything else
    /// (200, 405, 501...) = the far end is there, the call stays.
    func probeFinished(_ id: CallID, code: Int) {
        guard isStarted, PJ.registerThread(), let slot = try? liveSlot(id),
              let snap = CallSnapshot.read(slot) else { return }   // PJSIP ended it on 408/481
        bridge.updateCall(snap, mode: .updateOnly, mutate: { $0.probing = false })
        if code == 408 || code == 481 {
            endConnectionLost(id, why: "no media and the OPTIONS probe answered \(code)")
        } else {
            emit(.log(level: 3, "engine: call \(id): OPTIONS probe answered \(code); keeping the call"))
        }
    }

    // MARK: - REGISTER retry with backoff

    /// After a temporary failure (`.reconnecting(attempt, nextRetryIn, ...)` is already out).
    func scheduleRegistrationRetry(_ id: AccountID, attempt: Int, after delay: TimeInterval) {
        guard isStarted, accounts[id]?.wantsRegistration == true else { return }
        registrationRetries[id]?.cancel()
        registrationRetries[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard !Task.isCancelled else { return }
            await self?.registrationRetryFired(id, attempt: attempt)
        }
    }

    private func registrationRetryFired(_ id: AccountID, attempt: Int) {
        registrationRetries[id] = nil
        guard isStarted, PJ.registerThread(), let entry = accounts[id], entry.wantsRegistration,
              case let .reconnecting(current, _, _) = bridge.registration(of: id), current == attempt else { return }
        if sleeping || networkStatus == .offline {
            // No hammering: the network coming back (or wake) re-registers.
            emit(.log(level: 3, "engine: account \(entry.config.uri): REGISTER retry waits for the network"))
            return
        }
        if ipChange != nil {
            // pjsua is re-registering it right now; look again in a second.
            scheduleRegistrationRetry(id, attempt: attempt, after: 1)
            return
        }
        emit(.log(level: 3, "engine: account \(entry.config.uri): REGISTER retry \(attempt + 1)"))
        do {
            try applyRegistration(id, true, retrying: true)
        } catch {
            if let next = bridge.registrationFailedTemporarily(id, lastError: "\(error)") {
                scheduleRegistrationRetry(id, attempt: next.attempt, after: next.delay)
            }
        }
    }

    func cancelRegistrationRetry(_ id: AccountID) {
        registrationRetries.removeValue(forKey: id)?.cancel()
    }

    func cancelRegistrationRetries() {
        for task in registrationRetries.values { task.cancel() }
        registrationRetries = [:]
    }

    /// The connection that carried these accounts' registration closed (not during a round,
    /// which closes TCP/TLS connections on purpose and re-registers): a failed REGISTER.
    func registrationTransportLost(_ ids: [AccountID], reason: String) {
        guard isStarted, ipChange == nil, !sleeping else { return }
        for id in ids {
            guard let entry = accounts[id], entry.wantsRegistration,
                  case .registered = bridge.registration(of: id) else { continue }
            bridge.setRegistrarSource(entry.index, nil)
            if let next = bridge.registrationFailedTemporarily(id, lastError: reason) {
                emit(.log(level: 2, "engine: account \(entry.config.uri): \(reason); REGISTER again in "
                         + "\(Int(next.delay)) s"))
                scheduleRegistrationRetry(id, attempt: next.attempt, after: next.delay)
            }
        }
    }

    // MARK: - test hooks

    /// Tests: shorter SIP transaction timeout (applied at `start`) and watchdog limits.
    func setTestTimings(transactionTimeoutMs: UInt32? = nil, mediaSilence: TimeInterval? = nil,
                        rtcpSilence: TimeInterval? = nil, networkEventWindow: TimeInterval? = nil,
                        connectionLost: TimeInterval? = nil) {
        if let transactionTimeoutMs { transactionTimeoutOverrideMs = transactionTimeoutMs }
        if let mediaSilence { mediaSilenceThreshold = mediaSilence }
        if let rtcpSilence { rtcpSilenceThreshold = rtcpSilence }
        if let networkEventWindow { self.networkEventWindow = networkEventWindow }
        if let connectionLost { connectionLostTimeout = connectionLost }
    }

    /// Tests: the round now running (nil = none) and how many rounds ran.
    func ipChangeStateForTests() -> (running: UInt64?, rounds: UInt64, queued: Bool, postponed: Bool) {
        (ipChange?.round, ipChangeRound, queuedIPChange != nil, postponedIPChange != nil)
    }
}
