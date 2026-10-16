import Foundation

/// Canonical 44-byte header for 16-bit PCM WAV. Meeting audio is written as WAV
/// during the call because a truncated WAV (crash, force-quit) is recovered just
/// by fixing the two size fields.
public enum WAVHeader {
    public static let size = 44

    public static func make(dataBytes: UInt32, sampleRate: UInt32 = 16_000, channels: UInt16 = 1) -> Data {
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * bitsPerSample / 8
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        d.appendLE(UInt32(36) &+ dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.appendLE(UInt32(16))
        d.appendLE(UInt16(1))  // PCM
        d.appendLE(channels)
        d.appendLE(sampleRate)
        d.appendLE(sampleRate * UInt32(blockAlign))
        d.appendLE(blockAlign)
        d.appendLE(bitsPerSample)
        d.append(contentsOf: Array("data".utf8))
        d.appendLE(dataBytes)
        return d
    }

    /// Rewrites the size fields from the actual file length. Returns the number of
    /// whole 16-bit samples in the file.
    @discardableResult
    public static func repair(url: URL) throws -> Int {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length >= UInt64(size) else { return 0 }
        var dataBytes = length - UInt64(size)
        dataBytes -= dataBytes % 2
        let clamped = UInt32(min(dataBytes, UInt64(UInt32.max - 36)))
        try handle.seek(toOffset: 4)
        handle.write(Data(le: UInt32(36) &+ clamped))
        try handle.seek(toOffset: 40)
        handle.write(Data(le: clamped))
        return Int(clamped / 2)
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    init<T: FixedWidthInteger>(le value: T) {
        self.init()
        appendLE(value)
    }
}
