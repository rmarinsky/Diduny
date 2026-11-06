import AppKit
import QuartzCore
import SwiftUI

final class EdgeCommandPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// The panel is a non-activating panel of a usually-inactive app (the user is
/// dictating into another app). Without accepting first mouse, the initial
/// click is consumed by window-key handling and never reaches the SwiftUI
/// drag gesture or buttons — dragging during recording required a second
/// attempt and Stop/Copy needed a double click.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @MainActor @preconcurrency dynamic required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class EdgeCommandPanelContentView: NSView {
    private let tabHostingView: NSHostingView<EdgeCommandTabView>
    private let expandedHostingView: NSHostingView<EdgeCommandExpandedView>
    private let onHoverChange: (Bool) -> Void
    private var hoverTrackingArea: NSTrackingArea?

    init(
        tabView: EdgeCommandTabView,
        expandedView: EdgeCommandExpandedView,
        onHoverChange: @escaping (Bool) -> Void
    ) {
        tabHostingView = FirstMouseHostingView(rootView: tabView)
        expandedHostingView = FirstMouseHostingView(rootView: expandedView)
        self.onHoverChange = onHoverChange
        super.init(frame: .zero)

        tabHostingView.sizingOptions = []
        expandedHostingView.sizingOptions = []
        for hostingView: NSView in [tabHostingView, expandedHostingView] {
            hostingView.autoresizingMask = [.width, .height]
            addSubview(hostingView)
        }
        setExpanded(false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        tabHostingView.frame = bounds
        expandedHostingView.frame = bounds
    }

    func applyCornerMask(_ radius: CGFloat) {
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = radius > 0
    }

    /// Identity of the latest transition; a stale cross-fade completion must not hide the current view.
    private var transitionID = 0

    func setExpanded(_ expanded: Bool, animated: Bool = false) {
        transitionID += 1
        let currentTransition = transitionID
        let incoming: NSView = expanded ? expandedHostingView : tabHostingView
        let outgoing: NSView = expanded ? tabHostingView : expandedHostingView
        guard animated, incoming.isHidden,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            incoming.alphaValue = 1
            outgoing.alphaValue = 1
            incoming.isHidden = false
            outgoing.isHidden = true
            return
        }
        // Tab ↔ panel morph: the window frame grows from the tab (see position()),
        // while the two surfaces cross-fade so the tab appears to become the panel.
        incoming.alphaValue = 0
        incoming.isHidden = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            incoming.animator().alphaValue = 1
            outgoing.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, transitionID == currentTransition else { return }
            outgoing.isHidden = true
            outgoing.alphaValue = 1
        })
    }

    /// WP-40: the expanded content's fitting height at the panel width (design-spec 3.3); nil when it reports none.
    func expandedFittingHeight() -> CGFloat? {
        // Measured off-screen at the fixed width, so the live window (mid-morph or mid-resize) is untouched.
        let probe = NSHostingView(
            rootView: expandedHostingView.rootView.frame(width: EdgeCommandPanelPlacement.panelWidth)
        )
        let height = probe.fittingSize.height
        return height.isFinite && height > 0 ? ceil(height) : nil
    }

    func updateTabView(_ tabView: EdgeCommandTabView) {
        tabHostingView.rootView = tabView
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange(false)
    }
}
