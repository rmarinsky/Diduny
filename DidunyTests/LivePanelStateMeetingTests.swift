@testable import Diduny
import CoreGraphics
import Testing

/// Meeting cases of the live panel state (test-plan T1-MT-04, -05, -06, -09, -10, -11, -13, -15; WP-31).
@MainActor
struct LivePanelStateMeetingTests {
    static let parakeetBytes: Int64 = 480_000_000

    static func state(
        _ segment: MeetingSegment,
        engine: EngineID? = nil,
        readiness: [EngineID: EngineReadiness] = [.elevenLabs: .needsKey],
        appleSilicon: Bool = true,
        onBattery: Bool = false,
        connection: RealtimeConnectionStatus = .connected
    ) -> MeetingPanelState {
        var engines = MeetingPanelState.defaultEngines
        if let engine { engines[segment] = engine }
        return MeetingPanelState(
            segment: segment,
            engines: engines,
            readiness: FakeEngineReadinessSource(readiness),
            isAppleSilicon: appleSilicon,
            isOnBattery: onBattery,
            connection: connection
        )
    }

    // MARK: Segments

    @Test("Three segments in order with the test-plan identifiers")
    func segments() {
        let items = Self.state(.cloud).segments
        #expect(items.map(\.id) == [.thisMac, .cloud, .recordOnly])
        #expect(items.map(\.title) == ["This Mac", "Cloud", "Record only"])
        #expect(items.map(\.accessibilityID) == [
            "livePanel.segment.localLive", "livePanel.segment.cloudLive", "livePanel.segment.recordOnly",
        ])
        #expect(items.allSatisfy { $0.isEnabled })
    }

    @Test("Four or more segments fit the 226 pt track")
    func moreThanThreeSegmentsFit() {
        let widths = ModeSegmentsLayout.widths(ideal: [62, 50, 82, 78], available: 226 - 4, spacing: 2)
        #expect(widths.count == 4)
        #expect(abs(widths.reduce(0, +) + 6 - 222) < 0.01)
        #expect(widths.allSatisfy { $0 > 0 })
    }

    // MARK: T1-MT-04

    @Test("Picker label and static state per segment")
    func pickerLabel() {
        #expect(Self.state(.thisMac).fieldLabel == "Engine")
        #expect(Self.state(.cloud).fieldLabel == "Engine")
        #expect(Self.state(.recordOnly).fieldLabel == "Transcript after Stop")
        #expect(Self.state(.cloud).isFieldStatic)
        #expect(!Self.state(.thisMac).isFieldStatic)
        #expect(!Self.state(.recordOnly).isFieldStatic)
        #expect(!Self.state(.cloud, readiness: [:]).isFieldStatic)
        #expect(Self.state(.cloud).engineName == "Diduny Cloud")
    }

    @Test("Engine menus: one group in live segments, two ordered groups in Record only")
    func menus() {
        let thisMac = Self.state(.thisMac).menu
        #expect(thisMac.groups.count == 1 && thisMac.groups[0].header == nil)
        #expect(thisMac.visibleRows.map(\.id) == ["local-whisper", "apple-speech"])
        #expect(thisMac.selectedID == "local-whisper")
        #expect(thisMac.visibleRows.map(\.subline) == [
            "Live text (preview) · no speaker labels · Large v3 Turbo, recommended",
            "Live text · no speaker labels",
        ])

        let cloudKey = Self.state(.cloud, readiness: [:]).menu
        #expect(cloudKey.visibleRows.map(\.id) == ["diduny-cloud", "elevenlabs"])
        #expect(cloudKey.visibleRows[1].subline == "Live text · no speaker labels · your key")

        let record = Self.state(.recordOnly, readiness: [:]).menu
        #expect(record.groups.map(\.header) == ["On this Mac, recommended", "Cloud"])
        #expect(record.groups[0].rows.map(\.id) == ["local-whisper", "parakeet-v3", "apple-speech"])
        #expect(record.groups[1].rows.map(\.id) == ["diduny-cloud", "elevenlabs"])
        #expect(record.selectedID == "parakeet-v3")
        #expect(!record.showsSearch)
        #expect(Self.state(.recordOnly).menu.groups[1].rows.map(\.id) == ["diduny-cloud"])
    }

    @Test("Caption follows segment and engine")
    func captions() {
        #expect(Self.state(.cloud).caption == "Live text · speaker labels")
        #expect(Self.state(.thisMac).caption == "Live text (preview) · no speaker labels")
        #expect(Self.state(.thisMac, engine: .appleSpeech).caption == "Live text · no speaker labels")
        #expect(Self.state(.recordOnly).caption == "No live text · after Stop, on this Mac")
        #expect(Self.state(.recordOnly, engine: .didunyCloud).caption
            == "No live text · after Stop, in the cloud, speaker labels")
    }

    // MARK: T1-MT-05

    @Test("Status line per segment and connection")
    func status() {
        #expect(Self.state(.thisMac).status == .init(text: "Recording live", isLive: true))
        #expect(Self.state(.cloud).status == .init(text: "Recording live", isLive: true))
        #expect(Self.state(.recordOnly).status == .init(text: "Recording, no live text", isLive: false))
        #expect(Self.state(.cloud, connection: .connecting).status == .init(text: "Connecting", isLive: false))
        #expect(Self.state(.cloud, connection: .reconnecting(attempt: 1)).status == .init(text: "Reconnecting", isLive: false))
        #expect(Self.state(.thisMac, connection: .failed("offline")).status == .init(text: "Recording offline", isLive: false))
    }

    // MARK: T1-MT-06

    @Test("Battery warning only on This Mac on battery", arguments: MeetingSegment.allCases)
    func batteryWarning(segment: MeetingSegment) {
        #expect(Self.state(segment, onBattery: true).showsBatteryWarning == (segment == .thisMac))
        #expect(!Self.state(segment, onBattery: false).showsBatteryWarning)
    }

    @Test("Battery warning follows the power source")
    func batteryFollowsPower() {
        let source = FakePowerSourceForPanel(.ac)
        let monitor = PowerSourceMonitor(source: source)
        func panel() -> MeetingPanelState {
            MeetingPanelState(
                segment: .thisMac, engines: MeetingPanelState.defaultEngines,
                readiness: FakeEngineReadinessSource(), isAppleSilicon: true,
                isOnBattery: monitor.isOnBattery, connection: .connected
            )
        }
        #expect(!panel().showsBatteryWarning)
        source.kind = .battery
        source.fire()
        #expect(panel().showsBatteryWarning)
        source.kind = .ac
        source.fire()
        #expect(!panel().showsBatteryWarning)
        #expect(MeetingPanelState.batteryWarningText == "On battery, live text on this Mac drains it fast.")
        #expect(MeetingPanelState.useCloudTitle == "Use Cloud")
    }

    // MARK: T1-MT-09

    @Test("Record only: calm box, Copy disabled")
    func recordOnlyBody() {
        let state = Self.state(.recordOnly)
        #expect(state.showsCalmBox)
        #expect(!state.isCopyEnabled)
        #expect(MeetingPanelState.calmTitle == "Recording without live text")
        #expect(MeetingPanelState.calmDetail == "Pick This Mac or Cloud to see text from now on.")
        #expect(!Self.state(.cloud).showsCalmBox)
        #expect(Self.state(.cloud).isCopyEnabled)
    }

    // MARK: T1-MT-10, T1-MT-11

    @Test("Parakeet not downloaded: warning, size subline, value stays Parakeet V3")
    func parakeetMissing() {
        let state = Self.state(.recordOnly, readiness: [.elevenLabs: .needsKey, .parakeet: .notDownloaded(bytes: Self.parakeetBytes)])
        #expect(state.engineName == "Parakeet V3")
        #expect(state.parakeetDownloadBytes == Self.parakeetBytes)
        #expect(MeetingPanelState.parakeetMissingText
            == "Parakeet V3 is not downloaded. Until it is, Whisper Large v3 Turbo makes the transcript.")
        #expect(state.downloadParakeetTitle == "Download 480 MB")
        let row = state.menu.visibleRows.first { $0.id == "parakeet-v3" }
        #expect(row?.subline == "Not downloaded, 480 MB")
        #expect(row?.isEnabled == true)
        #expect(Self.state(.recordOnly).parakeetDownloadBytes == nil)
        #expect(Self.state(.thisMac, readiness: [.parakeet: .notDownloaded(bytes: Self.parakeetBytes)]).parakeetDownloadBytes == nil)
    }

    @Test("Intel Mac: Record only shows Whisper and no Parakeet row")
    func intelRecordOnly() {
        let state = Self.state(.recordOnly, readiness: [.elevenLabs: .needsKey, .parakeet: .unsupportedHardware], appleSilicon: false)
        #expect(state.engine == .whisper)
        #expect(state.engineName == "Whisper")
        #expect(!state.menu.visibleRows.map(\.id).contains("parakeet-v3"))
        #expect(state.parakeetDownloadBytes == nil)
    }

    // MARK: T1-MT-15

    @Test("No Diduny quota: row disabled with reason; Cloud segment disabled without a key")
    func noQuota() {
        let withKey = Self.state(.cloud, engine: .elevenLabs, readiness: [.didunyCloud: .noQuota])
        let row = withKey.menu.visibleRows.first { $0.id == "diduny-cloud" }
        #expect(row?.isEnabled == false)
        #expect(row?.subline == "Diduny quota used up")
        #expect(withKey.segments.first { $0.id == .cloud }?.isEnabled == true)

        let noKey = Self.state(.thisMac, readiness: [.didunyCloud: .noQuota, .elevenLabs: .needsKey])
        #expect(noKey.segments.first { $0.id == .cloud }?.isEnabled == false)
    }

    // MARK: T1-MT-13

    @Test("Speaker label lines, no timestamps; plain paragraphs without labels")
    func transcriptLines() {
        let turns: [MeetingTranscriptLines.Turn] = [
            .init(speaker: "1", text: "Hello there."),
            .init(speaker: "1", text: "Still me."),
            .init(speaker: "2", text: "Hi."),
        ]
        let labelled = MeetingTranscriptLines.make(turns: turns, speakerLabels: true)
        #expect(labelled == [
            .speaker("Speaker 1"), .text("Hello there."), .text("Still me."),
            .speaker("Speaker 2"), .text("Hi."),
        ])
        let plain = MeetingTranscriptLines.make(turns: turns, speakerLabels: false)
        #expect(plain == [.text("Hello there."), .text("Still me."), .text("Hi.")])
        #expect(!labelled.contains { if case let .text(t) = $0 { t.contains("[00:") } else { false } })
    }
}

/// Power source driven by the test.
@MainActor
final class FakePowerSourceForPanel: PowerSource {
    var kind: PowerSourceKind
    private var onChange: (@MainActor () -> Void)?

    init(_ kind: PowerSourceKind) { self.kind = kind }

    var current: PowerSourceKind { kind }
    func startObserving(_ onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
    func fire() { onChange?() }
}
