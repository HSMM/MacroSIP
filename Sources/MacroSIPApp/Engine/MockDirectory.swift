import Foundation
import MacroSIPCore
#if DEBUG

/// The directory for demo launches (`--demo-state`): sources answer from a small fake address book, each
/// after its own delay, so the "Searching <source>…" row can be seen. Nothing leaves the process.
final class MockDirectory: DirectoryBackend, @unchecked Sendable {
    private struct Person {
        var name: String
        var organization: String?
        var numbers: [PhoneNumber]
        var photo: Data?
    }

    let events: AsyncStream<DirectoryEvent>
    private let continuation: AsyncStream<DirectoryEvent>.Continuation
    private let lock = NSLock()
    private var settings: DirectorySettings
    private var announced: Set<UUID> = []

    init(settings: DirectorySettings) {
        self.settings = settings
        (events, continuation) = AsyncStream.makeStream()
        announce(settings)
    }

    // MARK: Fake data

    private static func number(_ label: PhoneLabel, _ value: String, _ isDefault: Bool = true) -> PhoneNumber {
        PhoneNumber(label: label, value: value, isDefault: isDefault)
    }

    /// What each kind of source holds, and how long it takes to answer.
    private func people(for kind: DirectorySourceKind) -> [Person] {
        switch kind {
        case .ldap:
            return [
                Person(name: DemoPeople.natallia, organization: "Sales", numbers: [Self.number(.work, "2214")]),
                Person(name: DemoPeople.katsiaryna, organization: "Support", numbers: [Self.number(.work, "2230")]),
                Person(name: DemoPeople.maryna, organization: "Accounting", numbers: [Self.number(.work, "2241")]),
                Person(name: DemoPeople.siarhei, organization: "Warehouse", numbers: [Self.number(.work, "2260")]),
            ]
        case .macContacts:
            return [
                Person(name: DemoPeople.andrei, organization: nil, numbers: [Self.number(.mobile, "+7 916 555-44-02")],
                       photo: DemoState.photoJPEG(top: (0.98, 0.72, 0.36), bottom: (0.86, 0.45, 0.16))),
                Person(name: DemoPeople.yauheni, organization: "Example Ltd", numbers: [Self.number(.mobile, "+49 30 123456")]),
                Person(name: DemoPeople.volha, organization: "Example Ltd", numbers: [Self.number(.work, "103")]),
                Person(name: DemoPeople.dzmitry, organization: nil,
                       numbers: [Self.number(.mobile, "+7 912 555-01-23"), Self.number(.home, "+375 17 200-30-40", false)],
                       photo: DemoState.photoJPEG(top: (0.44, 0.83, 0.61), bottom: (0.18, 0.64, 0.41))),
                Person(name: DemoPeople.kate, organization: "Example Ltd", numbers: [Self.number(.mobile, "+44 20 7946 0001")]),
                Person(name: DemoPeople.lev, organization: nil, numbers: [Self.number(.mobile, "+44 20 7946 0002")]),
            ]
        case .google:
            return [Person(name: DemoPeople.aliaksandr, organization: nil, numbers: [Self.number(.mobile, "+1 650 555-0199")])]
        case .url:
            return [
                Person(name: DemoPeople.kasia, organization: "Intranet", numbers: [Self.number(.work, "2305")]),
                Person(name: DemoPeople.pavel, organization: "Intranet", numbers: [Self.number(.work, "2306")]),
            ]
        }
    }

    private func delay(for kind: DirectorySourceKind) -> Duration {
        switch kind {
        case .ldap: return .milliseconds(450)
        case .macContacts: return .milliseconds(150)
        case .url: return .milliseconds(1_200)
        case .google: return .milliseconds(MockDirectory.googleDelayMilliseconds)
        }
    }

    /// Demo states show the Settings pane with the expired Google sign-in of the mockup; the others search it.
    private static var googleSignedIn: Bool { LaunchOptions.current.demoState != "settings-directory" }

    /// Long enough for a snapshot to catch the spinner row.
    static let googleDelayMilliseconds = 4_000

