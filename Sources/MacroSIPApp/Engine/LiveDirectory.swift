import Foundation
import MacroSIPCore

/// The real directory: Core's `DirectoryService` (LDAP, URL feeds, macOS Contacts, Google Contacts).
final class LiveDirectory: DirectoryBackend, @unchecked Sendable {
    private let service: DirectoryService

    init(settings: DirectorySettings) {
        service = DirectoryService(settings: settings)
    }

    var events: AsyncStream<DirectoryEvent> { service.events }

    func search(_ text: String) -> AsyncStream<DirectorySearchUpdate> { service.searchUpdates(text) }
    func lookup(number: String) async -> DirectoryEntry? { await service.lookup(number: number) }
    func test(source: DirectorySource, ldapPassword: String?) async -> DirectoryTestResult {
        await service.test(source: source, ldapPassword: ldapPassword)
    }
    func importAll(source: DirectorySource) async throws -> [Contact] { try await service.importAll(source: source) }
    func update(settings: DirectorySettings) async { await service.update(settings: settings) }
    func signInGoogle(sourceID: UUID, openURL: @escaping @Sendable (URL) -> Void) async throws -> String {
        try await service.signInGoogle(sourceID: sourceID, openURL: openURL)
    }
}
