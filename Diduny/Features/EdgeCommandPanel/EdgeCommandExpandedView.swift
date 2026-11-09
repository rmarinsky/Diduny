import SwiftUI

struct EdgeCommandExpandedView: View {
    let model: EdgeCommandPanelModel
    let liveStore: LiveDictationOverlayStore
    let onAction: (EdgeCommandAction) -> Void
    /// Capabilities and readiness of an engine (inputs; tests and previews pass stubs).
    let capabilities: (EngineID) -> EngineCapabilities?
    let readiness: (EngineID) -> EngineReadiness
    /// An Engine menu row id: an engine, "As in Settings" or "Providers...".
    let onEngineRow: (String) -> Void
    let onTarget: (String) -> Void
    let onRecordings: () -> Void
    let onSettings: () -> Void
    let onSignIn: () -> Void
    let onCopy: () -> Void
    let onStop: () -> Void
    let onDismissLive: () -> Void
    let onMinimizeLive: () -> Void
    let onSelectOutput: (DictationOutput) -> Void
    let onStartMeetingSuggestion: (UUID) -> Void
    let onDismissMeetingSuggestion: (UUID) -> Void
    let onMeetingSuggestionsEnabled: (Bool) -> Void
    let onCollapse: () -> Void
    let onDrag: () -> Void
    let onDragEnd: () -> Void
    /// The outcome after Stop (WP-42); shown in place of the live view until it auto-hides, ×,
    /// New recording or the next recording.
    var outcomeStore: EdgeCommandOutcomeStore = DictationOverlayController.shared.outcomeStore
    var onCloseOutcome: () -> Void = {}
    var onNewRecording: () -> Void = {}
    var onOpenRecording: (UUID) -> Void = { _ in }

    /// Which content the panel shows; a change is an M1 swap, anything else redraws in place (M3).
    enum ContentState: Equatable {
        case prompt
        case live
        case outcome
        case home

        /// The outcome replaces the live view at once: a slide would show both sets of buttons. The live
        /// view too: the microphone may block the main thread and freeze a fade half way.
        var slidesIn: Bool {
            self != .outcome && self != .live
        }
    }

    private var contentState: ContentState {
        if model.meetingSuggestion != nil { return .prompt }
        if visibleOutcome != nil { return .outcome }
        return model.isShowingLiveFeedback ? .live : .home
    }

    /// The outcome replaces the live view once the recording reached success.
    private var visibleOutcome: EdgeCommandOutcome? {
        EdgeCommandOutcomeVisibility.outcome(
            outcomeStore.outcome, isShowingLiveFeedback: model.isShowingLiveFeedback, phase: liveStore.phase
        )
    }

