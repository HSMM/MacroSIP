internal import CPJSUA
import Foundation

/// What occupies a conference bridge slot (see `Engine.slotOwners`).
enum PortOwner: Hashable, Sendable {
    case soundDevice
    case call(serial: UInt64)
    case recorder(pjsua_recorder_id)
}

// MARK: - Conference

extension Engine {
    /// Joins the calls into one local conference (PJSIP conference bridge, mixed on this Mac):
    /// every leg hears every other leg, the microphone and the speaker stay on each leg.
    /// 2...`maxConcurrentCalls` calls; each must be live and connected (`.connected` or
    /// `.held`; ringing or dialling calls throw `.invalidArgument`). Held legs are resumed
    /// first (re-INVITE). Legs already in a conference bring it along (conferences are
    /// joined). Sets `inConference` on every leg (`.callChanged`). Mute and hold keep
    /// working per leg: a held leg is cut off from everyone until resumed, a muted leg only
    /// stops receiving the microphone.
    public func merge(_ ids: [CallID]) throws {
        try requireStarted()
        var unique: [CallID] = []
        for id in ids where !unique.contains(id) { unique.append(id) }
        guard unique.count >= 2 else { throw EngineError.invalidArgument("merge needs at least two calls") }
        guard unique.count <= Engine.maxConcurrentCalls else {
            throw EngineError.invalidArgument("merge takes at most \(Engine.maxConcurrentCalls) calls")
        }

        var legs: [(id: CallID, held: Bool, conference: UInt64?)] = []
        for id in unique {
            let slot = try liveSlot(id)
            guard let snap = CallSnapshot.read(slot), let rec = bridge.record(slot), rec.serial == id.serial else {
                throw EngineError.noSuchCall(id)
            }
            guard snap.state == .confirmed else {
                throw EngineError.invalidArgument("call \(id) is not connected")
            }
            legs.append((id, rec.localHold || snap.mediaStatus == .localHold, rec.conference))
        }

        // Rewire whatever happened, also when a leg ended half-way (its update throws).
        defer { reconcileMedia() }
        for leg in legs where leg.held {
            try PJ.check(cpjsua_call_unhold(leg.id.raw), "resume \(leg.id) for the conference")
            try updateRecord(leg.id, reconcile: false) { $0.localHold = false }
        }

        // Keep the lowest existing conference id and fold the others (with their legs) into it.
        let existing = Set(legs.compactMap(\.conference))
        let group: UInt64
        if let lowest = existing.min() {
            group = lowest
        } else {
            group = nextConferenceID
            nextConferenceID += 1
        }
        for id in unique {
            try updateRecord(id, reconcile: false) { $0.conference = group }
        }
        for slot in CallSnapshot.allSlots() {
            guard let rec = bridge.record(slot), let c = rec.conference, c != group, existing.contains(c) else { continue }
            try? updateRecord(CallID(raw: slot, serial: rec.serial), reconcile: false) { $0.conference = group }
        }
    }

    /// Takes the call out of its conference. It stays connected to the microphone and the
    /// speaker (the UI holds it if it wants). When only one leg remains, that leg leaves the
    /// conference too. Both get `.callChanged` with `inConference == false`. A conference
    /// recording owned by the split leg moves to a remaining leg (see `rehomeRecordings`).
    public func split(_ id: CallID) throws {
        let slot = try liveSlot(id)
        guard let rec = bridge.record(slot), rec.serial == id.serial else { throw EngineError.noSuchCall(id) }
        guard rec.conference != nil else { throw EngineError.invalidArgument("call \(id) is not in a conference") }
        defer { reconcileMedia() }
        try updateRecord(id, reconcile: false) { $0.conference = nil }
        rehomeRecordings()                   // while the other legs are still in the conference
        dissolveSingleLegConferences()
    }

    /// A conference with one live leg is no conference: clear its flag (`.callChanged`).
    func dissolveSingleLegConferences() {
        var legs: [UInt64: [CallID]] = [:]
        for slot in CallSnapshot.allSlots() {
            guard let snap = CallSnapshot.read(slot), snap.state != .disconnected,
                  let rec = bridge.record(slot), rec.serial == snap.serial, let c = rec.conference else { continue }
            legs[c, default: []].append(CallID(raw: slot, serial: rec.serial))
        }
        for (_, ids) in legs where ids.count == 1 {
            try? updateRecord(ids[0], reconcile: false) { $0.conference = nil }
        }
    }
}

// MARK: - Conference bridge wiring

