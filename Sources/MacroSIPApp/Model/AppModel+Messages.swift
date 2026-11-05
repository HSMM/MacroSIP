import SwiftUI
import AppKit
import MacroSIPCore

/// Text messages (SIP MESSAGE, SCREENS.md section 14): the conversations of the Messages tab, sending and retrying,
/// the engine's `.messageReceived` / `.messageStatus` events, the read state behind the tab and Dock badges, and the
/// notification and sound for a new message. The store is `MessageStore` (messages.json); the engine only carries text.
extension AppModel {
    // MARK: - Loading

    /// Reads the conversations (and the open one's messages) back from the store after any change. The store keeps the
    /// file in memory, so this does not touch the disk.
    func reloadMessages() {
        let last = messageStore.lastMessages()
        // Newest activity first: by the time of the last message (a retried message moves to the end, and so does the row).
        conversations = messageStore.conversations().sorted {
            (last[$0.id]?.at ?? $0.lastActivityAt) > (last[$1.id]?.at ?? $1.lastActivityAt)
        }
        conversationLast = last
        if case let .conversation(id) = messagesPage {
            if conversations.contains(where: { $0.id == id }) { setThread(messageStore.messages(in: id)) }
            else { messagesPage = .list; setThread([]) }
        } else if !messageThread.isEmpty {
            setThread([])
        }
    }

    /// The open conversation's messages and the rows built from them (once per change, not once per redraw).
    private func setThread(_ messages: [Message]) {
        guard messages != messageThread else { return }
        messageThread = messages
        threadRows = MessageFormat.thread(messages)
    }

    /// Messages of one conversation, oldest first.
    func messages(in conversation: UUID) -> [Message] { messageStore.messages(in: conversation) }

    /// Settings › General › Messages (opt-in, off by default): the tab, the Send Message items, incoming messages, notifications
    /// and the Dock badge all follow it.
    var messagesEnabled: Bool { settings.general.messagesEnabled }

    /// Unread incoming messages over all conversations: the tab badge and, with the unseen missed calls, the Dock badge.
    /// Nothing counts while messages are off.
    var messagesUnread: Int { messagesEnabled ? conversations.reduce(0) { $0 + $1.unread } : 0 }

    func conversation(_ id: UUID) -> Conversation? { conversations.first { $0.id == id } }

    /// The conversation with `address` (a number in any format, a URI or `user@host`) on this account: numbers meet by
    /// their digits, a host counts where it tells peers apart (`ConversationAddress`).
    func conversation(account: AccountID, address: String) -> Conversation? {
        let key = ConversationAddress(address, accountDomain: self.account(account)?.domain ?? "")
        guard !key.user.isEmpty else { return nil }
        return conversations.first { $0.matches(account: account, address: key) }
    }

    // MARK: - Names and accounts

    func contact(for conversation: Conversation) -> Contact? {
        if let id = conversation.contactID, let c = contacts.first(where: { $0.id == id }) { return c }
        return contact(forNumber: conversation.remoteNumber)
    }

    /// The contact's name; else the display name of the last incoming message (unless it only repeats the number);
    /// else the number.
    func name(for conversation: Conversation) -> String {
        if let c = contact(for: conversation) { return c.displayName }
        if !isWeak(conversation.remoteDisplayName, number: conversation.remoteNumber), let n = conversation.remoteDisplayName {
            return n
        }
        return directoryName(forNumber: conversation.remoteNumber) ?? conversation.shownNumber
    }

    /// The account of a conversation is gone, or switched off: nothing can be sent or called through it.
    func accountState(of conversation: Conversation) -> MessageAccountState {
        guard let a = account(conversation.accountID) else { return .removed }
        return a.enabled ? .ready : .off
    }

    /// Composer placeholder when the account cannot send (`nil` = the normal one).
    func composerPlaceholder(for conversation: Conversation) -> String {
        switch accountState(of: conversation) {
        case .ready: return L.messagesComposerPlaceholder
        case .off: return L.messagesComposerAccountOff(accountName(conversation.accountID))
        case .removed: return L.messagesComposerAccountRemoved
        }
    }

    // MARK: - Navigation

    /// A conversation or the new-message form is shown: the composer or the To field has the focus, not the number field.
    var messageFieldHasFocus: Bool { tab == .messages && messagesPage != .list }

    func showMessagesList() {
        messagesPage = .list
        setThread([])
        directory.owner = .numberField
        clearDirectoryResults()
    }

    func openConversation(_ id: UUID, focus: Bool = false) {
        guard messagesEnabled, conversation(id) != nil else { return }
        tab = .messages
        messagesPage = .conversation(id)
        setThread(messageStore.messages(in: id))
        directory.owner = .numberField
        updateMessageReadState()
        if focus { focusComposer &+= 1 }
    }

    /// The form of 14.3. `prefill` is the recipient (the number field's text, or a contact).
    func newMessage(to prefill: NewMessagePrefill? = nil) {
        guard messagesEnabled else { return }
        tab = .messages
        newMessagePrefill = prefill
        messagesPage = .new
        setThread([])
    }

