import SwiftUI

// MARK: - State

/// What the meeting live panel shows (design-spec 7.1, changes/01 section 2). Pure: inputs in, strings out.
/// The segment row lays out any count, but the segments come from `MeetingSegment` and its exhaustive switches,
/// so a fourth segment also needs a new case there.
@MainActor
struct MeetingPanelState {
    struct Segment: Equatable {
        let id: MeetingSegment
        let title: String
        let isEnabled: Bool
        let accessibilityID: String
    }

    struct Status: Equatable {
        let text: String
        /// Accent dot before the text (`livePanel.status` value `live`).
        let isLive: Bool
    }

    /// Defaults per segment until WP-13 supplies the Settings > Modes values (Proto:499).
    static let defaultEngines: [MeetingSegment: EngineID] = [
        .thisMac: .whisper, .cloud: .didunyCloud, .recordOnly: .parakeet,
    ]

    static var batteryWarningText: String { String(localized: "On battery, live text on this Mac drains it fast.") }
    static var useCloudTitle: String { String(localized: "Use Cloud") }
    static var calmTitle: String { String(localized: "Recording without live text") }
    static var calmDetail: String { String(localized: "To see text from now on, use Turn on live transcript below.") }
    static var parakeetMissingText: String {
        String(localized: "Parakeet V3 is not downloaded. Until it is, Whisper Large v3 Turbo makes the transcript.")
    }

    let segment: MeetingSegment
    let segments: [Segment]
    /// The engine the segment runs (Parakeet on an Intel Mac shows Whisper).
    let engine: EngineID
    let engineName: String
    let fieldLabel: String
    let isFieldStatic: Bool
    let menu: PickerMenuModel
    let caption: String
    let status: Status
    let showsBatteryWarning: Bool
    /// The battery warning's "Use Cloud" link; hidden while switching is locked (until WP-63, decision 1A).
    let showsUseCloudLink: Bool
    /// Set when Record only uses Parakeet V3 and it is not downloaded.
    let parakeetDownloadBytes: Int64?

    var showsCalmBox: Bool { segment == .recordOnly }
    var isCopyEnabled: Bool { segment != .recordOnly }

    var downloadParakeetTitle: String? {
        parakeetDownloadBytes.map { bytes in
            let size = bytes.formatted(.byteCount(style: .file).locale(EngineLanguages.appLocale))
            return String(localized: "Download \(size)")
        }
    }

