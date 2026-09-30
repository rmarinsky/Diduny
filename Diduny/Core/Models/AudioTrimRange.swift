import Foundation

/// Selected interval in the original audio's time coordinates.
struct AudioTrimRange: Codable, Equatable, Sendable {
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval

    var durationSeconds: TimeInterval { endSeconds - startSeconds }

    func isValid(for duration: TimeInterval) -> Bool {
        duration.isFinite && duration > 0
            && startSeconds.isFinite && endSeconds.isFinite
            && startSeconds >= 0 && startSeconds < endSeconds && endSeconds <= duration
    }
}
