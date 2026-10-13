internal import CPJSUA
import Foundation
import os

// MARK: - Bridge between PJSIP's C callbacks and the Engine actor
//
// pjsua is a process-wide singleton and its callbacks are plain C function pointers
// without a context argument. They cannot capture the Engine instance, so they reach it
// through `EngineBridge.shared`: a process-global registry guarded by an unfair lock.
// It is a `Sendable` final class, so no `nonisolated(unsafe)` global is needed.
//
// Rules for every callback (they run on PJSIP worker / media threads):
//  1. copy what is needed out of PJSIP (CallSnapshot, reg info) right away;
//  2. update the registry under the lock (short critical sections, never calling pjsua
//     while holding it). Call events are yielded inside the same critical section as the
//     record update, so `.callChanged` can never be ordered after the call's `.callEnded`;
//  3. `yield` is non-blocking (unbounded AsyncStream) and never re-enters our code;
//  4. if the Engine must act (conference wiring, ringtone), schedule it with
//     `Task { await engine.... }` - asynchronous, never a synchronous call into the actor.

/// Per-call bookkeeping that PJSIP does not keep for us.
struct CallRecord: Sendable {
    var serial: UInt64
    var accountID: AccountID
    var direction: CallDirection
    /// Outgoing calls are announced at once; incoming calls once `.incomingCall` was emitted.
    var announced: Bool
    var isMuted = false
    var localHold = false
    var startedAt: Date?
    /// Last codec / SRTP state seen while media was up, reported again in `.callEnded`.
    var lastCodec: String?
    var lastSecure = false
    /// Local conference the call belongs to (Engine.merge); nil = not in a conference.
    var conference: UInt64?
    /// A recorder is attached (Engine.startRecording). Stays true in `.callEnded` when the
    /// call ended while recorded: that event is held back until the WAV is finalised.
    var isRecording = false
    /// `Call-Info: ...;answer-after=N` of the incoming INVITE.
    var answerAfter: Int?
    /// `CallInfo.isReconnecting` as last computed by the engine (`refreshReconnecting`).
    var reconnecting = false
    /// Network-change round whose re-INVITE this call still needs (docs/ENGINE.md "Network
    /// resilience"); nil = none. Set for every confirmed call when a round starts.
    var reinviteWanted: UInt64?
    /// Round of the engine's re-INVITE that is in flight (its final response settles it).
    var reinviteInFlight: UInt64?
    /// An in-dialog OPTIONS probe of the media watchdog is in flight.
    var probing = false
    /// The engine ends the call because its media is gone: `.callEnded` says
    /// `.disconnected(code: 0, reason: Engine.connectionLostReason)`.
    var connectionLost = false
    /// pjsua's INVITE session state at the last snapshot (single-call mode checks it in
    /// `on_incoming_call` without calling into pjsua for the other calls).
    var inviteState: InviteState = .null

    var reinvitePending: Bool { reinviteWanted != nil || reinviteInFlight != nil }
}

/// How `EngineBridge.updateCall` treats the call's record.
enum RecordMode: Sendable {
    /// PJSIP callbacks: create the record for a new call, refresh an existing one.
    case createOrUpdate
    /// Engine-originated updates: touch only an existing record of the same call; never
    /// create one (a call that ended in the meantime must not come back as a ghost).
    case updateOnly
    /// The call is over: report it and drop the record.
    case remove
}

final class EngineBridge: Sendable {
    static let shared = EngineBridge()

    struct AccountSlot: Sendable {
        var id: AccountID
        var registrationInterval: Int
        /// The outbound proxy when configured as an IP literal (a trusted INVITE source).
        var proxy: SignallingSource? = nil
        /// The engine wants this account registered (addAccount/updateAccount with
        /// `registers`, setRegistered). A REGISTER that pjsua sends on its own for an
        /// account that should not be registered is undone (see pjOnRegState2).
        var wantsRegistration = false
    }

    struct WatchedBuddy: Sendable {
        /// The URI as the caller passed it to `subscribePresence`; `.buddyPresence` carries it.
        var reportedURI: String
        var last: PresenceStatus?
        var lastNote: String?
        /// The last NOTIFY body had an RPID `on-the-phone` activity (pjrpid does not map it).
        var onThePhone = false
    }

    struct State: Sendable {
        var sink: AsyncStream<EngineEvent>.Continuation?
        var engine: Engine?
        var accounts: [Int32: AccountSlot] = [:]                // pjsua_acc_id -> account
        /// Source of the last REGISTER 2xx per account: the server whose INVITEs may carry a
        /// Call-Info answer-after that is honoured. Cleared when the account is not registered.
        var registrarSources: [Int32: SignallingSource] = [:]
        var registration: [AccountID: RegistrationState] = [:]
        /// Registration switch requested while a REGISTER transaction was in flight
        /// (PJSIP answered EBUSY); applied when that transaction completes.
        var pendingRegistration: [AccountID: Bool] = [:]
        /// Failed REGISTER attempts since the last success (temporary failures only).
        var retryAttempts: [AccountID: Int] = [:]
        /// Calls pjsua re-INVITEd in the current network change (by call serial).
        var ipChangeReinvited: Set<UInt64> = []
        /// Current network-change round (tags pjsua's progress reports).
        var ipChangeRound: UInt64 = 0
        /// Network online since (nil = offline); a DNS failure while online for a while is
        /// a configuration error, not a network one.
        var onlineSince: ContinuousClock.Instant? = .now
        /// Ordered queue of follow-up work for the engine (see `hop`).
        var hops: AsyncStream<@Sendable (Engine) async -> Void>.Continuation?
        var calls: [Int32: CallRecord] = [:]                    // pjsua_call_id -> record
        /// `.callEnded` of recorded calls, keyed by call serial, held back until the engine
        /// finalised the recording (see `releaseDeferredEnds`).
        var deferredEnds: [UInt64: EngineEvent] = [:]
        /// Watched buddies by the token stored in their pjsua user data (buddy ids are reused).
        var watched: [UInt64: WatchedBuddy] = [:]
        /// Latest voicemail indicator per account (RFC 3842 message-summary NOTIFY).
        var voicemail: [AccountID: VoicemailState] = [:]
        /// Never reset, so CallIDs stay unique across engine restarts in one process.
        var nextSerial: UInt64 = 1
        /// `Engine.setCallOptions` / `start`: read by `on_incoming_call` (single-call mode).
        var callOptions = CallOptions()
    }

