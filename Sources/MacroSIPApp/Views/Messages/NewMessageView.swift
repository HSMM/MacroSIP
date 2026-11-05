import SwiftUI
import MacroSIPCore

/// 14.3: back and title, the To field with the number field's suggestions, the From line, the composer.
struct NewMessageView: View {
    @Environment(AppModel.self) private var model
    @Local private var toText = ""
    @Local private var picked: NewMessagePrefill?          // a suggestion shown as a token followed by its number
    @Local private var text = ""
    @Local private var highlighted: SuggestionRow.ID?
    @Local private var composerFocus = 0
    @Local private var started = false
    @Local private var caretToEnd = false
    @Local private var accountOverride: AccountID?           // an account chosen outside the account row (a call-log entry's)
    @Local private var rowChoiceAtStart: AccountID?
    @FocusState private var toFocused: Bool
    @FocusState private var tokenFocused: Bool

    /// What the To field holds: the picked number, or the typed text.
    private var address: String { (picked?.number ?? toText).trimmingCharacters(in: .whitespacesAndNewlines) }

    private var local: [Contact] {
        guard picked == nil, toText.contains(where: \.isLetter), !toText.lowercased().hasPrefix("sip:"),
              !model.directory.dismissed else { return [] }
        return model.suggestions(for: toText)
    }

    /// The account the message goes through: the account row's choice, unless the form was opened for another account and
    /// the row has not been changed since.
    private var composeAccount: AccountConfig? {
        if let id = accountOverride, model.selectedAccountID == rowChoiceAtStart, let a = model.account(id), a.enabled { return a }
        return model.effectiveAccount
    }

