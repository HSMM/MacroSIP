internal import CPJSUA
import Foundation

/// One pjsua recorder: a WAV writer port in the conference bridge.
struct RecorderPort: Sendable {
    enum Role: Sendable {
        /// Mono layout: the call, its conference partners and the microphone.
        case mixed
        /// Stereo split: the microphone only.
        case local
        /// Stereo split: the call and its conference partners.
        case remote
    }

    var role: Role
    var recorderID: pjsua_recorder_id
    var confSlot: pjsua_conf_port_id
    var url: URL
}

/// One call recording: one recorder (`.mono`) or a local/remote pair (`.stereoSplit`).
struct Recording: Sendable {
    var files: RecordingFiles
    var ports: [RecorderPort]
    /// Conference of the owning call when last seen; the recording stays with it.
    var conference: UInt64?
    /// Stereo split: the tx level last applied to the local recorder's port (false = 0,
    /// the owning call is muted). nil until the first `reconcileMedia`.
    var localAudible: Bool?
}

extension Engine {
    /// How long `stopRecording` (and the automatic stop at the end of a call) waits for the
    /// conference bridge to drop the recorder, which writes the final WAV header. The bridge
    /// does that on its next 20 ms frame; after the timeout the header is patched here.
    static let recorderFinaliseTimeoutMs: UInt32 = 150

    /// How many finished file sets of ended calls `recordingFiles(of:)` remembers.
    static let finishedRecordingsKept = 32

