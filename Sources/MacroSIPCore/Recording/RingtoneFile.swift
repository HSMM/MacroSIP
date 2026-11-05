import Foundation

/// The WAV the engine rings with for a custom ringtone file (`RingtoneSource.file`). A 16-bit PCM
/// WAV is used as it is; anything else AVFoundation reads (AIFF, M4A, MP3, CAF, a float WAV) is
/// converted once by `AudioFileToWAV` into `ringtone.wav` in the app's data folder. The copy
/// remembers which file it was made from (path, size, modification date, in an extended
/// attribute), so the same file is not converted again at every launch, while another file or
/// a changed one is. Blocking file work: call it off the main actor.
public enum RingtoneFile {
    public static let convertedName = "ringtone.wav"
    static let sourceAttribute = "com.hsmm.macrosip.ringtone-source"

    /// Where the converted copy lives in `directory`.
    public static func convertedURL(in directory: URL) -> URL {
        directory.appendingPathComponent(convertedName)
    }

    /// The WAV for `source`: `source` itself when the engine plays it as it is, else the converted
    /// copy in `directory` (made now unless it was already made from this very file). Throws
    /// `AudioFileToWAV.ConversionError` for a file that is missing or cannot be read; the previous
    /// copy then stays as it was (the engine may still be ringing with it). The new copy is written
    /// next to it and renamed over it, so a ringtone starting meanwhile never opens half a file.
    public static func prepare(_ source: URL, in directory: URL) throws -> URL {
        if AudioFileToWAV.isPlayableWAV(source) { return source }
        let target = convertedURL(in: directory)
        let stamp = try fingerprint(of: source)
        if storedFingerprint(of: target) == stamp, AudioFileToWAV.isPlayableWAV(target) { return target }

        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw AudioFileToWAV.ConversionError.cannotWrite(error.localizedDescription) }
        let partial = directory.appendingPathComponent("ringtone-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: partial) }
        try AudioFileToWAV.convert(source, to: partial)
        _ = stamp.withUnsafeBytes { setxattr(partial.path, sourceAttribute, $0.baseAddress, $0.count, 0, 0) }
        guard rename(partial.path, target.path) == 0 else {
            throw AudioFileToWAV.ConversionError.cannotWrite(String(cString: strerror(errno)))
        }
        return target
    }

    /// Removes the converted copy (the ringtone is a melody or a WAV used as it is again).
    public static func removeConverted(in directory: URL) {
        try? FileManager.default.removeItem(at: convertedURL(in: directory))
    }

    /// Path, size and modification date of `url`.
    static func fingerprint(of url: URL) throws -> Data {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch { throw AudioFileToWAV.ConversionError.cannotRead(error.localizedDescription) }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return Data("\(url.standardizedFileURL.path)\n\(size)\n\(modified)".utf8)
    }

    static func storedFingerprint(of url: URL) -> Data? {
        let length = getxattr(url.path, sourceAttribute, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, sourceAttribute, $0.baseAddress, length, 0, 0) }
        return read == length ? data : nil
    }
}
