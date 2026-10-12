import SwiftUI
import AppKit
import MacroSIPCore

/// Single source of truth for the UI. Owns the engine, the stores and the observable state.
/// Engine calls are `Task { try await engine.x }` with errors shown as a transient banner.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let launch: LaunchOptions
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
    @ObservationIgnored var networkRestartTask: Task<Void, Never>?
    @ObservationIgnored var networkRestartPending = false
    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored var openSettingsAction: (() -> Void)?
    @ObservationIgnored var presentedIncoming: Set<CallID> = []
    @ObservationIgnored var micChecked = false
    @ObservationIgnored var presenceSubscriptions: [UUID: String] = [:]      // contact -> URI handed to the engine
    @ObservationIgnored var recordingJobs: [CallID: RecordingJob] = [:]
    @ObservationIgnored var autoRecordTried: Set<CallID> = []
    @ObservationIgnored var autoAnswerTasks: [CallID: Task<Void, Never>] = [:]
    @ObservationIgnored var recordingStopping: Set<CallID> = []
    @ObservationIgnored var recordingFolderScope: URL?          // security-scoped access held while the folder is in use
    @ObservationIgnored let sessionStart = Date()

    // Data
    var accounts: [AccountConfig] = []
    var registration: [AccountID: RegistrationState] = [:]
    var registrationTimes: [AccountID: Date] = [:]
    var contacts: [Contact] = []
    var callLog: [CallLogEntry] = []
    var settings: AppSettings
    var devices: [AudioDevice] = []
    var calls: [CallInfo] = []
    var seenLogAt: Date
    var presence: [String: PresenceStatus] = [:]             // keyed by `presenceKey(_:)`
    var recordingSince: [CallID: Date] = [:]                 // calls being recorded, for the REC chip
    var autoAnswer: [CallID: AutoAnswerCountdown] = [:]      // calls that will be answered by themselves
    var conferenceSince: Date?                               // when the running conference was formed
    var recordingFolderURL = RecordingFileName.defaultFolder    // resolved once, see refreshRecordingFolder()
    var savedRecordings: [URL] = []                          // finished M4A files of this session

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
    var settingsTab: SettingsTab = .general
    var settingsSelectedAccount: AccountID?
    var mainEditor: AccountEditorRequest?
    var settingsEditor: AccountEditorRequest?
    var ringtoneSilenced: Set<CallID> = []
    var focusContactsSearch = 0     // bumped by Command-F

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
        loadStores()
        refreshRecordingFolder()
    }

    // MARK: - Derived state

    var appName: String { Product.name }

    var enabledAccounts: [AccountConfig] { accounts.filter(\.enabled) }
    var defaultAccount: AccountConfig? { accounts.first(where: \.isDefaultOutgoing) ?? accounts.first }
    var effectiveAccount: AccountConfig? {
        selectedAccountID.flatMap(account(_:)) ?? defaultAccount
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
    var anyRegistered: Bool {
        accounts.contains { if case .registered = registration[$0.id] { return true } else { return false } }
    }
    var lastDialedNumber: String? { callLog.first { $0.direction == .outgoing }?.remoteNumber }

    func account(_ id: AccountID) -> AccountConfig? { accounts.first { $0.id == id } }
    func accountName(_ id: AccountID) -> String { account(id)?.displayName ?? "?" }

    func contact(forNumber number: String) -> Contact? {
        let n = Contact.normalize(number)
        guard !n.isEmpty else { return nil }
        return contacts.first { $0.normalizedNumber == n }
    }

    func name(for remote: RemoteParty) -> String {
        if let c = contact(forNumber: remote.number) { return c.name }
        if let n = remote.displayName, !n.isEmpty { return n }
        return remote.number.isEmpty ? remote.uri : remote.number
    }

    func name(for entry: CallLogEntry) -> String {
        if let id = entry.contactID, let c = contacts.first(where: { $0.id == id }) { return c.name }
        if let c = contact(forNumber: entry.remoteNumber) { return c.name }
        if let n = entry.remoteDisplayName, !n.isEmpty { return n }
        return entry.remoteNumber
    }

    func dot(for account: AccountConfig) -> RegistrationDot {
        guard account.enabled else { return .off }
        switch registration[account.id] ?? .unregistered {
        case .registered: return .registered
        case .failed: return .failed
        case .registering, .unregistered: return .registering
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
        contacts = contactStore.all().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        callLog = callLogStore.all()
        if let sel = selectedAccountID, account(sel) == nil { selectedAccountID = nil }
    }

    func reloadCallLog() { callLog = callLogStore.all() }

    // MARK: - Banner

    func showBanner(_ text: String, isError: Bool = true) {
        let b = Banner(text: text, isError: isError)
        banner = b
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            if self?.banner?.id == b.id { self?.banner = nil }
        }
    }

    func report(_ error: Error) { showBanner(describe(error)) }

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
