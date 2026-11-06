import AppKit
import SwiftUI

/// The one Reduce Motion source (test-plan 2.5). Views and controllers take a value so tests can inject it.
struct MotionPreference: Equatable {
    let reduceMotion: Bool

    static let standard = MotionPreference(reduceMotion: false)
    static let reduced = MotionPreference(reduceMotion: true)

    #if DEBUG || TEST_BUILD
        /// UI tests force Reduce Motion with this launch argument.
        static let reduceMotionArgument = "--ui-testing-reduce-motion"
    #endif

    static var current: MotionPreference {
        #if DEBUG || TEST_BUILD
            if ProcessInfo.processInfo.arguments.contains(reduceMotionArgument) { return .reduced }
        #endif
        return MotionPreference(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

/// Motion parameters for the command panel (design-spec 5: M1, M2, M3, M8), as testable values.
enum MotionPolicy {
    enum PanelChange: Equatable {
        /// Different content: home, live, prompt, outcome (M1).
        case swap
        /// Same content redrawn: picker change, sign-in toggle, Stop to progress (M3).
        case inPlace
    }

    struct ContentSwap: Equatable {
        /// Insertion offset; the content moves from here to zero.
        let offset: CGSize
        let duration: Double
        let curve: DS.Motion.Curve
        let fades: Bool

        var animation: Animation {
            curve == .easeOut ? DS.Motion.easeOut(duration) : DS.Motion.reduced
        }

        /// Old content leaves at once (removal identity).
        var transition: AnyTransition {
            .asymmetric(
                insertion: .offset(x: offset.width, y: offset.height).combined(with: .opacity),
                removal: .identity
            )
        }
    }

    struct HeightChange: Equatable {
        let animated: Bool
        let duration: Double
        /// `CAMediaTimingFunction(controlPoints:)` values.
        let controlPoints: [Float]
    }

    struct PulseKeyframe: Equatable {
        let scale: CGFloat
        let duration: Double
    }

    /// `DS.Motion.reduced`, 120 ms.
    static let reducedFadeDuration = 0.12

    static func contentSwap(
        _ change: PanelChange,
        edge: EdgeCommandPanelDockEdge,
        preference: MotionPreference
    ) -> ContentSwap? {
        guard change == .swap else { return nil }
        let token = DS.Motion.m1ContentSwap
        if preference.reduceMotion {
            return ContentSwap(offset: .zero, duration: reducedFadeDuration, curve: .linear, fades: true)
        }
        return ContentSwap(offset: slideOffset(for: edge), duration: token.duration, curve: token.curve, fades: true)
    }

    static func slideOffset(for edge: EdgeCommandPanelDockEdge) -> CGSize {
        let distance = DS.Motion.slideOffset
        return switch edge {
        case .right: CGSize(width: distance, height: 0)
        case .left: CGSize(width: -distance, height: 0)
        case .top: CGSize(width: 0, height: -distance)
        case .bottom: CGSize(width: 0, height: distance)
        }
    }

    static func heightChange(preference: MotionPreference) -> HeightChange {
        HeightChange(
            animated: !preference.reduceMotion,
            duration: preference.reduceMotion ? 0 : DS.Motion.m2PanelHeight.duration,
            controlPoints: [0.77, 0, 0.175, 1]
        )
    }

    /// M8: up to `pulseScale` and back, 200 ms each; none with Reduce Motion.
    static func successPulseKeyframes(preference: MotionPreference) -> [PulseKeyframe] {
        guard !preference.reduceMotion else { return [] }
        let half = DS.Motion.m8SuccessPulse.duration / 2
        return [PulseKeyframe(scale: DS.Motion.pulseScale, duration: half), PulseKeyframe(scale: 1, duration: half)]
    }
}
