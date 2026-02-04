import Foundation
import Observation
import os

enum RecordingState: Equatable, CustomStringConvertible {
    case idle
    case recording
    case processing
    case success
    case error

    var description: String {
        switch self {
        case .idle: "idle"
        case .recording: "recording"
        case .processing: "processing"
        case .success: "success"
        case .error: "error"
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
        case .idle: "idle"
        case .recording: "recording"
        case .processing: "processing"
        case .success: "success"
        case .error: "error"
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
        case .idle: "idle"
        case .recording: "recording"
        case .processing: "processing"
        case .success: "success"
        case .error: "error"
        }
    }
}

@Observable
@MainActor
final class AppState {
    var recordingState: RecordingState = .idle {
        didSet {
            Log.app.debug("recordingState changed: \(oldValue.description) -> \(self.recordingState.description)")
        }
    }

    var recordingStartTime: Date?
    var lastTranscription: String?
    var errorMessage: String? {
        didSet {
            if let msg = errorMessage {
                Log.app.debug("errorMessage set: \(msg)")
            }
        }
    }

    var isEmptyTranscription: Bool = false

    var useAutoDetect: Bool {
        didSet {
            SettingsStorage.shared.useAutoDetect = useAutoDetect
        }
    }

    var selectedDeviceID: AudioDeviceID? {
        didSet {
            SettingsStorage.shared.selectedDeviceID = selectedDeviceID
        }
    }

    var microphonePermissionGranted: Bool = false
    var screenCapturePermissionGranted: Bool = false

    // Settings trigger (for opening settings from non-SwiftUI code)
    var shouldOpenSettings: Bool = false

    // Meeting recording
    var meetingRecordingState: MeetingRecordingState = .idle {
        didSet {
            Log.app
                .debug("meetingRecordingState changed: \(oldValue.description) -> \(self.meetingRecordingState.description)")
        }
    }

    var meetingRecordingStartTime: Date?

    // Translation recording (EN <-> UK)
    var translationRecordingState: TranslationRecordingState = .idle {
        didSet {
            Log.app
                .debug(
                    "translationRecordingState changed: \(oldValue.description) -> \(self.translationRecordingState.description)"
                )
        }
    }

    var translationRecordingStartTime: Date?

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
        useAutoDetect = settings.useAutoDetect
        selectedDeviceID = settings.selectedDeviceID
        Log.app
            .debug(
                "Initialized: useAutoDetect=\(self.useAutoDetect), selectedDeviceID=\(String(describing: self.selectedDeviceID))"
            )
    }
}

// MARK: - RecordingState Extension

extension RecordingState {
    init(from translationState: TranslationRecordingState) {
        switch translationState {
        case .idle: self = .idle
        case .recording: self = .recording
        case .processing: self = .processing
        case .success: self = .success
        case .error: self = .error
        }
    }
}
