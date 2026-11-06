@testable import Diduny
import AppKit
import XCTest

final class LocalWhisperStreamingServiceTests: XCTestCase {
    @MainActor
    func testLocalMeetingModeCreatesLiveTranscriptPipeline() async {
        let delegate = AppDelegate()
        EdgeCommandPanelController.shared.configure(appDelegate: delegate)

        let store = await delegate.setupMeetingLiveTranscription(cloudModeEnabled: false)

        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.connectionStatus, .connected)
        XCTAssertNotNil(delegate.localMeetingStreamingService)
        XCTAssertNotNil(delegate.meetingRecorderService.onRealtimeAudioData)

        DictationOverlayController.shared.startRecording(mode: .meeting)
        let flowPanel = NSApp.windows.first {
            $0.identifier?.rawValue == "commandPanel"
        }
        XCTAssertEqual(flowPanel?.isVisible, true)
        XCTAssertEqual(flowPanel?.level, .floating)
        XCTAssertEqual(flowPanel?.collectionBehavior.contains(.canJoinAllSpaces), true)
        XCTAssertEqual(flowPanel?.collectionBehavior.contains(.fullScreenAuxiliary), true)

        DictationOverlayController.shared.dismiss()
        await delegate.stopMeetingLiveTranscription()

        XCTAssertNil(delegate.localMeetingStreamingService)
        XCTAssertNil(delegate.meetingRecorderService.onRealtimeAudioData)
    }

    func testWhisperSegmentTimestampsConvertToMilliseconds() {
        XCTAssertEqual(WhisperContext.milliseconds(fromTimestamp: 123), 1_230)
        XCTAssertEqual(WhisperContext.milliseconds(fromTimestamp: 456), 4_560)
    }

    func testSilenceDoesNotRunWhisper() async {
        let calls = CallCounter()
        let service = LocalWhisperStreamingService(
            configuration: .init(
                sampleRate: 4,
                windowDuration: 2,
                stepDuration: 1,
                rmsThreshold: 0.01,
                peakThreshold: 0.02
            ),
            transcribe: { samples in
                await calls.record(samples)
                return "unexpected"
            },
            onText: { _ in }
        )

        await service.appendPCM16(pcmData([0, 0, 0, 0]))
        await service.waitUntilIdle()

        let callCount = await calls.count
        XCTAssertEqual(callCount, 0)
    }

    func testQuietSpeechRunsWhisper() async {
        let calls = CallCounter()
        let service = LocalWhisperStreamingService(
            transcribe: { samples in
                await calls.record(samples)
                return "quiet speech"
            },
            onText: { _ in }
        )
        var samples = Array(repeating: Int16(80), count: 48_000)
        for index in stride(from: 0, to: samples.count, by: 32) {
            samples[index] = index.isMultiple(of: 64) ? 670 : -670
        }

        await service.appendPCM16(pcmData(samples))
        await service.waitUntilIdle()

        let callCount = await calls.count
        XCTAssertEqual(callCount, 1)
    }

    func testOverlappingWindowsEmitDeduplicatedCumulativeText() async {
        let transcriber = ScriptedTranscriber([
            "hello brave world",
            "brave world from Diduny",
            "brave world from Diduny",
        ])
        let texts = TextCollector()
        let service = LocalWhisperStreamingService(
            configuration: .init(
                sampleRate: 4,
                windowDuration: 2,
                stepDuration: 1,
                rmsThreshold: 0.01,
                peakThreshold: 0.02
            ),
            transcribe: { _ in try await transcriber.next() },
            onText: { text in await texts.append(text) }
        )

        for _ in 0 ..< 3 {
            await service.appendPCM16(pcmData([10_000, 10_000, 10_000, 10_000]))
            await service.waitUntilIdle()
        }

        let emittedTexts = await texts.values
        XCTAssertEqual(emittedTexts, ["hello brave world", "hello brave world from Diduny"])
    }

    private func pcmData(_ samples: [Int16]) -> Data {
        samples.withUnsafeBytes { Data($0) }
    }
}

private actor ScriptedTranscriber {
    private var responses: [String]

    init(_ responses: [String]) {
        self.responses = responses
    }

    func next() throws -> String {
        guard !responses.isEmpty else { throw TranscriptionError.emptyTranscription }
        return responses.removeFirst()
    }
}

private actor TextCollector {
    private(set) var values: [String] = []

    func append(_ text: String) {
        values.append(text)
    }
}

private actor CallCounter {
    private(set) var count = 0

    func record(_: [Float]) {
        count += 1
    }
}
