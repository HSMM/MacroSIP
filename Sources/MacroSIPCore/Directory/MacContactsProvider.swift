import Contacts
import Foundation
import os

/// The macOS Contacts app (Contacts framework). The permission prompt appears only from `test()`, which the
/// Add button of the sheet runs (SCREENS.md Q13.5); search and lookup never prompt and fail with
/// `.accessDenied` until access is granted. The address book is read once and kept in memory until
/// Contacts reports a change; thumbnails are read for the results only (all of them for an import).
/// The app's Info.plist must carry `NSContactsUsageDescription`, or macOS ends the process at the prompt.
public actor MacContactsProvider: DirectoryProvider {
    public nonisolated let sourceID: UUID
    private var index: DirectoryIndex?
    private let changed = OSAllocatedUnfairLock(initialState: true)
    private nonisolated(unsafe) let observer: NSObjectProtocol

    public init(source: DirectorySource) {
        sourceID = source.id
        let flag = changed
        observer = NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: nil) { _ in
            flag.withLock { $0 = true }
        }
    }

    deinit { NotificationCenter.default.removeObserver(observer) }

    // MARK: Permission

    public enum Access: Sendable { case granted, denied, notDetermined }

    public static var access: Access {
        let s = CNContactStore.authorizationStatus(for: .contacts)
        if s == .notDetermined { return .notDetermined }
        if s == .denied || s == .restricted { return .denied }
        return .granted                         // authorized, or limited where macOS has it
    }

    /// Shows the system prompt if the user has not answered it yet.
    public static func requestAccess() async -> Bool {
        if access != .notDetermined { return access == .granted }
        return await withCheckedContinuation { cont in
            CNContactStore().requestAccess(for: .contacts) { ok, _ in cont.resume(returning: ok) }
        }
    }

    private func requireAccess() throws {
        switch Self.access {
        case .granted: return
        case .denied: throw DirectoryError.accessDenied
        case .notDetermined: throw DirectoryError.accessNotRequested
        }
    }

    // MARK: DirectoryProvider

    public func search(_ query: String, limit: Int) async throws -> [DirectoryEntry] {
        try requireAccess()
        let found = try await snapshot().search(query, limit: limit)
        return await Self.withThumbnails(found)
    }

    public func lookup(number: String) async throws -> DirectoryEntry? {
        try requireAccess()
        guard let e = try await snapshot().lookup(number) else { return nil }
        return await Self.withThumbnails([e]).first
    }

    public func test() async throws -> DirectoryTestResult {
        guard await Self.requestAccess() else { return DirectoryTestResult(status: .error(.accessDenied)) }
        changed.withLock { $0 = true }
        return .connected(entries: try await snapshot().count)
    }

    public func allEntries() async throws -> [DirectoryEntry] {
        try requireAccess()
        return try await Self.fetchAll(sourceID: sourceID, thumbnails: true)
    }

    // MARK: Reading

    private func snapshot() async throws -> DirectoryIndex {
        let stale = changed.withLock { flag in
            defer { flag = false }
            return flag
        }
        if !stale, let index { return index }
        let fresh = DirectoryIndex(try await Self.fetchAll(sourceID: sourceID, thumbnails: false))
        index = fresh
        return fresh
    }

    private static let queue = DispatchQueue(label: "com.hsmm.macrosip.directory.contacts", qos: .userInitiated)

    static func fetchAll(sourceID: UUID, thumbnails: Bool) async throws -> [DirectoryEntry] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    var keys: [CNKeyDescriptor] = [
                        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                        CNContactOrganizationNameKey as CNKeyDescriptor,
                        CNContactPhoneNumbersKey as CNKeyDescriptor,
                        CNContactEmailAddressesKey as CNKeyDescriptor,
                    ]
                    if thumbnails { keys.append(CNContactThumbnailImageDataKey as CNKeyDescriptor) }
                    let request = CNContactFetchRequest(keysToFetch: keys)
                    request.unifyResults = true
                    var out: [DirectoryEntry] = []
                    try CNContactStore().enumerateContacts(with: request) { c, _ in
                        if let e = entry(c, sourceID: sourceID, thumbnails: thumbnails) { out.append(e) }
                    }
                    cont.resume(returning: out)
                } catch {
                    cont.resume(throwing: DirectoryError.server(error.localizedDescription))
                }
            }
        }
    }

    /// Adds the thumbnails of a few entries (results of a search).
    static func withThumbnails(_ entries: [DirectoryEntry]) async -> [DirectoryEntry] {
        let ids = entries.map { String($0.id.dropFirst(prefix.count)) }
        guard !ids.isEmpty else { return entries }
        let photos: [String: Data] = await withCheckedContinuation { cont in
            queue.async {
                var out: [String: Data] = [:]
                let keys = [CNContactThumbnailImageDataKey as CNKeyDescriptor]
                if let list = try? CNContactStore().unifiedContacts(matching: CNContact.predicateForContacts(withIdentifiers: ids), keysToFetch: keys) {
                    for c in list { if let d = c.thumbnailImageData { out[c.identifier] = d } }
                }
                cont.resume(returning: out)
            }
        }
        return entries.map { e in
            var e = e
            e.photo = photos[String(e.id.dropFirst(prefix.count))]
            return e
        }
    }

    static let prefix = "contacts:"

    static func entry(_ c: CNContact, sourceID: UUID, thumbnails: Bool) -> DirectoryEntry? {
        var numbers: [PhoneNumber] = []
        for lv in c.phoneNumbers {
            let value = lv.value.stringValue.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            numbers.append(PhoneNumber(label: label(lv.label), value: value, isDefault: numbers.isEmpty))
        }
        guard !numbers.isEmpty else { return nil }
        let org = c.organizationName.trimmingCharacters(in: .whitespaces)
        var name = CNContactFormatter.string(from: c, style: .fullName) ?? ""
        if name.isEmpty { name = org.isEmpty ? numbers[0].value : org }
        return DirectoryEntry(id: prefix + c.identifier, sourceID: sourceID, sourceKind: .macContacts, displayName: name,
                              numbers: numbers, organization: org.isEmpty ? nil : org,
                              email: c.emailAddresses.first.map { $0.value as String },
                              photo: thumbnails ? c.thumbnailImageData : nil)
    }

    static func label(_ raw: String?) -> PhoneLabel {
        switch raw {
        case CNLabelPhoneNumberMobile?, CNLabelPhoneNumberiPhone?: return .mobile
        case CNLabelWork?, CNLabelPhoneNumberMain?, CNLabelPhoneNumberWorkFax?: return .work
        case CNLabelHome?, CNLabelPhoneNumberHomeFax?: return .home
        default: return .other
        }
    }
}
