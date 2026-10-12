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
    /// Status published to the accounts with `publishPresence` (Menu bar › My Status).
    public var presenceStatus: PresenceStatus

    public init(
        launchAtLogin: Bool = false,
        language: String? = nil,
        handleURLSchemes: Bool = true,
        askBeforeCallingFromURL: Bool = true,
        keepRunningInMenuBar: Bool = true,
        showDockIcon: Bool = true,
        doNotDisturb: Bool = false,
        presenceStatus: PresenceStatus = .available
    ) {
        self.launchAtLogin = launchAtLogin
        self.language = language
        self.handleURLSchemes = handleURLSchemes
        self.askBeforeCallingFromURL = askBeforeCallingFromURL
        self.keepRunningInMenuBar = keepRunningInMenuBar
        self.showDockIcon = showDockIcon
        self.doNotDisturb = doNotDisturb
        self.presenceStatus = presenceStatus
    }

    /// Older settings.json files lack `presenceStatus`; it decodes as `.available`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        language = try c.decodeIfPresent(String.self, forKey: .language)
        handleURLSchemes = try c.decodeIfPresent(Bool.self, forKey: .handleURLSchemes) ?? true
        askBeforeCallingFromURL = try c.decodeIfPresent(Bool.self, forKey: .askBeforeCallingFromURL) ?? true
        keepRunningInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .keepRunningInMenuBar) ?? true
        showDockIcon = try c.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? true
        doNotDisturb = try c.decodeIfPresent(Bool.self, forKey: .doNotDisturb) ?? false
        presenceStatus = try c.decodeIfPresent(PresenceStatus.self, forKey: .presenceStatus) ?? .available
    }
}

/// Settings › Recording (SCREENS.md 8.6).
public struct RecordingSettings: Codable, Equatable, Sendable {
    /// nil = `~/Music/MacroSIP Recordings` (created on first use).
    public var folder: URL?
    /// Security-scoped bookmark of `folder` when the user picked it in the open panel.
    public var folderBookmark: Data?
    public var recordAllCalls: Bool

    public init(folder: URL? = nil, folderBookmark: Data? = nil, recordAllCalls: Bool = false) {
        self.folder = folder
        self.folderBookmark = folderBookmark
        self.recordAllCalls = recordAllCalls
    }
}

/// Settings › Auto-answer (SCREENS.md 8.7).
public enum AutoAnswerMode: String, Codable, Sendable, CaseIterable {
    case off, all, contactsOnly
}

public struct AutoAnswerSettings: Codable, Equatable, Sendable {
    public var mode: AutoAnswerMode
    /// Seconds before answering, 1...60.
    public var delaySeconds: Int
    /// Answer when the INVITE carries `Call-Info: ...;answer-after=N`, even in mode `.off`.
    public var honourCallInfo: Bool

    public init(mode: AutoAnswerMode = .off, delaySeconds: Int = 5, honourCallInfo: Bool = true) {
        self.mode = mode
        self.delaySeconds = delaySeconds
        self.honourCallInfo = honourCallInfo
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
    public var recording: RecordingSettings
    public var autoAnswer: AutoAnswerSettings

    public init(
        network: NetworkSettings = .default,
        audio: AudioSettings = AudioSettings(),
        codecOrder: [String] = AppSettings.defaultCodecOrder,
        enabledCodecs: Set<String> = Set(AppSettings.defaultCodecOrder),
        general: GeneralSettings = GeneralSettings(),
        callLogLimit: Int = 1000,
        recording: RecordingSettings = RecordingSettings(),
        autoAnswer: AutoAnswerSettings = AutoAnswerSettings()
    ) {
        self.network = network
        self.audio = audio
        self.codecOrder = codecOrder
        self.enabledCodecs = enabledCodecs
        self.general = general
        self.callLogLimit = callLogLimit
        self.recording = recording
        self.autoAnswer = autoAnswer
    }

    /// Older settings.json files lack `recording` / `autoAnswer`; they decode as defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        network = try c.decodeIfPresent(NetworkSettings.self, forKey: .network) ?? .default
        audio = try c.decodeIfPresent(AudioSettings.self, forKey: .audio) ?? AudioSettings()
        codecOrder = try c.decodeIfPresent([String].self, forKey: .codecOrder) ?? AppSettings.defaultCodecOrder
        enabledCodecs = try c.decodeIfPresent(Set<String>.self, forKey: .enabledCodecs) ?? Set(AppSettings.defaultCodecOrder)
        general = try c.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? GeneralSettings()
        callLogLimit = try c.decodeIfPresent(Int.self, forKey: .callLogLimit) ?? 1000
        recording = try c.decodeIfPresent(RecordingSettings.self, forKey: .recording) ?? RecordingSettings()
        autoAnswer = try c.decodeIfPresent(AutoAnswerSettings.self, forKey: .autoAnswer) ?? AutoAnswerSettings()
    }

    public static let `default` = AppSettings()
}
