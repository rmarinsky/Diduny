import Foundation
import os

/// The one live-audio callback of a meeting (ADR-0013 D1). Capture calls `deliver`; a switch only swaps the
/// consumer, so it never touches capture or the saved file and no buffer goes to two engines.
final class MeetingAudioFanOut: @unchecked Sendable {
    private let consumer = OSAllocatedUnfairLock<(@Sendable (Data) -> Void)?>(initialState: nil)

    func deliver(_ data: Data) {
        consumer.withLock { $0 }?(data)
    }

    /// Swaps the consumer and reads the frame offset in one lock section: that offset is the cut.
    @discardableResult
    func setConsumer(_ next: (@Sendable (Data) -> Void)?, readFrame: () -> Int = { 0 }) -> Int {
        consumer.withLockUnchecked { current in
            current = next
            return readFrame()
        }
    }
}
