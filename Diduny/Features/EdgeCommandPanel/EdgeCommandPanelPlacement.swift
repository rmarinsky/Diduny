import AppKit

enum EdgeCommandPanelDockEdge: String, Equatable {
    case left
    case right
    case top
    case bottom
}

struct EdgeCommandPanelDock: Equatable {
    let edge: EdgeCommandPanelDockEdge
    let offset: CGFloat

    init(edge: EdgeCommandPanelDockEdge, offset: CGFloat) {
        self.edge = edge
        self.offset = offset
    }

    /// Restores a dock persisted as raw values; nil when either value is
    /// missing or the edge name is unknown. A stale offset from a
    /// disconnected screen is safe — placement clamps it to the visible frame.
    init?(rawEdge: String?, offset: Double?) {
        guard let rawEdge, let edge = EdgeCommandPanelDockEdge(rawValue: rawEdge), let offset else {
            return nil
        }
        self.init(edge: edge, offset: CGFloat(offset))
    }
}

enum EdgeCommandPanelPlacement {
    static let expandedCornerRadius: CGFloat = 12
    static let liveControlHitTargetHeight: CGFloat = 38
    static let meetingSuggestionControlHitTargetHeight: CGFloat = 38
    /// Design-spec 3.3: one width in every expanded state.
    static let panelWidth: CGFloat = 300

    static func nearestDock(to proposedFrame: NSRect, in visibleFrame: NSRect) -> EdgeCommandPanelDock {
        let distances: [(EdgeCommandPanelDockEdge, CGFloat)] = [
            (.left, abs(proposedFrame.minX - visibleFrame.minX)),
            (.right, abs(visibleFrame.maxX - proposedFrame.maxX)),
            (.bottom, abs(proposedFrame.minY - visibleFrame.minY)),
            (.top, abs(visibleFrame.maxY - proposedFrame.maxY))
        ]
        let edge = distances.min(by: { $0.1 < $1.1 })?.0 ?? .right
        let offset = edge == .left || edge == .right ? proposedFrame.midY : proposedFrame.midX
        return EdgeCommandPanelDock(edge: edge, offset: offset)
    }

    static func frame(
        in visibleFrame: NSRect,
        dock: EdgeCommandPanelDock,
        presentation: EdgeCommandPanelPresentation,
        contentHeight: CGFloat? = nil
    ) -> NSRect {
        let size = size(for: presentation, edge: dock.edge, contentHeight: contentHeight)
        let origin = switch dock.edge {
        case .left:
            NSPoint(
                x: visibleFrame.minX,
                y: clampedOrigin(
                    dock.offset,
                    length: size.height,
                    minimum: visibleFrame.minY,
                    maximum: visibleFrame.maxY
                )
            )
        case .right:
            NSPoint(
                x: visibleFrame.maxX - size.width,
                y: clampedOrigin(
                    dock.offset,
                    length: size.height,
                    minimum: visibleFrame.minY,
                    maximum: visibleFrame.maxY
                )
            )
        case .top:
            NSPoint(
                x: clampedOrigin(
                    dock.offset,
                    length: size.width,
                    minimum: visibleFrame.minX,
                    maximum: visibleFrame.maxX
                ),
                y: visibleFrame.maxY - size.height
            )
        case .bottom:
            NSPoint(
                x: clampedOrigin(
                    dock.offset,
                    length: size.width,
                    minimum: visibleFrame.minX,
                    maximum: visibleFrame.maxX
                ),
                y: visibleFrame.minY
            )
        }

        return NSRect(origin: origin, size: size)
    }

    static func frame(in visibleFrame: NSRect, dock: EdgeCommandPanelDock, expanded: Bool) -> NSRect {
        frame(
            in: visibleFrame,
            dock: dock,
            presentation: expanded ? .commands(isCloud: true) : .collapsed
        )
    }

    static func size(
        for presentation: EdgeCommandPanelPresentation,
        edge: EdgeCommandPanelDockEdge,
        contentHeight: CGFloat? = nil
    ) -> NSSize {
        guard presentation != .collapsed else { return collapsedSize(for: edge) }
        return NSSize(width: panelWidth, height: contentHeight ?? fallbackHeight(for: presentation))
    }

