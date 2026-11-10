import SwiftUI

struct EdgeCommandTabView: View {
    let model: EdgeCommandPanelModel
    let onExpand: () -> Void
    let onDrag: () -> Void
    let onDragEnd: () -> Void

    var body: some View {
        let edge = model.dockEdge
        Button(action: onExpand) {
            ZStack {
                tabShape
                    .fill(.regularMaterial)
                if model.isLiveFeedbackMinimized {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .shadow(color: .red.opacity(0.45), radius: 4)
                        .accessibilityHidden(true)
                } else {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color("BrandAccentDeep"), Color.pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(
                            width: edge == .left || edge == .right ? 3 : 24,
                            height: edge == .left || edge == .right ? 24 : 3
                        )
                        .shadow(color: Color("BrandAccentDeep").opacity(0.45), radius: 5)
                }
            }
            .overlay(tabShape.stroke(Color("BrandTintBorder"), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Mouse only: it must never take the key view or show a ring.
        .focusable(false)
        .focusEffectDisabled()
        .gesture(dragGesture)
        .accessibilityIdentifier("commandPanel.tab")
        .accessibilityLabel(
            model.isLiveFeedbackMinimized
                ? "Show live recording panel"
                : "Open Diduny quick actions"
        )
        .help(
            model.isLiveFeedbackMinimized
                ? "Click to restore live transcript"
                : "Open Diduny quick actions"
        )
    }

    private var tabShape: UnevenRoundedRectangle {
        switch model.dockEdge {
        case .left:
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 10,
                topTrailingRadius: 10
            )
        case .right:
            UnevenRoundedRectangle(
                topLeadingRadius: 10,
                bottomLeadingRadius: 10,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
        case .top:
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 10,
                bottomTrailingRadius: 10,
                topTrailingRadius: 0
            )
        case .bottom:
            UnevenRoundedRectangle(
                topLeadingRadius: 10,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 10
            )
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { _ in onDrag() }
            .onEnded { _ in onDragEnd() }
    }
}
