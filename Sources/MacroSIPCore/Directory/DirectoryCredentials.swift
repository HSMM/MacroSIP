import Foundation
import os

/// Directory secrets in the Keychain, keyed by source id.
/// - LDAP bind passwords: the app's service (`com.hsmm.macrosip`), account = source id.
/// - Google OAuth tokens: service `<app service>.google` (`com.hsmm.macrosip.google`), account = source id;
///   the value is the JSON of `GoogleToken`.
/// Remove both when a source is deleted (`deleteAll(for:)`). `inMemory()` keeps everything in the process
/// instead (tests, demo launches).
public struct DirectoryCredentials: Sendable {
    public let keychain: Keychain
    public let googleKeychain: Keychain
    /// Passwords typed but not saved (the Test button of the source sheet): read before the Keychain, never written.
    private var ldapOverrides: [UUID: String] = [:]
    private let memory: MemoryStore?

    public init(keychain: Keychain = Keychain()) {
        self.keychain = keychain
        self.googleKeychain = Keychain(service: keychain.service + ".google")
        memory = nil
    }

    private init(memory: MemoryStore) {
        keychain = Keychain(service: "com.hsmm.macrosip.memory")
        googleKeychain = Keychain(service: "com.hsmm.macrosip.memory.google")
        self.memory = memory
    }

    /// Credentials that never touch the Keychain: kept in memory for the lifetime of the value and its copies.
    public static func inMemory() -> DirectoryCredentials { DirectoryCredentials(memory: MemoryStore()) }

    private func key(_ id: UUID) -> AccountID { AccountID(raw: id) }

    /// A copy that answers `password` for `sourceID` without touching the Keychain.
    public func overriding(ldapPassword password: String, for sourceID: UUID) -> DirectoryCredentials {
        var copy = self
        copy.ldapOverrides[sourceID] = password
        return copy
    }

    public func ldapPassword(for sourceID: UUID) throws -> String? {
        if let p = ldapOverrides[sourceID] { return p }
        if let memory { return memory.state.withLock { $0.ldap[sourceID] } }
        return try keychain.password(for: key(sourceID))
    }

    /// An empty password removes the item.
    public func setLDAPPassword(_ password: String, for sourceID: UUID) throws {
        if let memory { memory.state.withLock { $0.ldap[sourceID] = password.isEmpty ? nil : password }; return }
        if password.isEmpty { try keychain.deletePassword(for: key(sourceID)) }
        else { try keychain.setPassword(password, for: key(sourceID)) }
    }

    public func googleToken(for sourceID: UUID) throws -> GoogleToken? {
        if let memory { return memory.state.withLock { $0.google[sourceID] } }
        guard let s = try googleKeychain.password(for: key(sourceID)) else { return nil }
        return try? JSONDecoder().decode(GoogleToken.self, from: Data(s.utf8))
    }

    /// nil removes the token.
    public func setGoogleToken(_ token: GoogleToken?, for sourceID: UUID) throws {
        if let memory { memory.state.withLock { $0.google[sourceID] = token }; return }
        guard let token else { try googleKeychain.deletePassword(for: key(sourceID)); return }
        let data = try JSONEncoder().encode(token)
        try googleKeychain.setPassword(String(decoding: data, as: UTF8.self), for: key(sourceID))
    }

    public func deleteAll(for sourceID: UUID) throws {
        if let memory {
            memory.state.withLock { $0.ldap[sourceID] = nil; $0.google[sourceID] = nil }
            return
        }
        try keychain.deletePassword(for: key(sourceID))
        try googleKeychain.deletePassword(for: key(sourceID))
    }

    private final class MemoryStore: Sendable {
        struct Contents: Sendable {
            var ldap: [UUID: String] = [:]
            var google: [UUID: GoogleToken] = [:]
        }
        let state = OSAllocatedUnfairLock(initialState: Contents())
    }
}

/// OAuth 2.0 tokens of a Google Contacts source (the Keychain slot; see docs/DIRECTORY.md).
public struct GoogleToken: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scope: String?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, scope: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }
}
