import SwiftUI
import AppKit
import MacroSIPCore

/// 8.6 Recording: folder, record all calls, channels, file-name example, notice tone, Open in Finder.
struct RecordingPane: View {
    @Environment(AppModel.self) private var model

    private var folder: URL { model.recordingFolderURL }
    /// The default folder is created on first use, so only a chosen folder can be "missing".
    private var folderMissing: Bool {
        model.settings.recording.folder != nil && !FileManager.default.fileExists(atPath: folder.path)
    }

    private var sampleName: String {
        // 2026-10-10 14.52 Alesia Kazlouskaya (in).m4a
        RecordingFileName.make(date: Date(timeIntervalSince1970: 1_791_643_920), remote: DemoPeople.alesia,
                               direction: .incoming, timeZone: TimeZone(identifier: "UTC") ?? .current)
    }

    var body: some View {
        PaneContainer {
            FormGroup(content: {
                FormRow(label: L.recordingFolder) {
                    HStack(spacing: 8) {
                        if folderMissing {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                                .help(L.recordingFolderMissing)
                        }
                        Picker("", selection: folderSelection) {
                            Label(folder.lastPathComponent, systemImage: "folder").tag("current")
                            Divider()
                            Text(L.recordingChooseFolder).tag("choose")
                        }
                        .labelsHidden().frame(width: 220)
                    }
                }
                FormDivider()
                FormRow(label: L.recordingAuto) {
                    Toggle("", isOn: model.binding(\.recording.recordAllCalls)).labelsHidden().toggleStyle(.switch)
                }
                FormDivider()
                FormRow(label: L.recordingLayout,
                        help: model.settings.recording.layout == .mono ? L.recordingLayoutMonoHelp : L.recordingLayoutStereoHelp) {
                    Picker("", selection: model.binding(\.recording.layout)) {
                        Text(L.recordingLayoutMono).tag(RecordingLayout.mono)
                        Text(L.recordingLayoutStereo).tag(RecordingLayout.stereoSplit)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                }
            }, footerView: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.recordingFooter).fixedSize(horizontal: false, vertical: true)
                    Text(L.recordingFileName(sampleName)).font(.system(size: 11.5, design: .monospaced))
                }
            })
            FormGroup(header: L.recordingNoticeHeader, footer: L.recordingNoticeFooter(model.settings.recording.noticeToneIntervalSeconds)) {
                FormRow(label: L.recordingNoticeEnable) {
                    Toggle("", isOn: model.binding(\.recording.noticeTone)).labelsHidden().toggleStyle(.switch)
                }
                FormDivider()
                FormRow(label: L.recordingNoticeInterval) {
                    HStack(spacing: 6) {
                        NumberStepperField(value: noticeInterval, width: 56, isValid: { RecordingSettings.noticeIntervalRange.contains($0) },
                                           step: { RecordingSettings.clampInterval($0 + $1 * 5) })
                        Text(L.unitSeconds).font(.system(size: 12)).foregroundStyle(Theme.label2)
                    }
                    .disabled(!model.settings.recording.noticeTone)
                    .opacity(model.settings.recording.noticeTone ? 1 : 0.5)
                }
            }
            FormGroup {
                FormRow(label: L.recordingShowFolder) {
                    Button(L.recordingOpenFinder) { openInFinder() }
                }
            }
        }
    }

    private var noticeInterval: Binding<Int> {
        Binding(
            get: { MainActor.assumeIsolated { model.settings.recording.noticeToneIntervalSeconds } },
            set: { v in MainActor.assumeIsolated { model.updateSettings { $0.recording.noticeToneIntervalSeconds = RecordingSettings.clampInterval(v) } } })
    }

    private var folderSelection: Binding<String> {
        Binding(
            get: { "current" },
            set: { v in
                MainActor.assumeIsolated { if v == "choose" { chooseFolder() } }
            })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        model.updateSettings {
            $0.recording.folder = url
            $0.recording.folderBookmark = bookmark
        }
    }

    private func openInFinder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
