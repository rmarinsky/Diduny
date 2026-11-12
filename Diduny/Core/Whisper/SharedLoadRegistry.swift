import Foundation

/// One loaded value per key across all owners: a second owner gets the value another one already
/// loaded, or joins its load. Values are held weakly, so the value is freed once no owner keeps it.
/// Used for Whisper contexts: each queue item no longer loads its own copy of a model.
final class SharedLoadRegistry<Value: AnyObject & Sendable>: @unchecked Sendable {
    private final class WeakBox {
        weak var value: Value?
        init(_ value: Value) { self.value = value }
    }

    private let lock = NSLock()
    private var loaded: [String: WeakBox] = [:]
    private var pending: [String: Task<Value, Error>] = [:]

    func value(for key: String, load: @escaping @Sendable () throws -> Value) async throws -> Value {
        let task: Task<Value, Error> = lock.withLock {
            if let value = loaded[key]?.value { return Task { value } }
            if let task = pending[key] { return task }
            let task = Task.detached(priority: .userInitiated) { try load() }
            pending[key] = task
            return task
        }
        do {
            let value = try await task.value
            lock.withLock {
                pending[key] = nil
                loaded[key] = WeakBox(value)
            }
            return value
        } catch {
            lock.withLock { pending[key] = nil }
            throw error
        }
    }
}
