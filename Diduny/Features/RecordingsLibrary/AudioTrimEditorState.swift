import Foundation

struct AudioTrimEditorState {
    private struct Snapshot: Equatable {
        let range: AudioTrimRange
        let startText: String
        let endText: String
    }
    let duration: TimeInterval
    private let savedRange: AudioTrimRange
    private(set) var range: AudioTrimRange
    private(set) var startText: String
    private(set) var endText: String
    private var undoStates: [Snapshot] = []
    private var redoStates: [Snapshot] = []
    private var gestureStart: Snapshot?
    private var snapshot: Snapshot { Snapshot(range: range, startText: startText, endText: endText) }

    init(duration: TimeInterval, savedRange: AudioTrimRange?) {
        self.duration = duration
        let original = AudioTrimRange(startSeconds: 0, endSeconds: duration)
        let initial = savedRange.flatMap { $0.isValid(for: duration) ? $0 : nil } ?? original
        self.savedRange = initial
        range = initial
        startText = Self.format(initial.startSeconds)
        endText = Self.format(initial.endSeconds)
    }
    var isDirty: Bool { range != savedRange || startText != Self.format(savedRange.startSeconds) || endText != Self.format(savedRange.endSeconds) }
    var hasInvalidTime: Bool { parsedFields == nil }
    var canUndo: Bool { !undoStates.isEmpty || (gestureStart != nil && gestureStart != snapshot) }
    var canRedo: Bool { !redoStates.isEmpty }
    var rangeToSave: AudioTrimRange? { range.startSeconds == 0 && range.endSeconds == duration ? nil : range }

    mutating func beginGesture() { endGesture(); gestureStart = snapshot }
    mutating func endGesture() {
        if let previous = gestureStart, previous != snapshot { undoStates.append(previous) }
        gestureStart = nil
    }
    mutating func setStart(_ value: TimeInterval) {
        guard value.isFinite else { return }
        change(AudioTrimRange(startSeconds: max(0, min(value, range.endSeconds - min(0.01, duration / 2))), endSeconds: range.endSeconds))
    }
    mutating func setEnd(_ value: TimeInterval) {
        guard value.isFinite else { return }
        change(AudioTrimRange(startSeconds: range.startSeconds, endSeconds: min(duration, max(value, range.startSeconds + min(0.01, duration / 2)))))
    }
    @discardableResult
    mutating func setTime(_ text: String, isStart: Bool) -> Bool {
        guard let value = Self.parse(text) else { return false }
        let next = AudioTrimRange(startSeconds: isStart ? value : range.startSeconds, endSeconds: isStart ? range.endSeconds : value)
        guard next.isValid(for: duration) else { return false }
        change(next)
        return true
    }
    mutating func editTime(_ text: String, isStart: Bool) {
        let previous = snapshot
        if isStart { startText = text } else { endText = text }
        if let next = parsedFields { range = next }
        recordChange(from: previous)
    }
    @discardableResult
    mutating func commitTimeFields() -> Bool {
        guard let next = parsedFields else { return false }
        let previous = snapshot
        range = next
        synchronizeFields()
        recordChange(from: previous)
        endGesture()
        return true
    }
    mutating func restoreOriginal() { change(AudioTrimRange(startSeconds: 0, endSeconds: duration)) }
    mutating func cancel() { range = savedRange; synchronizeFields(); undoStates.removeAll(); redoStates.removeAll(); gestureStart = nil }
    mutating func undo() {
        endGesture()
        guard let previous = undoStates.popLast() else { return }
        redoStates.append(snapshot)
        apply(previous)
    }
    mutating func redo() {
        endGesture()
        guard let next = redoStates.popLast() else { return }
        undoStates.append(snapshot)
        apply(next)
    }
    private mutating func apply(_ state: Snapshot) { range = state.range; startText = state.startText; endText = state.endText }
    private mutating func change(_ next: AudioTrimRange) {
        guard next.isValid(for: duration) else { return }
        let previous = snapshot
        range = next
        synchronizeFields()
        recordChange(from: previous)
    }
    private mutating func recordChange(from previous: Snapshot) {
        guard previous != snapshot else { return }
        if gestureStart == nil { undoStates.append(previous) }
        redoStates.removeAll()
    }
    private var parsedFields: AudioTrimRange? {
        let start = startText == Self.format(range.startSeconds) ? range.startSeconds : Self.parse(startText)
        let end = endText == Self.format(range.endSeconds) ? range.endSeconds : Self.parse(endText)
        guard let start, let end else { return nil }
        let candidate = AudioTrimRange(startSeconds: start, endSeconds: end)
        return candidate.isValid(for: duration) ? candidate : nil
    }
    private static func parse(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]),
              h.isFinite, m.isFinite, s.isFinite, h >= 0, h.rounded() == h,
              m >= 0, m < 60, m.rounded() == m, s >= 0, s < 60 else { return nil }
        return h * 3600 + m * 60 + s
    }
    private mutating func synchronizeFields() { startText = Self.format(range.startSeconds); endText = Self.format(range.endSeconds) }
    static func format(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0, value < Double(Int.max) else { return "00:00:00" }
        let seconds = Int(value)
        if abs(value - Double(seconds)) > 0.0001 {
            return String(format: "%02d:%02d:%06.3f", seconds / 3600, seconds / 60 % 60, value.truncatingRemainder(dividingBy: 60))
        }
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}
