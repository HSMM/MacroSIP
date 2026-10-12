internal import CPJSUA
import Foundation

/// One call recording: a pjsua recorder (WAV writer port in the conference bridge).
struct Recording: Sendable {
    var recorderID: pjsua_recorder_id
    var confSlot: pjsua_conf_port_id
    var url: URL
    /// Conference of the owning call when last seen; the recording stays with it.
    var conference: UInt64?
}

extension Engine {
    /// How long `stopRecording` (and the automatic stop at the end of a call) waits for the
    /// conference bridge to drop the recorder, which writes the final WAV header. The bridge
    /// does that on its next 20 ms frame; after the timeout the header is patched here.
    static let recorderFinaliseTimeoutMs: UInt32 = 150

    /// Records the call into `wavURL` (WAV, 16-bit PCM mono at the conference clock rate,
    /// 16 kHz by default): the remote side plus our microphone (left out while muted). For a
    /// conference leg every leg of that conference goes into the same file, and the recording
    /// belongs to the conference: if its call ends or is split off while other legs remain,
    /// it moves to one of them (same file). Nothing is written while the call is on hold.
    /// The parent directory is created when missing; an existing file is overwritten.
    /// `.invalidArgument` when the call, or its conference, is already being recorded.
    /// The recording stops by itself when the call ends; that call's `.callEnded` then
    /// reports `isRecording == true` and is emitted only after the WAV is finalised.
    public func startRecording(_ id: CallID, to wavURL: URL) throws {
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
        let path = wavURL.path
        var recorder = PJ.invalidID
        var confSlot = PJ.invalidID
        try PJ.check(path.withCString { cpjsua_recorder_create($0, &recorder, &confSlot) }, "create recorder \(path)")
        recordings[id] = Recording(recorderID: recorder, confSlot: confSlot, url: wavURL, conference: conference)
        do {
            try updateRecord(id) { $0.isRecording = true }   // also wires the recorder
        } catch {
            finishRecorder(id)                                 // the call ended meanwhile
            try? FileManager.default.removeItem(at: wavURL)
            throw error
        }
    }

    /// Stops the recording that covers the call: its own, or the recording of its conference
    /// (whichever leg owns it), and returns its file. The WAV is complete (header final)
    /// when this returns. Works for a call that has just ended as long as its recording was
    /// not finished yet. A file without samples (held all the time) is still returned; see
    /// `recordingIsEmpty(_:)`.
    public func stopRecording(_ id: CallID) throws -> URL {
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
        return recording.url
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
            bridge.engineLogger.info("recording \(recording.url.lastPathComponent, privacy: .public) moved from \(owner) to \(heir)")
        }
    }

    /// Destroys the call's recorder and waits for the WAV header (patching it from the file
    /// length when the bridge did not finish in time). Leaves `isRecording` of the call's
    /// record alone (an ended call keeps reporting it).
    func finishRecorder(_ id: CallID) {
        guard let recording = recordings.removeValue(forKey: id) else { return }
        // Its wires disappear with the port; forget our requests for them.
        requestedWiring = requestedWiring.filter { $0.key.src != recording.confSlot && $0.key.sink != recording.confSlot }
        slotOwners[recording.confSlot] = nil
        var finalised: Int32 = 0
        let status = cpjsua_recorder_destroy_wait(recording.recorderID, Engine.recorderFinaliseTimeoutMs, &finalised)
        if status != PJ.success {
            PJ.warn(status, "stop recording \(recording.url.lastPathComponent)")
        }
        if finalised == 0 {
            // The bridge did not run (no sound clock). Make the file valid now; PJSIP rewrites
            // the header (and appends what it still buffers) when it processes the removal.
            let repaired = WAVFile.repair(recording.url)
            let text = "recording \(recording.url.lastPathComponent): bridge did not finish the WAV within "
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
            finishRecorder(id)
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
