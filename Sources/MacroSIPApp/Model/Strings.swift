import Foundation
import MacroSIPCore

// All user-visible strings. Keys follow docs/design/SCREENS.md "Strings"; a String Catalog
// can be added later without touching the views (the literals below are what Xcode extracts).

enum L {
    // MARK: common and main window
    static var mainTitle: String { String(localized: "main.title", defaultValue: "MacroSIP") }
    static var tabsDialpad: String { String(localized: "tabs.dialpad", defaultValue: "Dialpad") }
    static var tabsContacts: String { String(localized: "tabs.contacts", defaultValue: "Contacts") }
    static var tabsCallLog: String { String(localized: "tabs.callLog", defaultValue: "Call Log") }
    static var numberPlaceholder: String { String(localized: "main.numberField.placeholder", defaultValue: "Name or number") }
    static var accountPickerHelp: String { String(localized: "main.accountPicker.help", defaultValue: "Outgoing account") }
    static var accountPopupHeader: String { String(localized: "account.popup.header", defaultValue: "Accounts") }
    static var accountPopupSettings: String { String(localized: "account.popup.settings", defaultValue: "Account Settings…") }
    static var accountPopupNone: String { String(localized: "account.popup.none", defaultValue: "No account") }
    static func accountPopupFailed(_ reason: String, _ address: String) -> String {
        String(localized: "account.popup.failed", defaultValue: "\(reason) · \(address)")
    }
    static var statusNoneEnabled: String { String(localized: "status.noneEnabled", defaultValue: "All accounts off") }
    static var statusNoAccounts: String { String(localized: "status.noAccounts", defaultValue: "No accounts") }
    static func statusAccountFailed(_ name: String, _ reason: String) -> String {
        String(localized: "status.account.failed", defaultValue: "\(name): \(reason)")
    }
    static var statusRegistering: String { String(localized: "accounts.status.registering", defaultValue: "Registering…") }
    static func statusSummary(_ ok: Int, _ total: Int) -> String {
        String(localized: "status.summary", defaultValue: "\(ok)/\(total) registered")
    }
    static var menuSettings: String { String(localized: "menu.settings", defaultValue: "Settings…") }
    static func menuShowApp(_ name: String) -> String { String(localized: "menu.showApp", defaultValue: "Show \(name)") }
    static func menuQuitApp(_ name: String) -> String { String(localized: "menu.quitApp", defaultValue: "Quit \(name)") }
    static var commonCancel: String { String(localized: "common.cancel", defaultValue: "Cancel") }
    static var commonSave: String { String(localized: "common.save", defaultValue: "Save") }
    static var commonDelete: String { String(localized: "common.delete", defaultValue: "Delete") }
    static var commonDone: String { String(localized: "common.done", defaultValue: "Done") }

    // MARK: dialpad
    static var dialpadCallHelp: String { String(localized: "dialpad.call.help", defaultValue: "Call") }
    static var dialpadDeleteHelp: String { String(localized: "dialpad.delete.help", defaultValue: "Delete last digit") }
    static var dialpadHint: String { String(localized: "dialpad.hint", defaultValue: "Return calls · empty field + Call redials") }
    static func keyLetters(_ digit: Character) -> String {
        switch digit {
        case "2": return String(localized: "dialpad.key.letters.2", defaultValue: "ABC")
        case "3": return String(localized: "dialpad.key.letters.3", defaultValue: "DEF")
        case "4": return String(localized: "dialpad.key.letters.4", defaultValue: "GHI")
        case "5": return String(localized: "dialpad.key.letters.5", defaultValue: "JKL")
        case "6": return String(localized: "dialpad.key.letters.6", defaultValue: "MNO")
        case "7": return String(localized: "dialpad.key.letters.7", defaultValue: "PQRS")
        case "8": return String(localized: "dialpad.key.letters.8", defaultValue: "TUV")
        case "9": return String(localized: "dialpad.key.letters.9", defaultValue: "WXYZ")
        case "0": return String(localized: "dialpad.key.letters.0", defaultValue: "+")
        default: return ""
        }
    }

