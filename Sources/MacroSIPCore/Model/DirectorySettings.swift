import Foundation

/// Settings › Directory (SCREENS.md 13): where the number field looks up people besides the local Contacts.
/// Passwords and tokens are never here; they live in the Keychain (`DirectoryCredentials`).

public enum DirectorySourceKind: String, Codable, CaseIterable, Sendable {
    case macContacts, ldap, url, google
}

public struct DirectorySource: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: DirectorySourceKind
    public var name: String
    public var isEnabled: Bool
    /// false = search only (results are not stored); true = copied into Contacts and refreshed.
    public var importIntoContacts: Bool
    public var ldap: LDAPConfig?
    public var url: URLConfig?
    public var google: GoogleConfig?

    public init(
        id: UUID = UUID(),
        kind: DirectorySourceKind,
        name: String = "",
        isEnabled: Bool = true,
        importIntoContacts: Bool? = nil,
        ldap: LDAPConfig? = nil,
        url: URLConfig? = nil,
        google: GoogleConfig? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.isEnabled = isEnabled
        // macOS Contacts defaults to import (mockup row "This Mac · import into Contacts"), the others to search only.
        self.importIntoContacts = importIntoContacts ?? (kind == .macContacts)
        self.ldap = ldap ?? (kind == .ldap ? LDAPConfig() : nil)
        self.url = url ?? (kind == .url ? URLConfig() : nil)
        self.google = google ?? (kind == .google ? GoogleConfig() : nil)
    }

    /// Server, URL, account or "This Mac": the second line of the source list.
    public var address: String {
        switch kind {
        case .macContacts: return "This Mac"
        case .ldap: return ldap?.server ?? ""
        case .url: return url?.url ?? ""
        case .google: return google?.accountEmail ?? ""
        }
    }

    private enum CodingKeys: String, CodingKey { case id, kind, name, isEnabled, importIntoContacts, ldap, url, google }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(DirectorySourceKind.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        importIntoContacts = try c.decodeIfPresent(Bool.self, forKey: .importIntoContacts) ?? (kind == .macContacts)
        ldap = (try? c.decodeIfPresent(LDAPConfig.self, forKey: .ldap)) ?? (kind == .ldap ? LDAPConfig() : nil)
        url = (try? c.decodeIfPresent(URLConfig.self, forKey: .url)) ?? (kind == .url ? URLConfig() : nil)
        google = (try? c.decodeIfPresent(GoogleConfig.self, forKey: .google)) ?? (kind == .google ? GoogleConfig() : nil)
    }
}

// MARK: - LDAP

public struct LDAPConfig: Codable, Equatable, Sendable {
    public static let defaultFilter = "(|(cn=*%s*)(sn=*%s*)(telephoneNumber=*%s*))"

    /// `ldap://host[:port]` or `ldaps://host[:port]`; a bare host name means `ldap://`.
    public var server: String
    /// nil = from the URL, else 389 (ldap) / 636 (ldaps).
    public var port: Int?
    /// Upgrade an `ldap://` connection with StartTLS (fails if the server refuses). Ignored for `ldaps://`.
    public var startTLS: Bool
    public var baseDN: String
    /// Empty = anonymous. The password is in the Keychain under the source id.
    public var bindDN: String
    /// `%s` is replaced by the typed text (RFC 4515-escaped).
    public var searchFilter: String
    public var attributes: LDAPAttributeMap

    public init(server: String = "", port: Int? = nil, startTLS: Bool = false, baseDN: String = "", bindDN: String = "",
                searchFilter: String = LDAPConfig.defaultFilter, attributes: LDAPAttributeMap = LDAPAttributeMap()) {
        self.server = server
        self.port = port
        self.startTLS = startTLS
        self.baseDN = baseDN
        self.bindDN = bindDN
        self.searchFilter = searchFilter
        self.attributes = attributes
    }

    private enum CodingKeys: String, CodingKey { case server, port, startTLS, baseDN, bindDN, searchFilter, attributes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        server = try c.decodeIfPresent(String.self, forKey: .server) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        startTLS = try c.decodeIfPresent(Bool.self, forKey: .startTLS) ?? false
        baseDN = try c.decodeIfPresent(String.self, forKey: .baseDN) ?? ""
        bindDN = try c.decodeIfPresent(String.self, forKey: .bindDN) ?? ""
        let filter = try c.decodeIfPresent(String.self, forKey: .searchFilter) ?? ""
        searchFilter = filter.trimmingCharacters(in: .whitespaces).isEmpty ? LDAPConfig.defaultFilter : filter
        attributes = (try? c.decodeIfPresent(LDAPAttributeMap.self, forKey: .attributes)) ?? LDAPAttributeMap()
    }
}

/// Which LDAP attributes hold what. Defaults fit OpenLDAP (inetOrgPerson) and Active Directory.
public struct LDAPAttributeMap: Codable, Equatable, Sendable {
    public var name: String
    public var phone: String
    public var mobile: String
    public var email: String
    /// "o" in inetOrgPerson; Active Directory uses "company".
    public var organization: String

    public init(name: String = "cn", phone: String = "telephoneNumber", mobile: String = "mobile",
                email: String = "mail", organization: String = "o") {
        self.name = name
        self.phone = phone
        self.mobile = mobile
        self.email = email
        self.organization = organization
    }

    private enum CodingKeys: String, CodingKey { case name, phone, mobile, email, organization }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LDAPAttributeMap()
        func read(_ k: CodingKeys, _ fallback: String) throws -> String {
            let v = try c.decodeIfPresent(String.self, forKey: k)?.trimmingCharacters(in: .whitespaces) ?? ""
            return v.isEmpty ? fallback : v
        }
        name = try read(.name, d.name)
        phone = try read(.phone, d.phone)
        mobile = try read(.mobile, d.mobile)
        email = try read(.email, d.email)
        organization = try read(.organization, d.organization)
    }
}

