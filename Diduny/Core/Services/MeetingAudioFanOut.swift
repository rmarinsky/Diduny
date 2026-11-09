import Foundation
import os

/// The one live-audio callback of a meeting (ADR-0013 D1). Capture calls `deliver`; a switch only swaps the
/// consumer, so it never touches capture or the saved file and no buffer goes to two engines.
final class MeetingAudioFanOut: @unchecked Sendable {
    private let lock = NSLock()
    private var consumer: (@Sendable (Data) -> Void)?
    private let frames = OSAllocatedUnfairLock(initialState: 0)

    /// 16-bit mono frames delivered so far. Counted in the same lock section that picks the consumer, so a cut
    /// read in `setConsumer` splits the stream exactly where the consumers changed.
    var deliveredFrames: Int { frames.withLock { $0 } }

    func deliver(_ data: Data) {
        lock.lock()
        let current = consumer
        frames.withLock { $0 += data.count / 2 }
        lock.unlock()
        current?(data)
    }

    /// Swaps the consumer and reads the frame offset in one lock section: that offset is the cut.
    @discardableResult
    func setConsumer(_ next: (@Sendable (Data) -> Void)?, readFrame: () -> Int = { 0 }) -> Int {
        lock.lock()
        let previous = consumer
        consumer = next
        let frame = readFrame()
        lock.unlock()
        _ = previous // Released outside the lock.
        return frame
    }
}
