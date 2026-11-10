@testable import Diduny
import Foundation
import Testing

/// Press rules shared by every Carbon hotkey (test-plan 3.4): 0.35 s, strict, from the last press.
@Suite("PressCounter")
struct PressCounterTests {
    private func presses(_ times: [TimeInterval], required: Int) -> [Bool] {
        var counter = PressCounter()
        return times.map { counter.register(at: $0, required: required, window: PressCounter.hotkeyWindow) }
    }

    @Test("The hotkey window is 0.35 s")
    func hotkeyWindowIsToday() {
        #expect(PressCounter.hotkeyWindow == 0.35)
    }

    @Test("T5-HK-01 count 1 triggers every press")
    func countOneTriggersEveryPress() {
        #expect(presses([0, 0.1], required: 1) == [true, true])
    }

    @Test("T5-HK-02 count 2 triggers on the second press and resets")
    func countTwoTriggersOnSecondPressAndResets() {
        #expect(presses([0, 0.2, 0.3], required: 2) == [false, true, false])
    }

    @Test("T5-HK-03 0.349 s counts for 2x, 0.350 s starts a new sequence")
    func windowBoundaryIsStrict() {
        #expect(presses([0, 0.349], required: 2) == [false, true])
        #expect(presses([0, 0.350], required: 2) == [false, false])
    }

    @Test("T5-HK-04 count 3")
    func countThree() {
        #expect(presses([0, 0.2, 0.4], required: 3) == [false, false, true])
        #expect(presses([0, 0.2, 0.6], required: 3) == [false, false, false])
    }

    @Test("T5-HK-05 the window runs from the last press")
    func windowRunsFromLastPress() {
        #expect(presses([0, 0.34, 0.68], required: 3) == [false, false, true])
    }

    @Test("T5-HK-10 changing the count mid-sequence triggers and resets")
    func changingCountMidSequence() {
        var counter = PressCounter()
        // `#expect` cannot wrap a mutating call, so each result is bound first.
        let results = [
            counter.register(at: 0, required: 3, window: 0.35),
            counter.register(at: 0.1, required: 3, window: 0.35),
            counter.register(at: 0.2, required: 1, window: 0.35),
            // The sequence was reset, so 3x needs three new presses.
            counter.register(at: 0.3, required: 3, window: 0.35),
            counter.register(at: 0.4, required: 3, window: 0.35),
            counter.register(at: 0.5, required: 3, window: 0.35)
        ]
        #expect(results == [false, false, true, false, false, true])
    }

    @Test("Reset starts a new sequence")
    func resetStartsNewSequence() {
        var counter = PressCounter()
        _ = counter.register(at: 0, required: 2, window: 0.35)
        counter.reset()
        let triggered = counter.register(at: 0.1, required: 2, window: 0.35)
        #expect(!triggered)
    }
}
