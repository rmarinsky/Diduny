@testable import Diduny
import AppKit
import Testing

struct InplaceTranslationGestureTests {
    private typealias Gesture = InplaceTranslationGesture
    private let both: Gesture.Modifiers = [.option, .command]

    /// Feeds a full tap (⌥ down, ⌘ down, ⌘ up, ⌥ up) starting at `t`; returns whether it completed the gesture.
    private func tap(_ g: inout Gesture, at t: TimeInterval, hold: TimeInterval = 0.08) -> Bool {
        _ = g.handle(.modifiersChanged([.option], at: t))
        _ = g.handle(.modifiersChanged(both, at: t + 0.01))
        _ = g.handle(.modifiersChanged([.command], at: t + hold))
        return g.handle(.modifiersChanged([], at: t + hold + 0.01))
    }

    @Test func twoQuickTapsTrigger() {
        var g = Gesture()
        #expect(tap(&g, at: 0) == false)
        #expect(tap(&g, at: 0.2) == true)
    }

    @Test func singleTapDoesNothing() {
        var g = Gesture()
        #expect(tap(&g, at: 0) == false)
        // A later lone tap after the timeout is again just a first tap.
        #expect(tap(&g, at: 2) == false)
    }

    @Test func secondTapAfterTimeoutStartsNewGesture() {
        var g = Gesture()
        #expect(tap(&g, at: 0) == false)
        #expect(tap(&g, at: 0.6) == false)
        #expect(tap(&g, at: 0.8) == true)
    }

    @Test func keyDownBetweenTapsCancels() {
        var g = Gesture()
        _ = tap(&g, at: 0)
        _ = g.handle(.keyDown)
        #expect(tap(&g, at: 0.2) == false)
    }

    @Test func keyDownDuringTapCancels() {
        // ⌥⌘T: both held, then a letter, then release.
        var g = Gesture()
        _ = g.handle(.modifiersChanged(both, at: 0))
        _ = g.handle(.keyDown)
        _ = g.handle(.modifiersChanged([], at: 0.1))
        #expect(tap(&g, at: 0.2) == false)
    }

    @Test func extraModifierCancels() {
        var g = Gesture()
        _ = tap(&g, at: 0)
        _ = g.handle(.modifiersChanged([.option, .command, .other], at: 0.2))
        _ = g.handle(.modifiersChanged([], at: 0.25))
        #expect(g.handle(.modifiersChanged(both, at: 0.3)) == false)
        #expect(g.handle(.modifiersChanged([], at: 0.35)) == false)
    }

    @Test func triggersOnlyOnceUntilNextDoubleTap() {
        var g = Gesture()
        _ = tap(&g, at: 0)
        #expect(tap(&g, at: 0.2) == true)
        #expect(tap(&g, at: 0.3) == false)
        #expect(tap(&g, at: 0.45) == true)
    }

    @Test func modifierMappingIgnoresCapsLockAndFlagsOtherModifiers() {
        let m = InplaceTranslationHotkeyMonitor.modifiers(from: [.option, .command, .capsLock])
        #expect(m == .optionCommand)
        let withShift = InplaceTranslationHotkeyMonitor.modifiers(from: [.option, .command, .shift])
        #expect(withShift.contains(.other))
    }
}

struct InplaceTranslationAnchorTests {
    private let screen = InplaceTranslationAnchor.ScreenInfo(
        frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 780)
    )
    private let size = CGSize(width: 28, height: 28)

    @Test func axRectConvertsToAppKitCoordinates() {
        let r = InplaceTranslationAnchor.appKitRect(
            fromAX: CGRect(x: 10, y: 100, width: 50, height: 20), primaryScreenHeight: 800
        )
        #expect(r == CGRect(x: 10, y: 680, width: 50, height: 20))
    }

    @Test func placesBadgeRightOfSelectionEnd() {
        let rect = CGRect(x: 200, y: 400, width: 40, height: 20)
        let f = InplaceTranslationAnchor.panelFrame(size: size, selectionEnd: rect, mouse: .zero, screens: [screen])
        #expect(f.minX == 246)
        #expect(f.midY == 410)
    }

    @Test func flipsLeftWhenRightEdgeWouldLeaveScreen() {
        let rect = CGRect(x: 950, y: 400, width: 40, height: 20)
        let f = InplaceTranslationAnchor.panelFrame(size: size, selectionEnd: rect, mouse: .zero, screens: [screen])
        #expect(f.maxX == 944)
    }

    @Test func fallsBackToMouseWhenNoRect() {
        let f = InplaceTranslationAnchor.panelFrame(
            size: size, selectionEnd: nil, mouse: CGPoint(x: 300, y: 300), screens: [screen]
        )
        #expect(f.origin == CGPoint(x: 312, y: 260))
    }

    @Test func fallsBackToMouseWhenRectIsOffScreen() {
        let f = InplaceTranslationAnchor.panelFrame(
            size: size, selectionEnd: CGRect(x: 5000, y: 5000, width: 10, height: 10),
            mouse: CGPoint(x: 300, y: 300), screens: [screen]
        )
        #expect(f.origin == CGPoint(x: 312, y: 260))
    }

    @Test func clampsInsideVisibleFrame() {
        let f = InplaceTranslationAnchor.panelFrame(
            size: size, selectionEnd: nil, mouse: CGPoint(x: 995, y: 2), screens: [screen]
        )
        #expect(f.minX == CGFloat(964))
        #expect(f.minY == 8)
    }
}

struct InplaceTranslationPolicyTests {
    @Test func quotaErrorMapsToQuotaToast() {
        #expect(InplaceTranslationService.toast(for: TranslationError.quotaExceeded) == .quotaFailure)
    }

    @Test func otherErrorsMapToNetworkToast() {
        #expect(InplaceTranslationService.toast(for: URLError(.notConnectedToInternet)) == .networkFailure)
        #expect(InplaceTranslationService.toast(for: InplaceTranslationService.FlowError.timeout) == .networkFailure)
    }

    @Test func timeoutFiresWhenOperationIsSlow() async {
        await #expect(throws: InplaceTranslationService.FlowError.self) {
            try await InplaceTranslationService.withTimeout(seconds: 0.05) {
                try await Task.sleep(for: .seconds(5))
                return 1
            }
        }
    }

    @Test func fastOperationReturnsResult() async throws {
        let v = try await InplaceTranslationService.withTimeout(seconds: 5) { 42 }
        #expect(v == 42)
    }

    @Test func optionAndCommandKeysConflict() {
        #expect(PushToTalkKey.rightOption.isOptionOrCommand)
        #expect(PushToTalkKey.leftCommand.isOptionOrCommand)
        #expect(!PushToTalkKey.rightShift.isOptionOrCommand)
        #expect(!PushToTalkKey.none.isOptionOrCommand)
    }
}