    let state = OSAllocatedUnfairLock(initialState: State())
    let logger = Logger(subsystem: "com.hsmm.macrosip", category: "pjsip")
    let engineLogger = Logger(subsystem: "com.hsmm.macrosip", category: "engine")

    // MARK: lifecycle

    func attach(_ engine: Engine, sink: AsyncStream<EngineEvent>.Continuation) throws {
        let ok = state.withLock { st -> Bool in
            guard st.engine == nil else { return false }
            let serial = st.nextSerial
            st = State()
            st.nextSerial = serial
            st.engine = engine
            st.sink = sink
            return true
        }
        guard ok else { throw EngineError.alreadyStarted }
        // One consumer runs the follow-up work in the order the callbacks scheduled it (a
        // Task per callback would not keep that order: e.g. a REGISTER result and the
        // completion of a network change, or two final responses of the same call).
        let (stream, continuation) = AsyncStream.makeStream(of: (@Sendable (Engine) async -> Void).self,
                                                            bufferingPolicy: .unbounded)
        state.withLock { $0.hops = continuation }
        Task { [weak engine] in
            for await work in stream {
                guard let engine else { return }
                await work(engine)
            }
        }
    }

    func detach(_ engine: Engine) {
        let hops = state.withLock { st -> AsyncStream<@Sendable (Engine) async -> Void>.Continuation? in
            guard st.engine === engine else { return nil }
            let hops = st.hops
            let serial = st.nextSerial
            st = State()
            st.nextSerial = serial
            return hops
        }
        hops?.finish()
    }

    /// The engine currently attached (started), if any.
    func attachedEngine() -> Engine? {
        state.withLock { $0.engine }
    }

    // MARK: events

    func emit(_ event: EngineEvent) {
        let sink = state.withLock { $0.sink }
        sink?.yield(event)
    }

    /// Schedules `work` on the attached engine without waiting for it. Work items run one
    /// after another in the order they were scheduled.
    func hop(_ work: @escaping @Sendable (Engine) async -> Void) {
        let hops = state.withLock { $0.engine == nil ? nil : $0.hops }
        hops?.yield(work)
    }

    // MARK: accounts

    func setAccount(_ index: Int32, _ id: AccountID, registrationInterval: Int, proxy: SignallingSource? = nil) {
        state.withLock { st in
            let wants = st.accounts[index]?.id == id ? st.accounts[index]?.wantsRegistration ?? false : false
            st.accounts[index] = AccountSlot(id: id, registrationInterval: registrationInterval, proxy: proxy,
                                             wantsRegistration: wants)
        }
    }

    func setWantsRegistration(_ index: Int32, _ on: Bool) {
        state.withLock { $0.accounts[index]?.wantsRegistration = on }
    }

    func setRegistrarSource(_ index: Int32, _ source: SignallingSource?) {
        state.withLock { $0.registrarSources[index] = source }
    }

    /// The INVITE came from the server that accepted the account's REGISTER, or from its
    /// outbound proxy (IP literal).
    func isTrustedSource(_ source: SignallingSource, account index: Int32) -> Bool {
        state.withLock { st in
            if let registrar = st.registrarSources[index], source.isSamePeer(as: registrar) { return true }
            if let proxy = st.accounts[index]?.proxy, source.isSamePeer(as: proxy) { return true }
            return false
        }
    }

    func removeAccount(_ index: Int32) {
        state.withLock { st in
            st.registrarSources[index] = nil
            if let old = st.accounts.removeValue(forKey: index) {
                st.registration[old.id] = nil
                st.pendingRegistration[old.id] = nil
                st.retryAttempts[old.id] = nil
                st.voicemail[old.id] = nil
            }
        }
    }

    func account(for index: Int32) -> AccountSlot? {
        state.withLock { $0.accounts[index] }
    }

    func registration(of id: AccountID) -> RegistrationState {
        state.withLock { $0.registration[id] ?? .unregistered }
    }

    /// Stores and emits a registration state (only when it changed, unless `force`).
    func setRegistration(_ id: AccountID, _ new: RegistrationState, force: Bool = false) {
        state.withLock { st in
            guard st.accounts.values.contains(where: { $0.id == id }) else { return }
            let old = st.registration[id]
            st.registration[id] = new
            if force || old != new { st.sink?.yield(.registration(id, new)) }
        }
    }

    /// "registering" for the UI unless the account is registered (a refresh) or reconnecting
    /// (a retry: the UI keeps showing the attempt and its countdown).
    func showRegistering(_ id: AccountID) {
        state.withLock { st in
            guard st.accounts.values.contains(where: { $0.id == id }) else { return }
            switch st.registration[id] ?? .unregistered {
            case .registered, .reconnecting, .registering: return
            default:
                st.registration[id] = .registering
                st.sink?.yield(.registration(id, .registering))
            }
        }
    }

    /// One more temporary failure: stores and emits `.reconnecting` with the next attempt's
    /// delay. Returns the attempt number and the delay.
    @discardableResult
    func registrationFailedTemporarily(_ id: AccountID, lastError: String) -> (attempt: Int, delay: TimeInterval)? {
        state.withLock { st in
            guard st.accounts.values.contains(where: { $0.id == id }) else { return nil }
            let attempt = (st.retryAttempts[id] ?? 0) + 1
            st.retryAttempts[id] = attempt
            let delay = RegistrationBackoff.delay(attempt: attempt)
            let new = RegistrationState.reconnecting(attempt: attempt, nextRetryIn: delay, lastError: lastError)
            st.registration[id] = new
            st.sink?.yield(.registration(id, new))
            return (attempt, delay)
        }
    }

    func resetRetryAttempts(_ id: AccountID) {
        _ = state.withLock { $0.retryAttempts.removeValue(forKey: id) }
    }

    func resetAllRetryAttempts() {
        state.withLock { $0.retryAttempts = [:] }
    }

    func setPendingRegistration(_ id: AccountID, _ on: Bool?) {
        state.withLock { $0.pendingRegistration[id] = on }
    }

