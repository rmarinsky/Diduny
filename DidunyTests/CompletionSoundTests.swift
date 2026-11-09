import Foundation
@testable import Diduny
import os
import Testing

@Suite("Completion sound")
struct CompletionSoundTests {
    /// A stuck output device must not hold up the panel's move to the outcome (Roman's item 10).
    @Test func aStuckDeviceDoesNotHoldTheCaller() async {
        let device = DispatchSemaphore(value: 0)
        let played = OSAllocatedUnfairLock(initialState: false)
        let finished = AsyncStream<Void>.makeStream()
        CompletionSound.play {
            // Times out only if `play` ran on the caller, which the check below then catches.
            _ = device.wait(timeout: .now() + 5)
            played.withLock { $0 = true }
            finished.continuation.finish()
        }
        #expect(!played.withLock { $0 })
        device.signal()
        for await _ in finished.stream {}
        #expect(played.withLock { $0 })
    }
}
