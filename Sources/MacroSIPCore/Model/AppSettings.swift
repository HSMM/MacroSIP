import Foundation

public enum RingtoneChoice: Codable, Equatable, Sendable {
    case builtIn
    case file(URL)
}

public struct AudioSettings: Codable, Equatable, Sendable {
    /// Device names (CoreAudio ids change); nil = system default.
    public var inputDeviceName: String?
    public var outputDeviceName: String?
    public var ringtoneDeviceName: String?
    public var ringtone: RingtoneChoice

    public init(
        inputDeviceName: String? = nil,
        outputDeviceName: String? = nil,
        ringtoneDeviceName: String? = nil,
        ringtone: RingtoneChoice = .builtIn
    ) {
        self.inputDeviceName = inputDeviceName
        self.outputDeviceName = outputDeviceName
        self.ringtoneDeviceName = ringtoneDeviceName
        self.ringtone = ringtone
    }
}

public struct GeneralSettings: Codable, Equatable, Sendable {
    public var launchAtLogin: Bool
    /// "en", "ru", or nil = system.
    public var language: String?
    public var handleURLSchemes: Bool
    public var askBeforeCallingFromURL: Bool
    public var keepRunningInMenuBar: Bool
    public var showDockIcon: Bool
    public var doNotDisturb: Bool

    public init(
        launchAtLogin: Bool = false,
        language: String? = nil,
        handleURLSchemes: Bool = true,
        askBeforeCallingFromURL: Bool = true,
        keepRunningInMenuBar: Bool = true,
        showDockIcon: Bool = true,
        doNotDisturb: Bool = false
    ) {
        self.launchAtLogin = launchAtLogin
        self.language = language
        self.handleURLSchemes = handleURLSchemes
        self.askBeforeCallingFromURL = askBeforeCallingFromURL
        self.keepRunningInMenuBar = keepRunningInMenuBar
        self.showDockIcon = showDockIcon
        self.doNotDisturb = doNotDisturb
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let defaultCodecOrder = ["opus/48000/2", "G722/16000/1", "PCMU/8000/1", "PCMA/8000/1"]

    public var network: NetworkSettings
    public var audio: AudioSettings
    public var codecOrder: [String]
    public var enabledCodecs: Set<String>
    public var general: GeneralSettings
    public var callLogLimit: Int

    public init(
        network: NetworkSettings = .default,
        audio: AudioSettings = AudioSettings(),
        codecOrder: [String] = AppSettings.defaultCodecOrder,
        enabledCodecs: Set<String> = Set(AppSettings.defaultCodecOrder),
        general: GeneralSettings = GeneralSettings(),
        callLogLimit: Int = 1000
    ) {
        self.network = network
        self.audio = audio
        self.codecOrder = codecOrder
        self.enabledCodecs = enabledCodecs
        self.general = general
        self.callLogLimit = callLogLimit
    }

    public static let `default` = AppSettings()
}
