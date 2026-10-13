import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacroSIPCore

/// Settings › Quick keys (SCREENS.md screen 11): the key table, then the panel group.
struct QuickKeysPane: View {
    @Environment(AppModel.self) private var model
    private enum Field: Hashable {
        case name(Int), number(Int)
        var row: Int { switch self { case .name(let i), .number(let i): return i } }
    }
    @FocusState private var focus: Field?
    @Local private var dragging: UUID?
    @Local private var drafts: [Field: String] = [:]      // text typed in a field, saved when editing ends (Return or leaving the field)
    @Local private var focusTracked = false     // the window's first focus (row 1) is not a choice of the user

    var body: some View {
        PaneContainer(minHeight: 520) {
            VStack(alignment: .leading, spacing: 6) {
                table
                Text(L.quickKeysHint).font(.system(size: 11.5)).foregroundStyle(Theme.label2).padding(.horizontal, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FormGroup(header: L.quickKeysPanelHeader, content: {
                FormRow(label: L.quickKeysPanelShow, help: L.quickKeysPanelFooter) {
                    SegmentedTabs(items: [
                        .init(value: QuickKeyPanel.off, title: L.quickKeysPanelOff),
                        .init(value: QuickKeyPanel.right, title: L.quickKeysPanelRight),
                        .init(value: QuickKeyPanel.bottom, title: L.quickKeysPanelBottom),
                    ], selection: Binding(get: { model.quickKeyPanel }, set: { model.setQuickKeyPanel($0) }))
                    .frame(width: 210)
                }
                FormDivider()
                FormRow(label: L.quickKeysPickupLabel, help: L.quickKeysPickupSub) {
                    PickupCodeField()
                }
            }, footerView: {
                Text(L.quickKeysShortcutsNote).fixedSize(horizontal: false, vertical: true)
            })
        }
        .onAppear {
            focusTracked = false
            DispatchQueue.main.async { consumeRequests() }
            for delay in [0.05, 0.25] {     // the window hands its first field the focus after the pane appears
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if !focusTracked { NSApp.keyWindow?.makeFirstResponder(nil) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focusTracked = true }
        }
        .onChange(of: model.quickKeys.focusNewRow) { _, _ in consumeRequests() }
        .onChange(of: focus) { old, f in
            if let old, old != f { commit(old) }       // editing of a field ends: save it
            guard focusTracked || f == nil else { return }
            switch f {
            case .name(let i):
                // The list is dense: a row past its end is the first empty row.
                let row = min(i, model.settings.quickKeys.keys.count)
                model.quickKeys.selectedRow = row
                if row != i { focus = .name(row) }
            case .number(let i):
                let row = min(i, model.settings.quickKeys.keys.count)
                model.quickKeys.selectedRow = row
                if row != i { focus = .number(row) }
            case nil: model.normalizeQuickKeys()
            }
        }
        .onDisappear {
            commitAll()
            dragging = nil
            model.normalizeQuickKeys()
        }
    }

    // MARK: - Table

    private var table: some View {
        let keys = model.settings.quickKeys.keys
        return VStack(spacing: 0) {
            header
            Divider().opacity(0.7)
            ForEach(0..<QuickKeysSettings.maxKeys, id: \.self) { i in
                row(i, key: i < keys.count ? keys[i] : nil)
                Divider().opacity(0.4)
            }
            footer
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.groupBox))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.separator, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func cells<A: View, B: View, C: View, D: View, E: View, F: View>(
        @ViewBuilder _ grip: () -> A, @ViewBuilder _ name: () -> B, @ViewBuilder _ number: () -> C,
        @ViewBuilder _ type: () -> D, @ViewBuilder _ blf: () -> E, @ViewBuilder _ key: () -> F
    ) -> some View {
        HStack(spacing: 8) {
            grip().frame(width: 16)
            name().frame(width: 150, alignment: .leading)
            number().frame(width: 106, alignment: .leading)
            type().frame(width: 220, alignment: .leading)
            blf().frame(width: 30)
            key().frame(width: 54, alignment: .trailing)
        }
    }

    private var header: some View {
        cells({ Color.clear }, { Text(L.quickKeysColumnName) }, { Text(L.quickKeysColumnNumber) },
              { Text(L.quickKeysColumnType) }, { Text(L.quickKeysColumnBLF) }, { Text(L.quickKeysColumnKey) })
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.label2)
            .frame(height: 26)
    }

    private func row(_ i: Int, key: QuickKey?) -> some View {
        let selected = model.quickKeys.selectedRow == i
        let shown = key.flatMap { $0.isEmpty ? nil : $0 }
        return cells({
            Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(shown == nil ? Theme.label3 : Theme.label2)
                .frame(width: 16, height: 28).contentShape(Rectangle())
                .onDrag {
                    commitAll()
                    if let key = shown { dragging = key.id; return NSItemProvider(object: key.id.uuidString as NSString) }
                    return NSItemProvider()
                }
        }, {
            TextField("", text: textBinding(.name(i)), prompt: Text(L.quickKeysRowEmpty).foregroundStyle(Theme.label3))
                .textFieldStyle(.plain).font(.system(size: 13))
                .onSubmit { commit(.name(i)) }
                .focused($focus, equals: .name(i))
                .accessibilityLabel("\(L.quickKeysColumnName) \(i + 1)")
        }, {
            TextField("", text: textBinding(.number(i)))
                .textFieldStyle(.plain).font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.label2)
                .onSubmit { commit(.number(i)) }
                .focused($focus, equals: .number(i))
                .accessibilityLabel("\(L.quickKeysColumnNumber) \(i + 1)")
        }, {
            typeMenu(i, key: shown)
        }, {
            Toggle("", isOn: Binding(
                get: { key?.blf ?? false },
                set: { on in update(i) { $0.blf = on } }))
                .labelsHidden().toggleStyle(.checkbox)
                .disabled(shown == nil || shown?.trimmedNumber.isEmpty != false)
                .accessibilityLabel("\(L.quickKeysColumnBLF) \(i + 1)")
        }, {
            Text(QuickKeysSettings.shortcutDigit(at: i).map { "⌘\($0)" } ?? "—")
                .font(.system(size: 11.5, design: .rounded)).foregroundStyle(Theme.label2)
                .opacity(shown == nil ? 0.5 : 1)
        })
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 30)
        .background(selected ? Theme.blue.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.quickKeys.selectedRow = min(i, model.settings.quickKeys.keys.count) }
        .onDrop(of: [.text], delegate: RowDrop(index: i, model: model, dragging: $dragging))
    }

