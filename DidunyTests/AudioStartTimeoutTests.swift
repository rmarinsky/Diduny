@testable import Diduny
import Foundation
import Testing

/// A slow microphone must not hold the start: the timeout returns while the CoreAudio call still blocks.
struct AudioStartTimeoutTests {
    @Test("Timeout fires while the work is still blocked")
    func timeoutFiresWhileBlocked() async {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let queue = DispatchQueue(label: "test.audio-engine")
        let start = Date()
        await #expect(throws: AudioTimeoutError.self) {
            try await AudioRecorderService.runWithTimeout(on: queue, operation: "test", timeout: 0.2) {
                gate.wait()
            }
        }
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test("Fast work returns its value")
    func fastWorkReturnsValue() async throws {
        let queue = DispatchQueue(label: "test.audio-engine")
        let value = try await AudioRecorderService.runWithTimeout(on: queue, operation: "test", timeout: 2) { 42 }
        #expect(value == 42)
    }

    @Test("Work errors pass through")
    func workErrorPassesThrough() async {
        struct Boom: Error {}
        let queue = DispatchQueue(label: "test.audio-engine")
        await #expect(throws: Boom.self) {
            try await AudioRecorderService.runWithTimeout(on: queue, operation: "test", timeout: 2) { throw Boom() }
        }
    }

    @Test("A new recording clears the microphone notice")
    @MainActor
    func resetClearsMicNotice() {
        let store = LiveDictationOverlayStore()
        store.micNotice = "iPhone Microphone did not start. Recording from MacBook Pro Microphone."
        store.reset(mode: .voice)
        #expect(store.micNotice == nil)
    }
}
