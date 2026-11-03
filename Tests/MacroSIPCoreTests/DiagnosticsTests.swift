import Testing
import Foundation
@testable import MacroSIPCore

@Suite("Diagnostics archive and redaction")
struct DiagnosticsTests {
    @Test func digestValuesAreRedactedKeepingUserAndRealm() {
        let text = """
        2026-11-03 10:00:00.000 [pjsip] I TX 500 bytes Request msg REGISTER/cseq=2
        \tREGISTER sip:pbx.example.com SIP/2.0
        \tAuthorization: Digest username="1001", realm="pbx", nonce="abc123", uri="sip:pbx.example.com", response="deadbeef00", cnonce="c0ffee", nc=00000001, opaque="op4que", algorithm=MD5
        \tContent-Length: 0
        """
        let out = LogRedaction.redact(text)
        for secret in ["abc123", "deadbeef00", "c0ffee", "op4que"] { #expect(!out.contains(secret)) }
        #expect(out.contains(#"username="1001""#) && out.contains(#"realm="pbx""#) && out.contains("nc=00000001"))
        #expect(out.contains("Content-Length: 0"))
    }

    @Test func allFourHeadersCompactAndUnquoted() {
        let text = "Proxy-Authorization:Digest username=a,response=ff00,nonce=n1\nWWW-Authenticate: Digest realm=\"r\",nonce=\"n2\",opaque=\"o2\"\nProxy-Authenticate: Digest nonce=\"n3\"\nauthorization: Digest RESPONSE=\"r4\""
        let out = LogRedaction.redact(text)
        for secret in ["ff00", "n1", "n2", "o2", "n3", "r4"] { #expect(!out.contains("\"\(secret)\"") && !out.contains("=\(secret)")) }
        #expect(out.contains("username=a") && out.contains(#"realm="r""#))
    }

    @Test func continuationLinesAreRedactedAndTheNextHeaderIsNot() {
        let text = "\tAuthorization: Digest username=\"1\",\n\t\tnonce=\"sec1\",\n\t response=\"sec2\"\n\tVia: SIP/2.0/UDP host;branch=z9hG4bK;nonce=keepme\n2026-11-03 10:00:01.000 [app] I nonce=\"plain\""
        let out = LogRedaction.redact(text)
        #expect(!out.contains("sec1") && !out.contains("sec2"))
        #expect(out.contains("keepme"))
        #expect(out.contains("nonce=\"plain\""))     // only header lines count
        #expect(out.hasSuffix("\"plain\""))
    }

    @Test func headerOnTheLogLine() {
        let out = LogRedaction.redact("2026-11-03 09:00:00.000 [pjsip] D WWW-Authenticate: Digest realm=\"pbx\", nonce=\"N9\", opaque=\"O9\"")
        #expect(!out.contains("N9") && !out.contains("O9") && out.contains("realm=\"pbx\""))
    }

    @Test func basicAndBearerCredentials() {
        let out = LogRedaction.redact("Authorization: Basic dXNlcjpzZWNyZXQ=\nAuthorization: Bearer abc.def.ghi")
        #expect(!out.contains("dXNlcjpz") && !out.contains("abc.def"))
    }

    @Test func passwordLikeKeys() {
        let text = #"password=hunter2 pwd: abc "password" : "p w" {"access_token":"ya29.x","refreshToken":"r1","bindPassword":"zz"} client_secret=s3 name=Andrei"#
        let out = LogRedaction.redact(text)
        for secret in ["hunter2", "abc", "p w", "ya29", "r1", "zz", "s3"] { #expect(!out.contains(secret), "\(secret)") }
        #expect(out.contains("name=Andrei"))
    }

    @Test func urlAndSipUserinfoAndQuery() {
        let out = LogRedaction.redact("https://bob:s3cret@dir.example.com/list.csv?token=abc&x=1 https://h/p?api_key=K1&n=2 sip:1001:pw9@pbx.example.com sip:1001@pbx.example.com:5060")
        for secret in ["s3cret", "abc", "K1", "pw9"] { #expect(!out.contains(secret)) }
        #expect(out.contains("bob:") && out.contains("dir.example.com") && out.contains("x=1") && out.contains("n=2"))
        #expect(out.contains("sip:1001@pbx.example.com:5060"))
    }

    @Test func numbersAndAddressesStay() {
        let text = "2026-11-03 10:00:00.000 [engine] I call 1: +375291112233 -> sip:1001@pbx.example.com via 10.0.0.5:5060\n"
        #expect(LogRedaction.redact(text) == text)
    }

    @Test func policy() {
        #expect(LogLevelPolicy.effectiveLevel(launchLevel: 3, explicit: false, debugMode: false) == 3)
        #expect(LogLevelPolicy.effectiveLevel(launchLevel: 3, explicit: false, debugMode: true) == 4)
        #expect(LogLevelPolicy.effectiveLevel(launchLevel: 5, explicit: true, debugMode: false) == 5)
        #expect(LogLevelPolicy.effectiveLevel(launchLevel: 2, explicit: true, debugMode: true) == 2)
    }

    @Test func oldSettingsDecodeWithDebugOff() throws {
        let g = try JSONDecoder().decode(GeneralSettings.self, from: Data(#"{"launchAtLogin":true}"#.utf8))
        #expect(!g.debugMode)
        var s = AppSettings()
        s.general.debugMode = true
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s)).general.debugMode)
    }

    @Test func fileName() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 14, minute: 5))!
        #expect(DiagnosticsArchive.defaultFileName(now: date, calendar: cal) == "MacroSIP-diagnostics-20261103-1405.zip")
    }

