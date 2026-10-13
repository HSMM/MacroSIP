internal import CPJSUA
import Foundation

// MARK: - Pure mapping (tested without pjsua)

enum PresenceMapping {
    /// pjsua_buddy_status as seen by MacroSIP.
    enum Basic: Sendable, Equatable { case unknown, online, offline }
    /// RPID activity of a buddy or of our own status. pjrpid knows busy and away;
    /// `onThePhone` comes from the NOTIFY body (`<rpid:on-the-phone/>`, Asterisk/FreePBX).
    enum Activity: Sendable, Equatable { case unknown, away, busy, onThePhone }

    /// Notes that mean "busy" when the activity does not say so (Asterisk sends
    /// "On the phone" with basic open; ours is "Do Not Disturb").
    static let busyNotes: Set<String> = ["on the phone", "busy", "do not disturb"]
    /// Notes that mean the contact's phone is ringing (Asterisk/FreePBX send "Ringing" with basic
    /// open and an on-the-phone/busy activity for a ringing extension; "early" and "alerting" are
    /// the dialog-state words some servers put there instead).
    static let ringingNotes: Set<String> = ["ringing", "early", "alerting"]

    /// The note as `status` and `.buddyPresence` see it: trimmed, nil when empty.
    static func cleanNote(_ note: String?) -> String? {
        guard let n = note?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return nil }
        return n
    }

    /// Watched contact -> PresenceStatus. Offline or unknown basic status, and a terminated
    /// subscription (rejected, expired, network error), are `.offline`. Online: a ringing note
    /// (case-insensitive, trimmed, `ringingNotes`) -> `.ringing`, whatever the activity; else
    /// the RPID activity: busy or on-the-phone -> `.dnd`, away -> `.away`; with no known
    /// activity a busy note (`busyNotes`) -> `.dnd`, anything else -> `.available`.
    static func status(basic: Basic, activity: Activity, note: String? = nil,
                       subscriptionTerminated: Bool) -> PresenceStatus {
        guard !subscriptionTerminated, basic == .online else { return .offline }
        let n = cleanNote(note)?.lowercased() ?? ""
        if ringingNotes.contains(n) { return .ringing }
        switch activity {
        case .busy, .onThePhone: return .dnd
        case .away: return .away
        case .unknown: return busyNotes.contains(n) ? .dnd : .available
        }
    }

    /// Our own status -> what pjsua_acc_set_online_status2 publishes (PUBLISH / NOTIFY).
    static func publication(_ status: PresenceStatus) -> (online: Bool, activity: Activity, note: String?) {
        switch status {
        case .available: return (true, .unknown, nil)
        case .away: return (true, .away, nil)
        case .dnd: return (true, .busy, "Do Not Disturb")
        // Not a status the app offers for itself; published the way Asterisk reports it.
        case .ringing: return (true, .busy, "Ringing")
        case .offline: return (false, .unknown, nil)
        }
    }

    /// The key a presence subscription is stored under and the URI given to pjsua:
    /// trimmed, `<...>` brackets dropped, scheme lower-cased, `sip:` added when there is none.
    /// nil for an empty string or a non-SIP scheme (tel:, http:...).
    static func normalizedURI(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lt = s.firstIndex(of: "<"), let gt = s[lt...].firstIndex(of: ">") {
            s = String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
        }
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("sip:") { return lower.count > 4 ? "sip:" + s.dropFirst(4) : nil }
        if lower.hasPrefix("sips:") { return lower.count > 5 ? "sips:" + s.dropFirst(5) : nil }
        // Another scheme ("tel:+1..."): pjsua only subscribes SIP URIs. "host:port" is fine.
        if lower.hasPrefix("tel:") { return nil }
        if let colon = s.firstIndex(of: ":"), !s[..<colon].contains("@"),
           s[s.index(after: colon)...].first.map({ !$0.isNumber }) ?? true {
            return nil
        }
        return "sip:" + s
    }
}

