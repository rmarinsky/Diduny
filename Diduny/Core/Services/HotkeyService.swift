import Foundation
import KeyboardShortcuts

// MARK: - Shortcut Names Extension

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", default: .init(.d, modifiers: [.command, .option]))
    static let toggleMeetingRecording = Self("toggleMeetingRecording", default: .init(.m, modifiers: [.command, .option]))
    static let toggleTranslation = Self("toggleTranslation", default: .init(.slash, modifiers: [.command, .option]))
}

// MARK: - Hotkey Service

final class HotkeyService: HotkeyServiceProtocol {
    private var recordingHandler: (() -> Void)?
    private var meetingHandler: (() -> Void)?
    private var translationHandler: (() -> Void)?

    // MARK: - Recording Hotkey

    func registerRecordingHotkey(handler: @escaping () -> Void) {
        recordingHandler = handler
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            self?.recordingHandler?()
        }
    }

    func unregisterRecordingHotkey() {
        KeyboardShortcuts.disable(.toggleRecording)
        recordingHandler = nil
    }

    // MARK: - Meeting Hotkey

    func registerMeetingHotkey(handler: @escaping () -> Void) {
        meetingHandler = handler
        KeyboardShortcuts.onKeyDown(for: .toggleMeetingRecording) { [weak self] in
            self?.meetingHandler?()
        }
    }

    func unregisterMeetingHotkey() {
        KeyboardShortcuts.disable(.toggleMeetingRecording)
        meetingHandler = nil
    }

    // MARK: - Translation Hotkey

    func registerTranslationHotkey(handler: @escaping () -> Void) {
        translationHandler = handler
        KeyboardShortcuts.onKeyDown(for: .toggleTranslation) { [weak self] in
            self?.translationHandler?()
        }
    }

    func unregisterTranslationHotkey() {
        KeyboardShortcuts.disable(.toggleTranslation)
        translationHandler = nil
    }

    // MARK: - Convenience Methods

    func unregisterAll() {
        unregisterRecordingHotkey()
        unregisterMeetingHotkey()
        unregisterTranslationHotkey()
    }
}