    init(
        segment: MeetingSegment,
        engines: [MeetingSegment: EngineID],
        switchingLocked: Bool = false,
        readiness: any EngineReadinessSource,
        isAppleSilicon: Bool = ParakeetModelStore.isSupportedHardware,
        isOnBattery: Bool,
        connection: RealtimeConnectionStatus,
        capabilities: (EngineID) -> EngineCapabilities? = MeetingPanelState.registryCapabilities
    ) {
        func ready(_ id: EngineID) -> EngineReadiness { readiness.readiness(of: id) }
        /// Hidden: a key engine without a key, Parakeet on Intel (decision 6).
        func offered(_ id: EngineID) -> Bool {
            switch ready(id) {
            case .needsKey: false
            case .unsupportedHardware: id != .parakeet
            default: !(id == .parakeet && !isAppleSilicon)
            }
        }
        func usable(_ id: EngineID) -> Bool {
            switch ready(id) {
            case .ready: true
            case .notDownloaded: id == .parakeet
            default: false
            }
        }
        func groups(_ seg: MeetingSegment) -> [(id: String, header: String?, engines: [EngineID])] {
            switch seg {
            case .thisMac: [("engines", nil, [.whisper, .appleSpeech].filter(offered))]
            case .cloud: [("engines", nil, [.didunyCloud, .elevenLabs].filter(offered))]
            case .recordOnly: [
                ("onThisMac", String(localized: "On this Mac, recommended"), [.whisper, .parakeet, .appleSpeech].filter(offered)),
                ("cloud", String(localized: "Cloud"), [.didunyCloud, .elevenLabs].filter(offered)),
            ]
            }
        }

        self.segment = segment
        segments = MeetingSegment.allCases.map { seg in
            Segment(
                id: seg,
                title: EngineCaptions.startsIn(seg).title,
                isEnabled: switchingLocked ? seg == segment : groups(seg).flatMap(\.engines).contains(where: usable),
                accessibilityID: "livePanel.segment." + Self.testID(seg)
            )
        }

        let list = groups(segment)
        let all = list.flatMap(\.engines)
        let picked = engines[segment] ?? Self.defaultEngines[segment] ?? .didunyCloud
        let resolved = all.contains(picked) ? picked : (segment == .recordOnly && picked == .parakeet ? .whisper : all.first ?? picked)
        engine = resolved
        engineName = Self.name(resolved)
        fieldLabel = segment == .recordOnly ? String(localized: "Transcript after Stop") : String(localized: "Engine")
        isFieldStatic = switchingLocked || all.count <= 1

        menu = PickerMenuModel(
            groups: list.map { group in
                PickerMenuGroup(id: group.id, header: group.header, rows: group.engines.map { id in
                    let state = ready(id)
                    let subline: String? = if usable(id) {
                        capabilities(id).map {
                            EngineCaptions.meetingPanelMenuSubline(segment: segment, caps: $0, readiness: state)
                        }
                    } else {
                        Self.reason(state)
                    }
                    return PickerMenuRow(id: id.rawValue, title: Self.name(id), subline: subline, isEnabled: usable(id))
                })
            },
            selectedID: resolved.rawValue
        )
        caption = capabilities(resolved).map { EngineCaptions.meetingPanelCaption(segment: segment, caps: $0) } ?? ""

        if segment == .recordOnly {
            status = Status(text: String(localized: "Recording, no live text"), isLive: false)
        } else {
            switch connection {
            case .connected: status = Status(text: String(localized: "Recording live"), isLive: true)
            case .connecting: status = Status(text: String(localized: "Connecting"), isLive: false)
            case .reconnecting: status = Status(text: String(localized: "Reconnecting"), isLive: false)
            case .failed: status = Status(text: String(localized: "Recording offline"), isLive: false)
            case .disconnected: status = Status(text: String(localized: "Recording"), isLive: false)
            }
        }
        showsBatteryWarning = segment == .thisMac && isOnBattery
        showsUseCloudLink = !switchingLocked
        if segment == .recordOnly, resolved == .parakeet, case let .notDownloaded(bytes) = ready(.parakeet) {
            parakeetDownloadBytes = bytes
        } else {
            parakeetDownloadBytes = nil
        }
    }

    static func registryCapabilities(_ id: EngineID) -> EngineCapabilities? {
        ProviderRegistry.shared.module(id: id.rawValue).flatMap {
            EngineCapabilities.make($0, activeWhisperModel: nil)
        }
    }

    /// Test-plan 2.1 segment ids.
    static func testID(_ segment: MeetingSegment) -> String {
        switch segment {
        case .thisMac: "localLive"
        case .cloud: "cloudLive"
        case .recordOnly: "recordOnly"
        }
    }

    /// Panel names (Proto `ENG`); proper nouns, not localized.
    static func name(_ id: EngineID) -> String {
        switch id {
        case .didunyCloud: "Diduny Cloud"
        case .elevenLabs: "ElevenLabs"
        case .whisper: "Whisper"
        case .parakeet: "Parakeet V3"
        case .appleSpeech: "Apple Speech"
        }
    }

    /// Disabled row subline (01 section 2 states).
    private static func reason(_ readiness: EngineReadiness) -> String {
        switch readiness {
        case .noQuota: String(localized: "Diduny quota used up")
        case .notDownloaded: String(localized: "Download a local Whisper model in Settings.")
        case .signedOut: String(localized: "Sign in to record.")
        case .ready, .needsKey, .unsupportedHardware, .unavailable: String(localized: "Not available on this Mac")
        }
    }
}

// MARK: - Transcript lines

/// Live meeting transcript as label lines and paragraphs, no timestamps (01 section 2 item 6).
/// Marker lines ("06:22 · switched to Cloud") are appended by WP-63.
enum MeetingTranscriptLines {
    enum Line: Equatable {
        case speaker(String)
        case text(String)
        case marker(String)
    }

    struct Turn: Equatable {
        let speaker: String?
        let text: String
    }

