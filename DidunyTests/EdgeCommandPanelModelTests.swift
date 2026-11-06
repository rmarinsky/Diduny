import AppKit
@testable import Diduny
import Testing

@MainActor
struct EdgeCommandPanelModelTests {
    @Test("A dragged panel snaps to the nearest screen edge")
    func draggedPanelSnapsToNearestEdge() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

        #expect(EdgeCommandPanelPlacement.nearestDock(
            to: NSRect(x: 8, y: 260, width: 286, height: 326),
            in: visibleFrame
        ).edge == .left)
        #expect(EdgeCommandPanelPlacement.nearestDock(
            to: NSRect(x: 1140, y: 260, width: 286, height: 326),
            in: visibleFrame
        ).edge == .right)
        #expect(EdgeCommandPanelPlacement.nearestDock(
            to: NSRect(x: 560, y: 8, width: 286, height: 326),
            in: visibleFrame
        ).edge == .bottom)
        #expect(EdgeCommandPanelPlacement.nearestDock(
            to: NSRect(x: 560, y: 566, width: 286, height: 326),
            in: visibleFrame
        ).edge == .top)
    }

    @Test("A docked panel opens inward and collapses to a small edge tab")
    func dockedPanelUsesEdgeAwareFrames() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rightDock = EdgeCommandPanelDock(edge: .right, offset: 450)
        let bottomDock = EdgeCommandPanelDock(edge: .bottom, offset: 720)

        #expect(EdgeCommandPanelPlacement.frame(in: visibleFrame, dock: rightDock, presentation: .collapsed)
            == NSRect(x: 1426, y: 418, width: 14, height: 64))
        #expect(EdgeCommandPanelPlacement.frame(
            in: visibleFrame,
            dock: rightDock,
            presentation: .commands(isCloud: true)
        )
            == NSRect(x: 1140, y: 287, width: 300, height: 326))
        #expect(EdgeCommandPanelPlacement.frame(in: visibleFrame, dock: bottomDock, presentation: .collapsed)
            == NSRect(x: 688, y: 0, width: 64, height: 14))
        #expect(EdgeCommandPanelPlacement.frame(
            in: visibleFrame,
            dock: bottomDock,
            presentation: .commands(isCloud: true)
        )
            == NSRect(x: 570, y: 0, width: 300, height: 326))
    }

    @Test("Expanded panels keep rounded corners when docked")
    func expandedPanelsKeepRoundedCorners() {
        #expect(EdgeCommandPanelPlacement.expandedCornerRadius == 12)
    }

    @Test("Live controls have a comfortable click target")
    func liveControlsHaveComfortableClickTarget() {
        #expect(EdgeCommandPanelPlacement.liveControlHitTargetHeight == 38)
    }

    @Test("Meeting feedback grows beyond the compact dictation panel")
    func meetingFeedbackUsesLargerScrollableFrame() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let dock = EdgeCommandPanelDock(edge: .right, offset: 450)
        let dictation = EdgeCommandPanelPlacement.frame(
            in: visibleFrame,
            dock: dock,
            presentation: .live(.voice)
        )
        let meeting = EdgeCommandPanelPlacement.frame(
            in: visibleFrame,
            dock: dock,
            presentation: .live(.meeting)
        )

        #expect(dictation == NSRect(x: 1140, y: 294, width: 300, height: 312))
        #expect(meeting == NSRect(x: 1140, y: 240, width: 300, height: 420))
    }

    @Test("Every expanded state is 300 wide and takes the content's fitting height")
    func expandedStatesShareWidthAndFitContent() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let presentations: [EdgeCommandPanelPresentation] = [
            .commands(isCloud: true), .commands(isCloud: false), .live(.voice), .live(.meeting), .meetingSuggestion
        ]
        for edge in [EdgeCommandPanelDockEdge.left, .right, .top, .bottom] {
            let dock = EdgeCommandPanelDock(edge: edge, offset: 450)
            for presentation in presentations {
                let frame = EdgeCommandPanelPlacement.frame(
                    in: visibleFrame, dock: dock, presentation: presentation, contentHeight: 287
                )
                #expect(frame.width == EdgeCommandPanelPlacement.panelWidth)
                #expect(frame.height == 287)
            }
        }
        #expect(EdgeCommandPanelPlacement.panelWidth == 300)
    }

    @Test("Height change keeps the docked edge fixed")
    func heightChangeKeepsDockedEdge() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let top = EdgeCommandPanelDock(edge: .top, offset: 720)
        let bottom = EdgeCommandPanelDock(edge: .bottom, offset: 720)
        let short = EdgeCommandPanelPlacement.frame(
            in: visibleFrame, dock: top, presentation: .commands(isCloud: true), contentHeight: 200
        )
        let tall = EdgeCommandPanelPlacement.frame(
            in: visibleFrame, dock: top, presentation: .commands(isCloud: true), contentHeight: 400
        )
        #expect(short.maxY == tall.maxY)
        let shortBottom = EdgeCommandPanelPlacement.frame(
            in: visibleFrame, dock: bottom, presentation: .meetingSuggestion, contentHeight: 200
        )
        let tallBottom = EdgeCommandPanelPlacement.frame(
            in: visibleFrame, dock: bottom, presentation: .meetingSuggestion, contentHeight: 400
        )
        #expect(shortBottom.minY == tallBottom.minY)
    }

    @Test("Meeting suggestion is actionable for notch and compact-panel configurations")
    func meetingSuggestionOverridesConfiguredFeedbackSurface() {
        let savedSurface = SettingsStorage.shared.recordingFeedbackSurface
        defer { SettingsStorage.shared.recordingFeedbackSurface = savedSurface }

        for surface in [RecordingFeedbackSurface.notch, .compactPanel] {
            SettingsStorage.shared.recordingFeedbackSurface = surface
            let controller = EdgeCommandPanelController(meetingRecordingStarter: { _ in })
            let meeting = DetectedMeeting(id: UUID(), client: .zoom)

            controller.showMeetingSuggestion(meeting)

            #expect(controller.currentPresentation == .meetingSuggestion)
            controller.dismissMeetingSuggestion(id: meeting.id)
            #expect(controller.currentPresentation == .collapsed)
        }
    }

    @Test("Meeting suggestion controller starts recording only once")
    func meetingSuggestionControllerStartsOnce() {
        var startedProviders: [TranscriptionProvider] = []
        let controller = EdgeCommandPanelController { provider in
            startedProviders.append(provider)
        }
        let meeting = DetectedMeeting(id: UUID(), client: .zoom)

        controller.showMeetingSuggestion(meeting)
        controller.selectMeetingSuggestionProvider(.local)
        controller.startMeetingRecording(fromSuggestionID: meeting.id)
        controller.startMeetingRecording(fromSuggestionID: meeting.id)

        #expect(startedProviders == [.local])
    }

    @Test("Meeting suggestion falls back to Local when Cloud is unavailable")
    func unavailableCloudFallsBackToLocal() {
        let model = EdgeCommandPanelModel()
        let suggestion = MeetingSuggestion.resolve(
            meeting: DetectedMeeting(id: UUID(), client: .googleMeet),
            preferredProvider: .cloud,
            cloudAvailable: false,
            hasLocalModel: true
        )

        model.presentMeetingSuggestion(suggestion)

        #expect(model.meetingSuggestion?.selectedProvider == .local)
        #expect(model.meetingSuggestion?.processingMode == .local)
        #expect(!model.selectMeetingSuggestionProvider(.cloud))
    }

    @Test("Paid Pro access works without a whitelist and without remaining free hours")
    func paidProCloudAccessIsRecognized() throws {
        let data = Data(#"{"isWhitelisted":false,"isUnlimited":true,"usedHours":8,"limitHours":null,"remainingHours":null,"usedMs":28800000,"limitMs":null,"remainingMs":null}"#.utf8)
        let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
        #expect(UsageService.canUseCloudTranscription(hasStoredSession: true, usage: usage))
    }

    @Test("Cloud use requires confirmed usage while an unknown cache remains selectable")
    func cloudEligibilityDistinguishesConfirmedUseFromAnUnknownOffer() {
        let available = UsageResponse(
            isWhitelisted: false,
            usedHours: 1,
            limitHours: 5,
            remainingHours: 4,
            usedMs: 3_600_000,
            limitMs: 18_000_000,
            remainingMs: 14_400_000
        )
        let exhausted = UsageResponse(
            isWhitelisted: false,
            usedHours: 5,
            limitHours: 5,
            remainingHours: 0,
            usedMs: 18_000_000,
            limitMs: 18_000_000,
            remainingMs: 0
        )
        let noSubscription = UsageResponse(
            isWhitelisted: false,
            usedHours: 0,
            limitHours: nil,
            remainingHours: nil,
            usedMs: 0,
            limitMs: nil,
            remainingMs: nil
        )

        #expect(UsageService.canUseCloudTranscription(hasStoredSession: true, usage: available))
        #expect(!UsageService.canUseCloudTranscription(hasStoredSession: false, usage: available))
        #expect(!UsageService.canUseCloudTranscription(hasStoredSession: true, usage: exhausted))
        #expect(!UsageService.canUseCloudTranscription(hasStoredSession: true, usage: noSubscription))
        #expect(!UsageService.canUseCloudTranscription(hasStoredSession: true, usage: nil))
        #expect(UsageService.canOfferCloudTranscription(hasStoredSession: true, usage: nil))
        #expect(!UsageService.canOfferCloudTranscription(hasStoredSession: false, usage: nil))
    }

    @Test("Disabling future suggestions keeps the current meeting suggestion open")
    func disablingTrackingDoesNotDismissCurrentSuggestion() {
        let model = EdgeCommandPanelModel()
        let suggestion = MeetingSuggestion(
            meeting: DetectedMeeting(id: UUID(), client: .teams),
            selectedProvider: .cloud,
            isCloudAvailable: true,
            hasLocalModel: true
        )

        model.presentMeetingSuggestion(suggestion)
        model.meetingSuggestionsEnabled = false

        #expect(model.meetingSuggestion == suggestion)
    }

    @Test("Meeting suggestion controls meet the minimum pointer target")
    func meetingSuggestionControlsMeetMinimumTarget() {
        #expect(EdgeCommandPanelPlacement.meetingSuggestionControlHitTargetHeight == 38)
    }

    @Test("Meeting suggestion describes the actual processing path")
    func meetingSuggestionProcessingModeMatchesRuntimeReadiness() {
        #expect(MeetingSuggestionProcessingMode.resolve(cloudEnabled: true, hasLocalModel: false) == .cloud)
        #expect(MeetingSuggestionProcessingMode.resolve(cloudEnabled: false, hasLocalModel: true) == .local)
        #expect(
            MeetingSuggestionProcessingMode.resolve(cloudEnabled: false, hasLocalModel: false)
                == .recordingOnly
        )
    }

    @Test("Auto-hide only collapses after the pointer leaves the panel")
    func autoHideChecksThePointerAtTheEndOfTheDelay() {
        let panelFrame = NSRect(x: 1154, y: 287, width: 286, height: 326)

        #expect(!EdgeCommandPanelHoverPolicy.shouldCollapse(
            pointer: NSPoint(x: 1200, y: 400),
            panelFrame: panelFrame,
            isDragging: false
        ))
        #expect(!EdgeCommandPanelHoverPolicy.shouldCollapse(
            pointer: NSPoint(x: 900, y: 400),
            panelFrame: panelFrame,
            isDragging: true
        ))
        #expect(EdgeCommandPanelHoverPolicy.shouldCollapse(
            pointer: NSPoint(x: 900, y: 400),
            panelFrame: panelFrame,
            isDragging: false
        ))
    }

    @Test("A persisted dock position restores across app restarts")
    func dockRestoresFromPersistedRawValues() {
        let saved = EdgeCommandPanelDock(edge: .left, offset: 321)

        #expect(EdgeCommandPanelDock(rawEdge: saved.edge.rawValue, offset: Double(saved.offset)) == saved)
        #expect(EdgeCommandPanelDock(rawEdge: "diagonal", offset: 100) == nil)
        #expect(EdgeCommandPanelDock(rawEdge: nil, offset: 100) == nil)
        #expect(EdgeCommandPanelDock(rawEdge: "top", offset: nil) == nil)
    }

    @Test("The collapsed tab auto-hides only when idle and untouched")
    func tabAutoHidesOnlyWhenIdleAndUntouched() {
        let panelFrame = NSRect(x: 1426, y: 418, width: 14, height: 64)
        let outside = NSPoint(x: 700, y: 400)
        let inside = NSPoint(x: 1430, y: 440)

        #expect(EdgeCommandPanelAutoHidePolicy.shouldHide(
            pointer: outside, panelFrame: panelFrame,
            isDragging: false, isExpanded: false, isShowingLiveFeedback: false
        ))
        #expect(!EdgeCommandPanelAutoHidePolicy.shouldHide(
            pointer: inside, panelFrame: panelFrame,
            isDragging: false, isExpanded: false, isShowingLiveFeedback: false
        ))
        #expect(!EdgeCommandPanelAutoHidePolicy.shouldHide(
            pointer: outside, panelFrame: panelFrame,
            isDragging: true, isExpanded: false, isShowingLiveFeedback: false
        ))
        #expect(!EdgeCommandPanelAutoHidePolicy.shouldHide(
            pointer: outside, panelFrame: panelFrame,
            isDragging: false, isExpanded: true, isShowingLiveFeedback: false
        ))
        #expect(!EdgeCommandPanelAutoHidePolicy.shouldHide(
            pointer: outside, panelFrame: panelFrame,
            isDragging: false, isExpanded: false, isShowingLiveFeedback: true
        ))
        // Minimized live tab (red dot) auto-hides like the idle tab.
        #expect(EdgeCommandPanelAutoHidePolicy.shouldHide(
            pointer: outside, panelFrame: panelFrame,
            isDragging: false, isExpanded: false, isShowingLiveFeedback: false,
            isLiveFeedbackMinimized: true
        ))
        #expect(EdgeCommandPanelAutoHidePolicy.shouldHide(
            pointer: outside, panelFrame: panelFrame,
            isDragging: false, isExpanded: false, isShowingLiveFeedback: true,
            isLiveFeedbackMinimized: true
        ))
        #expect(!EdgeCommandPanelAutoHidePolicy.shouldHide(
            pointer: inside, panelFrame: panelFrame,
            isDragging: false, isExpanded: false, isShowingLiveFeedback: true,
            isLiveFeedbackMinimized: true
        ))
        #expect(EdgeCommandPanelAutoHidePolicy.shouldSchedule(isLiveFeedbackMinimized: true))
        #expect(EdgeCommandPanelAutoHidePolicy.shouldSchedule(isLiveFeedbackMinimized: false))
        #expect(!EdgeCommandPanelMinimizedLivePolicy.shouldAllowHoverExpand(isLiveFeedbackMinimized: true))
        #expect(EdgeCommandPanelMinimizedLivePolicy.shouldAllowHoverExpand(isLiveFeedbackMinimized: false))
    }

    @Test("A hidden tab reveals when the pointer touches the docked screen edge")
    func hiddenTabRevealsAtDockedEdge() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

        #expect(EdgeCommandPanelPlacement.edgeHotZoneContains(
            NSPoint(x: 1439, y: 500), screenFrame: screenFrame, edge: .right
        ))
        #expect(!EdgeCommandPanelPlacement.edgeHotZoneContains(
            NSPoint(x: 1400, y: 500), screenFrame: screenFrame, edge: .right
        ))
        #expect(EdgeCommandPanelPlacement.edgeHotZoneContains(
            NSPoint(x: 1, y: 500), screenFrame: screenFrame, edge: .left
        ))
        #expect(EdgeCommandPanelPlacement.edgeHotZoneContains(
            NSPoint(x: 700, y: 899), screenFrame: screenFrame, edge: .top
        ))
        #expect(EdgeCommandPanelPlacement.edgeHotZoneContains(
            NSPoint(x: 700, y: 1), screenFrame: screenFrame, edge: .bottom
        ))
        // A point on another screen's edge line but outside this screen is ignored.
        #expect(!EdgeCommandPanelPlacement.edgeHotZoneContains(
            NSPoint(x: 1439, y: 1200), screenFrame: screenFrame, edge: .right
        ))
    }
}