    var body: some View {
        // Slide from the docked edge (M1); with Reduce Motion a 120 ms fade.
        let swap = MotionPolicy.contentSwap(.swap, edge: model.dockEdge, preference: .current)
        ZStack {
            if let suggestion = model.meetingSuggestion {
                MeetingSuggestionView(
                    model: model,
                    suggestion: suggestion,
                    onStart: { onStartMeetingSuggestion(suggestion.meeting.id) },
                    onDismiss: { onDismissMeetingSuggestion(suggestion.meeting.id) },
                    onTrackingChanged: onMeetingSuggestionsEnabled,
                    onDrag: onDrag,
                    onDragEnd: onDragEnd
                )
                .transition(swap?.transition ?? .identity)
            } else if let outcome = visibleOutcome {
                EdgeCommandOutcomeView(
                    outcome: outcome,
                    transcript: RecordingQueueService.shared.transcriptState(for: outcome.recordingID),
                    isCopied: liveStore.copiedAt != nil,
                    onClose: onCloseOutcome,
                    onCopy: onCopy,
                    onNewRecording: onNewRecording,
                    onOpenRecording: { outcome.recordingID.map(onOpenRecording) }
                )
                .padding(DS.Panel.padding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(DS.Palette.panel, in: panelShape)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("commandPanel.outcome")
                .transition(swap?.transition ?? .identity)
            } else if model.isShowingLiveFeedback {
                LivePanelView(
                    store: liveStore,
                    onCopy: onCopy,
                    onStop: onStop,
                    onDismiss: onDismissLive,
                    onMinimize: onMinimizeLive,
                    onSelectOutput: onSelectOutput,
                    onDrag: onDrag,
                    onDragEnd: onDragEnd
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("commandPanel.live")
                .transition(swap?.transition ?? .identity)
            } else {
                // `commandView` sets `.contain` and `commandPanel.home` itself.
                commandView
                    .transition(swap?.transition ?? .identity)
            }
        }
        .animation(contentState.slidesIn ? swap?.animation : nil, value: contentState)
    }

    /// Command home (spec 7.4, 7.5; `cmdHome` P:577-592).
    private var commandView: some View {
        VStack(spacing: DS.Panel.blockGap) {
            header

            HStack(spacing: DS.Space.sm) {
                PickerField(
                    label: LocalizedStringKey(model.engineFieldLabel),
                    value: model.engineFieldValue,
                    layout: .stacked,
                    identifier: "commandPanel.engine",
                    menu: { CommandHome.engineMenu(pick: model.pick, caps: capabilities, readiness: readiness) },
                    onPick: onEngineRow
                )
                PickerField(
                    label: "Translate into",
                    value: CommandHome.languageName(model.target),
                    layout: .stacked,
                    menuAlignment: .trailing,
                    identifier: "commandPanel.translateInto",
                    menu: { CommandHome.translateIntoMenu(target: model.target, yourLanguages: model.yourLanguages) },
                    onPick: { row in onTarget(String(row.dropFirst(CommandHome.languageRowPrefix.count))) }
                )
            }

            if !model.isSignedIn {
                NoticeRow(text: "Sign in to record.", buttonTitle: "Sign in", action: onSignIn)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("commandPanel.signInNotice")
            }

            Grid(horizontalSpacing: DS.Space.sm, verticalSpacing: DS.Space.sm) {
                GridRow { tile(.transcribe); tile(.translate) }
                GridRow { tile(.meeting); tile(.translateMeeting) }
            }
            .fixedSize(horizontal: false, vertical: true)

            HeaderLink(title: "Batch files & URLs") { onAction(.batch) }
                .accessibilityIdentifier("commandPanel.batch")
                .frame(maxWidth: .infinity)
        }
        .padding(DS.Panel.padding)
        .background(DS.Palette.panel, in: panelShape)
        .overlay(panelShape.strokeBorder(DS.Palette.separator, lineWidth: DS.Panel.borderWidth))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("commandPanel.home")
    }

    private func tile(_ action: EdgeCommandAction) -> some View {
        let caption = CommandHome.caption(
            for: action, caps: capabilities(model.engine(for: action)), target: model.target, pair: model.pair
        )
        return CommandTile(
            symbol: action.icon,
            title: "\(action.title)",
            caption: "\(caption)",
            action: { onAction(action) }
        )
        .disabled(!model.tilesEnabled)
        .accessibilityIdentifier("commandPanel.tile.\(action.tileID)")
    }

    private var header: some View {
        PanelHeader(icon: PanelIconTile(symbol: "mic", symbolSize: DS.Size.symbolHomeHeader), title: "Diduny") {
            HeaderLink(title: "Recordings", action: onRecordings)
                .accessibilityIdentifier("commandPanel.recordings")
            HeaderLink(title: "Settings", action: onSettings)
                .accessibilityIdentifier("commandPanel.settings")
            PanelIconButton(kind: .close, action: onCollapse)
                .help("Hide quick actions")
                .accessibilityIdentifier("commandPanel.close")
        }
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: EdgeCommandPanelPlacement.expandedCornerRadius,
            style: .continuous
        )
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { _ in onDrag() }
            .onEnded { _ in onDragEnd() }
    }
}
