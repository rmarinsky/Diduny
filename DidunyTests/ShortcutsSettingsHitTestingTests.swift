import AppKit
@testable import Diduny
import SwiftUI
import Testing

/// Reproduces the Shortcuts tab click bugs by sending real mouse events to the
/// hosted view. Each bug test has a positive control that clicks the visible
/// glyph and must pass, which proves the coordinates below hit the right
/// control; the failing assertion is the click on the control's own padding.
///
/// Coordinates are top-left based, derived from `ShortcutLayout` in
/// ShortcutsSettingsView.swift (content x=22, y=6; action card rows are 48pt;
/// modifier card rows are 77pt). Update them if that layout changes.
@MainActor
struct ShortcutsSettingsHitTestingTests {
    nonisolated private static let windowSize = NSSize(width: 759, height: 666)

    private enum Point {
        // Dictation row of the "Action hotkeys" card (row centre y = 124).
        static let dictation2xGlyph = NSPoint(x: 563, y: 124)
        static let dictation2xPadding = NSPoint(x: 548, y: 124) // inside the 2x segment, left of its text
        static let dictationEditLabel = NSPoint(x: 453, y: 124)
        static let dictationFieldBody = NSPoint(x: 400, y: 124) // between keycaps and "edit"

        // Dictation row of the "Modifier key recording" card (row centre y = 446).
        static let dictationOffGlyph = NSPoint(x: 374, y: 446)
        static let dictationOffPadding = NSPoint(x: 356, y: 446)
    }

    private final class Harness {
        let window: NSWindow

        init() {
            let hostingView = NSHostingView(rootView: ShortcutsSettingsView())
            window = NSWindow(
                contentRect: NSRect(origin: .zero, size: ShortcutsSettingsHitTestingTests.windowSize),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostingView
            // The bugs are about clicks in a settings window the user is already in.
            // If the window isn't key (headless CI host), AppKit spends the first click
            // activating it and text fields never receive it.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            let deadline = Date().addingTimeInterval(2)
            while !window.isKeyWindow, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            settle()
        }

        func settle() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }

        func click(_ topLeft: NSPoint) {
            let point = NSPoint(x: topLeft.x, y: ShortcutsSettingsHitTestingTests.windowSize.height - topLeft.y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type,
                    location: point,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                ) else { continue }
                // Posted through the event queue, not window.sendEvent, so local event
                // monitors (the recorder cancels on mouse-up outside itself) see it.
                NSApp.postEvent(event, atStart: false)
                if let queued = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(queued)
                }
            }
            settle()
        }

        var isShortcutRecorderFocused: Bool {
            let responder = window.firstResponder
            return responder is NSSearchField || (responder as? NSText)?.delegate is NSSearchField
        }
    }

    // MARK: - Trigger after

    @Test("Trigger-after 2x: clicking the glyph selects it (control)")
    func triggerAfterGlyphClick() {
        let original = SettingsStorage.shared.recordingHotkeyPressCount
        defer { SettingsStorage.shared.recordingHotkeyPressCount = original }
        SettingsStorage.shared.recordingHotkeyPressCount = 1

        Harness().click(Point.dictation2xGlyph)

        #expect(SettingsStorage.shared.recordingHotkeyPressCount == 2)
    }

    @Test("Trigger-after 2x: clicking the segment outside its text selects it")
    func triggerAfterPaddingClick() {
        let original = SettingsStorage.shared.recordingHotkeyPressCount
        defer { SettingsStorage.shared.recordingHotkeyPressCount = original }
        SettingsStorage.shared.recordingHotkeyPressCount = 1

        Harness().click(Point.dictation2xPadding)

        #expect(SettingsStorage.shared.recordingHotkeyPressCount == 2)
    }

    // MARK: - Tap trigger

    @Test("Tap trigger Off: clicking the glyph turns it off (control)")
    func tapTriggerOffGlyphClick() {
        let originalKey = SettingsStorage.shared.pushToTalkKey
        let originalToggle = SettingsStorage.shared.pushToTalkToggleEnabled
        defer {
            SettingsStorage.shared.pushToTalkKey = originalKey
            SettingsStorage.shared.pushToTalkToggleEnabled = originalToggle
        }
        SettingsStorage.shared.pushToTalkKey = .rightShift
        SettingsStorage.shared.pushToTalkToggleEnabled = true

        Harness().click(Point.dictationOffGlyph)

        #expect(SettingsStorage.shared.pushToTalkToggleEnabled == false)
    }

    @Test("Tap trigger Off: clicking the segment outside its text turns it off")
    func tapTriggerOffPaddingClick() {
        let originalKey = SettingsStorage.shared.pushToTalkKey
        let originalToggle = SettingsStorage.shared.pushToTalkToggleEnabled
        defer {
            SettingsStorage.shared.pushToTalkKey = originalKey
            SettingsStorage.shared.pushToTalkToggleEnabled = originalToggle
        }
        SettingsStorage.shared.pushToTalkKey = .rightShift
        SettingsStorage.shared.pushToTalkToggleEnabled = true

        Harness().click(Point.dictationOffPadding)

        #expect(SettingsStorage.shared.pushToTalkToggleEnabled == false)
    }

    // MARK: - Shortcut recorder

    @Test("Clicking the shortcut field's 'edit' label starts recording")
    func clickingEditStartsRecording() throws {
        let harness = Harness()
        try #require(harness.window.isKeyWindow, "test window must be key, or the first click only activates it")

        harness.click(Point.dictationEditLabel)

        #expect(harness.isShortcutRecorderFocused, "first responder: \(String(describing: harness.window.firstResponder))")
    }

    @Test("Clicking the middle of the recorder control itself starts recording (control)")
    func clickingRecorderCenterStartsRecording() throws {
        let harness = Harness()
        try #require(harness.window.isKeyWindow, "test window must be key, or the first click only activates it")

        harness.click(NSPoint(x: 364, y: 124))

        #expect(harness.isShortcutRecorderFocused, "first responder: \(String(describing: harness.window.firstResponder))")
    }

    @Test("Clicking the body of the shortcut field starts recording")
    func clickingFieldBodyStartsRecording() throws {
        let harness = Harness()
        try #require(harness.window.isKeyWindow, "test window must be key, or the first click only activates it")

        harness.click(Point.dictationFieldBody)

        #expect(harness.isShortcutRecorderFocused, "first responder: \(String(describing: harness.window.firstResponder))")
    }
}