    // MARK: contacts
    static var contactsSearch: String { String(localized: "contacts.search.placeholder", defaultValue: "Search") }
    static func contactsCount(_ n: Int) -> String {
        n == 1 ? String(localized: "contacts.count.one", defaultValue: "1 contact")
               : String(localized: "contacts.count", defaultValue: "\(n) contacts")
    }
    static var contactsAddHelp: String { String(localized: "contacts.add.help", defaultValue: "Add contact") }
    static var contactsDeleteHelp: String { String(localized: "contacts.delete.help", defaultValue: "Delete contact") }
    static var contactsEditHelp: String { String(localized: "contacts.edit.help", defaultValue: "Edit contact") }
    static var contactsMenuCall: String { String(localized: "contacts.menu.call", defaultValue: "Call") }
    static var contactsMenuCallFrom: String { String(localized: "contacts.menu.callFrom", defaultValue: "Call from") }
    static var contactsMenuCopy: String { String(localized: "contacts.menu.copyNumber", defaultValue: "Copy Number") }
    static var contactsMenuEdit: String { String(localized: "contacts.menu.edit", defaultValue: "Edit…") }
    static var contactsMenuDelete: String { String(localized: "contacts.menu.delete", defaultValue: "Delete") }
    static func contactsDeleteConfirm(_ name: String) -> String {
        String(localized: "contacts.delete.confirm", defaultValue: "Delete \(name)?")
    }
    static var contactEditTitle: String { String(localized: "contact.edit.title", defaultValue: "Edit Contact") }
    static var contactNewTitle: String { String(localized: "contact.new.title", defaultValue: "New Contact") }
    static var contactName: String { String(localized: "contact.field.name", defaultValue: "Name") }
    static var contactNumber: String { String(localized: "contact.field.number", defaultValue: "Number") }
    static var contactAccount: String { String(localized: "contact.field.account", defaultValue: "Account") }
    static var contactAccountAny: String { String(localized: "contact.account.any", defaultValue: "Any (use default)") }
    static var contactsEmptyTitle: String { String(localized: "contacts.empty.title", defaultValue: "No contacts yet") }
    static var contactsEmptyBody: String { String(localized: "contacts.empty.body", defaultValue: "Add a contact to call it in one click.") }
    static var contactsNoResults: String { String(localized: "contacts.search.noResults", defaultValue: "No matching contacts") }

    // MARK: call log
    static var logAll: String { String(localized: "calllog.filter.all", defaultValue: "All") }
    static var logMissed: String { String(localized: "calllog.filter.missed", defaultValue: "Missed") }
    static var logClear: String { String(localized: "calllog.clear", defaultValue: "Clear…") }
    static var logToday: String { String(localized: "calllog.section.today", defaultValue: "Today") }
    static var logYesterday: String { String(localized: "calllog.section.yesterday", defaultValue: "Yesterday") }
    static var logRowMissed: String { String(localized: "calllog.row.missed", defaultValue: "missed") }
    static var logUnknown: String { String(localized: "calllog.row.unknown", defaultValue: "Unknown") }
    static var logMenuCall: String { String(localized: "calllog.menu.call", defaultValue: "Call") }
    static var logMenuCallFrom: String { String(localized: "calllog.menu.callFrom", defaultValue: "Call from") }
    static var logMenuAddContact: String { String(localized: "calllog.menu.addContact", defaultValue: "Add to Contacts") }
    static var logMenuCopy: String { String(localized: "calllog.menu.copyNumber", defaultValue: "Copy Number") }
    static var logMenuDelete: String { String(localized: "calllog.menu.delete", defaultValue: "Delete Entry") }
    static var logClearTitle: String { String(localized: "calllog.clear.title", defaultValue: "Clear the call log?") }
    static func logClearBody(_ n: Int) -> String { String(localized: "calllog.clear.body", defaultValue: "All \(n) entries are removed.") }
    static var logClearConfirm: String { String(localized: "calllog.clear.confirm", defaultValue: "Clear") }
    static var logEmptyTitle: String { String(localized: "calllog.empty.title", defaultValue: "No calls yet") }
    static var logEmptyBody: String { String(localized: "calllog.empty.body", defaultValue: "Calls you make and receive appear here.") }
    static var logEmptyMissed: String { String(localized: "calllog.empty.missed", defaultValue: "No missed calls") }

