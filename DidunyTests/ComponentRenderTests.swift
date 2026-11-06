import AppKit
@testable import Diduny
import SwiftUI
import Testing

/// Renders every WP-21 component in light and dark for the designer's review against
/// prototype v9. No pixel assertion: the test only checks that a non-empty PNG was made.
/// PNGs go to `$SCREENSHOT_DIR/components` (the runner strips `TEST_RUNNER_` from
/// `TEST_RUNNER_SCREENSHOT_DIR`); without it they are rendered and dropped. Rendered without
/// presenting a window, as `VoiceTranslationTests` does, so it needs no UI-test gate.
@MainActor
struct ComponentRenderTests {
    enum Appearance: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case light, dark
        var name: NSAppearance.Name { self == .light ? .aqua : .darkAqua }
        var testDescription: String { rawValue }
    }

    enum Sample: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case modeSegments, controlsRow, panelButtons, commandTiles, headers, marks
        case settingsRows, shortcutFields, progress, notices, boxes, links, previews

        var testDescription: String { rawValue }

        /// Panel components sit on `panel`, Settings components on `window`.
        var background: Color {
            switch self {
            case .settingsRows, .shortcutFields, .marks, .previews: DS.Palette.window
            default: DS.Palette.panel
            }
        }

        var width: CGFloat {
            switch self {
            case .settingsRows: 713.5
            case .marks, .previews, .shortcutFields: 420
            default: DS.Panel.contentWidth
            }
        }

        @MainActor @ViewBuilder var view: some View {
            switch self {
            case .modeSegments: ComponentGallery.modeSegments
            case .controlsRow: ComponentGallery.controlsRow
            case .panelButtons: ComponentGallery.panelButtons
            case .commandTiles: ComponentGallery.commandTiles
            case .headers: ComponentGallery.headers
            case .marks: ComponentGallery.marks
            case .settingsRows: ComponentGallery.settingsRows
            case .shortcutFields: ComponentGallery.shortcutFields
            case .progress: ComponentGallery.progress
            case .notices: ComponentGallery.notices
            case .boxes: ComponentGallery.boxes
            case .links: ComponentGallery.links
            case .previews: ComponentGallery.previews
            }
        }
    }

    private static let outputDirectory: URL? = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"]
        .map { URL(fileURLWithPath: $0).appendingPathComponent("components", isDirectory: true) }

    @Test("Component renders to a PNG", arguments: Sample.allCases, Appearance.allCases)
    func render(_ sample: Sample, _ appearance: Appearance) throws {
        let content = sample.view
            .frame(width: sample.width, alignment: .leading)
            .padding(DS.Panel.padding)
            .background(sample.background)
        let host = NSHostingView(rootView: content)
        host.appearance = NSAppearance(named: appearance.name)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(!png.isEmpty)
        #expect(host.bounds.width > 0 && host.bounds.height > 0)

        if let directory = Self.outputDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("\(sample.rawValue)-\(appearance.rawValue).png"))
        }
    }
}

/// The states each PNG shows. Strings are sample data, not app copy.
@MainActor
private enum ComponentGallery {
    static func caption(_ text: String) -> some View {
        Text(verbatim: text).font(DS.Font.caption).foregroundStyle(DS.Palette.secondary)
    }

    static var modeSegments: some View {
        VStack(alignment: .leading, spacing: 10) {
            caption("226 pt track, Cloud selected")
            ModeSegments(items: segmentItems(cloudEnabled: true), selection: .constant("cloudLive"))
                .frame(width: 226)
            caption("Record only selected, Cloud disabled")
            ModeSegments(items: segmentItems(cloudEnabled: false), selection: .constant("recordOnly"))
                .frame(width: 226)
            caption("Full width (prompt)")
            ModeSegments(items: segmentItems(cloudEnabled: true), selection: .constant("localLive"))
        }
    }

    static func segmentItems(cloudEnabled: Bool) -> [ModeSegments<String>.Item] {
        [
            .init(id: "localLive", title: "This Mac", accessibilityID: "livePanel.segment.localLive"),
            .init(id: "cloudLive", title: "Cloud", isEnabled: cloudEnabled, accessibilityID: "livePanel.segment.cloudLive"),
            .init(id: "recordOnly", title: "Record only", accessibilityID: "livePanel.segment.recordOnly"),
        ]
    }

