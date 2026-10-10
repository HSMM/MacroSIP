import Foundation
import MacroSIPCore

// ============================================================================
// REAL ENGINE WIRING: the single place that decides which engine the app uses.
// `MacroSIPCore.Engine` already has the exact method shapes of `SIPEngine`;
// the extension below is all the glue that is needed.
// ============================================================================
extension Engine: SIPEngine {}

enum EngineFactory {
    /// Real engine unless `--mock-engine` was passed. `AppModel` falls back to
    /// `MockEngine` (with a banner) when the real one fails to start.
    static func make(useMock: Bool) -> any SIPEngine {
        if useMock { return MockEngine() }
        return Engine(logLevel: 3)          // <- real engine
    }
}