    /// Used until the content reports its fitting height (live panels fill the window today).
    private static func fallbackHeight(for presentation: EdgeCommandPanelPresentation) -> CGFloat {
        switch presentation {
        case .collapsed: 0
        case let .commands(isCloud): isCloud ? 326 : 250
        // Design-spec 10.3: dictation 311.7, meeting 406, Translate meeting 362, meeting prompt 229.
        case let .live(mode):
            switch mode {
            case .meetingTranslation: 362
            case _ where mode.isMeeting: 406
            default: 312
            }
        case .meetingSuggestion: 229
        }
    }

    static let expandedSize = NSSize(width: panelWidth, height: 326)

    private static func collapsedSize(for edge: EdgeCommandPanelDockEdge) -> NSSize {
        switch edge {
        case .left, .right: NSSize(width: 14, height: 64)
        case .top, .bottom: NSSize(width: 64, height: 14)
        }
    }

    private static func clampedOrigin(_ offset: CGFloat, length: CGFloat, minimum: CGFloat,
                                      maximum: CGFloat) -> CGFloat
    {
        min(max(offset - length / 2, minimum), maximum - length)
    }

    /// Whether a pointer location counts as touching the given screen edge —
    /// the reveal gesture for an auto-hidden tab (same idea as the Dock).
    static func edgeHotZoneContains(
        _ location: NSPoint,
        screenFrame: NSRect,
        edge: EdgeCommandPanelDockEdge,
        threshold: CGFloat = 2
    ) -> Bool {
        guard NSMouseInRect(location, screenFrame, false) else { return false }
        return switch edge {
        case .left: location.x <= screenFrame.minX + threshold
        case .right: location.x >= screenFrame.maxX - threshold
        case .top: location.y >= screenFrame.maxY - threshold
        case .bottom: location.y <= screenFrame.minY + threshold
        }
    }
}

enum EdgeCommandPanelHoverPolicy {
    /// - Parameter openSurfaceFrame: an open picker menu or popup; the panel never collapses under it (ADR-0012 D7).
    static func shouldCollapse(
        pointer: NSPoint,
        panelFrame: NSRect,
        isDragging: Bool,
        openSurfaceFrame: NSRect? = nil
    ) -> Bool {
        openSurfaceFrame == nil && !isDragging && !panelFrame.contains(pointer)
    }

    /// A picker menu or popup just closed. No hover-exit event follows if the pointer already left the panel
    /// while the surface was open, so the expanded panel re-runs the collapse when the pointer is outside.
    static func shouldCollapseAfterSurfaceClose(
        pointer: NSPoint,
        panelFrame: NSRect,
        isExpanded: Bool,
        isDragging: Bool
    ) -> Bool {
        isExpanded && shouldCollapse(pointer: pointer, panelFrame: panelFrame, isDragging: isDragging)
    }
}

/// The collapsed edge tab auto-hides after a few idle seconds (it annoys
/// people when it sits on the screen edge permanently). It must never hide
/// under the pointer, mid-drag, or while the expanded live modal is open.
/// A minimized live-recording tab (red dot) does auto-hide, then reappears
/// on edge hover until the user clicks to restore the modal.
enum EdgeCommandPanelAutoHidePolicy {
    static let delay: TimeInterval = 3

    static func shouldHide(
        pointer: NSPoint,
        panelFrame: NSRect,
        isDragging: Bool,
        isExpanded: Bool,
        isShowingLiveFeedback: Bool,
        isLiveFeedbackMinimized: Bool = false,
        openSurfaceFrame: NSRect? = nil
    ) -> Bool {
        let liveModalExpanded = isShowingLiveFeedback && !isLiveFeedbackMinimized
        return openSurfaceFrame == nil
            && !isDragging
            && !isExpanded
            && !liveModalExpanded
            && !panelFrame.contains(pointer)
    }

    /// Auto-hide may run for idle tabs and for minimized live tabs.
    static func shouldSchedule(isLiveFeedbackMinimized _: Bool) -> Bool {
        true
    }
}

enum EdgeCommandPanelMinimizedLivePolicy {
    /// Hover may open the command menu only when live recording is not minimized.
    static func shouldAllowHoverExpand(isLiveFeedbackMinimized: Bool) -> Bool {
        !isLiveFeedbackMinimized
    }
}
