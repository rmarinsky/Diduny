import Foundation

struct RecoveryState: Codable {
    let tempFilePath: String
    let startTime: Date
    let recordingType: RecordingType

    enum RecordingType: String, Codable {
        case voice
        case meeting
        case translation
    }
}

final class RecoveryStateManager {
    static let shared = RecoveryStateManager()

    private let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "Diduny"
        let appDir = appSupport.appendingPathComponent(bundleID)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("recovery_state.json")
    }()

    private init() {}

    func saveState(_ state: RecoveryState) {
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL)
            Log.app.debug("Recovery state saved: \(state.recordingType.rawValue)")
        } catch {
            Log.app.error("Failed to save recovery state: \(error.localizedDescription)")
        }
    }

    func loadState() -> RecoveryState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(RecoveryState.self, from: data)
    }

    func clearState() {
        try? FileManager.default.removeItem(at: fileURL)
        Log.app.debug("Recovery state cleared")
    }

    func hasOrphanedRecording() -> (state: RecoveryState, fileExists: Bool)? {
        guard let state = loadState() else { return nil }
        let exists = FileManager.default.fileExists(atPath: state.tempFilePath)
        return (state, exists)
    }
}