    private func temp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("diag-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func unzip(_ zip: URL, into dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test func archiveWithLogsAndCrashReports() async throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let logs = base.appendingPathComponent("logs"), crashes = base.appendingPathComponent("crashes")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: crashes, withIntermediateDirectories: true)
        let original = "\tAuthorization: Digest nonce=\"N0\", response=\"R0\"\n"
        for n in ["MacroSIP.log", "MacroSIP.1.log", "MacroSIP.2.log", "Other.log"] { try original.write(to: logs.appendingPathComponent(n), atomically: true, encoding: .utf8) }
        let now = Date()
        for i in 0..<7 {       // 7 recent reports: only the newest 5 go in
            let f = crashes.appendingPathComponent("MacroSIP-2026-11-0\(i).ips")
            try "crash \(i)".write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-Double(i) * 3600)], ofItemAtPath: f.path)
        }
        let old = crashes.appendingPathComponent("MacroSIP-old.ips")
        try "old".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-40 * 86400)], ofItemAtPath: old.path)
        try "x".write(to: crashes.appendingPathComponent("OtherApp-1.ips"), atomically: true, encoding: .utf8)

        let dest = base.appendingPathComponent("MacroSIP-diagnostics-test.zip")
        let r = try await DiagnosticsArchive.create(destination: dest, logDirectory: logs, crashReportsDirectory: crashes,
                                                    diagnosticsText: "password=abc\nMacroSIP 26.1\n", now: now)
        #expect(r.logFiles == ["MacroSIP.log", "MacroSIP.1.log", "MacroSIP.2.log"])
        #expect(r.crashReports.count == 5 && !r.crashReports.contains("MacroSIP-old.ips") && r.bytes > 0)
        let out = base.appendingPathComponent("out")
        try unzip(dest, into: out)
        let root = out.appendingPathComponent("MacroSIP-diagnostics-test")
        let log = try String(contentsOf: root.appendingPathComponent("logs/MacroSIP.1.log"), encoding: .utf8)
        #expect(!log.contains("N0") && !log.contains("R0") && log.contains("Digest"))
        let diag = try String(contentsOf: root.appendingPathComponent("diagnostics.txt"), encoding: .utf8)
        #expect(!diag.contains("abc") && diag.contains("MacroSIP 26.1"))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("crash-reports").path))?.count == 5)
        // The original log is untouched.
        #expect(try String(contentsOf: logs.appendingPathComponent("MacroSIP.log"), encoding: .utf8) == original)
    }

    @Test func archiveWithNothingToInclude() async throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let dest = base.appendingPathComponent("empty.zip")
        let r = try await DiagnosticsArchive.create(destination: dest, logDirectory: base.appendingPathComponent("missing"),
                                                    crashReportsDirectory: nil, diagnosticsText: "report\n")
        #expect(r.logFiles.isEmpty && r.crashReports.isEmpty && FileManager.default.fileExists(atPath: dest.path))
        let out = base.appendingPathComponent("out")
        try unzip(dest, into: out)
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("empty/diagnostics.txt").path))
    }

    @Test func unwritableDestinationThrows() async throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        await #expect(throws: DiagnosticsArchive.Failure.self) {
            _ = try await DiagnosticsArchive.create(destination: base.appendingPathComponent("no/such/dir/a.zip"), logDirectory: base,
                                                    crashReportsDirectory: nil, diagnosticsText: "x")
        }
    }
}
