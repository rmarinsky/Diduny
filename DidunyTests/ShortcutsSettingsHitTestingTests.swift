import AppKit
import KeyboardShortcuts
@testable import Diduny
import SwiftUI
import Testing

/// Clicks on the Shortcuts page (WP-55 layout, design-spec 7.15) sent as real mouse events to the
/// hosted view. Controls are found by their test-plan 2.1 accessibility identifiers, so the tests
/// follow the layout instead of fixed coordinates. The page reads a fake store, never `.shared`.
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

        let store: FakeShortcutsSettingsStore

        init(store: FakeShortcutsSettingsStore? = nil) {
            let store = store ?? FakeShortcutsSettingsStore()
            self.store = store
            // Drop events left from a previous test so the next dequeue is ours.
            while NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) != nil {}
            let hostingView = NSHostingView(rootView: ShortcutsSettingsView(store: store))
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

        /// Window-base frame of the accessibility element with this identifier.
        /// SwiftUI's elements below the hosting view are `AccessibilityNode`s, which answer the
        /// NSAccessibility getters but do not conform to `NSAccessibilityProtocol`, so they are read
        /// by key. The tree is built lazily (the first query returns no children), so it is polled.
        func frame(of identifier: String) -> NSRect? {
            func value(_ key: String, of object: NSObject) -> Any? {
                object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
            }
            func find(_ element: Any) -> NSObject? {
                guard let element = element as? NSObject else { return nil }
                if value("accessibilityIdentifier", of: element) as? String == identifier { return element }
                for child in value("accessibilityChildren", of: element) as? [Any] ?? [] {
                    if let hit = find(child) { return hit }
                }
                return nil
            }
            var hit: NSObject?
            waitUntil { hit = window.contentView.flatMap(find); return hit != nil }
            if let hit, let screenFrame = (value("accessibilityFrame", of: hit) as? NSValue)?.rectValue {
                return window.convertFromScreen(screenFrame)
            }
            return appKitFrame(of: identifier)
        }

        /// Fallback when the runner's accessibility tree has no SwiftUI ids (CI, macOS 26): the
        /// segmented control and the switch are AppKit views carrying the id, and a keys field is the
        /// `RecorderCocoa` of its row's shortcut, laid under the field.
        private func appKitFrame(of identifier: String) -> NSRect? {
            guard let content = window.contentView else { return nil }
            let views = Self.allViews(in: content)
            if let view = views.first(where: { $0.accessibilityIdentifier() == identifier }) {
                return view.convert(view.bounds, to: nil)
            }
            let row = ShortcutRow.allCases.first {
                [$0.keysIdentifier, $0.pressCountIdentifier, $0.enabledIdentifier].contains(identifier)
            }
            guard let name = row?.shortcutName,
                  let recorder = views.compactMap({ $0 as? KeyboardShortcuts.RecorderCocoa }).first(where: { $0.shortcutName == name })
            else { return nil }
            let keys = recorder.convert(recorder.bounds, to: nil)
            if identifier == row?.keysIdentifier { return keys }
            // The row's count (segmented) and switch: the AppKit control of that kind on the keys' line.
            let isCount = identifier == row?.pressCountIdentifier
            let control = views.first { view in
                (isCount ? view is NSSegmentedControl : view is NSSwitch)
                    && abs(view.convert(view.bounds, to: nil).midY - keys.midY) < keys.height
            }
            return control.map { $0.convert($0.bounds, to: nil) }
        }

        /// Clicks at a fraction of the identified control's width, centred vertically.
        func click(_ identifier: String, atFraction fraction: CGFloat = 0.5) {
            guard let frame = frame(of: identifier) else {
                Issue.record("no element \(identifier)")
                return
            }
            click(window: NSPoint(x: frame.minX + frame.width * fraction, y: frame.midY))
        }

        func click(window point: NSPoint) {
            // Both events are queued before the down is delivered: a tracking control (the segmented
            // count) runs its own loop on mouse-down and waits for the up, so posting the up afterwards
            // deadlocks. Posted through the event queue, not window.sendEvent, so local event monitors
            // (the recorder cancels on mouse-up outside itself) see them.
            let events = [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap { type in
                NSEvent.mouseEvent(
                    with: type,
                    location: point,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            }
            events.forEach { NSApp.postEvent($0, atStart: false) }
            // Deliver exactly the events we posted; nothing else may be dequeued here.
            guard let down = NSApp.nextEvent(matching: .leftMouseDown, until: Date().addingTimeInterval(1),
                                             inMode: .default, dequeue: true),
                down.windowNumber == window.windowNumber
            else {
                Issue.record("posted mouse-down was not delivered")
                return
            }
            NSApp.sendEvent(down)
            // A tracking control has already taken the up; otherwise deliver it now.
            if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(up)
            }
        }

        var isShortcutRecorderFocused: Bool {
            let responder = window.firstResponder
            return responder is NSSearchField || (responder as? NSText)?.delegate is NSSearchField
        }
    }

    // MARK: - Keys field

    @Test("Clicking the keys field starts recording")
    func clickingFieldStartsRecording() throws {
        let harness = Harness()
        try #require(harness.window.isKeyWindow, "test window must be key, or the first click only activates it")

        harness.click(ShortcutRow.addMeetingChapter.keysIdentifier)

        harness.waitUntil { harness.isShortcutRecorderFocused }
        #expect(harness.isShortcutRecorderFocused, "first responder: \(String(describing: harness.window.firstResponder))")
    }

    @Test("Clicking near the edge of the keys field starts recording")
    func clickingFieldEdgeStartsRecording() throws {
        let harness = Harness()
        try #require(harness.window.isKeyWindow, "test window must be key, or the first click only activates it")

        harness.click(ShortcutRow.addMeetingChapter.keysIdentifier, atFraction: 0.9)

        harness.waitUntil { harness.isShortcutRecorderFocused }
        #expect(harness.isShortcutRecorderFocused, "first responder: \(String(describing: harness.window.firstResponder))")
    }

    // MARK: - Press count

    @Test("Each count segment selects its count", arguments: [(1, CGFloat(1) / 6), (2, 0.5), (3, CGFloat(5) / 6)])
    func countSegmentsSelect(count: Int, fraction: CGFloat) {
        let store = FakeShortcutsSettingsStore()
        store.counts[.addMeetingChapter] = count == 1 ? 2 : 1
        let harness = Harness(store: store)

        harness.click(ShortcutRow.addMeetingChapter.pressCountIdentifier, atFraction: fraction)

        harness.waitUntil { store.counts[.addMeetingChapter] == count }
        #expect(store.counts[.addMeetingChapter] == count)
    }

    // MARK: - Switch

    @Test("The switch turns the shortcut off; then the field and the count take no clicks")
    func switchDisablesFieldAndCount() throws {
        let store = FakeShortcutsSettingsStore()
        store.counts[.addMeetingChapter] = 1
        let harness = Harness(store: store)
        try #require(harness.window.isKeyWindow, "test window must be key, or the first click only activates it")

        harness.click(ShortcutRow.addMeetingChapter.enabledIdentifier)
        harness.waitUntil { store.enabled[.addMeetingChapter] == false }
        #expect(store.enabled[.addMeetingChapter] == false)

        harness.click(ShortcutRow.addMeetingChapter.pressCountIdentifier, atFraction: 0.5)
        harness.waitUntil(timeout: 0.5) { store.counts[.addMeetingChapter] == 2 }
        #expect(store.counts[.addMeetingChapter] == 1)

        harness.click(ShortcutRow.addMeetingChapter.keysIdentifier)
        harness.waitUntil(timeout: 0.5) { harness.isShortcutRecorderFocused }
        #expect(!harness.isShortcutRecorderFocused)
    }
}
