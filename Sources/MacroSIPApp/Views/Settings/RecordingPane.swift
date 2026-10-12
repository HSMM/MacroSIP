import SwiftUI
import AppKit
import MacroSIPCore

/// 8.6 Recording: folder, record all calls, file-name example, Open in Finder.
struct RecordingPane: View {
    @Environment(AppModel.self) private var model

    private var folder: URL { model.recordingFolderURL }
    /// The default folder is created on first use, so only a chosen folder can be "missing".
    private var folderMissing: Bool {
        model.settings.recording.folder != nil && !FileManager.default.fileExists(atPath: folder.path)
    }

    private var sampleName: String {
        // 2026-10-10 14.52 Anna Petrova (in).m4a
        RecordingFileName.make(date: Date(timeIntervalSince1970: 1_791_643_920), remote: "Anna Petrova",
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
            }, footerView: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.recordingFooter).fixedSize(horizontal: false, vertical: true)
                    Text(L.recordingFileName(sampleName)).font(.system(size: 11.5, design: .monospaced))
                }
            })
            FormGroup {
                FormRow(label: L.recordingShowFolder) {
                    Button(L.recordingOpenFinder) { openInFinder() }
                }
            }
        }
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
