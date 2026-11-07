import CoreGraphics
@testable import Diduny
import SwiftUI
import Testing

/// The width rule of `ModeSegmentsLayout` (design-spec 4.3, CSS `flex: 1 1 auto`, `min-width: 0`),
/// the weighted split of `PanelControlsLayout` (4.4, 4.5) and arrow-key stepping of `ModeSegments`.
struct ModeSegmentsLayoutTests {
    private func expectNear(_ actual: [CGFloat], _ expected: [CGFloat]) {
        #expect(actual.count == expected.count)
        for (a, e) in zip(actual, expected) {
            #expect(abs(a - e) < 0.001, "\(actual) != \(expected)")
        }
    }

    @Test("Extra track width is shared equally on top of each ideal width")
    func extraIsSharedEqually() {
        // 222 available, 4 for two gaps, 120 ideal: 98 extra, 32.67 each.
        let widths = ModeSegmentsLayout.widths(ideal: [30, 40, 50], available: 222, spacing: 2)
        expectNear(widths, [30 + 98.0 / 3, 40 + 98.0 / 3, 50 + 98.0 / 3])
    }

    @Test("Widths and gaps fill the available width exactly")
    func fillsAvailableWidth() {
        let widths = ModeSegmentsLayout.widths(ideal: [61.1, 43.3, 77.6], available: 222, spacing: 2)
        let total: Double = widths.reduce(0.0) { $0 + Double($1) }
        let error: Double = abs(total + 4.0 - 222.0)
        #expect(error < 0.001)
    }

    @Test("Differences between segments stay the label differences")
    func keepsDifferences() {
        let widths = ModeSegmentsLayout.widths(ideal: [61.1, 43.3, 77.6], available: 222, spacing: 2)
        let firstToSecond: Double = Double(widths[0] - widths[1])
        let thirdToFirst: Double = Double(widths[2] - widths[0])
        #expect(abs(firstToSecond - 17.8) < 0.001)
        #expect(abs(thirdToFirst - 16.5) < 0.001)
    }

    @Test("Without a proposed width each segment takes its ideal width")
    func idealWithoutProposal() {
        expectNear(ModeSegmentsLayout.widths(ideal: [30, 40, 50], available: nil, spacing: 2), [30, 40, 50])
    }

    @Test("A track narrower than the content shrinks each segment in proportion to its ideal width")
    func shrinksProportionally() {
        // 100 available, 4 gaps, 120 ideal: 24 too much, taken as 1/5 of each.
        expectNear(ModeSegmentsLayout.widths(ideal: [30, 40, 50], available: 100, spacing: 2), [24, 32, 40])
    }

    @Test("A track with no room left gives zero widths, never negative")
    func neverNegative() {
        let widths = ModeSegmentsLayout.widths(ideal: [30, 40, 50], available: 3, spacing: 2)
        #expect(widths.allSatisfy { $0 == 0 })
    }

    @Test("One segment fills the track; no segments give no widths")
    func edgeCounts() {
        expectNear(ModeSegmentsLayout.widths(ideal: [40], available: 270, spacing: 2), [270])
        #expect(ModeSegmentsLayout.widths(ideal: [], available: 270, spacing: 2).isEmpty)
    }

    @Test("The prompt's full-width track (274) keeps the same rule")
    func fullWidthTrack() {
        let ideal: [CGFloat] = [61.1, 43.3, 77.6]
        let widths = ModeSegmentsLayout.widths(ideal: ideal, available: 270, spacing: 2)
        let extra = (270 - 4 - ideal.reduce(0, +)) / 3
        expectNear(widths, ideal.map { $0 + extra })
    }

    // MARK: - Panel controls row

    @Test("Copy : Stop is 1 : 1.6 in the 274 pt row")
    func weightedSplit() {
        let widths = PanelControlsLayout.widths(available: 274, weights: [1, 1.6], spacing: 8)
        expectNear(widths, [266 / 2.6, 266 / 2.6 * 1.6])
    }

    @Test("Weights that sum to zero give equal parts")
    func zeroWeights() {
        expectNear(PanelControlsLayout.widths(available: 274, weights: [0, 0], spacing: 8), [133, 133])
    }

    // MARK: - Arrow keys

    private static let items: [ModeSegments<String>.Item] = [
        .init(id: "localLive", title: "This Mac"),
        .init(id: "cloudLive", title: "Cloud", isEnabled: false),
        .init(id: "recordOnly", title: "Record only"),
    ]

    @Test("Right arrow moves to the next enabled segment, skipping disabled ones")
    func stepRightSkipsDisabled() {
        #expect(ModeSegments.step(from: "localLive", by: 1, in: Self.items) == "recordOnly")
    }

    @Test("Left arrow moves to the previous enabled segment")
    func stepLeft() {
        #expect(ModeSegments.step(from: "recordOnly", by: -1, in: Self.items) == "localLive")
    }

    @Test("Arrows stop at the ends; they do not wrap")
    func stepStopsAtEnds() {
        #expect(ModeSegments.step(from: "recordOnly", by: 1, in: Self.items) == "recordOnly")
        #expect(ModeSegments.step(from: "localLive", by: -1, in: Self.items) == "localLive")
    }

    @Test("An unknown selection does not move")
    func stepUnknown() {
        #expect(ModeSegments.step(from: "missing", by: 1, in: Self.items) == "missing")
    }
}
