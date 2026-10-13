import Testing
@testable import MacroSIPCore

@Suite struct DialStringTests {
    func account(_ t: TransportKind = .udp) -> AccountConfig {
        AccountConfig(displayName: "A", username: "1001", domain: "sip.example.com", transport: t)
    }

    struct Case: Sendable { let input: String; let uri: String?; let display: String? }

    static let cases: [Case] = [
        .init(input: "100", uri: "sip:100@sip.example.com", display: "100"),
        .init(input: "+7 (495) 123-45-67", uri: "sip:+74951234567@sip.example.com", display: "+74951234567"),
        .init(input: "*72", uri: "sip:*72@sip.example.com", display: "*72"),
        .init(input: "sip:bob@host", uri: "sip:bob@host", display: "bob"),
        .init(input: "sips:bob@host:5061", uri: "sips:bob@host:5061", display: "bob"),
        .init(input: "SIP:Upper@Host", uri: "SIP:Upper@Host", display: "Upper"),
        .init(input: "tel:+1-555-0100", uri: "sip:+15550100@sip.example.com", display: "+15550100"),
        .init(input: "bob@host", uri: "sip:bob@host", display: "bob"),
        .init(input: "  100  ", uri: "sip:100@sip.example.com", display: "100"),
        .init(input: "", uri: nil, display: nil),
        .init(input: "abc", uri: nil, display: nil),
    ]

    @Test(arguments: cases) func udp(_ c: Case) {
        let r = DialString.parse(c.input, account: account())
        #expect(r?.uri == c.uri)
        #expect(r?.display == c.display)
    }

    @Test func tcpAddsTransport() {
        #expect(DialString.parse("100", account: account(.tcp))?.uri == "sip:100@sip.example.com;transport=tcp")
        #expect(DialString.parse("bob@host", account: account(.tcp))?.uri == "sip:bob@host;transport=tcp")
    }

    @Test func tlsAddsTransport() {
        #expect(DialString.parse("100", account: account(.tls))?.uri == "sip:100@sip.example.com;transport=tls")
    }

    @Test func existingTransportNotDuplicated() {
        let r = DialString.parse("sip:bob@host;transport=udp", account: account(.tls))
        #expect(r?.uri == "sip:bob@host;transport=udp")
        #expect(r?.display == "bob")
    }
}