    private func entries(for source: DirectorySource, matching text: String) -> [DirectoryEntry] {
        let q = text.lowercased()
        let digits = q.contains(where: \.isLetter) ? nil : DirectoryNumber.digits(q)
        return people(for: source.kind).enumerated().compactMap { i, p in
            let hit = p.name.lowercased().contains(q) || (p.organization ?? "").lowercased().contains(q)
                || p.numbers.contains { n in n.value.lowercased().contains(q) || (digits.map { !$0.isEmpty && DirectoryNumber.digits(n.value).contains($0) } ?? false) }
            guard hit else { return nil }
            return DirectoryEntry(id: "\(source.id.uuidString)-\(i)", sourceID: source.id, sourceKind: source.kind,
                                  displayName: p.name, numbers: p.numbers, organization: p.organization, photo: p.photo)
        }
    }

    // MARK: DirectoryBackend

    func search(_ text: String) -> AsyncStream<DirectorySearchUpdate> {
        let sources = lock.withLock { settings }.sources.filter { $0.isEnabled && !($0.kind == .google && !Self.googleSignedIn) }
        return AsyncStream { continuation in
            continuation.yield(.started(sources.map(\.id)))
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for source in sources {
                        group.addTask { [self] in
                            try? await Task.sleep(for: delay(for: source.kind))
                            guard !Task.isCancelled else { return }
                            continuation.yield(.results(sourceID: source.id, entries: entries(for: source, matching: text)))
                        }
                    }
                }
                if !Task.isCancelled { continuation.yield(.finished) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func lookup(number: String) async -> DirectoryEntry? {
        let sources = lock.withLock { settings.sources.filter(\.isEnabled) }
        try? await Task.sleep(for: .milliseconds(250))
        for source in sources where source.kind != .google {
            for (i, p) in people(for: source.kind).enumerated() where p.numbers.contains(where: { DirectoryNumber.matches($0.value, number) }) {
                return DirectoryEntry(id: "\(source.id.uuidString)-\(i)", sourceID: source.id, sourceKind: source.kind,
                                      displayName: p.name, numbers: p.numbers, organization: p.organization, photo: p.photo)
            }
        }
        return nil
    }

    func test(source: DirectorySource, ldapPassword: String?) async -> DirectoryTestResult {
        try? await Task.sleep(for: .milliseconds(700))
        switch source.kind {
        case .google: return DirectoryTestResult(status: Self.googleSignedIn ? .connected : .signInRequired)
        default: return .connected(entries: source.kind == .ldap ? 1_240 : people(for: source.kind).count)
        }
    }

    func importAll(source: DirectorySource) async throws -> [Contact] {
        try? await Task.sleep(for: .milliseconds(600))
        return people(for: source.kind).enumerated().map { i, p in
            DirectoryEntry(id: "\(i)", sourceID: source.id, sourceKind: source.kind, displayName: p.name,
                           numbers: p.numbers, organization: p.organization, photo: p.photo)
                .makeContact(imported: true)
        }
    }

    func update(settings new: DirectorySettings) async {
        lock.withLock { settings = new }
        announce(new)
    }

    /// Signs in after a second without opening anything; the source then reports "connected" like the real service.
    func signInGoogle(sourceID: UUID, openURL: @escaping @Sendable (URL) -> Void) async throws -> String {
        do { try await Task.sleep(for: .seconds(1)) } catch { throw DirectoryError.cancelled }
        continuation.yield(.sourceStatus(id: sourceID, status: .connected))
        return "andrei@gmail.com"
    }

    /// New sources report "connected" (or "sign in required" for Google) like the real service after its first contact.
    private func announce(_ s: DirectorySettings) {
        let fresh = lock.withLock { () -> [DirectorySource] in
            let list = s.sources.filter { !announced.contains($0.id) }
            announced.formUnion(list.map(\.id))
            return list
        }
        for source in fresh {
            switch source.kind {
            case .google: continuation.yield(.sourceStatus(id: source.id, status: Self.googleSignedIn ? .connected : .signInRequired))
            case .macContacts: continuation.yield(.sourceStatus(id: source.id, status: .syncedAt(Date().addingTimeInterval(-300))))
            default: continuation.yield(.sourceStatus(id: source.id, status: .connected))
            }
        }
    }
}
#endif
