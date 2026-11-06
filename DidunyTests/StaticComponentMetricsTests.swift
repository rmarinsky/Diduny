import AppKit
@testable import Diduny
import SwiftUI
import Testing

/// WP-21 component metrics (docs/design/panels-and-capabilities-redesign/design-spec.md 3.2, 10.3):
/// the numbers the plan files under "extend DesignSystemMetricsTests.swift". They live here so
/// WP-20 stays the only writer of that file. Sizes come from `NSHostingView.fittingSize`, ±1 pt,
/// because text metrics differ a little between font versions on CI runners.
@MainActor
struct StaticComponentMetricsTests {
    private static let tolerance: CGFloat = 1

    /// A window that is never shown and reports a Retina backing scale. SwiftUI snaps text and
    /// frames to the pixel grid of the window's scale (whole points without a window), so this
    /// measures what a 2x Mac draws, whatever display the runner has (spec 10.3: ±2 px at 2x).
    private final class RetinaMeasuringWindow: NSWindow {
        override var backingScaleFactor: CGFloat { 2 }
    }

    private func size(_ view: some View, width: CGFloat? = nil) -> CGSize {
        let host = NSHostingView(rootView: view.frame(width: width))
        let window = RetinaMeasuringWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        return host.fittingSize
    }

    /// How much wider `text` is in the rounded design than in the system design. The prototype
    /// measured keyboard glyphs in the system font; D17 draws them rounded.
    private func roundedExtraWidth(_ text: String, size: CGFloat) -> CGFloat {
        let rounded = self.size(Text(verbatim: text).font(.system(size: size, weight: .semibold, design: .rounded))).width
        let system = self.size(Text(verbatim: text).font(.system(size: size, weight: .semibold))).width
        return rounded - system
    }

    private func expectNear(_ actual: CGFloat, _ expected: CGFloat, _ what: String) {
        #expect(abs(actual - expected) <= Self.tolerance, "\(what): \(actual), expected \(expected)")
    }

    // MARK: - Mode segments (4.3)

    @Test("Mode segment track is 34 high and a segment 30")
    func modeSegmentHeights() {
        let segments = ModeSegments(
            items: [.init(id: 0, title: "This Mac"), .init(id: 1, title: "Cloud"), .init(id: 2, title: "Record only")],
            selection: .constant(1)
        )
        expectNear(size(segments, width: 226).height, DS.Size.segmentTrack, "track height")
        expectNear(size(ModeSegmentButton(title: "Cloud", isSelected: true) {}).height, DS.Size.segment, "segment height")
    }

    @Test("Mode segments in a 226 pt track are 73.1, 55.3 and 89.6 wide")
    func modeSegmentWidths() {
        let ideal = ["This Mac", "Cloud", "Record only"].map { title in
            size(ModeSegmentButton(title: LocalizedStringKey(title), isSelected: false) {}).width
        }
        let widths = ModeSegmentsLayout.widths(
            ideal: ideal,
            available: 226 - DS.Size.segmentInset * 2,
            spacing: DS.Size.segmentInset
        )
        #expect(widths.count == 3)
        for (actual, expected) in zip(widths, [73.1, 55.3, 89.6] as [CGFloat]) {
            expectNear(actual, expected, "segment width")
        }
    }

    // MARK: - Panel buttons (4.4, 4.5)

    @Test("Copy and Stop share a 274 pt row as 102 and 164, both 38 high")
    func copyAndStopSizes() {
        let widths = PanelControlsLayout.widths(available: DS.Panel.contentWidth, weights: [1, 1.6], spacing: DS.Space.sm)
        expectNear(widths[0], 102, "Copy width")
        expectNear(widths[1], 164, "Stop width")

        let copy = size(CopyButton(isCopied: false) {}, width: widths[0])
        expectNear(copy.height, DS.Size.panelButton, "Copy height")
        let stop = StopButton(cancelHint: "Cancel: Esc ×3", shortcut: "⌥ ×2", accessibilityHint: "") {}
        expectNear(size(stop, width: widths[1]).height, DS.Size.panelButton, "Stop height")
        // The Stop content must fit its 164 pt share without squeezing.
        #expect(size(stop).width <= widths[1] + Self.tolerance)
    }

    @Test("Two equal panel buttons in a 274 pt row are 133 each")
    func equalPanelButtons() {
        let widths = PanelControlsLayout.widths(available: DS.Panel.contentWidth, weights: [1, 1], spacing: DS.Space.sm)
        expectNear(widths[0], 133, "left")
        expectNear(widths[1], 133, "right")
        expectNear(size(PanelButton(title: "New recording", role: .primary) {}, width: 133).height,
                   DS.Size.panelButton, "button height")
    }

    @Test("Stop keycap is 20 high and 37.9 wide for ⌥ ×2")
    func keycap() {
        let keycap = size(Keycap(text: "⌥ ×2"))
        expectNear(keycap.height, DS.Size.keycapHeight, "keycap height")
        expectNear(keycap.width, 37.9, "keycap width")
    }

    // MARK: - Command tile (4.6)

    @Test("Tile is 47 high with a one-line title and 62 with two lines, in 133 pt")
    func tileHeights() {
        let oneLine = CommandTile(symbol: "mic", title: "Transcribe", caption: "Voice → text") {}
        let twoLines = CommandTile(symbol: "person.2", title: "Record meeting", caption: "System + mic") {}
        expectNear(size(oneLine, width: 133).height, DS.Size.tileOneLine, "one-line tile")
        expectNear(size(twoLines, width: 133).height, DS.Size.tileTwoLines, "two-line tile")
    }

    // MARK: - Header (4.7)

