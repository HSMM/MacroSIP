import AppKit
import Foundation
import MacroSIPCore

/// `macrosip-cli --import-microsip ...`: the same command as `MacroSIP --import-microsip ...` (`MicroSIPImportCommand`).
enum ImportCommand {
    static func run(_ args: [String]) -> Int32 {
        MicroSIPImportCommand.run(args, .init(program: "macrosip-cli", isAppRunning: {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: Product.bundleIdentifier)
            return MicroSIPImportCommand.isOtherProcess(among: running.map(\.processIdentifier), current: getpid())
        }))
    }
}
