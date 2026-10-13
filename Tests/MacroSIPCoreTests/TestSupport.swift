import Foundation

func makeTempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("macrosip-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func withTempDir<R>(_ body: (URL) throws -> R) rethrows -> R {
    let d = makeTempDir()
    defer { try? FileManager.default.removeItem(at: d) }
    return try body(d)
}