    func pendingRegistration(_ id: AccountID) -> Bool? {
        state.withLock { $0.pendingRegistration[id] }
    }

    func takePendingRegistration(_ id: AccountID) -> Bool? {
        state.withLock { $0.pendingRegistration.removeValue(forKey: id) }
    }

    // MARK: calls

    func setCallOptions(_ options: CallOptions) {
        state.withLock { $0.callOptions = options }
    }

    func callOptions() -> CallOptions {
        state.withLock { $0.callOptions }
    }

    /// Single-call mode: another call than `slot` is connected or held (confirmed), being
    /// answered (connecting), or an outgoing call is being set up (calling, early). A second
    /// call that only rings in does not count.
    func hasCallInProgress(except slot: Int32) -> Bool {
        state.withLock { st in
            st.calls.contains { key, rec in
                guard key != slot else { return false }
                switch rec.inviteState {
                case .confirmed, .connecting: return true
                case .calling, .early: return rec.direction == .outgoing
                default: return false
                }
            }
        }
    }

    func allocateSerial() -> UInt64 {
        state.withLock { st in
            defer { st.nextSerial += 1 }
            return st.nextSerial
        }
    }

    func record(_ slot: Int32) -> CallRecord? {
        state.withLock { $0.calls[slot] }
    }

    /// Updates the slot's record from a fresh snapshot and, in the same critical section,
    /// yields the event built by `event` (if any). Returns nil when `mode == .updateOnly`
    /// and the call has no record of the same serial (it ended or never was announced).
    ///
    /// With `mode == .remove` the event of a call that is being recorded is not yielded but
    /// kept until `releaseDeferredEnds` (the engine finalises the WAV first, so a `.callEnded`
    /// with `isRecording` always refers to a complete file).
    @discardableResult
    func updateCall(
        _ snap: CallSnapshot,
        mode: RecordMode,
        mutate: (@Sendable (inout CallRecord) -> Void)? = nil,
        event: (@Sendable (CallInfo, CallRecord) -> EngineEvent?)? = nil
    ) -> (CallInfo, CallRecord)? {
        let now = Date()
        let result = state.withLock { st -> (CallInfo, CallRecord, UInt64?)? in
            var serial = snap.serial
            var newSerial: UInt64?
            let existing = st.calls[snap.slot]
            var rec: CallRecord

            switch mode {
            case .updateOnly:
                guard let existing, existing.serial == serial, snap.serial != 0 else { return nil }
                rec = existing
            case .createOrUpdate, .remove:
                let clash = st.calls.contains { $0.key != snap.slot && $0.value.serial == serial }
                if mode == .createOrUpdate, serial == 0 || (existing?.serial != serial && clash) {
                    // pjsua created this call itself (REFER, Replaces) and copied or left user_data.
                    serial = st.nextSerial
                    st.nextSerial += 1
                    newSerial = serial
                }
                if let existing, existing.serial == serial {
                    rec = existing
                } else {
                    rec = CallRecord(
                        serial: serial,
                        accountID: st.accounts[snap.accIndex]?.id ?? .unknown,
                        direction: snap.isOutgoing ? .outgoing : .incoming,
                        announced: snap.isOutgoing
                    )
                }
            }

            mutate?(&rec)
            rec.inviteState = snap.state
            if let codec = snap.codec {
                rec.lastCodec = codec
                rec.lastSecure = snap.isSecure
            }
            if snap.state == .confirmed, rec.startedAt == nil {
                rec.startedAt = now.addingTimeInterval(-snap.connectDuration)
            }

            switch mode {
            case .remove:
                if st.calls[snap.slot]?.serial == serial { st.calls[snap.slot] = nil }
            case .createOrUpdate:
                // A disconnected call never gets a new record.
                if snap.state != .disconnected || existing?.serial == serial { st.calls[snap.slot] = rec }
            case .updateOnly:
                st.calls[snap.slot] = rec
            }

            let info = EngineBridge.makeInfo(snap, rec)
            // A late callback for a call whose record is already gone (its .callEnded was
            // emitted) must not produce a ghost event.
            let gone = mode == .createOrUpdate && snap.state == .disconnected && existing?.serial != serial
            if !gone, let e = event?(info, rec) {
                if mode == .remove && rec.isRecording {
                    st.deferredEnds[rec.serial] = e
                } else {
                    st.sink?.yield(e)
                }
            }
            return (info, rec, newSerial)
        }
        guard let result else { return nil }
        if let newSerial = result.2 {
            PJ.warn(cpjsua_call_set_serial(snap.slot, newSerial), "store call serial")
        }
        return (result.0, result.1)
    }

    static func makeInfo(_ s: CallSnapshot, _ r: CallRecord) -> CallInfo {
        let onHold = r.localHold || s.mediaStatus == .localHold
        let state: CallState
        switch s.state {
        case .null, .calling:
            state = r.direction == .incoming ? .incoming : .calling
        case .incoming:
            state = .incoming
        case .early:
            // We answer every incoming call with 180 at once, so it sits in EARLY while ringing.
            state = r.direction == .incoming ? .incoming : .early
        case .connecting:
            state = .connecting
        case .confirmed:
            state = onHold ? .held : .connected
        case .disconnected:
            // 481 or a timeout on the re-INVITE after a network change: the far end lost the
            // dialog (PJSIP ends the call itself on 481).
            if r.connectionLost || ((r.reinvitePending || r.probing) && [408, 481].contains(s.lastStatus)) {
                state = .disconnected(code: 0, reason: Engine.connectionLostReason)
            } else {
                state = .disconnected(code: s.lastStatus, reason: s.lastStatusText)
            }
        }
        return CallInfo(
            id: CallID(raw: s.slot, serial: r.serial),
            accountID: r.accountID,
            direction: r.direction,
            state: state,
            remote: RemoteParty.parse(s.remoteInfo),
            startedAt: r.startedAt,
            isMuted: r.isMuted,
            isOnHold: onHold,
            isRecording: r.isRecording,
            inConference: r.conference != nil,
            codec: s.state == .disconnected ? (s.codec ?? r.lastCodec) : s.codec,
            isSecure: s.state == .disconnected ? (s.codec != nil ? s.isSecure : r.lastSecure) : s.isSecure,
            answerAfter: r.answerAfter,
            isReconnecting: s.state == .confirmed && r.reconnecting
        )
    }

