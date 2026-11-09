import Foundation
@testable import Diduny
import Testing

@Suite("Completion sound")
struct CompletionSoundTests {
    /// A stuck output device must not hold up the panel's move to the outcome (Roman's item 10).
    @Test func aStuckDeviceDoesNotHoldTheCaller() async {
        let finished = AsyncStream<Void>.makeStream()
        let started = Date()
        CompletionSound.play {
            Thread.sleep(forTimeInterval: 0.5)
            finished.continuation.yield()
            finished.continuation.finish()
        }
        #expect(Date().timeIntervalSince(started) < 0.25)
        for await _ in finished.stream {}
        #expect(Date().timeIntervalSince(started) >= 0.5)
    }
}
