import Testing
@testable import MacroSIPCore

@Suite struct EditionTests {
    @Test func bundleIdentifiersDiffer() {
        #expect(Edition.lite.bundleIdentifier != Edition.full.bundleIdentifier)
    }

    @Test func currentMatchesCompileFlag() {
        #if FULL
        #expect(Edition.current == .full)
        #else
        #expect(Edition.current == .lite)
        #endif
    }
}
