internal import CPJSUA
import Foundation

extension Engine {
    public func makeCall(to dial: DialString, from account: AccountID) throws -> CallID {
        try requireStarted()
        guard let entry = accounts[account] else { throw EngineError.unknownAccount(account) }
        guard Int(cpjsua_active_call_count()) < Engine.maxConcurrentCalls else {
            throw EngineError.tooManyCalls(limit: Engine.maxConcurrentCalls)
        }
        let serial = bridge.allocateSerial()
        var slot = PJ.invalidID
        try PJ.check(cpjsua_call_make(entry.index, dial.uri, serial, &slot), "call \(dial.uri)")
        return CallID(raw: slot, serial: serial)
    }

    public func answer(_ id: CallID) throws {
        let slot = try liveSlot(id)
        try PJ.check(cpjsua_call_answer(slot, 200), "answer")
        reconcileTones()
    }

    public func reject(_ id: CallID, code: Int = 486) throws {
        guard (300...699).contains(code) else { throw EngineError.invalidArgument("reject code \(code)") }
        let slot = try liveSlot(id)
        try PJ.check(pjsua_call_hangup(slot, UInt32(code), nil, nil), "reject")
        reconcileTones()
    }

    public func hangup(_ id: CallID) throws {
        let slot = try liveSlot(id)
        try PJ.check(pjsua_call_hangup(slot, 0, nil, nil), "hangup")
        reconcileTones()
    }

    public func hangupAll() {
        guard isStarted, PJ.registerThread() else { return }
        pjsua_call_hangup_all()
        reconcileTones()
    }

    /// Local hold (re-INVITE sendonly) or resume (re-INVITE with PJSUA_CALL_UNHOLD).
    /// Holding one call does not resume another; the UI decides.
    public func setHold(_ id: CallID, _ on: Bool) throws {
        let slot = try liveSlot(id)
        if on {
            try PJ.check(pjsua_call_set_hold2(slot, 0, nil), "hold")
        } else {
            try PJ.check(cpjsua_call_unhold(slot), "unhold")
        }
        try updateRecord(id) { $0.localHold = on }
    }

    /// Disconnects (or reconnects) the microphone from the call's conference port.
    public func setMute(_ id: CallID, _ on: Bool) throws {
        _ = try liveSlot(id)
        try updateRecord(id) { $0.isMuted = on }
    }

    /// RFC 2833 telephone-events; SIP INFO when the remote did not offer telephone-event.
    public func sendDTMF(_ id: CallID, _ digits: String) throws {
        let allowed = Set("0123456789*#ABCDabcd")
        guard !digits.isEmpty, digits.allSatisfy({ allowed.contains($0) }) else {
            throw EngineError.invalidArgument("DTMF digits \"\(digits)\"")
        }
        let slot = try liveSlot(id)
        var usedInfo: Int32 = 0
        try PJ.check(cpjsua_call_send_dtmf(slot, digits, &usedInfo), "DTMF")
        if usedInfo != 0 {
            bridge.engineLogger.info("call \(slot): DTMF sent with SIP INFO (no RFC 2833 at remote)")
        }
    }

    public func blindTransfer(_ id: CallID, to dial: DialString) throws {
        let slot = try liveSlot(id)
        let arena = CStringArena()
        var dest = arena.pj(dial.uri)
        try withExtendedLifetime(arena) {
            try PJ.check(pjsua_call_xfer(slot, &dest, nil), "transfer to \(dial.uri)")
        }
    }

    /// REFER with Replaces: the party on `id` is connected to the party on `other`.
    public func attendedTransfer(_ id: CallID, replacing other: CallID) throws {
        let slot = try liveSlot(id)
        let otherSlot = try liveSlot(other)
        try PJ.check(pjsua_call_xfer_replaces(slot, otherSlot, UInt32(PJSUA_XFER_NO_REQUIRE_REPLACES), nil),
                     "attended transfer")
    }

    /// Every live, known call (disconnected ones excluded), in pjsua slot order (not by age).
    public func calls() -> [CallInfo] {
        guard isStarted, PJ.registerThread() else { return [] }
        return CallSnapshot.allSlots().compactMap { slot in
            guard let snap = CallSnapshot.read(slot), snap.state != .disconnected else { return nil }
            return bridge.updateCall(snap, mode: .updateOnly)?.0
        }
    }

    /// RTP counters of the call's audio stream.
    public func mediaStats(_ id: CallID) throws -> CallMediaStats {
        let slot = try liveSlot(id)
        var st = cpjsua_rtp_stat()
        try PJ.check(cpjsua_call_rtp_stat(slot, &st), "stream statistics")
        return CallMediaStats(
            rxPackets: Int(st.rx_packets),
            txPackets: Int(st.tx_packets),
            rxLost: Int(st.rx_lost),
            rxJitterMs: Double(st.rx_jitter_usec_mean) / 1000,
            rttMs: Double(st.rtt_usec_mean) / 1000
        )
    }

    // MARK: internals

    /// Validates that `id` still names the same live call and returns its pjsua slot.
    func liveSlot(_ id: CallID) throws -> pjsua_call_id {
        try requireStarted()
        guard id.raw >= 0, id.raw < Int32(pjsua_call_get_max_count()),
              pjsua_call_is_active(id.raw) != 0,
              let snap = CallSnapshot.read(id.raw),
              (bridge.record(id.raw)?.serial ?? snap.serial) == id.serial
        else { throw EngineError.noSuchCall(id) }
        return id.raw
    }

    /// Changes the call's record and announces it. Never creates a record: if the call
    /// ended meanwhile, nothing is emitted and `.noSuchCall` is thrown. Rewires the
    /// conference bridge unless `reconcile` is false (the caller does it once at the end).
    func updateRecord(_ id: CallID, reconcile: Bool = true,
                      _ change: @escaping @Sendable (inout CallRecord) -> Void) throws {
        guard let snap = CallSnapshot.read(id.raw), snap.serial == id.serial,
              bridge.updateCall(snap, mode: .updateOnly, mutate: change, event: { info, rec in
                  rec.announced ? .callChanged(info) : nil
              }) != nil
        else { throw EngineError.noSuchCall(id) }
        if reconcile { reconcileMedia() }
    }

    // Follow-up work scheduled by the callbacks (asynchronously, see EngineBridge).

    func handleCallStateChanged() {
        reconcileTones()
        finishEndedCalls()
    }

    func handleMediaStateChanged(_ slot: pjsua_call_id) {
        reconcileMedia()
        reconcileTones()
    }

    func handleTransferSucceeded(_ id: CallID) {
        guard let slot = try? liveSlot(id) else { return }
        PJ.warn(pjsua_call_hangup(slot, 0, nil, nil), "hang up transferred call \(slot)")
    }
}
