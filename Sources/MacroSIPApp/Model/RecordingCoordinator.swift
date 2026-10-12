import Foundation
import os
import MacroSIPCore

private let recordingLog = Logger(subsystem: "com.hsmm.macrosip", category: "recording")

/// Recording of calls (SCREENS.md 4.1, 8.6): the engine writes a temporary WAV; when the recording
/// stops or the call ends it is converted to M4A in the recordings folder and the WAV is deleted.
extension AppModel {
    // MARK: - Folder

    /// Works out the recordings folder once (and again when the setting changes), never while a view
    /// is being built. A security-scoped bookmark is resolved here and its access is kept for as long as
    /// the folder is in use; a stale bookmark is created again. Demo launches keep recordings inside
    /// their throw-away data directory.
    func refreshRecordingFolder() {
        recordingFolderScope?.stopAccessingSecurityScopedResource()
        recordingFolderScope = nil
        var url = settings.recording.folder ?? RecordingFileName.defaultFolder
        if settings.recording.folder == nil, launch.isDemo, let dir = launch.dataDirectory {
            url = dir.appendingPathComponent("Recordings", isDirectory: true)
        }
        if let data = settings.recording.folderBookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                       bookmarkDataIsStale: &stale) {
                url = resolved
                if resolved.startAccessingSecurityScopedResource() { recordingFolderScope = resolved }
                if stale, let fresh = try? resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    settings.recording.folderBookmark = fresh
                    do { try settingsStore.save(settings) } catch { recordingLog.error("saving the refreshed bookmark failed: \(describe(error), privacy: .public)") }
                }
            } else {
                recordingLog.error("the recordings folder bookmark could not be resolved; using \(url.path, privacy: .public)")
            }
        }
        recordingFolderURL = url
    }

    /// At launch: half-written `.partial.m4a` files in the recordings folder and temporary WAVs from
    /// earlier sessions are removed (and logged); nothing of the running session is touched.
    func cleanUpStaleRecordings() {
        let fm = FileManager.default
        func remove(_ url: URL, _ what: String) {
            recordingLog.notice("removing \(what, privacy: .public) \(url.path, privacy: .public)")
            try? fm.removeItem(at: url)
        }
        if let names = try? fm.contentsOfDirectory(atPath: recordingFolderURL.path) {
            for name in names where name.hasPrefix(".") && name.hasSuffix(".partial.m4a") {
                remove(recordingFolderURL.appendingPathComponent(name), "unfinished conversion")
            }
        }
        let temp = temporaryRecordingsDirectory
        let wavs = (try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in wavs where url.pathExtension == "wav" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < sessionStart { remove(url, "leftover temporary recording") }
        }
    }

    // MARK: - Start and stop

    var temporaryRecordingsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MacroSIP-Recording", isDirectory: true)
    }

    /// The calls a Record / Mute press on `call` applies to: the whole conference, or the call itself.
    func legs(of call: CallInfo) -> [CallInfo] {
        call.inConference ? conferenceCalls : [call]
    }

    /// True when the call, or any leg of its conference, is being recorded.
    func isRecording(_ call: CallInfo) -> Bool { legs(of: call).contains(where: \.isRecording) }

    /// The engine mixes every conference leg and the microphone into the one WAV started on any leg,
    /// so a conference has exactly one recording, on its primary leg (lowest call serial).
    /// If that leg is split out or hangs up, its file is finalised and not restarted.
    func toggleRecording(_ call: CallInfo) {
        let legs = legs(of: call).filter(\.isEstablished)
        if legs.contains(where: \.isRecording) {
            for leg in legs where leg.isRecording { stopRecording(leg) }
        } else if let primary = legs.min(by: { $0.id.serial < $1.id.serial }) {
            startRecording(primary)
        }
    }

    func startRecording(_ call: CallInfo) {
        guard recordingJobs[call.id] == nil, call.isEstablished else { return }
        let wav = temporaryRecordingsDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        recordingJobs[call.id] = RecordingJob(wav: wav, startedAt: Date(), direction: call.direction)
        let id = call.id
        run {
            do { try await self.engine.startRecording(id, to: wav) }
            catch {
                self.recordingJobs[id] = nil
                if case EngineError.noSuchCall = error { return }      // the other side hung up meanwhile
                throw error
            }
        }
    }

    func stopRecording(_ call: CallInfo) {
        let id = call.id
        guard let job = recordingJobs[id], recordingStopping.insert(id).inserted else { return }
        run {
            defer { self.recordingStopping.remove(id) }
            do {
                let wav = try await self.engine.stopRecording(id)
                self.finishRecording(id, call: self.calls.first { $0.id == id } ?? call, wav: wav)
            } catch {
                // Whatever the engine had written so far is still worth keeping.
                if FileManager.default.fileExists(atPath: job.wav.path) {
                    self.finishRecording(id, call: call, wav: job.wav)
                } else {
                    self.recordingJobs[id] = nil
                }
                if case EngineError.noSuchCall = error { return }      // raced a hang-up; the file is saved
                throw error
            }
        }
    }

    // MARK: - Engine events

    /// Called for every call update: tracks the REC chip, starts "record all calls", and keeps a
    /// conference down to one recording.
    func noteRecordingState(_ info: CallInfo) {
        if info.isRecording {
            // The engine moves a conference recording to a surviving leg when its owner leaves
            // (split or hang-up). Follow it: the job (file, start time) now belongs to this call.
            if recordingJobs[info.id] == nil, let moved = movedRecordingJobOwner(excluding: info.id) {
                adoptRecordingJob(from: moved, to: info.id)
            }
            if recordingSince[info.id] == nil { recordingSince[info.id] = recordingJobs[info.id]?.startedAt ?? Date() }
        } else {
            recordingSince[info.id] = nil
        }
        if settings.recording.recordAllCalls, info.state == .connected, !info.isRecording,
           !autoRecordTried.contains(info.id) {
            autoRecordTried.insert(info.id)
            // A call that joined a conference which is already recorded is in that recording.
            let conferenceRecorded = info.inConference && conferenceCalls.contains {
                $0.id != info.id && ($0.isRecording || recordingJobs[$0.id] != nil)
            }
            if !conferenceRecorded { startRecording(info) }
        }
        keepOneConferenceRecording()
    }

    /// The engine mixes all legs into any one recording, so after a merge only the primary
    /// (lowest serial) recording stays; the others are stopped and saved.
    private func keepOneConferenceRecording() {
        let recording = conferenceCalls.filter { $0.isRecording || recordingJobs[$0.id] != nil }
        guard recording.count > 1, let keep = recording.min(by: { $0.id.serial < $1.id.serial }) else { return }
        for call in recording where call.id != keep.id && call.isRecording { stopRecording(call) }
    }

    /// The call is gone. `isRecording == true` means the engine closed the recording with it;
    /// `false` with a job still here means the recording moved to another conference leg.
    func recordingCallEnded(_ info: CallInfo) {
        recordingSince[info.id] = nil
        autoRecordTried.remove(info.id)
        recordingStopping.remove(info.id)
        guard let job = recordingJobs[info.id] else { return }
        if !info.isRecording, let heir = recordingHeir(of: info) {
            adoptRecordingJob(from: info.id, to: heir)
            return
        }
        finishRecording(info.id, call: info, wav: job.wav)
    }

    /// A job whose owner no longer records (or is gone) while some other call does: the engine moved it.
    private func movedRecordingJobOwner(excluding id: CallID) -> CallID? {
        recordingJobs.keys.first { owner in
            owner != id && !(calls.first { $0.id == owner }?.isRecording ?? false)
        }
    }

    /// The live call that took over `ended`'s recording: one that records without a job, else the
    /// lowest-serial remaining conference leg (its `.callChanged` may arrive after this `.callEnded`).
    private func recordingHeir(of ended: CallInfo) -> CallID? {
        let live = calls.filter { call in
            if case .disconnected = call.state { return false }
            return call.id != ended.id
        }
        if let taker = live.first(where: { $0.isRecording && recordingJobs[$0.id] == nil }) { return taker.id }
        guard ended.inConference else { return nil }
        return live.filter { $0.inConference }.min(by: { $0.id.serial < $1.id.serial })?.id
    }

    private func adoptRecordingJob(from old: CallID, to new: CallID) {
        guard let job = recordingJobs.removeValue(forKey: old) else { return }
        recordingJobs[new] = job
        recordingSince[new] = recordingSince.removeValue(forKey: old) ?? job.startedAt
        recordingStopping.remove(old)
        recordingLog.info("recording of call \(old, privacy: .public) continues on call \(new, privacy: .public)")
    }

    // MARK: - Conversion

    /// Converts in the background. A WAV without samples is deleted silently. When the conversion
    /// fails, the WAV moves into the recordings folder under the M4A's name (never stays in the temp
    /// folder) and the banner says so.
    @discardableResult
    private func finishRecording(_ id: CallID, call: CallInfo, wav: URL) -> Task<Void, Never>? {
        guard let job = recordingJobs.removeValue(forKey: id) else { return nil }
        let remote = name(for: call.remote)
        let fileName = RecordingFileName.make(date: job.startedAt, remote: remote, direction: job.direction)
        let folder = recordingFolderURL
        return Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: wav.path) else {
                recordingLog.error("the temporary recording \(wav.lastPathComponent, privacy: .public) is missing")
                return
            }
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = try await RecordingConverter.convert(wav: wav, to: folder.appendingPathComponent(fileName))
                try? fm.removeItem(at: wav)
                recordingLog.info("saved \(target.lastPathComponent, privacy: .public)")
                await AppModel.shared.recordingSaved(target)
            } catch RecordingConverter.ConversionError.empty {
                recordingLog.info("\(wav.lastPathComponent, privacy: .public) holds no samples; deleted")
                try? fm.removeItem(at: wav)
            } catch {
                let message = describe(error)
                recordingLog.error("conversion of \(wav.lastPathComponent, privacy: .public) failed: \(message, privacy: .public)")
                let kept = Self.keepWAV(wav, in: folder, named: fileName)
                recordingLog.error("the recording was kept as \(kept?.path ?? wav.path, privacy: .public)")
                await AppModel.shared.showBanner(L.bannerRecordingKeptAsWAV(message, kept?.lastPathComponent ?? wav.lastPathComponent))
            }
        }
    }

    /// Moves the WAV next to where the M4A would have gone: same name with `.wav`, " 2", " 3" when taken.
    nonisolated private static func keepWAV(_ wav: URL, in folder: URL, named m4aName: String) -> URL? {
        let fm = FileManager.default
        let base = (m4aName as NSString).deletingPathExtension
        for n in 1...1000 {
            let name = n == 1 ? "\(base).wav" : "\(base) \(n).wav"
            let target = folder.appendingPathComponent(name)
            guard !fm.fileExists(atPath: target.path) else { continue }
            do { try fm.moveItem(at: wav, to: target); return target } catch { return nil }
        }
        return nil
    }

    /// Quitting: recordings still running are stopped and converted before the app exits.
    func finishRecordingsForQuit() async {
        var tasks: [Task<Void, Never>] = []
        for call in calls where recordingJobs[call.id] != nil {
            let wav = (try? await engine.stopRecording(call.id)) ?? recordingJobs[call.id]?.wav
            if let wav, let t = finishRecording(call.id, call: call, wav: wav) { tasks.append(t) }
        }
        for t in tasks { await t.value }
    }

    /// Hook for the self-test and the UI.
    func recordingSaved(_ url: URL) {
        savedRecordings.append(url)
    }
}
