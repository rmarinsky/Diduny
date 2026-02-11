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

    /// Warning message shown when selected device is unavailable and fallback was used
    var deviceFallbackWarning: String? {
        didSet {
            if let warning = deviceFallbackWarning {
                Log.app.debug("deviceFallbackWarning set: \(warning)")
            }
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
    var meetingRecordingState: RecordingState = .idle {
        didSet {
            Log.app
                .debug("meetingRecordingState changed: \(oldValue.description) -> \(self.meetingRecordingState.description)")
        }
    }

    var meetingRecordingStartTime: Date?
    var meetingChapters: [MeetingChapter] = []
    var liveTranscriptStore: LiveTranscriptStore?

    // Translation recording (EN <-> UK)
    var translationRecordingState: RecordingState = .idle {
        didSet {
            Log.app
                .debug(
                    "translationRecordingState changed: \(oldValue.description) -> \(self.translationRecordingState.description)"
                )
        }
    }

    var translationRecordingStartTime: Date?

    var ambientListeningActive: Bool = false

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
        selectedDeviceID = settings.selectedDeviceID
        Log.app
            .debug(
                "Initialized: selectedDeviceID=\(String(describing: self.selectedDeviceID))"
            )
    }
}

