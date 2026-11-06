import SwiftUI

/// The keycap and cancel hint on Stop. An input so the shortcuts model (WP-15) can supply them;
/// today they come from the store's hints.
struct LivePanelShortcuts: Equatable {
    /// For example "⌥ ×2"; nil hides the keycap.
    var stop: String?
    /// For example "Esc ×3"; nil hides the hint line.
    var cancel: String?

    @MainActor
    init(store: LiveDictationOverlayStore) {
        stop = store.stopShortcutHint
        cancel = store.cancelShortcutHint
    }

    init(stop: String?, cancel: String?) {
        self.stop = stop
        self.cancel = cancel
    }

    /// "Cancel: Esc ×3".
    var cancelHint: String? {
        cancel.map { String(localized: "Cancel: \($0)") }
    }

    /// Today's hint: "Stop and process recording. ⌥ ×2 also stops. Esc ×3 cancels".
    var accessibilityHint: String {
        var parts = [String(localized: "Stop and process recording")]
        if let stop { parts.append(String(localized: "\(stop) also stops")) }
        if let cancel { parts.append(String(localized: "\(cancel) cancels")) }
        return parts.joined(separator: ". ")
    }
}

/// Live panel shell for all four modes (design-spec 3.3, 4.7, 6): solid `panel`, 1 pt `line` border,
/// padding 12, blocks 10 apart. Header, then the mode's content file, then Copy + Stop, which become
/// the progress row after Stop. Mode content: `DictationLiveContent`, `MeetingLiveContent` (WP-31),
/// `TranslateMeetingLiveContent` (WP-32).
struct LivePanelView: View {
    let store: LiveDictationOverlayStore
    let onCopy: () -> Void
    let onStop: () -> Void
    let onDismiss: () -> Void
    let onMinimize: () -> Void
    let onSelectOutput: (DictationOutput) -> Void
    let onDrag: () -> Void
    let onDragEnd: () -> Void
    /// Nil reads the store's hints at each render.
    var shortcuts: LivePanelShortcuts?