    // MARK: active call
    static var callConnected: String { String(localized: "call.state.connected", defaultValue: "Connected") }
    static var callCalling: String { String(localized: "call.state.outgoing", defaultValue: "Calling…") }
    static var callRinging: String { String(localized: "call.state.early", defaultValue: "Ringing…") }
    static var callRingingIn: String { String(localized: "call.state.ringing", defaultValue: "Ringing") }
    static var callHeld: String { String(localized: "call.state.held", defaultValue: "On hold") }
    static func callVia(_ account: String) -> String { String(localized: "call.via", defaultValue: "via \(account)") }
    static var callSRTP: String { String(localized: "call.srtp.label", defaultValue: "SRTP") }
    static var callSRTPHelp: String { String(localized: "call.srtp.help", defaultValue: "Media encrypted with SRTP") }
    static var callMute: String { String(localized: "call.mute", defaultValue: "Mute") }
    static var callHold: String { String(localized: "call.hold", defaultValue: "Hold") }
    static var callResume: String { String(localized: "calls.resume", defaultValue: "Resume") }
    static var callTransfer: String { String(localized: "call.transfer", defaultValue: "Transfer") }
    static var callKeypad: String { String(localized: "call.keypad", defaultValue: "Keypad") }
    static var callEnd: String { String(localized: "call.end", defaultValue: "End Call") }
    static func callEndWith(_ name: String) -> String { String(localized: "call.endWith", defaultValue: "End Call with \(name)") }
    static var keypadBack: String { String(localized: "keypad.back", defaultValue: "Back to call") }
    static func keypadWho(_ name: String, _ time: String) -> String { String(localized: "keypad.who", defaultValue: "\(name) · \(time)") }
    static var callbarHelp: String { String(localized: "callbar.help", defaultValue: "Click to return to the call") }
    static var callbarMuted: String { String(localized: "callbar.muted.help", defaultValue: "Muted") }
    static func callbarMoreHeld(_ n: Int) -> String { String(localized: "callbar.moreHeld", defaultValue: "+\(n) on hold") }
    static var callbarIncoming: String { String(localized: "callbar.incoming", defaultValue: "Incoming") }
    static func transferTitle(_ name: String) -> String { String(localized: "transfer.title", defaultValue: "Transfer \(name) to") }
    static var transferPlaceholder: String { String(localized: "transfer.placeholder", defaultValue: "Number or contact") }
    static var transferCallFirst: String { String(localized: "transfer.callFirst", defaultValue: "Call First") }
    static func transferCallFirstHelp(_ target: String) -> String {
        String(localized: "transfer.callFirst.help", defaultValue: "Attended: call \(target) first, then complete")
    }
    static var transferNow: String { String(localized: "transfer.now", defaultValue: "Transfer Now") }
    static var transferNowHelp: String { String(localized: "transfer.now.help", defaultValue: "Blind: hand the call over now") }
    static func transferExplanation(_ target: String) -> String {
        String(localized: "transfer.explanation", defaultValue: "Transfer Now hands the call over immediately. Call First lets you talk to \(target) before you complete the transfer.")
    }
    static var transferTargetFallback: String { String(localized: "transfer.targetFallback", defaultValue: "the new party") }
    static var micDenied: String { String(localized: "call.mic.denied", defaultValue: "Microphone access is off") }
    static var micOpenSettings: String { String(localized: "call.mic.openSettings", defaultValue: "Open System Settings") }

    // MARK: several calls
    static func callsCount(_ n: Int) -> String { String(localized: "calls.count", defaultValue: "\(n) calls") }
    static var callsSwitchHint: String { String(localized: "calls.switchHint", defaultValue: "Click a row to switch") }
    static func callsActive(_ time: String) -> String { String(localized: "calls.row.active", defaultValue: "Active · \(time)") }
    static func callsHeld(_ time: String) -> String { String(localized: "calls.row.held", defaultValue: "On hold · \(time)") }
    static func callsConsulting(_ time: String) -> String { String(localized: "calls.row.consulting", defaultValue: "Consulting · \(time)") }
    static var callsWaitingTransfer: String { String(localized: "calls.row.waitingTransfer", defaultValue: "On hold · waiting for transfer") }
    static var callsEndHelp: String { String(localized: "calls.end.help", defaultValue: "End") }
    static func transferBannerTitle(_ a: String, _ b: String) -> String {
        String(localized: "transfer.banner.title", defaultValue: "Transfer \(a) to \(b)?")
    }
    static func transferBannerBody(_ a: String, _ b: String) -> String {
        String(localized: "transfer.banner.body", defaultValue: "\(a) and \(b) will be connected and you leave both calls.")
    }
    static var transferComplete: String { String(localized: "transfer.complete", defaultValue: "Complete Transfer") }

    // MARK: incoming
    static func incomingEyebrow(_ account: String) -> String { String(localized: "incoming.eyebrow", defaultValue: "Incoming call on \(account)") }
    static var incomingAnswer: String { String(localized: "incoming.answer", defaultValue: "Answer") }
    static var incomingDecline: String { String(localized: "incoming.decline", defaultValue: "Decline") }
    static func incomingNotificationTitle(_ account: String) -> String {
        String(localized: "incoming.notification.title", defaultValue: "Incoming call · \(account)")
    }
    static func incomingOnCall(_ name: String, _ time: String) -> String {
        String(localized: "incoming.onCall.status", defaultValue: "You are on a call with \(name) (\(time)).")
    }
    static var incomingHoldAnswer: String { String(localized: "incoming.holdAnswer", defaultValue: "Hold & Answer") }
    static var incomingEndAnswer: String { String(localized: "incoming.endCurrentAnswer", defaultValue: "End Current & Answer") }
    static var incomingStateRinging: String { String(localized: "incoming.state.ringing", defaultValue: "Ringing") }

