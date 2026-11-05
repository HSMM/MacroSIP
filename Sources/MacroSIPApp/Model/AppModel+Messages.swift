import SwiftUI
import AppKit
import MacroSIPCore

/// Text messages (SIP MESSAGE, SCREENS.md section 14): the conversations of the Messages tab, sending and retrying,
/// the engine's `.messageReceived` / `.messageStatus` events, the read state behind the tab and Dock badges, and the
/// notification and sound for a new message. The store is `MessageStore` (messages.json); the engine only carries text.
extension AppModel {
    // MARK: - Loading

    /// Reads the conversations (and the open one's messages) back from the store after any change.
    func reloadMessages() {
        let all = messageStore.allMessages()
        var last: [UUID: Message] = [:]
        for m in all { last[m.conversationID] = m }
        // Newest activity first: by the time of the last message (a retried message moves to the end, and so does the row).
        conversations = messageStore.conversations().sorted {
            (last[$0.id]?.at ?? $0.lastActivityAt) > (last[$1.id]?.at ?? $1.lastActivityAt)
        }
        conversationLast = last
        if case let .conversation(id) = messagesPage {
            if conversations.contains(where: { $0.id == id }) { messageThread = all.filter { $0.conversationID == id } }
            else { messagesPage = .list; messageThread = [] }
        } else {
            messageThread = []
        }
    }

    /// Messages of one conversation, oldest first.
    func messages(in conversation: UUID) -> [Message] { messageStore.messages(in: conversation) }

    /// Unread incoming messages over all conversations: the tab badge and, with the unseen missed calls, the Dock badge.
    var messagesUnread: Int { conversations.reduce(0) { $0 + $1.unread } }

    func conversation(_ id: UUID) -> Conversation? { conversations.first { $0.id == id } }

    /// The conversation of this account and number (same number after `Contact.normalize`).
    func conversation(account: AccountID, number: String) -> Conversation? {
        let key = Contact.normalize(number)
        guard !key.isEmpty else { return nil }
        return conversations.first { $0.accountID == account && Contact.normalize($0.remoteNumber) == key }
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
        return directoryName(forNumber: conversation.remoteNumber) ?? conversation.remoteNumber
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
        messageThread = []
        directory.owner = .numberField
        clearDirectoryResults()
    }

    func openConversation(_ id: UUID, focus: Bool = false) {
        guard conversation(id) != nil else { return }
        tab = .messages
        messagesPage = .conversation(id)
        messageThread = messageStore.messages(in: id)
        directory.owner = .numberField
        updateMessageReadState()
        if focus { focusComposer &+= 1 }
    }

    /// The form of 14.3. `prefill` is the recipient (the number field's text, or a contact).
    func newMessage(to prefill: NewMessagePrefill? = nil) {
        tab = .messages
        newMessagePrefill = prefill
        messagesPage = .new
        messageThread = []
    }

    /// New Message button: the number field's text goes into To.
    func newMessageFromList() {
        let typed = dialText.trimmingCharacters(in: .whitespacesAndNewlines)
        newMessage(to: typed.isEmpty ? nil : NewMessagePrefill(number: typed, name: nil))
    }

    /// "Send Message" in the Contacts and Call Log menus: the conversation with this number on the outgoing account when
    /// it exists, otherwise the new-message form with the recipient filled in.
    func composeMessage(to number: String, name: String?, account explicit: AccountID? = nil) {
        let target = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        if let explicit, account(explicit)?.enabled == true { selectedAccountID = explicit }
        guard let acct = effectiveAccount else { showBanner(L.bannerNoAccount); return }
        let key = DialString.parse(target, account: acct)?.display ?? target
        if let existing = conversation(account: acct.id, number: key) { openConversation(existing.id, focus: true) }
        else { newMessage(to: NewMessagePrefill(number: target, name: name)) }
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

    /// Whether the main window counts as key for reading: really key in the active app (a demo check can pretend).
    var mainWindowIsKey: Bool {
        if let o = messagesWindowKeyOverride { return o }
        return NSApp.isActive && mainWindow?.isKeyWindow == true
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

    /// 14.3: the first message of a new conversation. The conversation is created with the message.
    @discardableResult
    func sendNew(text: String, to rawAddress: String, name: String?) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend(trimmed), let acct = effectiveAccount, let dial = DialString.parse(rawAddress, account: acct) else { return nil }
        let conv: Conversation
        if let existing = conversation(account: acct.id, number: dial.display) { conv = existing }
        else {
            do { conv = try messageStore.conversation(account: acct.id, remoteNumber: dial.display, remoteURI: dial.uri, displayName: name) }
            catch { report(error); return nil }
        }
        let message = Message(conversationID: conv.id, direction: .outgoing, text: trimmed, at: Date(), state: .sending)
        do { try messageStore.append(message) } catch { report(error); return nil }
        reloadMessages()
        transmit(message, in: conv, through: acct)
        return conv.id
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
        do {
            try messageStore.remove(message: message.id)
            try messageStore.append(again)
        } catch { report(error); return }
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
        guard account(incoming.accountID) != nil else {
            AppLog.app.info("message for an unknown account ignored")
            return
        }
        let remote = incoming.remote
        let number = remote.number.isEmpty ? remote.uri : remote.number
        let displayName = isWeak(remote.displayName, number: number) ? nil : remote.displayName
        let conv: Conversation
        do {
            conv = try messageStore.conversation(account: incoming.accountID, remoteNumber: number, remoteURI: remote.uri, displayName: displayName)
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
        placeCall(to: conversation.remoteNumber, account: conversation.accountID)
    }

    func addToContacts(_ conversation: Conversation) {
        ContactCardController.shared.show(
            ContactEditorRequest(contact: nil, prefillName: conversation.remoteDisplayName ?? "", prefillNumber: conversation.remoteNumber),
            model: self)
    }
}

enum MessageAccountState { case ready, off, removed }