    @State private var autoPaste = SettingsStorage.shared.autoPaste
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = store.panelState
        VStack(alignment: .leading, spacing: DS.Panel.blockGap) {
            header(state)
                .reveal(store.contentRevealed, step: 0, reduceMotion: reduceMotion)
            content
                .reveal(store.contentRevealed, step: 1, reduceMotion: reduceMotion)
            if store.phase == .pasted {
                Toggle("Paste and close automatically", isOn: $autoPaste)
                    .toggleStyle(.checkbox)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.secondary)
                    .onChange(of: autoPaste) { _, value in SettingsStorage.shared.autoPaste = value }
            }
            controls(state)
                .reveal(store.contentRevealed, step: 2, reduceMotion: reduceMotion)
        }
        .padding(DS.Panel.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay { skeleton.opacity(store.contentRevealed ? 0 : 1) }
        .animation(DS.Motion.easeOut(0.2), value: store.contentRevealed)
        .background(DS.Palette.panel, in: panelShape)
        .overlay(panelShape.strokeBorder(DS.Palette.line, lineWidth: DS.Panel.borderWidth))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var identifier: String {
        switch store.mode {
        case .voice, .fileTranscription: "livePanel.dictation"
        case .translation: "livePanel.dictationTranslation"
        case .meeting: "livePanel.meeting"
        case .meetingTranslation: "livePanel.meetingTranslation"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.mode {
        case .meeting:
            MeetingLiveSection(store: store)
        case .meetingTranslation:
            TranslateMeetingLiveContent(store: store)
        case .voice, .translation, .fileTranscription:
            DictationLiveContent(store: store, onSelectOutput: onSelectOutput)
        }
    }

    private func header(_ state: LivePanelState) -> some View {
        PanelHeader(
            icon: PanelIconTile(symbol: state.icon, hasGlobeBadge: store.mode == .meetingTranslation),
            title: LocalizedStringKey(state.title),
            status: status(state),
            titleID: "livePanel.title",
            statusID: "livePanel.status"
        ) {
            if store.phase != .pasted {
                LivePanelTimer(store: store)
                PanelIconButton(kind: .minimize, action: onMinimize)
                    .help("Hide to edge tab")
                    .accessibilityIdentifier("livePanel.minimize")
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in onDrag() }
                .onEnded { _ in onDragEnd() }
        )
        .help("Drag to attach to another screen edge")
    }

    /// While recording a meeting: WP-31's status (segment and connection), or WP-32's status
    /// without live text. Otherwise the shell's.
    private func status(_ state: LivePanelState) -> PanelStatus {
        guard store.phase == .recording else { return Self.panelStatus(state.status) }
        switch store.mode {
        case .meeting:
            let meeting = store.meetingPanelState.status
            return meeting.isLive ? .live(LocalizedStringKey(meeting.text)) : .plain(LocalizedStringKey(meeting.text))
        case .meetingTranslation:
            if let text = store.translateMeetingPanelModel?.notLiveStatus { return .plain(LocalizedStringKey(text)) }
            return Self.panelStatus(state.status)
        case .voice, .translation, .fileTranscription:
            return Self.panelStatus(state.status)
        }
    }

    /// Record only has no live text to copy (WP-31).
    private func isCopyEnabled(_ state: LivePanelState) -> Bool {
        state.isCopyEnabled && (store.mode != .meeting || store.meetingPanelState.isCopyEnabled)
    }

    static func panelStatus(_ status: LivePanelState.Status) -> PanelStatus {
        switch status {
        case let .live(text): .live(LocalizedStringKey(text))
        case let .plain(text): .plain(LocalizedStringKey(text))
        case let .error(text): .error(LocalizedStringKey(text))
        }
    }

    @ViewBuilder
    private func controls(_ state: LivePanelState) -> some View {
        if let line = state.progressLine {
            LiveProgressRow(line: line)
        } else {
            PanelControlsLayout(weights: [1, 1.6]) {
                CopyButton(isCopied: store.copiedAt != nil, action: onCopy)
                    .disabled(!isCopyEnabled(state))
                    .help("Copy transcript")
                    .accessibilityIdentifier("livePanel.copy")
                if showsCloseButton {
                    PanelButton(title: "Close", action: onDismiss)
                        .accessibilityIdentifier("livePanel.close")
                } else {
                    let hints = shortcuts ?? LivePanelShortcuts(store: store)
                    StopButton(
                        cancelHint: hints.cancelHint,
                        shortcut: hints.stop,
                        accessibilityHint: hints.accessibilityHint,
                        action: onStop
                    )
                    .disabled(!store.canStop)
                    .accessibilityIdentifier("livePanel.stop")
                }
            }
        }
    }

    /// After a paste and during the background hand-off the right button closes the panel (today).
    private var showsCloseButton: Bool {
        store.phase == .pasted || store.backgroundHandoffDetail != nil
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: EdgeCommandPanelPlacement.expandedCornerRadius, style: .continuous)
    }

    /// Static placeholder in the panel's layout, shown while the panel morphs in.
    private var skeleton: some View {
        let bar = DS.Palette.chip
        return VStack(alignment: .leading, spacing: DS.Panel.blockGap) {
            HStack(spacing: DS.Space.sm) {
                RoundedRectangle(cornerRadius: DS.Radius.iconTile, style: .continuous).fill(bar)
                    .frame(width: DS.Size.iconTile, height: DS.Size.iconTile)
                RoundedRectangle(cornerRadius: 4).fill(bar).frame(width: 90, height: 12)
                Spacer()
            }
            RoundedRectangle(cornerRadius: 4).fill(bar).frame(width: 120, height: 10)
            RoundedRectangle(cornerRadius: DS.Radius.box, style: .continuous).fill(bar).frame(maxHeight: .infinity)
            RoundedRectangle(cornerRadius: DS.Radius.panelButton, style: .continuous).fill(bar)
                .frame(height: DS.Size.panelButton)
        }
        .padding(DS.Panel.padding)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The progress row after Stop. Dictation has no fraction: the bar fills linearly over 1.4 s and
/// waits near the end until the text arrives (02 Q13 default).
private struct LiveProgressRow: View {
    let line: String
    /// When the row appeared, that is when Stop was pressed.
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 0.1)) { timeline in
            ProgressRow(
                line: LocalizedStringKey(line),
                fraction: min(timeline.date.timeIntervalSince(startedAt) / 1.4, 0.95),
                idPrefix: "livePanel.progress"
            )
        }
    }
}

private extension View {
    /// Entrance cascade after the tab→panel morph (unchanged): blocks rise 4pt and fade in, 40ms apart.
    func reveal(_ visible: Bool, step: Int, reduceMotion: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 4)
            .animation(
                !visible ? DS.Motion.easeOut(0.1)
                    : reduceMotion ? DS.Motion.reduced
                    : DS.Motion.easeOut(0.22).delay(Double(step) * 0.04),
                value: visible
            )
    }
}
