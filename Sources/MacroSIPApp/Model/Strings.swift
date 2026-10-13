import Foundation
import MacroSIPCore

// All user-visible strings. Keys follow docs/design/SCREENS.md "Strings". Every key also lives in
// Resources/en.lproj and Resources/ru.lproj (Localizable.strings; counts in Localizable.stringsdict).
// The English default below is only the fallback for a missing key; scripts/check-strings.sh keeps the files in sync.

enum L {
    /// Looks the key up in the language chosen by `AppleLanguages`. Interpolations become
    /// `%@` / `%lld` (or `%1$@` ...) in the .strings value.
    private static func loc(_ key: StaticString, _ defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: stringsBundle)
    }

    /// The bundle that holds Localizable.strings. In the .app the tables live in
    /// `Contents/Resources/<lang>.lproj` (make-app.sh copies them there), so `Bundle.main` wins.
    /// A plain `swift build` / `swift run` finds the SwiftPM resource bundle next to the binary.
    /// Never traps: a missing bundle only means the English defaults are shown.
    private static let stringsBundle: Bundle = {
        let main = Bundle.main
        if main.url(forResource: "Localizable", withExtension: "strings") != nil
            || main.url(forResource: "Localizable", withExtension: "stringsdict") != nil {
            return main
        }
        let name = "MacroSIP_MacroSIPApp.bundle"
        let places = [main.resourceURL, main.bundleURL, main.executableURL?.deletingLastPathComponent()]
        for place in places {
            if let url = place?.appendingPathComponent(name), let bundle = Bundle(url: url),
               bundle.url(forResource: "Localizable", withExtension: "strings") != nil {
                return bundle
            }
        }
        return main
    }()
    // MARK: common and main window
    static var mainTitle: String { loc("main.title", "MacroSIP") }
    static var tabsDialpad: String { loc("tabs.dialpad", "Dialpad") }
    static var tabsContacts: String { loc("tabs.contacts", "Contacts") }
    static var tabsCallLog: String { loc("tabs.callLog", "Call Log") }
    static var numberPlaceholder: String { loc("main.numberField.placeholder", "Name or number") }
    static var accountPickerHelp: String { loc("main.accountPicker.help", "Outgoing account") }
    static var accountPopupHeader: String { loc("account.popup.header", "Accounts") }
    static var accountPopupSettings: String { loc("account.popup.settings", "Account Settings…") }
    static var accountPopupNone: String { loc("account.popup.none", "No account") }
    static func accountPopupFailed(_ reason: String, _ address: String) -> String {
        loc("account.popup.failed", "\(reason) · \(address)")
    }
    static var statusNoneEnabled: String { loc("status.noneEnabled", "All accounts off") }
    static var statusNoAccounts: String { loc("status.noAccounts", "No accounts") }
    static func statusAccountFailed(_ name: String, _ reason: String) -> String {
        loc("status.account.failed", "\(name): \(reason)")
    }
    static var statusRegistering: String { loc("accounts.status.registering", "Registering…") }
    /// "4 of 6 online" or, with failures, "4 of 6 online · 2 failed".
    static func statusSummary(_ ok: Int, _ total: Int, failed: Int = 0) -> String {
        let base = loc("status.summary", "\(ok) of \(total) online")
        return failed > 0 ? "\(base) · \(statusSummaryFailed(failed))" : base
    }
    static func statusSummaryFailed(_ n: Int) -> String { loc("status.summary.failed", "\(n) failed") }
    static var menuSettings: String { loc("menu.settings", "Settings…") }
    static func menuShowApp(_ name: String) -> String { loc("menu.showApp", "Show \(name)") }
    static func menuQuitApp(_ name: String) -> String { loc("menu.quitApp", "Quit \(name)") }
    static var commonCancel: String { loc("common.cancel", "Cancel") }
    static var commonSave: String { loc("common.save", "Save") }
    static var commonDelete: String { loc("common.delete", "Delete") }
    static var commonDone: String { loc("common.done", "Done") }

    // MARK: dialpad
    static var dialpadCallHelp: String { loc("dialpad.call.help", "Call") }
    static var dialpadDeleteHelp: String { loc("dialpad.delete.help", "Delete last digit") }
    static func keyLetters(_ digit: Character) -> String {
        switch digit {
        case "2": return loc("dialpad.key.letters.2", "ABC")
        case "3": return loc("dialpad.key.letters.3", "DEF")
        case "4": return loc("dialpad.key.letters.4", "GHI")
        case "5": return loc("dialpad.key.letters.5", "JKL")
        case "6": return loc("dialpad.key.letters.6", "MNO")
        case "7": return loc("dialpad.key.letters.7", "PQRS")
        case "8": return loc("dialpad.key.letters.8", "TUV")
        case "9": return loc("dialpad.key.letters.9", "WXYZ")
        case "0": return loc("dialpad.key.letters.0", "+")
        default: return ""
        }
    }

    // MARK: contacts
    static var contactsSearch: String { loc("contacts.search.placeholder", "Search") }
    static func contactsCount(_ n: Int) -> String {
        loc("contacts.count", "\(n) contacts")
    }
    static var contactsAddHelp: String { loc("contacts.add.help", "Add contact") }
    static var contactsDeleteHelp: String { loc("contacts.delete.help", "Delete contact") }
    static var contactsEditHelp: String { loc("contacts.edit.help", "Edit contact") }
    static var contactsMenuCall: String { loc("contacts.menu.call", "Call") }
    static var contactsMenuCallFrom: String { loc("contacts.menu.callFrom", "Call from") }
    static var contactsMenuCopy: String { loc("contacts.menu.copyNumber", "Copy Number") }
    static var contactsMenuEdit: String { loc("contacts.menu.edit", "Edit…") }
    static var contactsMenuDelete: String { loc("contacts.menu.delete", "Delete") }
    static func contactsDeleteConfirm(_ name: String) -> String {
        loc("contacts.delete.confirm", "Delete \(name)?")
    }
    static var contactEditTitle: String { loc("contact.edit.title", "Edit Contact") }
    static var contactNewTitle: String { loc("contact.new.title", "New Contact") }
    static var contactAccount: String { loc("contact.field.account", "Account") }
    static var contactAccountAny: String { loc("contact.account.any", "Any (use default)") }
    static var contactsEmptyTitle: String { loc("contacts.empty.title", "No contacts yet") }
    static var contactsEmptyBody: String { loc("contacts.empty.body", "Add a contact to call it in one click.") }
    static var contactsNoResults: String { loc("contacts.search.noResults", "No matching contacts") }

    // MARK: call log
    static var logAll: String { loc("calllog.filter.all", "All") }
    static var logMissed: String { loc("calllog.filter.missed", "Missed") }
    static var logClear: String { loc("calllog.clear", "Clear…") }
    static var logToday: String { loc("calllog.section.today", "Today") }
    static var logYesterday: String { loc("calllog.section.yesterday", "Yesterday") }
    static var logRowMissed: String { loc("calllog.row.missed", "missed") }
    static var logUnknown: String { loc("calllog.row.unknown", "Unknown") }
    static var logMenuCall: String { loc("calllog.menu.call", "Call") }
    static var logMenuCallFrom: String { loc("calllog.menu.callFrom", "Call from") }
    static var logMenuAddContact: String { loc("calllog.menu.addContact", "Add to Contacts") }
    static var logMenuCopy: String { loc("calllog.menu.copyNumber", "Copy Number") }
    static var logMenuDelete: String { loc("calllog.menu.delete", "Delete Entry") }
    static var logClearTitle: String { loc("calllog.clear.title", "Clear the call log?") }
    static func logClearBody(_ n: Int) -> String { loc("calllog.clear.body", "All \(n) entries are removed.") }
    static var logClearConfirm: String { loc("calllog.clear.confirm", "Clear") }
    static var logEmptyTitle: String { loc("calllog.empty.title", "No calls yet") }
    static var logEmptyBody: String { loc("calllog.empty.body", "Calls you make and receive appear here.") }
    static var logEmptyMissed: String { loc("calllog.empty.missed", "No missed calls") }

    // MARK: active call
    static var callConnected: String { loc("call.state.connected", "Connected") }
    static var callCalling: String { loc("call.state.outgoing", "Calling…") }
    static var callRinging: String { loc("call.state.early", "Ringing…") }
    static var callRingingIn: String { loc("call.state.ringing", "Ringing") }
    static var callHeld: String { loc("call.state.held", "On hold") }
    static func callVia(_ account: String) -> String { loc("call.via", "via \(account)") }
    static var callSRTP: String { loc("call.srtp.label", "SRTP") }
    static var callSRTPHelp: String { loc("call.srtp.help", "Media encrypted with SRTP") }
    static var callMute: String { loc("call.mute", "Mute") }
    static var callHold: String { loc("call.hold", "Hold") }
    static var callResume: String { loc("calls.resume", "Resume") }
    static var callTransfer: String { loc("call.transfer", "Transfer") }
    static var callKeypad: String { loc("call.keypad", "Keypad") }
    static var callEnd: String { loc("call.end", "End Call") }
    static func callEndWith(_ name: String) -> String { loc("call.endWith", "End Call with \(name)") }
    static var keypadBack: String { loc("keypad.back", "Back to call") }
    static func keypadWho(_ name: String, _ time: String) -> String { loc("keypad.who", "\(name) · \(time)") }
    static var callbarHelp: String { loc("callbar.help", "Click to return to the call") }
    static var callbarMuted: String { loc("callbar.muted.help", "Muted") }
    static func callbarMoreHeld(_ n: Int) -> String { loc("callbar.moreHeld", "+\(n) on hold") }
    static var callbarIncoming: String { loc("callbar.incoming", "Incoming") }
    static func transferTitle(_ name: String) -> String { loc("transfer.title", "Transfer \(name) to") }
    static var transferPlaceholder: String { loc("transfer.placeholder", "Number or contact") }
    static var transferCallFirst: String { loc("transfer.callFirst", "Call First") }
    static func transferCallFirstHelp(_ target: String) -> String {
        loc("transfer.callFirst.help", "Attended: call \(target) first, then complete")
    }
    static var transferNow: String { loc("transfer.now", "Transfer Now") }
    static var transferNowHelp: String { loc("transfer.now.help", "Blind: hand the call over now") }
    static func transferExplanation(_ target: String) -> String {
        loc("transfer.explanation", "Transfer Now hands the call over immediately. Call First lets you talk to \(target) before you complete the transfer.")
    }
    static var transferTargetFallback: String { loc("transfer.targetFallback", "the new party") }
    static var micDenied: String { loc("call.mic.denied", "Microphone access is off") }
    static var micOpenSettings: String { loc("call.mic.openSettings", "Open System Settings") }

    // MARK: several calls
    static func callsCount(_ n: Int) -> String { loc("calls.count", "\(n) calls") }
    static var callsSwitchHint: String { loc("calls.switchHint", "Click a row to switch") }
    static func callsActive(_ time: String) -> String { loc("calls.row.active", "Active · \(time)") }
    static func callsHeld(_ time: String) -> String { loc("calls.row.held", "On hold · \(time)") }
    static func callsConsulting(_ time: String) -> String { loc("calls.row.consulting", "Consulting · \(time)") }
    static var callsWaitingTransfer: String { loc("calls.row.waitingTransfer", "On hold · waiting for transfer") }
    static var callsEndHelp: String { loc("calls.end.help", "End") }
    static func transferBannerTitle(_ a: String, _ b: String) -> String {
        loc("transfer.banner.title", "Transfer \(a) to \(b)?")
    }
    static func transferBannerBody(_ a: String, _ b: String) -> String {
        loc("transfer.banner.body", "\(a) and \(b) will be connected and you leave both calls.")
    }
    static var transferComplete: String { loc("transfer.complete", "Complete Transfer") }

    // MARK: incoming
    static func incomingEyebrow(_ account: String) -> String { loc("incoming.eyebrow", "Incoming call on \(account)") }
    static var incomingAnswer: String { loc("incoming.answer", "Answer") }
    static var incomingDecline: String { loc("incoming.decline", "Decline") }
    static func incomingNotificationTitle(_ account: String) -> String {
        loc("incoming.notification.title", "Incoming call · \(account)")
    }
    static func incomingOnCall(_ name: String, _ time: String) -> String {
        loc("incoming.onCall.status", "You are on a call with \(name) (\(time)).")
    }
    static var incomingHoldAnswer: String { loc("incoming.holdAnswer", "Hold & Answer") }
    static var incomingEndAnswer: String { loc("incoming.endCurrentAnswer", "End Current & Answer") }
    static var incomingStateRinging: String { loc("incoming.state.ringing", "Ringing") }

    // MARK: menu bar
    static func menuAccountFailed(_ reason: String) -> String { loc("menu.account.failed", "Failed: \(reason)") }
    static var menuQuickDialPlaceholder: String { loc("menu.quickDial.placeholder", "Call number or name…") }
    static var menuRecentCalls: String { loc("menu.recentCalls", "Recent Calls") }
    static var menuDND: String { loc("menu.dnd", "Do Not Disturb") }
    static var menubarOffline: String { loc("menubar.state.offline.help", "Offline") }
    static var menuCall: String { loc("menu.call", "Call") }
    static var menuEndCall: String { loc("menu.endCall", "End Call") }
    static var menuToggleMute: String { loc("menu.toggleMute", "Mute") }
    static var menuSimulateIncoming: String { loc("menu.debug.simulateIncoming", "Simulate incoming call") }

    // MARK: settings
    static var settingsGeneral: String { loc("settings.tab.general", "General") }
    static var settingsAccounts: String { loc("settings.tab.accounts", "Accounts") }
    static var settingsAudio: String { loc("settings.tab.audio", "Audio") }
    static var settingsNetwork: String { loc("settings.tab.network", "Network") }
    static var settingsCodecs: String { loc("settings.tab.codecs", "Codecs") }
    static var launchAtLogin: String { loc("settings.general.launchAtLogin", "Launch at login") }
    static var keepRunning: String { loc("settings.general.keepRunning", "Keep running in the menu bar when the window is closed") }
    static var showInDock: String { loc("settings.general.showInDock", "Show icon in the Dock") }
    static var language: String { loc("settings.general.language", "Language") }
    static var languageHelp: String { loc("settings.general.language.help", "Takes effect after MacroSIP restarts.") }
    static func languageSystem(_ resolved: String) -> String { loc("settings.general.language.system", "System (\(resolved))") }
    static var languageFooter: String { loc("settings.general.language.footer", "Choices: System, English, Русский.") }
    static var languageRestartTitle: String { loc("settings.general.language.restart.title", "Restart to change the language?") }
    static var languageRestartBody: String { loc("settings.general.language.restart.body", "The new language is used after MacroSIP restarts.") }
    static var languageRestartNow: String { loc("settings.general.language.restart.now", "Restart Now") }
    static var languageRestartLater: String { loc("settings.general.language.restart.later", "Later") }
    static var linksHeader: String { loc("settings.general.links.header", "Links") }
    static var linksTitle: String { loc("settings.general.links.title", "Open sip: and tel: links with MacroSIP") }
    static var linksOtherHandler: String { loc("settings.general.links.otherHandler", "Another app currently handles tel: links.") }
    static var linksIsDefault: String { loc("settings.general.links.isDefault", "MacroSIP handles these links.") }
    static var linksMakeDefault: String { loc("settings.general.links.makeDefault", "Make Default") }
    static var linksOnOpen: String { loc("settings.general.links.onOpen", "When a link is opened") }
    static var linksOnOpenHelp: String { loc("settings.general.links.onOpen.help", "Fills the number field so you can check it first.") }
    static var linksAsk: String { loc("settings.general.links.askBeforeCalling", "Ask before calling") }
    static var linksCallNow: String { loc("settings.general.links.callImmediately", "Call immediately") }
    static var linksFillOnly: String { loc("settings.general.links.fillOnly", "Only fill the dial field") }
    static var launchAtLoginApproval: String { loc("settings.general.launchAtLogin.approval", "Allow MacroSIP in System Settings › General › Login Items.") }
    static var launchAtLoginOpenSettings: String { loc("settings.general.launchAtLogin.openSettings", "Open Login Items…") }
    static func launchAtLoginFailed(_ reason: String) -> String {
        loc("settings.general.launchAtLogin.failed", "macOS did not change the login item: \(reason)")
    }
    static var troubleshootingHeader: String { loc("settings.general.troubleshooting.header", "Troubleshooting") }
    static var logFileTitle: String { loc("settings.general.log.title", "Log file") }
    static var logFileHelp: String { loc("settings.general.log.help", "~/Library/Logs/MacroSIP/MacroSIP.log, 2 MB per file, 3 files.") }
    static var logOpenFolder: String { loc("settings.general.log.openFolder", "Open Log Folder") }
    static var diagnosticsTitle: String { loc("settings.general.diagnostics.title", "Diagnostics") }
    static var diagnosticsHelp: String { loc("settings.general.diagnostics.help", "Versions, accounts and settings, without passwords. Paste it into a bug report.") }
    static var diagnosticsCopy: String { loc("settings.general.diagnostics.copy", "Copy Diagnostics") }
    static var diagnosticsCopied: String { loc("settings.general.diagnostics.copied", "Diagnostics copied to the clipboard.") }
    static func menuAbout(_ name: String) -> String { loc("menu.about", "About \(name)") }
    static var aboutCredits: String {
        loc("about.credits", "Built on PJSIP 2.17 (GPLv2+). MacroSIP is free software under the GNU GPL v2 or later.")
    }

    static var accountsFooter: String { loc("accounts.list.footer", "Double-click an account to edit it. Drag to reorder; the order is used in the account picker and the status bar.") }
    static var accountsColName: String { loc("accounts.column.name", "Name") }
    static var accountsColAddress: String { loc("accounts.column.address", "Address") }
    static var accountsColTransport: String { loc("accounts.column.transport", "Transport") }
    static var accountsColStatus: String { loc("accounts.column.status", "Status") }
    static var accountsBadgeDefault: String { loc("accounts.badge.default", "Default") }
    static var accountsRegistered: String { loc("accounts.status.registered", "Registered") }
    static var accountsDisabled: String { loc("accounts.status.disabled", "Disabled") }
    static var accountsOutgoingOnly: String { loc("accounts.status.outgoingOnly", "Outgoing only") }
    static var accountsRegisteringShort: String { loc("accounts.status.registering.short", "…") }
    static func accountsLastErrorHeader(_ name: String) -> String { loc("accounts.lastError.header", "\(name) · last error") }
    static func accountsLastErrorBody(_ time: String) -> String {
        loc("accounts.lastError.body", "REGISTER rejected at \(time). Check the username and password.")
    }
    static var accountsRetry: String { loc("accounts.retry", "Retry") }
    static var accountsEdit: String { loc("accounts.edit", "Edit…") }
    static var accountsEmpty: String { loc("accounts.empty", "No accounts") }
    static var accountsAddHelp: String { loc("accounts.add.help", "Add account") }
    static var accountsRemoveHelp: String { loc("accounts.remove.help", "Remove account") }

    static var audioDevicesHeader: String { loc("settings.audio.devices.header", "Devices") }
    static var audioMicrophone: String { loc("settings.audio.microphone", "Microphone") }
    static var audioSpeaker: String { loc("settings.audio.speaker", "Speaker") }
    static var audioTest: String { loc("settings.audio.test", "Test") }
    static var audioRingtoneDevice: String { loc("settings.audio.ringtoneDevice", "Ringtone device") }
    static var audioRingtoneDeviceHelp: String { loc("settings.audio.ringtoneDevice.help", "Ring through the speakers even when a headset is used for calls.") }
    static var audioSystemDefault: String { loc("settings.audio.systemDefault", "System default") }
    static var audioDevicesFooter: String { loc("settings.audio.devices.footer", "“System default” follows macOS Sound settings. If a chosen device is unplugged, MacroSIP falls back to the system default and switches back when it returns.") }
    static var audioRingtoneHeader: String { loc("settings.audio.ringtone.header", "Ringtone") }
    static var audioSound: String { loc("settings.audio.ringtoneSound", "Sound") }
    static var audioPlay: String { loc("settings.audio.ringtonePlay", "Play") }
    static var ringtoneClassic: String { loc("settings.audio.ringtone.classic", "Classic") }
    static var ringtoneDigital: String { loc("settings.audio.ringtone.digital", "Digital") }
    static var ringtoneSoft: String { loc("settings.audio.ringtone.soft", "Soft") }
    static var ringtoneCustom: String { loc("settings.audio.ringtone.custom", "Custom file…") }
    static func ringtoneCustomName(_ name: String) -> String { loc("settings.audio.ringtone.customName", "Custom: \(name)") }
    static var audioVolume: String { loc("settings.audio.ringtoneVolume", "Volume") }
    static var audioRingtoneFooter: String { loc("settings.audio.ringtone.footer", "Built-in choices: Classic, Digital, Soft. “Custom file…” accepts WAV, AIFF, M4A, MP3.") }
    static var audioProcessingHeader: String { loc("settings.audio.processing.header", "Processing") }
    static var audioEcho: String { loc("settings.audio.echoCancellation", "Echo cancellation") }
    static var audioEchoHelp: String { loc("settings.audio.echoCancellation.help", "Turn off only when using a headset with its own echo cancellation.") }

    static var netConnectionHeader: String { loc("settings.network.connection.header", "Connection") }
    static var netSTUN: String { loc("settings.network.stun", "STUN server") }
    static var netSTUNHelp: String { loc("settings.network.stun.help", "Leave empty if you are not behind NAT.") }
    static var netPort: String { loc("settings.network.port", "Local SIP port") }
    static var netPortHelp: String { loc("settings.network.port.help", "0 picks a free port automatically.") }
    static var netKeepAlive: String { loc("settings.network.keepAlive", "Keep-alive interval") }
    static var netKeepAliveHelp: String { loc("settings.network.keepAlive.help", "Keeps NAT bindings open between registrations.") }
    static var unitSeconds: String { loc("settings.unit.seconds", "seconds") }
    static var netICE: String { loc("settings.network.ice", "Use ICE") }
    static var netICEHelp: String { loc("settings.network.ice.help", "Finds a working media path through NAT. Uses the STUN server above.") }
    static var netFooter: String { loc("settings.network.footer", "Changing the port re-registers all accounts. Calls in progress are not interrupted. Transport and SRTP are set per account in the account editor.") }

    static var codecsHeader: String { loc("settings.codecs.header", "Audio codecs, in order of preference") }
    static var codecsColCodec: String { loc("settings.codecs.column.codec", "Codec") }
    static var codecsColRate: String { loc("settings.codecs.column.sampleRate", "Sample rate") }
    static var codecsColBitrate: String { loc("settings.codecs.column.bitrate", "Bitrate") }
    static func unitKHz(_ value: String) -> String { loc("unit.khz", "\(value) kHz") }
    static func unitKbps(_ value: String) -> String { loc("unit.kbps", "\(value) kbit/s") }
    static var codecsPCMU: String { loc("settings.codecs.pcmu", "PCMU (G.711 µ-law)") }
    static var codecsPCMA: String { loc("settings.codecs.pcma", "PCMA (G.711 A-law)") }
    static var codecsMoveUp: String { loc("settings.codecs.moveUp", "Move up") }
    static var codecsMoveDown: String { loc("settings.codecs.moveDown", "Move down") }
    static var codecsRestore: String { loc("settings.codecs.restoreDefaults", "Restore Defaults") }
    static var codecsFooter: String { loc("settings.codecs.footer", "Drag rows or use the arrows to reorder. Unchecked codecs are never offered. At least one codec must stay enabled.") }

    // MARK: account editor
    static var accountTitleEdit: String { loc("account.title.edit", "Edit Account") }
    static var accountTitleNew: String { loc("account.title.new", "New Account") }
    static var accountGroupIdentity: String { loc("account.group.identity", "Identity") }
    static var accountName: String { loc("account.field.name", "Account name") }
    static var accountDisplayName: String { loc("account.field.displayName", "Display name") }
    static var accountDisplayNameHelp: String { loc("account.field.displayName.help", "Shown to people you call.") }
    static var accountGroupServer: String { loc("account.group.server", "Server") }
    static var accountServer: String { loc("account.field.server", "SIP server") }
    static var accountUsername: String { loc("account.field.username", "Username") }
    static var accountAuthUsername: String { loc("account.field.authUsername", "Auth username") }
    static var accountAuthUsernameHelp: String { loc("account.field.authUsername.help", "Only if different from the username.") }
    static var accountOptional: String { loc("account.field.optional", "Optional") }
    static var accountPassword: String { loc("account.field.password", "Password") }
    static var accountPasswordHelp: String { loc("account.field.password.help", "Stored in the Keychain.") }
    static var accountDomain: String { loc("account.field.domain", "Domain") }
    static var accountDomainHelp: String { loc("account.field.domain.help", "Empty uses the SIP server.") }
    static var accountProxy: String { loc("account.field.proxy", "Outgoing proxy") }
    static var accountProxyPlaceholder: String { loc("account.field.proxy.placeholder", "Optional, e.g. sip:proxy.example.com;lr") }
    static var accountGroupConnection: String { loc("account.group.connection", "Connection") }
    static var accountTransport: String { loc("account.field.transport", "Transport") }
    static var accountSRTP: String { loc("account.field.srtp", "Media encryption (SRTP)") }
    static var srtpDisabled: String { loc("account.srtp.disabled", "Disabled") }
    static var srtpOptional: String { loc("account.srtp.optional", "Optional") }
    static var srtpMandatory: String { loc("account.srtp.mandatory", "Mandatory") }
    static var accountExpiry: String { loc("account.field.expiry", "Registration expiry") }
    static var accountEnabled: String { loc("account.field.enabled", "Enabled") }
    static var accountEnabledHelp: String {
        loc("account.field.enabled.help", "Off stops registration and outgoing calls; the account stays in the pop-up, dimmed, and leaves the status bar.")
    }
    static var accountRegister: String { loc("account.field.register", "Register with server") }
    static var accountRegisterHelp: String { loc("account.field.register.help", "Off keeps the account for outgoing calls only.") }
    static var accountDefaultOutgoing: String { loc("account.field.defaultOutgoing", "Default for outgoing calls") }
    static var accountDelete: String { loc("account.delete", "Delete Account…") }
    static func accountDeleteTitle(_ name: String) -> String { loc("account.delete.confirm.title", "Delete account “\(name)”?") }
    static var accountDeleteBody: String { loc("account.delete.confirm.body", "Its password is removed from Keychain. Call history is kept.") }
    static var accountTest: String { loc("account.test", "Test") }
    static var accountUnsaved: String { loc("account.status.unsaved", "Not saved") }
    static var accountTesting: String { loc("account.test.running", "Testing…") }
    static func accountTestSuccess(_ ms: Int) -> String { loc("account.test.success", "Registered successfully (\(ms) ms)") }
    static func accountTestFailed(_ reason: String) -> String { loc("account.test.failed", "Test failed: \(reason)") }
    static var accountTestFailedHint: String { loc("account.test.failed.hint", "The server rejected the username or password. Nothing was saved.") }
    static var accountTestTimeoutHint: String { loc("account.test.timeout.hint", "The server did not answer in time. Nothing was saved.") }
    static var accountTestTimeout: String { loc("account.test.timeout", "No response") }
    static var accountTestAgain: String { loc("account.test.again", "Test Again") }
    static var accountErrorServer: String { loc("account.error.server", "Enter a host name like pbx.example.com, or an IP address.") }
    static var accountErrorExpiry: String { loc("account.error.expiry", "Registration expiry must be 60 to 3600 seconds.") }

    // MARK: first launch
    static var firstRunTitle: String { loc("firstrun.title", "Add a SIP account to start calling") }
    static var firstRunBody: String { loc("firstrun.body", "You need the server address, username and password from your phone provider or PBX administrator.") }
    static var firstRunAdd: String { loc("firstrun.addAccount", "Add Account…") }
    static var firstRunFootnote: String { loc("firstrun.footnote", "Contacts and the call log work without an account.") }

    // MARK: banners (UI-only)
    static var bannerEngineFallback: String { loc("banner.engine.fallback", "SIP engine unavailable; using the simulated engine.") }
    static func bannerLinkFilled(_ number: String) -> String { loc("banner.link.filled", "Link opened: \(number). Press Call to dial.") }
    static var bannerNoAccount: String { loc("banner.noAccount", "Add an account before calling.") }
    static var bannerTooManyCalls: String { loc("banner.tooManyCalls", "Four calls are already in progress.") }

    // MARK: presence (screens 2, 7)
    static var presenceAvailable: String { loc("presence.available", "Available") }
    static var presenceAway: String { loc("presence.away", "Away") }
    static var presenceDND: String { loc("presence.dnd", "Do Not Disturb") }
    static var presenceOffline: String { loc("presence.offline", "Offline") }
    static var contactsMenuWatchPresence: String { loc("contacts.menu.watchPresence", "Watch Presence") }
    static var contactWatchPresence: String { loc("contact.watchPresence", "Watch presence") }
    static var menuMyStatus: String { loc("menu.myStatus", "My Status") }

    // MARK: call log additions (screen 3)
    static var logClearBodyRecordings: String { loc("calllog.clear.bodyRecordings", "Recordings stay in their folder.") }
    static var logNoteCallLimit: String { loc("calllog.note.callLimit", "Rejected: call limit") }

    // MARK: recording, conference (screens 4, 5)
    static func callRecChip(_ time: String) -> String { loc("call.rec.chip", "REC \(time)") }
    static var callRecShort: String { loc("callbar.rec", "REC") }
    static var callRecord: String { loc("call.record", "Record") }
    static var callMerge: String { loc("call.merge", "Merge") }
    static var callsInConference: String { loc("calls.row.inConference", "In conference") }
    static var callsSplit: String { loc("calls.split", "Split") }
    static func conferenceHeader(_ n: Int) -> String { loc("conference.header", "Conference · \(n) participants") }
    static var conferenceEnd: String { loc("conference.end", "End Conference") }

    // MARK: auto-answer (screens 6.5, 8.7)
    static func autoAnswerCountdown(_ seconds: Int) -> String { loc("incoming.autoAnswer.countdown", "Auto-answer in \(seconds) s") }
    static var autoAnswerCancel: String { loc("incoming.autoAnswer.cancel", "Cancel") }
    static var settingsCalls: String { loc("settings.tab.calls", "Calls") }
    static var autoAnswerMode: String { loc("settings.autoAnswer.mode", "Answer incoming calls automatically") }
    static var autoAnswerOff: String { loc("settings.autoAnswer.off", "Off") }
    static var autoAnswerAll: String { loc("settings.autoAnswer.all", "All calls") }
    static var autoAnswerContactsOnly: String { loc("settings.autoAnswer.contactsOnly", "Contacts only") }
    static var autoAnswerDelay: String { loc("settings.autoAnswer.delay", "Delay before answering") }
    static var autoAnswerHonour: String { loc("settings.autoAnswer.honourServer", "Honour the server's answer-after request") }
    static var autoAnswerHonourHelp: String {
        loc("settings.autoAnswer.honourServer.help", "Answers when the PBX sends Call-Info: answer-after=N (intercom, paging), even if the mode is Off.")
    }
    static var autoAnswerFooter: String {
        loc("settings.autoAnswer.footer", "Do Not Disturb wins over auto-answer. Auto-answer never answers a second call while you are already on one.")
    }

    // MARK: recording settings (screen 8.6)
    static var settingsRecording: String { loc("settings.tab.recording", "Recording") }
    static var recordingFolder: String { loc("settings.recording.folder", "Save recordings to") }
    static var recordingChooseFolder: String { loc("settings.recording.chooseFolder", "Choose Folder…") }
    static var recordingFolderMissing: String { loc("settings.recording.folderMissing", "Folder not found") }
    static var recordingAuto: String { loc("settings.recording.auto", "Record all calls automatically") }
    static var recordingLayout: String { loc("settings.recording.layout", "Channels") }
    static var recordingLayoutMono: String { loc("settings.recording.layout.mono", "Mono") }
    static var recordingLayoutStereo: String { loc("settings.recording.layout.stereo", "Stereo") }
    static var recordingLayoutMonoHelp: String { loc("settings.recording.layout.mono.help", "Both sides mixed into one channel.") }
    static var recordingLayoutStereoHelp: String { loc("settings.recording.layout.stereo.help", "You on the left channel, the caller on the right.") }
    static var recordingFooter: String {
        loc("settings.recording.footer", "Recordings are saved as M4A (AAC). The temporary WAV files are deleted after conversion.")
    }
    static func recordingFileName(_ sample: String) -> String { loc("settings.recording.fileName", "File name: \(sample)") }
    static var recordingShowFolder: String { loc("settings.recording.showFolder", "Show Recordings Folder") }
    static var recordingOpenFinder: String { loc("settings.recording.openFinder", "Open in Finder") }
    static func bannerRecordingKeptAsWAV(_ reason: String, _ file: String) -> String {
        loc("banner.recording.keptAsWAV", "Recording could not be converted (\(reason)). It was saved as \(file) in the recordings folder.")
    }
    static var autoAnswerServerOnly: String {
        loc("settings.autoAnswer.honourServer.note", "Only requests from your own server are honoured.")
    }
    static func logNoteText(_ code: String) -> String {
        switch code {
        case CallLogNote.callLimit: return logNoteCallLimit
        case CallLogNote.connectionLost: return logNoteConnectionLost
        case CallLogNote.busy: return logNoteBusy
        case CallLogNote.denied: return logNoteDenied
        default: return code
        }
    }

    // MARK: menu bar status, account editor additions
    static var menuStatusAvailable: String { loc("menu.status.available", "Available") }
    static var menuStatusAway: String { loc("menu.status.away", "Away") }
    static var menuStatusDND: String { loc("menu.status.dnd", "Do Not Disturb") }
    static var accountPublishPresence: String { loc("account.field.publishPresence", "Publish my presence") }
    static var accountPublishPresenceHelp: String {
        loc("account.field.publishPresence.help", "Lets contacts who watch you see Available / Away / DND.")
    }
    static var accountVerifyCertificate: String { loc("account.field.verifyCertificate", "Verify server certificate") }
    static var accountVerifyCertificateHelp: String {
        loc("account.field.verifyCertificate.help", "Turn off only for a server with a self-signed certificate.")
    }

    /// A number for display: at most one decimal, in the app's language ("0,5" in Russian).
    static func number(_ value: Double) -> String {
        let language = stringsBundle.preferredLocalizations.first ?? "en"
        return value.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: language)))
    }

    // MARK: call quality, call volume, Opus options, following new audio devices
    static func unitPercent(_ value: String) -> String { loc("unit.percent", "\(value) %") }
    static func unitMs(_ value: String) -> String { loc("unit.ms", "\(value) ms") }
    static func callQualityDetails(loss: String, jitter: String, rtt: String, mos: String) -> String {
        loc("call.quality.details", "Loss \(loss) · Jitter \(jitter) · RTT \(rtt) · MOS \(mos)")
    }
    static var callQualityGood: String { loc("call.quality.level.good", "Good connection") }
    static var callQualityFair: String { loc("call.quality.level.fair", "Fair connection") }
    static var callQualityPoor: String { loc("call.quality.level.poor", "Poor connection") }
    static func callPoorLoss(_ loss: String) -> String { loc("call.quality.poor.loss", "Poor connection: \(loss) packet loss") }
    static func callPoorJitter(_ jitter: String) -> String { loc("call.quality.poor.jitter", "Poor connection: high jitter (\(jitter))") }
    static func callPoorRTT(_ rtt: String) -> String { loc("call.quality.poor.rtt", "Poor connection: high latency (\(rtt))") }
    static func callPoorMOS(_ mos: String) -> String { loc("call.quality.poor.mos", "Poor connection: low audio quality (MOS \(mos))") }
    static var callVolume: String { loc("call.volume.title", "Call volume") }
    static var callVolumeReset: String { loc("call.volume.reset", "Reset") }
    static func bannerSpeakerVolume(_ value: String) -> String { loc("banner.volume.speaker", "Speaker volume: \(value)") }
    static var menuVolumeUp: String { loc("menu.volumeUp", "Speaker Volume Up") }
    static var menuVolumeDown: String { loc("menu.volumeDown", "Speaker Volume Down") }
    static var audioFollowDevices: String { loc("settings.audio.followNewDevices", "Switch to a headset when it is connected") }
    static var audioFollowDevicesHelp: String { loc("settings.audio.followNewDevices.help", "Uses a newly connected headset for calls until it is unplugged.") }
    static func bannerAudioSwitched(_ name: String) -> String { loc("banner.audio.switched", "Switched to \(name)") }
    static func bannerAudioBack(_ name: String) -> String { loc("banner.audio.back", "Back to \(name)") }
    static var bannerAudioBackDefault: String { loc("banner.audio.backDefault", "Back to the system default") }
    static var codecsOpusHeader: String { loc("settings.codecs.opus.header", "Opus") }
    static var codecsOpusFEC: String { loc("settings.codecs.opus.fec", "Packet-loss correction (FEC)") }
    static var codecsOpusDTX: String { loc("settings.codecs.opus.dtx", "Silence suppression (DTX)") }
    static var codecsOpusFooter: String {
        loc("settings.codecs.opus.footer", "Packet-loss correction adds a little data so lost packets can be repaired; keep it on for Wi-Fi and mobile networks. Silence suppression sends nothing during pauses to save bandwidth, but can clip the start of a word; turn it on only when bandwidth is tight.")
    }

    static var accountAdvanced: String { loc("account.group.advanced", "Advanced") }

    // MARK: network and reconnecting
    static var statusNoNetwork: String { loc("status.noNetwork", "No network") }
    static func statusAccountRetry(_ name: String, _ seconds: Int) -> String { loc("status.account.retry", "\(name) · retry in \(seconds) s") }
    static func statusAccountRetrying(_ name: String) -> String { loc("status.account.retrying", "\(name) · retrying…") }
    static var statusReconnecting: String { loc("accounts.status.reconnecting", "Reconnecting…") }
    static func callReconnecting(_ seconds: Int) -> String { loc("call.state.reconnecting", "Reconnecting… \(seconds) s") }
    static var logNoteConnectionLost: String { loc("calllog.note.connectionLost", "Connection lost") }
    static var menubarNoNetwork: String { loc("menubar.state.noNetwork.help", "No network") }

    // MARK: many accounts
    static var accountPopupSearch: String { loc("account.popup.search", "Search accounts") }
    static var accountPopupNoMatches: String { loc("account.popup.noMatches", "No matching accounts") }
    static var accountsFilter: String { loc("accounts.filter", "Filter accounts") }
    static var accountPopupHelpStatus: String { loc("status.summary.help", "Click to see all accounts") }

    // MARK: updates (ADR 0013)
    static var updatesMenuCheck: String { loc("updates.menu.check", "Check for Updates…") }
    static var updatesHeader: String { loc("updates.header", "Updates") }
    static var updatesAutomatic: String { loc("updates.automatic", "Check for updates automatically") }
    static var updatesAutomaticHelp: String { loc("updates.automatic.help", "Once a day. MacroSIP asks before installing an update.") }
    static var updatesReleaseCandidates: String { loc("updates.releaseCandidates", "Include release candidates") }
    static var updatesReleaseCandidatesHelp: String { loc("updates.releaseCandidates.help", "Test builds of the next version, offered before it is final.") }
    static var updatesCheckNow: String { loc("updates.checkNow", "Check Now") }
    static func updatesLastCheck(_ date: String) -> String { loc("updates.lastCheck", "Last checked \(date)") }
    static var updatesLastCheckNever: String { loc("updates.lastCheck.never", "Not checked yet") }
    static var updatesUnavailable: String { loc("updates.unavailable", "Updates work only in the installed app.") }
    static var quitDuringCallTitle: String { loc("quit.duringCall.title", "End the call and quit?") }
    static var quitDuringCallMessage: String { loc("quit.duringCall.message", "A call is in progress. Quitting MacroSIP ends it.") }
    static var quitDuringCallConfirm: String { loc("quit.duringCall.confirm", "End Call and Quit") }

    // MARK: 26.1 calls, timed Do Not Disturb, recording playback
    static var callsHeader: String { loc("settings.calls.duringCall.header", "During a call") }
    static var callsIncomingWhileOnCall: String { loc("settings.general.calls.incomingWhileOnCall", "When a call comes in during a call") }
    static var callsIncomingWhileOnCallHelp: String {
        loc("settings.general.calls.incomingWhileOnCall.help", "Busy answers the second caller with 486 Busy Here; you see nothing of it except in the call log.")
    }
    static var callsWaiting: String { loc("settings.general.calls.waiting", "Call waiting (tone and window)") }
    static var callsWindowOnly: String { loc("settings.general.calls.windowOnly", "Window only") }
    static var callsBusy: String { loc("settings.general.calls.busy", "Busy (single-call mode)") }
    static var callsDTMF: String { loc("settings.general.calls.dtmf", "DTMF method") }
    static var callsDTMFHelp: String { loc("settings.general.calls.dtmf.help", "Automatic uses RFC 2833 and falls back to SIP INFO.") }
    static var callsDTMFAutomatic: String { loc("settings.general.calls.dtmf.automatic", "Automatic") }
    static var callsDTMFInBand: String { loc("settings.general.calls.dtmf.inBand", "In-band") }
    static var callsBringToFront: String { loc("settings.general.calls.bringToFront", "Bring the main window to the front on an incoming call") }
    static var callsBringToFrontHelp: String { loc("settings.general.calls.bringToFront.help", "The incoming-call window still appears as well.") }
    static var dndOff: String { loc("dnd.off", "Off") }
    static var dndOn: String { loc("dnd.on", "On") }
    static var dnd30Minutes: String { loc("dnd.minutes30", "For 30 minutes") }
    static var dnd1Hour: String { loc("dnd.hour1", "For 1 hour") }
    static var dndTomorrow: String { loc("dnd.tomorrow", "Until tomorrow 9:00") }
    static func menuDNDRemaining(_ remaining: String) -> String { loc("menu.dnd.remaining", "Do Not Disturb · \(remaining)") }
    static func dndUntil(_ time: String, _ remaining: String) -> String { loc("settings.general.dnd.until", "Until \(time) · \(remaining) left") }
    static var dndHelp: String { loc("settings.general.dnd.help", "Declines incoming calls with 486 Busy Here and publishes Do Not Disturb.") }
    static func durationShort(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return loc("duration.minutes", "\(m) min") }
        if m == 0 { return loc("duration.hours", "\(h) h") }
        return loc("duration.hoursMinutes", "\(h) h \(m) min")
    }
    static var logRecordingPlay: String { loc("calllog.recording.play", "Play recording") }
    static var logRecordingPause: String { loc("calllog.recording.pause", "Pause") }
    static var logRecordingClose: String { loc("calllog.recording.close", "Close player") }
    static var logRecordingShowInFinder: String { loc("calllog.recording.showInFinder", "Show in Finder") }
    static var logRecordingFailed: String { loc("calllog.recording.failed", "The recording cannot be played.") }
    static var logRecordingPosition: String { loc("calllog.recording.position", "Playback position") }
    static var logNoteBusy: String { loc("calllog.note.busy", "Rejected: on another call") }

    // MARK: 26.2 contact card
    static var contactFavorite: String { loc("contact.favorite", "Favorite") }
    static var contactPhotoChoose: String { loc("contact.photo.choose", "Choose…") }
    static var contactPhotoRemove: String { loc("contact.photo.remove", "Remove Photo") }
    static var contactFirstName: String { loc("contact.firstName", "First name") }
    static var contactLastName: String { loc("contact.lastName", "Last name") }
    static var contactOrganization: String { loc("contact.organization", "Organization") }
    static var contactNumbersHeader: String { loc("contact.numbers.header", "Phone numbers") }
    static var contactLabelWork: String { loc("contact.label.work", "Work") }
    static var contactLabelMobile: String { loc("contact.label.mobile", "Mobile") }
    static var contactLabelHome: String { loc("contact.label.home", "Home") }
    static var contactLabelOther: String { loc("contact.label.other", "Other") }
    static var contactLabelSIP: String { loc("contact.label.sip", "SIP") }
    static var contactNumbersDefault: String { loc("contact.numbers.default", "Default") }
    static var contactNumbersAdd: String { loc("contact.numbers.add", "Add number") }
    static var contactNumbersRemove: String { loc("contact.numbers.remove", "Remove number") }
    static var contactNumbersHint: String { loc("contact.numbers.hint", "Labels: Work, Mobile, Home, Other, SIP. The default number is used by double-click, Return and presence.") }
    static var contactEmail: String { loc("contact.email", "Email") }
    static func contactAccountSub(_ name: String) -> String { loc("contact.account.sub", "Preferred account for calls to \(name).") }
    static var contactAccountSubNoName: String { loc("contact.account.subNoName", "Preferred account for calls to this contact.") }
    static var contactPresenceSub: String { loc("contact.presence.sub", "Subscribes to the default number.") }
    static var contactNotes: String { loc("contact.notes", "Notes") }
    static var contactsSectionFavorites: String { loc("contacts.section.favorites", "Favorites") }
    static func contactsMenuCallNumber(_ label: String, _ number: String) -> String { loc("contacts.menu.callNumber", "Call \(label) \(number)") }
    static var contactsMenuFavoriteAdd: String { loc("contacts.menu.favoriteAdd", "Add to Favorites") }
    static var contactsMenuFavoriteRemove: String { loc("contacts.menu.favoriteRemove", "Remove from Favorites") }
    static var settingsContactsHeader: String { loc("settings.general.contacts.header", "Contacts") }
    static var settingsContactSort: String { loc("settings.general.sort", "Sort by") }
    static var settingsContactSortFirst: String { loc("settings.general.sort.first", "First name") }
    static var settingsContactSortLast: String { loc("settings.general.sort.last", "Last name") }
    static var settingsContactSortFooter: String { loc("settings.general.sort.footer", "Names are always shown as “First Last”. Sorting by last name also groups the sections by its first letter.") }
    static func contactsMorePill(_ n: Int) -> String { "+\(n)" }
    static func contactsFavoritesCount(_ n: Int) -> String { loc("contacts.favorites.count", "\(n) favorites") }
    static func phoneLabel(_ l: PhoneLabel) -> String {
        switch l {
        case .work: return contactLabelWork
        case .mobile: return contactLabelMobile
        case .home: return contactLabelHome
        case .other: return contactLabelOther
        case .sip: return contactLabelSIP
        }
    }
    // MARK: quick keys (26.2, screen 11)
    static var quickKeysTitle: String { loc("quickkeys.title", "Quick keys") }
    static var quickKeysAdd: String { loc("quickkeys.add", "Add key…") }
    static var quickKeysAddShort: String { loc("quickkeys.add.short", "Add…") }
    static var quickKeysEdit: String { loc("quickkeys.menu.edit", "Edit…") }
    static var quickKeysRemove: String { loc("quickkeys.menu.remove", "Remove") }
    static var quickKeysShow: String { loc("quickkeys.menu.show", "Show Quick Keys") }
    static var quickKeysHide: String { loc("quickkeys.menu.hide", "Hide Quick Keys") }
    static var quickKeysRinging: String { loc("quickkeys.state.ringing", "ringing") }
    static var quickKeysBlfAvailable: String { loc("quickkeys.blf.available", "Available") }
    static var quickKeysBlfBusy: String { loc("quickkeys.blf.busy", "On the phone") }
    static var quickKeysBlfRinging: String { loc("quickkeys.blf.ringing", "Ringing") }
    static var quickKeysBlfUnknown: String { loc("quickkeys.blf.unknown", "No information") }
    static var quickKeysColumnName: String { loc("quickkeys.column.name", "Name") }
    static var quickKeysColumnNumber: String { loc("quickkeys.column.number", "Number") }
    static var quickKeysColumnType: String { loc("quickkeys.column.type", "Type") }
    static var quickKeysColumnBLF: String { loc("quickkeys.column.blf", "BLF") }
    static var quickKeysColumnKey: String { loc("quickkeys.column.key", "Key") }
    static var quickKeysRowEmpty: String { loc("quickkeys.row.empty", "Empty") }
    static func quickKeysCount(_ n: Int) -> String { loc("quickkeys.count", "\(n) of 12 keys") }
    static var quickKeysHint: String { loc("quickkeys.hint", "Drag rows to reorder. Name and Number are edited in place; double-click a row or start typing. The BLF box watches the number's line state.") }
    static var quickKeysTypeCall: String { loc("quickkeys.type.call", "Call") }
    static var quickKeysTypeDTMF: String { loc("quickkeys.type.dtmf", "DTMF") }
    static var quickKeysTypeBlind: String { loc("quickkeys.type.blindTransfer", "Blind transfer") }
    static var quickKeysTypeAttended: String { loc("quickkeys.type.attendedTransfer", "Attended transfer") }
    static var quickKeysTypeConference: String { loc("quickkeys.type.conference", "Add to conference") }
    static var quickKeysSmartCaption: String { loc("quickkeys.type.smart.caption", "Smart: call when idle, act on the call when in one") }
    static var quickKeysTypeCallBlind: String { loc("quickkeys.type.callBlind", "Call / Blind transfer") }
    static var quickKeysTypeCallAttended: String { loc("quickkeys.type.callAttended", "Call / Attended transfer") }
    static var quickKeysTypeCallConference: String { loc("quickkeys.type.callConference", "Call / Conference") }
    static var quickKeysPanelHeader: String { loc("quickkeys.panel.header", "Panel") }
    static var quickKeysPanelShow: String { loc("quickkeys.panel.show", "Show panel") }
    static var quickKeysPanelOff: String { loc("quickkeys.panel.off", "Off") }
    static var quickKeysPanelRight: String { loc("quickkeys.panel.right", "Right") }
    static var quickKeysPanelBottom: String { loc("quickkeys.panel.bottom", "Bottom") }
    static var quickKeysPanelFooter: String { loc("quickkeys.panel.footer", "Right widens the window to 560 pt; Bottom adds a 3-column strip.") }
    static var quickKeysPickupLabel: String { loc("quickkeys.pickup.label", "Pickup code") }
    static var quickKeysPickupSub: String { loc("quickkeys.pickup.sub", "Used when you click a ringing key.") }
    static var quickKeysShortcutsNote: String { loc("quickkeys.shortcuts.note", "⌘1 – ⌘9 press keys 1–9 while MacroSIP is the frontmost app, also when the panel is hidden. Keys 10–12 are clicked only. Shortcuts follow the order of the list.") }
    // MARK: quick keys, ringing line
    static func quickKeysRingingFor(_ minutes: Int) -> String { loc("quickkeys.blf.ringing.for", "Ringing · \(minutes) min") }
    // MARK: 26.2 network, codecs, incoming-call rule
    static var netRTPHeader: String { loc("settings.network.rtp.header", "RTP") }
    static var netRTPPortRange: String { loc("settings.network.rtp.portRange", "Port range") }
    static var netRTPPortRangeHelp: String { loc("settings.network.rtp.portRange.help", "Audio uses this range. Each call needs two ports; 1024–65535.") }
    static var netRTPStart: String { loc("settings.network.rtp.start", "Start") }
    static var netRTPCount: String { loc("settings.network.rtp.count", "Ports") }
    static var netRport: String { loc("settings.network.rport", "Use rport") }
    static var netRportHelp: String { loc("settings.network.rport.help", "Asks the server to reply to the address and port it sees. Helps behind NAT.") }
    static var netDNSHeader: String { loc("settings.network.dns.header", "DNS") }
    static var netDNSSRV: String { loc("settings.network.dns.srv", "Use DNS SRV records") }
    static var netDNSSRVHelp: String { loc("settings.network.dns.srv.help", "Finds the server and port of an account through SRV records, then falls back to the domain itself.") }
    static var netNameserver: String { loc("settings.network.dns.nameserver", "Nameserver") }
    static var netNameserverHelp: String { loc("settings.network.dns.nameserver.help", "Address of a DNS server. Empty uses the system's servers.") }
    static var netNameserverPlaceholder: String { loc("settings.network.dns.nameserver.placeholder", "System") }
    static var netRestartFooter: String { loc("settings.network.restartFooter", "Changes to the port range and DNS apply after a restart of the engine.") }
    static var netRestartBanner: String { loc("settings.network.restart.banner", "Network changes are waiting for a restart of the engine. Accounts register again.") }
    static var netRestartNow: String { loc("settings.network.restart.now", "Restart now") }
    static var netRestartBusy: String { loc("settings.network.restart.busy", "End your calls first.") }
    static var codecsWidebandNote: String { loc("settings.codecs.footer.wideband", "Wideband codecs (Opus, G.722, G.722.1, Speex 16 and 32 kHz) work only if the PBX supports them.") }
    static var denyHeader: String { loc("settings.general.deny.header", "Incoming calls") }
    static var denyLabel: String { loc("settings.general.deny.label", "Reject calls from") }
    static var denyHelp: String { loc("settings.general.deny.help", "A rejected call never rings. The caller gets 603 Decline and the call log shows “Rejected: rule”.") }
    static var denyNobody: String { loc("settings.general.deny.nobody", "Nobody") }
    static var denyEveryone: String { loc("settings.general.deny.everyone", "Everyone") }
    static var denyNotInContacts: String { loc("settings.general.deny.notInContacts", "Numbers not in Contacts") }
    static var denyAnonymous: String { loc("settings.general.deny.anonymous", "Anonymous callers") }
    static var logNoteDenied: String { loc("calllog.note.denied", "Rejected: rule") }
    // MARK: directory (screen 13)
    static var directoryTitle: String { loc("directory.title", "Directory") }
    static var directorySectionContacts: String { loc("directory.section.contacts", "Contacts") }
    static var directorySectionDirectory: String { loc("directory.section.directory", "Directory") }
    static func directorySearching(_ source: String) -> String { loc("directory.searching", "Searching \(source)…") }
    static var directoryNoSources: String { loc("directory.empty", "No sources") }
    static var directoryMenuCall: String { loc("directory.menu.call", "Call") }
    static var directoryMenuCopy: String { loc("directory.menu.copy", "Copy Number") }
    static var directoryMenuAdd: String { loc("directory.menu.add", "Add to Contacts") }
    static var directoryColumnSource: String { loc("directory.column.source", "Source") }
    static var directoryColumnStatus: String { loc("directory.column.status", "Status") }
    static var directoryColumnOn: String { loc("directory.column.on", "On") }
    static var directoryModeSearch: String { loc("directory.mode.search", "search only") }
    static var directoryModeImport: String { loc("directory.mode.import", "import into Contacts") }
    static var directoryStatusConnected: String { loc("directory.status.connected", "Connected") }
    static var directoryStatusSignIn: String { loc("directory.status.signin", "Sign in required") }
    static func directoryStatusSynced(_ ago: String) -> String { loc("directory.status.synced", "Synced \(ago)") }
    static var directoryStatusDenied: String { loc("directory.status.denied", "Access denied") }
    static var directoryStatusOff: String { loc("directory.status.off", "Off") }
    static var directoryErrorAccessNotRequested: String { loc("directory.error.accessNotRequested", "Contacts access has not been requested") }
    static var directoryErrorTimedOut: String { loc("directory.error.timedOut", "Timed out") }
    static var directoryErrorCancelled: String { loc("directory.error.cancelled", "Cancelled") }
    static func directoryErrorCannotConnect(_ host: String) -> String { loc("directory.error.cannotConnect", "Cannot connect to \(host)") }
    static var directoryErrorInvalidCredentials: String { loc("directory.error.invalidCredentials", "Invalid bind DN or password") }
    static func directoryErrorHTTP(_ code: Int) -> String { loc("directory.error.http", "HTTP \(code)") }
    static var directoryErrorEmptyServer: String { loc("directory.error.emptyServer", "Enter the server address") }
    static var directoryErrorBadLDAPURL: String { loc("directory.error.badLDAPURL", "The server must be ldap://host or ldaps://host") }
    static var directoryErrorBadFeedURL: String { loc("directory.error.badFeedURL", "Enter an http, https or file URL") }
    static var directoryErrorNotText: String { loc("directory.error.notText", "The file is not text") }
    static var directoryErrorNoNumberColumn: String { loc("directory.error.noNumberColumn", "No number column in the header") }
    static var directoryErrorInvalidJSON: String { loc("directory.error.invalidJSON", "The file is not valid JSON") }
    static var directoryErrorNoContactArray: String { loc("directory.error.noContactArray", "No array of contacts in the JSON") }
    static var directoryErrorUnsupported: String { loc("directory.error.unsupported", "Unsupported source") }
    static var directoryErrorNotConnected: String { loc("directory.error.notConnected", "Not connected") }
    static func directoryImportedFrom(_ source: String) -> String { loc("directory.import.note", "Imported from \(source)") }
    static var directorySourcesFooter: String { loc("directory.sources.footer", "Results are listed in this order; drag to reorder. A source that is switched off is not searched and not synced.") }
    static var directoryAddHelp: String { loc("directory.add.help", "Add source") }
    static var directoryRemoveHelp: String { loc("directory.remove.help", "Remove source") }
    static var directoryEdit: String { loc("directory.edit", "Edit…") }
    static func directoryRemoveTitle(_ name: String) -> String { loc("directory.remove.title", "Remove “\(name)”?") }
    static var directoryRemoveBody: String { loc("directory.remove.body", "Contacts already imported from this source stay in Contacts.") }
    static var directorySignInTitle: String { loc("directory.signin.title", "Access has expired or was revoked") }
    static var directorySignInSub: String { loc("directory.signin.sub", "Search skips this source until you sign in again.") }
    static var directorySignInButton: String { loc("directory.signin.button", "Sign In…") }
    static var directorySearchHeader: String { loc("directory.search.header", "Search") }
    static var directoryMinLength: String { loc("directory.search.minLength", "Minimum characters") }
    static var directoryMinLengthSub: String { loc("directory.search.minLength.sub", "Search starts after this many characters and a 300 ms pause in typing.") }
    static var directoryLookupEnable: String { loc("directory.lookup.enable", "Look up names of incoming callers") }
    static var directoryLookupSub: String { loc("directory.lookup.sub", "Asks search-only sources for at most 1 second while the call rings.") }
    static var directoryAddTitle: String { loc("directory.add.title", "Add Directory Source") }
    static var directoryEditTitle: String { loc("directory.edit.title", "Edit Directory Source") }
    static var directoryAddType: String { loc("directory.add.type", "Type") }
    static var directoryAddName: String { loc("directory.add.name", "Name") }
    static var directoryTypeLDAP: String { loc("directory.type.ldap", "LDAP") }
    static var directoryTypeURL: String { loc("directory.type.url", "URL (CSV or JSON)") }
    static var directoryTypeGoogle: String { loc("directory.type.google", "Google Contacts") }
    static var directoryTypeMacOS: String { loc("directory.type.macos", "macOS Contacts") }
    static var directoryBadgeLDAP: String { loc("directory.badge.ldap", "LDAP") }
    static var directoryBadgeURL: String { loc("directory.badge.url", "URL") }
    static var directoryBadgeGoogle: String { loc("directory.badge.google", "Google") }
    static var directoryBadgeContacts: String { loc("directory.badge.contacts", "Contacts") }
    static var directoryAddCancel: String { loc("directory.add.cancel", "Cancel") }
    static var directoryAddConfirm: String { loc("directory.add.confirm", "Add") }
    static var directoryLDAPServer: String { loc("directory.ldap.server", "Server") }
    static var directoryLDAPServerSub: String { loc("directory.ldap.server.sub", "ldaps:// or StartTLS when possible.") }
    static var directoryLDAPStartTLS: String { loc("directory.ldap.starttls", "Use StartTLS") }
    static var directoryLDAPBaseDN: String { loc("directory.ldap.baseDN", "Base DN") }
    static var directoryLDAPBindDN: String { loc("directory.ldap.bindDN", "Bind DN") }
    static var directoryLDAPBindDNSub: String { loc("directory.ldap.bindDN.sub", "Empty for anonymous search.") }
    static var directoryLDAPPassword: String { loc("directory.ldap.password", "Password") }
    static var directoryLDAPPasswordSub: String { loc("directory.ldap.password.sub", "Stored in the Keychain.") }
    static var directoryLDAPFilter: String { loc("directory.ldap.filter", "Search filter") }
    static var directoryLDAPFilterSub: String { loc("directory.ldap.filter.sub", "%s is the typed text.") }
    static var directoryResultsHeader: String { loc("directory.results.header", "Results") }
    static var directoryResultsSearch: String { loc("directory.results.search", "Search only") }
    static var directoryResultsSearchSub: String { loc("directory.results.search.sub", "results are not stored") }
    static var directoryResultsImport: String { loc("directory.results.import", "Import into Contacts") }
    static var directoryResultsImportSub: String { loc("directory.results.import.sub", "copied and refreshed daily") }
    static var directoryTest: String { loc("directory.test", "Test") }
    static var directoryTesting: String { loc("directory.test.running", "Testing…") }
    static func directoryTestSuccess(_ n: Int) -> String { loc("directory.test.success", "Connected · \(n) entries") }
    static var directoryTestConnected: String { loc("directory.test.connected", "Connected") }
    static var directoryURLURL: String { loc("directory.url.url", "URL") }
    static var directoryURLRefresh: String { loc("directory.url.refresh", "Refresh every") }
    static var directoryURLRefreshHour: String { loc("directory.url.refresh.hour", "Hour") }
    static var directoryURLRefreshHours6: String { loc("directory.url.refresh.hours6", "6 hours") }
    static var directoryURLRefreshDay: String { loc("directory.url.refresh.day", "Day") }
    static var directoryURLRefreshWeek: String { loc("directory.url.refresh.week", "Week") }
    static var directoryURLFooter: String { loc("directory.url.footer", "CSV with a header row, or a JSON array of objects. Columns named name, first name, last name, number, mobile, email are recognised.") }
    static var directoryGoogleSignIn: String { loc("directory.google.signin", "Sign in with Google") }
    static var directoryGoogleFooter: String { loc("directory.google.footer", "Opens Google in your browser once to allow read-only access to your contacts. MacroSIP keeps only the access token, in the Keychain; you can remove access in your Google Account at any time.") }
    static var directoryMacOSAllow: String { loc("directory.macos.allow", "Allow access") }
    static var directoryMacOSFooter: String { loc("directory.macos.footer", "MacroSIP asks macOS for access to Contacts when you press Allow access.") }
    static var directoryMacOSName: String { loc("directory.macos.name", "macOS Contacts") }
    static var directoryOpenPrivacy: String { loc("directory.macos.openSettings", "Open System Settings…") }
    static var directoryImportNow: String { loc("directory.import.now", "Import now") }
    static var directoryImporting: String { loc("directory.import.running", "Importing…") }
    static func directoryImported(_ n: Int) -> String { loc("directory.import.done", "Imported \(n) contacts") }
    static func directoryImportedUpdated(_ n: Int) -> String { loc("directory.import.updated", "(\(n) updated)") }
    static var directoryImportNothing: String { loc("directory.import.nothing", "Nothing to import") }
    static func directoryResultsCount(_ n: Int) -> String { loc("directory.results.count", "\(n) results") }
    static func directoryResultsSources(_ n: Int) -> String { loc("directory.results.sources", "from \(n) sources") }
    static func directoryImportFailed(_ reason: String) -> String { loc("directory.import.failed", "Import failed: \(reason)") }
    static var directorySummaryThisMac: String { loc("directory.summary.thisMac", "This Mac") }
    static var directoryGoogleAccount: String { loc("directory.google.account", "Google account") }
    static var directorySearchEnable: String { loc("directory.search.enable", "Search directories from the number field") }
    static var directoryResultsPerSource: String { loc("directory.search.limit", "Results per source") }
    static var directoryTypesFooter: String { loc("directory.add.types.footer", "Types: LDAP, URL (CSV or JSON), Google Contacts, macOS Contacts.") }
    static var directoryURLFormat: String { loc("directory.url.format", "Format") }
    static var autoAnswerHeader: String { loc("settings.autoAnswer.header", "Auto-answer") }
    static var advancedHeader: String { loc("settings.general.advanced.header", "Advanced") }

    // MARK: hold music, sound events, audio test, headset buttons (8.3), notice tone (8.6), voicemail (7.2, 9), Google sign-in (13)
    static var audioHoldMusicHeader: String { loc("settings.audio.holdMusic.header", "Hold music") }
    static var audioHoldMusicSource: String { loc("settings.audio.holdMusic.source", "Source") }
    static var audioHoldMusicBuiltIn: String { loc("settings.audio.holdMusic.builtIn", "Built-in") }
    static var audioHoldMusicOff: String { loc("settings.audio.holdMusic.off", "Off") }
    static var audioHoldMusicFooter: String { loc("settings.audio.holdMusic.footer", "The caller hears this while on hold.") }
    static func audioHoldMusicError(_ reason: String) -> String { loc("settings.audio.holdMusic.error", "The file could not be used: \(reason)") }
    static var audioSoundEventsHeader: String { loc("settings.audio.soundEvents.header", "Sound events") }
    static var audioSoundCallEvents: String { loc("settings.audio.soundEvents.callEvents", "Call connected and ended") }
    static var audioSoundKeyPress: String { loc("settings.audio.soundEvents.keyPress", "Dial pad key presses") }
    static var audioSoundVoicemail: String { loc("settings.audio.soundEvents.voicemail", "New voicemail") }
    static var audioSoundError: String { loc("settings.audio.soundEvents.error", "Registration error and lost network") }
    static var audioSoundEventsFooter: String { loc("settings.audio.soundEvents.footer", "Short beeps on the speaker; the other side never hears them.") }
    static var audioTestHeader: String { loc("settings.audio.audioTest.header", "Audio test") }
    static var audioTestRow: String { loc("settings.audio.audioTest.row", "Speaker and microphone") }
    static var audioTestHelp: String { loc("settings.audio.audioTest.help", "Test plays two notes on the speaker for 2 seconds; the meter shows the microphone.") }
    static var audioHeadsetButtons: String { loc("settings.audio.headsetButtons", "Headset buttons") }
    static func audioHeadsetConnected(_ name: String) -> String { loc("settings.audio.headsetButtons.connected", "Connected: \(name)") }
    static var audioHeadsetNone: String { loc("settings.audio.headsetButtons.none", "No headset with call controls") }
    static var recordingNoticeHeader: String { loc("settings.recording.notice.header", "Notice tone") }
    static var recordingNoticeEnable: String { loc("settings.recording.notice.enable", "Play a notice tone while recording") }
    static var recordingNoticeInterval: String { loc("settings.recording.notice.interval", "Every") }
    static func recordingNoticeFooter(_ seconds: Int) -> String { loc("settings.recording.notice.footer", "A short beep every \(seconds) seconds tells both sides that the call is recorded.") }
    static var accountGroupVoicemail: String { loc("account.group.voicemail", "Voicemail") }
    static var accountVoicemailNumber: String { loc("account.field.voicemailNumber", "Voicemail number") }
    static var accountVoicemailNumberHelp: String { loc("account.field.voicemailNumber.help", "Dialled from the menu bar and the status bar.") }
    static var accountMWI: String { loc("account.field.mwi", "Voicemail indicator (MWI)") }
    static var accountMWIHelp: String { loc("account.field.mwi.help", "Shows the number of new messages the server reports.") }
    static var menuVoicemail: String { loc("menu.voicemail", "Voicemail") }
    static func voicemailNewCount(_ n: Int) -> String { loc("voicemail.newCount", "\(n) new") }
    static var directoryErrorGoogleClientID: String { loc("directory.error.googleClientID", "Google sign-in is not configured in this build") }
    static var directoryGoogleSigningIn: String { loc("directory.google.signingIn", "Waiting for Google…") }
}