    // MARK: network change

    func beginIPChangeRound(_ round: UInt64) {
        state.withLock {
            $0.ipChangeReinvited = []
            $0.ipChangeRound = round
        }
    }

    func currentIPChangeRound() -> UInt64 {
        state.withLock { $0.ipChangeRound }
    }

    func setOnline(_ online: Bool) {
        state.withLock { st in
            if !online { st.onlineSince = nil } else if st.onlineSince == nil { st.onlineSince = .now }
        }
    }

    /// Online for at least `seconds` without interruption.
    func onlineStable(for seconds: Double = 10) -> Bool {
        state.withLock { st in
            guard let since = st.onlineSince else { return false }
            return ContinuousClock.now - since >= .seconds(seconds)
        }
    }

    func noteIPChangeReinvite(serial: UInt64) {
        _ = state.withLock { $0.ipChangeReinvited.insert(serial) }
    }

    func ipChangeReinvited() -> Set<UInt64> {
        state.withLock { $0.ipChangeReinvited }
    }

    /// Yields the held-back `.callEnded` events except those of calls in `keep` (serials whose
    /// recording is still being finalised). Ordered by serial.
    func releaseDeferredEnds(keeping keep: Set<UInt64> = []) {
        state.withLock { st in
            for serial in st.deferredEnds.keys.sorted() where !keep.contains(serial) {
                if let e = st.deferredEnds.removeValue(forKey: serial) { st.sink?.yield(e) }
            }
        }
    }

    /// Yields one held-back `.callEnded` with `isRecording == false`: its recording moved to a
    /// leg that stays in the conference.
    func releaseDeferredEndWithoutRecording(serial: UInt64) {
        state.withLock { st in
            guard let e = st.deferredEnds.removeValue(forKey: serial) else { return }
            if case .callEnded(var info, let duration) = e {
                info.isRecording = false
                st.sink?.yield(.callEnded(info, duration: duration))
            } else {
                st.sink?.yield(e)
            }
        }
    }

    // MARK: presence

    func watch(token: UInt64, reportedAs reported: String) {
        state.withLock { $0.watched[token] = WatchedBuddy(reportedURI: reported) }
    }

    func unwatch(token: UInt64) {
        _ = state.withLock { $0.watched.removeValue(forKey: token) }
    }

    func unwatchAll() {
        state.withLock { $0.watched = [:] }
    }

    func setOnThePhone(token: UInt64, _ on: Bool) {
        state.withLock { st in st.watched[token]?.onThePhone = on }
    }

    /// Emits `.buddyPresence` for a watched buddy when its status or note changed.
    func reportPresence(_ buddy: BuddySnapshot) {
        state.withLock { st in
            guard var w = st.watched[buddy.token] else { return }
            let activity = buddy.activity == .unknown && w.onThePhone ? .onThePhone : buddy.activity
            let status = PresenceMapping.status(basic: buddy.basic, activity: activity, note: buddy.note,
                                                subscriptionTerminated: buddy.terminated)
            let note = status == .offline && buddy.terminated ? nil : PresenceMapping.cleanNote(buddy.note)
            guard w.last != status || w.lastNote != note else { return }
            w.last = status
            w.lastNote = note
            st.watched[buddy.token] = w
            st.sink?.yield(.buddyPresence(contactURI: w.reportedURI, status, note: note))
        }
    }

    // MARK: voicemail

    func voicemail(of id: AccountID) -> VoicemailState? {
        state.withLock { $0.voicemail[id] }
    }

    /// Stores the indicator and emits `.voicemail` when it differs from the last one.
    func reportVoicemail(_ id: AccountID, _ summary: VoicemailState, solicited: Bool) {
        state.withLock { st in
            guard st.accounts.values.contains(where: { $0.id == id }) else { return }
            let old = st.voicemail[id]
            st.voicemail[id] = summary
            st.sink?.yield(.log(level: 4, "engine: account \(id.raw): voicemail \(summary.waiting ? "waiting" : "none"), "
                                + "\(summary.new) new / \(summary.old) old (\(solicited ? "subscription" : "unsolicited") NOTIFY)"))
            if old != summary {
                st.sink?.yield(.voicemail(id, waiting: summary.waiting, new: summary.new, old: summary.old))
            }
        }
    }

    /// Logs a warning (os_log + `.log` event) from a callback.
    func warn(_ text: String) {
        engineLogger.notice("\(text, privacy: .public)")
        emit(.log(level: 2, "engine: \(text)"))
    }
}

// MARK: - Registration result mapping

enum RegistrationMapping {
    /// Maps an on_reg_state2 result. `renew == false` is the answer to an un-REGISTER:
    /// the user switched the account off, whatever the server said.
    static func state(renew: Bool, status: Int32, code: Int, reason: String, expiration: UInt32,
                      notSpecified: UInt32, interval: Int) -> RegistrationState {
        guard renew else { return .unregistered }
        if status != PJ.success {
            return .failed(code: code, reason: reason.isEmpty ? PJ.errorText(status) : reason)
        }
        guard code / 100 == 2 else {
            return .failed(code: code, reason: reason.isEmpty ? "Registration failed" : reason)
        }
        // 2xx without an Expires value: the binding lasts for what we asked for.
        if expiration == notSpecified { return .registered(expires: max(1, interval)) }
        return expiration > 0 ? .registered(expires: Int(min(expiration, UInt32(Int32.max)))) : .unregistered
    }

    /// A REGISTER failure that may go away by itself: no answer (408), server errors 500,
    /// 502, 503, 504, 480, and transport or DNS errors (PJSIP reports them with a status
    /// other than PJ_SUCCESS and a placeholder code, or as 408/503 from the transaction).
    /// Credentials and configuration errors (401, 403, 404, 407, other 4xx-6xx) are not.
    static func isTemporary(status: Int32, code: Int) -> Bool {
        switch code {
        case 0, 408, 480, 500, 502, 503, 504: return true
        case 401, 407, 423: return false        // also with a status: no usable credentials
        default: return status != PJ.success
        }
    }

