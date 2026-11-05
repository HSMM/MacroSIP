import SwiftUI
import MacroSIPCore

/// The Messages tab (SCREENS.md 14): the conversation list, one conversation, or the new-message form. Which one is
/// shown lives in the model, so it is still there after another tab was used.
struct MessagesTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.messagesPage {
        case .list: MessagesView()
        case let .conversation(id): ConversationView(id: id).id(id)
        case .new: NewMessageView()
        }
    }
}

/// 14.1: tool row with New Message, then the conversations, newest activity first.
struct MessagesView: View {
    @Environment(AppModel.self) private var model
    @Local private var selection: UUID?
    @Local private var pendingDelete: UUID?
    @FocusState private var listFocused: Bool

    private var selected: Conversation? { selection.flatMap(model.conversation) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { model.newMessageFromList() } label: {
                    Label(L.messagesNew, systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(model.enabledAccounts.isEmpty)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(height: 40)
            Divider()
            if model.conversations.isEmpty {
                VStack(spacing: 4) {
                    Spacer()
                    Image(systemName: "bubble.left").font(.system(size: 30, weight: .light))
                        .foregroundStyle(Theme.label3).padding(.bottom, 6)
                    Text(L.messagesEmptyTitle).font(.system(size: 13, weight: .semibold))
                    Text(L.messagesEmptyBody)
                        .font(.system(size: 12)).foregroundStyle(Theme.label2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Spacer().frame(height: 20)
                }
                .padding(.horizontal, 34)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.conversations) { conv in
                                ConversationRow(conversation: conv, selected: selection == conv.id,
                                                select: { selection = conv.id; listFocused = true },
                                                open: { model.openConversation(conv.id, focus: true) },
                                                delete: { pendingDelete = conv.id })
                                    .id(conv.id)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
                }
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(.return) {
                    guard !model.incomingKeyGuard, let c = selected else { return .ignored }
                    model.openConversation(c.id, focus: true); return .handled
                }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.delete, phases: .down) { press in
                    guard press.modifiers.contains(.command), let c = selected else { return .ignored }
                    pendingDelete = c.id; return .handled
                }
            }
        }
        .alert(pendingDeleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button(L.commonCancel, role: .cancel) { pendingDelete = nil }
            Button(L.commonDelete, role: .destructive) {
                if let id = pendingDelete { model.deleteConversation(id); if selection == id { selection = nil } }
                pendingDelete = nil
            }
        } message: {
            Text(L.messagesDeleteBody(pendingDelete.map { model.messages(in: $0).count } ?? 0))
        }
    }

    private var pendingDeleteTitle: String {
        L.messagesDeleteTitle(pendingDelete.flatMap(model.conversation).map(model.name(for:)) ?? "")
    }

    private func move(_ delta: Int) {
        let list = model.conversations
        guard !list.isEmpty else { return }
        guard let current = selection, let i = list.firstIndex(where: { $0.id == current }) else {
            selection = list.first?.id; return
        }
        selection = list[max(0, min(list.count - 1, i + delta))].id
    }
}

/// One conversation (44 pt): avatar, name with the account chip, the last message, the time and the unread count.
struct ConversationRow: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let selected: Bool
    let select: () -> Void
    let open: () -> Void
    let delete: () -> Void

    var body: some View {
        let c = conversation
        let name = model.name(for: c)
        let last = model.conversationLast[c.id]
        let unread = c.unread > 0
        let secondary: Color = selected ? .white.opacity(0.8) : Theme.label2
        HStack(spacing: 9) {
            AvatarView(name: name, size: 32, contact: model.contact(for: c))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(name).font(.system(size: 13, weight: unread ? .bold : .medium)).lineLimit(1)
                    if model.account(c.accountID) != nil { AccountChip(name: model.accountName(c.accountID), selected: selected) }
                }
                previewLine(last, secondary: secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                Text(last.map { MessageFormat.rowTime($0.at) } ?? "")
                    .font(.system(size: 11.5, weight: unread ? .medium : .regular)).monospacedDigit().lineLimit(1)
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : (unread ? Theme.blue : Theme.label2))
                if unread {
                    Text("\(c.unread)")
                        .font(.system(size: 10.5, weight: .bold)).foregroundStyle(selected ? Theme.blue : .white)
                        .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 16)
                        .background(Capsule().fill(selected ? Color.white : Theme.blue))
                        .accessibilityLabel(L.messagesRowUnread(c.unread))
                } else {
                    Color.clear.frame(width: 1, height: 16)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minHeight: 44)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.blue : .clear))
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open() }
        .onTapGesture { select() }
        .contextMenu {
            Button(L.messagesMenuCall) { model.call(c) }.disabled(model.accountState(of: c) != .ready)
            if model.contact(for: c) == nil { Button(L.messagesMenuAddContact) { model.addToContacts(c) } }
            Button(L.messagesMenuCopyNumber) { model.copyToPasteboard(c.remoteNumber) }
            Divider()
            Button(L.messagesMenuDeleteConversation, role: .destructive, action: delete)
                .keyboardShortcut(.delete, modifiers: .command)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility(name: name, last: last))
    }

    /// Line 2: the last message on one line. A last outgoing message that failed starts with the red "Not sent" marker.
    @ViewBuilder
    private func previewLine(_ last: Message?, secondary: Color) -> some View {
        if let last {
            let failed = last.direction == .outgoing && last.state == .failed
            HStack(spacing: 0) {
                if failed {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(selected ? Color.white : Theme.red).padding(.trailing, 2)
                    Text(L.messagesStatusFailed).fontWeight(.medium).foregroundStyle(selected ? Color.white : Theme.red).lineLimit(1)
                        .fixedSize()
                    Text(" · ").foregroundStyle(secondary)
                }
                Text(MessageFormat.preview(last)).foregroundStyle(secondary).lineLimit(1).truncationMode(.tail)
            }
            .font(.system(size: 11.5))
        }
    }

    private func accessibility(name: String, last: Message?) -> String {
        var parts = [name]
        if conversation.unread > 0 { parts.append(L.messagesRowUnread(conversation.unread)) }
        if let last { parts.append(MessageFormat.preview(last)) }
        return parts.joined(separator: ", ")
    }
}

/// The account name as a small grey chip (as in the call log rows).
struct AccountChip: View {
    let name: String
    var selected = false

    var body: some View {
        Text(name)
            .font(.system(size: 10)).lineLimit(1)
            .padding(.horizontal, 5)
            .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.white.opacity(0.2) : Theme.fill))
            .fixedSize()
    }
}
