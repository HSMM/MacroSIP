import Foundation

public enum RingtoneChoice: Codable, Equatable, Sendable {
    case builtIn
    case file(URL)
}

/// What the far end hears while a call is on local hold (`Engine.setHoldMusic`).
public enum HoldMusic: Codable, Equatable, Sendable {
    /// A short generated melody, looped.
    case builtIn
    /// An audio file played in a loop: WAV as is; M4A, MP3 and other formats are converted
    /// once to a temporary WAV by the engine.
    case file(URL)
    /// Silence (the far end hears nothing while held).
    case off
}

/// Which short UI sounds the app plays through `Engine.playEventSound` (all off by default;
/// the app decides when to play them).
public struct SoundEventSettings: Codable, Equatable, Sendable {
    /// `.callConnected` and `.callEnded`.
    public var callEvents: Bool
    /// `.keyPress(digit)` on the dial pad.
    public var keyPress: Bool
    /// `.voicemail` when a new message arrives.
    public var voicemail: Bool
    /// `.error` when a call or registration fails.
    public var error: Bool

    public init(callEvents: Bool = false, keyPress: Bool = false, voicemail: Bool = false, error: Bool = false) {
        self.callEvents = callEvents
        self.keyPress = keyPress
        self.voicemail = voicemail
        self.error = error
    }

    /// Missing keys decode as off.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        callEvents = (try? c.decodeIfPresent(Bool.self, forKey: .callEvents)) ?? false
        keyPress = (try? c.decodeIfPresent(Bool.self, forKey: .keyPress)) ?? false
        voicemail = (try? c.decodeIfPresent(Bool.self, forKey: .voicemail)) ?? false
        error = (try? c.decodeIfPresent(Bool.self, forKey: .error)) ?? false
    }
}

public struct AudioSettings: Codable, Equatable, Sendable {
    /// Device names (CoreAudio ids change); nil = system default.
    public var inputDeviceName: String?
    public var outputDeviceName: String?
    public var ringtoneDeviceName: String?
    public var ringtone: RingtoneChoice
    /// Ringtone loudness, 0...1.
    public var ringtoneVolume: Float
    /// Speaker and microphone gain of calls, 0...2 (1 = unity). The default for every new call.
    public var callSpeakerVolume: Float
    public var callMicrophoneVolume: Float
    /// Use a headset (input and output in one device) as soon as it is connected.
    public var followNewDevices: Bool
    /// What the far end hears while a call is on hold.
    public var holdMusic: HoldMusic
    /// Short UI sounds (`Engine.playEventSound`).
    public var soundEvents: SoundEventSettings
    /// Answer, hang up and mute from the buttons of a USB headset (Settings › Audio). Default on.
    public var headsetButtons: Bool

    public static let callVolumeRange: ClosedRange<Float> = 0...2

    public init(
        inputDeviceName: String? = nil,
        outputDeviceName: String? = nil,
        ringtoneDeviceName: String? = nil,
        ringtone: RingtoneChoice = .builtIn,
        ringtoneVolume: Float = 1,
        callSpeakerVolume: Float = 1,
        callMicrophoneVolume: Float = 1,
        followNewDevices: Bool = true,
        holdMusic: HoldMusic = .builtIn,
        soundEvents: SoundEventSettings = SoundEventSettings(),
        headsetButtons: Bool = true
    ) {
        self.inputDeviceName = inputDeviceName
        self.outputDeviceName = outputDeviceName
        self.ringtoneDeviceName = ringtoneDeviceName
        self.ringtone = ringtone
        self.ringtoneVolume = ringtoneVolume
        self.callSpeakerVolume = callSpeakerVolume
        self.callMicrophoneVolume = callMicrophoneVolume
        self.followNewDevices = followNewDevices
        self.holdMusic = holdMusic
        self.soundEvents = soundEvents
        self.headsetButtons = headsetButtons
    }

