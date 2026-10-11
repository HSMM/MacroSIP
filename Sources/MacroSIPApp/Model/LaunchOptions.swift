import Foundation

/// Command-line switches.
///   --mock-engine           use MockEngine
///   --data-dir PATH         keep JSON stores in PATH instead of ~/Library/Application Support/MacroSIP
///   --snapshot PREFIX       (DEBUG) write PNGs of the app's windows to PREFIX-<window>.png after
///   --snapshot-after SECS   SECS seconds (default 6); works without a display, unlike screencapture
///   --demo-state NAME       (DEBUG builds) seed sample data and put the mock in a given state;
///                           implies --mock-engine and a throw-away data directory.
///   --log-level N           PJSIP log level 0...6 (default 3); also MACROSIP_LOG_LEVEL=N.
///                           Logs go to the unified log, subsystem com.hsmm.macrosip.
struct LaunchOptions {
    var mockEngine = false
    var logLevel = 3
    var dataDirectory: URL?
    var demoState: String?
    var demoTab: String?
    var snapshotPrefix: String?
    var snapshotDelay = 6.0

    var isDemo: Bool { demoState != nil }

    static let current: LaunchOptions = {
        var o = LaunchOptions()
        let args = CommandLine.arguments
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--mock-engine": o.mockEngine = true
            case "--data-dir" where i + 1 < args.count:
                i += 1; o.dataDirectory = URL(fileURLWithPath: args[i], isDirectory: true)
            case "--demo-state" where i + 1 < args.count:
                i += 1; o.demoState = args[i]
            case "--snapshot" where i + 1 < args.count:
                i += 1; o.snapshotPrefix = args[i]
            case "--snapshot-after" where i + 1 < args.count:
                i += 1; o.snapshotDelay = Double(args[i]) ?? 6
            case "--demo-tab" where i + 1 < args.count:
                i += 1; o.demoTab = args[i]
            case "--log-level" where i + 1 < args.count:
                i += 1; o.logLevel = Int(args[i]) ?? o.logLevel
            default: break
            }
            i += 1
        }
        if !args.contains("--log-level"),
           let env = ProcessInfo.processInfo.environment["MACROSIP_LOG_LEVEL"], let n = Int(env) {
            o.logLevel = n
        }
        o.logLevel = max(0, min(6, o.logLevel))
        #if !DEBUG
        o.demoState = nil
        o.demoTab = nil
        o.snapshotPrefix = nil
        #endif
        if o.demoState != nil {
            o.mockEngine = true
            if o.dataDirectory == nil {
                o.dataDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MacroSIP-demo-\(o.demoState ?? "x")", isDirectory: true)
            }
        }
        return o
    }()
}
