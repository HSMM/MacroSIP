import Foundation
import os
import MacroSIPCore

private let recordingLog = AppLog.recording

/// Recording of calls (SCREENS.md 4.1, 8.6): the engine writes a temporary WAV (mono) or a pair of
/// one-channel WAVs (stereo: me left, caller right); when the recording stops or the call ends the set
/// is converted to one M4A in the recordings folder and the WAVs are deleted.
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
                    do { try settingsStore.save(settings) } catch { recordingLog.error("saving the refreshed bookmark failed: \(describe(error))") }
                }
            } else {
                recordingLog.error("the recordings folder bookmark could not be resolved; using \(url.path)")
            }
        }
        recordingFolderURL = url
        refreshRecordingLinks()
    }

    /// At launch: half-written `.partial.m4a` files in the recordings folder and temporary WAVs from
    /// earlier sessions are removed (and logged); nothing of the running session is touched.
    func cleanUpStaleRecordings() {
        let fm = FileManager.default
        func remove(_ url: URL, _ what: String) {
            recordingLog.notice("removing \(what) \(url.path)")
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
        let layout = settings.recording.layout
        recordingJobs[call.id] = RecordingJob(wav: wav, layout: layout, startedAt: Date(), direction: call.direction)
        let id = call.id
        run {
            do {
                try await self.engine.startRecording(id, to: wav, layout: layout)
                self.recordingJobs[id]?.files = await self.engine.recordingFiles(of: id)
            } catch {
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
                let files = try await self.engine.stopRecording(id)
                self.finishRecording(id, call: self.calls.first { $0.id == id } ?? call, files: files)
            } catch {
                // Whatever the engine had written so far is still worth keeping.
                let files = await self.engine.recordingFiles(of: id) ?? job.files ?? RecordingFiles.planned(for: job.wav, layout: job.layout)
                if files.all.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                    self.finishRecording(id, call: call, files: files)
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
        // The engine closed the files with the call; the job remembers what it reported at the start.
        finishRecording(info.id, call: info, files: job.files)
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
        recordingLog.info("recording of call \(old) continues on call \(new)")
    }

    // MARK: - Conversion

    /// Converts in the background. A set without samples is deleted silently. When the conversion
    /// fails, every WAV of the set moves into the recordings folder under the M4A's name (`<name>.wav`,
    /// `<name>-local.wav`, `<name>-remote.wav`; never stays in the temp folder) and the banner says so.
    /// `files` nil means the engine never reported the set: the job's own paths are used.
    @discardableResult
    private func finishRecording(_ id: CallID, call: CallInfo, files: RecordingFiles?) -> Task<Void, Never>? {
        guard let job = recordingJobs.removeValue(forKey: id) else { return nil }
        let remote = name(for: call.remote)
        let fileName = RecordingFileName.make(date: job.startedAt, remote: remote, direction: job.direction)
        let folder = recordingFolderURL
        let reported = files ?? job.files ?? RecordingFiles.planned(for: job.wav, layout: job.layout)
        return Task.detached(priority: .utility) {
            let fm = FileManager.default
            // Only what is on disk (a stereo set may lose a side; a missing set is logged).
            let present = RecordingFiles(layout: reported.layout,
                                         mixed: reported.mixed.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil },
                                         local: reported.local.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil },
                                         remote: reported.remote.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil })
            let names = present.all.map(\.lastPathComponent).joined(separator: ", ")
            guard !present.all.isEmpty else {
                recordingLog.error("the temporary recording \(reported.all.map(\.lastPathComponent).joined(separator: ", ")) is missing")
                return
            }
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = try await RecordingConverter.convert(files: present, to: folder.appendingPathComponent(fileName))
                for url in present.all { try? fm.removeItem(at: url) }
                recordingLog.info("saved \(target.lastPathComponent)")
                await AppModel.shared.recordingSaved(target, for: id)
            } catch RecordingConverter.ConversionError.empty {
                recordingLog.info("\(names) holds no samples; deleted")
                for url in present.all { try? fm.removeItem(at: url) }
            } catch {
                let message = describe(error)
                recordingLog.error("conversion of \(names) failed: \(message)")
                let kept = Self.keepWAVs(present, in: folder, named: fileName)
                let keptNames = kept.map(\.lastPathComponent).joined(separator: ", ")
                recordingLog.error("the recording was kept as \(keptNames.isEmpty ? names : keptNames)")
                await AppModel.shared.showBanner(L.bannerRecordingKeptAsWAV(message, keptNames.isEmpty ? names : keptNames))
            }
        }
    }

    /// Moves the WAVs next to where the M4A would have gone: the M4A's name with `.wav` (mixed),
    /// `-local.wav`, `-remote.wav`; " 2", " 3" after the name when any of them is taken.
    /// Returns the files that ended up in the folder.
    nonisolated private static func keepWAVs(_ files: RecordingFiles, in folder: URL, named m4aName: String) -> [URL] {
        let fm = FileManager.default
        let base = (m4aName as NSString).deletingPathExtension
        let parts: [(url: URL, suffix: String)] = [(files.mixed, ""), (files.local, "-local"), (files.remote, "-remote")]
            .compactMap { url, suffix in url.map { ($0, suffix) } }
        for n in 1...1000 {
            let stem = n == 1 ? base : "\(base) \(n)"
            let targets = parts.map { folder.appendingPathComponent("\(stem)\($0.suffix).wav") }
            guard !targets.contains(where: { fm.fileExists(atPath: $0.path) }) else { continue }
            var moved: [URL] = []
            for (part, target) in zip(parts, targets) {
                do { try fm.moveItem(at: part.url, to: target); moved.append(target) }
                catch { recordingLog.error("moving \(part.url.lastPathComponent) failed: \(describe(error))"); moved.append(part.url) }
            }
            return moved
        }
        return parts.map(\.url)
    }

    /// Quitting: recordings still running are stopped and converted before the app exits.
    func finishRecordingsForQuit() async {
        var tasks: [Task<Void, Never>] = []
        for call in calls where recordingJobs[call.id] != nil {
            let files = try? await engine.stopRecording(call.id)
            if let t = finishRecording(call.id, call: call, files: files) { tasks.append(t) }
        }
        for t in tasks { await t.value }
    }

    /// A recording was converted: the call-log entry of its call (now, or when the call ends) remembers the file.
    func recordingSaved(_ url: URL, for call: CallID? = nil) {
        savedRecordings.append(url)
        guard let call else { return }
        if let entry = logEntryByCall.removeValue(forKey: call) {
            do { try callLogStore.setRecording(url, for: entry) } catch { report(error) }
            reloadCallLog()
        } else {
            recordingByCall[call] = url
        }
    }

    /// Which call-log entries have a recording to play. Works in the background and applies the result when
    /// it is still the latest request.
    func refreshRecordingLinks() {
        Task { @MainActor in await updateRecordingLinks() }
    }

    func updateRecordingLinks() async {
        recordingLinksGeneration += 1
        let generation = recordingLinksGeneration
        let entries = callLog
        var names: [UUID: String] = [:]
        for e in entries where e.recordingURL == nil && e.startedAt < recordingHeuristicCutoff && (e.direction != .missed || e.duration > 0) {
            names[e.id] = name(for: e)
        }
        let links = await recordingResolver.resolve(entries: entries, names: names, folder: recordingFolderURL)
        guard generation == recordingLinksGeneration else { return }
        if links != recordingLinks { recordingLinks = links }
        if let playing = playerEntry, links[playing] == nil { closeRecordingPlayer() }
    }

    func closeRecordingPlayer() {
        playerEntry = nil
        recordingPlayer.close()
    }
}