@MainActor
struct EdgeCommandPanelLiveTextTests {
    @Test("Recording controls expose active stop and cancel shortcuts")
    func recordingControlsExposeActiveShortcuts() {
        let settings = SettingsStorage.shared
        let previousKey = settings.pushToTalkKey
        let previousToggleEnabled = settings.pushToTalkToggleEnabled
        let previousTapCount = settings.pushToTalkToggleTapCount
        let previousCancelEnabled = settings.escapeCancelEnabled
        let previousCancelShortcut = settings.escapeCancelShortcut
        let previousCancelPressCount = settings.escapeCancelPressCount
        defer {
            settings.pushToTalkKey = previousKey
            settings.pushToTalkToggleEnabled = previousToggleEnabled
            settings.pushToTalkToggleTapCount = previousTapCount
            settings.escapeCancelEnabled = previousCancelEnabled
            settings.escapeCancelShortcut = previousCancelShortcut
            settings.escapeCancelPressCount = previousCancelPressCount
        }

        settings.pushToTalkKey = .rightShift
        settings.pushToTalkToggleEnabled = true
        settings.pushToTalkToggleTapCount = 2
        settings.escapeCancelEnabled = true
        settings.escapeCancelShortcut = RecordingCancelShortcut(
            keyCode: 0,
            modifiersRawValue: NSEvent.ModifierFlags.command.rawValue,
            keyLabel: "A"
        )
        settings.escapeCancelPressCount = 3

        let store = LiveDictationOverlayStore()
        store.reset(mode: .voice)
        store.phase = .recording

        #expect(store.stopShortcutHint == "⇧ ×2")
        #expect(store.cancelShortcutHint == "Esc ×3")

        settings.escapeCancelEnabled = false
        #expect(store.cancelShortcutHint == nil)
    }

