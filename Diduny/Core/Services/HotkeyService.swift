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
    private var recordingHandler: (() -> Void)?
    private var meetingHandler: (() -> Void)?
    private var meetingTranslationHandler: (() -> Void)?
    private var translationHandler: (() -> Void)?
    private var chapterHandler: (() -> Void)?
    private var historyPaletteHandler: (() -> Void)?

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

    // MARK: - Meeting Translation Hotkey

    func registerMeetingTranslationHotkey(handler: @escaping () -> Void) {
        meetingTranslationHandler = handler
        KeyboardShortcuts.onKeyDown(for: .toggleMeetingTranslation) { [weak self] in
            self?.meetingTranslationHandler?()
        }
    }

    func unregisterMeetingTranslationHotkey() {
        KeyboardShortcuts.disable(.toggleMeetingTranslation)
        meetingTranslationHandler = nil
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
}
