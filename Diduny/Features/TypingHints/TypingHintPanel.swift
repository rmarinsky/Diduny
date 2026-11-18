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

    /// The logo hints: the pill right of the text end, centered on its line (the in-place translation's
    /// rule), else Papuga's place at the pointer. The other hints: at the pointer.
    static func frame(for content: TypingHintContent, near point: NSPoint, textEnd: CGRect?, size: NSSize, visibleFrame: NSRect) -> NSRect {
        let margin = content.logoMargin
        let pill = NSSize(width: size.width - 2 * margin, height: size.height - 2 * margin)
        let frame: NSRect
        if content.placesAtText, let textEnd {
            let screens = NSScreen.screens.map { InplaceTranslationAnchor.ScreenInfo(frame: $0.frame, visibleFrame: $0.visibleFrame) }
            frame = InplaceTranslationAnchor.panelFrame(size: pill, selectionEnd: textEnd, mouse: point, screens: screens)
        } else {
            frame = NSRect(origin: origin(near: point, size: pill, gap: content.gap, visibleFrame: visibleFrame), size: pill)
        }
        return frame.insetBy(dx: -margin, dy: -margin)
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
        case let .undo(onClick): onClick == nil ? String(localized: "Oops, fixed") : String(localized: "Undo fix")
        case .swapped: String(localized: "Swapped")
        case let .recovery(hint, _): hint.title
        case .chip: String(localized: "Apply the deferred fix")
        case let .proposal(hint, _, _, _): hint.title
        }
    }

    var identifier: String {
        switch self {
        case .undo: "typingHint.undo"
        case .swapped: "typingHint.swapped"
        case .recovery: "typingHint.recovery"
        case .chip: "typingHint.chip"
        case .proposal: "typingHint.proposal"
        }
    }

    var takesClicks: Bool {
        switch self {
        case .undo(onClick: nil), .swapped: false
        default: true
        }
    }

    /// The logo hints draw room around their pill (`LogoPill.margin`); the pill, not the panel, is placed.
    var logoMargin: CGFloat {
        switch self {
        case .undo, .swapped: LogoPill.margin
        default: 0
        }
    }

    /// The logo hints sit right of the changed text, like the in-place translation; the rest at the pointer.
    var placesAtText: Bool {
        logoMargin > 0
    }

    var gap: CGFloat {
        if case .proposal = self { return 8 }
        return 6
    }

    var widthRange: ClosedRange<CGFloat> {
        switch self {
        case .undo, .swapped, .recovery: 0 ... 320 + 2 * LogoPill.margin
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
    /// The end of the text before the caret, off the main thread; nil when the app gives no geometry.
    private let textEnd: @Sendable () -> CGRect?
    /// Each show and hide takes a new number, so a late caret lookup or a finished fade-out drops itself.
    private var generation = 0
    private var isHiding = false

    init(
        motion: @escaping () -> MotionPreference = { .current },
        textEnd: @escaping @Sendable () -> CGRect? = { AXCaretGeometry().caret()?.rect }
    ) {
        self.motion = motion
        self.textEnd = textEnd
    }

    var isVisible: Bool {
        panel?.isVisible == true && !isHiding
    }

    var containsMouse: Bool {
        panel.map { NSPointInRect(NSEvent.mouseLocation, $0.frame) } ?? false
    }

    func show(_ content: TypingHintContent, near point: NSPoint) {
        generation += 1
        guard content.placesAtText else {
            present(content, near: point, textEnd: nil)
            return
        }
        let current = generation
        let lookup = textEnd
        Task { @MainActor [weak self] in
            let rect = await Task.detached(priority: .userInitiated) { lookup() }.value
            guard let self, generation == current else { return }
            present(content, near: point, textEnd: rect)
        }
    }

    private func present(_ content: TypingHintContent, near point: NSPoint, textEnd: CGRect?) {
        isHiding = false
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

        panel.setFrame(TypingHintPlacement.frame(for: content, near: point, textEnd: textEnd, size: size, visibleFrame: visibleFrame), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            // The logo hints pop in themselves; the window only has to be there.
            context.duration = content.logoMargin > 0 ? 0.01
                : preference.reduceMotion ? MotionPolicy.reducedFadeDuration : DS.Motion.m6PopupOpen.duration
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

    /// Fades out in 0.15 s; `isVisible` is false at once, so the engine never treats a fading hint as live.
    func hide() {
        generation += 1
        guard let panel, panel.isVisible, !isHiding else { return }
        isHiding = true
        let current = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeOut
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.isHiding = false
                panel.orderOut(nil)
            }
        }
    }

    static let fadeOut: TimeInterval = 0.15

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
