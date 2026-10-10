import Foundation
import Security

/// The macOS system root certificates as a PEM bundle for PJSIP's OpenSSL (`ca_list_file`).
/// OpenSSL cannot read the macOS trust store, so the anchors are exported at engine start.
enum TLSRoots {
    /// `~/Library/Application Support/MacroSIP/ca-roots.pem`
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MacroSIP", isDirectory: true).appendingPathComponent("ca-roots.pem")
    }

    /// PEM text of every system anchor certificate.
    static func pemBundle() throws -> (pem: String, count: Int) {
        var anchors: CFArray?
        let status = SecTrustCopyAnchorCertificates(&anchors)
        guard status == errSecSuccess, let certs = anchors as? [SecCertificate], !certs.isEmpty else {
            throw EngineError.unsupported("system root certificates unavailable (OSStatus \(status))")
        }
        var pem = ""
        for cert in certs {
            let der = SecCertificateCopyData(cert) as Data
            pem += "-----BEGIN CERTIFICATE-----\n"
            pem += der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            pem += "\n-----END CERTIFICATE-----\n"
        }
        return (pem, certs.count)
    }

    /// Writes the bundle atomically to `url` (creating the directory). Returns the count.
    @discardableResult
    static func export(to url: URL) throws -> Int {
        let (pem, count) = try pemBundle()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(pem.utf8).write(to: url, options: .atomic)
        return count
    }
}
