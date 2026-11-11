import SwiftUI

/// The app's only slider (docs: ~/.claude/skills/product-designer/references/sliders.md).
/// A thick track split by a tall thin handle with a gap on each side, and a stop dot at the end.
/// `.controlSize(.small)` gives the dense size for list rows.
struct GapSlider<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    @Binding var value: Value
    let range: ClosedRange<Value>
    var step: Value?
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var dragging = false

    init(value: Binding<Value>, in range: ClosedRange<Value>, step: Value? = nil,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value
        self.range = range
        self.step = step
        self.onEditingChanged = onEditingChanged
    }

    private var metrics: GapSliderGeometry.Metrics {
        controlSize == .small || controlSize == .mini ? .small : .regular
    }

    private var fraction: Double {
        let span = Double(range.upperBound - range.lowerBound)
        guard span > 0 else { return 0 }
        return min(1, max(0, Double(value - range.lowerBound) / span))
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = GapSliderGeometry.layout(width: proxy.size.width, fraction: fraction, metrics: metrics)
            let track = metrics.track
            ZStack(alignment: .leading) {
                if layout.activeWidth > 0 {
                    UnevenRoundedRectangle(topLeadingRadius: track / 2, bottomLeadingRadius: track / 2,
                                           bottomTrailingRadius: 2, topTrailingRadius: 2)
                        .fill(DS.Palette.accent)
                        .frame(width: layout.activeWidth, height: track)
                }
                if layout.inactiveWidth > 0 {
                    UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2,
                                           bottomTrailingRadius: track / 2, topTrailingRadius: track / 2)
                        .fill(DS.Palette.tintSoft)
                        .frame(width: layout.inactiveWidth, height: track)
                        .offset(x: layout.inactiveStart)
                    if layout.inactiveWidth > track {
                        Circle()
                            .fill(DS.Palette.accent)
                            .frame(width: 4, height: 4)
                            .offset(x: proxy.size.width - track / 2 - 2)
                    }
                }
                Capsule()
                    .fill(DS.Palette.accent)
                    .frame(width: dragging ? 2 : metrics.handleWidth, height: metrics.handle)
                    .frame(width: metrics.handleWidth)
                    .offset(x: layout.handleX)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: dragging)
            }
            .frame(width: proxy.size.width, height: metrics.handle)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !dragging {
                            dragging = true
                            onEditingChanged(true)
                        }
                        set(fraction: GapSliderGeometry.fraction(at: drag.location.x, width: proxy.size.width, metrics: metrics))
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: metrics.handle)
        .opacity(isEnabled ? 1 : 0.4)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 8).stroke(DS.Palette.accent, lineWidth: 2).padding(-3)
            }
        }
        .onKeyPress(.leftArrow) { nudge(-1); return .handled }
        .onKeyPress(.rightArrow) { nudge(1); return .handled }
        .accessibilityElement()
        .accessibilityAddTraits(.allowsDirectInteraction)
        .accessibilityValue(Text("\(Int((fraction * 100).rounded())) percent"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
    }

    /// One step, or 5% of the range when there is no step. Saves like a finished drag.
    private func nudge(_ direction: Double) {
        guard isEnabled else { return }
        let span = Double(range.upperBound - range.lowerBound)
        let delta = step.map(Double.init) ?? span * 0.05
        onEditingChanged(true)
        set(value: Double(value) + direction * delta)
        onEditingChanged(false)
    }

    private func set(fraction: Double) {
        set(value: Double(range.lowerBound) + fraction * Double(range.upperBound - range.lowerBound))
    }

    private func set(value raw: Double) {
        var next = raw
        if let step, step > 0 {
            let base = Double(range.lowerBound)
            next = base + (((next - base) / Double(step)).rounded() * Double(step))
        }
        value = Value(min(Double(range.upperBound), max(Double(range.lowerBound), next)))
    }
}

/// Where the parts go for a width and a value. Pure, so it is tested without drawing.
enum GapSliderGeometry {
    struct Metrics: Equatable {
        var track: CGFloat
        var handle: CGFloat
        var handleWidth: CGFloat
        var gap: CGFloat

        static let regular = Metrics(track: 16, handle: 44, handleWidth: 4, gap: 6)
        static let small = Metrics(track: 8, handle: 24, handleWidth: 4, gap: 4)
    }

    struct Layout: Equatable {
        var handleX: CGFloat
        var activeWidth: CGFloat
        var inactiveStart: CGFloat
        var inactiveWidth: CGFloat
    }

    /// The handle moves across `width - handleWidth`, so it stays inside at 0 and 1.
    static func layout(width: CGFloat, fraction: Double, metrics: Metrics) -> Layout {
        let travel = max(0, width - metrics.handleWidth)
        let handleX = travel * CGFloat(min(1, max(0, fraction)))
        let activeWidth = max(0, handleX - metrics.gap)
        let inactiveStart = handleX + metrics.handleWidth + metrics.gap
        return Layout(handleX: handleX, activeWidth: activeWidth,
                      inactiveStart: inactiveStart, inactiveWidth: max(0, width - inactiveStart))
    }

    static func fraction(at x: CGFloat, width: CGFloat, metrics: Metrics) -> Double {
        let travel = width - metrics.handleWidth
        guard travel > 0 else { return 0 }
        return Double(min(1, max(0, (x - metrics.handleWidth / 2) / travel)))
    }
}
