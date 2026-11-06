import AppKit
import QuartzCore

extension EdgeCommandPanelController {
    func position(
        _ panel: NSPanel,
        presentation: EdgeCommandPanelPresentation,
        on explicitVisibleFrame: NSRect? = nil,
        morphFromTab: Bool = false
    ) {
        // A live drag owns the frame; phase changes and toasts must not snap
        // the panel back to its dock mid-drag. onDragEnd re-docks and calls
        // position() again after clearing the drag offset.
        guard dragCursorOffset == nil else { return }
        let screen = dock == nil ? activeScreen() : panel.screen ?? activeScreen()
        let visibleFrame = explicitVisibleFrame
            ?? screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let resolvedDock = dock
            ?? EdgeCommandPanelDock(
                rawEdge: SettingsStorage.shared.edgePanelDockEdge,
                offset: SettingsStorage.shared.edgePanelDockOffset
            )
            ?? EdgeCommandPanelDock(edge: .right, offset: visibleFrame.midY)
        dock = resolvedDock
        model?.dockEdge = resolvedDock.edge
        let isExpanded = presentation != .collapsed
        model?.isExpanded = isExpanded
        panelContentView?.setExpanded(isExpanded, animated: morphFromTab || (panel.isVisible && panel.alphaValue > 0))
        // Backstop clip: the SwiftUI material's shape mask can be lost by the
        // window server; the layer clip keeps expanded corners rounded no
        // matter what. The collapsed tab keeps its own edge-flush shape.
        panelContentView?.applyCornerMask(
            isExpanded ? EdgeCommandPanelPlacement.expandedCornerRadius : 0
        )

        let frame = EdgeCommandPanelPlacement.frame(
            in: visibleFrame,
            dock: resolvedDock,
            presentation: presentation,
            contentHeight: fittingHeight(for: presentation, maximum: visibleFrame.height)
        )
        let motion = MotionPreference.current
        if morphFromTab {
            let tabFrame = EdgeCommandPanelPlacement.frame(
                in: visibleFrame,
                dock: resolvedDock,
                presentation: .collapsed
            )
            morphPanel(panel, from: tabFrame, to: frame)
        } else if panel.isVisible, isExpanded {
            // M2: height follows the content swap; the docked edge stays fixed (placement).
            let height = MotionPolicy.heightChange(preference: motion)
            guard height.animated else {
                panel.setFrame(frame, display: true)
                return
            }
            let points = height.controlPoints
            NSAnimationContext.runAnimationGroup { context in
                context.duration = height.duration
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: points[0], points[1], points[2], points[3]
                )
                panel.animator().setFrame(frame, display: true)
            }
        } else if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    /// Fresh appearance: the window grows out of the edge tab's frame while a
    /// static skeleton fills it; live content cascades in once the morph lands.
    private func morphPanel(_ panel: NSPanel, from tabFrame: NSRect, to frame: NSRect) {
        let store = DictationOverlayController.shared.store
        panel.ignoresMouseEvents = false
        guard !MotionPreference.current.reduceMotion else {
            store.contentRevealed = true
            panel.setFrame(frame, display: true)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
            return
        }
        store.contentRevealed = false
        panel.setFrame(tabFrame, display: true)
        panel.alphaValue = 1
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.34
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: {
            store.contentRevealed = true
        })
    }

    /// Live panels fill the window until WP-30/31/32 give them an intrinsic height, so they keep fixed heights.
    private func fittingHeight(for presentation: EdgeCommandPanelPresentation, maximum: CGFloat) -> CGFloat? {
        switch presentation {
        case .commands, .meetingSuggestion:
            panelContentView?.expandedFittingHeight().map { min($0, maximum) }
        case .collapsed, .live:
            nil
        }
    }

    func activeScreen() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
    }
}
