@testable import Diduny
import Foundation
import Testing

/// Review round 1, item 3: a recovered Translate meeting is saved and handed to the queue (same path as Stop).
@MainActor
@Suite("Recovered meeting translation hand-off")
struct RecoveryMeetingTranslationTests {
    @Test("Saves the audio, cleans the source, enqueues once, never transcribes here")
    func handOff() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID().uuidString).wav")
        try Self.wav(seconds: 1).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = RecoveryState(tempFilePath: url.path, startTime: Date(), recordingType: .meetingTranslation)
        let saved = UUID()
        var cleaned = 0, updates = 0
        var enqueued: [UUID] = []
        let processor = RecoveryRecordingProcessor(
            save: { data, _, duration in #expect(!data.isEmpty && duration > 0.9); return saved },
            update: { _, _, _, _ in updates += 1 },
            cleanupSource: { _ in cleaned += 1 })
        let id = try await processor.handOff(state: state) { enqueued.append($0) }
        #expect(id == saved && enqueued == [saved] && cleaned == 1 && updates == 0)
    }

    /// 16-bit mono 16 kHz PCM.
    static func wav(seconds: Int) -> Data {
        let rate: UInt32 = 16000, samples = Int(rate) * seconds, bytes = UInt32(samples * 2)
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes); d.append(Data(count: Int(bytes)))
        return d
    }
}
