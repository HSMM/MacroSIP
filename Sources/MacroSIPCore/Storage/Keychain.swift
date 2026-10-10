import Foundation
import Security

public enum KeychainError: Error, Equatable {
    case osStatus(OSStatus)
    case invalidData
}

/// Generic-password storage. Uses the data-protection keychain (access not tied to the code
/// signature). If that is refused with errSecMissingEntitlement (e.g. ad-hoc signed binaries
/// without an application identifier), each operation falls back to the legacy login keychain.
public struct Keychain: Sendable {
    public let service: String
    public init(service: String = "com.hsmm.macrosip") { self.service = service }

    private func query(_ id: AccountID, dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.raw.uuidString,
        ]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    /// Runs `body` against the data-protection keychain, then the legacy one on errSecMissingEntitlement.
    private func withFallback<R>(_ body: (_ dataProtection: Bool) throws -> R) throws -> R {
        do {
            return try body(true)
        } catch KeychainError.osStatus(let s) where s == errSecMissingEntitlement {
            return try body(false)
        }
    }

    public func setPassword(_ password: String, for id: AccountID) throws {
        let data = Data(password.utf8)
        try withFallback { dp in
            let attrs: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let update = SecItemUpdate(query(id, dataProtection: dp) as CFDictionary, attrs as CFDictionary)
            if update == errSecSuccess { return }
            guard update == errSecItemNotFound else { throw KeychainError.osStatus(update) }
            var add = query(id, dataProtection: dp)
            add.merge(attrs) { $1 }
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        }
    }

    public func password(for id: AccountID) throws -> String? {
        // Without the entitlement the data-protection keychain reports "not found" on reads,
        // so a miss there also checks the legacy keychain where the fallback write landed.
        if let found = try readPassword(id, dataProtection: true) { return found }
        return try readPassword(id, dataProtection: false)
    }

    private func readPassword(_ id: AccountID, dataProtection: Bool) throws -> String? {
        do {
            let dp = dataProtection
            var q = query(id, dataProtection: dp)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
            guard let data = out as? Data, let s = String(data: data, encoding: .utf8) else { throw KeychainError.invalidData }
            return s
        } catch KeychainError.osStatus(let st) where dataProtection && st == errSecMissingEntitlement {
            return nil
        }
    }

    public func deletePassword(for id: AccountID) throws {
        // Delete from both keychains so no stale copy survives either way.
        for dp in [true, false] {
            let status = SecItemDelete(query(id, dataProtection: dp) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound
                    || (dp && status == errSecMissingEntitlement) else { throw KeychainError.osStatus(status) }
        }
    }
}
