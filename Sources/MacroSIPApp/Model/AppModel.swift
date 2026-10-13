import SwiftUI
import AppKit
import MacroSIPCore

/// Single source of truth for the UI. Owns the engine, the stores and the observable state.
/// Engine calls are `Task { try await engine.x }` with errors shown as a transient banner.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let launch: LaunchOptions
    let quickKeys = QuickKeyRuntime()                        // panel state that is not a setting (screen 11)
    let directory = DirectoryRuntime()                       // directory search, statuses, import reports (screen 13)
    var isMockEngine: Bool
    @ObservationIgnored var engine: any SIPEngine
    @ObservationIgnored let accountStore: AccountStore
    @ObservationIgnored let contactStore: ContactStore
    @ObservationIgnored let callLogStore: CallLogStore
    @ObservationIgnored let settingsStore: SettingsStore
    @ObservationIgnored let vault: PasswordVault
    @ObservationIgnored let prefs: UserDefaults
    @ObservationIgnored var eventTask: Task<Void, Never>?
    @ObservationIgnored var engineAccounts: Set<AccountID> = []
    @ObservationIgnored var bannerTask: Task<Void, Never>?
    @ObservationIgnored var testWaiters: [AccountID: CheckedContinuation<AccountTestResult, Never>] = [:]
    @ObservationIgnored var testActive: Set<AccountID> = []
    @ObservationIgnored var testOutcomes: [AccountID: AccountTestResult] = [:]
    @ObservationIgnored var accountSync: Task<Void, Never>?
    @ObservationIgnored var networkRestartTask: Task<Void, Never>?
    @ObservationIgnored var syncedKnownNumbers: Set<String> = []        // what the engine last got as `CallOptions.knownNumbers`
    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored var openSettingsAction: (() -> Void)?
    @ObservationIgnored var presentedIncoming: Set<CallID> = []
    @ObservationIgnored var micChecked = false
    @ObservationIgnored var presenceSubscriptions: [UUID: String] = [:]      // contact -> URI it asks the registry to watch
    @ObservationIgnored var presenceRegistry = PresenceRegistry()            // who watches which target (contacts, quick keys); one engine subscription each
    @ObservationIgnored var recordingJobs: [CallID: RecordingJob] = [:]
    @ObservationIgnored var autoRecordTried: Set<CallID> = []
    @ObservationIgnored var autoAnswerTasks: [CallID: Task<Void, Never>] = [:]
    @ObservationIgnored var recordingStopping: Set<CallID> = []
    @ObservationIgnored var recordingFolderScope: URL?          // security-scoped access held while the folder is in use
    @ObservationIgnored let sessionStart = Date()
    @ObservationIgnored var qualityTask: Task<Void, Never>?
    @ObservationIgnored var qualityMonitor = QualityMonitor()
    @ObservationIgnored var headsetFollow = HeadsetFollow()
    @ObservationIgnored var dndTask: Task<Void, Never>?
    @ObservationIgnored var recordingByCall = RecentMap<CallID, URL>(capacity: 64)    // saved before the call's log entry exists
    @ObservationIgnored var logEntryByCall = RecentMap<CallID, UUID>(capacity: 64)    // log entry of a call that ended (its recording may still be converting)
    @ObservationIgnored let recordingResolver = RecordingLinkResolver()
    @ObservationIgnored var recordingLinksGeneration = 0
    @ObservationIgnored var recordingHeuristicCutoff = Date.distantPast     // entries before this date may be matched to recordings by file name
    @ObservationIgnored var callOptionsTask: Task<Void, Never>?
    @ObservationIgnored var clickMonitor: Any?
    @ObservationIgnored let recordingPlayer = RecordingPlayer()
    @ObservationIgnored var headsetButtons: HeadsetButtons?           // HID telephony buttons and LEDs (AppModel+Headset)
    @ObservationIgnored var headsetButtonsEnabled = true               // Settings bind it through setHeadsetButtonsEnabled(_:)
    @ObservationIgnored var lastErrorSoundAt: Date?                    // the `.error` sound plays at most once per 10 s

    // Data
    var accounts: [AccountConfig] = []
    var registration: [AccountID: RegistrationState] = [:]
    var registrationTimes: [AccountID: Date] = [:]
    /// Sorted by name (`Contact.precedes`). Change it only through `setContacts` / `saveContact` / `deleteContact`.
    var contacts: [Contact] = []
    /// Bumped whenever `contacts` changes; views key their cached sections on it.
    private(set) var contactsRevision = 0
    /// Contacts by the user part of each of their numbers (`Contact.normalize`), for `contact(forNumber:)`.
    @ObservationIgnored private var contactIndex: [String: [Contact]] = [:]
    var callLog: [CallLogEntry] = []
    var settings: AppSettings
    var devices: [AudioDevice] = []
    var calls: [CallInfo] = []
    var networkOnline = true                                 // the Mac has a usable network path
    var reconnectingSince: [CallID: Date] = [:]              // calls whose media stopped, for "Reconnecting… N s"
    var quality: [CallID: CallQuality] = [:]                 // latest sample of every connected call
    var poorWarning: [CallID: PoorReason] = [:]              // calls with the "Poor connection" banner
    var seenLogAt: Date
    var presence: [String: PresenceStatus] = [:]             // keyed by `presenceKey(_:)`
    var recordingSince: [CallID: Date] = [:]                 // calls being recorded, for the REC chip
    var autoAnswer: [CallID: AutoAnswerCountdown] = [:]      // calls that will be answered by themselves
    var conferenceSince: Date?                               // when the running conference was formed
    var recordingFolderURL = RecordingFileName.defaultFolder    // resolved once, see refreshRecordingFolder()
    var savedRecordings: [URL] = []                          // finished M4A files of this session
    var incomingKeyGuard = false                             // main window brought forward by a call: keys are ignored until the user clicks into it
    var playerEntry: UUID?                                   // the call-log entry whose inline player is open
    var recordingLinks: [UUID: URL] = [:]                    // call-log entries whose recording file exists
    var voicemail: [AccountID: VoicemailState] = [:]         // message-summary indicator per account (`.voicemail` events)

    // UI state
    var banner: Banner?
    var tab: MainTab = .dialpad
    var dialText = ""
    var selectedAccountID: AccountID?
    var showKeypad = false
    var dtmfSent = ""
    var transfer: TransferContext?
    var micDenied = false
    var engineReady = false
    /// `applyNetworkSettings` said `.needsRestart`: Settings › Network offers "Restart now".
    var networkRestartNeeded = false
    var settingsTab: SettingsTab = .general
    var settingsSelectedAccount: AccountID?
    var mainEditor: AccountEditorRequest?
    var settingsEditor: AccountEditorRequest?
    var ringtoneSilenced: Set<CallID> = []
    var generalAdvancedOpen = false     // Settings › General › Advanced, remembered for the session
    var accountAdvancedOpen = false     // the editor's Advanced section, remembered for the session
    var callVolumeShown = false     // the call-volume popover (demo state opens it)
    var focusContactsSearch = 0     // bumped by Command-F
    var loginItemNeedsApproval = false      // SMAppService.mainApp.status == .requiresApproval
    var loginItemError: String?             // why macOS refused to (un)register the login item
    var headsetButtonsDevice: String?       // name of the connected headset with call-control buttons; nil = none (read-only for views)
    var holdMusicError: String?             // why the engine refused the hold music file (Settings › Audio)

    private init() {
        let launch = LaunchOptions.current
        self.launch = launch
        let dir = launch.dataDirectory ?? JSONStore<[Contact]>.appSupportDirectory()
        if let d = launch.dataDirectory {
            // Demo launches always start from scratch (only inside the temporary directory).
            if launch.isDemo, d.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                try? FileManager.default.removeItem(at: d)
            }
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        if launch.isDemo, let suite = UserDefaults(suiteName: "com.hsmm.macrosip.demo") {
            suite.removePersistentDomain(forName: "com.hsmm.macrosip.demo")
            prefs = suite
            vault = PasswordVault(inMemory: true)
        } else {
            prefs = .standard
            vault = PasswordVault(inMemory: false)
        }
        accountStore = AccountStore(directory: dir)
        contactStore = ContactStore(directory: dir)
        callLogStore = CallLogStore(directory: dir, contacts: contactStore)
        settingsStore = SettingsStore(directory: dir)
        isMockEngine = launch.mockEngine
        engine = EngineFactory.make(useMock: launch.mockEngine)
        #if DEBUG
        if launch.isDemo { DemoState.seed(stores: (accountStore, contactStore, callLogStore, settingsStore), vault: vault) }
        #endif
        settings = settingsStore.load()
        seenLogAt = (prefs.object(forKey: "seenLogAt") as? Date) ?? .distantPast
        // From the first launch with playback on, only recordings stored in an entry are linked; older entries
        // (whose recordings were saved before entries remembered them) are matched by file name.
        if let cutoff = prefs.object(forKey: "recordingLinksCutoff") as? Date { recordingHeuristicCutoff = cutoff }
        else { recordingHeuristicCutoff = Date(); prefs.set(recordingHeuristicCutoff, forKey: "recordingLinksCutoff") }
        loadStores()
        refreshRecordingFolder()
    }

    // MARK: - Derived state

    var appName: String { Product.name }

    var enabledAccounts: [AccountConfig] { accounts.filter(\.enabled) }
    /// The default for outgoing calls among the enabled accounts: the flagged one, else the first.
    var defaultAccount: AccountConfig? {
        enabledAccounts.first(where: \.isDefaultOutgoing) ?? enabledAccounts.first
    }
    /// Account the next call goes out on: the picked one if it is still enabled, else the default.
    var effectiveAccount: AccountConfig? {
        selectedAccountID.flatMap(account(_:)).flatMap { $0.enabled ? $0 : nil } ?? defaultAccount
    }
    var hasAccounts: Bool { !accounts.isEmpty }

    var ringingCalls: [CallInfo] { calls.filter(\.isRinging) }
    var incomingCall: CallInfo? { ringingCalls.first }
    var liveCalls: [CallInfo] { calls.filter { !$0.isRinging && $0.isLive } }
    var activeCall: CallInfo? { liveCalls.first { !$0.isHeldCall } }
    var activeCalls: [CallInfo] { liveCalls.filter { !$0.isHeldCall } }
    var conferenceCalls: [CallInfo] { liveCalls.filter(\.inConference) }
    var currentCall: CallInfo? { activeCall ?? liveCalls.first }
    var heldCount: Int { liveCalls.filter(\.isHeldCall).count }
    var hasCallActivity: Bool { !calls.isEmpty }

    var missedUnseen: Int { callLog.filter { $0.direction == .missed && $0.startedAt > seenLogAt }.count }
    var doNotDisturb: Bool { settings.general.doNotDisturb }
    /// When the running timed Do Not Disturb ends; nil = off or until switched off.
    var doNotDisturbUntil: Date? { settings.general.doNotDisturb ? settings.general.doNotDisturbUntil : nil }
    var anyRegistered: Bool {
        enabledAccounts.contains { if case .registered = registration[$0.id] { return true } else { return false } }
    }
    var lastDialedNumber: String? { callLog.first { $0.direction == .outgoing }?.remoteNumber }

    func account(_ id: AccountID) -> AccountConfig? { accounts.first { $0.id == id } }
    func accountName(_ id: AccountID) -> String { account(id)?.displayName ?? "?" }

    /// The contact that has `number` among any of its numbers (spaces, dashes and brackets ignored).
    func contact(forNumber number: String) -> Contact? {
        let user = Contact.normalize(number)
        guard !user.isEmpty, let candidates = contactIndex[user] else { return nil }
        return Contact.find(number: number, in: candidates)
    }

    func setContacts(_ list: [Contact]) {
        contacts = list.sorted(by: Contact.precedes)
        contactsRevision &+= 1
        var index: [String: [Contact]] = [:]
        for c in contacts { for key in Set(c.allNormalizedNumbers) { index[key, default: []].append(c) } }
        contactIndex = index
        syncKnownNumbers()
    }

    func contact(for remote: RemoteParty) -> Contact? { contact(forNumber: remote.number) }

    func contact(for entry: CallLogEntry) -> Contact? {
        if let id = entry.contactID, let c = contacts.first(where: { $0.id == id }) { return c }
        return contact(forNumber: entry.remoteNumber)
    }

    func name(for remote: RemoteParty) -> String {
        if let c = contact(forNumber: remote.number) { return c.displayName }
        if let n = resolvedRemoteName(remote), !n.isEmpty { return n }
        return remote.number.isEmpty ? remote.uri : remote.number
    }

    func name(for entry: CallLogEntry) -> String {
        if let c = contact(for: entry) { return c.displayName }
        if let n = entry.remoteDisplayName, !n.isEmpty { return n }
        return entry.remoteNumber
    }

    func dot(for account: AccountConfig) -> RegistrationDot {
        guard account.enabled, account.registerWithServer else { return .off }
        switch registration[account.id] ?? .unregistered {
        case .registered: return .registered
        case .failed: return .failed
        case .registering, .unregistered, .reconnecting: return .registering
        }
    }

    // MARK: - Loading

    func loadStores() {
        var list = accountStore.all()
        let order = (prefs.stringArray(forKey: "accountOrder") ?? []).compactMap(UUID.init(uuidString:))
        list.sort { a, b in
            let ia = order.firstIndex(of: a.id.raw) ?? Int.max
            let ib = order.firstIndex(of: b.id.raw) ?? Int.max
            return ia < ib
        }
        accounts = list
        setContacts(contactStore.all())
        callLog = callLogStore.all()
        if let sel = selectedAccountID, account(sel)?.enabled != true { selectedAccountID = nil }
    }

    func reloadCallLog() {
        callLog = callLogStore.all()
        refreshRecordingLinks()
    }

    // MARK: - Banner

    func showBanner(_ text: String, isError: Bool = true, seconds: Double = 6) {
        let b = Banner(text: text, isError: isError)
        banner = b
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            if self?.banner?.id == b.id { self?.banner = nil }
        }
    }

    func report(_ error: Error) {
        AppLog.app.error(describe(error))
        showBanner(describe(error))
    }

    /// Runs an engine operation off the call stack of the view; failures become a banner.
    func run(_ body: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await body() } catch { report(error) }
        }
    }
}

/// Passwords live only in Keychain. `inMemory` is used by the demo launch modes so that no
/// Keychain item is created or read.
final class PasswordVault: @unchecked Sendable {
    private let keychain = Keychain()
    private let inMemory: Bool
    private var memory: [AccountID: String] = [:]
    private let lock = NSLock()

    init(inMemory: Bool) { self.inMemory = inMemory }

    func set(_ password: String, for id: AccountID) throws {
        if inMemory { lock.lock(); memory[id] = password; lock.unlock(); return }
        try keychain.setPassword(password, for: id)
    }

    func password(for id: AccountID) -> String? {
        if inMemory { lock.lock(); defer { lock.unlock() }; return memory[id] }
        return (try? keychain.password(for: id)) ?? nil
    }

    func delete(for id: AccountID) throws {
        if inMemory { lock.lock(); memory[id] = nil; lock.unlock(); return }
        try keychain.deletePassword(for: id)
    }
}
