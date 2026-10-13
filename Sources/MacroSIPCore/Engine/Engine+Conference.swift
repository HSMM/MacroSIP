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
        // The conference resumes its legs; a hold request still waiting would undo that.
        for leg in legs { pendingHolds[leg.id] = nil }
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
    /// call unless muted; conference legs (media up) transmit to each other; a mono recorder
    /// gets its call, the call's conference partners and (unless muted) the microphone. A call on
    /// local hold or without media is connected to nothing. A stereo split recording has a
    /// local recorder (microphone only, level 0 while muted) and a remote recorder (call
    /// and conference partners). Idempotent; runs after every
    /// media, mute, hold, conference, recording and call volume change. The per-call volume is
    /// a connection level: speaker on call -> sound device, microphone on sound device -> call;
    /// every other connection (recorders, conference partners) stays at 1, so recordings and
    /// the other legs are not affected by it.
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
        for recording in recordings.values {
            for port in recording.ports where port.confSlot != PJ.invalidID {
                owners[port.confSlot] = .recorder(port.recorderID)
            }
        }

        // Requests that involve a port that is gone or now belongs to someone else are void:
        // PJSIP removed those connections together with the old port.
        // (Every request is made below, after `slotOwners` was updated, so its ports are known.)
        requestedWiring = requestedWiring.filter { wire, _ in
            [wire.src, wire.sink].allSatisfy { owners[$0] != nil && owners[$0] == slotOwners[$0] }
        }
        requestedLevels = requestedLevels.filter { requestedWiring[$0.key] == true }
        slotOwners = owners

        // Per-call volume; a call seen for the first time gets the default.
        pruneEndedCallState()
        for leg in legs where callVolumes[leg.id] == nil { callVolumes[leg.id] = defaultCallVolume }

        var levels: [Wire: Float] = [:]
        var desired: Set<Wire> = []
        for leg in legs where leg.up {
            let volume = callVolumes[leg.id] ?? defaultCallVolume
            desired.insert(Wire(src: leg.port, sink: 0))
            levels[Wire(src: leg.port, sink: 0)] = volume.speaker
            if !leg.muted {
                desired.insert(Wire(src: 0, sink: leg.port))
                levels[Wire(src: 0, sink: leg.port)] = volume.microphone
            }
            if let c = leg.conference {
                for other in legs where other.up && other.conference == c && other.port != leg.port {
                    desired.insert(Wire(src: other.port, sink: leg.port))
                }
            }
        }
        for (id, recording) in recordings {
            guard let leg = legs.first(where: { $0.id == id }), leg.up else { continue }
            for port in recording.ports where port.confSlot != PJ.invalidID {
                let sink = port.confSlot
                // The microphone: into the mixed file unless muted; into the local file
                // always (muted = level 0 below), so both stereo files get every frame.
                if port.role == .local || (port.role == .mixed && !leg.muted) {
                    desired.insert(Wire(src: 0, sink: sink))
                }
                guard port.role != .local else { continue }
                desired.insert(Wire(src: leg.port, sink: sink))
                if let c = leg.conference {
                    for other in legs where other.up && other.conference == c && other.port != leg.port {
                        desired.insert(Wire(src: other.port, sink: sink))
                    }
                }
            }
        }

        // Disconnect first, then connect (order of PJSIP's queue = order of our calls).
        for (wire, on) in requestedWiring where on && !desired.contains(wire) {
            connect(wire.src, wire.sink, false)
        }
        for wire in desired.sorted(by: { ($0.src, $0.sink) < ($1.src, $1.sink) }) {
            connect(wire.src, wire.sink, true, level: levels[wire] ?? 1)
        }

        // Stereo split, muted call: the local recorder keeps receiving the microphone but at
        // level 0, i.e. silence. Disconnecting it would make the bridge skip the file
        // (a port without transmitters gets no frames) and the two files would drift apart.
        for id in Array(recordings.keys) {
            guard let recording = recordings[id],
                  let local = recording.ports.first(where: { $0.role == .local }),
                  local.confSlot != PJ.invalidID else { continue }
            let audible = !(legs.first(where: { $0.id == id })?.muted ?? false)
            guard recording.localAudible != audible else { continue }
            PJ.warn(pjsua_conf_adjust_tx_level(local.confSlot, audible ? 1 : 0),
                    "recorder \(local.url.lastPathComponent) level \(audible ? 1 : 0)")
            recordings[id]?.localAudible = audible
        }

        // Tone players that follow the calls: hold music into held calls, the recording notice
        // into recorded calls, the speaker and the recorders.
        reconcileHoldMusic()
        reconcileRecordingNotices()
    }

    /// PJSIP 2.17 queues conference (dis)connections and applies them on the next audio
    /// frame, so `cpjsua_conf_is_connected` can lag behind our own requests. An operation is
    /// skipped only when both our last request and the applied state already match `on`;
    /// otherwise it is issued (a duplicate is harmless: PJSIP logs and ignores it).
    /// A connection is made with its `level` (`pjsua_conf_connect2`); when the level of a
    /// requested connection changes, `pjmedia_conf_adjust_conn_level` is queued after any
    /// pending connect, so it reaches the connection whichever request PJSIP applied.
    func connect(_ src: pjsua_conf_port_id, _ sink: pjsua_conf_port_id, _ on: Bool, level: Float = 1) {
        let wire = Wire(src: src, sink: sink)
        let applied = cpjsua_conf_is_connected(src, sink) != 0
        guard on else {
            requestedLevels[wire] = nil
            if requestedWiring[wire] == false && !applied { return }
            requestedWiring[wire] = false
            PJ.warn(pjsua_conf_disconnect(src, sink), "conference disconnect \(src)->\(sink)")
            return
        }
        let previous = requestedWiring[wire] == true ? requestedLevels[wire] : nil
        if !(requestedWiring[wire] == true && applied) {
            var prm = pjsua_conf_connect_param()
            pjsua_conf_connect_param_default(&prm)
            prm.level = level
            PJ.warn(pjsua_conf_connect2(src, sink, &prm), "conference connect \(src)->\(sink)")
        }
        if let previous, previous != level {
            PJ.warn(cpjsua_conf_adjust_conn_level(src, sink, level), "conference level \(src)->\(sink)")
        }
        requestedWiring[wire] = true
        requestedLevels[wire] = level
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

    /// Applied connection into a recorder of `recorded` (the one with `role`; the first one
    /// when nil) from `source`'s conference port, or from the microphone when `source` is
    /// nil (tests and diagnostics).
    func recorderHears(_ recorded: CallID, from source: CallID?, role: RecorderPort.Role? = nil) -> Bool {
        guard isStarted, PJ.registerThread(), let recording = recordings[recorded],
              let recorder = recording.ports.first(where: { role == nil || $0.role == role }) else { return false }
        var port: pjsua_conf_port_id = 0
        if let source {
            guard let snap = CallSnapshot.read(source.raw), snap.confSlot != PJ.invalidID else { return false }
            port = snap.confSlot
        }
        return cpjsua_conf_is_connected(port, recorder.confSlot) != 0
    }

    /// Applied tx level of the local (microphone) recorder of a stereo split recording owned
    /// by `recorded` (1 = normal, 0 = silenced while muted); nil without one (tests).
    func localRecorderLevel(_ recorded: CallID) -> Float? {
        guard isStarted, PJ.registerThread(),
              let local = recordings[recorded]?.ports.first(where: { $0.role == .local }) else { return nil }
        var info = pjsua_conf_port_info()
        guard pjsua_conf_get_port_info(local.confSlot, &info) == PJ.success else { return nil }
        return info.tx_level_adj
    }
}

// MARK: - Test hooks

extension Engine {
    /// Plays a WAV file in a loop into the call's conference port (as if the call's remote
    /// side spoke, from the other end's point of view). Returns the pjsua player id for
    /// `stopTestPlayer`. Tests only: the engine does not track or rewire this port.
    func startTestPlayer(_ wav: URL, into id: CallID) throws -> Int32 {
        let slot = try liveSlot(id)
        guard let snap = CallSnapshot.read(slot), snap.confSlot != PJ.invalidID else { throw EngineError.noSuchCall(id) }
        let arena = CStringArena()
        var file = arena.pj(wav.path)
        var player: pjsua_player_id = PJ.invalidID
        try withExtendedLifetime(arena) {
            try PJ.check(pjsua_player_create(&file, 0, &player), "player \(wav.lastPathComponent)")
        }
        let port = pjsua_player_get_conf_port(player)
        try PJ.check(pjsua_conf_connect(port, snap.confSlot), "player -> call \(id)")
        return player
    }

    func stopTestPlayer(_ player: Int32) {
        guard isStarted, PJ.registerThread() else { return }
        PJ.warn(pjsua_player_destroy(player), "destroy player")
    }
}
