import SwiftUI
import MacroSIPCore

/// Screen 3: All / Missed, Clear…, date-sectioned rows, context menu.
struct CallLogView: View {
    @Environment(AppModel.self) private var model
    @Local private var filter: Filter = .all
    @Local private var selection: UUID?
    @Local private var confirmClear = false
    @FocusState private var listFocused: Bool

    enum Filter: Hashable { case all, missed }

    private var entries: [CallLogEntry] {
        filter == .all ? model.callLog : model.callLog.filter { $0.direction == .missed }
    }

    private var sections: [(String, [CallLogEntry])] {
        let cal = Calendar.current
        var result: [(Date, [CallLogEntry])] = []
        for e in entries {
            let day = cal.startOfDay(for: e.startedAt)
            if let i = result.firstIndex(where: { $0.0 == day }) { result[i].1.append(e) } else { result.append((day, [e])) }
        }
        return result.map { (sectionTitle($0.0), $0.1) }
    }

    private func sectionTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return L.logToday }
        if cal.isDateInYesterday(day) { return L.logYesterday }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SegmentedTabs(items: [.init(value: Filter.all, title: L.logAll), .init(value: Filter.missed, title: L.logMissed)],
                              selection: $filter)
                    .frame(width: 190)      // fits "Пропущенные"
                Spacer()
                Button(L.logClear) { confirmClear = true }
                    .controlSize(.small)
                    .disabled(model.callLog.isEmpty)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            if entries.isEmpty {
                VStack(spacing: 4) {
                    Spacer()
                    Text(filter == .missed && !model.callLog.isEmpty ? L.logEmptyMissed : L.logEmptyTitle)
                        .font(.system(size: 13, weight: .semibold))
                    if model.callLog.isEmpty {
                        Text(L.logEmptyBody).font(.system(size: 12)).foregroundStyle(Theme.label2)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections, id: \.0) { title, items in
                            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.label2)
                                .padding(.horizontal, 15).padding(.top, 8).padding(.bottom, 3)
                            ForEach(items) { entry in
                                row(entry)
                                if model.playerEntry == entry.id, model.recordingLinks[entry.id] != nil { InlinePlayer(player: model.recordingPlayer) { closePlayer() } }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(.return) {
                    guard !model.incomingKeyGuard, let id = selection, let e = entries.first(where: { $0.id == id }) else { return .ignored }
                    model.callBack(e); return .handled
                }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
            }
        }
        .onAppear { model.markLogSeen(); model.refreshRecordingLinks() }
        .onDisappear { closePlayer() }
        .alert(L.logClearTitle, isPresented: $confirmClear) {
            Button(L.commonCancel, role: .cancel) {}
            Button(L.logClearConfirm, role: .destructive) { closePlayer(); model.clearCallLog(); selection = nil }
        } message: {
            Text(L.logClearBody(model.callLog.count) + " " + L.logClearBodyRecordings)
        }
    }

    private func row(_ e: CallLogEntry) -> some View {
        let missed = e.direction == .missed
        let selected = selection == e.id
        let name = model.name(for: e)
        let known = name != e.remoteNumber
        let tint: Color = selected ? .white : (missed ? Theme.red : Theme.label2)
        return HStack(spacing: 9) {
            Image(systemName: e.direction == .outgoing ? "phone.arrow.up.right" : "phone.arrow.down.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(selected ? Color.white : (missed ? Theme.red : Color.primary))
                HStack(spacing: 4) {
                    Text(known ? e.remoteNumber : L.logUnknown)
                    Text("·")
                    Text(model.accountName(e.accountID))
                        .font(.system(size: 10))
                        .padding(.horizontal, 5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.white.opacity(0.2) : Theme.fill))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(selected ? Color.white.opacity(0.8) : Theme.label2)
                .lineLimit(1)
                if let note = e.note, !note.isEmpty {
                    Text(L.logNoteText(note)).font(.system(size: 11))
                        .foregroundStyle(selected ? Color.white.opacity(0.9) : Theme.orange)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let url = model.recordingLinks[e.id] {
                let playing = model.playerEntry == e.id && model.recordingPlayer.isPlaying
                Button { togglePlayback(e, url) } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(selected ? Theme.blue : Color.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(selected ? Color.white : Theme.blue))
                }
                .buttonStyle(.plain)
                .help(playing ? L.logRecordingPause : L.logRecordingPlay)
                .accessibilityLabel(playing ? L.logRecordingPause : L.logRecordingPlay)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(e.startedAt.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                Text(missed ? L.logRowMissed : formatDuration(e.duration)).monospacedDigit()
            }
            .font(.system(size: 11.5))
            .foregroundStyle(selected ? Color.white.opacity(0.85) : Theme.label2)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.blue : .clear))
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.callBack(e) }
        .onTapGesture { selection = e.id; listFocused = true }
        .contextMenu {
            Button(L.logMenuCall) { model.callBack(e) }
            Menu(L.logMenuCallFrom) {
                ForEach(model.enabledAccounts) { a in Button(a.displayName) { model.callBack(e, account: a.id) } }
            }
            Button(L.logMenuAddContact) {
                ContactCardController.shared.show(ContactEditorRequest(contact: nil, prefillName: e.remoteDisplayName ?? "", prefillNumber: e.remoteNumber), model: model)
            }
            Button(L.logMenuCopy) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(e.remoteNumber, forType: .string)
            }
            if let url = model.recordingLinks[e.id] {
                Divider()
                Button(L.logRecordingPlay) { togglePlayback(e, url, onlyStart: true) }
                Button(L.logRecordingShowInFinder) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Divider()
            Button(L.logMenuDelete, role: .destructive) {
                if model.playerEntry == e.id { closePlayer() }
                model.deleteLogEntry(e.id)
            }
        }
        .accessibilityElement(children: .combine)
        .id(e.id)
    }

    /// Play button of a row: opens the inline player under the row and plays; again, it pauses and resumes.
    private func togglePlayback(_ e: CallLogEntry, _ url: URL, onlyStart: Bool = false) {
        selection = e.id
        let player = model.recordingPlayer
        if model.playerEntry == e.id, player.url == url {
            if !onlyStart || !player.isPlaying { player.toggle() }
        } else {
            model.playerEntry = e.id
            player.open(url)
        }
    }

    private func closePlayer() { model.closeRecordingPlayer() }

    private func move(_ delta: Int) {
        let flat = entries
        guard !flat.isEmpty else { return }
        guard let current = selection, let i = flat.firstIndex(where: { $0.id == current }) else {
            selection = flat.first?.id; return
        }
        selection = flat[max(0, min(flat.count - 1, i + delta))].id
    }
}

/// Compact player under a call-log row: play/pause, elapsed, scrubber, total, close (SCREENS.md 3).
struct InlinePlayer: View {
    let player: RecordingPlayer
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? L.logRecordingPause : L.logRecordingPlay)
            .accessibilityLabel(player.isPlaying ? L.logRecordingPause : L.logRecordingPlay)
            if player.failed {
                Text(L.logRecordingFailed).font(.system(size: 11.5)).foregroundStyle(Theme.orange).lineLimit(1)
                Spacer(minLength: 0)
            } else {
                Text(formatDuration(player.position)).monospacedDigit()
                Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }),
                       in: 0...max(player.duration, 0.1))
                    .controlSize(.mini)
                    .accessibilityLabel(L.logRecordingPosition)
                Text(formatDuration(player.duration)).monospacedDigit()
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.label2)
            .help(L.logRecordingClose)
            .accessibilityLabel(L.logRecordingClose)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.label2)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fill))
        .padding(.horizontal, 5).padding(.bottom, 3)
    }
}
