import Testing
import Foundation
@testable import OpenBridgeApp

/// #294: WAV (PCM) container writer. RED first — the encoder starts as a
/// stub returning empty data, so every expectation below must fail until the
/// writer is implemented.
@Suite(.serialized) struct MeetingWAVFileTests {
    @Test func headerIdentifiesRIFFWAVEFmtData() {
        let d = MeetingWAVFile.data(pcm: Data([0, 0]), sampleRate: 48000)
        #expect(d.count >= 44)
        #expect(String(data: d.prefix(4), encoding: .utf8) == "RIFF")
        #expect(String(data: d.subdata(in: 8..<12), encoding: .utf8) == "WAVE")
        #expect(String(data: d.subdata(in: 12..<16), encoding: .utf8) == "fmt ")
        #expect(String(data: d.subdata(in: 36..<40), encoding: .utf8) == "data")
    }
    @Test func headerFieldsAreLittleEndianAndAccurate() {
        let d = MeetingWAVFile.data(pcm: Data([0, 0]), sampleRate: 48000, channels: 1, bitsPerSample: 16)
        let le16 = { (o: Int) -> UInt16 in d.subdata(in: o..<(o + 2)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) } }
        let le32 = { (o: Int) -> UInt32 in d.subdata(in: o..<(o + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        #expect(le16(20) == 1)      // PCM format
        #expect(le16(22) == 1)      // mono
        #expect(le32(24) == 48000)  // sample rate
        #expect(le32(28) == 96000)  // byte rate = rate * channels * 2
        #expect(le16(32) == 2)      // block align
        #expect(le16(34) == 16)     // bits per sample
        #expect(le32(40) == 2)      // data chunk size
    }
    @Test func totalLengthIsHeaderPlusPCM() {
        let pcm = Data(repeating: 0, count: 1000)
        let d = MeetingWAVFile.data(pcm: pcm, sampleRate: 44100)
        #expect(d.count == 44 + 1000)
    }
    @Test func writeProducesReadableFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavtest-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try MeetingWAVFile.write(pcm: Data(repeating: 1, count: 10), sampleRate: 48000, to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk.count == 54)
    }

    @Test func streamingWriterMakesActivePCMRecoverableBeforeFinalization() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavstream-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try MeetingStreamingWAVWriter(
            url: url,
            sampleRate: 16_000,
            initialPCM: Data([1, 2, 3, 4])
        )
        try writer.append(Data([5, 6, 7, 8]))

        // The file is a valid WAV while the writer is still active. A process
        // force-quit at this point therefore leaves eight recoverable bytes.
        let active = try Data(contentsOf: url)
        let dataSize = active.subdata(in: 40..<44).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }
        #expect(active.count == MeetingWAVFile.headerByteCount + 8)
        #expect(dataSize == 8)

        try writer.synchronizeAndClose()
    }

    @Test func repairRestoresPCMAppendedBeforeHeaderRefresh() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavrepair-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try MeetingWAVFile.write(pcm: Data([1, 2]), sampleRate: 16_000, to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([3, 4, 5, 6]))
        try handle.close()

        #expect(try MeetingWAVFile.repairHeaderIfNeeded(at: url))
        let repaired = try Data(contentsOf: url)
        let dataSize = repaired.subdata(in: 40..<44).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }
        #expect(dataSize == 6)
        #expect(repaired.count == MeetingWAVFile.headerByteCount + 6)
    }

    @Test func durationUsesActualPCMBytesAndHeaderByteRate() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavduration-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try MeetingWAVFile.write(
            pcm: Data(repeating: 0, count: 16_000 * 2),
            sampleRate: 16_000,
            to: url
        )
        #expect(try MeetingWAVFile.durationSeconds(at: url) == 1)
    }
}
