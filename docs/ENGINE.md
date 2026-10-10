# Engine design (MacroSIPCore)

The engine is the only code that talks to PJSIP. The UI never imports `CPJSUA`.

## Threading model
- PJSIP demands that every `pjsua_*` call comes from a thread registered with `pj_thread_register`, and that its callbacks are not blocked.
- `Engine` is a Swift `actor` whose executor is a dedicated serial `DispatchQueue("macrosip.engine")`. The queue's thread registers itself with PJSIP on first use (`pj_thread_register` guarded by a thread-local flag). All `pjsua_*` calls run inside the actor.
- PJSIP callbacks (`on_reg_state2`, `on_incoming_call`, `on_call_state`, `on_call_media_state`, `on_call_transfer_status`, `on_buddy_state`, `on_dtmf_digit2`...) run on PJSIP worker threads. They copy the minimal data into an `EngineEvent` value and hand it to `Engine.events` (an `AsyncStream<EngineEvent>`), returning immediately. They never call back into the actor synchronously and never touch UI.
- `pjsua_config.thread_cnt = 1` and `cb` struct set once in `start()`. No `pjsua_handle_events` polling; the worker thread does it.
- Audio device changes (`pjsua_set_snd_dev2`) also happen inside the actor.

## Public types (all `Sendable`, `Codable` where persisted)
```swift
public struct AccountID: Hashable, Codable { let raw: UUID }
public enum TransportKind: String, Codable { case udp, tcp, tls }
public enum SRTPMode: String, Codable { case disabled, optional, mandatory }

public struct AccountConfig: Codable, Identifiable, Equatable {
    public var id: AccountID
    public var displayName: String          // "Office"
    public var username: String             // "1001"
    public var domain: String               // "sip.example.com"
    public var registrar: String?           // nil = domain
    public var outboundProxy: String?       // "sip:proxy.example.com:5061;transport=tls"
    public var authID: String?              // nil = username
    public var transport: TransportKind
    public var srtp: SRTPMode
    public var enabled: Bool                // register on start
    public var isDefaultOutgoing: Bool
    public var registrationInterval: Int    // seconds, default 300
    public var publishPresence: Bool        // FULL
    // password is NOT here; it lives in Keychain under id
}

public enum RegistrationState: Equatable { case unregistered, registering, registered(expires: Int), failed(code: Int, reason: String) }

public struct CallID: Hashable { let raw: Int32 }   // pjsua_call_id
public enum CallDirection { case incoming, outgoing }
public enum CallState: Equatable { case incoming, calling, early, connecting, connected, held, disconnected(code: Int, reason: String) }

public struct RemoteParty: Equatable { public var displayName: String?; public var uri: String; public var number: String }

public struct CallInfo: Identifiable, Equatable {
    public var id: CallID
    public var accountID: AccountID
    public var direction: CallDirection
    public var state: CallState
    public var remote: RemoteParty
    public var startedAt: Date?             // when connected
    public var isMuted: Bool
    public var isOnHold: Bool               // local hold
    public var isRecording: Bool            // FULL
    public var inConference: Bool           // FULL
    public var codec: String?               // "opus/48000"
    public var isSecure: Bool               // SRTP active
}

public struct AudioDevice: Identifiable, Equatable { public var id: Int; public var name: String; public var inputChannels: Int; public var outputChannels: Int }
public struct CodecInfo: Identifiable, Equatable { public var id: String; public var priority: UInt8 }

public struct NetworkSettings: Codable, Equatable {
    public var stunServer: String?          // nil = off
    public var localPort: UInt16            // 0 = random
    public var keepAliveSeconds: Int        // 15
    public var useICE: Bool                 // false
    public var echoCancellation: Bool       // true
}

public enum PresenceStatus: String, Codable { case available, away, dnd, offline }   // FULL

public enum EngineEvent: Sendable {
    case registration(AccountID, RegistrationState)
    case incomingCall(CallInfo)
    case callChanged(CallInfo)
    case callEnded(CallInfo, duration: TimeInterval)
    case transferStatus(CallID, code: Int, final: Bool)
    case dtmfReceived(CallID, digit: Character)
    case buddyPresence(contactURI: String, PresenceStatus)   // FULL
    case audioDevicesChanged
    case log(level: Int, String)
}
```

