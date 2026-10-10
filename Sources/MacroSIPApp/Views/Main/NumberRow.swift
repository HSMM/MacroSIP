import SwiftUI
import MacroSIPCore

/// Outgoing account popup and number field (SCREENS.md "Number row").
struct NumberRow: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    private var suggestions: [Contact] {
        let text = model.dialText
        guard text.contains(where: \.isLetter), !text.lowercased().hasPrefix("sip:") else { return [] }
        return model.suggestions(for: text)
    }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            AccountPicker()
            TextField(L.numberPlaceholder, text: $model.dialText)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($focused)
                .padding(.horizontal, 8)
                .frame(minHeight: 30)
                .fieldBackground(focused: focused)
                .disabled(!model.hasAccounts)
                .opacity(model.hasAccounts ? 1 : 0.5)
                .onSubmit { model.placeCallFromField() }
                .onKeyPress(.escape) {
                    guard !model.dialText.isEmpty else { return .ignored }
                    model.dialText = ""
                    return .handled
                }
                .accessibilityLabel(L.numberPlaceholder)
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(height: 46)
        .overlay(alignment: .topLeading) {
            if !suggestions.isEmpty {
                SuggestionList(contacts: suggestions) { contact in
                    model.dialText = contact.number
                    model.selectedAccountID = contact.preferredAccountID
                    focused = true
                }
                .padding(.leading, 10 + 112 + 6)
                .padding(.trailing, 10)
                .offset(y: 38)
            }
        }
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if (note.object as? NSWindow) === model.mainWindow, !model.showKeypad { focused = true }
        }
        .onChange(of: model.showKeypad) { _, on in if !on { focused = true } }
        .onChange(of: model.tab) { _, tab in if tab == .dialpad, !model.showKeypad { focused = true } }
    }
}

struct SuggestionList: View {
    let contacts: [Contact]
    let pick: (Contact) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(contacts) { c in
                Button { pick(c) } label: {
                    HStack(spacing: 8) {
                        AvatarView(name: c.name, size: 22)
                        Text(c.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(c.number).font(.system(size: 11.5)).foregroundStyle(Theme.label2).lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.separator))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
    }
}

/// Short account name with a status dot; disabled when there are no accounts.
struct AccountPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let current = model.effectiveAccount
        Menu {
            ForEach(model.accounts) { account in
                Button {
                    model.selectedAccountID = account.id
                } label: {
                    Text(account.displayName)
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let current {
                    StatusDot(kind: model.dot(for: current), size: 8)
                    Text(current.displayName).font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail)
                } else {
                    StatusDot(kind: .off, size: 8)
                    Text(L.accountPickerNone).font(.system(size: 12.5)).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.blue))
            }
            .padding(.leading, 7).padding(.trailing, 4)
            .frame(width: 112, height: 30)
            .fieldBackground()
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .disabled(!model.hasAccounts)
        .opacity(model.hasAccounts ? 1 : 0.5)
        .help(L.accountPickerHelp)
        .accessibilityLabel(L.accountPickerHelp)
    }
}