    /// Older settings.json files lack the volumes, `followNewDevices`, `holdMusic`, `soundEvents`
    /// and `headsetButtons`; they decode as defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputDeviceName = try c.decodeIfPresent(String.self, forKey: .inputDeviceName)
        outputDeviceName = try c.decodeIfPresent(String.self, forKey: .outputDeviceName)
        ringtoneDeviceName = try c.decodeIfPresent(String.self, forKey: .ringtoneDeviceName)
        ringtone = try c.decodeIfPresent(RingtoneChoice.self, forKey: .ringtone) ?? .builtIn
        ringtoneVolume = Self.clamp(try c.decodeIfPresent(Float.self, forKey: .ringtoneVolume) ?? 1, 0...1)
        callSpeakerVolume = Self.clamp(try c.decodeIfPresent(Float.self, forKey: .callSpeakerVolume) ?? 1, Self.callVolumeRange)
        callMicrophoneVolume = Self.clamp(try c.decodeIfPresent(Float.self, forKey: .callMicrophoneVolume) ?? 1, Self.callVolumeRange)
        followNewDevices = try c.decodeIfPresent(Bool.self, forKey: .followNewDevices) ?? true
        holdMusic = (try? c.decodeIfPresent(HoldMusic.self, forKey: .holdMusic)) ?? .builtIn
        soundEvents = (try? c.decodeIfPresent(SoundEventSettings.self, forKey: .soundEvents)) ?? SoundEventSettings()
        headsetButtons = (try? c.decodeIfPresent(Bool.self, forKey: .headsetButtons)) ?? true
    }

    private static func clamp(_ v: Float, _ r: ClosedRange<Float>) -> Float { v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : 1 }
}

public struct GeneralSettings: Codable, Equatable, Sendable {
    public var launchAtLogin: Bool
    /// A language code from `languages` or nil = system.
    public var language: String?
    /// The interface languages the app ships.
    public static let languages = ["en", "ru"]
    public var handleURLSchemes: Bool
    public var askBeforeCallingFromURL: Bool
    public var keepRunningInMenuBar: Bool
    public var showDockIcon: Bool
    public var doNotDisturb: Bool
    /// Timed Do Not Disturb: when it ends. nil = until switched off by hand. Only meaningful while `doNotDisturb` is on.
    public var doNotDisturbUntil: Date?
    /// Show and activate the main window when a call rings, in addition to the floating panel.
    public var bringToFrontOnIncoming: Bool
    /// Status published to the accounts with `publishPresence` (Menu bar › My Status).
    public var presenceStatus: PresenceStatus
    /// Order and section letters of the Contacts tab (Settings › General › Contacts).
    public var contactSort: ContactSortOrder

    public init(
        launchAtLogin: Bool = false,
        language: String? = nil,
        handleURLSchemes: Bool = true,
        askBeforeCallingFromURL: Bool = true,
        keepRunningInMenuBar: Bool = true,
        showDockIcon: Bool = true,
        doNotDisturb: Bool = false,
        doNotDisturbUntil: Date? = nil,
        bringToFrontOnIncoming: Bool = false,
        presenceStatus: PresenceStatus = .available,
        contactSort: ContactSortOrder = .firstName
    ) {
        self.launchAtLogin = launchAtLogin
        self.language = language
        self.handleURLSchemes = handleURLSchemes
        self.askBeforeCallingFromURL = askBeforeCallingFromURL
        self.keepRunningInMenuBar = keepRunningInMenuBar
        self.showDockIcon = showDockIcon
        self.doNotDisturb = doNotDisturb
        self.doNotDisturbUntil = doNotDisturbUntil
        self.bringToFrontOnIncoming = bringToFrontOnIncoming
        self.presenceStatus = presenceStatus
        self.contactSort = contactSort
    }

    /// Older settings.json files lack `presenceStatus`, `doNotDisturbUntil` and `bringToFrontOnIncoming`; they decode as defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        language = try c.decodeIfPresent(String.self, forKey: .language)
        handleURLSchemes = try c.decodeIfPresent(Bool.self, forKey: .handleURLSchemes) ?? true
        askBeforeCallingFromURL = try c.decodeIfPresent(Bool.self, forKey: .askBeforeCallingFromURL) ?? true
        keepRunningInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .keepRunningInMenuBar) ?? true
        showDockIcon = try c.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? true
        doNotDisturb = try c.decodeIfPresent(Bool.self, forKey: .doNotDisturb) ?? false
        doNotDisturbUntil = try c.decodeIfPresent(Date.self, forKey: .doNotDisturbUntil)
        bringToFrontOnIncoming = try c.decodeIfPresent(Bool.self, forKey: .bringToFrontOnIncoming) ?? false
        presenceStatus = try c.decodeIfPresent(PresenceStatus.self, forKey: .presenceStatus) ?? .available
        contactSort = try c.decodeIfPresent(ContactSortOrder.self, forKey: .contactSort) ?? .firstName
    }
}

