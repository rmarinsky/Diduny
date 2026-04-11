import Foundation
import KeyboardShortcuts

// MARK: - Shortcut Names Extension

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", default: .init(.d, modifiers: [.command, .option]))
    static let toggleMeetingRecording = Self("toggleMeetingRecording", default: .init(.m, modifiers: [.command, .option]))
    static let toggleMeetingTranslation = Self(
        "toggleMeetingTranslation",
        default: .init(.m, modifiers: [.command, .option, .shift])
    )
    static let toggleTranslation = Self("toggleTranslation", default: .init(.slash, modifiers: [.command, .option]))
    static let addMeetingChapter = Self("addMeetingChapter", default: .init(.b, modifiers: [.command, .option]))
    static let toggleHistoryPalette = Self("toggleHistoryPalette", default: .init(.h, modifiers: [.command, .option]))
}

// MARK: - Hotkey Service

final class HotkeyService: HotkeyServiceProtocol {
    private struct PressTracker {
        var lastPressAt: TimeInterval?
        var count = 0

        mutating func registerPress(at eventTime: TimeInterval, requiredPressCount: Int, threshold: TimeInterval) -> Bool {
            guard requiredPressCount > 1 else {
                reset()
                return true
            }

            if let lastPressAt, eventTime - lastPressAt < threshold {
                count += 1
            } else {
                count = 1
            }
            self.lastPressAt = eventTime

            guard count >= requiredPressCount else { return false }
            reset()
            return true
        }

        mutating func reset() {
            lastPressAt = nil
            count = 0
        }
    }

    private enum MultiPressHotkey {
        case recording
        case translation
        case meeting
        case meetingTranslation
    }

    private let multiPressThreshold: TimeInterval = 0.35

    private var recordingHandler: (() -> Void)?
    private var meetingHandler: (() -> Void)?
    private var meetingTranslationHandler: (() -> Void)?
    private var translationHandler: (() -> Void)?
    private var chapterHandler: (() -> Void)?
    private var historyPaletteHandler: (() -> Void)?

    private var recordingPressTracker = PressTracker()
    private var translationPressTracker = PressTracker()
    private var meetingPressTracker = PressTracker()
    private var meetingTranslationPressTracker = PressTracker()

    // MARK: - Recording Hotkey

    func registerRecordingHotkey(handler: @escaping () -> Void) {
        recordingHandler = handler
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            self?.handleMultiPress(.recording)
        }
    }

    func unregisterRecordingHotkey() {
        KeyboardShortcuts.disable(.toggleRecording)
        recordingPressTracker.reset()
        recordingHandler = nil
    }

    // MARK: - Meeting Hotkey

    func registerMeetingHotkey(handler: @escaping () -> Void) {
        meetingHandler = handler
        KeyboardShortcuts.onKeyDown(for: .toggleMeetingRecording) { [weak self] in
            self?.handleMultiPress(.meeting)
        }
    }

    func unregisterMeetingHotkey() {
        KeyboardShortcuts.disable(.toggleMeetingRecording)
        meetingPressTracker.reset()
        meetingHandler = nil
    }

    // MARK: - Meeting Translation Hotkey

    func registerMeetingTranslationHotkey(handler: @escaping () -> Void) {
        meetingTranslationHandler = handler
        KeyboardShortcuts.onKeyDown(for: .toggleMeetingTranslation) { [weak self] in
            self?.handleMultiPress(.meetingTranslation)
        }
    }

    func unregisterMeetingTranslationHotkey() {
        KeyboardShortcuts.disable(.toggleMeetingTranslation)
        meetingTranslationPressTracker.reset()
        meetingTranslationHandler = nil
    }

    // MARK: - Translation Hotkey

    func registerTranslationHotkey(handler: @escaping () -> Void) {
        translationHandler = handler
        KeyboardShortcuts.onKeyDown(for: .toggleTranslation) { [weak self] in
            self?.handleMultiPress(.translation)
        }
    }

    func unregisterTranslationHotkey() {
        KeyboardShortcuts.disable(.toggleTranslation)
        translationPressTracker.reset()
        translationHandler = nil
    }

    // MARK: - Chapter Bookmark Hotkey

    func registerChapterHotkey(handler: @escaping () -> Void) {
        chapterHandler = handler
        KeyboardShortcuts.onKeyDown(for: .addMeetingChapter) { [weak self] in
            self?.chapterHandler?()
        }
    }

    func unregisterChapterHotkey() {
        KeyboardShortcuts.disable(.addMeetingChapter)
        chapterHandler = nil
    }

    // MARK: - History Palette Hotkey

    func registerHistoryPaletteHotkey(handler: @escaping () -> Void) {
        historyPaletteHandler = handler
        KeyboardShortcuts.onKeyDown(for: .toggleHistoryPalette) { [weak self] in
            self?.historyPaletteHandler?()
        }
    }

    func unregisterHistoryPaletteHotkey() {
        KeyboardShortcuts.disable(.toggleHistoryPalette)
        historyPaletteHandler = nil
    }

    // MARK: - Convenience Methods

    func unregisterAll() {
        unregisterRecordingHotkey()
        unregisterMeetingHotkey()
        unregisterMeetingTranslationHotkey()
        unregisterTranslationHotkey()
        unregisterChapterHotkey()
        unregisterHistoryPaletteHotkey()
    }

    // MARK: - Multi-Press

    private func handleMultiPress(_ hotkey: MultiPressHotkey) {
        let eventTime = Date().timeIntervalSinceReferenceDate
        let requiredPressCount = requiredPressCount(for: hotkey)
        let didTrigger: Bool

        switch hotkey {
        case .recording:
            didTrigger = recordingPressTracker.registerPress(
                at: eventTime,
                requiredPressCount: requiredPressCount,
                threshold: multiPressThreshold
            )
            if didTrigger {
                recordingHandler?()
            }
        case .translation:
            didTrigger = translationPressTracker.registerPress(
                at: eventTime,
                requiredPressCount: requiredPressCount,
                threshold: multiPressThreshold
            )
            if didTrigger {
                translationHandler?()
            }
        case .meeting:
            didTrigger = meetingPressTracker.registerPress(
                at: eventTime,
                requiredPressCount: requiredPressCount,
                threshold: multiPressThreshold
            )
            if didTrigger {
                meetingHandler?()
            }
        case .meetingTranslation:
            didTrigger = meetingTranslationPressTracker.registerPress(
                at: eventTime,
                requiredPressCount: requiredPressCount,
                threshold: multiPressThreshold
            )
            if didTrigger {
                meetingTranslationHandler?()
            }
        }
    }

    private func requiredPressCount(for hotkey: MultiPressHotkey) -> Int {
        switch hotkey {
        case .recording:
            SettingsStorage.shared.recordingHotkeyPressCount
        case .translation:
            SettingsStorage.shared.translationHotkeyPressCount
        case .meeting:
            SettingsStorage.shared.meetingHotkeyPressCount
        case .meetingTranslation:
            SettingsStorage.shared.meetingTranslationHotkeyPressCount
        }
    }
}