## Engine API
```swift
public actor Engine {
    public nonisolated let events: AsyncStream<EngineEvent>
    public init(logLevel: Int = 3)
    public func start(network: NetworkSettings, codecPriorities: [String]) throws
    public func stop()

    // accounts
    public func addAccount(_ cfg: AccountConfig, password: String) throws
    public func updateAccount(_ cfg: AccountConfig, password: String?) throws
    public func removeAccount(_ id: AccountID) throws
    public func setRegistered(_ id: AccountID, _ on: Bool) throws
    public func registrationState(of id: AccountID) -> RegistrationState

    // calls
    public func makeCall(to dial: DialString, from account: AccountID) throws -> CallID
    public func answer(_ id: CallID) throws
    public func reject(_ id: CallID, code: Int = 486) throws
    public func hangup(_ id: CallID) throws
    public func hangupAll()
    public func setHold(_ id: CallID, _ on: Bool) throws       // holding one call un-holds nothing else; UI decides
    public func setMute(_ id: CallID, _ on: Bool) throws       // disconnects mic from the call's conf port
    public func sendDTMF(_ id: CallID, _ digits: String) throws   // RFC 2833, INFO fallback
    public func blindTransfer(_ id: CallID, to dial: DialString) throws
    public func attendedTransfer(_ id: CallID, replacing other: CallID) throws   // REFER with Replaces
    public func calls() -> [CallInfo]

    // audio
    public func audioDevices() -> [AudioDevice]
    public func setAudioDevices(input: Int?, output: Int?) throws
    public func setRingtoneDevice(_ id: Int?)
    public func codecs() -> [CodecInfo]
    public func setCodecPriorities(_ ordered: [String]) throws

    #if FULL
    public func merge(_ ids: [CallID]) throws        // connect all conf ports pairwise + mic/speaker
    public func split(_ id: CallID) throws
    public func startRecording(_ id: CallID, to wavURL: URL) throws
    public func stopRecording(_ id: CallID) throws -> URL
    public func subscribePresence(uri: String) throws
    public func unsubscribePresence(uri: String) throws
    public func publishPresence(_ status: PresenceStatus, for account: AccountID) throws
    #endif
}
```

## Dial strings
`DialString.parse(_ raw: String, account: AccountConfig) -> DialString` yields a full SIP URI:
- `sip:user@host` / `sips:` → used as is.
- `tel:+7495...` → digits only, then `sip:<digits>@<domain>`.
- `100`, `+7 (495) 123-45-67`, `*72` → strip spaces, parens, dashes; `sip:<result>@<domain>`; transport parameter appended if the account uses TCP/TLS.
- Anything containing `@` without a scheme → prefix `sip:`.
Pure Swift, tested.

## Ringtone and ringback
- Incoming: `pjsua_player` with the ringtone WAV looped to the ringtone device (separate `pjmedia_snd_port` if the device differs from the call output). Stops on answer/decline.
- Outgoing early media absent: generate ringback tone with `pjmedia_tonegen` connected to the speaker.

## Storage (MacroSIPCore, no PJSIP)
- `JSONStore<T: Codable>`: atomic write to `~/Library/Application Support/MacroSIP/<name>.json` (`FileManager.replaceItemAt`), load with default on missing/corrupt (corrupt file renamed `.broken-<timestamp>`).
- `AccountStore`, `ContactStore`, `CallLogStore`, `SettingsStore` wrap it.
- `Keychain`: `set(password:for: AccountID)`, `password(for:)`, `delete(for:)`; service `com.hsmm.macrosip` (edition-independent so accounts carry over), account = UUID string.

## Error handling
`EngineError.pjsip(status: Int32, message: String)` built from `pj_strerror`. Every `pjsua_*` return value is checked. Errors never crash the engine; a failed registration becomes `RegistrationState.failed`.

## Tests (Swift Testing)
- DialString parsing table.
- JSONStore round trip, corrupt file recovery.
- Keychain with a test service name.
- Auto-answer rules (`AutoAnswerPolicy.decide(call:, contacts:, settings:) -> delay?`), FULL.
- Engine smoke: start, add an account with `enabled=false`, list codecs, stop (no network).
