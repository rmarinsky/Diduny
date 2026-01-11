import Foundation
import Combine
import os

enum RecordingState: Equatable, CustomStringConvertible {
    case idle
    case recording
    case processing
    case success
    case error

    var description: String {
        switch self {
        case .idle: return "idle"
        case .recording: return "recording"
        case .processing: return "processing"
        case .success: return "success"
        case .error: return "error"
        }
    }
}

enum MeetingRecordingState: Equatable, CustomStringConvertible {
    case idle
    case recording
    case processing
    case success
    case error

    var description: String {
        switch self {
        case .idle: return "idle"
        case .recording: return "recording"
        case .processing: return "processing"
        case .success: return "success"
        case .error: return "error"
        }
    }
}

enum TranslationRecordingState: Equatable, CustomStringConvertible {
    case idle
    case recording
    case processing
    case success
    case error

    var description: String {
        switch self {
        case .idle: return "idle"
        case .recording: return "recording"
        case .processing: return "processing"
        case .success: return "success"
        case .error: return "error"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var recordingState: RecordingState = .idle {
        didSet {
            Log.app.debug("recordingState changed: \(oldValue.description) -> \(self.recordingState.description)")
        }
    }
    @Published var recordingStartTime: Date?
    @Published var lastTranscription: String?
    @Published var errorMessage: String? {
        didSet {
            if let msg = errorMessage {
                Log.app.debug("errorMessage set: \(msg)")
            }
        }
    }

    @Published var useAutoDetect: Bool {
        didSet {
            SettingsStorage.shared.useAutoDetect = useAutoDetect
        }
    }
    @Published var selectedDeviceID: AudioDeviceID? {
        didSet {
            SettingsStorage.shared.selectedDeviceID = selectedDeviceID
        }
    }
    @Published var microphonePermissionGranted: Bool = false
    @Published var screenCapturePermissionGranted: Bool = false

    // Settings trigger (for opening settings from non-SwiftUI code)
    @Published var shouldOpenSettings: Bool = false

    // Meeting recording
    @Published var meetingRecordingState: MeetingRecordingState = .idle {
        didSet {
            Log.app.debug("meetingRecordingState changed: \(oldValue.description) -> \(self.meetingRecordingState.description)")
        }
    }
    @Published var meetingRecordingStartTime: Date?

    // Translation recording (EN <-> UK)
    @Published var translationRecordingState: TranslationRecordingState = .idle {
        didSet {
            Log.app.debug("translationRecordingState changed: \(oldValue.description) -> \(self.translationRecordingState.description)")
        }
    }
    @Published var translationRecordingStartTime: Date?

    var recordingDuration: TimeInterval {
        guard let startTime = recordingStartTime else { return 0 }
        return Date().timeIntervalSince(startTime)
    }

    var meetingRecordingDuration: TimeInterval {
        guard let startTime = meetingRecordingStartTime else { return 0 }
        return Date().timeIntervalSince(startTime)
    }

    var translationRecordingDuration: TimeInterval {
        guard let startTime = translationRecordingStartTime else { return 0 }
        return Date().timeIntervalSince(startTime)
    }

    init() {
        let settings = SettingsStorage.shared
        self.useAutoDetect = settings.useAutoDetect
        self.selectedDeviceID = settings.selectedDeviceID
        Log.app.debug("Initialized: useAutoDetect=\(self.useAutoDetect), selectedDeviceID=\(String(describing: self.selectedDeviceID))")
    }
}
