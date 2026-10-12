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
    public var publishPresence: Bool
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
    public var isRecording: Bool
    public var inConference: Bool
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

public enum PresenceStatus: String, Codable { case available, away, dnd, offline }

public enum EngineEvent: Sendable {
    case registration(AccountID, RegistrationState)
    case incomingCall(CallInfo)
    case callChanged(CallInfo)
    case callEnded(CallInfo, duration: TimeInterval)
    case transferStatus(CallID, code: Int, final: Bool)
    case dtmfReceived(CallID, digit: Character)
    case buddyPresence(contactURI: String, PresenceStatus)
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

    public func merge(_ ids: [CallID]) throws        // connect all conf ports pairwise + mic/speaker
    public func split(_ id: CallID) throws
    public func startRecording(_ id: CallID, to wavURL: URL) throws
    public func stopRecording(_ id: CallID) throws -> URL
    public func subscribePresence(uri: String) throws
    public func unsubscribePresence(uri: String) throws
    public func publishPresence(_ status: PresenceStatus, for account: AccountID) throws
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
- `Keychain`: `set(password:for: AccountID)`, `password(for:)`, `delete(for:)`; service `com.hsmm.macrosip` (so accounts carry over), account = UUID string.

## Error handling
`EngineError.pjsip(status: Int32, message: String)` built from `pj_strerror`. Every `pjsua_*` return value is checked. Errors never crash the engine; a failed registration becomes `RegistrationState.failed`.

## Tests (Swift Testing)
- DialString parsing table.
- JSONStore round trip, corrupt file recovery.
- Keychain with a test service name.
- Auto-answer rules (`AutoAnswerPolicy.decide(call:, contacts:, settings:) -> delay?`).
- Engine smoke: start, add an account with `enabled=false`, list codecs, stop (no network).

## Implementation notes (milestone 2)
Code: `Sources/MacroSIPCore/Engine/` (Engine, EngineBridge, EngineTypes, AccountMapping, PJSupport, TonePlayer, AudioDeviceWatcher), C helpers in `Sources/CPJSUA`, manual phone `macrosip-cli` (`--selftest` runs the localhost call check).

- **Executor and threads.** `Engine.unownedExecutor` is a `DispatchSerialQueue("macrosip.engine")`. GCD may run it on different pool threads, so every entry point calls `cpjsua_thread_register()` (C11 `_Thread_local pj_thread_desc`, no-op once registered, re-registers after a pjsua restart).
- **Callback bridge.** pjsua callbacks are C function pointers without context, so they are global Swift functions that reach the engine through `EngineBridge.shared` (a `Sendable` class over `OSAllocatedUnfairLock`; no `nonisolated(unsafe)`). A callback reads PJSIP data, updates the registry, yields the event and, when the engine must act (conference wiring, ringtone, hang-up after transfer), schedules `Task { await engine.… }`. Follow-up work is idempotent (reconcile current state), so its ordering does not matter.
- **Events.** Single consumer. They are yielded from PJSIP threads and the actor, so the UI iterates on `@MainActor`. `CallID` is `(raw: pjsua slot, serial)`: slots are reused, serials never are, and a stale `CallID` throws `.noSuchCall`. Upsert UI rows on `.incomingCall`/`.callChanged` (the first `.callChanged` of an outgoing call can arrive before `makeCall` returns) and remove them on `.callEnded`. A fifth incoming call gets 486 and appears only as `.callEnded(... .disconnected(code: 486 ...))`. Incoming calls stay `.incoming` while ringing (pjsua state EARLY after the automatic 180). `.callEnded` repeats the last codec/SRTP state and `duration` is the connected time (0 if never answered). `CallState.held` means local hold (`isOnHold`); remote hold stays `.connected`.
- **Deviations / additions.** `CallID` gained `serial`. `CallDirection` is the call-log enum from `Model/CallLogEntry.swift` (it also has `missed`, never produced by the engine). `Engine.init` takes `nullAudio` and `bindAddress` (bind SIP and RTP to one address; needed for localhost calls when the default route is a VPN). Additive API: `mediaStats(_:)`, `localPort(of:)`, `setRingtoneFile(_:)` (hook for the bundled WAV; nil = generated tone), `silenceRingtone()`, `inputLevel()`. `EngineError` has more cases than `.pjsip`. Conference, recording and presence members were stubs (`.unsupported`) until milestone 5; see below.
- **PJSIP specifics.** Calls are audio-only with `txt_cnt = 0`; the pjsua default offers an RFC 4103 text m-line that breaks un-hold. RTP base port 4000 is randomized within a 16000-port range. VAD is off. Codec priorities start at 254 because PJSIP demotes 255 and creates a tie; unlisted codecs get 0 (disabled). After a successful transfer (final 2xx NOTIFY) the engine hangs up the transferred leg. `updateAccount` uses `disable_reg_on_modify` and re-registers explicitly. The old binding is not un-REGISTERed when the registrar changes; it expires on the server.
- **Review fixes (milestone 2.1).**
  - TLS: two listeners. The default one verifies the server: the macOS system roots are exported at `start` to `Application Support/MacroSIP/ca-roots.pem` (path injectable) for OpenSSL, and PJSIP sets SNI and checks CN/SAN against the request's destination host. Accounts with `AccountConfig.verifyTLSCertificate == false` (decodes as `true` from older JSON) use the second, non-verifying listener and get a `.log` warning. If the export fails, verification fails closed.
  - Registration: switching off never throws because of the registration's own state. PJSIP's "nothing registered" (`PJ_EINVALIDOP`) means done; "transaction in flight" (`PJSIP_EBUSY`, either direction) is remembered and repeated when the transaction completes. `updateAccount` always applies the new configuration. `addAccount` validates the id, registrar and proxy URIs with `pjsua_verify_sip_url` and rolls back if the registration cannot start. A 2xx without Expires counts as registered for the account's interval.
  - Calls: `CallID` serials continue across stop/start. Engine-side updates (`setMute`, `setHold`, `calls()`) never create call records, and call events are yielded inside the bridge lock, so no `.callChanged` follows a call's `.callEnded`. Conference wiring tracks the last requested state, because PJSIP 2.17 queues (dis)connections until the next audio frame.
  - Audio devices are remembered by name (`setAudioDevices(inputName:outputName:)`, `setRingtoneDevice(name:)`; the index variants store names too) and re-resolved after every device-list change.

## Implementation notes (milestone 5)
Code: `Engine+Conference.swift` (merge/split and the conference bridge wiring), `Engine+Recording.swift`, `Engine+Presence.swift`; bridge additions in `EngineBridge.swift`; `SignallingSource` in `PJSupport.swift`; C helpers in `Sources/CPJSUA` (recorder create/destroy-and-wait, buddy snapshot and token, NOTIFY body scan, presence publish, Call-Info parser, packet source). Public signatures are unchanged; `CallInfo.inConference`, `isRecording` and `answerAfter` are now filled. Additive public API: `Engine.recordingIsEmpty(_:)`.

- **Conference model.** A conference is a group id in the bridge's `CallRecord.conference` (`inConference = conference != nil`, announced with `.callChanged`). `merge(ids)`: 2...`maxConcurrentCalls` distinct ids, each live (stale -> `.noSuchCall`) and CONFIRMED (`.connected`/`.held`; ringing, dialling, connecting -> `.invalidArgument`). Held legs are resumed first (re-INVITE with `PJSUA_CALL_UNHOLD`); they join the mix once their media is active again. A leg that is already in a conference brings its conference along (the lowest id survives). `split(id)` clears the flag on that leg; a conference left with one leg is dissolved (that leg gets `inConference == false` too). The same happens when a leg ends: with 3+ legs the others stay joined, the last remaining leg leaves. The split leg keeps microphone and speaker; holding it is the UI's decision. `merge`/`split` rewire the bridge even when they throw half-way.
- **Bridge wiring is one desired-state reconcile** (`reconcileMedia()`, replaces the per-call version). From all live calls and recordings it computes the wanted connections and diffs them against `requestedWiring`: per leg with media up (active or remote hold) leg->speaker, mic->leg unless muted; conference legs with media up transmit to each other both ways; a recorder gets its call, that call's conference partners and the mic (unless the recorded call is muted). A leg on local hold (or without media) is connected to nothing, but keeps its conference membership. `slotOwners` remembers who owned each conference slot; requests for a slot whose owner changed or vanished are forgotten (PJSIP dropped them with the port), which keeps slot reuse safe. Tone players connect themselves and are not touched.
- **Recording.** `pjsua_recorder_create` (WAV, 16-bit PCM mono at the conference clock rate, 16 kHz by default; the file name must end in `.wav`), parent directory created, existing file overwritten, one recorder per call. Nothing is written while the call is held; the mic is left out while muted. A file that only has the 44-byte header (held all the time) is still returned; `Engine.recordingIsEmpty(url)` tells the UI to delete it.
- **A conference recording belongs to the conference.** `startRecording` on a leg whose conference is already recorded -> `.invalidArgument("the conference of call X is already being recorded (by Y)")`; `stopRecording` on any leg of a conference stops the conference's recording (the owner is resolved through membership) and clears `isRecording` on the owner. When the owning leg is split off or ends while other legs of its conference remain, `rehomeRecordings()` (start of every `reconcileMedia`, and before conferences are dissolved in `split` and after a call ended) moves the recorder - same pjsua recorder, same file, which keeps growing - to the first remaining leg without its own recording: `.callChanged` for the new owner (`isRecording` true) and, if the old owner is still live, for it (false); an ended old owner's `.callEnded` carries `isRecording == false`. A conference whose legs were all recorded before the merge (auto-record) keeps one recording per leg, each with the whole mix; such a recording is not moved onto a leg that has its own. `isRecording` is true only on the owning leg; the UI shows REC for the conference when any leg has it.
- **PJSIP 2.17: the WAV header is finished asynchronously.** Conference ports are removed on the next audio frame, and the WAV writer writes the RIFF/data sizes in its `on_destroy`, which runs when the bridge drops its group-lock reference. `cpjsua_recorder_destroy_wait` adds a group-lock destroy handler to the recorder port (handlers run FIFO, so it runs after the writer's own), calls `pjsua_recorder_destroy` and waits up to 150 ms (typically one 20 ms frame) on the engine queue. If the bridge does not run in time (no sound clock), the engine patches the RIFF and data sizes from the file length itself (`WAVFile.repair`) and logs it, so the returned file is always valid; PJSIP rewrites the header (and appends what it still buffered) when it processes the removal later, at the latest in `pjsua_destroy`. Not exercised by tests (the null sound device always runs); the repair function is.
- **Recording at call end (deviation).** PJSIP deinitialises the call's media (queues the removal of its conference port) *before* `on_call_state(DISCONNECTED)`, so the recorder cannot be stopped before the port goes; it is stopped by the follow-up on the actor right after (at most the last frame is lost). To keep "`.callEnded` with `isRecording` = a finished file", the bridge holds back the `.callEnded` of a recorded call (`deferredEnds`, keyed by serial) and releases it after the WAV is finalised (typically ~20 ms later) or after the recording moved to another leg (then with `isRecording == false`). The record is still removed in the callback, so no `.callChanged` can follow. `stop()` finalises all recordings before `pjsua_call_hangup_all` and releases the held-back events after `pjsua_destroy`.
- **Call-Info answer-after (security).** In `on_incoming_call` every `Call-Info` header of the INVITE is printed with `pjsip_hdr_print_on` (PJSIP has no dedicated parser for it) and scanned for an `answer-after=N` parameter: after any `;` (`<sip:pbx>;answer-after=0`, the bare `;answer-after=5`) or at the start of the value, case-insensitive, blanks around `;`/`=` and a quoted number accepted, capped at 86400; first match wins. It is honoured only when the INVITE comes from the account's own server, because pjsua routes INVITEs that match no account to the default account and anyone who reaches the SIP port could otherwise make us answer with the microphone open. Trusted sources per pjsua account: the source of the last REGISTER 2xx (`cbparam->rdata->pkt_info.src_name/src_port` and transport, stored in `on_reg_state2`, cleared when the account is not registered, removed, or gets another registrar/proxy/transport), and the configured outbound proxy when it is an IP literal (a host-name proxy is covered by its REGISTER answer, since REGISTER goes through it). Match: same transport and IP address; over UDP also the same port (TCP/TLS servers may open a new connection from another port). Otherwise `answerAfter` stays nil and `.log` says "call N: ignored answer-after from untrusted source ADDR:PORT/transport". An unregistered account therefore never auto-answers by header. Tests cover both paths: a raw-UDP INVITE (untrusted, nil + warning) and a registrar stub that answers REGISTER with 200 and then sends the INVITE from the same socket (trusted, 5; another port on the same host is not trusted).
- **Presence (watching).** `subscribePresence(uri:)` normalises the URI (trim, drop `<...>`, lower-case scheme, add `sip:`; `tel:`, other schemes and empty input -> `.invalidArgument`, then `pjsua_verify_sip_url`), keys the subscription by it (second subscribe = no-op) and calls `pjsua_buddy_add` with `subscribe = PJ_TRUE`, no fixed account (pjsua picks it per request with `pjsua_acc_find_for_outgoing`: domain match, else the default) and a token (a fresh serial) as user data. Events are matched by that token, never by the URI (pjsua buddy ids are reused, URIs may be long); the watch entry exists before `pjsua_buddy_add` because pjsua may call `on_buddy_state` from inside it. `.buddyPresence` carries the URI exactly as first passed (the UI normalises its own key) and is emitted only when the status changed. pjsua's `pjsua_buddy_add` asserts (aborts a debug build) beyond `PJSUA_MAX_BUDDIES` (256), so the engine throws `.invalidArgument("too many presence subscriptions (limit 256)")` first. `unsubscribePresence` calls `pjsua_buddy_del` first (it takes the dialog lock and clears the subscription's module data, so no callback runs after it) and forgets the URI only on success; unknown URIs are a no-op. A failed SUBSCRIBE is retried by pjsua only after 300 s, so the engine calls `pjsua_buddy_update_pres` (no-op for active subscriptions) for the buddies an account serves after `updateAccount` and when that account becomes registered. `stop()` clears the list without events; after a restart the caller subscribes again. `on_pager` stays unset.
- **Presence mapping.** Subscription TERMINATED or basic status offline/unknown -> `.offline`. Online: RPID activity busy or on-the-phone -> `.dnd`, away -> `.away`; with no known activity a note of "On the phone", "Busy", "Ringing" or "Do Not Disturb" (case-insensitive, trimmed) -> `.dnd`; else `.available`. pjrpid only recognises `busy` and `away` and reports Asterisk/FreePBX's `<rpid:on-the-phone/>` as unknown and does not expose the element, so `on_buddy_evsub_state` (which pjsua calls right before `on_buddy_state` for the same NOTIFY) scans the received NOTIFY body for `on-the-phone` and keeps a per-buddy flag; a NOTIFY without it clears the flag. The first event is usually `.offline` (subscription SENT, no NOTIFY yet). `on_buddy_state` fires for every NOTIFY (PJSIP's evsub calls `on_evsub_state` on each one). A test stub (accepts SUBSCRIBE, sends Asterisk-style PIDF NOTIFYs) checks activity-only on-the-phone, notes, away and closed.
- **Presence (publishing).** `AccountMapping` sets `publish_enabled` from `AccountConfig.publishPresence` and `publish_opt.queue_request = PJ_TRUE`. pjsua accounts start with `online_status = 0` and send the first PUBLISH only after REGISTER succeeds, so `addAccount` sets "available" right away for publishing accounts. `publishPresence` -> `pjsua_acc_set_online_status2` with a PERSON RPID element: available = online/unknown, away = online/away, dnd = online/busy + note "Do Not Disturb", offline = closed. The last status is kept per account and re-applied by `updateAccount` (switching publishing off makes pjsua un-PUBLISH and reset the status to offline). Accounts without `publishPresence` -> `.invalidArgument`. PUBLISH failures (e.g. 489/501 from a server without presence) are only logged by pjsua; there is no event for them.
- **Audio device changes.** `handleAudioDevicesChanged` refreshes PJSIP's list and re-resolves the remembered names, but calls `pjsua_set_snd_dev2` only when the resolved capture or playback index differs from the applied one (a virtual device from Zoom/Teams appearing must not reopen the sound device mid-call). The ringtone is restarted only when its separate device resolves differently. The index can still change for the same physical device when a device listed before it disappears; then the device is reopened, because pjsua opens later streams by index.
- **Tests.** Loopback (one engine calling itself twice, four legs): merge with a held leg, per-leg mute/hold in the conference, applied bridge connections, conference recording (call + partner + mic), WAV header, split of the recording leg (recording moves), stop through another leg, refusal of a second conference recording, the recording leg ending (recording moves, file keeps growing, `.callEnded` flags), the last leg ending with a final WAV when `.callEnded` arrives; `stop()` while recording; argument checks without calls; presence bookkeeping, normalisation and the 256 limit (no network); Asterisk-style NOTIFYs via a presence stub; SUBSCRIBE retried after `updateAccount` via a refusing stub; publish rules; answer-after untrusted/trusted; pure tables for answer-after parsing, presence mapping, peer matching and proxy parsing, WAV repair.
- **Selftest** (`scripts/selftest-call.sh`): two pjsua phones (5080, 5081). Presence of 5080: available, then away / dnd / available driven through pjsua's telnet CLI (`--cli-telnet-port`, command `T n`; pjsua's app sets its accounts online at start, no flag needed). Recording of the first call for 3 s: WAV > 50 KB, header final, the remote 600 Hz tone audible (RMS check), then `RecordingConverter.convert` -> M4A > 1 KB. Conference: first call held, second dialled, merged (resumes the first), conference recorded on leg 1, 3 s of RTP growth on both legs, `inConference` on both; split of the recorded leg: both leave the conference, the recording moves to leg 2 and the WAV keeps growing; hang-up: `.callEnded` of leg 2 says `isRecording`, leg 1's does not, WAV final.
- **Manual checks** (`macrosip-cli` interactive): `merge`, `split`, `rec <file.wav>`, `stoprec`, `sub <uri>`, `unsub <uri>`, `status <available|away|dnd|offline>`, `acc publish on|off`.