    private func typeMenu(_ i: Int, key: QuickKey?) -> some View {
        let current = key?.type ?? .call
        let type = Binding<QuickKeyType>(get: { current }, set: { t in update(i) { $0.type = t } })
        return Menu {
            Picker("", selection: type) {
                ForEach([QuickKeyType.call, .dtmf], id: \.self) { t in Label { Text(L.quickKeyTypeName(t)) } icon: { QuickKeyGlyph(type: t) }.tag(t) }
            }.pickerStyle(.inline).labelsHidden()
            Divider()
            Picker("", selection: type) {
                ForEach([QuickKeyType.blindTransfer, .attendedTransfer, .conference], id: \.self) { t in
                    Label { Text(L.quickKeyTypeName(t)) } icon: { QuickKeyGlyph(type: t) }.tag(t)
                }
            }.pickerStyle(.inline).labelsHidden()
            Divider()
            Section(L.quickKeysSmartCaption) {
                Picker("", selection: type) {
                    ForEach([QuickKeyType.smartBlindTransfer, .smartAttendedTransfer, .smartConference], id: \.self) { t in
                        Label { Text(L.quickKeyTypeName(t)) } icon: { QuickKeyGlyph(type: t) }.tag(t)
                    }
                }.pickerStyle(.inline).labelsHidden()
            }
        } label: {
            Text(key == nil ? "" : L.quickKeyTypeName(current)).font(.system(size: 13))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 190, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(key == nil ? .hidden : .visible)
        .disabled(key == nil)
        .accessibilityLabel("\(L.quickKeysColumnType) \(i + 1)")
    }

    private var footer: some View {
        let count = model.quickKeyList.count
        return HStack(spacing: 4) {
            footerButton("plus", help: L.quickKeysAdd, disabled: count >= QuickKeysSettings.maxKeys) { addRow() }
            footerButton("minus", help: L.quickKeysRemove, disabled: selectedKey == nil) {
                commitAll()
                if let k = selectedKey { model.removeQuickKey(k.id); model.quickKeys.selectedRow = nil }
            }
            Spacer(minLength: 0)
            Text(L.quickKeysCount(count)).font(.system(size: 11.5)).foregroundStyle(Theme.label2)
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(Color.primary.opacity(0.03))
    }

    private func footerButton(_ symbol: String, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 22, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Theme.label2).disabled(disabled).opacity(disabled ? 0.4 : 1)
        .help(help).accessibilityLabel(help)
    }

    // MARK: - Editing

    private var selectedKey: QuickKey? {
        guard let r = model.quickKeys.selectedRow, model.settings.quickKeys.keys.indices.contains(r) else { return nil }
        let k = model.settings.quickKeys.keys[r]
        return k.isEmpty ? nil : k
    }

    /// The first row without a key: the list is dense, so it is the one after the last key.
    private func addRow() {
        commitAll()
        model.normalizeQuickKeys()
        let row = model.settings.quickKeys.keys.count
        guard row < QuickKeysSettings.maxKeys else { return }
        model.quickKeys.selectedRow = row
        focusTracked = true
        focus = .name(row)
    }

    private func consumeRequests() {
        if model.quickKeys.focusNewRow {
            model.quickKeys.focusNewRow = false
            DispatchQueue.main.async { addRow() }
        }
    }

    /// The field shows what is being typed; the key changes when the field is committed.
    private func textBinding(_ field: Field) -> Binding<String> {
        Binding(
            get: {
                if let d = drafts[field] { return d }
                let keys = model.settings.quickKeys.keys
                guard field.row < keys.count else { return "" }
                switch field { case .name: return keys[field.row].name; case .number: return keys[field.row].number }
            },
            set: { drafts[field] = $0 })
    }

    private func commit(_ field: Field) {
        guard let text = drafts.removeValue(forKey: field) else { return }
        let keys = model.settings.quickKeys.keys
        let current = field.row < keys.count ? { switch field { case .name: return keys[field.row].name; case .number: return keys[field.row].number } }() : ""
        guard text != current else { return }
        switch field {
        case .name: update(field.row) { $0.name = text }
        case .number: update(field.row) { $0.number = text }
        }
    }

    private func commitAll() {
        for field in drafts.keys.sorted(by: { $0.row < $1.row }) { commit(field) }
    }

    /// Changes row `i`. A row past the end of the list becomes a new key (the list stays dense).
    private func update(_ i: Int, _ change: (inout QuickKey) -> Void) {
        model.updateSettings { s in
            if i < s.quickKeys.keys.count {
                change(&s.quickKeys.keys[i])
            } else if s.quickKeys.keys.count < QuickKeysSettings.maxKeys {
                var k = QuickKey()
                change(&k)
                s.quickKeys.keys.append(k)
            }
        }
    }
}

/// Reorders by drag: the dragged key moves to the row it is dropped on (live, while over it).
private struct RowDrop: DropDelegate {
    let index: Int
    let model: AppModel
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let id = dragging else { return }
        // A drag that was cancelled leaves `dragging` behind; with the button up there is no drag any more.
        guard NSEvent.pressedMouseButtons & 1 != 0 else { dragging = nil; return }
        MainActor.assumeIsolated {
            let keys = model.settings.quickKeys.keys
            guard let from = keys.firstIndex(where: { $0.id == id }) else { return }
            let to = min(index, keys.count - 1)
            guard from != to else { return }
            model.updateSettings { $0.quickKeys.move(from: from, to: to) }
            model.quickKeys.selectedRow = to
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropExited(info: DropInfo) {
        if NSEvent.pressedMouseButtons & 1 == 0 { dragging = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// The pickup code: digits, `*` and `#` only. A wrong character shows the red outline; the field is saved
/// when editing ends (Return or leaving the field) and goes back to the saved code if it is still wrong.
private struct PickupCodeField: View {
    @Environment(AppModel.self) private var model
    @Local private var text = ""
    @FocusState private var focused: Bool

    private var saved: String { model.settings.quickKeys.pickupCode }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: .monospaced))
            .padding(.horizontal, 7)
            .frame(width: 90, height: 22)
            .fieldBackground(focused: focused, invalid: !QuickKeysSettings.isValidPickupCode(text))
            .focused($focused)
            .onAppear { text = saved }
            .onSubmit { commit() }
            .onChange(of: focused) { _, f in
                if !f { commit(); if !QuickKeysSettings.isValidPickupCode(text) { text = saved } }
            }
            .onChange(of: saved) { _, new in if !focused { text = new } }
            .onDisappear { commit() }
            .accessibilityLabel(L.quickKeysPickupLabel)
    }

    private func commit() {
        guard QuickKeysSettings.isValidPickupCode(text), text != saved else { return }
        model.updateSettings { $0.quickKeys.pickupCode = text }
    }
}
