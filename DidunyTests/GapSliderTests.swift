import CoreGraphics
import Testing
@testable import Diduny

struct GapSliderTests {
    private let m = GapSliderGeometry.Metrics.regular

    @Test func gapOnBothSidesOfTheHandle() {
        let l = GapSliderGeometry.layout(width: 204, fraction: 0.5, metrics: m)
        #expect(l.handleX == 100)
        #expect(l.handleX - l.activeWidth == 6)
        #expect(l.inactiveStart - (l.handleX + 4) == 6)
        #expect(l.inactiveStart + l.inactiveWidth == 204)
    }

    @Test func handleStaysInsideAtTheEnds() {
        let start = GapSliderGeometry.layout(width: 204, fraction: 0, metrics: m)
        #expect(start.handleX == 0 && start.activeWidth == 0)
        let end = GapSliderGeometry.layout(width: 204, fraction: 1, metrics: m)
        #expect(end.handleX == 200 && end.inactiveWidth == 0)
    }

    @Test func pointerPositionMapsToFraction() {
        #expect(GapSliderGeometry.fraction(at: 102, width: 204, metrics: m) == 0.5)
        #expect(GapSliderGeometry.fraction(at: -20, width: 204, metrics: m) == 0)
        #expect(GapSliderGeometry.fraction(at: 400, width: 204, metrics: m) == 1)
    }
}
