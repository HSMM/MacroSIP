import Foundation
import Security

public enum KeychainError: Error, Equatable {
    case osStatus(OSStatus)
    case invalidData
}

public struct Keychain: Sendable {
    public let service: String
    public init(service: String = "com.hsmm.macrosip") { self.service = service }

    private func query(_ id: AccountID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.raw.uuidString]
    }

    public func setPassword(_ password: String, for id: AccountID) throws {
        let data = Data(password.utf8)
        let update = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.osStatus(update) }
        var add = query(id)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    public func password(for id: AccountID) throws -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        guard let data = out as? Data, let s = String(data: data, encoding: .utf8) else { throw KeychainError.invalidData }
        return s
    }

    public func deletePassword(for id: AccountID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.osStatus(status) }
    }
}
