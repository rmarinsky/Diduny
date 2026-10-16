import Foundation

/// In-memory consent for one observed source. The owner serializes calls.
public struct SyncSession {
    private var source: String?
    private var active: UUID?
    private var lastStart: TimeInterval?
    public init() {}
    public mutating func connect(source: String) {
        self.source = source; active = nil; lastStart = nil
    }
    public mutating func disconnect() {
        source = nil; active = nil; lastStart = nil
    }
    public mutating func begin(source: String, now: TimeInterval, force: Bool = false) -> UUID? {
        guard self.source == source, active == nil else { return nil }
        guard force || lastStart.map({ now - $0 >= 60 }) ?? true else { return nil }
        let read = UUID(); active = read; lastStart = now
        return read
    }
    public mutating func finish(_ read: UUID, now: TimeInterval) -> Bool {
        guard source != nil, active == read else { return false }
        active = nil
        return true
    }
}
