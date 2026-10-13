// macrosip-cli: a small command-line phone over MacroSIPCore.Engine for manual testing.
//
//   macrosip-cli [--null-audio] [--log N] [--port P] [--stun host:port] [--bind ADDR]
//   macrosip-cli --selftest [--target sip:test@127.0.0.1:5080] [--target2 sip:test@127.0.0.1:5081]
//                [--scratch DIR] [--target-cli PORT] [--target2-cli PORT] [--bind ADDR|any] [--log N]
//
// The self-test calls --target (recording, presence of --target), then --target2 and merges
// both into a conference. --scratch is where recordings go (default: a temporary directory).
// --target-cli is the telnet port of the --target pjsua CLI: presence changes, incoming calls
// and the transfer checks are driven there; --target2-cli is the one of --target2 (transfers).
// Without both CLI ports the incoming-call and transfer steps are skipped.
// --bind binds SIP/RTP to ADDR and advertises it (the self-test uses 127.0.0.1 so a VPN
// default route cannot swallow localhost traffic; "any" = all interfaces, the interactive default).
//
// Interactive commands: type `help`.

import Foundation
import MacroSIPCore

struct Options {
    var selftest = false
    var nullAudio = false
    var logLevel: Int?
    var port: UInt16 = 0
    var stun: String?
    var target = "sip:test@127.0.0.1:5080"
    var target2 = "sip:test@127.0.0.1:5081"
    var scratch: String?
    /// Telnet port of the --target pjsua's CLI; lets the self-test change its presence.
    var targetCLI: UInt16?
    /// Telnet port of the --target2 pjsua's CLI (transfer checks).
    var target2CLI: UInt16?
    var bind: String?

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--selftest": o.selftest = true
            case "--null-audio": o.nullAudio = true
            case "--log": o.logLevel = it.next().flatMap(Int.init)
            case "--port": o.port = it.next().flatMap(UInt16.init) ?? 0
            case "--stun": o.stun = it.next()
            case "--target": o.target = it.next() ?? o.target
            case "--target2": o.target2 = it.next() ?? o.target2
            case "--scratch": o.scratch = it.next()
            case "--target-cli": o.targetCLI = it.next().flatMap(UInt16.init)
            case "--target2-cli": o.target2CLI = it.next().flatMap(UInt16.init)
            case "--bind": o.bind = it.next()
            case "-h", "--help":
                print("""
                usage: macrosip-cli [--null-audio] [--log N] [--port P] [--stun host:port] [--bind ADDR]
                       macrosip-cli --selftest [--target URI] [--target2 URI] [--scratch DIR] [--target-cli PORT]
                                               [--target2-cli PORT] [--bind ADDR|any] [--log N]
                """)
                exit(0)
            default:
                print("unknown option \(a)")
                exit(2)
            }
        }
        return o
    }
}

// MARK: - formatting

func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

func describe(_ s: CallState) -> String {
    switch s {
    case .incoming: return "incoming"
    case .calling: return "calling"
    case .early: return "early"
    case .connecting: return "connecting"
    case .connected: return "connected"
    case .held: return "held"
    case let .disconnected(code, reason): return "disconnected(\(code) \(reason))"
    }
}

func describe(_ s: RegistrationState) -> String {
    switch s {
    case .unregistered: return "unregistered"
    case .registering: return "registering"
    case let .registered(expires): return "registered (expires \(expires) s)"
    case let .failed(code, reason): return "failed (\(code) \(reason))"
    case let .reconnecting(attempt, next, error):
        return "reconnecting (attempt \(attempt), next in \(Int(next)) s, \(error))"
    }
}

func describe(_ c: CallInfo) -> String {
    var parts = ["\(c.id)", c.direction.rawValue, describe(c.state), c.remote.uri]
    if let n = c.remote.displayName { parts.append("\"\(n)\"") }
    if let codec = c.codec { parts.append("codec=\(codec)") }
    parts.append(c.isSecure ? "srtp=on" : "srtp=off")
    if c.isMuted { parts.append("muted") }
    if c.isOnHold { parts.append("on-hold") }
    if c.inConference { parts.append("conference") }
    if c.isRecording { parts.append("recording") }
    if let after = c.answerAfter { parts.append("answer-after=\(after)") }
    if c.isReconnecting { parts.append("reconnecting") }
    return parts.joined(separator: " ")
}

func describe(_ e: EngineEvent) -> String {
    switch e {
    case let .registration(id, st): return "[registration] \(id.raw.uuidString.prefix(8)) \(describe(st))"
    case let .incomingCall(c): return "[incomingCall] \(describe(c))"
    case let .callChanged(c): return "[callChanged] \(describe(c))"
    case let .callEnded(c, d): return "[callEnded] \(describe(c)) duration=\(String(format: "%.1f", d))s"
    case let .transferStatus(id, code, final): return "[transferStatus] \(id) \(code)\(final ? " final" : "")"
    case let .dtmfReceived(id, digit): return "[dtmfReceived] \(id) '\(digit)'"
    case let .buddyPresence(uri, st, note): return "[buddyPresence] \(uri) \(st.rawValue)\(note.map { " (\($0))" } ?? "")"
    case .audioDevicesChanged: return "[audioDevicesChanged]"
    case let .network(state): return "[network] \(state == .online ? "online" : "offline")"
    case let .voicemail(id, waiting, new, old):
        return "[voicemail] \(id.raw.uuidString.prefix(8)) \(waiting ? "waiting" : "none") new=\(new) old=\(old)"
    case let .log(level, text):
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { "  pj\(level)| \($0)" }.joined(separator: "\n")
    }
}

func printEvent(_ e: EngineEvent) {
    if case .log = e { print(describe(e)) } else { print("\(stamp()) \(describe(e))") }
}

// MARK: - main

let options = Options.parse(CommandLine.arguments)
setvbuf(stdout, nil, _IOLBF, 0)

if options.selftest {
    let code = await SelfTest.run(options)
    exit(code)
}
await Interactive.run(options)