    var body: some View {
        let account = composeAccount
        let local = self.local
        let mine = model.directory.owner == .messageTo && picked == nil
        let sections = mine ? model.directorySections(excluding: local) : []
        let rows = SuggestionRow.rows(local: local, sections: sections)
        let pending = (mine && !model.directory.dismissed) ? model.directory.pending : []
        VStack(spacing: 0) {
            header
            Divider()
            toRow(rows: rows)
            fromLine(account)
            Spacer(minLength: 0).background(Theme.content)
            MessageComposerBar(
                text: $text, placeholder: L.messagesComposerPlaceholder, enabled: account != nil,
                canSend: account != nil && !address.isEmpty && model.canSend(text), tooLong: model.isTooLong(text),
                focusTrigger: composerFocus, autoFocus: false,
                onSend: send, onEscape: escape)
        }
        .overlay(alignment: .topLeading) {
            if !rows.isEmpty || !pending.isEmpty {
                SuggestionList(local: local, sections: sections, pending: pending, highlighted: highlighted, query: toText,
                               fill: { pick($0) }, call: { pick($0) }, maxHeight: 270)
                .padding(.leading, 44).padding(.trailing, 10)
                .offset(y: 74)
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            rowChoiceAtStart = model.selectedAccountID
            if let prefill = model.newMessagePrefill {
                model.newMessagePrefill = nil
                accountOverride = prefill.account
                if let name = prefill.name, !name.isEmpty { picked = prefill } else { toText = prefill.number }
            }
            if picked != nil { composerFocus &+= 1 }
            else {
                caretToEnd = !toText.isEmpty
                toFocused = true
            }
            if picked == nil, !toText.isEmpty { model.textChangedForDirectory(toText, owner: .messageTo) }
        }
        .onChange(of: toFocused) { _, focused in
            // A prefilled address is not selected when the field gets the focus: the cursor goes to its end.
            guard focused, caretToEnd else { return }
            caretToEnd = false
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                _ = NSApp.sendAction(#selector(NSResponder.moveToEndOfLine(_:)), to: nil, from: nil)
            }
        }
        .onChange(of: toText) { _, t in
            highlighted = nil
            model.textChangedForDirectory(t, owner: .messageTo)
        }
        .onDisappear { model.directory.owner = .numberField; model.clearDirectoryResults() }
        .background(Theme.content)
    }

    private var header: some View {
        ZStack {
            Text(L.messagesNew).font(.system(size: 13, weight: .semibold))
            HStack { BackButton { model.showMessagesList() }; Spacer() }
        }
        .padding(.leading, 6).padding(.trailing, 10)
        .frame(height: 44)
    }

    private func toRow(rows: [SuggestionRow]) -> some View {
        HStack(spacing: 6) {
            Text(L.messagesNewTo).font(.system(size: 12.5)).foregroundStyle(Theme.label2)
            Group {
                if let picked {
                    HStack(spacing: 6) {
                        Text(picked.name ?? picked.number)
                            .font(.system(size: 12.5)).foregroundStyle(Theme.blue).lineLimit(1)
                            .padding(.horizontal, 7).frame(height: 19)
                            .background(Capsule().fill(Theme.blueTint))
                        Text(picked.number).font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.label2).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .focusable()
                    .focused($tokenFocused)
                    .focusEffectDisabled()
                    .onTapGesture { tokenFocused = true }
                    .onKeyPress(.delete) { clearToken(); return .handled }
                    .onKeyPress(.deleteForward) { clearToken(); return .handled }
                } else {
                    TextField(L.numberPlaceholder, text: $toText)
                        .textFieldStyle(.plain)
                        .focused($toFocused)
                        .onSubmit {
                            if let id = highlighted, let row = rows.first(where: { $0.id == id }) { pick(row) }
                            else { commitAddress() }
                        }
                        .onKeyPress(.downArrow) { move(1, in: rows) }
                        .onKeyPress(.upArrow) { move(-1, in: rows) }
                        .onKeyPress(.escape) {
                            if !rows.isEmpty || !model.directory.pending.isEmpty {
                                model.directory.dismissed = true; highlighted = nil; return .handled
                            }
                            escape(); return .handled
                        }
                        .accessibilityLabel(L.messagesNewTo)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8).frame(minHeight: 26)
            .fieldBackground(focused: toFocused || tokenFocused)
        }
        .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, 4)
        .zIndex(1)
    }

    private func fromLine(_ account: AccountConfig?) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                StatusDot(kind: account.map { model.dot(for: $0) } ?? .off, size: 7)
                Text(L.messagesNewFrom(account?.displayName ?? L.accountPopupNone)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11)).foregroundStyle(Theme.label2)
            .padding(.leading, 37).padding(.trailing, 10).padding(.bottom, 7)
            Divider()
        }
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

    /// A suggestion becomes the token; the cursor goes to the composer.
    private func pick(_ row: SuggestionRow) {
        let name: String
        switch row {
        case let .contact(c): name = c.displayName
        case let .entry(e): name = e.displayName
        }
        guard let number = row.number else { return }
        picked = NewMessagePrefill(number: number, name: name)
        toText = ""
        highlighted = nil
        model.clearDirectoryResults()
        if !switchToExisting() { composerFocus &+= 1 }
    }

    private func clearToken() {
        picked = nil
        toText = ""
        toFocused = true
    }

    /// Return in the To field with nothing highlighted: the typed address is final, the cursor goes to the composer.
    private func commitAddress() {
        guard !address.isEmpty else { return }
        model.clearDirectoryResults()
        if !switchToExisting() { composerFocus &+= 1 }
    }

    /// The address already has a conversation on the outgoing account: show it, with the typed text in its composer.
    @discardableResult
    private func switchToExisting() -> Bool {
        guard let account = composeAccount, let dial = DialString.parse(address, account: account),
              let existing = model.conversation(account: account.id, address: dial.uri) else { return false }
        if !text.isEmpty { model.messageDrafts[existing.id] = text }
        model.openConversation(existing.id, focus: true)
        return true
    }

    private func send() {
        guard !address.isEmpty else { return }
        // An address that already has a conversation on this account sends into it (`sendNew` reuses it).
        if let id = model.sendNew(text: text, to: address, name: picked?.name, account: composeAccount?.id) { model.openConversation(id, focus: true) }
    }

    private func escape() { model.showMessagesList() }
}
