import Foundation
import MacroSIPCore
#if DEBUG
import AppKit

/// Demo states of screen 14 (Messages):
///   messages                 the conversation list: two unread, one not sent (README `messages-list`)
///   messages-conversation    Andrei Kavaliou, the last message "Sent", a reply typed (README `messages-conversation`)
///   messages-failed          Volha Marozava: the last message failed with 404 Not Found, Retry
///   messages-new             the new-message form with "Ka" in To: and the suggestion list (contacts, then the directory)
///   messages-empty           no conversations
///   messages-many            120 unread messages and 120 missed calls: both tab badges at their widest (Russian labels still fit)
///   messages-selftest        only the message checks of `selftest` (send, receive, retry, unread, notifications, sound)
extension DemoState {
    static func isMessagesState(_ state: String) -> Bool { state.hasPrefix("messages") }

    /// The six conversations of the mockup (14.1), oldest activity first because a new conversation starts "now".
    static func seedMessages(_ store: MessageStore, state: String) {
        guard state == "selftest" || (isMessagesState(state) && state != "messages-empty" && state != "messages-many") else { return }
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        /// A time today, `minutes` ago (not before 00:01).
        func ago(_ minutes: Double) -> Date { max(now.addingTimeInterval(-minutes * 60), startOfToday.addingTimeInterval(60)) }
        func day(_ offset: Int, _ hour: Int, _ minute: Int) -> Date {
            let d = cal.date(byAdding: .day, value: offset, to: startOfToday) ?? startOfToday
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: d) ?? d
        }
        func conversation(_ account: AccountID, _ number: String, uri: String, name: String? = nil) -> Conversation? {
            try? store.conversation(account: account, remoteNumber: number, remoteURI: uri, displayName: name)
        }
        func add(_ c: Conversation?, _ direction: MessageDirection, _ text: String, _ at: Date,
                 failed: (Int, String)? = nil, read: Bool = true) {
            guard let c else { return }
            var m = Message(conversationID: c.id, direction: direction, text: text, at: at, state: .sent)
            if let failed { m.state = .failed; m.failureCode = failed.0; m.failureReason = failed.1 }
            _ = try? store.append(m)
            if read, direction == .incoming { try? store.markRead(c.id) }
        }
        let ru = Locale.preferredLanguages.first?.hasPrefix("ru") == true
        func pick(_ latin: String, _ cyrillic: String) -> String { ru ? cyrillic : latin }

