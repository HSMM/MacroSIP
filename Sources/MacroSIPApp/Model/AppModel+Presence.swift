import Foundation
import os
import MacroSIPCore

private let presenceLog = AppLog.presence

extension AppModel {
    // MARK: - Watching contacts

    /// Key for `AppModel.presence`: lower case, no scheme, no URI parameters ("102@pbx.example.com").
    static func presenceKey(_ uri: String) -> String { PresenceRegistry.key(uri) }

    /// The URI the contact is watched at: the dial string on the preferred or the default account.
    func presenceURI(for contact: Contact) -> String? {
        guard let acct = contact.preferredAccountID.flatMap(account(_:)) ?? defaultAccount else { return nil }
        guard let number = contact.defaultNumber?.value else { return nil }
        return DialString.parse(number, account: acct)?.uri
    }

    /// nil = not watched, or no answer yet.
    func presenceStatus(for contact: Contact) -> PresenceStatus? {
        guard contact.subscribePresence, let uri = presenceURI(for: contact) else { return nil }
        return presence[Self.presenceKey(uri)]
    }

    func setWatchPresence(_ on: Bool, for contact: Contact) {
        var c = contact
        c.subscribePresence = on
        saveContact(c)          // loadStores() syncs the subscriptions
    }

    /// Contacts and quick keys ask for what they watch through `setPresenceWatches(owner:uris:)`; the
    /// registry makes sure each target is subscribed once, however many owners and spellings there are, and
    /// unsubscribed when the last owner is gone.
    static let contactsOwner = "contacts"
    static let quickKeysOwner = "quickkeys"

    /// Makes the contacts' watches match the contacts that have the flag. Idempotent; called after every
    /// change of contacts or accounts and after the engine started (the quick keys follow).
    func syncPresenceSubscriptions() {
        guard engineReady else { return }
        var desired: [UUID: String] = [:]
        for c in contacts where c.subscribePresence {
            if let uri = presenceURI(for: c) { desired[c.id] = uri }
        }
        presenceSubscriptions = desired
        setPresenceWatches(owner: Self.contactsOwner, uris: Array(desired.values))
        syncQuickKeySubscriptions()
    }

    /// Replaces what `owner` watches and does the engine work that follows: subscribe targets nobody watched
    /// before, unsubscribe (and forget the status of) targets nobody watches any more.
    func setPresenceWatches(owner: String, uris: [String]) {
        guard engineReady else { return }
        let change = presenceRegistry.setWatches(owner: owner, uris: uris)
        for w in change.unsubscribe {
            presence[w.key] = nil
            quickKeys.ringing.remove(w.key)
            quickKeys.ringingSince[w.key] = nil
            quiet("unsubscribe \(w.uri)") { try await self.engine.unsubscribePresence(uri: w.uri) }
        }
        for w in change.subscribe {
            Task { @MainActor in
                do { try await self.engine.subscribePresence(uri: w.uri) }
                catch {
                    // Once per target; the engine retries by itself when the account changes.
                    if self.presenceRegistry.reportFailure(key: w.key) { presenceLog.notice("subscribe \(w.uri) failed: \(describe(error))") }
                }
            }
        }
    }

    /// Engine restarted: all subscriptions are gone.
    func resetPresence() {
        presenceSubscriptions = [:]
        presenceRegistry.reset()
        quickKeys.subscribed = [:]
        quickKeys.ringing = []
        quickKeys.ringingSince = [:]
        presence = [:]
    }

    func handlePresence(uri: String, status: PresenceStatus) {
        presence[Self.presenceKey(uri)] = status
    }

    // MARK: - My status

    /// What is published: Do Not Disturb overrides the chosen status.
    var effectivePresence: PresenceStatus {
        settings.general.doNotDisturb ? .dnd : settings.general.presenceStatus
    }

    /// Menu bar › My Status. Do Not Disturb also switches the DND setting (kept in sync).
    func setMyStatus(_ status: PresenceStatus) {
        updateSettings {
            $0.general.presenceStatus = status
            $0.general.doNotDisturb = status == .dnd
        }
    }

    /// Publishes the status on every enabled account that has "Publish my presence" on.
    func publishMyPresence(only ids: Set<AccountID>? = nil) {
        guard engineReady else { return }
        let status = effectivePresence
        for a in accounts where a.publishPresence && a.enabled && engineAccounts.contains(a.id) {
            if let ids, !ids.contains(a.id) { continue }
            quiet("publish \(status.rawValue)") { try await self.engine.publishPresence(status, for: a.id) }
        }
    }

    /// Presence is a background feature: failures (including "not supported" from an engine
    /// without it) go to the log, not to a banner.
    func quiet(_ what: String, _ body: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await body() } catch { presenceLog.notice("\(what) failed: \(describe(error))") }
        }
    }
}
