import Foundation

struct AudioTrimEditorState {
    let duration: TimeInterval
    private let savedRange: AudioTrimRange
    private(set) var range: AudioTrimRange
    private var undoRanges: [AudioTrimRange] = []
    private var redoRanges: [AudioTrimRange] = []
    private var gestureStart: AudioTrimRange?

    init(duration: TimeInterval, savedRange: AudioTrimRange?) {
        self.duration = duration
        let original = AudioTrimRange(startSeconds: 0, endSeconds: duration)
        let initial = savedRange.flatMap { $0.isValid(for: duration) ? $0 : nil } ?? original
        self.savedRange = initial
        range = initial
    }

    var isDirty: Bool { range != savedRange }
    var canUndo: Bool { !undoRanges.isEmpty }
    var canRedo: Bool { !redoRanges.isEmpty }
    var rangeToSave: AudioTrimRange? {
        range.startSeconds == 0 && range.endSeconds == duration ? nil : range
    }

    mutating func beginGesture() { gestureStart = range }
    mutating func endGesture() {
        if let previous = gestureStart, previous != range {
            undoRanges.append(previous)
            redoRanges.removeAll()
        }
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
    mutating func setTime(_ text: String, isStart: Bool) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]),
              hours >= 0, hours.rounded() == hours, minutes >= 0, minutes < 60, minutes.rounded() == minutes,
              seconds >= 0, seconds < 60 else { return false }
        let value = hours * 3600 + minutes * 60 + seconds
        let next = AudioTrimRange(startSeconds: isStart ? value : range.startSeconds, endSeconds: isStart ? range.endSeconds : value)
        guard next.isValid(for: duration) else { return false }
        change(next)
        return true
    }
    mutating func restoreOriginal() { change(AudioTrimRange(startSeconds: 0, endSeconds: duration)) }
    mutating func cancel() { range = savedRange; undoRanges.removeAll(); redoRanges.removeAll(); gestureStart = nil }
    mutating func undo() {
        guard let previous = undoRanges.popLast() else { return }
        redoRanges.append(range); range = previous
    }
    mutating func redo() {
        guard let next = redoRanges.popLast() else { return }
        undoRanges.append(range); range = next
    }
    private mutating func change(_ next: AudioTrimRange) {
        guard next != range, next.isValid(for: duration) else { return }
        if gestureStart == nil { undoRanges.append(range); redoRanges.removeAll() }
        range = next
    }
    static func format(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "00:00:00" }
        let seconds = Int(value)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}
