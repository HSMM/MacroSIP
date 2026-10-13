import Foundation
import Observation
import Sparkle

/// In-app updates (ADR 0013): a thin wrapper over Sparkle's standard updater controller.
///
/// The feed URL, the public EdDSA key and the daily check come from Info.plist (`SUFeedURL`,
/// `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`, written by
/// scripts/make-app.sh). Release candidates are appcast items on the `beta` channel; they are
/// offered only when "Include release candidates" is on.
///
/// Calls come first: a scheduled update found during a call is not shown until every call has
/// ended (gentle reminder), and "Install and Relaunch" chosen during a call waits for the calls to end.
///
/// The updater does not start for `--mock-engine` and demo launches, nor outside an .app bundle
/// (`swift run`), where there is no feed URL; the Settings group then explains that updates work
/// only in the installed app.
@MainActor @Observable
final class Updater: NSObject {
    static let shared = Updater()

    /// UserDefaults key of the "Include release candidates" toggle.
    nonisolated static let includeReleaseCandidatesKey = "updates.includeReleaseCandidates"
    /// The appcast channel that carries release candidates (`-rc.` tags).
    nonisolated static let releaseCandidateChannel = "beta"

    private(set) var isRunning = false
    private(set) var canCheck = false
    private(set) var lastCheck: Date?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// Sparkle's continuation for a relaunch postponed until the calls end.
    @ObservationIgnored private var pendingRelaunch: (() -> Void)?
    /// A scheduled update found during a call, to be shown when the calls end.
    @ObservationIgnored private var pendingReminder = false

    private override init() { super.init() }

    /// Starts the updater once, from `applicationDidFinishLaunching`.
    func start() {
        guard controller == nil else { return }
        let launch = LaunchOptions.current
        guard !launch.mockEngine, !launch.isDemo else {
            AppLog.app.info("updates: updater not started (mock engine or demo launch)")
            return
        }
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            AppLog.app.info("updates: not running from an app bundle with a feed URL; updater not started")
            return
        }
        UserDefaults.standard.register(defaults: [Self.includeReleaseCandidatesKey: Self.runningReleaseCandidate])
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        isRunning = true
        let updater = controller.updater
        // KVO handlers are @Sendable and may run off the main thread: hop to the main actor.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                let value = updater.canCheckForUpdates
                Task { @MainActor in self?.canCheck = value }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] updater, _ in
                let value = updater.lastUpdateCheckDate
                Task { @MainActor in self?.lastCheck = value }
            },
        ]
        observeContinuously { [weak self] in
            let busy = AppModel.shared.hasLiveCalls
            self?.callsChanged(busy: busy)
        }
        AppLog.app.info("updates: updater started, automatic checks \(updater.automaticallyChecksForUpdates ? "on" : "off"), release candidates \(includeReleaseCandidates ? "on" : "off")")
    }

    /// "Check for Updates…" and "Check Now": Sparkle shows its own progress and result windows.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Sparkle keeps this setting in the app's defaults (`SUEnableAutomaticChecks`).
    var automaticallyChecks: Bool {
        get {
            access(keyPath: \.automaticallyChecks)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecks) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var includeReleaseCandidates: Bool {
        get {
            access(keyPath: \.includeReleaseCandidates)
            return Self.storedIncludeReleaseCandidates
        }
        set {
            withMutation(keyPath: \.includeReleaseCandidates) {
                UserDefaults.standard.set(newValue, forKey: Self.includeReleaseCandidatesKey)
            }
        }
    }

    /// The last call ended: run a postponed relaunch, or bring a held-back update into view.
    private func callsChanged(busy: Bool) {
        guard !busy else { return }
        if let relaunch = pendingRelaunch {
            pendingRelaunch = nil
            pendingReminder = false
            AppLog.app.info("updates: calls ended; relaunching to finish the update")
            relaunch()
        } else if pendingReminder {
            pendingReminder = false
            AppLog.app.info("updates: calls ended; showing the update found during a call")
            controller?.checkForUpdates(nil)
        }
    }

    /// A release-candidate build (26.1.0-rc.1) offers release candidates until the owner turns that off.
    private nonisolated static var runningReleaseCandidate: Bool {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return version.contains("-rc.")
    }

    private nonisolated static var storedIncludeReleaseCandidates: Bool {
        UserDefaults.standard.object(forKey: includeReleaseCandidatesKey) as? Bool ?? runningReleaseCandidate
    }

    /// Sparkle calls its delegates on the main thread; this keeps that assumption checked and safe.
    private nonisolated static func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }
}

extension Updater: SPUUpdaterDelegate {
    /// Items without a channel are always offered; `beta` items only when release candidates are on.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Self.storedIncludeReleaseCandidates ? [Self.releaseCandidateChannel] : []
    }

    /// "Install and Relaunch" during a call: install after the last call ends.
    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        nonisolated(unsafe) let handler = installHandler
        return Self.onMain {
            guard AppModel.shared.hasLiveCalls else { return false }
            Updater.shared.pendingRelaunch = handler
            AppLog.app.info("updates: relaunch postponed until the calls end")
            return true
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let text = error.localizedDescription
        Task { @MainActor in AppLog.app.notice("updates: check ended: \(text)") }
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled update never interrupts a call; it is shown when the calls end.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                         andInImmediateFocus immediateFocus: Bool) -> Bool {
        Self.onMain { !AppModel.shared.hasLiveCalls }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        Task { @MainActor in
            Updater.shared.pendingReminder = true
            AppLog.app.info("updates: \(version) found during a call; shown when the calls end")
            // The call may have ended in the meantime.
            Updater.shared.callsChanged(busy: AppModel.shared.hasLiveCalls)
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in Updater.shared.pendingReminder = false }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in Updater.shared.pendingReminder = false }
    }
}
