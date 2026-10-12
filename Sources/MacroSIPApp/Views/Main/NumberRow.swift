import SwiftUI
import MacroSIPCore

/// Number field (SCREENS.md "Number row"); the account pop-up button sits in its own row above (`AccountRow`).
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
            TextField(L.numberPlaceholder, text: $model.dialText)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($focused)
                .padding(.horizontal, 8)
                .frame(minHeight: 30)
                .fieldBackground(focused: focused)
                .disabled(model.effectiveAccount == nil)
                .opacity(model.effectiveAccount == nil ? 0.5 : 1)
                .onSubmit { model.placeCallFromField() }
                .onKeyPress(.escape) {
                    guard !model.dialText.isEmpty else { return .ignored }
                    model.dialText = ""
                    return .handled
                }
                .accessibilityLabel(L.numberPlaceholder)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(height: 40)
        .overlay(alignment: .topLeading) {
            if !suggestions.isEmpty {
                SuggestionList(contacts: suggestions) { contact in
                    model.dialText = contact.number
                    model.selectedAccountID = contact.preferredAccountID
                    focused = true
                }
                .padding(.horizontal, 10)
                .offset(y: 32)
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
