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
    static func statusSummary(_ ok: Int, _ total: Int) -> String {
        loc("status.summary", "\(ok)/\(total) registered")
    }
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
    static var contactName: String { loc("contact.field.name", "Name") }
    static var contactNumber: String { loc("contact.field.number", "Number") }
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
    static var contactWatchPresence: String { loc("contact.watchPresence", "Watch presence (subscribe)") }
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
    static var settingsAutoAnswer: String { loc("settings.tab.autoAnswer", "Auto-answer") }
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
    static var recordingLayoutMono: String { loc("settings.recording.layout.mono", "Mono (mixed)") }
    static var recordingLayoutStereo: String { loc("settings.recording.layout.stereo", "Stereo: me left, caller right") }
    static var recordingFooter: String {
        loc("settings.recording.footer", "Recordings are saved as M4A (AAC), mono or stereo with you on the left channel and the caller on the right. The temporary WAV files are deleted after conversion.")
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
}
