import AppKit
import SwiftUI

enum LogoBadgePhase: Equatable {
    /// A 30% arc spins on the rim (1 s a turn) while the logo breathes.
    case waiting
    /// The arc stops where it is and grows into a closed ring.
    case done
    /// Red ring.
    case error
}

/// The app icon on its material disc: the in-place translation badge, the caret logo after
/// Stop and the outcome header logo (docs/design/stop-animation, "Logo badge").
struct LogoBadge: View {
    var phase: LogoBadgePhase
    var discSize: CGFloat = PasteMarkPlan.disc
    var isVisible = true
    /// Each change plays one M8 pulse (none under Reduce Motion).
    var pulseTrigger = 0
    var pulsesOnAppear = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var frozenAngle: Double = 0
    @State private var ringTrim: CGFloat = 1
    @State private var pulses = 0

    private static let turn: Double = 1.0
    private static let arc: CGFloat = 0.3

    private var unit: CGFloat {
        discSize / 28
    }

    private var ringColor: Color {
        if phase == .error { return .red }
        return colorScheme == .dark ? Color("BrandTintSoft").opacity(0.9) : Color("BrandAccentDeep")
    }

    var body: some View {
        ZStack {
            Circle().fill(.regularMaterial)
            Circle().stroke(Color("BrandTintBorder"), lineWidth: 0.5)
            logo
            rim
        }
        .frame(width: discSize, height: discSize)
        .keyframeAnimator(initialValue: 1.0, trigger: pulses) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(DS.Motion.pulseScale, duration: DS.Motion.m8SuccessPulse.duration / 2)
                CubicKeyframe(1.0, duration: DS.Motion.m8SuccessPulse.duration / 2)
            }
        }
        .scaleEffect(reduceMotion || isVisible ? 1 : 0.85)
        .opacity(isVisible ? 1 : 0)
        .animation(visibilityAnimation, value: isVisible)
        .accessibilityHidden(true)
        .onAppear {
            ringTrim = phase == .waiting ? Self.arc : 1
            if pulsesOnAppear { pulse() }
        }
        .onChange(of: phase) { _, new in close(into: new) }
        .onChange(of: pulseTrigger) { _, _ in pulse() }
    }

    /// Waiting: the logo breathes 1 to 1.08 (2.4 s cycle, eased). Otherwise it stays still.
    @ViewBuilder
    private var logo: some View {
        if phase == .waiting, !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                logoImage.scaleEffect(1 + 0.08 * (1 - cos(t * 2 * .pi / 2.4)) / 2)
            }
        } else {
            logoImage
        }
    }

    private var logoImage: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 18 * unit, height: 18 * unit)
    }

    @ViewBuilder
    private var rim: some View {
        switch phase {
        case .waiting:
            if !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
                    ring(trim: Self.arc, angle: Self.angle(at: timeline.date))
                }
            }
        case .done, .error:
            ring(trim: ringTrim, angle: frozenAngle)
                .transition(.opacity.animation(reduceMotion ? DS.Motion.reduced : nil))
        }
    }

    private func ring(trim: CGFloat, angle: Double) -> some View {
        Circle()
            .trim(from: 0, to: trim)
            .stroke(ringColor, style: StrokeStyle(lineWidth: 1.5 * unit, lineCap: .round))
            .rotationEffect(.degrees(angle - 90))
    }

    private static func angle(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: turn) / turn * 360
    }

    private func close(into new: LogoBadgePhase) {
        guard new != .waiting else {
            ringTrim = Self.arc
            return
        }
        guard !reduceMotion, new == .done else {
            ringTrim = 1
            return
        }
        frozenAngle = Self.angle(at: Date())
        ringTrim = Self.arc
        withAnimation(DS.Motion.easeOut(PasteMarkPlan.timeline(reduceMotion: false).ringClose)) { ringTrim = 1 }
    }

    private func pulse() {
        if !reduceMotion { pulses += 1 }
    }

    private var visibilityAnimation: Animation {
        let timeline = PasteMarkPlan.timeline(reduceMotion: reduceMotion)
        if reduceMotion { return .linear(duration: isVisible ? timeline.appear : timeline.fade) }
        // Springy pop-in; the exit keeps the timeline's fade.
        return isVisible ? .spring(response: 0.28, dampingFraction: 0.72) : DS.Motion.easeOut(timeline.fade)
    }
}