    // MARK: menu bar
    static func menuAccountFailed(_ reason: String) -> String { String(localized: "menu.account.failed", defaultValue: "Failed: \(reason)") }
    static var menuQuickDialPlaceholder: String { String(localized: "menu.quickDial.placeholder", defaultValue: "Call number or name…") }
    static var menuRecentCalls: String { String(localized: "menu.recentCalls", defaultValue: "Recent Calls") }
    static var menuDND: String { String(localized: "menu.dnd", defaultValue: "Do Not Disturb") }
    static var menubarOffline: String { String(localized: "menubar.state.offline.help", defaultValue: "Offline") }
    static var menuCall: String { String(localized: "menu.call", defaultValue: "Call") }
    static var menuEndCall: String { String(localized: "menu.endCall", defaultValue: "End Call") }
    static var menuToggleMute: String { String(localized: "menu.toggleMute", defaultValue: "Mute") }
    static var menuSimulateIncoming: String { String(localized: "menu.debug.simulateIncoming", defaultValue: "Simulate incoming call") }

    // MARK: settings
    static var settingsGeneral: String { String(localized: "settings.tab.general", defaultValue: "General") }
    static var settingsAccounts: String { String(localized: "settings.tab.accounts", defaultValue: "Accounts") }
    static var settingsAudio: String { String(localized: "settings.tab.audio", defaultValue: "Audio") }
    static var settingsNetwork: String { String(localized: "settings.tab.network", defaultValue: "Network") }
    static var settingsCodecs: String { String(localized: "settings.tab.codecs", defaultValue: "Codecs") }
    static var launchAtLogin: String { String(localized: "settings.general.launchAtLogin", defaultValue: "Launch at login") }
    static var keepRunning: String { String(localized: "settings.general.keepRunning", defaultValue: "Keep running in the menu bar when the window is closed") }
    static var showInDock: String { String(localized: "settings.general.showInDock", defaultValue: "Show icon in the Dock") }
    static var language: String { String(localized: "settings.general.language", defaultValue: "Language") }
    static var languageHelp: String { String(localized: "settings.general.language.help", defaultValue: "Takes effect after MacroSIP restarts.") }
    static func languageSystem(_ resolved: String) -> String { String(localized: "settings.general.language.system", defaultValue: "System (\(resolved))") }
    static var languageFooter: String { String(localized: "settings.general.language.footer", defaultValue: "Choices: System, English, Русский.") }
    static var languageRestartTitle: String { String(localized: "settings.general.language.restart.title", defaultValue: "Restart to change the language?") }
    static var languageRestartBody: String { String(localized: "settings.general.language.restart.body", defaultValue: "The new language is used after MacroSIP restarts.") }
    static var languageRestartNow: String { String(localized: "settings.general.language.restart.now", defaultValue: "Restart Now") }
    static var languageRestartLater: String { String(localized: "settings.general.language.restart.later", defaultValue: "Later") }
    static var linksHeader: String { String(localized: "settings.general.links.header", defaultValue: "Links") }
    static var linksTitle: String { String(localized: "settings.general.links.title", defaultValue: "Open sip: and tel: links with MacroSIP") }
    static var linksOtherHandler: String { String(localized: "settings.general.links.otherHandler", defaultValue: "Another app currently handles tel: links.") }
    static var linksIsDefault: String { String(localized: "settings.general.links.isDefault", defaultValue: "MacroSIP handles these links.") }
    static var linksMakeDefault: String { String(localized: "settings.general.links.makeDefault", defaultValue: "Make Default") }
    static var linksOnOpen: String { String(localized: "settings.general.links.onOpen", defaultValue: "When a link is opened") }
    static var linksOnOpenHelp: String { String(localized: "settings.general.links.onOpen.help", defaultValue: "Fills the number field so you can check it first.") }
    static var linksAsk: String { String(localized: "settings.general.links.askBeforeCalling", defaultValue: "Ask before calling") }
    static var linksCallNow: String { String(localized: "settings.general.links.callImmediately", defaultValue: "Call immediately") }
    static var linksFillOnly: String { String(localized: "settings.general.links.fillOnly", defaultValue: "Only fill the dial field") }

