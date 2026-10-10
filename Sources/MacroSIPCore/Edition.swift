/// Which edition this binary was compiled as. Decided at build time with `-DFULL`.
public enum Edition: String, Sendable {
    case lite
    case full

    public static let current: Edition = {
        #if FULL
        return .full
        #else
        return .lite
        #endif
    }()

    /// Product name shown to the user and used for the bundle.
    public var productName: String {
        switch self {
        case .lite: return "MacroSIP Lite"
        case .full: return "MacroSIP"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .lite: return "com.hsmm.macrosip.lite"
        case .full: return "com.hsmm.macrosip"
        }
    }
}