    static var controlsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            caption("Copy + Stop")
            PanelControlsLayout(weights: [1, 1.6]) {
                CopyButton(isCopied: false) {}
                StopButton(cancelHint: "Cancel: Esc ×3", shortcut: "⌥ ×2", accessibilityHint: "") {}
            }
            caption("Copied; Stop with no shortcuts")
            PanelControlsLayout(weights: [1, 1.6]) {
                CopyButton(isCopied: true) {}
                StopButton(cancelHint: nil, shortcut: nil, accessibilityHint: "") {}
            }
            caption("Copy disabled; Stop disabled")
            PanelControlsLayout(weights: [1, 1.6]) {
                CopyButton(isCopied: false) {}.disabled(true)
                StopButton(cancelHint: "Cancel: Esc ×3", shortcut: "⌥ ×2", accessibilityHint: "") {}.disabled(true)
            }
        }
    }

    static var panelButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            caption("Outcome: Copy + New recording")
            PanelControlsLayout(weights: [1, 1]) {
                CopyButton(isCopied: false) {}
                PanelButton(title: "New recording") {}
            }
            caption("Meeting outcome / prompt: primary + neutral")
            PanelControlsLayout(weights: [1, 1]) {
                PanelButton(title: "Not now") {}
                PanelButton(title: "Start recording", role: .primary) {}
            }
        }
    }

    static var commandTiles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(horizontalSpacing: DS.Space.sm, verticalSpacing: DS.Space.sm) {
                GridRow {
                    CommandTile(symbol: "mic", title: "Transcribe", caption: "Voice → text") {}
                    CommandTile(symbol: "globe", title: "Translate", caption: "Voice → English") {}
                }
                GridRow {
                    CommandTile(symbol: "person.2", title: "Record meeting", caption: "System + mic") {}
                    CommandTile(symbol: "person.2", title: "Translate meeting", caption: "Live · EN ↔ UK") {}
                }
            }
            caption("Disabled (signed out)")
            Grid(horizontalSpacing: DS.Space.sm) {
                GridRow {
                    CommandTile(symbol: "mic", title: "Transcribe", caption: "Voice → text") {}.disabled(true)
                    CommandTile(symbol: "globe", title: "Translate", caption: "Voice → English") {}.disabled(true)
                }
            }
        }
    }

    static var headers: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelHeader(icon: PanelIconTile(symbol: "person.2"), title: "Recording meeting", status: .live("Recording live")) {
                PanelTimer(text: "06:22")
                PanelIconButton(kind: .minimize) {}
            }
            PanelHeader(icon: PanelIconTile(symbol: "person.2", hasGlobeBadge: true), title: "Translating meeting",
                        status: .plain("Recording · no live text")) {
                PanelTimer(text: "00:58", isWarning: true)
                PanelIconButton(kind: .minimize) {}
            }
            PanelHeader(icon: PanelIconTile(symbol: "mic", symbolSize: 14), title: "Diduny") {
                HeaderLink(title: "Recordings") {}
                HeaderLink(title: "Settings") {}
                PanelIconButton(kind: .close) {}
            }
            PanelHeader(icon: PanelIconTile(symbol: "checkmark", style: .ok, pulsesOnAppear: true),
                        title: "Pasted into Notes", status: .plain("7 s · also in Recordings")) {
                PanelIconButton(kind: .close) {}
            }
            PanelHeader(icon: PanelIconTile(symbol: "mic"), title: "Dictating", status: .error("Connection lost")) {
                PanelIconButton(kind: .minimize) {}
            }
        }
    }

    static var marks: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ForEach(CapabilityMark.Kind.allCases, id: \.self) { CapabilityMark(kind: $0) }
            }
            HStack(spacing: 22) {
                ForEach(CapabilityMark.Kind.allCases, id: \.self) { kind in
                    HStack(spacing: 6) {
                        CapabilityMark(kind: kind, size: DS.Size.legendMark)
                        caption(kind.rawValue)
                    }
                }
            }
            HStack(spacing: 12) {
                CapabilityMark(kind: .yes).padding(8).background(DS.Palette.tint)
                CapabilityMark(kind: .byDiduny).padding(8).background(DS.Palette.tint)
                CapabilityMark(kind: .no).padding(8).background(DS.Palette.tint)
            }
        }
    }

    static var settingsRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "General").font(DS.Font.groupHeading).foregroundStyle(DS.Palette.text).padding(.bottom, 2)
            SettingsLineRow(title: "Launch at login", kind: .toggle) {
                SettingsSwitch(title: "Launch at login", isOn: .constant(true))
            }
            SettingsLineRow(title: "Paste automatically", caption: "Puts the text where your cursor is", kind: .toggle) {
                SettingsSwitch(title: "Paste automatically", isOn: .constant(false))
            }
            SettingsLineRow(title: "Keep dictations", kind: .popUp) {
                Picker("Keep dictations", selection: .constant(1)) { Text(verbatim: "30 days").tag(1) }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            SettingsLineRow(title: "Setup guide", kind: .button) {
                Button("Open") {}.buttonStyle(.bordered)
            }
            SettingsLineRow(title: "Press count", kind: .segmented) {
                ShortcutPressCountPicker(selection: .constant(2))
            }
            SettingsLineRow(title: "Delete expired recordings",
                            caption: "Removes audio and text after the time above.\nRecordings you starred stay.",
                            kind: .toggle) {
                SettingsSwitch(title: "Delete expired recordings", isOn: .constant(true))
            }
            SettingsLineRow(title: "Dictation", showsHairline: false) {
                ExpanderButton(isExpanded: false, accessibilityLabel: "Dictation options") {}
                ExpanderButton(isExpanded: true, accessibilityLabel: "Dictation options") {}
                TrashButton(accessibilityLabel: "Delete Base") {}
            }
        }
    }

    static var shortcutFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ShortcutField(shortcut: "⌥⌘D", rowLabel: "Dictation")
                ShortcutPressCountPicker(selection: .constant(1))
                SettingsSwitch(title: "Dictation", isOn: .constant(true))
            }
            HStack(spacing: 8) {
                ShortcutField(shortcut: "⇧⌥⌘M", rowLabel: "Meeting", isRecording: true)
                caption("recording")
            }
            HStack(spacing: 8) {
                ShortcutField(shortcut: "⌘,", rowLabel: "Open Settings").disabled(true)
                caption("disabled")
            }
            HStack(spacing: 8) {
                ShortcutField(shortcut: "⌥⌘T", rowLabel: "Translation", isOff: true)
                ShortcutPressCountPicker(selection: .constant(2), isOff: true)
                SettingsSwitch(title: "Translation", isOn: .constant(false))
                caption("off")
            }
            HStack(spacing: 8) {
                ShortcutField(shortcut: nil, rowLabel: "Force submit")
                caption("not set")
            }
        }
    }

    static var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressRow(line: "Finishing the last words...", fraction: 0.35)
            ProgressRow(line: "Saving the recording...", fraction: 0.8)
            PanelProgressBar(fraction: 0.5)
        }
    }

    static var notices: some View {
        VStack(alignment: .leading, spacing: 10) {
            NoticeRow(text: "Sign in to record.", buttonTitle: "Sign in") {}
            WarningLine(message: "On battery, live text on this Mac drains it fast.", linkTitle: "Use Cloud") {}
            WarningLine(message: "Parakeet V3 is not downloaded. Until it is, Whisper Large v3 Turbo makes the transcript.",
                        linkTitle: "Download 480 MB") {}
        }
    }

    static var boxes: some View {
        VStack(alignment: .leading, spacing: 10) {
            TranscriptBox(height: DS.Size.transcriptDictation) {
                Text(verbatim: "Yes, I will have the regression pass done by Thursday.")
                Text(verbatim: "One risk: the notarization queue was slow last week.")
            }
            CalmBox(title: "Recording without live text",
                    detail: "Pick This Mac or Cloud to see text from now on.",
                    height: DS.Size.transcriptDictation)
            ResultBox(text: "Yes, by the way, I want to refresh the window view now.")
            ResultBox(text: String(repeating: "A long result that has to scroll inside the box once it passes 170 points. ", count: 12))
        }
    }

    static var links: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                HeaderLink(title: "Recordings") {}
                HeaderLink(title: "Settings") {}
            }
            HeaderLink(title: "Batch files & URLs") {}.frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                Text(verbatim: "Live text · speaker labels").font(DS.Font.meta).foregroundStyle(DS.Palette.secondary)
                Spacer()
                InlineLink(title: "Show original text") {}.font(DS.Font.meta)
            }
            InlineLink(title: "60 languages", showsChevron: true) {}.font(DS.Font.callout)
        }
    }

    static var previews: some View {
        HStack(spacing: 10) {
            SurfacePreviewTile(kind: .floatingPanel, isSelected: true) {}
            SurfacePreviewTile(kind: .dynamicNotch, isSelected: false) {}
        }
    }
}
