import Foundation

/// One person or number found in a directory source. Not stored unless the source imports into Contacts.
public struct DirectoryEntry: Identifiable, Hashable, Sendable {
    /// Stable within the source: the LDAP DN, the Contacts identifier, the feed row.
    public var id: String
    public var sourceID: UUID
    public var sourceKind: DirectorySourceKind
    public var displayName: String
    public var numbers: [PhoneNumber]
    public var organization: String?
    public var email: String?
    /// JPEG or PNG thumbnail when the source has one (macOS Contacts).
    public var photo: Data?

    public init(id: String, sourceID: UUID, sourceKind: DirectorySourceKind, displayName: String,
                numbers: [PhoneNumber], organization: String? = nil, email: String? = nil, photo: Data? = nil) {
        self.id = id
        self.sourceID = sourceID
        self.sourceKind = sourceKind
        self.displayName = displayName
        self.numbers = numbers
        self.organization = organization
        self.email = email
        self.photo = photo
    }

    /// The number to call: the default one, else the first.
    public var defaultNumber: PhoneNumber? { numbers.first(where: \.isDefault) ?? numbers.first }

    /// A card for Contacts ("Add to Contacts", import). The name is split at the last space. An imported card
    /// remembers its source (`Contact.importedFrom`), so later imports may update it; `note` goes to `notes`.
    public func makeContact(imported: Bool = false, note: String = "") -> Contact {
        let (first, last) = Contact.splitName(displayName)
        var list = numbers
        if !list.isEmpty, !list.contains(where: \.isDefault) { list[0].isDefault = true }
        return Contact(firstName: first, lastName: last, organization: organization ?? "", numbers: list,
                       email: email ?? "", notes: note, photo: photo.flatMap { ContactPhoto.jpeg(from: $0) },
                       importedFrom: imported ? sourceID : nil)
    }
}

/// What Settings › Directory shows next to a source.
public enum DirectorySourceStatus: Equatable, Sendable {
    case connected
    case signInRequired
    case error(DirectoryError)
    case syncedAt(Date)

    /// A macOS Contacts source whose access was refused (shown as "Access denied" with a link to System Settings).
    public var isAccessDenied: Bool { self == .error(.accessDenied) }

    /// Whether search and lookup still ask the source. A failed source is asked again after a pause (and an
    /// import may always be retried); one that needs a sign-in is not.
    public var isUsable: Bool {
        switch self {
        case .connected, .syncedAt, .error: return true
        case .signInRequired: return false
        }
    }
}

public enum DirectoryEvent: Equatable, Sendable {
    case sourceStatus(id: UUID, status: DirectorySourceStatus)
}

/// The result of the Test button: `.connected` with the entry count when known
/// ("Connected · %lld entries"), else the reason.
public struct DirectoryTestResult: Equatable, Sendable {
    public var status: DirectorySourceStatus
    public var entryCount: Int?

    public init(status: DirectorySourceStatus, entryCount: Int? = nil) {
        self.status = status
        self.entryCount = entryCount
    }

    public var isSuccess: Bool { status == .connected }

    public static func connected(entries: Int?) -> DirectoryTestResult { DirectoryTestResult(status: .connected, entryCount: entries) }
}

/// Why a source could not answer. Cases are structured so the app can show them in its own language;
/// `description` is the English text for logs and tests. `.server` carries text from a library or the system
/// (libldap, URLSession, Contacts) and is shown as it is.
public enum DirectoryError: Error, Equatable, Sendable, CustomStringConvertible {
    case accessDenied
    /// macOS Contacts: the user has not pressed "Allow access" yet.
    case accessNotRequested
    case signInRequired
    case timedOut
    case cancelled
    case cannotConnect(host: String)
    case invalidCredentials
    case http(Int)
    case notConfigured(ConfigurationProblem)
    case badFeed(FeedProblem)
    case unsupportedSource
    case notConnected
    case server(String)

    public enum ConfigurationProblem: Equatable, Sendable {
        case emptyServer
        case badLDAPURL
        case badFeedURL
        /// Google Contacts: `GoogleOAuth.Configuration.clientID` is empty in this build.
        case googleClientID
    }

    public enum FeedProblem: Equatable, Sendable {
        case notText
        case noNumberColumn
        case invalidJSON
        case noContactArray
    }

    public var description: String {
        switch self {
        case .accessDenied: return "Access denied"
        case .accessNotRequested: return "Contacts access has not been requested"
        case .signInRequired: return "Sign in required"
        case .timedOut: return "Timed out"
        case .cancelled: return "Cancelled"
        case .cannotConnect(let host): return "Cannot connect to \(host)"
        case .invalidCredentials: return "Invalid bind DN or password"
        case .http(let code): return "HTTP \(code)"
        case .notConfigured(.emptyServer): return "Enter the server address"
        case .notConfigured(.badLDAPURL): return "The server must be ldap://host or ldaps://host"
        case .notConfigured(.badFeedURL): return "Enter an http, https or file URL"
        case .notConfigured(.googleClientID): return "Google sign-in is not configured in this build (no OAuth client id)"
        case .badFeed(.notText): return "The file is not text"
        case .badFeed(.noNumberColumn): return "No number column in the header"
        case .badFeed(.invalidJSON): return "The file is not valid JSON"
        case .badFeed(.noContactArray): return "No array of contacts in the JSON"
        case .unsupportedSource: return "Unsupported source"
        case .notConnected: return "Not connected"
        case .server(let s): return s
        }
    }

    /// The status a source is in after this error.
    public var status: DirectorySourceStatus {
        switch self {
        case .signInRequired: return .signInRequired
        default: return .error(self)
        }
    }

    static func from(_ error: Error) -> DirectoryError {
        if let e = error as? DirectoryError { return e }
        if error is CancellationError { return .cancelled }
        if let u = error as? URLError {
            if u.code == .timedOut { return .timedOut }
            if u.code == .cancelled { return .cancelled }
            return .server(u.localizedDescription)
        }
        return .server(error.localizedDescription)
    }
}

/// One directory source. Implementations are cheap to create; `DirectoryService` makes one per source and
/// keeps it while the source's settings do not change.
public protocol DirectoryProvider: Sendable {
    var sourceID: UUID { get }
    /// At most `limit` entries whose name, organization or number contains `query`.
    func search(_ query: String, limit: Int) async throws -> [DirectoryEntry]
    /// The entry that has `number` (spaces, dashes, brackets and a country prefix ignored), if any.
    func lookup(number: String) async throws -> DirectoryEntry?
    /// Connects (and for macOS Contacts asks for permission) and reports what it found.
    func test() async throws -> DirectoryTestResult
    /// Everything the source has, for "Import into Contacts".
    func allEntries() async throws -> [DirectoryEntry]
}