    @Test("Meeting transcript keeps timestamps and speaker diarization")
    func meetingTranscriptKeepsStructuredMetadata() {
        let store = LiveDictationOverlayStore()
        store.reset(mode: .meeting)

        store.processTokens([
            RealtimeToken(text: "Hello", isFinal: true, speaker: "1", startMs: 1200),
            RealtimeToken(text: "Hi", isFinal: true, speaker: "2", startMs: 65000)
        ])

        #expect(store.displayText.contains("[00:01] Speaker 1: Hello"))
        #expect(store.displayText.contains("[01:05] Speaker 2: Hi"))

        store.processTokens([
            RealtimeToken(text: "Still speaking", isFinal: false, speaker: "2", startMs: 66000)
        ])

        #expect(store.displayText.contains("Still speaking"))
    }

    @Test("Meeting transcript keeps provider phrase boundaries")
    func meetingTranscriptKeepsPhraseBoundaries() {
        let store = LiveDictationOverlayStore()
        store.reset(mode: .meeting)

        store.processTokens([
            RealtimeToken(text: "First phrase", isFinal: true, speaker: "1", startMs: 1000)
        ])
        store.markSegmentBoundary()
        store.processTokens([
            RealtimeToken(text: "Second phrase", isFinal: true, speaker: "1", startMs: 8000)
        ])

        #expect(store.displayText.contains("[00:01] Speaker 1: First phrase"))
        #expect(store.displayText.contains("[00:08] Speaker 1: Second phrase"))
    }

    @Test("Meeting translation displays translated tokens instead of source tokens")
    func meetingTranslationPrefersTranslatedTokens() {
        let store = LiveDictationOverlayStore()
        store.reset(mode: .meetingTranslation)

        store.processTokens([
            RealtimeToken(text: "Привіт", isFinal: true, translationStatus: "source"),
            RealtimeToken(text: "Hello", isFinal: true, translationStatus: "translation")
        ])

        #expect(store.visibleText == "Hello")
    }
}
