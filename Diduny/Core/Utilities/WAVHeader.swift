import Foundation

// MARK: - WAV Builder

/// Wraps raw PCM samples in a RIFF/WAVE container so `AVAudioPlayer(data:)`
/// can play in-memory audio returned by the 60db TTS API (LINEAR16 encoding).
enum WAVBuilder {
    /// Returns `pcm` prefixed with a 44-byte canonical WAV header for the
    /// given format. Does not validate that `pcm` is well-formed for the
    /// specified bit depth; callers pass 16-bit little-endian mono PCM.
    static func wavData(fromPCM pcm: Data, sampleRate: Int, channels: Int = 1, bitsPerSample: Int = 16) -> Data {
        var wav = headerData(sampleRate: sampleRate, dataLength: pcm.count, channels: channels, bitsPerSample: bitsPerSample)
        wav.append(pcm)
        return wav
    }

    /// Canonical 44-byte RIFF header for PCM data.
    static func headerData(sampleRate: Int, dataLength: Int, channels: Int, bitsPerSample: Int) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        var header = Data(capacity: 44)
        append(string: "RIFF", to: &header)
        appendUInt32(UInt32(36 + dataLength), to: &header) // riffChunkSize
        append(string: "WAVE", to: &header)
        append(string: "fmt ", to: &header)
        appendUInt32(16, to: &header) // fmtChunkSize
        appendUInt16(1, to: &header) // audioFormat = PCM
        appendUInt16(UInt16(channels), to: &header)
        appendUInt32(UInt32(sampleRate), to: &header)
        appendUInt32(UInt32(byteRate), to: &header)
        appendUInt16(UInt16(blockAlign), to: &header)
        appendUInt16(UInt16(bitsPerSample), to: &header)
        append(string: "data", to: &header)
        appendUInt32(UInt32(dataLength), to: &header)
        return header
    }

    // MARK: - Private

    private static func append(string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
