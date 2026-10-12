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
    }

    struct WatchedBuddy: Sendable {
        /// The URI as the caller passed it to `subscribePresence`; `.buddyPresence` carries it.
        var reportedURI: String
        var last: PresenceStatus?
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
        var calls: [Int32: CallRecord] = [:]                    // pjsua_call_id -> record
        /// `.callEnded` of recorded calls, keyed by call serial, held back until the engine
        /// finalised the recording (see `releaseDeferredEnds`).
        var deferredEnds: [UInt64: EngineEvent] = [:]
        /// Watched buddies by the token stored in their pjsua user data (buddy ids are reused).
        var watched: [UInt64: WatchedBuddy] = [:]
        /// Never reset, so CallIDs stay unique across engine restarts in one process.
        var nextSerial: UInt64 = 1
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
    }

    func detach(_ engine: Engine) {
        state.withLock { st in
            guard st.engine === engine else { return }
            let serial = st.nextSerial
            st = State()
            st.nextSerial = serial
        }
    }

    // MARK: events

    func emit(_ event: EngineEvent) {
        let sink = state.withLock { $0.sink }
        sink?.yield(event)
    }

    /// Schedules `work` on the attached engine without waiting for it.
    func hop(_ work: @escaping @Sendable (Engine) async -> Void) {
        guard let engine = state.withLock({ $0.engine }) else { return }
        Task { await work(engine) }
    }

    // MARK: accounts

    func setAccount(_ index: Int32, _ id: AccountID, registrationInterval: Int, proxy: SignallingSource? = nil) {
        state.withLock { st in
            st.accounts[index] = AccountSlot(id: id, registrationInterval: registrationInterval, proxy: proxy)
        }
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
            state = .disconnected(code: s.lastStatus, reason: s.lastStatusText)
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
            answerAfter: r.answerAfter
        )
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

    /// Emits `.buddyPresence` for a watched buddy when its status changed.
    func reportPresence(_ buddy: BuddySnapshot) {
        state.withLock { st in
            guard var w = st.watched[buddy.token] else { return }
            let activity = buddy.activity == .unknown && w.onThePhone ? .onThePhone : buddy.activity
            let status = PresenceMapping.status(basic: buddy.basic, activity: activity, note: buddy.note,
                                                subscriptionTerminated: buddy.terminated)
            guard w.last != status else { return }
            w.last = status
            st.watched[buddy.token] = w
            st.sink?.yield(.buddyPresence(contactURI: w.reportedURI, status))
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
    // Refreshes of a working registration do not flicker the UI through "registering".
    if case .registered = bridge.registration(of: id) { return }
    bridge.setRegistration(id, .registering)
}

private func pjOnRegState2(_ accID: pjsua_acc_id, _ info: UnsafeMutablePointer<pjsua_reg_info>?) {
    let bridge = EngineBridge.shared
    guard let account = bridge.account(for: accID) else { return }
    let id = account.id
    let new: RegistrationState
    var source: SignallingSource?
    if let info, let param = info.pointee.cbparam {
        let p = param.pointee
        source = SignallingSource.read(p.rdata)
        new = RegistrationMapping.state(
            renew: info.pointee.renew != 0, status: p.status, code: Int(p.code),
            reason: PJ.string(p.reason), expiration: p.expiration,
            notSpecified: cpjsua_regc_expiration_not_specified(),
            interval: account.registrationInterval)
    } else if let info, info.pointee.renew == 0 {
        new = .unregistered
    } else {
        new = .failed(code: 0, reason: "Registration failed")
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

    switch bridge.takePendingRegistration(id) {
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
        bridge.setRegistration(id, new)
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
