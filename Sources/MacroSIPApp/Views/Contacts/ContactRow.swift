import SwiftUI
import MacroSIPCore

/// One row of the Contacts list. Hover state lives here, so moving the pointer redraws one row and not the list.
struct ContactRow: View {
    @Environment(AppModel.self) private var model
    let contact: Contact
    let selected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onToggleFavorite: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    @Local private var hovered = false

    /// "102 · Work"; a SIP address shows without its label.
    static func numberLine(_ n: PhoneNumber) -> String {
        n.label == .sip ? n.value : "\(n.value) · \(L.phoneLabel(n.label))"
    }

    var body: some View {
        let c = contact
        let status = model.presenceStatus(for: c)
        let extra = max(0, c.numbers.count - 1)
        let line = c.defaultNumber.map(Self.numberLine) ?? ""
        HStack(spacing: 9) {
            AvatarView(name: c.displayName, size: 32, contact: c)
                .overlay(alignment: .bottomTrailing) {
                    if c.subscribePresence {
                        PresenceDot(status: status, ring: selected ? Theme.blue : Theme.content)
                            .offset(x: 2, y: 2)
                    }
                }
            VStack(alignment: .leading, spacing: 0) {
                Text(c.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(line).font(.system(size: 11.5))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Theme.label2).lineLimit(1)
            }
            Spacer(minLength: 4)
            if extra > 0 {
                Text(L.contactsMorePill(extra)).font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(selected ? Color.white.opacity(0.22) : Theme.fill2))
                    .foregroundStyle(selected ? Color.white : Theme.label2)
            }
            if let status, let text = PresenceDot.text(status) {
                Text(text).font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Theme.label2)
                    .lineLimit(1)
            }
            if selected || hovered {
                Button { model.placeCall(to: c) } label: {
                    Image(systemName: "phone.fill").font(.system(size: 11))
                        .foregroundStyle(Theme.green)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(selected ? Color.white : Theme.fill))
                }
                .buttonStyle(.plain)
                .help(L.contactsMenuCall)
                .accessibilityLabel(L.contactsMenuCall)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minHeight: 44)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.blue : (hovered ? Theme.fill : .clear)))
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { model.placeCall(to: c) }
        .onTapGesture { onSelect() }
        .contextMenu {
            ForEach(Array(c.numbersDefaultFirst.enumerated()), id: \.offset) { index, n in
                if index == 0 {
                    Button(L.contactsMenuCallNumber(L.phoneLabel(n.label), n.value)) { model.placeCall(to: c, number: n) }
                        .keyboardShortcut(.return, modifiers: [])
                } else {
                    Button(L.contactsMenuCallNumber(L.phoneLabel(n.label), n.value)) { model.placeCall(to: c, number: n) }
                }
            }
            Menu(L.contactsMenuCallFrom) {
                ForEach(model.enabledAccounts) { a in
                    Button(a.displayName) { model.placeCall(to: c, account: a.id) }
                }
            }
            Button(L.contactsMenuCopy, action: onCopy).keyboardShortcut("c", modifiers: .command)
            Divider()
            Button(L.contactsMenuEdit, action: onEdit).keyboardShortcut("e", modifiers: .command)
            Button(c.isFavorite ? L.contactsMenuFavoriteRemove : L.contactsMenuFavoriteAdd, action: onToggleFavorite)
            Toggle(L.contactsMenuWatchPresence, isOn: Binding(
                get: { c.subscribePresence },
                set: { model.setWatchPresence($0, for: c) }))
            Divider()
            Button(L.contactsMenuDelete, role: .destructive, action: onDelete)
                .keyboardShortcut(.delete, modifiers: .command)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(c.displayName), \(line)" + (status.flatMap(PresenceDot.text).map { ", \($0)" } ?? ""))
    }
}