        let katsiaryna = conversation(officeID, "elena", uri: "sip:elena@pbx.example.com")
        add(katsiaryna, .incoming, pick("Room 4 is free on Thursday.", "Переговорная 4 свободна в четверг."), day(-30, 10, 12))
        let dzmitry = conversation(homeID, "+79125550123", uri: "sip:+79125550123@sip.provider.net")
        add(dzmitry, .outgoing, pick("Sent you the invoice.", "Отправил вам счёт."), day(-3, 16, 5))
        add(dzmitry, .incoming, pick("Thanks, the invoice is paid.", "Спасибо, счёт оплачен."), day(-3, 16, 20))
        let volha = conversation(officeID, "+375 44 555-77-10", uri: "sip:+375445557710@pbx.example.com", name: DemoPeople.volha)
        add(volha, .incoming, pick("Are we still meeting tomorrow?", "Мы завтра встречаемся?"), day(-1, 18, 2))
        add(volha, .outgoing, pick("Yes.", "Да."), day(-1, 18, 4))
        add(volha, .outgoing, pick("See you at 10 at the entrance.", "Встречаемся в 10 у входа."), day(-1, 18, 8), failed: (404, "Not Found"))
        let andrei = conversation(officeID, "101", uri: "sip:101@pbx.example.com")
        add(andrei, .incoming, pick("Did you get the contract?", "Ты получил договор?"), day(-1, 17, 30))
        add(andrei, .outgoing, pick("Not yet. I'll check in the morning.", "Пока нет. Утром проверю."), day(-1, 17, 32))
        add(andrei, .incoming, pick("It's in the shared folder now.", "Он уже в общей папке."), ago(190))
        add(andrei, .outgoing, pick("Got it, thanks!", "Получил, спасибо!"), ago(180))
        let parcel = conversation(homeID, "+375 29 123-45-67", uri: "sip:+375291234567@sip.provider.net")
        add(parcel, .incoming, pick("Parcel 2214 is ready for pickup until 12 Nov.", "Посылка 2214 ждёт вас в пункте выдачи до 12 ноября."),
            ago(100), read: false)
        let alesia = conversation(officeID, "+375295550142", uri: "sip:+375295550142@pbx.example.com")
        add(alesia, .incoming, pick("Can you call me after the meeting?", "Перезвони, пожалуйста, после совещания."), ago(12), read: false)
    }

    @MainActor
    static func runMessages(_ model: AppModel, state: String) async {
        try? await Task.sleep(for: .seconds(1.2))
        if state != "messages-selftest", state != "messages-many" { model.markLogSeen() }       // the Call Log badge is not part of these frames
        func open(_ name: String) {
            guard let c = model.conversations.first(where: { model.name(for: $0) == name }) else { return }
            model.openConversation(c.id)
        }
        switch state {
        case "messages", "messages-empty":
            model.tab = .messages
        case "messages-conversation":
            model.tab = .messages
            if let c = model.conversations.first(where: { model.name(for: $0) == DemoPeople.andrei }) {
                model.messageDrafts[c.id] = Locale.preferredLanguages.first?.hasPrefix("ru") == true
                    ? "Отправлю замечания к трём" : "I'll send my comments by 3"
                model.openConversation(c.id)
            }
        case "messages-failed":
            model.tab = .messages
            open(DemoPeople.volha)
        case "messages-new":
            let ru = Locale.preferredLanguages.first?.hasPrefix("ru") == true
            model.newMessage(to: NewMessagePrefill(number: ru ? "Ка" : "Ka", name: nil))
            try? await Task.sleep(for: .seconds(Double(MockDirectory.googleDelayMilliseconds) / 1000 + 1))
        case "messages-many":
            for i in 0..<120 {
                let incoming = IncomingMessage(accountID: officeID, remote: RemoteParty(displayName: nil, uri: "sip:777@pbx", number: "777"),
                                               text: "#\(i)", receivedAt: Date())
                model.handleMessageReceived(incoming)
            }
            for i in 0..<120 {
                _ = try? model.callLogStore.append(CallLogEntry(direction: .missed, remoteNumber: "100", remoteDisplayName: nil, accountID: officeID,
                                                                 startedAt: Date().addingTimeInterval(-Double(i) - 1), duration: 0))
            }
            model.reloadCallLog()
            model.tab = .messages
        case "messages-selftest":
            await runMessagesSelftest(model)
        default: break
        }
    }

    @MainActor
    static func runMessagesSelftest(_ model: AppModel) async {
        var out: [String] = []
        var failures = 0
        await messagesChecks(model) { name, ok, detail in
            if !ok { failures += 1 }
            out.append("\(ok ? "PASS" : "FAIL") \(name) \(ok ? "" : detail)")
        }
        let text = out.joined(separator: "\n") + "\nfailures=\(failures)\n"
        if let prefix = model.launch.snapshotPrefix { try? text.write(toFile: "\(prefix)-selftest.txt", atomically: true, encoding: .utf8) }
        print(text)
        quitLater()
    }

    /// Sending, receiving, retrying, the read state behind the badges, notifications and the sound, through the mock engine.
    @MainActor
    static func messagesChecks(_ model: AppModel, report: (String, Bool, String) -> Void) async {
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") { report("messages: " + name, ok, ok ? "" : detail()) }
        func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        func until(_ seconds: Double, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        }
        guard let mock = model.engine as? MockEngine else { check("mock engine", false); return }
        let notifications = MessageNotifications.shared
        let savedSound = model.settings.audio.soundEvents
        let savedDND = model.settings.general.doNotDisturb

        // The seeded list
        await until(3) { model.engineReady && model.registration[officeID] != nil }
        model.messagesWindowKeyOverride = false
        model.selectedAccountID = nil
        model.tab = .messages
        model.showMessagesList()
        model.updateSettings { $0.general.doNotDisturb = false; $0.audio.soundEvents.message = false }
        check("message sound is off by default", !AppSettings().audio.soundEvents.message)
        check("six conversations, newest activity first",
              model.conversations.count == 6 && model.name(for: model.conversations[0]) == DemoPeople.alesia,
              model.conversations.map { model.name(for: $0) }.joined(separator: ", "))
        check("two unread messages in the badge", model.messagesUnread == 2, "\(model.messagesUnread)")
        let number = model.conversations.first { $0.remoteNumber == "+375 29 123-45-67" }
        check("a number without a contact is named by its number", number.map { model.name(for: $0) } == "+375 29 123-45-67")
        let andrei = model.conversations.first { model.name(for: $0) == DemoPeople.andrei }
        check("a conversation with a contact number shows the contact", andrei.map { model.contact(for: $0) != nil } == true)
        let volha = model.conversations.first { model.name(for: $0) == DemoPeople.volha }
        check("a stranger with a display name shows it, and the last message is not sent",
              volha != nil && volha.flatMap { model.conversationLast[$0.id] }?.state == .failed)
        check("the previews are the last message of each conversation",
              andrei.flatMap { model.conversationLast[$0.id] }.map(MessageFormat.preview) == L.messagesRowYou(model.conversationLast[andrei!.id]!.text))

        // Receiving: unread, notification, sound, Do Not Disturb
        notifications.clearPosted()
        await mock.clearPlayedSounds()
        await mock.simulateIncomingMessage(account: officeID, from: "101", text: "Call me")
        await until(2) { (andrei.flatMap { model.conversation($0.id) }?.unread ?? 0) == 1 }
        check("an incoming message counts as unread", andrei.flatMap { model.conversation($0.id) }?.unread == 1 && model.messagesUnread == 3,
              "\(model.messagesUnread)")
        check("the conversation moves to the top", model.conversations.first?.id == andrei?.id)
        check("one notification: sender, account, text, conversation",
              notifications.posted.count == 1 && notifications.posted[0] == .init(
                  conversation: andrei?.id ?? UUID(), title: DemoPeople.andrei, subtitle: "Office", body: "Call me"),
              "\(notifications.posted)")
        check("no sound while the setting is off", await mock.playedSounds.isEmpty)
        model.updateSettings { $0.audio.soundEvents.message = true }
        model.lastMessageSoundAt = nil
        await mock.simulateIncomingMessage(account: officeID, from: "101", text: "Hello?")
        await until(2) { model.messagesUnread == 4 }
        await wait(0.3)
        var sounds = await mock.playedSounds
        check("the message sound plays once the setting is on", sounds == [.message], "\(sounds)")
        await mock.simulateIncomingMessage(account: officeID, from: "101", text: "Hello??")
        await until(2) { model.messagesUnread == 5 }
        await wait(0.3)
        sounds = await mock.playedSounds
        check("the sound plays at most once every 2 seconds", sounds.count == 1, "\(sounds)")
        model.updateSettings { $0.general.doNotDisturb = true }
        notifications.clearPosted()
        model.lastMessageSoundAt = nil
        await mock.clearPlayedSounds()
        await mock.simulateIncomingMessage(account: officeID, from: "101", text: "Quiet one")
        await until(2) { model.messagesUnread == 6 }
        await wait(0.3)
        sounds = await mock.playedSounds
        check("Do Not Disturb: stored and counted, no notification, no sound",
              model.messagesUnread == 6 && notifications.posted.isEmpty && sounds.isEmpty, "\(model.messagesUnread) \(notifications.posted.count) \(sounds)")
        model.updateSettings { $0.general.doNotDisturb = false }

        // The read state
        if let andrei {
            model.openConversation(andrei.id)
            check("a conversation shown while the window is not key stays unread", model.conversation(andrei.id)?.unread == 4)
            model.messagesWindowKeyOverride = true
            model.updateMessageReadState()
            check("it is read when the window becomes key", model.conversation(andrei.id)?.unread == 0 && model.messagesUnread == 2, "\(model.messagesUnread)")
            notifications.clearPosted()
            model.lastMessageSoundAt = nil
            await mock.clearPlayedSounds()
            await mock.simulateIncomingMessage(account: officeID, from: "101", text: "Are you there?")
            await until(2) { model.messageThread.last?.text == "Are you there?" }
            await wait(0.3)
            sounds = await mock.playedSounds
            check("a message for the open conversation is read at once: no notification, the sound still plays",
                  model.conversation(andrei.id)?.unread == 0 && notifications.posted.isEmpty && sounds == [.message],
                  "\(String(describing: model.conversation(andrei.id)?.unread)) \(notifications.posted.count) \(sounds)")
            check("the open thread shows it last", model.messageThread.last?.text == "Are you there?" && model.messageThread.last?.direction == .incoming)
            model.messagesWindowKeyOverride = false
            await mock.simulateIncomingMessage(account: officeID, from: "101", text: "Hello again")
            await until(2) { model.conversation(andrei.id)?.unread == 1 }
            check("a message for the open conversation in a window that is not key stays unread and is notified",
                  model.conversation(andrei.id)?.unread == 1 && notifications.posted.count == 1)
            model.tab = .callLog
            model.messagesWindowKeyOverride = true
            model.updateMessageReadState()
            check("another tab does not read the conversation", model.conversation(andrei.id)?.unread == 1)
            model.tab = .messages
            model.updateMessageReadState()
            check("back on the Messages tab it is read", model.conversation(andrei.id)?.unread == 0)
            check("the page is remembered across tabs", model.messagesPage == .conversation(andrei.id))
        }
        model.messagesWindowKeyOverride = false
        model.showMessagesList()
        model.markMessagesRead(model.conversations.first { $0.unread > 0 }?.id ?? UUID())

        // Sending
        if let andrei {
            model.openConversation(andrei.id)
            let before = model.messageThread.count
            check("an empty text is not sent", !model.send(text: "  \n ", in: andrei.id) && model.messageThread.count == before)
            let tooLong = String(repeating: "é", count: model.messageByteLimit / 2 + 1)
            check("over the byte limit is refused", model.isTooLong(tooLong) && !model.canSend(tooLong) && !model.send(text: tooLong, in: andrei.id))
            check("the limit is the engine's", model.messageByteLimit == Engine.maxMessageBytes && model.canSend(String(repeating: "é", count: model.messageByteLimit / 2)))
            check("a text is sent trimmed", model.send(text: "  On my way \n", in: andrei.id))
            check("the message shows Sending… at once", model.messageThread.last?.text == "On my way" && model.messageThread.last?.state == .sending)
            await until(2) { model.messageThread.last?.state == .sent }
            check("accepted by the engine: Sent", model.messageThread.last?.state == .sent)
            let sent = await mock.sentMessages.last
            check("the engine got the text for the conversation's account", sent?.text == "On my way" && sent?.user == "101" && sent?.account == officeID, "\(String(describing: sent))")
            let rows = MessageFormat.thread(model.messageThread)
            check("Sent only under the last outgoing message", rows.filter(\.showsSent).count == 1 && rows.last?.showsSent == true)
        }

        // Failures and Retry
        model.selectedAccountID = officeID
        func failure(_ to: String) async -> Message? {
            guard let id = model.sendNew(text: "to \(to)", to: to, name: nil) else { return nil }
            await until(3) { model.messages(in: id).last?.state == .failed }
            return model.messages(in: id).last
        }
        let notFound = await failure("404")
        check("404: Not sent · 404 Not Found", notFound.map { MessageFormat.failure($0).reason } == "404 Not Found", "\(String(describing: notFound))")
        let timedOut = await failure("timeout@pbx.example.com")
        check("no answer: 408 Request Timeout", timedOut.map { MessageFormat.failure($0).reason } == "408 Request Timeout")
        let local = await failure("offline@pbx.example.com")
        check("a local failure: No connection, the engine's text is the tooltip",
              local.map { MessageFormat.failure($0) }.map { $0.reason == L.messagesErrorLocal && $0.tooltip == "Network is unreachable" } == true)
        if let notFound {
            let conv = notFound.conversationID
            model.openConversation(conv)
            model.retry(notFound)
            check("Retry: the same text, sending again, at the end, one message", model.messageThread.count == 1 && model.messageThread[0].state == .sending
                  && model.messageThread[0].text == notFound.text && model.messageThread[0].id != notFound.id)
            await until(3) { model.messageThread.last?.state == .failed }
            check("Retry fails again the same way", model.messageThread.last.map { MessageFormat.failure($0).reason } == "404 Not Found")
            model.deleteMessage(model.messageThread[0].id)
            check("deleting the last message removes the conversation and returns to the list",
                  model.conversation(conv) == nil && model.messagesPage == .list)
        }
        if let timedOut {
            model.deleteConversation(timedOut.conversationID)
            check("Delete Conversation removes it and its messages", model.conversation(timedOut.conversationID) == nil
                  && model.messages(in: timedOut.conversationID).isEmpty)
        }
        if let local { model.deleteConversation(local.conversationID) }

        // Interrupted sends, status of unknown messages, accounts
        if let andrei {
            let stuck = Message(conversationID: andrei.id, direction: .outgoing, text: "stuck", at: Date(), state: .sending)
            _ = try? model.messageStore.append(stuck)
            try? model.messageStore.failInterruptedSends()
            model.reloadMessages()
            let after = model.messages(in: andrei.id).first { $0.id == stuck.id }
            check("a send still waiting at launch becomes Not sent · Interrupted",
                  after.map { MessageFormat.failure($0).reason } == L.messagesErrorInterrupted && after?.state == .failed)
            let count = model.messages(in: andrei.id).count
            model.handleMessageStatus(MessageID(), .accepted(code: 200))
            check("a status nobody waits for changes nothing", model.messages(in: andrei.id).count == count)
            try? model.messageStore.remove(message: stuck.id)
            model.reloadMessages()
        }
        let ghost = try? model.messageStore.conversation(account: AccountID(), remoteNumber: "777", remoteURI: "sip:777@gone.example.org", displayName: nil)
        model.reloadMessages()
        check("a conversation whose account was removed cannot send or call", ghost.map { model.accountState(of: $0) == .removed } == true
              && ghost.map { !model.send(text: "x", in: $0.id) } == true
              && ghost.map { model.composerPlaceholder(for: $0) == L.messagesComposerAccountRemoved } == true)
        if let ghost { model.deleteConversation(ghost.id) }
        if let andrei {
            model.setAccountEnabled(officeID, false)
            await model.waitForAccountSync()
            check("a switched-off account disables the composer and Call", model.accountState(of: andrei) == .off
                  && model.composerPlaceholder(for: andrei) == L.messagesComposerAccountOff("Office") && !model.send(text: "x", in: andrei.id))
            model.setAccountEnabled(officeID, true)
            await model.waitForAccountSync()
        }

        // Entry points
        if let andrei {
            model.showMessagesList()
            model.selectedAccountID = officeID
            model.composeMessage(to: "101", name: DemoPeople.andrei)
            check("Send Message opens the existing conversation", model.messagesPage == .conversation(andrei.id) && model.tab == .messages)
            model.composeMessage(to: "888", name: "Nobody")
            check("Send Message without a conversation opens the form with the recipient",
                  model.messagesPage == .new && model.newMessagePrefill == NewMessagePrefill(number: "888", name: "Nobody"))
            model.newMessagePrefill = nil
            model.dialText = "555"
            model.newMessageFromList()
            check("New Message copies the number field", model.newMessagePrefill == NewMessagePrefill(number: "555", name: nil))
            model.newMessagePrefill = nil
            model.dialText = ""
        }
        model.showMessagesList()
        check("an address matches a conversation of the same number and account",
              model.conversation(account: officeID, number: "+375 (29) 555-01-42") != nil && model.conversation(account: homeID, number: "101") == nil)

        // Formatting
        let cal = Calendar(identifier: .gregorian)
        let noon = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 12))!
        func at(_ d: Int, _ h: Int, _ m: Int, _ s: Int = 0) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m, second: s))!
        }
        let conv = UUID()
        func msg(_ dir: MessageDirection, _ date: Date, _ state: MessageState = .sent) -> Message {
            Message(conversationID: conv, direction: dir, text: "x", at: date, state: state)
        }
        let a = msg(.incoming, at(4, 23, 59)), b = msg(.incoming, at(5, 0, 1)), c = msg(.incoming, at(5, 0, 2))
        let d = msg(.outgoing, at(5, 9, 0)), e = msg(.outgoing, at(5, 9, 1)), f = msg(.outgoing, at(5, 9, 5), .sending)
        let g = msg(.outgoing, at(5, 9, 6), .failed)
        let rows = MessageFormat.thread([a, b, c, d, e, f, g], now: noon, calendar: cal)
        func row(_ m: Message) -> MessageFormat.Row? { rows.first { $0.id == m.id.uuidString } }
        check("day separators before the first message of each day", rows.filter { if case .day = $0.kind { return true } else { return false } }.count == 2)
        check("consecutive messages less than 2 minutes apart form a group: time under the last only",
              row(b)?.showsMeta == false && row(c)?.showsMeta == true && row(d)?.showsMeta == false && row(e)?.showsMeta == true)
        check("Sending… and Not sent are shown under every such message", row(f)?.showsMeta == true && row(g)?.showsMeta == true)
        check("2 pt inside a group, 8 pt between groups, none under a day separator",
              row(a)?.gap == 0 && row(c)?.gap == 2 && row(d)?.gap == 8 && row(e)?.gap == 2 && row(f)?.gap == 8 && row(b)?.gap == 0)
        check("a day boundary breaks a group", row(b)?.gap == 0 && row(a)?.showsMeta == true)
        check("Sent is never shown when the last outgoing message is not accepted", rows.allSatisfy { !$0.showsSent })
        check("row time: today is a time", MessageFormat.rowTime(at(5, 9, 0), now: noon, calendar: cal) == at(5, 9, 0).formatted(date: .omitted, time: .shortened))
        check("row time: yesterday", MessageFormat.rowTime(at(4, 9, 0), now: noon, calendar: cal) == L.messagesDayYesterday)
        check("row time: within 6 days is the weekday", MessageFormat.rowTime(at(2, 9, 0), now: noon, calendar: cal) == at(2, 9, 0).formatted(.dateTime.weekday(.abbreviated)))
        let oct = cal.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 10))!
        let old = cal.date(from: DateComponents(year: 2025, month: 10, day: 6, hour: 10))!
        check("row time: older is the date, with the year when not this year",
              MessageFormat.rowTime(oct, now: noon, calendar: cal) == oct.formatted(.dateTime.day().month(.abbreviated))
              && MessageFormat.rowTime(old, now: noon, calendar: cal) == old.formatted(.dateTime.day().month(.abbreviated).year()))
        check("day separator: Today, Yesterday, then the date", MessageFormat.daySeparator(at(5, 1, 0), now: noon, calendar: cal) == L.messagesDayToday
              && MessageFormat.daySeparator(at(4, 1, 0), now: noon, calendar: cal) == L.messagesDayYesterday
              && MessageFormat.daySeparator(at(1, 1, 0), now: noon, calendar: cal) == at(1, 1, 0).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
        var multi = msg(.outgoing, noon)
        multi.text = "line one\nline two"
        check("a preview is one line", MessageFormat.preview(multi) == L.messagesRowYou("line one line two"))

        // Put things back
        model.messagesWindowKeyOverride = nil
        model.updateSettings { $0.audio.soundEvents = savedSound; $0.general.doNotDisturb = savedDND }
        model.tab = .dialpad
        notifications.clearPosted()
    }
}
#endif