    static var accountsFooter: String { String(localized: "accounts.list.footer", defaultValue: "Double-click an account to edit it. Drag to reorder; the order is used in the account picker and the status bar.") }
    static var accountsColName: String { String(localized: "accounts.column.name", defaultValue: "Name") }
    static var accountsColAddress: String { String(localized: "accounts.column.address", defaultValue: "Address") }
    static var accountsColTransport: String { String(localized: "accounts.column.transport", defaultValue: "Transport") }
    static var accountsColStatus: String { String(localized: "accounts.column.status", defaultValue: "Status") }
    static var accountsBadgeDefault: String { String(localized: "accounts.badge.default", defaultValue: "Default") }
    static var accountsRegistered: String { String(localized: "accounts.status.registered", defaultValue: "Registered") }
    static var accountsDisabled: String { String(localized: "accounts.status.disabled", defaultValue: "Disabled") }
    static var accountsOutgoingOnly: String { String(localized: "accounts.status.outgoingOnly", defaultValue: "Outgoing only") }
    static var accountsRegisteringShort: String { String(localized: "accounts.status.registering.short", defaultValue: "…") }
    static func accountsLastErrorHeader(_ name: String) -> String { String(localized: "accounts.lastError.header", defaultValue: "\(name) · last error") }
    static func accountsLastErrorBody(_ time: String) -> String {
        String(localized: "accounts.lastError.body", defaultValue: "REGISTER rejected at \(time). Check the username and password.")
    }
    static var accountsRetry: String { String(localized: "accounts.retry", defaultValue: "Retry") }
    static var accountsEdit: String { String(localized: "accounts.edit", defaultValue: "Edit…") }
    static var accountsEmpty: String { String(localized: "accounts.empty", defaultValue: "No accounts") }
    static var accountsAddHelp: String { String(localized: "accounts.add.help", defaultValue: "Add account") }
    static var accountsRemoveHelp: String { String(localized: "accounts.remove.help", defaultValue: "Remove account") }

    static var audioDevicesHeader: String { String(localized: "settings.audio.devices.header", defaultValue: "Devices") }
    static var audioMicrophone: String { String(localized: "settings.audio.microphone", defaultValue: "Microphone") }
    static var audioSpeaker: String { String(localized: "settings.audio.speaker", defaultValue: "Speaker") }
    static var audioTest: String { String(localized: "settings.audio.test", defaultValue: "Test") }
    static var audioRingtoneDevice: String { String(localized: "settings.audio.ringtoneDevice", defaultValue: "Ringtone device") }
    static var audioRingtoneDeviceHelp: String { String(localized: "settings.audio.ringtoneDevice.help", defaultValue: "Ring through the speakers even when a headset is used for calls.") }
    static var audioSystemDefault: String { String(localized: "settings.audio.systemDefault", defaultValue: "System default") }
    static var audioDevicesFooter: String { String(localized: "settings.audio.devices.footer", defaultValue: "“System default” follows macOS Sound settings. If a chosen device is unplugged, MacroSIP falls back to the system default and switches back when it returns.") }
    static var audioRingtoneHeader: String { String(localized: "settings.audio.ringtone.header", defaultValue: "Ringtone") }
    static var audioSound: String { String(localized: "settings.audio.ringtoneSound", defaultValue: "Sound") }
    static var audioPlay: String { String(localized: "settings.audio.ringtonePlay", defaultValue: "Play") }
    static var ringtoneClassic: String { String(localized: "settings.audio.ringtone.classic", defaultValue: "Classic") }
    static var ringtoneDigital: String { String(localized: "settings.audio.ringtone.digital", defaultValue: "Digital") }
    static var ringtoneSoft: String { String(localized: "settings.audio.ringtone.soft", defaultValue: "Soft") }
    static var ringtoneCustom: String { String(localized: "settings.audio.ringtone.custom", defaultValue: "Custom file…") }
    static func ringtoneCustomName(_ name: String) -> String { String(localized: "settings.audio.ringtone.customName", defaultValue: "Custom: \(name)") }
    static var audioVolume: String { String(localized: "settings.audio.ringtoneVolume", defaultValue: "Volume") }
    static var audioRingtoneFooter: String { String(localized: "settings.audio.ringtone.footer", defaultValue: "Built-in choices: Classic, Digital, Soft. “Custom file…” accepts WAV, AIFF, M4A, MP3.") }
    static var audioProcessingHeader: String { String(localized: "settings.audio.processing.header", defaultValue: "Processing") }
    static var audioEcho: String { String(localized: "settings.audio.echoCancellation", defaultValue: "Echo cancellation") }
    static var audioEchoHelp: String { String(localized: "settings.audio.echoCancellation.help", defaultValue: "Turn off only when using a headset with its own echo cancellation.") }

    static var netConnectionHeader: String { String(localized: "settings.network.connection.header", defaultValue: "Connection") }
    static var netSTUN: String { String(localized: "settings.network.stun", defaultValue: "STUN server") }
    static var netSTUNHelp: String { String(localized: "settings.network.stun.help", defaultValue: "Leave empty if you are not behind NAT.") }
    static var netPort: String { String(localized: "settings.network.port", defaultValue: "Local SIP port") }
    static var netPortHelp: String { String(localized: "settings.network.port.help", defaultValue: "0 picks a free port automatically.") }
    static var netKeepAlive: String { String(localized: "settings.network.keepAlive", defaultValue: "Keep-alive interval") }
    static var netKeepAliveHelp: String { String(localized: "settings.network.keepAlive.help", defaultValue: "Keeps NAT bindings open between registrations.") }
    static var unitSeconds: String { String(localized: "settings.unit.seconds", defaultValue: "seconds") }
    static var netICE: String { String(localized: "settings.network.ice", defaultValue: "Use ICE") }
    static var netICEHelp: String { String(localized: "settings.network.ice.help", defaultValue: "Finds a working media path through NAT. Uses the STUN server above.") }
    static var netFooter: String { String(localized: "settings.network.footer", defaultValue: "Changing the port re-registers all accounts. Calls in progress are not interrupted. Transport and SRTP are set per account in the account editor.") }

