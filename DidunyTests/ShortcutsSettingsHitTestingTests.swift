import AppKit
@testable import Diduny
import SwiftUI
import Testing

/// Reproduces the Shortcuts tab click bugs by sending real mouse events to the
/// hosted view. Each bug test has a positive control that clicks the visible
/// glyph and must pass, which proves the coordinates below hit the right
/// control; the failing assertion is the click on the control's own padding.
///
/// Coordinates are top-left based, measured from a snapshot of ShortcutsSettingsView in a
/// 760×1100 window (tall enough that nothing scrolls): PageScaffold, quiet rows of 57pt in
/// "Action hotkeys", "Recording keys" rows of ~69pt. Update them if that layout changes.
/// Drives a real key window, so it runs only on CI (`DIDUNY_UI_TESTS=1`), never on a dev Mac.
@MainActor
// Serialized: every test makes its own window key and spins the run loop, so concurrent
// tests would interleave inside those spins and steal key window, first responder and clicks.
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["DIDUNY_UI_TESTS"] == "1", "UI tests run on CI only")
)
struct ShortcutsSettingsHitTestingTests {
    nonisolated private static let windowSize = NSSize(width: 760, height: 1100)

    private enum Point {
        // Dictation row of the "Action hotkeys" card (row centre y = 119).
        static let dictation2xGlyph = NSPoint(x: 663, y: 119)
        static let dictation2xPadding = NSPoint(x: 650, y: 119) // inside the 2x segment, left of its text
        static let dictationEditLabel = NSPoint(x: 572, y: 119)
        static let dictationFieldBody = NSPoint(x: 530, y: 119) // between keycaps and "edit"
        static let dictationRecorderCenter = NSPoint(x: 500, y: 119)

        // Dictation row of the "Recording keys" card (row centre y = 479).
        static let dictationOffGlyph = NSPoint(x: 433, y: 479)
        static let dictationOffPadding = NSPoint(x: 415, y: 479)
    }

    /// A non-activating panel takes clicks without the test host being the active app. macOS
    /// may refuse to activate the host (cooperative activation, another app in front); in a
    /// normal window SwiftUI then spends the click on activation and the control never sees it,
    /// which made these tests flaky. The tests model a settings window the person is already in.
    private final class TestPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    @MainActor
    private final class Harness {
        let window: NSWindow

        init() {
            // Drop events left from a previous test so the next dequeue is ours.
            while NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) != nil {}
            let hostingView = NSHostingView(rootView: ShortcutsSettingsView())
            window = TestPanel(
                contentRect: NSRect(origin: .zero, size: ShortcutsSettingsHitTestingTests.windowSize),
                styleMask: [.titled, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = hostingView
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            // The page lays out in several passes: SwiftUI sizes each hosted recorder field, and the
            // field then sizes its `RecorderCocoa`, which until that pass is still 130×24 at the
            // field's left edge. A click before it lands is cancelled by the recorder on mouse-up.
            // Key status also arrives late, and right after the previous test's window closes AppKit
            // can leave the new panel not key, so it is asked again until it is. Locally this takes
            // ~200 ms; the old fixed 0.15 s spin let a busy CI runner click before either was done.
            let settled = waitUntil {
                if !window.isKeyWindow { window.makeKey() }
                return isSettled
            }
            if !settled {
                Issue.record("window not ready: key=\(window.isKeyWindow), visible=\(window.isVisible)")
            }
        }

        deinit {
            // A live recorder's local event monitor reacts to clicks in any window; close ours.
            MainActor.assumeIsolated {
                window.makeFirstResponder(nil)
                window.orderOut(nil)
                window.close()
            }
        }

        /// Spins the main run loop until `condition` holds or `timeout` passes.
        @discardableResult
        func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                guard Date() < deadline else { return false }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            return true
        }

        /// Key and on screen, no view waiting for layout, and every shortcut recorder fills its field.
        private var isSettled: Bool {
            guard window.isKeyWindow, window.isVisible, let content = window.contentView else { return false }
            let views = Self.allViews(in: content)
            let recorders = views.compactMap { $0 as? NSSearchField }
            return !views.contains(where: \.needsLayout)
                && !recorders.isEmpty
                && recorders.allSatisfy { $0.frame == $0.superview?.bounds }
        }

        private static func allViews(in view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(allViews)
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
                // Deliver exactly the event we posted; nothing else may be dequeued here.
                let mask: NSEvent.EventTypeMask = type == .leftMouseDown ? .leftMouseDown : .leftMouseUp
                guard let queued = NSApp.nextEvent(matching: mask, until: Date().addingTimeInterval(1),
                                                   inMode: .default, dequeue: true),
                    queued.windowNumber == window.windowNumber
                else {
                    Issue.record("posted \(type) was not delivered")
                    return
                }
                NSApp.sendEvent(queued)
            }
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

        let harness = Harness()
        harness.click(Point.dictation2xGlyph)

        harness.waitUntil { SettingsStorage.shared.recordingHotkeyPressCount == 2 }
        #expect(SettingsStorage.shared.recordingHotkeyPressCount == 2)
    }

    @Test("Trigger-after 2x: clicking the segment outside its text selects it")
    func triggerAfterPaddingClick() {
        let original = SettingsStorage.shared.recordingHotkeyPressCount
        defer { SettingsStorage.shared.recordingHotkeyPressCount = original }
        SettingsStorage.shared.recordingHotkeyPressCount = 1

        let harness = Harness()
        harness.click(Point.dictation2xPadding)

        harness.waitUntil { SettingsStorage.shared.recordingHotkeyPressCount == 2 }
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

        let harness = Harness()
        harness.click(Point.dictationOffGlyph)

        harness.waitUntil { SettingsStorage.shared.pushToTalkToggleEnabled == false }
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

        let harness = Harness()
        harness.click(Point.dictationOffPadding)

        harness.waitUntil { SettingsStorage.shared.pushToTalkToggleEnabled == false }
        #expect(SettingsStorage.shared.pushToTalkToggleEnabled == false)
    }

    // MARK: - Shortcut recorder

    @Test("Clicking the shortcut field's 'edit' label starts recording")
    func clickingEditStartsRecording() throws {
        let harness = Harness()
        try #require(harness.window.isKeyWindow, "test window must be key, or the first click only activates it")

        harness.click(Point.dictationEditLabel)

        harness.waitUntil { harness.isShortcutRecorderFocused }
        #expect(harness.isShortcutRecorderFocused, "first responder: \(String(describing: harness.window.firstResponder))")
    }

    @Test("Clicking the middle of the recorder control itself starts recording (control)")
    func clickingRecorderCenterStartsRecording() throws {
        let harness = Harness()
        try #require(harness.window.isKeyWindow, "test window must be key, or the first click only activates it")

        harness.click(Point.dictationRecorderCenter)

        harness.waitUntil { harness.isShortcutRecorderFocused }
        #expect(harness.isShortcutRecorderFocused, "first responder: \(String(describing: harness.window.firstResponder))")
    }

    @Test("Clicking the body of the shortcut field starts recording")
    func clickingFieldBodyStartsRecording() throws {
        let harness = Harness()
        try #require(harness.window.isKeyWindow, "test window must be key, or the first click only activates it")

        harness.click(Point.dictationFieldBody)

        harness.waitUntil { harness.isShortcutRecorderFocused }
        #expect(harness.isShortcutRecorderFocused, "first responder: \(String(describing: harness.window.firstResponder))")
    }
}
