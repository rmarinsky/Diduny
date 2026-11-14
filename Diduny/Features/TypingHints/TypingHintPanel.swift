import AppKit
import PapugaKit
import SwiftUI

/// Where a hint goes: right of and below the point, kept on the visible screen. Papuga's rule.
enum TypingHintPlacement {
    static let screenMargin: CGFloat = 8
    static let offsetX: CGFloat = 14

    /// - Parameter gap: space between the point and the hint's top edge (Papuga: 6, proposal 8).
    static func origin(near point: NSPoint, size: NSSize, gap: CGFloat, visibleFrame: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(point.x + offsetX, visibleFrame.minX + screenMargin), visibleFrame.maxX - size.width - screenMargin),
            y: min(max(point.y - size.height - gap, visibleFrame.minY + screenMargin), visibleFrame.maxY - size.height - screenMargin)
        )
    }

    /// The screen under the point, else the main one.
    static func visibleFrame(containing point: NSPoint) -> NSRect {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
    }
}

extension TypingHintContent {
    /// The panel's accessibility label and title.
    var title: String {
        switch self {
        case let .undo(onClick): onClick == nil ? String(localized: "Fixed") : String(localized: "Undo fix")
        case let .recovery(hint, _): hint.title
        case .chip: String(localized: "Apply the deferred fix")
        case let .proposal(hint, _, _, _): hint.title
        }
    }

    var identifier: String {
        switch self {
        case .undo: "typingHint.undo"
        case .recovery: "typingHint.recovery"
        case .chip: "typingHint.chip"
        case .proposal: "typingHint.proposal"
        }
    }

    var takesClicks: Bool {
        if case .undo(onClick: nil) = self { return false }
        return true
    }

    var gap: CGFloat {
        if case .proposal = self { return 8 }
        return 6
    }

    var widthRange: ClosedRange<CGFloat> {
        switch self {
        case .undo, .recovery: 0 ... 320
        case .chip: 170 ... 360
        case .proposal: 260 ... 560
        }
    }
}

/// A borderless panel that never takes focus, like the in-place translation toast.
@MainActor
final class TypingHintPanel: TypingHintSurface {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private var panel: Panel?
    private let motion: () -> MotionPreference

    init(motion: @escaping () -> MotionPreference = { .current }) {
        self.motion = motion
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    var containsMouse: Bool {
        panel.map { NSPointInRect(NSEvent.mouseLocation, $0.frame) } ?? false
    }

    func show(_ content: TypingHintContent, near point: NSPoint) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let preference = motion()
        let visibleFrame = TypingHintPlacement.visibleFrame(containing: point)

        let view = TypingHintView(content: content, motion: preference)
        // The natural size, then clamped: a long word truncates instead of widening the panel.
        let fitting = NSHostingView(rootView: view.fixedSize()).fittingSize
        let hosting = NSHostingView(rootView: view)
        // The panel decides the size. A hosting view that resizes its window from inside a running
        // animation re-enters AppKit's layout pass (Papuga crashed there with the chip's drain bar).
        hosting.sizingOptions = []
        let widths = content.widthRange
        let maxWidth = max(widths.lowerBound, min(widths.upperBound, visibleFrame.width - 2 * TypingHintPlacement.screenMargin))
        let size = NSSize(width: min(max(ceil(fitting.width), widths.lowerBound), maxWidth), height: ceil(fitting.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

        panel.contentView = hosting
        panel.ignoresMouseEvents = !content.takesClicks
        panel.title = content.title
        panel.identifier = NSUserInterfaceItemIdentifier(content.identifier)
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.window)
        panel.setAccessibilityLabel(content.title)
        panel.setAccessibilityIdentifier(content.identifier)

        let origin = TypingHintPlacement.origin(near: point, size: size, gap: content.gap, visibleFrame: visibleFrame)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = preference.reduceMotion ? MotionPolicy.reducedFadeDuration : DS.Motion.m6PopupOpen.duration
            panel.animator().alphaValue = 1
        } completionHandler: {
            MainActor.assumeIsolated { panel.invalidateShadow() }
        }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: content.announcement, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> Panel {
        let panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Hiding Diduny must not take a proposal off screen while its keys are still captured.
        panel.canHide = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }
}