    /// `isTemporary`, except for transport errors that no retry fixes: a TLS certificate or
    /// TLS configuration error, and a host name that does not resolve while the network has
    /// been up for a while (a typo in the server name; right after a network change DNS may
    /// not work yet, so then it is still temporary). PJSIP reports both as 502/503 with the
    /// error text as the reason.
    static func isTemporary(status: Int32, code: Int, reason: String, onlineStable: Bool) -> Bool {
        guard isTemporary(status: status, code: code) else { return false }
        if isPermanentTransportError(reason) { return false }
        if onlineStable && isResolveFailure(reason) { return false }
        return true
    }

    static let permanentTransportTexts: [String] = {
        var codes = [pj_status_t](repeating: 0, count: 16)
        let n = Int(cpjsua_permanent_transport_errors(&codes, UInt32(codes.count)))
        return codes.prefix(n).map { PJ.errorText($0) }
    }()

    static let resolveTexts: [String] = [PJ.errorText(cpjsua_err_resolve()), PJ.errorText(cpjsua_err_nxdomain())]

    static func isPermanentTransportError(_ reason: String) -> Bool {
        let r = reason.lowercased()
        return permanentTransportTexts.contains { !$0.isEmpty && r.contains($0.lowercased()) }
            || r.contains("certificate")
    }

    static func isResolveFailure(_ reason: String) -> Bool {
        let r = reason.lowercased()
        return resolveTexts.contains { !$0.isEmpty && r.contains($0.lowercased()) }
    }

    /// "408 Request Timeout", or the PJSIP error text for local failures.
    static func errorText(status: Int32, code: Int, reason: String) -> String {
        if status != PJ.success {
            return reason.isEmpty || code == 400 ? PJ.errorText(status) : reason
        }
        let r = reason.isEmpty ? "Registration failed" : reason
        return code > 0 ? "\(code) \(r)" : r
    }
}

/// Delay before REGISTER retry number `attempt + 1` after `attempt` temporary failures.
enum RegistrationBackoff {
    static let delays: [TimeInterval] = [2, 4, 8, 16, 32, 60]

    static func delay(attempt: Int) -> TimeInterval {
        delays[min(max(attempt, 1), delays.count) - 1]
    }
}

// MARK: - C callbacks
//
// Global functions (not closures formed inside the actor) so they are nonisolated and can
// be converted to @convention(c) function pointers.

func installPJCallbacks(_ cb: inout pjsua_callback) {
    cb.on_call_state = pjOnCallState
    cb.on_incoming_call = pjOnIncomingCall
    cb.on_call_media_state = pjOnCallMediaState
    cb.on_reg_started2 = pjOnRegStarted2
    cb.on_reg_state2 = pjOnRegState2
    cb.on_call_transfer_status = pjOnCallTransferStatus
    cb.on_dtmf_digit2 = pjOnDtmfDigit2
    cb.on_call_replaced = pjOnCallReplaced
    cb.on_buddy_state = pjOnBuddyState
    cb.on_buddy_evsub_state = pjOnBuddyEvsubState
    cb.on_call_tsx_state = pjOnCallTsxState
    cb.on_transport_state = pjOnTransportState
    cb.on_ip_change_progress = pjOnIPChangeProgress
    cb.on_mwi_info = pjOnMwiInfo
    // on_pager (instant messages) stays unset: pjsua answers MESSAGE with 200 and drops it.
}

/// PJSIP log writer: os_log (subsystem com.hsmm.macrosip, category pjsip) + `.log` event.
func pjLogWriter(_ level: Int32, _ data: UnsafePointer<CChar>?, _ len: Int32) {
    guard let data, len > 0 else { return }
    var text = String(decoding: UnsafeRawBufferPointer(start: data, count: Int(len)), as: UTF8.self)
    while let last = text.last, last.isNewline { text.removeLast() }   // "\r\n" is one Character
    let bridge = EngineBridge.shared
    let type: OSLogType
    switch level {
    case ...0: type = .fault
    case 1: type = .error
    case 2: type = .default
    case 3: type = .info
    default: type = .debug
    }
    bridge.logger.log(level: type, "\(text, privacy: .public)")
    bridge.emit(.log(level: Int(level), text))
}

private func pjOnCallState(_ callID: pjsua_call_id, _ event: UnsafeMutablePointer<pjsip_event>?) {
    PJ.registerThread()
    guard let snap = CallSnapshot.read(callID) else { return }
    let bridge = EngineBridge.shared
    if snap.state == .disconnected {
        let duration = snap.connectDuration
        bridge.updateCall(snap, mode: .remove, event: { info, _ in .callEnded(info, duration: duration) })
    } else {
        bridge.updateCall(snap, mode: .createOrUpdate, event: { info, rec in rec.announced ? .callChanged(info) : nil })
    }
    bridge.hop { await $0.handleCallStateChanged() }
}