    static var codecsHeader: String { String(localized: "settings.codecs.header", defaultValue: "Audio codecs, in order of preference") }
    static var codecsColCodec: String { String(localized: "settings.codecs.column.codec", defaultValue: "Codec") }
    static var codecsColRate: String { String(localized: "settings.codecs.column.sampleRate", defaultValue: "Sample rate") }
    static var codecsColBitrate: String { String(localized: "settings.codecs.column.bitrate", defaultValue: "Bitrate") }
    static var codecsPCMU: String { String(localized: "settings.codecs.pcmu", defaultValue: "PCMU (G.711 µ-law)") }
    static var codecsPCMA: String { String(localized: "settings.codecs.pcma", defaultValue: "PCMA (G.711 A-law)") }
    static var codecsMoveUp: String { String(localized: "settings.codecs.moveUp", defaultValue: "Move up") }
    static var codecsMoveDown: String { String(localized: "settings.codecs.moveDown", defaultValue: "Move down") }
    static var codecsRestore: String { String(localized: "settings.codecs.restoreDefaults", defaultValue: "Restore Defaults") }
    static var codecsFooter: String { String(localized: "settings.codecs.footer", defaultValue: "Drag rows or use the arrows to reorder. Unchecked codecs are never offered. At least one codec must stay enabled.") }

    // MARK: account editor
    static var accountTitleEdit: String { String(localized: "account.title.edit", defaultValue: "Edit Account") }
    static var accountTitleNew: String { String(localized: "account.title.new", defaultValue: "New Account") }
    static var accountGroupIdentity: String { String(localized: "account.group.identity", defaultValue: "Identity") }
    static var accountName: String { String(localized: "account.field.name", defaultValue: "Account name") }
    static var accountDisplayName: String { String(localized: "account.field.displayName", defaultValue: "Display name") }
    static var accountDisplayNameHelp: String { String(localized: "account.field.displayName.help", defaultValue: "Shown to people you call.") }
    static var accountGroupServer: String { String(localized: "account.group.server", defaultValue: "Server") }
    static var accountServer: String { String(localized: "account.field.server", defaultValue: "SIP server") }
    static var accountUsername: String { String(localized: "account.field.username", defaultValue: "Username") }
    static var accountAuthUsername: String { String(localized: "account.field.authUsername", defaultValue: "Auth username") }
    static var accountAuthUsernameHelp: String { String(localized: "account.field.authUsername.help", defaultValue: "Only if different from the username.") }
    static var accountOptional: String { String(localized: "account.field.optional", defaultValue: "Optional") }
    static var accountPassword: String { String(localized: "account.field.password", defaultValue: "Password") }
    static var accountPasswordHelp: String { String(localized: "account.field.password.help", defaultValue: "Stored in the Keychain.") }
    static var accountDomain: String { String(localized: "account.field.domain", defaultValue: "Domain") }
    static var accountDomainHelp: String { String(localized: "account.field.domain.help", defaultValue: "Empty uses the SIP server.") }
    static var accountProxy: String { String(localized: "account.field.proxy", defaultValue: "Outgoing proxy") }
    static var accountProxyPlaceholder: String { String(localized: "account.field.proxy.placeholder", defaultValue: "Optional, e.g. sip:proxy.example.com;lr") }
    static var accountGroupConnection: String { String(localized: "account.group.connection", defaultValue: "Connection") }
    static var accountTransport: String { String(localized: "account.field.transport", defaultValue: "Transport") }
    static var accountSRTP: String { String(localized: "account.field.srtp", defaultValue: "Media encryption (SRTP)") }
    static var srtpDisabled: String { String(localized: "account.srtp.disabled", defaultValue: "Disabled") }
    static var srtpOptional: String { String(localized: "account.srtp.optional", defaultValue: "Optional") }
    static var srtpMandatory: String { String(localized: "account.srtp.mandatory", defaultValue: "Mandatory") }
    static var accountExpiry: String { String(localized: "account.field.expiry", defaultValue: "Registration expiry") }
    static var accountEnabled: String { String(localized: "account.field.enabled", defaultValue: "Enabled") }
    static var accountEnabledHelp: String {
        String(localized: "account.field.enabled.help", defaultValue: "Off stops registration and outgoing calls; the account stays in the pop-up, dimmed, and leaves the status bar.")
    }
    static var accountRegister: String { String(localized: "account.field.register", defaultValue: "Register with server") }
    static var accountRegisterHelp: String { String(localized: "account.field.register.help", defaultValue: "Off keeps the account for outgoing calls only.") }
    static var accountDefaultOutgoing: String { String(localized: "account.field.defaultOutgoing", defaultValue: "Default for outgoing calls") }
    static var accountDelete: String { String(localized: "account.delete", defaultValue: "Delete Account…") }
    static func accountDeleteTitle(_ name: String) -> String { String(localized: "account.delete.confirm.title", defaultValue: "Delete account “\(name)”?") }
    static var accountDeleteBody: String { String(localized: "account.delete.confirm.body", defaultValue: "Its password is removed from Keychain. Call history is kept.") }
    static var accountTest: String { String(localized: "account.test", defaultValue: "Test") }
    static var accountUnsaved: String { String(localized: "account.status.unsaved", defaultValue: "Not saved") }
    static var accountTesting: String { String(localized: "account.test.running", defaultValue: "Testing…") }
    static func accountTestSuccess(_ ms: Int) -> String { String(localized: "account.test.success", defaultValue: "Registered successfully (\(ms) ms)") }
    static func accountTestFailed(_ reason: String) -> String { String(localized: "account.test.failed", defaultValue: "Test failed: \(reason)") }
    static var accountTestFailedHint: String { String(localized: "account.test.failed.hint", defaultValue: "The server rejected the username or password. Nothing was saved.") }
    static var accountTestTimeoutHint: String { String(localized: "account.test.timeout.hint", defaultValue: "The server did not answer in time. Nothing was saved.") }
    static var accountTestTimeout: String { String(localized: "account.test.timeout", defaultValue: "No response") }
    static var accountTestAgain: String { String(localized: "account.test.again", defaultValue: "Test Again") }
    static var accountErrorServer: String { String(localized: "account.error.server", defaultValue: "Enter a host name like pbx.example.com, or an IP address.") }
    static var accountErrorExpiry: String { String(localized: "account.error.expiry", defaultValue: "Registration expiry must be 60 to 3600 seconds.") }

