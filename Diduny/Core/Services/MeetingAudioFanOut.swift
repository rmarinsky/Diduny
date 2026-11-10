import Foundation
import os

/// The one live-audio callback of a meeting (ADR-0013 D1). Capture calls `deliver`; a switch only swaps the
/// consumer, so it never touches capture or the saved file and no buffer goes to two engines.
final class MeetingAudioFanOut: @unchecked Sendable {
    private let lock = NSLock()
    private var consumer: (@Sendable (Data) -> Void)?
    private let frames = OSAllocatedUnfairLock(initialState: 0)
    private let levelBox = OSAllocatedUnfairLock<Float>(initialState: 0)

    /// The latest mixed mic + system level, 0...1 on the dictation meter's -60...0 dB scale. Set on every
    /// delivery, with or without a consumer, so Record only and a switch in progress still move the meter.
    var level: Float { levelBox.withLock { $0 } }

    /// 16-bit mono frames delivered so far. Counted in the same lock section that picks the consumer, so a cut
    /// read in `setConsumer` splits the stream exactly where the consumers changed.
    var deliveredFrames: Int { frames.withLock { $0 } }

    func deliver(_ data: Data) {
        lock.lock()
        let current = consumer
        frames.withLock { $0 += data.count / 2 }
        lock.unlock()
        levelBox.withLock { $0 = Self.level(of: data) }
        current?(data)
    }

    /// RMS of 16-bit mono PCM mapped like `AudioRecorderService`: -60 dB is 0, 0 dB is 1.
    static func level(of data: Data) -> Float {
        let count = data.count / 2
        guard count > 0 else { return 0 }
        let sum: Float = data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).prefix(count).reduce(0) { acc, sample in
                let value = Float(sample) / Float(Int16.max)
                return acc + value * value
            }
        }
        let db = 20 * log10(max(sqrt(sum / Float(count)), 0.0001))
        return max(0, min(1, (db + 60) / 60))
    }

    /// Pushes `level` to `sink` on the main actor about 20 times a second until the fan-out is released
    /// (capture clears its callback and the controller goes) or the task is cancelled.
    @MainActor
    static func startLevelPump(
        _ fanOut: MeetingAudioFanOut, interval: Duration = .milliseconds(50), sink: @escaping @MainActor (Float) -> Void
    ) -> Task<Void, Never> {
        weak var weakFanOut = fanOut
        return Task { @MainActor in
            while !Task.isCancelled, let fanOut = weakFanOut {
                sink(fanOut.level)
                try? await Task.sleep(for: interval)
            }
            sink(0)
        }
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
