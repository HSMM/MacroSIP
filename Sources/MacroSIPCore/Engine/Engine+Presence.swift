internal import CPJSUA
import Foundation

// MARK: - Pure mapping (tested without pjsua)

enum PresenceMapping {
    /// pjsua_buddy_status as seen by MacroSIP.
    enum Basic: Sendable, Equatable { case unknown, online, offline }
    /// RPID activity (pjrpid_activity) of a buddy or of our own status.
    enum Activity: Sendable, Equatable { case unknown, away, busy }

    /// Watched contact -> PresenceStatus. Offline or unknown basic status, and a terminated
    /// subscription (rejected, expired, network error), are `.offline`. Online maps the RPID
    /// activity: busy -> `.dnd`, away -> `.away`, anything else -> `.available`.
    static func status(basic: Basic, activity: Activity, subscriptionTerminated: Bool) -> PresenceStatus {
        guard !subscriptionTerminated, basic == .online else { return .offline }
        switch activity {
        case .busy: return .dnd
        case .away: return .away
        case .unknown: return .available
        }
    }

    /// Our own status -> what pjsua_acc_set_online_status2 publishes (PUBLISH / NOTIFY).
    static func publication(_ status: PresenceStatus) -> (online: Bool, activity: Activity, note: String?) {
        switch status {
        case .available: return (true, .unknown, nil)
        case .away: return (true, .away, nil)
        case .dnd: return (true, .busy, "Do Not Disturb")
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
    var uri: String
    var presence: PresenceStatus

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
        return BuddySnapshot(
            uri: PJ.string(tuple: b.uri),
            presence: PresenceMapping.status(basic: basic, activity: activity,
                                             subscriptionTerminated: b.sub_state == PJSIP_EVSUB_STATE_TERMINATED))
    }
}

// MARK: - Engine API

extension Engine {
    /// Watches a contact's presence (SUBSCRIBE to `presence`, pjsua buddy). `uri` may lack
    /// the `sip:` scheme. Subscribing the same URI again is a no-op. Updates arrive as
    /// `.buddyPresence(contactURI:, status)` with `contactURI` exactly as passed here (the
    /// first time); a rejected or ended subscription reports `.offline` (pjsua retries
    /// later on its own). The subscription uses the account pjsua picks for the URI (the
    /// one whose domain matches, else the default account); with no account at all nothing
    /// is sent until the next pjsua presence refresh. Subscriptions do not survive `stop()`.
    public func subscribePresence(uri: String) throws {
        try requireStarted()
        guard let key = PresenceMapping.normalizedURI(uri), pjsua_verify_sip_url(key) == PJ.success else {
            throw EngineError.invalidArgument("presence URI \"\(uri)\"")
        }
        guard buddies[key] == nil else { return }
        // Watch first: pjsua may report the first state from inside pjsua_buddy_add.
        bridge.watch(key, reportedAs: uri.trimmingCharacters(in: .whitespacesAndNewlines))
        var buddy = PJ.invalidID
        let status = cpjsua_buddy_add(key, &buddy)
        guard status == PJ.success else {
            bridge.unwatch(key)
            throw PJ.error(status, "subscribe presence of \(key)")
        }
        buddies[key] = buddy
    }

    /// Ends the subscription (un-SUBSCRIBE) and forgets the URI. Unknown URIs are a no-op.
    /// No `.buddyPresence` event follows for this URI.
    public func unsubscribePresence(uri: String) throws {
        try requireStarted()
        guard let key = PresenceMapping.normalizedURI(uri), let buddy = buddies[key] else { return }
        bridge.unwatch(key)
        buddies[key] = nil
        try PJ.check(pjsua_buddy_del(buddy), "unsubscribe presence of \(key)")
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
        case .busy: activity = PJRPID_ACTIVITY_BUSY
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
