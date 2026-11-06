import CoreGraphics
@testable import Diduny
import Testing

/// T2-MO-01 to T2-MO-04 (test-plan.md): command panel Slide, Reduce Motion fade, in-place changes, success pulse.
@Suite("Slide transition")
struct SlideTransitionTests {
    @Test("T2-MO-01 Slide comes from the docked edge", arguments: [
        (EdgeCommandPanelDockEdge.right, CGSize(width: 16, height: 0)),
        (.left, CGSize(width: -16, height: 0)),
        (.top, CGSize(width: 0, height: -16)),
        (.bottom, CGSize(width: 0, height: 16))
    ])
    func slideFromDockedEdge(edge: EdgeCommandPanelDockEdge, offset: CGSize) throws {
        let swap = try #require(MotionPolicy.contentSwap(.swap, edge: edge, preference: .standard))
        #expect(swap.offset == offset)
        #expect(swap.duration == DS.Motion.m1ContentSwap.duration)
        #expect(swap.duration == 0.22)
        #expect(swap.curve == .easeOut)
        #expect(swap.fades)

        let height = MotionPolicy.heightChange(preference: .standard)
        #expect(height.animated)
        #expect(height.duration == DS.Motion.m2PanelHeight.duration)
        #expect(height.controlPoints == [0.77, 0, 0.175, 1])
    }

    @Test("T2-MO-02 Reduce Motion replaces Slide with a fade", arguments: [
        EdgeCommandPanelDockEdge.right, .left, .top, .bottom
    ])
    func reduceMotionFades(edge: EdgeCommandPanelDockEdge) throws {
        let swap = try #require(MotionPolicy.contentSwap(.swap, edge: edge, preference: .reduced))
        #expect(swap.offset == .zero)
        #expect(swap.duration == 0.12)
        #expect(swap.curve == .linear)
        #expect(swap.fades)
        #expect(!MotionPolicy.heightChange(preference: .reduced).animated)
    }

    @Test("T2-MO-03 Not a swap: no transition", arguments: [MotionPreference.standard, .reduced])
    func inPlaceChangeHasNoTransition(preference: MotionPreference) {
        #expect(MotionPolicy.contentSwap(.inPlace, edge: .right, preference: preference) == nil)
    }

    @Test("T2-MO-04 Success pulse off with Reduce Motion")
    func successPulseOffWithReduceMotion() {
        #expect(MotionPolicy.successPulseKeyframes(preference: .standard) == [
            .init(scale: 1.15, duration: 0.2), .init(scale: 1, duration: 0.2)
        ])
        #expect(MotionPolicy.successPulseKeyframes(preference: .reduced).isEmpty)
    }
}