/// Sendable copy of `cpjsua_buddy_snapshot`.
struct BuddySnapshot: Sendable {
    var token: UInt64
    var uri: String
    var basic: PresenceMapping.Basic
    var activity: PresenceMapping.Activity
    var note: String
    var terminated: Bool

    /// Reads the buddy from pjsua. Must run on a pj-registered thread.
    static func read(_ id: pjsua_buddy_id) -> BuddySnapshot? {
        let p = UnsafeMutablePointer<cpjsua_buddy_snapshot>.allocate(capacity: 1)
        p.initialize(to: cpjsua_buddy_snapshot())
        defer {
            p.deinitialize(count: 1)
            p.deallocate()
        }
        guard cpjsua_buddy_snapshot_get(id, p) == PJ.success else { return nil }
        let b = p.pointee
        let basic: PresenceMapping.Basic
        switch b.status {
        case PJSUA_BUDDY_STATUS_ONLINE: basic = .online
        case PJSUA_BUDDY_STATUS_OFFLINE: basic = .offline
        default: basic = .unknown
        }
        let activity: PresenceMapping.Activity
        switch b.activity {
        case PJRPID_ACTIVITY_BUSY: activity = .busy
        case PJRPID_ACTIVITY_AWAY: activity = .away
        default: activity = .unknown
        }
        return BuddySnapshot(token: UInt64(b.token), uri: PJ.string(tuple: b.uri), basic: basic,
                             activity: activity, note: PJ.string(tuple: b.note),
                             terminated: b.sub_state == PJSIP_EVSUB_STATE_TERMINATED)
    }

    /// The token MacroSIP stored in the buddy's user data, nil for an invalid buddy.
    static func token(_ id: pjsua_buddy_id) -> UInt64? {
        guard pjsua_buddy_is_valid(id) != 0 else { return nil }
        let t = UInt64(UInt(bitPattern: pjsua_buddy_get_user_data(id)))
        return t == 0 ? nil : t
    }
}

// MARK: - Engine API

extension Engine {
    /// A watched contact: pjsua buddy id and the token in its user data (events are matched
    /// by the token, never by the URI).
    struct Buddy: Sendable {
        var id: pjsua_buddy_id
        var token: UInt64
    }

    /// Watches a contact's presence (SUBSCRIBE to `presence`, pjsua buddy). `uri` may lack
    /// the `sip:` scheme. Subscribing the same URI again is a no-op. Updates arrive as
    /// `.buddyPresence(contactURI:, status, note:)` with `contactURI` exactly as passed here (the
    /// first time); a rejected or ended subscription reports `.offline`. The subscription
    /// uses the account pjsua picks for the URI (the one whose domain matches, else the
    /// default account). Failed subscriptions are retried when that account is updated or
    /// becomes registered (pjsua itself retries after 300 s). `.invalidArgument` beyond
    /// PJSUA_MAX_BUDDIES (256). Subscriptions do not survive `stop()`.
    public func subscribePresence(uri: String) throws {
        try requireStarted()
        guard let key = PresenceMapping.normalizedURI(uri), pjsua_verify_sip_url(key) == PJ.success else {
            throw EngineError.invalidArgument("presence URI \"\(uri)\"")
        }
        guard buddies[key] == nil else { return }
        // pjsua_buddy_add asserts (aborts a debug build) when the list is full.
        let limit = cpjsua_max_buddies()
        guard pjsua_get_buddy_count() < limit else {
            throw EngineError.invalidArgument("too many presence subscriptions (limit \(limit))")
        }
        // Watch first: pjsua may report the first state from inside pjsua_buddy_add.
        let token = bridge.allocateSerial()
        bridge.watch(token: token, reportedAs: uri.trimmingCharacters(in: .whitespacesAndNewlines))
        var id = PJ.invalidID
        let status = cpjsua_buddy_add(key, token, &id)
        guard status == PJ.success else {
            bridge.unwatch(token: token)
            throw PJ.error(status, "subscribe presence of \(key)")
        }
        buddies[key] = Buddy(id: id, token: token)
    }

