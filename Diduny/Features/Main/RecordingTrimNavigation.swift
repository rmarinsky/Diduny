import Observation

/// Guards navigation boundaries that can remove the active trim editor.
@MainActor
@Observable
final class RecordingTrimNavigation {
    static let shared = RecordingTrimNavigation()

    var canLeave: (() -> Bool)?
    var isEditing: Bool { canLeave != nil }

    func requestLeave() -> Bool { canLeave?() ?? true }
}
