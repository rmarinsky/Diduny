import AVFoundation
@testable import Diduny
import XCTest

final class RecordingTrimTests: XCTestCase {
    @MainActor
    func test_trimPersistsWithoutChangingOriginalAndCanBeRestored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingsLibraryStorage(baseDirectory: directory)
        let bytes = Data([1, 2, 3, 4])
        let id = try XCTUnwrap(store.saveRecording(audioData: bytes, type: .meeting, duration: 100, transcriptionText: "Original", forceSave: true))
        let range = AudioTrimRange(startSeconds: 10, endSeconds: 40)
        XCTAssertTrue(store.updateTrimRange(id: id, range: range))
        let reopened = RecordingsLibraryStorage(baseDirectory: directory)
        let recording = try XCTUnwrap(reopened.recordings.first)
        XCTAssertEqual(recording.trimRange, range)
        XCTAssertEqual(recording.effectiveDurationSeconds, 30)
        XCTAssertEqual(recording.durationSeconds, 100)
        XCTAssertEqual(recording.transcriptionText, "Original")
        XCTAssertEqual(try Data(contentsOf: reopened.audioFileURL(for: recording)), bytes)
        XCTAssertTrue(reopened.updateTrimRange(id: id, range: nil))
        XCTAssertNil(RecordingsLibraryStorage(baseDirectory: directory).recordings.first?.trimRange)
    }
    @MainActor
    func test_invalidRangesAndActiveStatesLeaveRecordingUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingsLibraryStorage(baseDirectory: directory)
        let id = try XCTUnwrap(store.saveRecording(audioData: Data([1]), type: .meeting, duration: 100, forceSave: true))
        for range in [
            AudioTrimRange(startSeconds: -1, endSeconds: 40),
            AudioTrimRange(startSeconds: 40, endSeconds: 40),
            AudioTrimRange(startSeconds: 40, endSeconds: 20),
            AudioTrimRange(startSeconds: 0, endSeconds: 101),
            AudioTrimRange(startSeconds: .nan, endSeconds: 40),
            AudioTrimRange(startSeconds: 0, endSeconds: .infinity),
        ] {
            XCTAssertFalse(store.updateTrimRange(id: id, range: range))
            XCTAssertNil(store.recordings.first?.trimRange)
        }
        XCTAssertTrue(store.updateTrimRange(id: id, range: AudioTrimRange(startSeconds: 0, endSeconds: 100)))
        XCTAssertNil(store.recordings.first?.trimRange)
        for status in [Recording.ProcessingStatus.recording, .needsRecovery, .processing] {
            store.updateRecording(id: id, status: status)
            XCTAssertFalse(store.updateTrimRange(id: id, range: AudioTrimRange(startSeconds: 10, endSeconds: 40)))
        }
    }

    @MainActor
    func test_failedMetadataWriteRestoresSelectionAndTranscriptHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalStore = RecordingsLibraryStorage(baseDirectory: directory)
        let id = try XCTUnwrap(originalStore.saveRecording(audioData: Data([1]), type: .meeting, duration: 100, transcriptionText: "Original", forceSave: true))
        let store = RecordingsLibraryStorage(baseDirectory: directory, synchronousMetadataWriter: { _, _ in false })
        let before = try XCTUnwrap(store.recordings.first)
        XCTAssertFalse(store.updateTrimRange(id: id, range: AudioTrimRange(startSeconds: 10, endSeconds: 40)))
        XCTAssertEqual(store.recordings.first, before)
        XCTAssertEqual(RecordingsLibraryStorage(baseDirectory: directory).recordings.first, before)
    }

    @MainActor
    func test_transcriptionVersionsKeepTheirSourceSelectionAfterRestore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingsLibraryStorage(baseDirectory: directory)
        let id = try XCTUnwrap(store.saveRecording(audioData: Data([1]), type: .meeting, duration: 100, transcriptionText: "Original", forceSave: true))
        let range = AudioTrimRange(startSeconds: 10, endSeconds: 40)
        XCTAssertTrue(store.updateTrimRange(id: id, range: range))
        store.completeTranscription(id: id, status: .transcribed, text: "Selected", segments: nil, kind: .local)
        XCTAssertTrue(store.updateTrimRange(id: id, range: nil))
        let history = try XCTUnwrap(RecordingsLibraryStorage(baseDirectory: directory).recordings.first).resolvedTranscriptHistory
        XCTAssertEqual(history.map(\.text), ["Original", "Selected"])
        XCTAssertNil(history[0].sourceTrimRange)
        XCTAssertEqual(history[1].sourceTrimRange, range)
    }

    func test_selectedExportUsesActualSamplesAndPreservesOriginalBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("input.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
            buffer.frameLength = 16000
            for index in 0..<16000 { buffer.floatChannelData![0][index] = Float(index) / 16000 }
            try file.write(from: buffer)
        }
        let original = try Data(contentsOf: source)
        let output = try await AudioTrimService.prepareAudio(fileURL: source, range: AudioTrimRange(startSeconds: 0.5, endSeconds: 1.25))
        defer { try? FileManager.default.removeItem(at: output) }
        XCTAssertNotEqual(output, source)
        do {
            let file = try AVAudioFile(forReading: output)
            XCTAssertEqual(file.length, 6000)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 6000))
            try file.read(into: buffer)
            XCTAssertEqual(buffer.floatChannelData![0][0], 0.25, accuracy: 0.0001)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        let unchanged = try await AudioTrimService.prepareAudio(fileURL: source, range: nil)
        XCTAssertEqual(unchanged, source)
        try FileManager.default.removeItem(at: output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        do {
            _ = try await AudioTrimService.prepareAudio(fileURL: source, range: AudioTrimRange(startSeconds: 0, endSeconds: 3))
            XCTFail("An interval beyond the audio must fail")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

}