    static func make(turns: [Turn], speakerLabels: Bool, markers: [Line] = []) -> [Line] {
        var lines: [Line] = []
        var lastSpeaker: String?
        for turn in turns {
            let text = turn.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if speakerLabels, let speaker = turn.speaker, speaker != lastSpeaker {
                lines.append(.speaker(label(speaker)))
                lastSpeaker = speaker
            }
            lines.append(.text(text))
        }
        return lines + markers
    }

    static func label(_ speaker: String) -> String {
        Int(speaker).map { String(localized: "Speaker \($0)") } ?? speaker
    }
}

// MARK: - View

/// Meeting rows of the live panel: waveform and segments, engine block, body. The shell (WP-30) draws the
/// header (status from `state.status`) and the controls (Copy enabled from `state.isCopyEnabled`).
struct MeetingLiveContent<Waveform: View>: View {
    let state: MeetingPanelState
    let lines: [MeetingTranscriptLines.Line]
    @Binding var segment: MeetingSegment
    let onPickEngine: (EngineID) -> Void
    let onDownloadParakeet: () -> Void
    /// Record only: streams the rest of the meeting to Cloud (nil hides the link).
    var onTurnOnLiveTranscript: (() -> Void)?
    /// The 38 pt waveform circle (`LiveWaveformCircle` draws its own frame, tint and identifier).
    @ViewBuilder let waveform: () -> Waveform

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Panel.blockGap) {
            HStack(spacing: DS.Panel.blockGap) {
                waveform()
                ModeSegments(
                    items: state.segments.map {
                        .init(id: $0.id, title: LocalizedStringKey($0.title), isEnabled: $0.isEnabled, accessibilityID: $0.accessibilityID)
                    },
                    selection: $segment
                )
            }
            engineBlock
            if state.showsCalmBox {
                CalmBox(
                    title: LocalizedStringKey(MeetingPanelState.calmTitle),
                    detail: LocalizedStringKey(MeetingPanelState.calmDetail),
                    height: DS.Size.transcriptMeeting,
                    action: onTurnOnLiveTranscript.map {
                        (title: "Turn on live transcript", id: "livePanel.turnOnLiveTranscript", run: $0)
                    }
                )
            } else {
                TranscriptBox(height: DS.Size.transcriptMeeting) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in lineView(line) }
                }
            }
        }
    }

    private var engineBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.isFieldStatic {
                PickerField(staticLabel: LocalizedStringKey(state.fieldLabel), value: state.engineName, layout: .stacked, identifier: "livePanel.engine")
            } else {
                PickerField(
                    label: LocalizedStringKey(state.fieldLabel), value: state.engineName, layout: .stacked,
                    identifier: "livePanel.engine", menu: { state.menu },
                    onPick: { id in EngineID(rawValue: id).map(onPickEngine) }
                )
            }
            Text(verbatim: state.caption)
                .font(DS.Font.meta)
                .foregroundStyle(DS.Palette.secondary)
                .lineSpacing(DS.Font.LineSpacing.meta)
                .padding(.top, 6)
                .accessibilityIdentifier("livePanel.caption")
            if state.showsBatteryWarning {
                WarningLine(
                    message: MeetingPanelState.batteryWarningText,
                    linkTitle: state.showsUseCloudLink ? MeetingPanelState.useCloudTitle : nil,
                    action: { segment = .cloud }, id: "livePanel.batteryWarning", linkID: "livePanel.useCloud"
                )
            }
            if let download = state.downloadParakeetTitle {
                WarningLine(
                    message: MeetingPanelState.parakeetMissingText, linkTitle: download,
                    action: onDownloadParakeet, id: "livePanel.parakeetMissing", linkID: "livePanel.downloadParakeet"
                )
            }
        }
    }

    @ViewBuilder private func lineView(_ line: MeetingTranscriptLines.Line) -> some View {
        switch line {
        case let .speaker(label):
            Text(verbatim: label)
                .font(DS.Font.captionStrong)
                .foregroundStyle(DS.Palette.accentText)
                .accessibilityIdentifier("livePanel.speakerLine")
        case let .text(text):
            Text(verbatim: text)
        case let .marker(text):
            Text(verbatim: text)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.secondary)
                .accessibilityIdentifier("livePanel.marker")
        }
    }
}
