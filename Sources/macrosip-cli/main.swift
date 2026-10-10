// macrosip-cli: a small command-line phone over MacroSIPCore.Engine for manual testing.
//
//   macrosip-cli [--null-audio] [--log N] [--port P] [--stun host:port] [--bind ADDR]
//   macrosip-cli --selftest [--target sip:test@127.0.0.1:5080] [--bind ADDR|any] [--log N]
//
// --bind binds SIP/RTP to ADDR and advertises it (the self-test uses 127.0.0.1 so a VPN
// default route cannot swallow localhost traffic; "any" turns that off).
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
            case "--bind": o.bind = it.next()
            case "-h", "--help":
                print("""
                usage: macrosip-cli [--null-audio] [--log N] [--port P] [--stun host:port] [--bind ADDR]
                       macrosip-cli --selftest [--target URI] [--bind ADDR|any] [--log N]
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
    }
}

func describe(_ c: CallInfo) -> String {
    var parts = ["\(c.id)", c.direction.rawValue, describe(c.state), c.remote.uri]
    if let n = c.remote.displayName { parts.append("\"\(n)\"") }
    if let codec = c.codec { parts.append("codec=\(codec)") }
    parts.append(c.isSecure ? "srtp=on" : "srtp=off")
    if c.isMuted { parts.append("muted") }
    if c.isOnHold { parts.append("on-hold") }
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
    case let .buddyPresence(uri, st): return "[buddyPresence] \(uri) \(st.rawValue)"
    case .audioDevicesChanged: return "[audioDevicesChanged]"
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
