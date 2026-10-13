import Foundation
import Testing
@testable import MacroSIPCore

@Suite struct KeychainTests {
    @Test func roundTrip() throws {
        let kc = Keychain(service: "com.hsmm.macrosip.tests")
        let id = AccountID()
        defer { try? kc.deletePassword(for: id) }
        do {
            try kc.setPassword("one", for: id)
        } catch KeychainError.osStatus(let s) where s == errSecNotAvailable || s == errSecInteractionNotAllowed || s == errSecMissingEntitlement {
            withKnownIssue("Keychain unavailable in this environment (OSStatus \(s))") {
                throw KeychainError.osStatus(s)
            }
            return
        }
        #expect(try kc.password(for: id) == "one")
        try kc.setPassword("two", for: id)
        #expect(try kc.password(for: id) == "two")
        try kc.deletePassword(for: id)
        #expect(try kc.password(for: id) == nil)
        try kc.deletePassword(for: id)  // idempotent
    }
}