// MARK: - URL (CSV or JSON)

public enum URLDirectoryFormat: String, Codable, CaseIterable, Sendable {
    case csv, json
}

/// Where each field is found in a feed: a CSV column name (case-insensitive) or a JSON key path
/// (dot-separated, e.g. "phones.work"). nil = the recognised names (name, first name, last name,
/// number, mobile, email, organization, and common spellings of them).
public struct URLFieldMap: Codable, Equatable, Sendable {
    public var name: String?
    public var firstName: String?
    public var lastName: String?
    public var number: String?
    public var mobile: String?
    public var email: String?
    public var organization: String?

    public init(name: String? = nil, firstName: String? = nil, lastName: String? = nil, number: String? = nil,
                mobile: String? = nil, email: String? = nil, organization: String? = nil) {
        self.name = name
        self.firstName = firstName
        self.lastName = lastName
        self.number = number
        self.mobile = mobile
        self.email = email
        self.organization = organization
    }
}

public struct URLConfig: Codable, Equatable, Sendable {
    /// Refresh choices of the sheet: hour, 6 hours, day, week.
    public static let refreshChoices = [60, 360, 1440, 10080]

    public var url: String
    public var format: URLDirectoryFormat
    public var refreshMinutes: Int
    /// JSON: key paths of the fields in each object.
    public var jsonPaths: URLFieldMap
    /// JSON: key path of the array when the document is an object (e.g. "data.contacts"); nil = the root.
    public var jsonItemsPath: String?
    /// CSV: header names of the columns.
    public var csvColumns: URLFieldMap

    public init(url: String = "", format: URLDirectoryFormat = .csv, refreshMinutes: Int = 60,
                jsonPaths: URLFieldMap = URLFieldMap(), jsonItemsPath: String? = nil, csvColumns: URLFieldMap = URLFieldMap()) {
        self.url = url
        self.format = format
        self.refreshMinutes = refreshMinutes
        self.jsonPaths = jsonPaths
        self.jsonItemsPath = jsonItemsPath
        self.csvColumns = csvColumns
    }

    private enum CodingKeys: String, CodingKey { case url, format, refreshMinutes, jsonPaths, jsonItemsPath, csvColumns }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        format = (try? c.decodeIfPresent(URLDirectoryFormat.self, forKey: .format)) ?? .csv
        refreshMinutes = max(1, try c.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? 60)
        jsonPaths = (try? c.decodeIfPresent(URLFieldMap.self, forKey: .jsonPaths)) ?? URLFieldMap()
        jsonItemsPath = try c.decodeIfPresent(String.self, forKey: .jsonItemsPath)
        csvColumns = (try? c.decodeIfPresent(URLFieldMap.self, forKey: .csvColumns)) ?? URLFieldMap()
    }
}

// MARK: - Google

/// Google Contacts (People API, read-only). The OAuth tokens are in the Keychain, service
/// `com.hsmm.macrosip.google`, account = source id (`DirectoryCredentials`).
public struct GoogleConfig: Codable, Equatable, Sendable {
    /// The signed-in account, shown in the source list; nil before the first sign-in.
    public var accountEmail: String?
    public init(accountEmail: String? = nil) { self.accountEmail = accountEmail }
}

// MARK: - Settings

public struct DirectorySettings: Codable, Equatable, Sendable {
    public static let resultsPerSourceRange: ClosedRange<Int> = 1...10

    /// In result order (drag to reorder in Settings).
    public var sources: [DirectorySource]
    /// Ask search-only sources for the name of a ringing caller (at most 1 second).
    public var lookupIncomingCallers: Bool
    /// Characters typed before the number field searches the directories.
    public var minimumQueryLength: Int
    /// "Search directories from the number field".
    public var searchFromNumberField: Bool
    /// "Results per source", 1...10.
    public var resultsPerSource: Int

    public init(sources: [DirectorySource] = [], lookupIncomingCallers: Bool = true, minimumQueryLength: Int = 2,
                searchFromNumberField: Bool = true, resultsPerSource: Int = 5) {
        self.sources = sources
        self.lookupIncomingCallers = lookupIncomingCallers
        self.minimumQueryLength = minimumQueryLength
        self.searchFromNumberField = searchFromNumberField
        self.resultsPerSource = resultsPerSource
    }

    private enum CodingKeys: String, CodingKey { case sources, lookupIncomingCallers, minimumQueryLength, searchFromNumberField, resultsPerSource }

    /// Missing keys decode as defaults; a source of a kind this version does not know is dropped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent([FailableSource].self, forKey: .sources)) ?? []
        sources = raw.compactMap(\.value)
        lookupIncomingCallers = try c.decodeIfPresent(Bool.self, forKey: .lookupIncomingCallers) ?? true
        minimumQueryLength = max(1, try c.decodeIfPresent(Int.self, forKey: .minimumQueryLength) ?? 2)
        searchFromNumberField = try c.decodeIfPresent(Bool.self, forKey: .searchFromNumberField) ?? true
        let limit = try c.decodeIfPresent(Int.self, forKey: .resultsPerSource) ?? 5
        resultsPerSource = min(max(limit, Self.resultsPerSourceRange.lowerBound), Self.resultsPerSourceRange.upperBound)
    }

    private struct FailableSource: Decodable {
        let value: DirectorySource?
        init(from decoder: Decoder) throws { value = try? DirectorySource(from: decoder) }
    }
}
