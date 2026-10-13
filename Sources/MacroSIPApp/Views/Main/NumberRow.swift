import SwiftUI
import MacroSIPCore

/// Number field (SCREENS.md "Number row"); the account pop-up button sits in its own row above (`AccountRow`).
/// Under the field: local contacts that match the letters typed, then results from the directory sources
/// (screen 13).
struct NumberRow: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @Local private var highlighted: SuggestionRow.ID?

    private var suggestions: [Contact] {
        let text = model.dialText
        guard text.contains(where: \.isLetter), !text.lowercased().hasPrefix("sip:") else { return [] }
        return model.suggestions(for: text)
    }

    var body: some View {
        @Bindable var model = model
        // Computed once per body, from the contacts held in memory.
        let local = model.directory.dismissed ? [] : self.suggestions
        let sections = model.directorySections(excluding: local)
        let rows = SuggestionRow.rows(local: local, sections: sections)
        let pending = model.directory.dismissed ? [] : model.directory.pending
        let visible = !rows.isEmpty
        HStack(spacing: 6) {
            TextField(L.numberPlaceholder, text: $model.dialText)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($focused)
                .padding(.horizontal, 8)
                .frame(minHeight: 30)
                .fieldBackground(focused: focused)
                .disabled(model.effectiveAccount == nil)
                .opacity(model.effectiveAccount == nil ? 0.5 : 1)
                .onSubmit {
                    if let id = highlighted, let row = rows.first(where: { $0.id == id }) { activate(row) }
                    else { model.placeCallFromField() }
                }
                .onKeyPress(.escape) {
                    if visible || !pending.isEmpty { model.directory.dismissed = true; highlighted = nil; return .handled }
                    guard !model.dialText.isEmpty else { return .ignored }
                    model.dialText = ""
                    return .handled
                }
                .onKeyPress(.downArrow) { move(1, in: rows) }
                .onKeyPress(.upArrow) { move(-1, in: rows) }
                .onKeyPress(characters: ["c"], phases: .down) { press in
                    guard press.modifiers == .command, let id = highlighted,
                          let number = rows.first(where: { $0.id == id })?.number else { return .ignored }
                    model.copyToPasteboard(number)
                    return .handled
                }
                .accessibilityLabel(L.numberPlaceholder)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(height: 40)
        .overlay(alignment: .topLeading) {
            if visible || !pending.isEmpty {
                SuggestionList(local: local, sections: sections, pending: pending, highlighted: highlighted,
                               query: model.dialText) { row in
                    fill(row)
                } call: { row in
                    activate(row)
                }
                .padding(.horizontal, 10)
                .offset(y: 32)
            }
        }
        .onAppear { focused = true }
        .onChange(of: model.dialText) { _, text in
            highlighted = nil
            model.textChangedForDirectory(text)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if (note.object as? NSWindow) === model.mainWindow, !model.showKeypad { focused = true }
        }
        .onChange(of: model.showKeypad) { _, on in if !on { focused = true } }
        .onChange(of: model.tab) { _, tab in if tab == .dialpad, !model.showKeypad { focused = true } }
    }

    private func move(_ delta: Int, in rows: [SuggestionRow]) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let current = highlighted.flatMap { id in rows.firstIndex { $0.id == id } }
        let next: Int
        if let current { next = (current + delta + rows.count) % rows.count }
        else { next = delta > 0 ? 0 : rows.count - 1 }
        highlighted = rows[next].id
        return .handled
    }

    /// A click fills the field with the number (as before); the row's Return/double action calls.
    private func fill(_ row: SuggestionRow) {
        switch row {
        case let .contact(c):
            model.dialText = c.defaultNumber?.value ?? ""
            model.selectedAccountID = c.preferredAccountID
        case let .entry(e):
            model.dialText = e.defaultNumber?.value ?? ""
        }
        model.directory.suppressedText = model.dialText
        model.clearDirectoryResults()
        focused = true
    }

    /// Return on a highlighted row: calls it.
    private func activate(_ row: SuggestionRow) {
        switch row {
        case let .contact(c): model.placeCall(to: c)
        case let .entry(e): model.placeCall(to: e)
        }
        model.clearDirectoryResults()
    }
}

/// One selectable row of the suggestion list.
enum SuggestionRow: Identifiable, Equatable {
    case contact(Contact)
    case entry(DirectoryEntry)

    var id: String {
        switch self {
        case let .contact(c): return "c:\(c.id.uuidString)"
        case let .entry(e): return "d:\(e.sourceID.uuidString):\(e.id)"
        }
    }

    var number: String? {
        switch self {
        case let .contact(c): return c.defaultNumber?.value
        case let .entry(e): return e.defaultNumber?.value
        }
    }

    static func rows(local: [Contact], sections: [DirectorySection]) -> [SuggestionRow] {
        local.map(SuggestionRow.contact) + sections.flatMap { $0.entries.map(SuggestionRow.entry) }
    }
}