    /// Ends the subscription (un-SUBSCRIBE) and forgets the URI. Unknown URIs are a no-op.
    /// No `.buddyPresence` event follows for this URI. If pjsua cannot delete the buddy the
    /// subscription stays known (and watched) and the error is thrown.
    public func unsubscribePresence(uri: String) throws {
        try requireStarted()
        guard let key = PresenceMapping.normalizedURI(uri), let buddy = buddies[key] else { return }
        // pjsua_buddy_del takes the dialog lock and clears the subscription's module data,
        // so no callback for this buddy runs after it returns.
        try PJ.check(pjsua_buddy_del(buddy.id), "unsubscribe presence of \(key)")
        buddies[key] = nil
        bridge.unwatch(token: buddy.token)
    }

    /// Restarts the subscriptions pjsua sends through this account that are not active
    /// (failed or never started); active ones are left alone. Runs after `updateAccount` and
    /// when the account becomes registered.
    func refreshPresenceSubscriptions(accountIndex index: pjsua_acc_id) {
        guard isStarted, PJ.registerThread(), !buddies.isEmpty else { return }
        for (key, buddy) in buddies.sorted(by: { $0.key < $1.key }) {
            let account = key.withCString { p -> pjsua_acc_id in
                var uri = cpjsua_str(p)
                return pjsua_acc_find_for_outgoing(&uri)
            }
            guard account == index else { continue }
            // No-op when the subscription is active; subscribes at once otherwise.
            PJ.warn(pjsua_buddy_update_pres(buddy.id), "resubscribe presence of \(key)")
        }
    }

    /// Publishes our status (PUBLISH with PIDF/RPID, and NOTIFY to anyone subscribed to us)
    /// for an account that has `publishPresence`. DND publishes busy + "Do Not Disturb";
    /// offline publishes a closed basic status. Remembered and re-applied when the account
    /// is updated. Throws `.invalidArgument` for an account without `publishPresence`.
    public func publishPresence(_ status: PresenceStatus, for account: AccountID) throws {
        try requireStarted()
        guard var entry = accounts[account] else { throw EngineError.unknownAccount(account) }
        guard entry.config.publishPresence else {
            throw EngineError.invalidArgument("account \(entry.config.uri) does not publish presence")
        }
        try applyPresence(status, index: entry.index)
        entry.presence = status
        accounts[account] = entry
    }

    /// Sets the account's online status in pjsua (before registration this only stores it:
    /// pjsua sends the first PUBLISH after the registration succeeds).
    func applyPresence(_ status: PresenceStatus, index: pjsua_acc_id) throws {
        let p = PresenceMapping.publication(status)
        let activity: pjrpid_activity
        switch p.activity {
        case .unknown: activity = PJRPID_ACTIVITY_UNKNOWN
        case .away: activity = PJRPID_ACTIVITY_AWAY
        case .busy, .onThePhone: activity = PJRPID_ACTIVITY_BUSY
        }
        let rc: pj_status_t
        if let note = p.note {
            rc = note.withCString { cpjsua_acc_set_presence(index, p.online ? 1 : 0, activity, $0) }
        } else {
            rc = cpjsua_acc_set_presence(index, p.online ? 1 : 0, activity, nil)
        }
        try PJ.check(rc, "publish presence \(status.rawValue)")
    }

    /// Number of pjsua buddies (tests and diagnostics).
    func presenceSubscriptionCount() -> Int {
        guard isStarted, PJ.registerThread() else { return 0 }
        return Int(pjsua_get_buddy_count())
    }

    /// Watched URIs (normalised), sorted (tests and diagnostics).
    func presenceSubscriptions() -> [String] {
        buddies.keys.sorted()
    }

    /// Last status given to `publishPresence` for the account (tests and diagnostics).
    func publishedPresence(of id: AccountID) -> PresenceStatus? {
        accounts[id]?.presence
    }
}