    // MARK: first launch
    static var firstRunTitle: String { String(localized: "firstrun.title", defaultValue: "Add a SIP account to start calling") }
    static var firstRunBody: String { String(localized: "firstrun.body", defaultValue: "You need the server address, username and password from your phone provider or PBX administrator.") }
    static var firstRunAdd: String { String(localized: "firstrun.addAccount", defaultValue: "Add Account…") }
    static var firstRunFootnote: String { String(localized: "firstrun.footnote", defaultValue: "Contacts and the call log work without an account.") }

    // MARK: banners (UI-only)
    static var bannerEngineFallback: String { String(localized: "banner.engine.fallback", defaultValue: "SIP engine unavailable; using the simulated engine.") }
    static func bannerLinkFilled(_ number: String) -> String { String(localized: "banner.link.filled", defaultValue: "Link opened: \(number). Press Call to dial.") }
    static var bannerNoAccount: String { String(localized: "banner.noAccount", defaultValue: "Add an account before calling.") }
    static var bannerTooManyCalls: String { String(localized: "banner.tooManyCalls", defaultValue: "Four calls are already in progress.") }

    // MARK: presence (screens 2, 7)
    static var presenceAvailable: String { String(localized: "presence.available", defaultValue: "Available") }
    static var presenceAway: String { String(localized: "presence.away", defaultValue: "Away") }
    static var presenceDND: String { String(localized: "presence.dnd", defaultValue: "Do Not Disturb") }
    static var presenceOffline: String { String(localized: "presence.offline", defaultValue: "Offline") }
    static var contactsMenuWatchPresence: String { String(localized: "contacts.menu.watchPresence", defaultValue: "Watch Presence") }
    static var contactWatchPresence: String { String(localized: "contact.watchPresence", defaultValue: "Watch presence (subscribe)") }
    static var menuMyStatus: String { String(localized: "menu.myStatus", defaultValue: "My Status") }

    // MARK: call log additions (screen 3)
    static var logClearBodyRecordings: String { String(localized: "calllog.clear.bodyRecordings", defaultValue: "Recordings stay in their folder.") }
    static var logNoteCallLimit: String { String(localized: "calllog.note.callLimit", defaultValue: "Rejected: call limit") }

    // MARK: recording, conference (screens 4, 5)
    static func callRecChip(_ time: String) -> String { String(localized: "call.rec.chip", defaultValue: "REC \(time)") }
    static var callRecShort: String { String(localized: "callbar.rec", defaultValue: "REC") }
    static var callRecord: String { String(localized: "call.record", defaultValue: "Record") }
    static var callMerge: String { String(localized: "call.merge", defaultValue: "Merge") }
    static var callsInConference: String { String(localized: "calls.row.inConference", defaultValue: "In conference") }
    static var callsSplit: String { String(localized: "calls.split", defaultValue: "Split") }
    static func conferenceHeader(_ n: Int) -> String { String(localized: "conference.header", defaultValue: "Conference · \(n) participants") }
    static var conferenceEnd: String { String(localized: "conference.end", defaultValue: "End Conference") }