    @Test("Panel header is 29 high; icon tile 28, icon button 26")
    func headerHeights() {
        let header = PanelHeader(
            icon: PanelIconTile(symbol: "person.2"),
            title: "Recording meeting",
            status: .live("Recording live")
        ) {
            PanelTimer(text: "06:22")
            PanelIconButton(kind: .minimize) {}
        }
        expectNear(size(header, width: DS.Panel.contentWidth).height, 29, "header height")
        let tile = size(PanelIconTile(symbol: "mic"))
        expectNear(tile.width, DS.Size.iconTile, "icon tile width")
        expectNear(tile.height, DS.Size.iconTile, "icon tile height")
        let button = size(PanelIconButton(kind: .close) {})
        expectNear(button.width, DS.Size.iconButton, "icon button width")
        expectNear(button.height, DS.Size.iconButton, "icon button height")
    }

    // MARK: - Marks (4.8)

    @Test("Marks are 20 x 20 in tables and 16 x 16 in the legend", arguments: CapabilityMark.Kind.allCases)
    func marks(kind: CapabilityMark.Kind) {
        let table = size(CapabilityMark(kind: kind))
        expectNear(table.width, DS.Size.mark, "table mark width")
        expectNear(table.height, DS.Size.mark, "table mark height")
        let legend = size(CapabilityMark(kind: kind, size: DS.Size.legendMark))
        expectNear(legend.width, DS.Size.legendMark, "legend mark width")
        expectNear(legend.height, DS.Size.legendMark, "legend mark height")
    }

    // MARK: - Settings rows (4.10)

    enum RowCase: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case labelAndSwitch, labelAndSegmented, labelAndButton, labelAndPopUp, labelCaptionControl, labelTwoLineCaption

        var expectedHeight: CGFloat {
            switch self {
            case .labelAndSwitch: 39
            case .labelAndSegmented: 42
            case .labelAndButton: 44
            case .labelAndPopUp: 47
            case .labelCaptionControl: 53.1
            case .labelTwoLineCaption: 69.2
            }
        }

        var testDescription: String { rawValue }

        @MainActor @ViewBuilder var row: some View {
            switch self {
            case .labelAndSwitch:
                SettingsLineRow(title: "Launch at login", kind: .toggle) {
                    SettingsSwitch(title: "Launch at login", isOn: .constant(true))
                }
            case .labelAndSegmented:
                SettingsLineRow(title: "Press count", kind: .segmented) {
                    ShortcutPressCountPicker(selection: .constant(2))
                }
            case .labelAndButton:
                SettingsLineRow(title: "Setup guide", kind: .button) {
                    Button("Open") {}.buttonStyle(.bordered)
                }
            case .labelAndPopUp:
                SettingsLineRow(title: "Keep dictations", kind: .popUp) {
                    Picker("Keep dictations", selection: .constant(1)) {
                        Text(verbatim: "30 days").tag(1)
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
            case .labelCaptionControl:
                SettingsLineRow(title: "Paste automatically", caption: "Puts the text where your cursor is", kind: .toggle) {
                    SettingsSwitch(title: "Paste automatically", isOn: .constant(true))
                }
            case .labelTwoLineCaption:
                SettingsLineRow(
                    title: "Delete expired recordings",
                    caption: "Removes audio and text after the time above.\nRecordings you starred stay.",
                    kind: .toggle
                ) {
                    SettingsSwitch(title: "Delete expired recordings", isOn: .constant(false))
                }
            }
        }
    }

    @Test("Settings row heights match the prototype", arguments: RowCase.allCases)
    func settingsRowHeight(_ row: RowCase) {
        expectNear(size(row.row, width: 713.5).height, row.expectedHeight, row.rawValue)
    }

    // MARK: - Other fixed sizes (3.2)

    @Test("Shortcut field is 25 high, at least 58 wide, 63.9 for ⇧⌥⌘M plus the D17 rounded-font difference")
    func shortcutField() {
        let short = size(ShortcutField(shortcut: "⌥D", rowLabel: "Dictation"))
        expectNear(short.height, DS.Size.shortcutFieldHeight, "field height")
        expectNear(short.width, DS.Size.shortcutFieldMinWidth, "minimum width")
        expectNear(size(ShortcutField(shortcut: "⇧⌥⌘M", rowLabel: "Meeting")).width,
                   63.9 + roundedExtraWidth("⇧⌥⌘M", size: 12), "four-glyph width")
    }

    @Test("Header link 23, progress row 38, progress bar 4, expander 26, trash 24, preview 132 x 78")
    func fixedSizes() {
        expectNear(size(HeaderLink(title: "Recordings") {}).height, DS.Size.headerLink, "header link")
        expectNear(size(ProgressRow(line: "Saving the recording...", fraction: 0.4), width: 274).height,
                   DS.Size.panelButton, "progress row")
        expectNear(size(PanelProgressBar(fraction: 0.4), width: 274).height, DS.Size.progressBar, "progress bar")
        expectNear(size(ExpanderButton(isExpanded: false, accessibilityLabel: "Dictation options") {}).height,
                   DS.Size.expander, "expander")
        expectNear(size(TrashButton(accessibilityLabel: "Delete Base") {}).height, DS.Size.trash, "trash")
        let preview = size(SurfacePreviewDrawing(kind: .floatingPanel))
        expectNear(preview.width, 132, "preview width")
        expectNear(preview.height, 78, "preview height")
    }

    @Test("Transcript and calm boxes are 170 for meetings and 120 for dictation")
    func boxHeights() {
        expectNear(size(TranscriptBox(height: DS.Size.transcriptMeeting) { Text(verbatim: "Hello") }, width: 274).height,
                   170, "meeting transcript")
        expectNear(size(CalmBox(title: "Recording", detail: "No live text.", height: DS.Size.transcriptDictation), width: 274).height,
                   120, "dictation calm box")
    }
}
