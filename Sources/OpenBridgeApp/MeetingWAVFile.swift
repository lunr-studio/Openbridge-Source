import Foundation

/// #294: minimal WAV (RIFF/PCM) container writer for recorder chunk files.
/// The engine consumes WAV; the recorder slices continuous capture into
/// overlapping chunk windows (wave-1 3857377369) and writes each as a WAV.
enum MeetingWAVFile {
    static let headerByteCount = 44

    static func write(pcm: Data, sampleRate: Int, channels: Int = 1, bitsPerSample: Int = 16, to url: URL) throws {
        try data(pcm: pcm, sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample)
            .write(to: url, options: .atomic)
    }

    /// Build a complete 44-byte-header PCM WAV file (little-endian).
    static func data(pcm: Data, sampleRate: Int, channels: Int = 1, bitsPerSample: Int = 16) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = pcm.count
        let riffSize = 36 + dataSize

        var d = Data(capacity: 44 + dataSize)
        d.append(Data("RIFF".utf8))
        d.append(contentsOf: littleEndian(UInt32(riffSize)))
        d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8))
        d.append(contentsOf: littleEndian(UInt32(16)))          // fmt chunk size
        d.append(contentsOf: littleEndian(UInt16(1)))           // PCM
        d.append(contentsOf: littleEndian(UInt16(channels)))
        d.append(contentsOf: littleEndian(UInt32(sampleRate)))
        d.append(contentsOf: littleEndian(UInt32(byteRate)))
        d.append(contentsOf: littleEndian(UInt16(blockAlign)))
        d.append(contentsOf: littleEndian(UInt16(bitsPerSample)))
        d.append(Data("data".utf8))
        d.append(contentsOf: littleEndian(UInt32(dataSize)))
        d.append(pcm)
        return d
    }

    /// Repairs the two WAV size fields from the file's actual length.
    ///
    /// A force-quit can land after streaming PCM reached the file but before
    /// its header was refreshed. The bytes are still recoverable; correcting
    /// the RIFF/data sizes makes the complete file readable again.
    @discardableResult
    static func repairHeaderIfNeeded(at url: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: headerByteCount),
              header.count == headerByteCount,
              String(data: header.prefix(4), encoding: .ascii) == "RIFF",
              String(data: header[8..<12], encoding: .ascii) == "WAVE",
              String(data: header[36..<40], encoding: .ascii) == "data"
        else {
            return false
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value >= Int64(headerByteCount)
        else {
            return false
        }

        let pcmByteCount = Int(fileSize.int64Value) - headerByteCount
        guard pcmByteCount <= Int(UInt32.max) - 36 else {
            throw MeetingWAVFileError.fileTooLarge
        }
        let storedRIFFSize = decodeLittleEndianUInt32(header[4..<8])
        let storedDataSize = decodeLittleEndianUInt32(header[40..<44])
        let expectedRIFFSize = UInt32(36 + pcmByteCount)
        let expectedDataSize = UInt32(pcmByteCount)
        guard storedRIFFSize != expectedRIFFSize || storedDataSize != expectedDataSize else {
            return false
        }

        try writeSizes(pcmByteCount: pcmByteCount, to: handle)
        try handle.synchronize()
        return true
    }

    /// Reads duration from the canonical PCM byte-rate field and the actual
    /// file length. Using the file length (rather than trusting the data-size
    /// field) also works immediately after force-quit header repair.
    static func durationSeconds(at url: URL) throws -> TimeInterval? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: headerByteCount),
              header.count == headerByteCount,
              String(data: header.prefix(4), encoding: .ascii) == "RIFF",
              String(data: header[8..<12], encoding: .ascii) == "WAVE",
              String(data: header[36..<40], encoding: .ascii) == "data"
        else { return nil }

        let byteRate = decodeLittleEndianUInt32(header[28..<32])
        guard byteRate > 0 else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value >= Int64(headerByteCount)
        else { return nil }
        let pcmByteCount = fileSize.int64Value - Int64(headerByteCount)
        return TimeInterval(pcmByteCount) / TimeInterval(byteRate)
    }

    /// Capture can negotiate a rate different from the source's preference.
    /// Recovery reads the actual canonical WAV format, never that preference.
    static func sampleRate(at url: URL) throws -> Double? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: headerByteCount),
              header.count == headerByteCount,
              String(data: header.prefix(4), encoding: .ascii) == "RIFF",
              String(data: header[8..<12], encoding: .ascii) == "WAVE",
              String(data: header[36..<40], encoding: .ascii) == "data" else { return nil }
        let rate = decodeLittleEndianUInt32(header[24..<28])
        return rate > 0 ? Double(rate) : nil
    }

    fileprivate static func writeSizes(pcmByteCount: Int, to handle: FileHandle) throws {
        guard pcmByteCount >= 0, pcmByteCount <= Int(UInt32.max) - 36 else {
            throw MeetingWAVFileError.fileTooLarge
        }
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Data(littleEndian(UInt32(36 + pcmByteCount))))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: Data(littleEndian(UInt32(pcmByteCount))))
        try handle.seekToEnd()
    }

    private static func littleEndian<T: FixedWidthInteger>(_ v: T) -> [UInt8] {
        var v = v.littleEndian
        return withUnsafeBytes(of: &v) { Array($0) }
    }

    private static func decodeLittleEndianUInt32(_ bytes: Data.SubSequence) -> UInt32 {
        bytes.enumerated().reduce(0) { partial, pair in
            partial | (UInt32(pair.element) << UInt32(pair.offset * 8))
        }
    }
}

