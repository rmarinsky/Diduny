import SwiftUI

/// "Looks like a meeting started" (design-spec 7.8, 02 section 7): segments preset from Modes, a static
/// engine field, the Keep suggesting switch, Not now / Start recording. 300 x 229.
struct MeetingSuggestionView: View {
    let model: EdgeCommandPanelModel
    let suggestion: MeetingSuggestion
    let onStart: () -> Void
    let onDismiss: () -> Void
    let onTrackingChanged: (Bool) -> Void
    let onDrag: () -> Void
    let onDragEnd: () -> Void

    /// 229 - 2 x 12 padding - 4 x 10 gaps - header 28, segments 34, field 42, buttons 38.
    static let switchRowHeight: CGFloat = 23

    private var current: MeetingSuggestion {
        model.meetingSuggestion ?? suggestion
    }

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            PanelHeader(
                icon: PanelIconTile(symbol: "person.2"),
                title: "Looks like a meeting started",
                status: .plain("Record it?"),
                titleID: "prompt.title",
                statusID: "prompt.subtitle"
            ) {
                PanelIconButton(kind: .close, action: onDismiss)
                    .accessibilityIdentifier("prompt.close")
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)

            ModeSegments(
                items: MeetingSegment.allCases.map { segment in
                    .init(
                        id: segment,
                        title: Self.title(for: segment),
                        isEnabled: current.isSelectable(segment),
                        accessibilityID: Self.accessibilityID(for: segment)
                    )
                },
                selection: Binding(
                    get: { current.selectedSegment },
                    set: { model.selectMeetingSuggestionSegment($0) }
                )
            )

            PickerField(
                staticLabel: current.isEngineAfterStop ? "Transcript after Stop" : "Engine",
                value: current.engineName,
                layout: .stacked,
                identifier: "prompt.engine"
            )

            HStack(spacing: DS.Space.sm) {
                Text("Keep suggesting when a meeting starts")
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                // Only a user flip reports; a write-back from the controller does not loop through onChange.
                SettingsSwitch(title: "Keep suggesting when a meeting starts", isOn: Binding(
                    get: { model.meetingSuggestionsEnabled },
                    set: { model.meetingSuggestionsEnabled = $0; onTrackingChanged($0) }
                ))
                    .accessibilityIdentifier("prompt.keepSuggesting")
            }
            .frame(height: Self.switchRowHeight)

            HStack(spacing: DS.Space.sm) {
                PanelButton(title: "Not now", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("prompt.notNow")
                PanelButton(title: "Start recording", role: .primary, action: onStart)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("prompt.start")
            }
        }
        .padding(DS.Space.md)
        .frame(width: 300)
        .background(DS.Palette.panel, in: panelShape)
        .overlay(panelShape.stroke(DS.Palette.line, lineWidth: 1))
        .onExitCommand(perform: onDismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting recording suggestion")
        .accessibilityIdentifier("commandPanel.prompt")
    }

    static func title(for segment: MeetingSegment) -> LocalizedStringKey {
        switch segment {
        case .thisMac: "Local"
        case .cloud: "Cloud"
        case .recordOnly: "Record only"
        }
    }

    /// test-plan 2.1 names the segments by `meetingTranscriptMode` values.
    static func accessibilityID(for segment: MeetingSegment) -> String {
        switch segment {
        case .thisMac: "prompt.segment.localLive"
        case .cloud: "prompt.segment.cloudLive"
        case .recordOnly: "prompt.segment.recordOnly"
        }
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { _ in onDrag() }
            .onEnded { _ in onDragEnd() }
    }
}