    /// New Message button: the number field's text goes into To.
    func newMessageFromList() {
        let typed = dialText.trimmingCharacters(in: .whitespacesAndNewlines)
        newMessage(to: typed.isEmpty ? nil : NewMessagePrefill(number: typed, name: nil))
    }

    /// "Send Message" in the Contacts and Call Log menus: the conversation with this number on the outgoing account when
    /// it exists, otherwise the new-message form with the recipient filled in. `account` (a call-log entry's account)
    /// is used for this message only; the account row's choice for calls stays.
    func composeMessage(to number: String, name: String?, account explicit: AccountID? = nil) {
        let target = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard messagesEnabled, !target.isEmpty else { return }
        let chosen = explicit.flatMap { self.account($0) }.flatMap { $0.enabled ? $0 : nil } ?? effectiveAccount
        guard let acct = chosen else { showBanner(L.bannerNoAccount); return }
        let address = DialString.parse(target, account: acct)?.uri ?? target
        if let existing = conversation(account: acct.id, address: address) { openConversation(existing.id, focus: true) }
        else { newMessage(to: NewMessagePrefill(number: target, name: name, account: explicit.flatMap { $0 == acct.id ? $0 : nil })) }
    }

    func sendMessage(to contact: Contact) {
        guard let number = contact.defaultNumber?.value else { return }
        composeMessage(to: number, name: contact.displayName)
    }

    func sendMessage(to entry: CallLogEntry) {
        composeMessage(to: entry.remoteNumber, name: contact(for: entry)?.displayName ?? entry.remoteDisplayName,
                       account: self.account(entry.accountID) != nil ? entry.accountID : nil)
    }

    /// A click on a message notification: the window comes forward on the conversation, the cursor in the composer.
    func openConversationFromNotification(_ id: UUID) {
        showMainWindow()
        openConversation(id, focus: true)
    }

    // MARK: - Read state

    /// Whether the user can be reading the main window: it is key in the active app, not covered, and the screen is not locked
    /// (a demo check can pretend).
    var mainWindowIsKey: Bool {
        if let o = messagesWindowKeyOverride { return o }
        guard NSApp.isActive, !screenLocked, let w = mainWindow else { return false }
        return w.isKeyWindow && w.occlusionState.contains(.visible)
    }

    /// The conversation shown on the Messages tab in the key main window is read: its count and the badges drop and its
    /// notifications go.
    func updateMessageReadState() {
        guard tab == .messages, case let .conversation(id) = messagesPage, mainWindowIsKey,
              (conversation(id)?.unread ?? 0) > 0 else { return }
        markMessagesRead(id)
    }

    func markMessagesRead(_ id: UUID) {
        do { try messageStore.markRead(id) } catch { report(error) }
        reloadMessages()
        MessageNotifications.shared.remove(conversation: id)
    }

    /// The open conversation, when the user could be reading it right now.
    func isReading(_ id: UUID) -> Bool {
        tab == .messages && messagesPage == .conversation(id) && mainWindowIsKey
    }

    // MARK: - Sending

    /// Longest text that can be sent, in UTF-8 bytes (`Engine.maxMessageBytes`).
    var messageByteLimit: Int { Engine.maxMessageBytes }

    func canSend(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.utf8.count <= messageByteLimit
    }

    func isTooLong(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count > messageByteLimit
    }

