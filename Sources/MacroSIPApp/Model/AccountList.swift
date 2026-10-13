import Foundation
import MacroSIPCore

/// Lists of accounts that grow long: the filter and the order of the account pop-up.
enum AccountList {
    /// From this many accounts on, the pop-up and Settings › Accounts offer a search / filter field.
    static let searchThreshold = 8

    static func needsSearch(_ count: Int) -> Bool { count >= searchThreshold }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Name, user name, domain and registrar contain the query (case and accents ignored); an empty query matches all.
    static func matches(_ a: AccountConfig, query: String) -> Bool {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return true }
        let hay = fold([a.displayName, "\(a.username)@\(a.domain)", a.registrar ?? ""].joined(separator: " "))
        return hay.contains(q)
    }

    /// Enabled accounts first, then disabled ones; each group by name.
    static func popupOrder(_ accounts: [AccountConfig]) -> [AccountConfig] {
        func byName(_ a: AccountConfig, _ b: AccountConfig) -> Bool {
            a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
        return accounts.filter(\.enabled).sorted(by: byName) + accounts.filter { !$0.enabled }.sorted(by: byName)
    }
}
