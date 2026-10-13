import Foundation
import SystemConfiguration

/// DNS servers for SIP SRV resolution (`NetworkSettings.dnsSRV`, docs/ENGINE.md "Network options").
struct DNSServer: Equatable, Sendable, CustomStringConvertible {
    var host: String
    var port: UInt16 = 53

    var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

enum DNSServers {
    /// pjsua_config.nameserver has room for 4.
    static let maxCount = 4

    /// "10.0.0.1", "10.0.0.1:5353", "[2001:db8::1]:53", "2001:db8::1", several separated by
    /// commas, semicolons or blanks. Entries that cannot be read are skipped.
    static func parse(_ text: String?) -> [DNSServer] {
        guard let text else { return [] }
        var out: [DNSServer] = []
        let items = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "\t" || $0 == "\n" })
        for raw in items {
            if let s = parseOne(String(raw)), !out.contains(s) { out.append(s) }
        }
        return Array(out.prefix(maxCount))
    }

    static func parseOne(_ raw: String) -> DNSServer? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            if rest.isEmpty { return usable(host) ? DNSServer(host: host) : nil }
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()), port > 0 else { return nil }
            return usable(host) ? DNSServer(host: host, port: port) : nil
        }
        let colons = s.filter { $0 == ":" }.count
        if colons == 1 {
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            guard let port = UInt16(parts[1]), port > 0 else { return nil }
            let host = String(parts[0])
            return usable(host) ? DNSServer(host: host, port: port) : nil
        }
        return usable(s) ? DNSServer(host: s) : nil      // IPv4, host name, or bare IPv6
    }

    /// pjlib's resolver cannot use scoped (link-local) IPv6 servers.
    private static func usable(_ host: String) -> Bool {
        !host.isEmpty && !host.contains("%") && !host.lowercased().hasPrefix("fe80:")
    }

    /// The system's resolvers: SystemConfiguration's global DNS (what macOS itself uses),
    /// else the `nameserver` lines of /etc/resolv.conf (the same list, as res_ninit reads it).
    static func system() -> [DNSServer] {
        if let dict = SCDynamicStoreCopyValue(nil, "State:/Network/Global/DNS" as CFString) as? [String: Any],
           let addresses = dict["ServerAddresses"] as? [String] {
            let servers = parse(addresses.joined(separator: " "))
            if !servers.isEmpty { return servers }
        }
        return resolvConf((try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8)) ?? "")
    }

    static func resolvConf(_ text: String) -> [DNSServer] {
        var hosts: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count >= 2, fields[0] == "nameserver" { hosts.append(String(fields[1])) }
        }
        return parse(hosts.joined(separator: " "))
    }

    /// What `start` uses: the configured servers, else the system's; empty when SRV is off.
    static func forSettings(_ network: NetworkSettings) -> [DNSServer] {
        guard network.dnsSRV else { return [] }
        let configured = parse(network.nameserver)
        return configured.isEmpty ? system() : configured
    }
}