/// Settings › Recording (SCREENS.md 8.6).
public struct RecordingSettings: Codable, Equatable, Sendable {
    /// nil = `~/Music/MacroSIP Recordings` (created on first use).
    public var folder: URL?
    /// Security-scoped bookmark of `folder` when the user picked it in the open panel.
    public var folderBookmark: Data?
    public var recordAllCalls: Bool
    /// One mixed channel, or me on the left and the caller on the right. Default mono.
    public var layout: RecordingLayout
    /// A short beep for both parties every `noticeToneIntervalSeconds` while a call is
    /// recorded (`Engine.setRecordingNotice`). Default off.
    public var noticeTone: Bool
    /// Seconds between notice beeps, `noticeIntervalRange`. Default 15.
    public var noticeToneIntervalSeconds: Int

    public static let noticeIntervalRange: ClosedRange<Int> = 5...60
    public static let defaultNoticeInterval = 15

    public init(folder: URL? = nil, folderBookmark: Data? = nil, recordAllCalls: Bool = false,
                layout: RecordingLayout = .mono, noticeTone: Bool = false,
                noticeToneIntervalSeconds: Int = RecordingSettings.defaultNoticeInterval) {
        self.folder = folder
        self.folderBookmark = folderBookmark
        self.recordAllCalls = recordAllCalls
        self.layout = layout
        self.noticeTone = noticeTone
        self.noticeToneIntervalSeconds = Self.clampInterval(noticeToneIntervalSeconds)
    }

    /// Older settings.json files lack `layout` and the notice tone; they decode as mono / off.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folder = try c.decodeIfPresent(URL.self, forKey: .folder)
        folderBookmark = try c.decodeIfPresent(Data.self, forKey: .folderBookmark)
        recordAllCalls = try c.decodeIfPresent(Bool.self, forKey: .recordAllCalls) ?? false
        layout = (try? c.decodeIfPresent(RecordingLayout.self, forKey: .layout)) ?? .mono
        noticeTone = (try? c.decodeIfPresent(Bool.self, forKey: .noticeTone)) ?? false
        noticeToneIntervalSeconds = Self.clampInterval(
            (try? c.decodeIfPresent(Int.self, forKey: .noticeToneIntervalSeconds)) ?? Self.defaultNoticeInterval)
    }

    /// Into `noticeIntervalRange`.
    public static func clampInterval(_ seconds: Int) -> Int {
        min(max(seconds, noticeIntervalRange.lowerBound), noticeIntervalRange.upperBound)
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
    /// Opus FEC and DTX (Settings › Codecs).
    public var codecOptions: CodecOptions
    /// Second call while on a call, DTMF method (Settings › General › Calls).
    public var callOptions: CallOptions
    /// Speed-dial and BLF panel (screen 11).
    public var quickKeys: QuickKeysSettings
    /// Directory sources and search options (screen 13).
    public var directory: DirectorySettings

    public init(
        network: NetworkSettings = .default,
        audio: AudioSettings = AudioSettings(),
        codecOrder: [String] = AppSettings.defaultCodecOrder,
        enabledCodecs: Set<String> = Set(AppSettings.defaultCodecOrder),
        general: GeneralSettings = GeneralSettings(),
        callLogLimit: Int = 1000,
        recording: RecordingSettings = RecordingSettings(),
        autoAnswer: AutoAnswerSettings = AutoAnswerSettings(),
        codecOptions: CodecOptions = CodecOptions(),
        callOptions: CallOptions = CallOptions(),
        quickKeys: QuickKeysSettings = QuickKeysSettings(),
        directory: DirectorySettings = DirectorySettings()
    ) {
        self.network = network
        self.audio = audio
        self.codecOrder = codecOrder
        self.enabledCodecs = enabledCodecs
        self.general = general
        self.callLogLimit = callLogLimit
        self.recording = recording
        self.autoAnswer = autoAnswer
        self.codecOptions = codecOptions
        self.callOptions = callOptions
        self.quickKeys = quickKeys
        self.directory = directory
    }

    /// Older settings.json files lack `recording` / `autoAnswer` / `codecOptions` / `callOptions` / `quickKeys` / `directory`; they decode as defaults.
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
        codecOptions = (try? c.decodeIfPresent(CodecOptions.self, forKey: .codecOptions)) ?? CodecOptions()
        callOptions = (try? c.decodeIfPresent(CallOptions.self, forKey: .callOptions)) ?? CallOptions()
        quickKeys = (try? c.decodeIfPresent(QuickKeysSettings.self, forKey: .quickKeys)) ?? QuickKeysSettings()
        directory = (try? c.decodeIfPresent(DirectorySettings.self, forKey: .directory)) ?? DirectorySettings()
    }

    public static let `default` = AppSettings()
}
