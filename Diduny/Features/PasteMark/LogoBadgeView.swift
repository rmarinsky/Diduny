import AppKit
import SwiftUI

enum LogoBadgePhase: Equatable {
    /// A 25% arc spins on the rim (900 ms a turn); the only waiting cue.
    case waiting
    /// The arc stops where it is and grows into a closed ring.
    case done
    /// Red ring.
    case error
}

/// The app icon on its material disc: the in-place translation badge, the caret logo after
/// Stop and the outcome header logo. Restored to the earlier in-place translation look
/// (before 87dfc77): spring pop-in, a breathing and tilting logo with three orbiting dots
/// while waiting, then a check and six sparks when the text lands, or a red ring on error.
struct LogoBadge: View {
    var phase: LogoBadgePhase
    var discSize: CGFloat = PasteMarkPlan.disc
    var isVisible = true
    /// Each change replays the landing burst (none under Reduce Motion).
    var pulseTrigger = 0
    var pulsesOnAppear = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var breathing = false
    @State private var burst = false

    private var unit: CGFloat {
        discSize / 28
    }

    private var ringColor: Color {
        if phase == .error { return .red }
        return colorScheme == .dark ? Color("BrandTintSoft").opacity(0.9) : Color("BrandAccentDeep")
    }

    private var isThinking: Bool {
        isVisible && phase == .waiting && !reduceMotion
    }

    var body: some View {
        ZStack {
            if phase == .done, !reduceMotion { burstView }
            ZStack {
                Circle().fill(.regularMaterial)
                Circle().stroke(Color("BrandTintBorder"), lineWidth: 0.5)
                // Paused (no frames) whenever the badge is not thinking.
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isThinking)) { timeline in
                    thinking(t: timeline.date.timeIntervalSinceReferenceDate)
                }
                ring
                if phase == .done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11 * unit, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, ringColor)
                        .offset(x: 9 * unit, y: 9 * unit)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.2).combined(with: .opacity))
                }
            }
            .frame(width: discSize, height: discSize)
        }
        .scaleEffect(scale)
        .opacity(isVisible ? 1 : 0)
        .animation(appearAnimation, value: isVisible)
        .animation(reduceMotion ? nil : .bouncy(duration: 0.3, extraBounce: 0.15), value: phase)
        .accessibilityHidden(true)
        .onAppear {
            if pulsesOnAppear { playBurst() }
            guard reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { breathing = true }
        }
        .onChange(of: phase) { _, new in if new == .done { playBurst() } }
        .onChange(of: pulseTrigger) { _, _ in playBurst() }
    }

    /// Logo + orbiting dots, driven by the timeline clock (60 fps cap).
    private func thinking(t: Double) -> some View {
        let animate = phase == .waiting && !reduceMotion
        let orbit = t.truncatingRemainder(dividingBy: 0.9) / 0.9 // one orbit per 0.9 s
        let pulse = animate ? (sin(t * 2 * .pi / 0.9) + 1) / 2 : 0
        return ZStack {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 18 * unit, height: 18 * unit)
                .scaleEffect(1 + 0.08 * pulse)
                .rotationEffect(.degrees(animate ? sin(t * 2 * .pi / 1.8) * 6 : 0))
                .opacity(reduceMotion && phase == .waiting ? (breathing ? 0.6 : 1.0) : 1)
            if animate {
                ForEach(0..<3, id: \.self) { i in
                    let angle = (orbit - Double(i) * 0.08) * 2 * .pi
                    let size = (3.5 - Double(i)) * unit
                    Circle()
                        .fill(ringColor)
                        .frame(width: size, height: size)
                        .opacity(1 - Double(i) * 0.3)
                        .offset(x: cos(angle) * 14 * unit, y: sin(angle) * 14 * unit)
                }
            }
        }
    }

    @ViewBuilder
    private var ring: some View {
        if reduceMotion {
            if phase == .error { Circle().stroke(ringColor, lineWidth: 1.5 * unit) }
        } else if phase != .waiting {
            Circle().stroke(ringColor, lineWidth: 1.5 * unit)
                .transition(.opacity)
        }
    }

    /// Six sparks that fly out and fade when the text lands.
    private var burstView: some View {
        ForEach(0..<6, id: \.self) { i in
            let angle = Double(i) / 6 * 2 * .pi
            let distance = (burst ? 20 : 12) * unit
            Circle()
                .fill(ringColor)
                .frame(width: 3 * unit, height: 3 * unit)
                .offset(x: cos(angle) * distance, y: sin(angle) * distance)
                .opacity(burst ? 0 : 1)
        }
    }

    private var scale: CGFloat {
        if reduceMotion { return 1 }
        if !isVisible { return 0.4 }
        return phase == .done ? 1.15 : 1
    }

    private var appearAnimation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.15) }
        return isVisible ? .bouncy(duration: 0.28, extraBounce: 0.2) : .easeIn(duration: 0.15)
    }

    private func playBurst() {
        guard !reduceMotion else { return }
        burst = false
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.35)) { burst = true }
        }
    }
}