private func pjOnIncomingCall(_ accID: pjsua_acc_id, _ callID: pjsua_call_id, _ rdata: UnsafeMutablePointer<pjsip_rx_data>?) {
    PJ.registerThread()
    let bridge = EngineBridge.shared
    PJ.warn(cpjsua_call_set_serial(callID, bridge.allocateSerial()), "store call serial")

    // Deny rules (CallOptions.denyIncoming): 603 Decline, or 433 Anonymity Disallowed for
    // anonymous callers, before the 180 and any tone; evaluated here on the PJSIP thread, so
    // the rule works whatever the app is doing. The DISCONNECTED state that follows produces
    // `.callEnded(... 603/433)`.
    let options = bridge.callOptions()
    if options.denyIncoming != .nobody {
        let fromURI = CallSnapshot.read(callID).map { RemoteParty.parse($0.remoteInfo).uri } ?? ""
        if let denial = options.denial(fromURI: fromURI, privacy: RequestHeader.value("Privacy", in: rdata)) {
            rejectIncoming(callID, code: denial.code, verb: "denied", because: denial.why)
            return
        }
    }

    // Do Not Disturb (CallOptions.doNotDisturb): 486 at once, before the 180 and any tone; the
    // DISCONNECTED state that follows produces `.callEnded(... 486)`, as below.
    if options.doNotDisturb {
        rejectBusy(callID, because: "do not disturb")
        return
    }

    // Too many calls: reject with 486 Busy Here. The DISCONNECTED state that follows
    // produces `.callEnded(... .disconnected(code: 486 ...))`, which is the event the UI sees.
    if cpjsua_active_call_count() > UInt32(Engine.maxConcurrentCalls) {
        if let snap = CallSnapshot.read(callID) { bridge.updateCall(snap, mode: .createOrUpdate) }
        bridge.engineLogger.notice("call \(callID): rejecting, more than \(Engine.maxConcurrentCalls) calls")
        if cpjsua_call_answer(callID, 486) != PJ.success {
            PJ.warn(pjsua_call_hangup(callID, 486, nil, nil), "reject call \(callID) with 486")
        }
        return
    }

    // Single-call mode (CallOptions.incomingWhileOnCall == .busy): 486 at once, same path as
    // above. The UI notes the rejected call from that `.callEnded` and this log line.
    if options.incomingWhileOnCall == .busy, bridge.hasCallInProgress(except: callID) {
        rejectBusy(callID, because: "single-call mode, another call in progress")
        return
    }

    // Intercom / paging: Call-Info: <...>;answer-after=N (AutoAnswerPolicy decides). Honoured
    // only from the account's own server: anyone who reaches the SIP port could otherwise
    // make us answer with the microphone open.
    var trustedAfter: Int?
    let after = Int(cpjsua_rdata_answer_after(rdata))
    if after >= 0 {
        let source = SignallingSource.read(rdata)
        if let source, bridge.isTrustedSource(source, account: accID) {
            trustedAfter = after
        } else {
            bridge.warn("call \(callID): ignored answer-after from untrusted source \(source?.description ?? "unknown")")
        }
    }
    let answerAfter = trustedAfter

    // Ring: 180 Ringing goes out now; the call waits in EARLY until answer()/reject().
    PJ.warn(cpjsua_call_answer(callID, 180), "call \(callID): 180 Ringing")
    guard let snap = CallSnapshot.read(callID) else { return }
    bridge.updateCall(snap, mode: .createOrUpdate, mutate: {
        $0.announced = true
        $0.answerAfter = answerAfter
    }, event: { info, _ in
        if case .disconnected = info.state { return nil }
        return .incomingCall(info)
    })
    bridge.hop { await $0.handleCallStateChanged() }
}

/// Answers a new incoming call 486 Busy Here from `on_incoming_call` (Do Not Disturb, single-call
/// mode) with a `.log` line; the DISCONNECTED state that follows emits `.callEnded(... 486)`.
private func rejectBusy(_ callID: pjsua_call_id, because why: String) {
    rejectIncoming(callID, code: 486, verb: "rejected", because: why)
}

/// Answers a new incoming call with a final `code` from `on_incoming_call` and logs
/// "engine: call N from X <verb> with <code> <reason> (<why>)"; the DISCONNECTED state that
/// follows emits `.callEnded(... code)`.
private func rejectIncoming(_ callID: pjsua_call_id, code: Int, verb: String, because why: String) {
    let bridge = EngineBridge.shared
    let snap = CallSnapshot.read(callID)
    if let snap { bridge.updateCall(snap, mode: .createOrUpdate) }
    let from = snap.map { party -> String in
        let p = RemoteParty.parse(party.remoteInfo)
        return p.number.isEmpty ? p.uri : p.number
    } ?? "unknown"
    let reason = PJ.string(pjsip_get_status_text(Int32(code)).pointee)
    let text = "engine: call \(callID) from \(from) \(verb) with \(code) \(reason) (\(why))"
    bridge.engineLogger.notice("\(text, privacy: .public)")
    bridge.emit(.log(level: 3, text))
    if cpjsua_call_answer(callID, UInt32(code)) != PJ.success {
        PJ.warn(pjsua_call_hangup(callID, UInt32(code), nil, nil), "reject call \(callID) with \(code)")
    }
}

