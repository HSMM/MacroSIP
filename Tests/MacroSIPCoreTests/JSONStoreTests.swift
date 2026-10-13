import Foundation
import Testing
@testable import MacroSIPCore

@Suite struct JSONStoreTests {
    struct Doc: Codable, Equatable, Sendable { var n: Int; var date: Date }
    let def = Doc(n: 0, date: Date(timeIntervalSince1970: 0))

    @Test func roundTrip() throws {
        try withTempDir { dir in
            let s = JSONStore(directory: dir, name: "doc", default: def)
            let v = Doc(n: 5, date: Date(timeIntervalSince1970: 1_700_000_000))
            try s.save(v)
            #expect(s.load() == v)
            let text = try String(contentsOf: dir.appendingPathComponent("doc.json"), encoding: .utf8)
            #expect(text.contains("2023-11-14T22:13:20Z"))
            #expect(text.contains("\n"))
        }
    }

    @Test func missingFileReturnsDefault() {
        withTempDir { dir in
            #expect(JSONStore(directory: dir, name: "doc", default: def).load() == def)
        }
    }

    @Test func corruptFileRenamed() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("doc.json")
            try Data("{not json".utf8).write(to: url)
            let s = JSONStore(directory: dir, name: "doc", default: def)
            #expect(s.load() == def)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(files.count == 1)
            #expect(files[0].hasPrefix("doc.broken-") && files[0].hasSuffix(".json"))
        }
    }

    @Test func saveLeavesNoTempFiles() throws {
        try withTempDir { dir in
            let s = JSONStore(directory: dir, name: "doc", default: def)
            for i in 0..<5 { try s.save(Doc(n: i, date: Date(timeIntervalSince1970: 0))) }
            let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(files == ["doc.json"])
            #expect(s.load().n == 4)
        }
    }

    @Test func appSupportDirectoryExists() {
        var isDir: ObjCBool = false
        let d = JSONStore<Int>.appSupportDirectory()
        #expect(FileManager.default.fileExists(atPath: d.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(d.lastPathComponent == "MacroSIP")
    }
}
