import Testing

@testable import Diduny

@Suite("PushToTalkService Hold Delay")
@MainActor
struct PushToTalkServiceTests {
    init() {
        SettingsStorage.shared.handsFreeModeEnabled = false
        SettingsStorage.shared.pushToTalkHoldStartDelaySeconds = 0.2
        SettingsStorage.shared.translationPushToTalkHoldStartDelaySeconds = 0.2
    }

    @Test("Short hold before threshold does not start or stop recording")
    func shortHoldBeforeThresholdDoesNotStart() async {
        let sut = PushToTalkService()
        sut.selectedKey = .rightShift
        sut.holdStartDelaySeconds = 0.2

        var starts = 0
        var stops = 0
        sut.onKeyDown = { starts += 1 }
        sut.onKeyUp = { stops += 1 }

        sut.processModifierKeyEvent(isPressed: true, eventTime: 0)
        try? await Task.sleep(for: .milliseconds(100))
        sut.processModifierKeyEvent(isPressed: false, eventTime: 0.1)
        try? await Task.sleep(for: .milliseconds(150))

        #expect(starts == 0)
        #expect(stops == 0)
    }

    @Test("Hold past threshold starts once and release stops once")
    func holdPastThresholdStartsAndReleaseStops() async {
        let sut = PushToTalkService()
        sut.selectedKey = .rightShift
        sut.holdStartDelaySeconds = 0.2

        var starts = 0
        var stops = 0
        sut.onKeyDown = { starts += 1 }
        sut.onKeyUp = { stops += 1 }

        sut.processModifierKeyEvent(isPressed: true, eventTime: 0)
        try? await Task.sleep(for: .milliseconds(250))

        #expect(starts == 1)
        #expect(stops == 0)

        sut.processModifierKeyEvent(isPressed: false, eventTime: 0.25)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(starts == 1)
        #expect(stops == 1)
    }

    @Test("Hands-free toggle ignores hold delay")
    func handsFreeToggleIgnoresHoldDelay() async {
        SettingsStorage.shared.handsFreeModeEnabled = true

        let sut = PushToTalkService()
        sut.selectedKey = .rightShift
        sut.toggleTapCount = 2
        sut.holdStartDelaySeconds = 1.0

        var toggles = 0
        var starts = 0
        sut.onToggle = { toggles += 1 }
        sut.onKeyDown = { starts += 1 }

        sut.processModifierKeyEvent(isPressed: true, eventTime: 0)
        sut.processModifierKeyEvent(isPressed: false, eventTime: 0.05)
        sut.processModifierKeyEvent(isPressed: true, eventTime: 0.1)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(toggles == 1)
        #expect(starts == 0)
    }

    @Test("Settings clamp hold start delay range")
    func settingsClampHoldStartDelayRange() {
        SettingsStorage.shared.pushToTalkHoldStartDelaySeconds = 0.05
        #expect(SettingsStorage.shared.pushToTalkHoldStartDelaySeconds == 0.2)

        SettingsStorage.shared.pushToTalkHoldStartDelaySeconds = 1.5
        #expect(SettingsStorage.shared.pushToTalkHoldStartDelaySeconds == 1.0)

        SettingsStorage.shared.translationPushToTalkHoldStartDelaySeconds = 0.55
        #expect(SettingsStorage.shared.translationPushToTalkHoldStartDelaySeconds == 0.6)
    }
}