/// Finds the recording of every call-log entry away from the main actor: the stored file if it still exists,
/// else, for entries in `names` (older than the first launch with playback), a file in the recordings folder
/// named for the same minute, direction and party. The folder listing is kept until the folder changes.
actor RecordingLinkResolver {
    private var cached: (folder: URL, stamp: Date, index: RecordingFileName.Index)?

    func resolve(entries: [CallLogEntry], names: [UUID: String], folder: URL) -> [UUID: URL] {
        let fm = FileManager.default
        var links: [UUID: URL] = [:]
        var claimed = Set<URL>()
        var legacy: [(entry: CallLogEntry, name: String)] = []
        for e in entries {
            if let url = e.recordingURL {
                if fm.fileExists(atPath: url.path) { links[e.id] = url; claimed.insert(url.standardizedFileURL) }
            } else if let name = names[e.id] {
                legacy.append((e, name))
            }
        }
        if !legacy.isEmpty, let index = index(of: folder), !index.isEmpty {
            for (id, url) in index.assign(legacy, excluding: claimed) { links[id] = url }
        }
        return links
    }

    private func index(of folder: URL) -> RecordingFileName.Index? {
        guard let stamp = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
        if let c = cached, c.folder == folder, c.stamp == stamp { return c.index }
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        let index = RecordingFileName.Index(files: files.filter { $0.pathExtension.lowercased() == "m4a" })
        cached = (folder, stamp, index)
        return index
    }
}
