import Foundation

/// Writes the meeting's 2-channel file next to the mixed mono chunks: 16 kHz, 16-bit,
/// channel 1 = microphone, channel 2 = system audio. Frames line up 1:1 with the mixed file,
/// so a timestamp in the mixed transcript points at the same frame here.
///
/// Plain WAV written by appending: the size fields are patched on `close()`, and
/// `repairHeader(at:)` fixes them after a crash (any appended frames are valid audio).
/// Not thread-safe: use from one queue (`SystemAudioCaptureService.fileWriteQueue`).
final class MeetingTracksWriter {
    static let sampleRate = 16000
    static let channelCount = 2
    static let headerSize = 44

    private let handle: FileHandle
    let url: URL

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: Self.header(dataByteCount: 0))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.url = url
    }

    /// Appends `max(mic.count, system.count)` frames; a missing or shorter side is silence.
    func append(mic: [Float], system: [Float]) {
        let frameCount = max(mic.count, system.count)
        guard frameCount > 0 else { return }
        var data = Data(count: frameCount * Self.channelCount * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for i in 0 ..< frameCount {
                out[i * 2] = Self.int16(i < mic.count ? mic[i] : 0).littleEndian
                out[i * 2 + 1] = Self.int16(i < system.count ? system[i] : 0).littleEndian
            }
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            Log.audio.error("Tracks write failed: \(error.localizedDescription)")
        }
    }

    func close() {
        try? handle.synchronize()
        try? handle.close()
        Self.repairHeader(at: url)
    }

    /// Sets the RIFF and data sizes from the file length. Safe to call on a closed file.
    @discardableResult
    static func repairHeader(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int,
              fileSize >= headerSize,
              let handle = try? FileHandle(forUpdating: url)
        else { return false }
        defer { try? handle.close() }
        let frameBytes = channelCount * MemoryLayout<Int16>.size
        let dataByteCount = (fileSize - headerSize) / frameBytes * frameBytes
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header(dataByteCount: dataByteCount))
            try handle.truncate(atOffset: UInt64(headerSize + dataByteCount))
            return true
        } catch {
            return false
        }
    }

    static func header(dataByteCount: Int) -> Data {
        let bitsPerSample = 16
        let blockAlign = channelCount * bitsPerSample / 8
        var data = Data()
        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append("RIFF")
        append(UInt32(36 + dataByteCount))
        append("WAVE")
        append("fmt ")
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(channelCount))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * blockAlign))
        append(UInt16(blockAlign))
        append(UInt16(bitsPerSample))
        append("data")
        append(UInt32(dataByteCount))
        return data
    }

    private static func int16(_ sample: Float) -> Int16 {
        Int16(max(-1.0, min(1.0, sample)) * Float(Int16.max))
    }
}
