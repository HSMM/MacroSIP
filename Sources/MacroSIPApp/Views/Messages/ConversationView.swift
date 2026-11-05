import SwiftUI
import MacroSIPCore

/// 14.2: header (back, contact, Call), the bubbles, the composer.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    @Local private var text = ""
    @Local private var loaded = false

    var body: some View {
        if let conv = model.conversation(id) { content(conv) } else { Color.clear }
    }

    private func content(_ conv: Conversation) -> some View {
        let state = model.accountState(of: conv)
        let ready = state == .ready
        return VStack(spacing: 0) {
            ConversationHeader(conversation: conv)
            Divider()
            MessageThreadView(conversation: conv)
            MessageComposerBar(
                text: $text, placeholder: model.composerPlaceholder(for: conv), enabled: ready,
                canSend: ready && model.canSend(text), tooLong: model.isTooLong(text),
                focusTrigger: model.focusComposer, autoFocus: true,
                onSend: { if model.send(text: text, in: conv.id) { text = "" } },
                onEscape: { model.showMessagesList() })
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = model.messageDrafts[id] ?? ""
            model.updateMessageReadState()
        }
        .onChange(of: text) { _, new in model.messageDrafts[id] = new.isEmpty ? nil : new }
    }
}

struct ConversationHeader: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        let c = conversation
        let name = model.name(for: c)
        let hasChip = model.account(c.accountID) != nil
        HStack(spacing: 8) {
            BackButton { model.showMessagesList() }
            AvatarView(name: name, size: 28, contact: model.contact(for: c))
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    if name != c.remoteNumber { Text(c.remoteNumber).monospacedDigit().lineLimit(1) }
                    if name != c.remoteNumber, hasChip { Text("·") }
                    if hasChip { AccountChip(name: model.accountName(c.accountID)) }
                }
                .font(.system(size: 11)).foregroundStyle(Theme.label2)
            }
            Spacer(minLength: 4)
            let ready = model.accountState(of: c) == .ready
            Button { model.call(c) } label: {
                Image(systemName: "phone.fill").font(.system(size: 11)).foregroundStyle(Theme.green)
                    .frame(width: 24, height: 24).background(Circle().fill(Theme.fill))
            }
            .buttonStyle(.plain)
            .disabled(!ready)
            .opacity(ready ? 1 : 0.4)
            .help(L.messagesCallHelp)
            .accessibilityLabel(L.messagesCallHelp)
        }
        .padding(.leading, 6).padding(.trailing, 10).padding(.vertical, 5)
        .frame(height: 44)
        .background(Theme.content)
    }
}

/// Chevron at the left of the 14.2 and 14.3 headers.
struct BackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.blue)
                .frame(width: 22, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L.messagesBackHelp)
        .accessibilityLabel(L.messagesBackHelp)
    }
}

/// The bubbles of one conversation, oldest at the top; opens at the newest message.
struct MessageThreadView: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        let rows = MessageFormat.thread(model.messageThread)
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            switch row.kind {
                            case let .day(title):
                                Text(title)
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.label2)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 8).padding(.bottom, 5)
                            case let .bubble(message):
                                MessageBubbleRow(message: message, showsMeta: row.showsMeta, showsSent: row.showsSent,
                                                 width: geo.size.width - 20)
                                    .padding(.top, row.gap)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 6)
                    .frame(minHeight: geo.size.height, alignment: .bottom)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.messageThread.map(\.id)) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .background(Theme.content)
    }
}

/// A bubble with its time line.
struct MessageBubbleRow: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let showsMeta: Bool
    let showsSent: Bool
    let width: CGFloat

    private var outgoing: Bool { message.direction == .outgoing }
    private var failed: Bool { message.state == .failed }

    var body: some View {
        VStack(alignment: outgoing ? .trailing : .leading, spacing: 0) {
            HStack(spacing: 6) {
                if outgoing { Spacer(minLength: 0) }
                if failed { failedGlyph }
                bubble
                if !outgoing { Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
            if showsMeta { meta.padding(.top, 2) }
        }
    }

    private var bubble: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 15, bottomLeadingRadius: outgoing ? 15 : 5,
                                           bottomTrailingRadius: outgoing ? 5 : 15, topTrailingRadius: 15)
        // At most 76 % of the list width (84 % with the failed glyph), as wide as its text below that.
        let limit = failed ? width * 0.84 - 22 : width * 0.76
        return CappedWidth(maxWidth: limit) {
            Text(message.text)
                .font(.system(size: 13))
                .foregroundStyle(outgoing ? Color.white : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(shape.fill(outgoing ? Theme.blue : Theme.fill2))
        }
        .contextMenu { bubbleMenu }
    }

    @ViewBuilder
    private var bubbleMenu: some View {
        Button(L.messagesMenuCopyText) { model.copyToPasteboard(message.text) }
        if failed { Button(L.messagesRetry) { model.retry(message) } }
        Divider()
        Button(L.messagesMenuDeleteMessage, role: .destructive) { model.deleteMessage(message.id) }
    }

    /// Red exclamation in a circle at the left of a failed bubble; a click opens the bubble menu.
    private var failedGlyph: some View {
        Menu { bubbleMenu } label: {
            Image(systemName: "exclamationmark.circle").font(.system(size: 16, weight: .regular)).foregroundStyle(Theme.red)
                .frame(width: 16, height: 16)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(L.messagesStatusFailed)
    }

    /// Time of the message, then the status of an outgoing one.
    private var meta: some View {
        HStack(spacing: 4) {
            Text(MessageFormat.timeOfDay(message.at)).monospacedDigit()
            if outgoing {
                switch message.state {
                case .sending:
                    Text("·")
                    ProgressView().controlSize(.mini).scaleEffect(0.55).frame(width: 9, height: 9)
                    Text(L.messagesStatusSending)
                case .failed:
                    let f = MessageFormat.failure(message)
                    Text("·")
                    Text(L.messagesStatusFailedReason(f.reason)).fontWeight(.medium).foregroundStyle(Theme.red)
                        .help(f.tooltip ?? "")
                    Text("·")
                    Button(L.messagesRetry) { model.retry(message) }
                        .buttonStyle(.plain).fontWeight(.medium).foregroundStyle(Theme.blue)
                case .sent:
                    if showsSent {
                        Text("·")
                        Text(L.messagesStatusSent).help(L.messagesStatusSentHelp)
                    }
                }
            }
        }
        .font(.system(size: 10.5)).foregroundStyle(Theme.label2).lineLimit(1)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }
}

/// Offers its one child at most `maxWidth` and takes the size the child chooses (unlike `frame(maxWidth:)`, which grows).
private struct CappedWidth: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = proposal.width.map { min($0, maxWidth) } ?? maxWidth
        return child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
