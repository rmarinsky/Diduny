import Foundation

/// The one live-audio callback of a meeting (ADR-0013 D1). Capture calls `deliver`; a switch only swaps the
/// consumer, so it never touches capture or the saved file and no buffer goes to two engines.
final class MeetingAudioFanOut: @unchecked Sendable {
    private let lock = NSLock()
    private var consumer: (@Sendable (Data) -> Void)?

    func deliver(_ data: Data) {
        lock.lock()
        let current = consumer
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