extension Engine {
    /// Wires the conference bridge from the current state of every call and recording.
    /// Per live call whose media is up (active or remote hold): call -> speaker, microphone ->
    /// call unless muted; conference legs (media up) transmit to each other; a recorder gets
    /// its call, the call's conference partners and (unless muted) the microphone. A call on
    /// local hold or without media is connected to nothing. Idempotent; runs after every
    /// media, mute, hold, conference and recording change.
    func reconcileMedia() {
        guard isStarted, PJ.registerThread() else { return }
        rehomeRecordings()

        struct Leg {
            var id: CallID
            var port: pjsua_conf_port_id
            var up: Bool
            var muted: Bool
            var conference: UInt64?
        }
        var legs: [Leg] = []
        var owners: [pjsua_conf_port_id: PortOwner] = [0: .soundDevice]
        for slot in CallSnapshot.allSlots() {
            guard let snap = CallSnapshot.read(slot), snap.state != .disconnected, snap.confSlot != PJ.invalidID,
                  let rec = bridge.record(slot), rec.serial == snap.serial else { continue }
            let up = snap.mediaStatus == .active || snap.mediaStatus == .remoteHold
            legs.append(Leg(id: CallID(raw: slot, serial: rec.serial), port: snap.confSlot, up: up,
                            muted: rec.isMuted, conference: rec.conference))
            owners[snap.confSlot] = .call(serial: rec.serial)
        }
        for recording in recordings.values where recording.confSlot != PJ.invalidID {
            owners[recording.confSlot] = .recorder(recording.recorderID)
        }

        // Requests that involve a port that is gone or now belongs to someone else are void:
        // PJSIP removed those connections together with the old port.
        // (Every request is made below, after `slotOwners` was updated, so its ports are known.)
        requestedWiring = requestedWiring.filter { wire, _ in
            [wire.src, wire.sink].allSatisfy { owners[$0] != nil && owners[$0] == slotOwners[$0] }
        }
        slotOwners = owners

        var desired: Set<Wire> = []
        for leg in legs where leg.up {
            desired.insert(Wire(src: leg.port, sink: 0))
            if !leg.muted { desired.insert(Wire(src: 0, sink: leg.port)) }
            if let c = leg.conference {
                for other in legs where other.up && other.conference == c && other.port != leg.port {
                    desired.insert(Wire(src: other.port, sink: leg.port))
                }
            }
        }
        for (id, recording) in recordings where recording.confSlot != PJ.invalidID {
            guard let leg = legs.first(where: { $0.id == id }), leg.up else { continue }
            desired.insert(Wire(src: leg.port, sink: recording.confSlot))
            if !leg.muted { desired.insert(Wire(src: 0, sink: recording.confSlot)) }
            if let c = leg.conference {
                for other in legs where other.up && other.conference == c && other.port != leg.port {
                    desired.insert(Wire(src: other.port, sink: recording.confSlot))
                }
            }
        }

        // Disconnect first, then connect (order of PJSIP's queue = order of our calls).
        for (wire, on) in requestedWiring where on && !desired.contains(wire) {
            connect(wire.src, wire.sink, false)
        }
        for wire in desired.sorted(by: { ($0.src, $0.sink) < ($1.src, $1.sink) }) {
            connect(wire.src, wire.sink, true)
        }
    }

    /// PJSIP 2.17 queues conference (dis)connections and applies them on the next audio
    /// frame, so `cpjsua_conf_is_connected` can lag behind our own requests. An operation is
    /// skipped only when both our last request and the applied state already match `on`;
    /// otherwise it is issued (a duplicate is harmless: PJSIP logs and ignores it).
    func connect(_ src: pjsua_conf_port_id, _ sink: pjsua_conf_port_id, _ on: Bool) {
        let wire = Wire(src: src, sink: sink)
        let applied = cpjsua_conf_is_connected(src, sink) != 0
        if requestedWiring[wire] == on && applied == on { return }
        requestedWiring[wire] = on
        PJ.warn(on ? pjsua_conf_connect(src, sink) : pjsua_conf_disconnect(src, sink),
                "conference \(on ? "connect" : "disconnect") \(src)->\(sink)")
    }

    /// Applied conference wiring of a call (tests and diagnostics).
    func wiring(of id: CallID) -> (toSpeaker: Bool, fromMic: Bool)? {
        guard isStarted, PJ.registerThread(),
              let snap = CallSnapshot.read(id.raw), snap.confSlot != PJ.invalidID else { return nil }
        return (cpjsua_conf_is_connected(snap.confSlot, 0) != 0,
                cpjsua_conf_is_connected(0, snap.confSlot) != 0)
    }

    /// Applied connection between two calls' conference ports, `from` -> `to` (tests).
    func isConnected(from: CallID, to: CallID) -> Bool {
        guard isStarted, PJ.registerThread(),
              let a = CallSnapshot.read(from.raw), let b = CallSnapshot.read(to.raw),
              a.confSlot != PJ.invalidID, b.confSlot != PJ.invalidID else { return false }
        return cpjsua_conf_is_connected(a.confSlot, b.confSlot) != 0
    }

    /// Applied connection into the recorder of `recorded` from `source`'s conference port,
    /// or from the microphone when `source` is nil (tests and diagnostics).
    func recorderHears(_ recorded: CallID, from source: CallID?) -> Bool {
        guard isStarted, PJ.registerThread(), let recording = recordings[recorded] else { return false }
        var port: pjsua_conf_port_id = 0
        if let source {
            guard let snap = CallSnapshot.read(source.raw), snap.confSlot != PJ.invalidID else { return false }
            port = snap.confSlot
        }
        return cpjsua_conf_is_connected(port, recording.confSlot) != 0
    }
}