    /// Stores the text as a message in `conversation` and sends it through the conversation's account.
    @discardableResult
    func send(text: String, in conversationID: UUID) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend(trimmed), let conv = conversation(conversationID),
              let acct = account(conv.accountID), acct.enabled else { return false }
        let message = Message(conversationID: conv.id, direction: .outgoing, text: trimmed, at: Date(), state: .sending)
        do { try messageStore.append(message) } catch { report(error); return false }
        messageDrafts[conv.id] = nil
        reloadMessages()
        transmit(message, in: conv, through: acct)
        return true
    }

    /// 14.3: the first message of a conversation with `rawAddress` through `account` (the account row's choice when nil).
    /// The conversation and the message are stored in one write; an address that already has a conversation sends into it.
    @discardableResult
    func sendNew(text: String, to rawAddress: String, name: String?, account: AccountID? = nil) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend(trimmed), let acct = account.flatMap({ self.account($0) }) ?? effectiveAccount, acct.enabled,
              let dial = DialString.parse(rawAddress, account: acct) else { return nil }
        let stored: (Conversation, Message)
        do {
            stored = try messageStore.conversation(account: acct.id, remoteNumber: dial.display, remoteURI: dial.uri, displayName: name,
                                                   accountDomain: acct.domain) {
                Message(conversationID: $0, direction: .outgoing, text: trimmed, at: Date(), state: .sending)
            }
        } catch { report(error); return nil }
        reloadMessages()
        transmit(stored.1, in: stored.0, through: acct)
        return stored.0.id
    }

    /// Hands the message to the engine. The status comes back as `.messageStatus` under a fresh id; a request that could
    /// not even be made fails here.
    private func transmit(_ message: Message, in conv: Conversation, through acct: AccountConfig) {
        let target = conv.remoteURI.isEmpty ? conv.remoteNumber : conv.remoteURI
        guard let dial = DialString.parse(target, account: acct) else {
            finish(message.id, .failed(code: 0, reason: "invalid address"))
            return
        }
        let id = MessageID()
        pendingSends[id] = message.id
        let text = message.text
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { _ = try await self.engine.sendMessage(text, to: dial, from: acct.id, id: id) }
            catch {
                if self.pendingSends.removeValue(forKey: id) != nil { self.finish(message.id, .failed(code: 0, reason: describe(error))) }
            }
        }
    }

    /// Retry: the same text through the same account, as a new message at the end of the conversation.
    func retry(_ message: Message) {
        guard message.state == .failed, let conv = conversation(message.conversationID),
              let acct = account(conv.accountID), acct.enabled else { return }
        let again = Message(conversationID: conv.id, direction: .outgoing, text: message.text, at: Date(), state: .sending)
        do { try messageStore.replace(message: message.id, with: again) } catch { report(error); return }
        reloadMessages()
        transmit(again, in: conv, through: acct)
    }

    /// The final outcome of a send: stored and shown.
    func finish(_ message: UUID, _ result: MessageSendResult) {
        do {
            try messageStore.update(message) { m in
                switch result {
                case .accepted:
                    m.state = .sent; m.failureCode = nil; m.failureReason = nil
                case let .failed(code, reason):
                    m.state = .failed; m.failureCode = code; m.failureReason = reason
                }
            }
        } catch { report(error) }
        reloadMessages()
    }

    func handleMessageStatus(_ id: MessageID, _ result: MessageSendResult) {
        guard let message = pendingSends.removeValue(forKey: id) else { return }
        finish(message, result)
        if case let .failed(code, reason) = result { AppLog.app.info("message not sent: \(code) \(reason)") }
    }

    // MARK: - Receiving

    func handleMessageReceived(_ incoming: IncomingMessage) {
        guard messagesEnabled else {
            let from = incoming.remote.number.isEmpty ? incoming.remote.uri : incoming.remote.number
            AppLog.app.info("messages: off, dropped a message from \(from)")
            return
        }
        guard account(incoming.accountID) != nil else {
            AppLog.app.info("message for an unknown account ignored")
            return
        }
        let remote = incoming.remote
        let number = remote.number.isEmpty ? remote.uri : remote.number
        let displayName = isWeak(remote.displayName, number: number) ? nil : remote.displayName
        let conv: Conversation
        do {
            conv = try messageStore.conversation(account: incoming.accountID, remoteNumber: number, remoteURI: remote.uri,
                                                 displayName: displayName, accountDomain: account(incoming.accountID)?.domain ?? "")
            try messageStore.append(Message(conversationID: conv.id, direction: .incoming, text: incoming.text,
                                            at: incoming.receivedAt, state: .sent))
        } catch { report(error); return }
        reloadMessages()
        let reading = isReading(conv.id)
        updateMessageReadState()
        guard !doNotDisturb else { return }          // stored and counted, but silent
        playMessageSound()
        if !reading, let stored = conversation(conv.id) {
            MessageNotifications.shared.post(text: incoming.text, from: name(for: stored), account: accountName(stored.accountID),
                                             conversation: stored.id)
        }
    }

    /// "New message" sound event: also for the open conversation, at most once every 2 seconds.
    func playMessageSound() {
        let now = Date()
        if let last = lastMessageSoundAt, now.timeIntervalSince(last) < 2 { return }
        lastMessageSoundAt = now
        playSound(.message)
    }

    // MARK: - Deleting

    /// Removes one message; the last one takes the conversation with it (the page goes back to the list).
    func deleteMessage(_ id: UUID) {
        guard let m = messageThread.first(where: { $0.id == id }) ?? messageStore.allMessages().first(where: { $0.id == id }) else { return }
        let conv = m.conversationID
        do {
            try messageStore.remove(message: id)
            if messageStore.messages(in: conv).isEmpty { try messageStore.remove(conversation: conv); forget(conversation: conv) }
        } catch { report(error) }
        reloadMessages()
    }

    func deleteConversation(_ id: UUID) {
        do { try messageStore.remove(conversation: id) } catch { report(error) }
        forget(conversation: id)
        reloadMessages()
    }

    private func forget(conversation id: UUID) {
        messageDrafts[id] = nil
        MessageNotifications.shared.remove(conversation: id)
        if messagesPage == .conversation(id) { messagesPage = .list }
    }

    // MARK: - Calling from a conversation

    /// Call through the conversation's own account.
    func call(_ conversation: Conversation) {
        guard accountState(of: conversation) == .ready else { return }
        // The URI the peer was last seen at: right for `sip:` users and for hosts other than the account's own.
        placeCall(to: conversation.remoteURI.isEmpty ? conversation.remoteNumber : conversation.remoteURI, account: conversation.accountID)
    }

    func addToContacts(_ conversation: Conversation) {
        ContactCardController.shared.show(
            ContactEditorRequest(contact: nil, prefillName: conversation.remoteDisplayName ?? "", prefillNumber: conversation.shownNumber),
            model: self)
    }
}

enum MessageAccountState { case ready, off, removed }
