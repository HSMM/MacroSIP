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
//     while holding it);
//  3. `yield` an EngineEvent to the AsyncStream continuation (non-blocking, unbounded);
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
}

final class EngineBridge: Sendable {
    static let shared = EngineBridge()

    struct State: Sendable {
        var sink: AsyncStream<EngineEvent>.Continuation?
        var engine: Engine?
        var accounts: [Int32: AccountID] = [:]                  // pjsua_acc_id -> AccountID
        var registration: [AccountID: RegistrationState] = [:]
        var calls: [Int32: CallRecord] = [:]                    // pjsua_call_id -> record
        var nextSerial: UInt64 = 1
    }

    let state = OSAllocatedUnfairLock(initialState: State())
    let logger = Logger(subsystem: "com.hsmm.macrosip", category: "pjsip")
    let engineLogger = Logger(subsystem: "com.hsmm.macrosip", category: "engine")

    // MARK: lifecycle

    func attach(_ engine: Engine, sink: AsyncStream<EngineEvent>.Continuation) throws {
        let ok = state.withLock { st -> Bool in
            guard st.engine == nil else { return false }
            st = State()
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

    func setAccount(_ index: Int32, _ id: AccountID?) {
        state.withLock { st in
            if let id {
                st.accounts[index] = id
            } else if let old = st.accounts.removeValue(forKey: index) {
                st.registration[old] = nil
            }
        }
    }

    func accountID(for index: Int32) -> AccountID? {
        state.withLock { $0.accounts[index] }
    }

    func registration(of id: AccountID) -> RegistrationState {
        state.withLock { $0.registration[id] ?? .unregistered }
    }

    /// Stores and emits a registration state (only when it changed).
    func setRegistration(_ id: AccountID, _ new: RegistrationState, force: Bool = false) {
        let changed = state.withLock { st -> Bool in
            guard st.accounts.values.contains(id) else { return false }
            let old = st.registration[id]
            st.registration[id] = new
            return force || old != new
        }
        if changed { emit(.registration(id, new)) }
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

    /// Builds the public CallInfo for a snapshot, creating or refreshing the slot's record.
    ///
    /// - `mutate` edits the record under the lock (mute/hold flags, announcement).
    /// - `remove` drops the record afterwards (the call is over).
    /// A disconnected call never gets a new record, so late readers cannot resurrect it.
    func callInfo(
        _ snap: CallSnapshot,
        remove: Bool = false,
        mutate: (@Sendable (inout CallRecord) -> Void)? = nil
    ) -> (CallInfo, CallRecord) {
        let now = Date()
        let (record, newSerial) = state.withLock { st -> (CallRecord, UInt64?) in
            var serial = snap.serial
            var newSerial: UInt64?
            let existing = st.calls[snap.slot]
            let clash = st.calls.contains { $0.key != snap.slot && $0.value.serial == serial }
            if serial == 0 || (existing?.serial != serial && clash) {
                // pjsua created this call itself (REFER, Replaces) and copied or left user_data.
                serial = st.nextSerial
                st.nextSerial += 1
                newSerial = serial
            }
            var rec: CallRecord
            if let existing, existing.serial == serial {
                rec = existing
            } else {
                rec = CallRecord(
                    serial: serial,
                    accountID: st.accounts[snap.accIndex] ?? .unknown,
                    direction: snap.isOutgoing ? .outgoing : .incoming,
                    announced: snap.isOutgoing
                )
            }
            mutate?(&rec)
            if let codec = snap.codec {
                rec.lastCodec = codec
                rec.lastSecure = snap.isSecure
            }
            if snap.state == .confirmed, rec.startedAt == nil {
                rec.startedAt = now.addingTimeInterval(-snap.connectDuration)
            }
            if remove {
                if st.calls[snap.slot]?.serial == serial { st.calls[snap.slot] = nil }
            } else if snap.state != .disconnected || existing?.serial == serial {
                st.calls[snap.slot] = rec
            }
            return (rec, newSerial)
        }
        if let newSerial {
            PJ.warn(cpjsua_call_set_serial(snap.slot, newSerial), "store call serial")
        }
        return (EngineBridge.makeInfo(snap, record), record)
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
            isRecording: false,
            inConference: false,
            codec: s.state == .disconnected ? (s.codec ?? r.lastCodec) : s.codec,
            isSecure: s.state == .disconnected ? (s.codec != nil ? s.isSecure : r.lastSecure) : s.isSecure
        )
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
        let (info, _) = bridge.callInfo(snap, remove: true)
        bridge.emit(.callEnded(info, duration: snap.connectDuration))
    } else {
        let (info, record) = bridge.callInfo(snap)
        if record.announced { bridge.emit(.callChanged(info)) }
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
        if let snap = CallSnapshot.read(callID) { _ = bridge.callInfo(snap) }
        bridge.engineLogger.notice("call \(callID): rejecting, more than \(Engine.maxConcurrentCalls) calls")
        if cpjsua_call_answer(callID, 486) != PJ.success {
            PJ.warn(pjsua_call_hangup(callID, 486, nil, nil), "reject call \(callID) with 486")
        }
        return
    }

    // Ring: 180 Ringing goes out now; the call waits in EARLY until answer()/reject().
    let status = cpjsua_call_answer(callID, 180)
    if status != PJ.success {
        bridge.engineLogger.error("call \(callID): 180 Ringing failed: \(PJ.errorText(status), privacy: .public)")
    }
    guard let snap = CallSnapshot.read(callID) else { return }
    let (info, _) = bridge.callInfo(snap) { $0.announced = true }
    if case .disconnected = info.state { return }
    bridge.emit(.incomingCall(info))
    bridge.hop { await $0.handleCallStateChanged() }
}

private func pjOnCallMediaState(_ callID: pjsua_call_id) {
    PJ.registerThread()
    guard let snap = CallSnapshot.read(callID) else { return }
    let bridge = EngineBridge.shared
    let (info, record) = bridge.callInfo(snap)
    if record.announced { bridge.emit(.callChanged(info)) }
    let slot = callID
    bridge.hop { engine in
        await engine.handleMediaStateChanged(slot)
    }
}

private func pjOnCallReplaced(_ oldCallID: pjsua_call_id, _ newCallID: pjsua_call_id) {
    PJ.registerThread()
    guard let snap = CallSnapshot.read(newCallID) else { return }
    let bridge = EngineBridge.shared
    // The replacing call is auto-answered by pjsua; show it as a regular call.
    let (info, _) = bridge.callInfo(snap) { $0.announced = true }
    bridge.emit(.callChanged(info))
}

private func pjOnRegStarted2(_ accID: pjsua_acc_id, _ info: UnsafeMutablePointer<pjsua_reg_info>?) {
    guard let info, info.pointee.renew != 0 else { return }
    let bridge = EngineBridge.shared
    guard let id = bridge.accountID(for: accID) else { return }
    // Refreshes of a working registration do not flicker the UI through "registering".
    if case .registered = bridge.registration(of: id) { return }
    bridge.setRegistration(id, .registering)
}

private func pjOnRegState2(_ accID: pjsua_acc_id, _ info: UnsafeMutablePointer<pjsua_reg_info>?) {
    let bridge = EngineBridge.shared
    guard let id = bridge.accountID(for: accID) else { return }
    let new: RegistrationState
    if let info, info.pointee.renew == 0 {
        // Result of an un-REGISTER: the user switched the account off, whatever the server said.
        new = .unregistered
    } else if let info, let param = info.pointee.cbparam {
        let p = param.pointee
        let code = Int(p.code)
        let reason = PJ.string(p.reason)
        if p.status != PJ.success {
            new = .failed(code: code, reason: reason.isEmpty ? PJ.errorText(p.status) : reason)
        } else if code / 100 == 2 {
            // PJSIP reports "expires not specified" as UInt32.max.
            let expires = p.expiration >= UInt32(Int32.max) ? 0 : Int(p.expiration)
            new = expires > 0 ? .registered(expires: expires) : .unregistered
        } else {
            new = .failed(code: code, reason: reason.isEmpty ? "Registration failed" : reason)
        }
    } else {
        new = .failed(code: 0, reason: "Registration failed")
    }
    bridge.setRegistration(id, new)
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