    /// Records the call (WAV, 16-bit PCM mono at the conference clock rate, 16 kHz by
    /// default). `.mono` (the default) writes `wavURL`: the remote side plus our microphone
    /// (left out while muted). `.stereoSplit` writes two files next to it,
    /// `<base>-local.wav` (the microphone only; silence while muted) and `<base>-remote.wav`
    /// (the remote side), created and destroyed together so their lengths match (see
    /// `RecordingFiles.planned(for:layout:)`). For a conference leg every leg of that
    /// conference goes into the (remote) file, and the recording belongs to the conference:
    /// if its call ends or is split off while other legs remain, it moves to one of them
    /// (same files). Nothing is written while the call is on hold. The parent directory is
    /// created when missing; existing files are overwritten.
    /// `.invalidArgument` when the call, or its conference, is already being recorded.
    /// The recording stops by itself when the call ends; that call's `.callEnded` then
    /// reports `isRecording == true` and is emitted only after the WAVs are finalised.
    public func startRecording(_ id: CallID, to wavURL: URL, layout: RecordingLayout = .mono) throws {
        let slot = try liveSlot(id)
        guard recordings[id] == nil else {
            throw EngineError.invalidArgument("call \(id) is already being recorded")
        }
        let conference = bridge.record(slot).flatMap { $0.serial == id.serial ? $0.conference : nil }
        if let conference, let owner = recordingOwner(inConference: conference) {
            throw EngineError.invalidArgument("the conference of call \(id) is already being recorded (by \(owner))")
        }
        guard wavURL.isFileURL, wavURL.pathExtension.lowercased() == "wav" else {
            throw EngineError.invalidArgument("recording file \(wavURL) must be a local .wav file")
        }
        let dir = wavURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw EngineError.invalidArgument("cannot create \(dir.path): \(error.localizedDescription)")
        }
        let files = RecordingFiles.planned(for: wavURL, layout: layout)
        let plan: [(RecorderPort.Role, URL)]
        switch layout {
        case .mono: plan = [(.mixed, wavURL)]
        case .stereoSplit: plan = [(.local, files.local!), (.remote, files.remote!)]
        }
        // All recorders in this one engine turn: the bridge adds them on the same frame.
        var ports: [RecorderPort] = []
        for (role, url) in plan {
            let path = url.path
            var recorder = PJ.invalidID
            var confSlot = PJ.invalidID
            let status = path.withCString { cpjsua_recorder_create($0, &recorder, &confSlot) }
            guard status == PJ.success else {
                destroyRecorders(ports)
                for port in ports { try? FileManager.default.removeItem(at: port.url) }
                throw PJ.error(status, "create recorder \(path)")
            }
            ports.append(RecorderPort(role: role, recorderID: recorder, confSlot: confSlot, url: url))
        }
        finishedRecordings[id] = nil
        recordings[id] = Recording(files: files, ports: ports, conference: conference)
        do {
            try updateRecord(id) { $0.isRecording = true }   // also wires the recorders
        } catch {
            finishRecorder(id)                                 // the call ended meanwhile
            for url in files.all { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    /// Stops the recording that covers the call: its own, or the recording of its conference
    /// (whichever leg owns it), and returns its files. The WAVs are complete (headers final)
    /// when this returns. Works for a call that has just ended as long as its recording was
    /// not finished yet. Files without samples (held all the time) are still returned; see
    /// `recordingIsEmpty(_:)`.
    public func stopRecording(_ id: CallID) throws -> RecordingFiles {
        try requireStarted()
        guard let owner = recordingOwner(for: id), let recording = recordings[owner] else {
            _ = try liveSlot(id)
            throw EngineError.invalidArgument("call \(id) is not being recorded")
        }
        finishRecorder(owner)
        if let snap = CallSnapshot.read(owner.raw), snap.serial == owner.serial {
            bridge.updateCall(snap, mode: .updateOnly, mutate: { $0.isRecording = false },
                              event: { info, rec in rec.announced ? .callChanged(info) : nil })
        }
        releaseFinishedEnds()
        reconcileMedia()
        return recording.files
    }

    /// The files of the recording that covers the call (its own, or its conference's,
    /// whichever leg owns it) while it runs. After a recorded call ended (its `.callEnded`
    /// says `isRecording`), the finished files of that call stay available here (for the
    /// last 32 such calls, `finishedRecordingsKept`). nil when the call is not being recorded or
    /// the recording was stopped with `stopRecording`.
    public func recordingFiles(of id: CallID) -> RecordingFiles? {
        if let owner = recordingOwner(for: id), let recording = recordings[owner] { return recording.files }
        return finishedRecordings[id]
    }

    /// True when the recording holds no audio samples (missing file or a bare 44-byte
    /// header, e.g. the call was on hold the whole time). The UI deletes such files.
    public static func recordingIsEmpty(_ url: URL) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        else { return true }
        return size.intValue <= WAVFile.size
    }

    /// The call whose recording covers `id`: its own, else the one of its conference.
    func recordingOwner(for id: CallID) -> CallID? {
        if recordings[id] != nil { return id }
        guard let rec = bridge.record(id.raw), rec.serial == id.serial, let c = rec.conference else { return nil }
        return recordingOwner(inConference: c)
    }

    /// The owner of a recording of conference `c` (a live owner's current conference, or the
    /// conference an ended owner was in until its recording is moved or finished).
    func recordingOwner(inConference c: UInt64) -> CallID? {
        for owner in recordings.keys.sorted(by: { $0.raw < $1.raw }) {
            let current: UInt64?
            if let r = bridge.record(owner.raw), r.serial == owner.serial {
                current = r.conference
            } else {
                current = recordings[owner]?.conference
            }
            if current == c { return owner }
        }
        return nil
    }

    /// Keeps a conference's recording with the conference: when its call ended or left the
    /// conference (split) while other legs remain, the recorder (same pjsua recorder, same
    /// file) moves to the first remaining leg without a recording of its own. Both legs get
    /// `.callChanged` (isRecording false / true); an ended owner's held-back `.callEnded` is
    /// released with `isRecording == false`. Runs at the start of every `reconcileMedia` and
    /// before conferences are dissolved.
    func rehomeRecordings() {
        guard !recordings.isEmpty else { return }
        var legs: [UInt64: [CallID]] = [:]          // conference -> live legs, slot order
        var liveConference: [CallID: UInt64?] = [:]
        for slot in CallSnapshot.allSlots() {
            guard let snap = CallSnapshot.read(slot), snap.state != .disconnected,
                  let rec = bridge.record(slot), rec.serial == snap.serial else { continue }
            let id = CallID(raw: slot, serial: rec.serial)
            liveConference[id] = rec.conference
            if let c = rec.conference { legs[c, default: []].append(id) }
        }
        for owner in recordings.keys.sorted(by: { $0.raw < $1.raw }) {
            guard var recording = recordings[owner] else { continue }
            let live = liveConference.keys.contains(owner)
            let current = liveConference[owner] ?? nil
            if live, current != nil || recording.conference == nil {
                recording.conference = current        // unchanged, or conferences were joined
                recordings[owner] = recording
                continue
            }
            // The owner ended or left its conference.
            guard let old = recording.conference,
                  let heir = legs[old]?.first(where: { $0 != owner && recordings[$0] == nil }) else {
                if live {
                    recording.conference = nil
                    recordings[owner] = recording
                }
                continue
            }
            recordings[owner] = nil
            recordings[heir] = recording
            do {
                try updateRecord(heir, reconcile: false) { $0.isRecording = true }
            } catch {
                recordings[heir] = nil                // the heir ended too: keep it where it was
                recordings[owner] = recording
                continue
            }
            if live {
                try? updateRecord(owner, reconcile: false) { $0.isRecording = false }
            } else {
                bridge.releaseDeferredEndWithoutRecording(serial: owner.serial)
            }
            let names = recording.files.all.map(\.lastPathComponent).joined(separator: ", ")
            bridge.engineLogger.info("recording \(names, privacy: .public) moved from \(owner) to \(heir)")
        }
    }

    /// Destroys the call's recorders (together) and waits for the WAV headers (patching
    /// them from the file length when the bridge did not finish in time). Leaves
    /// `isRecording` of the call's record alone (an ended call keeps reporting it).
    /// `keepFiles`: the call ended; remember its files for `recordingFiles(of:)`.
    func finishRecorder(_ id: CallID, keepFiles: Bool = false) {
        guard let recording = recordings.removeValue(forKey: id) else { return }
        stopRecordingNotice(for: id)
        // Their wires disappear with the ports; forget our requests for them.
        let slots = Set(recording.ports.map(\.confSlot))
        requestedWiring = requestedWiring.filter { !slots.contains($0.key.src) && !slots.contains($0.key.sink) }
        for slot in slots { slotOwners[slot] = nil }
        destroyRecorders(recording.ports)
        if keepFiles {
            finishedRecordings[id] = recording.files
            if finishedRecordings.count > Engine.finishedRecordingsKept,
               let oldest = finishedRecordings.keys.min(by: { $0.serial < $1.serial }) {
                finishedRecordings[oldest] = nil
            }
        }
    }

    /// `cpjsua_recorders_destroy_wait` for all ports at once (same bridge frame, so a
    /// stereo pair ends with the same length), then repairs headers the bridge did not
    /// finish in time.
    func destroyRecorders(_ ports: [RecorderPort]) {
        guard !ports.isEmpty else { return }
        var ids = ports.map(\.recorderID)
        var finalised = [Int32](repeating: 0, count: ports.count)
        let status = cpjsua_recorders_destroy_wait(&ids, UInt32(ids.count), Engine.recorderFinaliseTimeoutMs, &finalised)
        if status != PJ.success {
            PJ.warn(status, "stop recording \(ports.map(\.url.lastPathComponent).joined(separator: ", "))")
        }
        for (port, done) in zip(ports, finalised) where done == 0 {
            // The bridge did not run (no sound clock). Make the file valid now; PJSIP rewrites
            // the header (and appends what it still buffers) when it processes the removal.
            let repaired = WAVFile.repair(port.url)
            let text = "recording \(port.url.lastPathComponent): bridge did not finish the WAV within "
                + "\(Engine.recorderFinaliseTimeoutMs) ms; header \(repaired ? "patched from the file length" : "NOT repaired")"
            bridge.engineLogger.error("\(text, privacy: .public)")
            emit(.log(level: 2, "engine: \(text)"))
        }
    }

    /// Releases the held-back `.callEnded` of recorded calls whose recording is finished.
    func releaseFinishedEnds() {
        bridge.releaseDeferredEnds(keeping: Set(recordings.keys.map(\.serial)))
    }

    /// After a call ended: move conference recordings to remaining legs, stop the recordings
    /// of ended calls (finalising the WAV), then emit their `.callEnded`; dissolve conferences
    /// left with one leg; rewire the bridge.
    func finishEndedCalls() {
        guard isStarted, PJ.registerThread() else { return }
        rehomeRecordings()
        for id in Array(recordings.keys) where !isLive(id) {
            finishRecorder(id, keepFiles: true)
        }
        releaseFinishedEnds()
        dissolveSingleLegConferences()
        reconcileMedia()
    }

    /// The call still has its bridge record (it has not reached DISCONNECTED).
    func isLive(_ id: CallID) -> Bool {
        bridge.record(id.raw)?.serial == id.serial
    }
}

/// The 44-byte PCM header pjmedia's WAV writer produces.
enum WAVFile {
    static let size = 44

    /// Writes the RIFF and data chunk sizes from the file length. false when the file is not a
    /// 44-byte-header PCM WAV or cannot be written.
    @discardableResult
    static func repair(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        do {
            let length = try handle.seekToEnd()
            guard length >= UInt64(size), length - 8 <= UInt64(UInt32.max) else { return false }
            try handle.seek(toOffset: 0)
            guard let head = try handle.read(upToCount: size), head.count == size,
                  head[0..<4] == Data("RIFF".utf8), head[8..<12] == Data("WAVE".utf8),
                  head[36..<40] == Data("data".utf8) else { return false }
            func le(_ v: UInt64) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: le(length - 8))
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: le(length - UInt64(size)))
            return true
        } catch {
            return false
        }
    }
}
