import Foundation

/// Product identity (ADR 0003).
public enum Product {
    public static let name = "MacroSIP"
    public static let bundleIdentifier = "com.hsmm.macrosip"

    /// The version of the running app: `CFBundleShortVersionString`, which `make-app.sh` takes from the nearest
    /// git tag (ADR 0010), so an rc build reports its rc. Tools and tests without a bundle fall back to
    /// `fallbackVersion`, the last final release.
    public static let version: String = {
        if let s = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !s.isEmpty,
           s.first?.isNumber == true { return s }
        return fallbackVersion
    }()

    public static let fallbackVersion = "26.0.1"
}
