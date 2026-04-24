import Testing

@testable import Diduny

@Suite("EscapeCancelService Press Logic")
@MainActor
struct EscapeCancelServiceTests {
    private var sut: EscapeCancelService { EscapeCancelService.shared }

    init() {
        sut.deactivate()
        SettingsStorage.shared.escapeCancelEnabled = true
        SettingsStorage.shared.escapeCancelPressCount = 2
    }

    // MARK: - Double-press cancel (default: 2 presses)

    @Test("Two presses within threshold triggers cancel")
    func doublePressTriggersCancel() {
        var cancelled = false
        sut.onCancel = { cancelled = true }

        let t0 = Date()
        sut.processEscapePress(at: t0)
        #expect(!cancelled)

        sut.processEscapePress(at: t0.addingTimeInterval(0.3))
        #expect(cancelled)
    }

    @Test("Two presses outside threshold does not cancel")
    func pressesOutsideThresholdDoNotCancel() {
        var cancelled = false
        sut.onCancel = { cancelled = true }

        let t0 = Date()
        sut.processEscapePress(at: t0)
        sut.processEscapePress(at: t0.addingTimeInterval(2.0))

        #expect(!cancelled)
    }

    // MARK: - Triple-press cancel

    @Test("Three presses required when configured for 3")
    func triplePressCancel() {
        SettingsStorage.shared.escapeCancelPressCount = 3

        var cancelled = false
        sut.onCancel = { cancelled = true }

        let t0 = Date()
        sut.processEscapePress(at: t0)
        #expect(!cancelled)

        sut.processEscapePress(at: t0.addingTimeInterval(0.3))
        #expect(!cancelled)

        sut.processEscapePress(at: t0.addingTimeInterval(0.6))
        #expect(cancelled)
    }

    // MARK: - Progress callback

    @Test("onProgressEscape fires with correct counts")
    func progressCallbackCounts() {
        SettingsStorage.shared.escapeCancelPressCount = 3

        var progressCalls: [(current: Int, required: Int)] = []
        sut.onProgressEscape = { current, required in
            progressCalls.append((current, required))
        }

        let t0 = Date()
        sut.processEscapePress(at: t0)
        sut.processEscapePress(at: t0.addingTimeInterval(0.3))

        #expect(progressCalls.count == 2)
        #expect(progressCalls[0].current == 1)
        #expect(progressCalls[0].required == 3)
        #expect(progressCalls[1].current == 2)
        #expect(progressCalls[1].required == 3)
    }

    @Test("onProgressEscape does not fire on final press (onCancel fires instead)")
    func progressDoesNotFireOnFinalPress() {
        var progressCount = 0
        var cancelled = false
        sut.onProgressEscape = { _, _ in progressCount += 1 }
        sut.onCancel = { cancelled = true }

        let t0 = Date()
        sut.processEscapePress(at: t0)
        sut.processEscapePress(at: t0.addingTimeInterval(0.3))

        #expect(progressCount == 1)
        #expect(cancelled)
    }

    // MARK: - Threshold boundaries

    @Test("Press at exactly 1.5s still counts (<=)")
    func thresholdBoundaryInclusive() {
        var cancelled = false
        sut.onCancel = { cancelled = true }

        let t0 = Date()
        sut.processEscapePress(at: t0)
        sut.processEscapePress(at: t0.addingTimeInterval(1.5))

        #expect(cancelled)
    }

    @Test("Press at 1.501s resets count")
    func thresholdBoundaryExclusive() {
        var cancelled = false
        sut.onCancel = { cancelled = true }

        let t0 = Date()
        sut.processEscapePress(at: t0)
        sut.processEscapePress(at: t0.addingTimeInterval(1.501))

        #expect(!cancelled)
    }

    // MARK: - Count reset after timeout gap

    @Test("Count resets when gap exceeds threshold")
    func countResetsAfterGap() {
        SettingsStorage.shared.escapeCancelPressCount = 3
        var cancelled = false
        sut.onCancel = { cancelled = true }

        let t0 = Date()
        // Press 1 and 2 within threshold
        sut.processEscapePress(at: t0)
        sut.processEscapePress(at: t0.addingTimeInterval(0.5))
        // Gap too long — count resets
        sut.processEscapePress(at: t0.addingTimeInterval(3.0))

        #expect(!cancelled, "Count should have reset after gap, so 3rd press starts over at 1")
    }
}
