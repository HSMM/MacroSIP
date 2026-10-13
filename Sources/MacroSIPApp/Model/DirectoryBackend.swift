import Foundation
import MacroSIPCore

/// The directory as the app sees it. `LiveDirectory` wraps Core's `DirectoryService`; `MockDirectory`
/// (demo launches) answers from a fake address book with delays.
protocol DirectoryBackend: Sendable {
    /// `.started` with the sources asked, one `.results` / `.failed` per source as it answers, `.finished`.
    /// The stream ends after `.finished` or when the consuming task is cancelled.
    func search(_ text: String) -> AsyncStream<DirectorySearchUpdate>
    func lookup(number: String) async -> DirectoryEntry?
    /// `ldapPassword`: the one typed in the sheet, used for this test only.
    func test(source: DirectorySource, ldapPassword: String?) async -> DirectoryTestResult
    func importAll(source: DirectorySource) async throws -> [Contact]
    func update(settings: DirectorySettings) async
    /// Google OAuth in the browser (`openURL` opens the consent page); returns the signed-in e-mail. Throws
    /// `DirectoryError.cancelled` when the task is cancelled, `.notConfigured(.googleClientID)` in a build
    /// without a client id, `.timedOut` after two minutes.
    func signInGoogle(sourceID: UUID, openURL: @escaping @Sendable (URL) -> Void) async throws -> String
    var events: AsyncStream<DirectoryEvent> { get }
}
