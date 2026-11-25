import Foundation

/// A single consented read. Revocation stops subsequent operations; an in-flight OS call may finish.
public final class ReadAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    private let seconds: Int
    private let deadline: Date
    /// Twelve seconds covers naming a window. A calendar page walk gets longer: a cold Edge tree can outlast the short budget.
    public init(now: Date = Date(), seconds: Int = 12) {
        self.seconds = seconds
        deadline = now.addingTimeInterval(TimeInterval(seconds))
    }
    public func check(now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        if revoked { throw CancellationError() }
        if now >= deadline { throw ReadTimeout(seconds: seconds) }
    }
    public func cancel() { lock.lock(); revoked = true; lock.unlock() }
}
private struct ReadTimeout: LocalizedError {
    let seconds: Int
    var errorDescription: String? { String(localized: "Reading took more than \(seconds) seconds. Retry when the page has loaded.") }
}
