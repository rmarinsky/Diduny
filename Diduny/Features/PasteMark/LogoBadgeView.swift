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

    private static let turn: Double = 0.9
    private static let arc: CGFloat = 0.25

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
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 18 * unit, height: 18 * unit)
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
        .scaleEffect(reduceMotion || isVisible ? 1 : 0.95, anchor: .leading)
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
        return DS.Motion.easeOut(isVisible ? timeline.appear : timeline.fade)
    }
}