/// Headers of a received request (`cpjsua_rdata_header`).
enum RequestHeader {
    static func value(_ name: String, in rdata: UnsafeMutablePointer<pjsip_rx_data>?) -> String? {
        guard let rdata else { return nil }
        var buf = [CChar](repeating: 0, count: 512)
        let n = cpjsua_rdata_header(rdata, name, &buf, UInt32(buf.count))
        guard n >= 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

private func pjOnCallMediaState(_ callID: pjsua_call_id) {
    PJ.registerThread()
    guard let snap = CallSnapshot.read(callID) else { return }
    let bridge = EngineBridge.shared
    bridge.updateCall(snap, mode: .createOrUpdate, event: { info, rec in rec.announced ? .callChanged(info) : nil })
    let slot = callID
    bridge.hop { engine in
        await engine.handleMediaStateChanged(slot)
    }
}

private func pjOnCallReplaced(_ oldCallID: pjsua_call_id, _ newCallID: pjsua_call_id) {
    PJ.registerThread()
    guard let snap = CallSnapshot.read(newCallID) else { return }
    // The replacing call is auto-answered by pjsua; show it as a regular call.
    EngineBridge.shared.updateCall(snap, mode: .createOrUpdate, mutate: { $0.announced = true },
                                   event: { info, _ in .callChanged(info) })
}

private func pjOnRegStarted2(_ accID: pjsua_acc_id, _ info: UnsafeMutablePointer<pjsua_reg_info>?) {
    guard let info, info.pointee.renew != 0 else { return }
    let bridge = EngineBridge.shared
    guard let id = bridge.account(for: accID)?.id else { return }
    // Refreshes of a working registration do not flicker the UI through "registering",
    // retries keep showing "reconnecting".
    bridge.showRegistering(id)
}

private func pjOnRegState2(_ accID: pjsua_acc_id, _ info: UnsafeMutablePointer<pjsua_reg_info>?) {
    let bridge = EngineBridge.shared
    guard let account = bridge.account(for: accID) else { return }
    let id = account.id
    var new: RegistrationState
    var source: SignallingSource?
    var transientError: String?
    if let info, let param = info.pointee.cbparam {
        let p = param.pointee
        source = SignallingSource.read(p.rdata)
        new = RegistrationMapping.state(
            renew: info.pointee.renew != 0, status: p.status, code: Int(p.code),
            reason: PJ.string(p.reason), expiration: p.expiration,
            notSpecified: cpjsua_regc_expiration_not_specified(),
            interval: account.registrationInterval)
        let reason = PJ.string(p.reason)
        if case .failed = new, RegistrationMapping.isTemporary(status: p.status, code: Int(p.code), reason: reason,
                                                               onlineStable: bridge.onlineStable()) {
            transientError = RegistrationMapping.errorText(status: p.status, code: Int(p.code), reason: reason)
        }
    } else if let info, info.pointee.renew == 0 {
        new = .unregistered
    } else {
        new = .failed(code: 0, reason: "Registration failed")
        transientError = "Registration failed"
    }

    // The server that accepted the REGISTER is the trusted source of intercom INVITEs.
    let wasRegistered: Bool
    if case .registered = bridge.registration(of: id) { wasRegistered = true } else { wasRegistered = false }
    if case .registered = new {
        if let source { bridge.setRegistrarSource(accID, source) }
        // Subscriptions that failed while the account was not registered: retry now, not in 300 s.
        if !wasRegistered { bridge.hop { await $0.refreshPresenceSubscriptions(accountIndex: accID) } }
    } else {
        bridge.setRegistrarSource(accID, nil)
    }

    let pending = bridge.takePendingRegistration(id)
    // A temporary failure of an account that should be registered: retry with backoff
    // (pjsua's own retry is off). Anything else ends the series of attempts.
    var retry: (attempt: Int, delay: TimeInterval)?
    if let transientError, account.wantsRegistration, pending != false {
        retry = bridge.registrationFailedTemporarily(id, lastError: transientError)
        if let retry {
            new = .reconnecting(attempt: retry.attempt, nextRetryIn: retry.delay, lastError: transientError)
        }
    } else {
        bridge.resetRetryAttempts(id)
    }

    switch pending {
    case false?:
        // Switched off while this transaction was in flight: its result no longer matters
        // (the UI already shows "unregistered"); send the un-REGISTER now.
        bridge.hop { await $0.applyPendingRegistration(id, false) }
    case true?:
        bridge.setRegistration(id, new)
        if case .registered = new {} else {
            bridge.hop { await $0.applyPendingRegistration(id, true) }
        }
    case nil:
        if case .registered = new, !account.wantsRegistration {
            // pjsua re-registered an account that is switched off (e.g. while handling a
            // network change): take the binding back instead of showing it as registered.
            bridge.warn("account \(id.raw): unexpected REGISTER result for an account that is off; unregistering")
            bridge.hop { await $0.applyPendingRegistration(id, false) }
        } else {
            bridge.setRegistration(id, new)
        }
    }
    if let retry {
        bridge.hop { await $0.scheduleRegistrationRetry(id, attempt: retry.attempt, after: retry.delay) }
    }
}

/// Final responses to requests we sent in a call: the re-INVITE after a network change and
/// the media watchdog's OPTIONS probe.
private func pjOnCallTsxState(_ callID: pjsua_call_id, _ tsx: UnsafeMutablePointer<pjsip_transaction>?,
                              _ event: UnsafeMutablePointer<pjsip_event>?) {
    var code: Int32 = 0
    let kind = cpjsua_tsx_final(tsx, &code)
    guard kind != 0 else { return }
    PJ.registerThread()
    let bridge = EngineBridge.shared
    guard let rec = bridge.record(callID) else { return }
    let status = Int(code)
    if status == 401 || status == 407 { return }    // pjsua repeats it with credentials
    let id = CallID(raw: callID, serial: rec.serial)
    if kind == 2 {
        guard rec.probing else { return }
        bridge.hop { await $0.probeFinished(id, code: status) }
        return
    }
    guard rec.reinvitePending else { return }
    // Which round's re-INVITE this answers: the engine's own in-flight one, or pjsua's of the
    // current round. Anything else (a hold re-INVITE sent before the change) is unattributed.
    var sentRound = rec.reinviteInFlight
    if sentRound == nil, bridge.ipChangeReinvited().contains(rec.serial) { sentRound = bridge.currentIPChangeRound() }
    if rec.reinviteInFlight != nil, let snap = CallSnapshot.read(callID) {
        bridge.updateCall(snap, mode: .updateOnly, mutate: { $0.reinviteInFlight = nil })
    }
    let round = sentRound
    bridge.hop { await $0.reinviteFinished(id, code: status, sentRound: round) }
}

/// TCP/TLS connection of a registration closed: retry the REGISTER with backoff.
private func pjOnTransportState(_ tp: UnsafeMutablePointer<pjsip_transport>?, _ state: pjsip_transport_state,
                                _ info: UnsafePointer<pjsip_transport_state_info>?) {
    guard state == PJSIP_TP_STATE_DISCONNECTED || state == PJSIP_TP_STATE_SHUTDOWN, let tp else { return }
    // The accounts whose registration uses exactly this transport (pjsua releases it from
    // their registration right after this callback).
    var indices = [pjsua_acc_id](repeating: PJ.invalidID, count: 16)
    let n = Int(cpjsua_accounts_on_transport(tp, &indices, UInt32(indices.count)))
    guard n > 0 else { return }
    let bridge = EngineBridge.shared
    let ids = indices.prefix(n).compactMap { bridge.account(for: $0)?.id }
    guard !ids.isEmpty else { return }
    var remote = cpjsua_pkt_source()
    var peer = "server"
    var kind = "connection"
    if cpjsua_transport_remote(tp, &remote) == PJ.success {
        let t: TransportKind? = UInt32(bitPattern: remote.transport) == PJSIP_TRANSPORT_TLS.rawValue ? .tls
            : UInt32(bitPattern: remote.transport) == PJSIP_TRANSPORT_TCP.rawValue ? .tcp : nil
        peer = SignallingSource(address: PJ.string(tuple: remote.addr), port: Int(remote.port), transport: t).description
        kind = "\(t?.rawValue.uppercased() ?? "SIP") connection"
    }
    let reason = info.map { PJ.errorText($0.pointee.status) } ?? ""
    let what = state == PJSIP_TP_STATE_SHUTDOWN ? "shut down" : "disconnected"
    let text = "\(kind) to \(peer) \(what)" + (reason.isEmpty || info?.pointee.status == 0 ? "" : " (\(reason))")
    bridge.hop { await $0.registrationTransportLost(ids, reason: text) }
}

/// Progress of pjsua_handle_ip_change (pjsua_core.c / pjsua_acc.c).
private func pjOnIPChangeProgress(_ op: pjsua_ip_change_op, _ status: pj_status_t,
                                  _ info: UnsafePointer<pjsua_ip_change_op_info>?) {
    PJ.registerThread()
    let bridge = EngineBridge.shared
    let result = status == PJ.success ? "ok" : PJ.errorText(status)
    switch op {
    case PJSUA_IP_CHANGE_OP_SHUTDOWN_TP:
        bridge.emit(.log(level: 4, "engine: network change: TCP/TLS connections shut down (\(result))"))
    case PJSUA_IP_CHANGE_OP_RESTART_LIS:
        let tp = info?.pointee.lis_restart.transport_id ?? -1
        bridge.emit(.log(level: 3, "engine: network change: listener \(tp) restarted (\(result))"))
    case PJSUA_IP_CHANGE_OP_ACC_SHUTDOWN_TP:
        let acc = info?.pointee.acc_shutdown_tp.acc_id ?? -1
        bridge.emit(.log(level: 4, "engine: network change: account \(acc) transport shut down (\(result))"))
    case PJSUA_IP_CHANGE_OP_ACC_UPDATE_CONTACT:
        let acc = info?.pointee.acc_update_contact.acc_id ?? -1
        let code = info?.pointee.acc_update_contact.code ?? 0
        bridge.emit(.log(level: 3, "engine: network change: account \(acc) re-REGISTER \(code > 0 ? "answered \(code)" : "sent") (\(result))"))
        if code > 0 || status != PJ.success {
            let round = bridge.currentIPChangeRound()
            bridge.hop { await $0.ipChangeAccountAnswered(acc, round: round) }
        }
    case PJSUA_IP_CHANGE_OP_ACC_HANGUP_CALLS:
        let call = info?.pointee.acc_hangup_calls.call_id ?? -1
        bridge.emit(.log(level: 3, "engine: network change: pjsua hung up unconfirmed call \(call)"))
    case PJSUA_IP_CHANGE_OP_ACC_REINVITE_CALLS:
        let slot = info?.pointee.acc_reinvite_calls.call_id ?? -1
        guard slot >= 0, let rec = bridge.record(slot) else { return }
        if status == PJ.success {
            bridge.noteIPChangeReinvite(serial: rec.serial)
            bridge.emit(.log(level: 3, "engine: call \(CallID(raw: slot, serial: rec.serial)): re-INVITE after network change sent"))
        } else {
            bridge.emit(.log(level: 2, "engine: call \(CallID(raw: slot, serial: rec.serial)): re-INVITE after network change failed: \(result)"))
        }
    case PJSUA_IP_CHANGE_OP_COMPLETED:
        let round = bridge.currentIPChangeRound()
        bridge.hop { await $0.ipChangeCompleted(round: round) }
    default:
        break
    }
}

private func pjOnCallTransferStatus(
    _ callID: pjsua_call_id, _ code: Int32, _ text: UnsafePointer<pj_str_t>?,
    _ final: pj_bool_t, _ cont: UnsafeMutablePointer<pj_bool_t>?
) {
    let bridge = EngineBridge.shared
    let serial = bridge.record(callID)?.serial ?? UInt64(cpjsua_call_serial(callID))
    let id = CallID(raw: callID, serial: serial)
    let isFinal = final != 0
    bridge.emit(.transferStatus(id, code: Int(code), final: isFinal))
    if !isFinal {
        cont?.pointee = 1   // keep receiving NOTIFYs
    } else if code / 100 == 2 {
        // Transfer accepted by the target: our leg is no longer needed.
        bridge.hop { await $0.handleTransferSucceeded(id) }
    }
}

private func pjOnDtmfDigit2(_ callID: pjsua_call_id, _ info: UnsafePointer<pjsua_dtmf_info>?) {
    guard let info, let scalar = Unicode.Scalar(info.pointee.digit) else { return }
    let bridge = EngineBridge.shared
    let serial = bridge.record(callID)?.serial ?? UInt64(cpjsua_call_serial(callID))
    bridge.emit(.dtmfReceived(CallID(raw: callID, serial: serial), digit: Character(scalar)))
}

/// Voicemail indicator: a message-summary NOTIFY of our own MWI subscription (`mwi_enabled`)
/// or an unsolicited one pjsua routed to the account (`enable_unsolicited_mwi`, its default).
private func pjOnMwiInfo(_ accID: pjsua_acc_id, _ info: UnsafeMutablePointer<pjsua_mwi_info>?) {
    let bridge = EngineBridge.shared
    guard let account = bridge.account(for: accID) else { return }
    var buf = [CChar](repeating: 0, count: 4096)
    var solicited: Int32 = 0
    let n = cpjsua_mwi_body(info, &buf, UInt32(buf.count), &solicited)
    guard n >= 0 else {
        bridge.emit(.log(level: 4, "engine: account \(account.id.raw): message-summary NOTIFY without a body"))
        return
    }
    let body = String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    bridge.reportVoicemail(account.id, MessageSummary.parse(body), solicited: solicited != 0)
}

private func pjOnBuddyState(_ buddyID: pjsua_buddy_id) {
    PJ.registerThread()
    guard let buddy = BuddySnapshot.read(buddyID) else { return }
    EngineBridge.shared.reportPresence(buddy)
}

/// Runs right before `on_buddy_state` for the same NOTIFY: remembers whether its PIDF had an
/// RPID `on-the-phone` activity (Asterisk/FreePBX), which pjrpid reports as unknown.
private func pjOnBuddyEvsubState(_ buddyID: pjsua_buddy_id, _ sub: OpaquePointer?,
                                 _ event: UnsafeMutablePointer<pjsip_event>?) {
    PJ.registerThread()
    let hit = cpjsua_event_notify_body_contains(event, "on-the-phone")
    guard hit >= 0, let token = BuddySnapshot.token(buddyID) else { return }
    EngineBridge.shared.setOnThePhone(token: token, hit == 1)
}
