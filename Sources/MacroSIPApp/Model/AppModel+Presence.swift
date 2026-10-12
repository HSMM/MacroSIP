import Foundation
import os
import MacroSIPCore

private let presenceLog = AppLog.presence

extension AppModel {
    // MARK: - Watching contacts

    /// Key for `AppModel.presence`: lower case, no scheme, no URI parameters ("102@pbx.example.com").
    static func presenceKey(_ uri: String) -> String {
        var s = uri.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("<"), s.hasSuffix(">") { s = String(s.dropFirst().dropLast()) }
        for scheme in ["sips:", "sip:"] where s.hasPrefix(scheme) { s.removeFirst(scheme.count); break }
        if let semicolon = s.firstIndex(of: ";") { s = String(s[..<semicolon]) }
        return s
    }

    /// The URI the contact is watched at: the dial string on the preferred or the default account.
    func presenceURI(for contact: Contact) -> String? {
        guard let acct = contact.preferredAccountID.flatMap(account(_:)) ?? defaultAccount else { return nil }
        return DialString.parse(contact.number, account: acct)?.uri
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

    /// Makes the engine's subscriptions match the contacts that have the flag. Idempotent; called
    /// after every change of contacts or accounts and after the engine started.
    func syncPresenceSubscriptions() {
        guard engineReady else { return }
        var desired: [UUID: String] = [:]
        for c in contacts where c.subscribePresence {
            if let uri = presenceURI(for: c) { desired[c.id] = uri }
        }
        let before = Set(presenceSubscriptions.values)
        let after = Set(desired.values)
        presenceSubscriptions = desired
        for uri in before.subtracting(after) {
            presence[Self.presenceKey(uri)] = nil
            quiet("unsubscribe \(uri)") { try await self.engine.unsubscribePresence(uri: uri) }
        }
        for uri in after.subtracting(before) {
            quiet("subscribe \(uri)") { try await self.engine.subscribePresence(uri: uri) }
        }
    }

    /// Engine restarted: all subscriptions are gone.
    func resetPresence() {
        presenceSubscriptions = [:]
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
