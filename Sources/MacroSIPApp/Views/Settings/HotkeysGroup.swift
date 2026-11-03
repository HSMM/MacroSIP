import SwiftUI
import AppKit
import MacroSIPCore

/// Settings › Calls › Global hotkeys (SCREENS.md 8.7): a master switch and a recorder for Answer, Hang up, Mute.
struct HotkeysGroup: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        FormGroup(header: L.hotkeysHeader, footer: model.settings.hotkeys.enabled ? L.hotkeysFooter : nil) {
            FormRow(label: L.hotkeysEnable, help: L.hotkeysEnableHelp) {
                Toggle("", isOn: Binding(
                    get: { MainActor.assumeIsolated { model.settings.hotkeys.enabled } },
                    set: { v in MainActor.assumeIsolated { model.setHotkeysEnabled(v) } }))
                    .labelsHidden().toggleStyle(.switch)
            }
            if model.settings.hotkeys.enabled {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    FormDivider()
                    HotkeyRow(action: action)
                }
            }
        }
    }
}

private struct HotkeyRow: View {
    @Environment(AppModel.self) private var model
    let action: HotkeyAction

    private var label: String {
        switch action {
        case .answer: return L.hotkeysAnswer
        case .hangUp: return L.hotkeysHangUp
        case .mute: return L.hotkeysMute
        }
    }

    private var help: String {
        switch action {
        case .answer: return L.hotkeysAnswerHelp
        case .hangUp: return L.hotkeysHangUpHelp
        case .mute: return L.hotkeysMuteHelp
        }
    }

    /// A refused combination the user just typed wins over a registration failure of the stored one.
    private var message: String? {
        if let issue = model.hotkeyIssues[action] { return Self.text(for: issue) }
        switch model.hotkeyFailures[action] {
        case .inUse: return L.hotkeysErrorInUse
        case let .system(code): return L.hotkeysErrorSystem(code)
        case nil: return nil
        }
    }

    var body: some View {
        FormRow(label: label, help: help) {
            VStack(alignment: .trailing, spacing: 3) {
                HotkeyRecorder(combo: model.settings.hotkeys[action],
                               isRecording: { model.setHotkeyRecording($0) },
                               onChange: { model.setHotkey($0, for: action) })
                if let message {
                    Text(message).font(.system(size: 11.5)).foregroundStyle(Theme.red)
                        .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(message)
                }
            }
        }
    }

    static func text(for issue: HotkeyIssue) -> String {
        switch issue {
        case .needsModifier: return L.hotkeysIssueNeedsModifier
        case .unsupportedKey: return L.hotkeysIssueUnsupportedKey
        case .usedByMenu: return L.hotkeysIssueUsedByMenu
        case let .duplicate(other):
            switch other {
            case .answer: return L.hotkeysIssueDuplicate(L.hotkeysAnswer)
            case .hangUp: return L.hotkeysIssueDuplicate(L.hotkeysHangUp)
            case .mute: return L.hotkeysIssueDuplicate(L.hotkeysMute)
            }
        }
    }
}

/// The key recorder: shows the combination; a click makes it listen, the next key press with modifiers is the
/// new combination. Esc cancels, Delete (without modifiers) clears, as does the × button.
struct HotkeyRecorder: View {
    let combo: HotkeyCombo?
    let isRecording: (Bool) -> Void
    let onChange: (HotkeyCombo?) -> Void
    @Local private var recording = false

    var body: some View {
        HStack(spacing: 6) {
            Button { setRecording(!recording) } label: {
                Text(recording ? L.hotkeysRecording : (combo?.display ?? L.hotkeysNotSet))
                    .font(.system(size: 12.5, weight: combo == nil || recording ? .regular : .medium))
                    .foregroundStyle(recording || combo == nil ? Theme.label2 : Color.primary)
                    .frame(width: 124, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.fill))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(recording ? Color.accentColor : Theme.separator, lineWidth: recording ? 1.5 : 0.5))
            }
            .buttonStyle(.plain)
            .help(L.hotkeysRecordHelp)
            .background(KeyCatcher(active: recording) { handle($0) })
            Button { onChange(nil) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.label3)
            }
            .buttonStyle(.plain)
            .help(L.hotkeysClearHelp)
            .opacity(combo == nil ? 0 : 1)
            .disabled(combo == nil)
        }
        .onDisappear { setRecording(false) }
    }

    private func setRecording(_ on: Bool) {
        guard recording != on else { return }
        recording = on
        isRecording(on)
    }

    private func handle(_ result: KeyCatcher.Result) {
        switch result {
        case .cancelled: break
        case .cleared: onChange(nil)
        case let .combo(c): onChange(c)
        }
        setRecording(false)
    }
}

/// Takes the keyboard while `active`: a key press (with ⌘ too, so no menu sees it) is reported once.
private struct KeyCatcher: NSViewRepresentable {
    enum Result { case cancelled, cleared, combo(HotkeyCombo) }
    var active: Bool
    var report: (Result) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.report = report
        view.active = active
        if active, view.window?.firstResponder !== view {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    final class CatcherView: NSView {
        var report: ((Result) -> Void)?
        var active = false

        override var acceptsFirstResponder: Bool { active }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard active, event.type == .keyDown else { return false }
            handle(event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard active else { super.keyDown(with: event); return }
            handle(event)
        }

        override func resignFirstResponder() -> Bool {
            if active { DispatchQueue.main.async { [weak self] in self?.finish(.cancelled) } }
            return true
        }

        private func handle(_ event: NSEvent) {
            let modifiers = GlobalHotkeys.modifiers(from: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            let code = Int(event.keyCode)
            if modifiers.isEmpty {
                if code == 53 { finish(.cancelled); return }                         // Esc
                if code == 51 || code == 117 { finish(.cleared); return }            // Delete, Forward Delete
            }
            finish(.combo(HotkeyCombo(keyCode: code, modifiers: modifiers)))
        }

        private func finish(_ result: Result) {
            guard active else { return }
            active = false
            report?(result)
        }
    }
}