    // MARK: auto-answer (screens 6.5, 8.7)
    static func autoAnswerCountdown(_ seconds: Int) -> String { String(localized: "incoming.autoAnswer.countdown", defaultValue: "Auto-answer in \(seconds) s") }
    static var autoAnswerCancel: String { String(localized: "incoming.autoAnswer.cancel", defaultValue: "Cancel") }
    static var settingsAutoAnswer: String { String(localized: "settings.tab.autoAnswer", defaultValue: "Auto-answer") }
    static var autoAnswerMode: String { String(localized: "settings.autoAnswer.mode", defaultValue: "Answer incoming calls automatically") }
    static var autoAnswerOff: String { String(localized: "settings.autoAnswer.off", defaultValue: "Off") }
    static var autoAnswerAll: String { String(localized: "settings.autoAnswer.all", defaultValue: "All calls") }
    static var autoAnswerContactsOnly: String { String(localized: "settings.autoAnswer.contactsOnly", defaultValue: "Contacts only") }
    static var autoAnswerDelay: String { String(localized: "settings.autoAnswer.delay", defaultValue: "Delay before answering") }
    static var autoAnswerHonour: String { String(localized: "settings.autoAnswer.honourServer", defaultValue: "Honour the server's answer-after request") }
    static var autoAnswerHonourHelp: String {
        String(localized: "settings.autoAnswer.honourServer.help", defaultValue: "Answers when the PBX sends Call-Info: answer-after=N (intercom, paging), even if the mode is Off.")
    }
    static var autoAnswerFooter: String {
        String(localized: "settings.autoAnswer.footer", defaultValue: "Do Not Disturb wins over auto-answer. Auto-answer never answers a second call while you are already on one.")
    }

    // MARK: recording settings (screen 8.6)
    static var settingsRecording: String { String(localized: "settings.tab.recording", defaultValue: "Recording") }
    static var recordingFolder: String { String(localized: "settings.recording.folder", defaultValue: "Save recordings to") }
    static var recordingChooseFolder: String { String(localized: "settings.recording.chooseFolder", defaultValue: "Choose Folder…") }
    static var recordingFolderMissing: String { String(localized: "settings.recording.folderMissing", defaultValue: "Folder not found") }
    static var recordingAuto: String { String(localized: "settings.recording.auto", defaultValue: "Record all calls automatically") }
    static var recordingFooter: String {
        String(localized: "settings.recording.footer", defaultValue: "Recordings are saved as M4A (AAC). The temporary WAV is deleted after conversion.")
    }
    static func recordingFileName(_ sample: String) -> String { String(localized: "settings.recording.fileName", defaultValue: "File name: \(sample)") }
    static var recordingShowFolder: String { String(localized: "settings.recording.showFolder", defaultValue: "Show Recordings Folder") }
    static var recordingOpenFinder: String { String(localized: "settings.recording.openFinder", defaultValue: "Open in Finder") }
    static func bannerRecordingKeptAsWAV(_ reason: String, _ file: String) -> String {
        String(localized: "banner.recording.keptAsWAV", defaultValue: "Recording could not be converted (\(reason)). It was saved as \(file) in the recordings folder.")
    }
    static var autoAnswerServerOnly: String {
        String(localized: "settings.autoAnswer.honourServer.note", defaultValue: "Only requests from your own server are honoured.")
    }
    static func logNoteText(_ code: String) -> String {
        switch code {
        case CallLogNote.callLimit: return logNoteCallLimit
        default: return code
        }
    }

    // MARK: menu bar status, account editor additions
    static var menuStatusAvailable: String { String(localized: "menu.status.available", defaultValue: "Available") }
    static var menuStatusAway: String { String(localized: "menu.status.away", defaultValue: "Away") }
    static var menuStatusDND: String { String(localized: "menu.status.dnd", defaultValue: "Do Not Disturb") }
    static var accountPublishPresence: String { String(localized: "account.field.publishPresence", defaultValue: "Publish my presence") }
    static var accountPublishPresenceHelp: String {
        String(localized: "account.field.publishPresence.help", defaultValue: "Lets contacts who watch you see Available / Away / DND.")
    }
    static var accountVerifyCertificate: String { String(localized: "account.field.verifyCertificate", defaultValue: "Verify server certificate") }
    static var accountVerifyCertificateHelp: String {
        String(localized: "account.field.verifyCertificate.help", defaultValue: "Turn off only for a server with a self-signed certificate.")
    }
}
