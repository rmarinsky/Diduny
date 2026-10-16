import Foundation

/// A single consented read. Revocation stops subsequent operations; an in-flight OS call may finish.
public final class ReadAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    private let deadline: Date
    public init(now: Date = Date()) { deadline = now.addingTimeInterval(12) }
    public func check(now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        if revoked { throw CancellationError() }
        if now >= deadline { throw ReadTimeout() }
    }
    public func cancel() { lock.lock(); revoked = true; lock.unlock() }
}
private struct ReadTimeout: LocalizedError {
    var errorDescription: String? { "Читання зайняло понад 12 секунд. Спробуйте ще раз, коли сторінка завантажиться." }
}
