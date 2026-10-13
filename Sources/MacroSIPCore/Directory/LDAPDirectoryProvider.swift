import CLDAP
import Foundation

/// An LDAP directory (OpenLDAP, Active Directory, FreeIPA…) through the system libldap: ldap://, ldaps://
/// and StartTLS, simple bind (anonymous when the bind DN is empty; the password comes from the Keychain),
/// subtree searches under the base DN with the source's filter, 3 s per request (connect, bind and search
/// together; 30 s for an import). Each request opens its own connection; at most two run at a time, and a
/// request whose caller gave up is not started. Paged results are not used: the server's size limit applies
/// to imports.
public struct LDAPDirectoryProvider: DirectoryProvider {
    public let sourceID: UUID
    let config: LDAPConfig
    private let password: @Sendable () -> String?
    /// Connect, bind and search limit of search, lookup and test.
    let timeout: TimeInterval
    /// Limit of `allEntries` (an import may be large).
    let importTimeout: TimeInterval

    public init(source: DirectorySource, credentials: DirectoryCredentials, timeout: TimeInterval = 3) {
        let id = source.id
        self.init(source: source, timeout: timeout, password: { try? credentials.ldapPassword(for: id) })
    }

    init(source: DirectorySource, timeout: TimeInterval = 3, importTimeout: TimeInterval = 30, password: @escaping @Sendable () -> String?) {
        sourceID = source.id
        config = source.ldap ?? LDAPConfig()
        self.password = password
        self.timeout = timeout
        self.importTimeout = importTimeout
    }

    // MARK: DirectoryProvider

    public func search(_ query: String, limit: Int) async throws -> [DirectoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, limit > 0 else { return [] }
        let filter = LDAPFilter.substitute(config.searchFilter, query: q)
        let found = try await records(filter: filter, sizeLimit: limit * 2 + 5)
        return Array(found.compactMap(entry).prefix(limit))
    }

    public func lookup(number: String) async throws -> DirectoryEntry? {
        let digits = DirectoryNumber.digits(number)
        guard !digits.isEmpty else { return nil }
        // Servers compare telephone numbers ignoring spaces and dashes but not brackets or a different
        // prefix, so ask for the last four digits and compare here.
        let tail = LDAPFilter.escape(String(digits.suffix(4)))
        let a = config.attributes
        let filter = "(|(\(a.phone)=*\(tail)*)(\(a.mobile)=*\(tail)*))"
        let entries = try await records(filter: filter, sizeLimit: 50).compactMap(entry)
        return DirectoryIndex(entries).lookup(number)
    }

    public func test() async throws -> DirectoryTestResult {
        let request = try makeRequest(timeout: timeout)
        let base = config.baseDN
        let a = config.attributes
        let count: Int? = try await LDAPClient.run(request) { session in
            _ = try session.search(base: base, scope: Int32(CLDAP_SCOPE_BASE), filter: "(objectClass=*)", attributes: ["1.1"], sizeLimit: 1)
            return try? session.search(base: base, scope: Int32(CLDAP_SCOPE_SUBTREE), filter: "(|(\(a.phone)=*)(\(a.mobile)=*))",
                                       attributes: ["1.1"], sizeLimit: 1000).count
        }
        return .connected(entries: count)
    }

    public func allEntries() async throws -> [DirectoryEntry] {
        let a = config.attributes
        return try await records(filter: "(|(\(a.phone)=*)(\(a.mobile)=*))", sizeLimit: 0, timeout: importTimeout).compactMap(entry)
    }

    // MARK: Helpers

    private var attributeList: [String] {
        let a = config.attributes
        var seen = Set<String>()
        return [a.name, a.phone, a.mobile, a.email, a.organization].filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private func makeRequest(timeout: TimeInterval) throws -> LDAPClient.Request {
        let endpoint = try LDAPClient.endpoint(server: config.server, port: config.port)
        let dn = config.bindDN.trimmingCharacters(in: .whitespacesAndNewlines)
        return LDAPClient.Request(endpoint: endpoint, startTLS: config.startTLS, bindDN: dn,
                                  password: dn.isEmpty ? nil : password(), timeout: timeout)
    }

    private func records(filter: String, sizeLimit: Int, timeout: TimeInterval? = nil) async throws -> [LDAPRecord] {
        let request = try makeRequest(timeout: timeout ?? self.timeout)
        let base = config.baseDN
        let attrs = attributeList
        return try await LDAPClient.run(request) { session in
            try session.search(base: base, scope: Int32(CLDAP_SCOPE_SUBTREE), filter: filter, attributes: attrs, sizeLimit: sizeLimit)
        }
    }

    func entry(_ r: LDAPRecord) -> DirectoryEntry? {
        let a = config.attributes
        var numbers: [PhoneNumber] = []
        func add(_ attr: String, _ label: PhoneLabel) {
            for v in r.attributes[attr] ?? [] {
                let s = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty, !numbers.contains(where: { $0.value == s }) {
                    numbers.append(PhoneNumber(label: label, value: s, isDefault: numbers.isEmpty))
                }
            }
        }
        add(a.phone, .work)
        add(a.mobile, .mobile)
        guard !numbers.isEmpty else { return nil }
        let org = r.first(a.organization)
        let name = r.first(a.name) ?? org ?? numbers[0].value
        return DirectoryEntry(id: r.dn, sourceID: sourceID, sourceKind: .ldap, displayName: name, numbers: numbers,
                              organization: org, email: r.first(a.email))
    }
}

/// RFC 4515 filter strings.
public enum LDAPFilter {
    /// Escapes `*`, `(`, `)`, `\` and NUL so typed text is matched literally.
    public static func escape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "*": out += "\\2a"
            case "(": out += "\\28"
            case ")": out += "\\29"
            case "\\": out += "\\5c"
            case "\0": out += "\\00"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    /// `template` with every `%s` replaced by the escaped query; wrapped in parentheses when it is not.
    public static func substitute(_ template: String, query: String) -> String {
        var t = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { t = LDAPConfig.defaultFilter }
        if !t.hasPrefix("(") { t = "(\(t))" }
        return t.replacingOccurrences(of: "%s", with: escape(query))
    }
}