enum MeetingWAVFileError: Error {
    case fileTooLarge
    case insufficientPCM
    case writerClosed
}

/// Incremental PCM WAV writer used for the currently active meeting segment.
///
/// The file is created before the segment is finalized and its header is
/// refreshed after every append. Therefore a normal app force-quit leaves a
/// discoverable `segment_NNNN.wav` on disk instead of losing the active chunk
/// with the process's in-memory ring.
final class MeetingStreamingWAVWriter {
    let url: URL
    let sampleRate: Int
    private var handle: FileHandle?
    private(set) var pcmByteCount: Int

    init(url: URL, sampleRate: Int, initialPCM: Data = Data()) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.pcmByteCount = initialPCM.count
        try MeetingWAVFile.write(pcm: initialPCM, sampleRate: sampleRate, to: url)
        self.handle = try FileHandle(forUpdating: url)
        try self.handle?.seekToEnd()
    }

    deinit {
        try? handle?.close()
    }

    func append(_ pcm: Data) throws {
        guard !pcm.isEmpty else { return }
        guard let handle else { throw MeetingWAVFileError.writerClosed }
        try handle.seekToEnd()
        try handle.write(contentsOf: pcm)
        pcmByteCount += pcm.count
        try MeetingWAVFile.writeSizes(pcmByteCount: pcmByteCount, to: handle)
    }

    func truncatePCM(toByteCount requestedByteCount: Int) throws {
        guard let handle else { throw MeetingWAVFileError.writerClosed }
        guard requestedByteCount >= 0, requestedByteCount <= pcmByteCount else {
            throw MeetingWAVFileError.insufficientPCM
        }
        let nextByteCount = requestedByteCount
        try handle.truncate(atOffset: UInt64(MeetingWAVFile.headerByteCount + nextByteCount))
        pcmByteCount = nextByteCount
        try MeetingWAVFile.writeSizes(pcmByteCount: pcmByteCount, to: handle)
    }

    func synchronizeAndClose() throws {
        guard let handle else { return }
        try MeetingWAVFile.writeSizes(pcmByteCount: pcmByteCount, to: handle)
        try handle.synchronize()
        try handle.close()
        self.handle = nil
    }
}
