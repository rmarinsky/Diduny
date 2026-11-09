import SwiftUI

// Pieces every live panel mode shares (design-spec 3.4, 4.7, 4.18). Mode content files use them.

/// 38 pt circle on `tint` with the real level meter in `accent` (D15: the app's size, not the
/// prototype's looping bars). Before and after recording it shows the phase symbol.
struct LiveWaveformCircle: View {
    let store: LiveDictationOverlayStore

    var body: some View {
        ZStack {
            Circle().fill(DS.Palette.tint)
            if store.phase == .recording {
                LiveAudioMeter(level: store.audioLevel, color: DS.Palette.accent)
                    .frame(width: 26, height: 18)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.Palette.accent)
            }
        }
        .frame(width: DS.Size.waveformCircle, height: DS.Size.waveformCircle)
        .accessibilityElement()
        .accessibilityLabel(Text("Audio level"))
        .accessibilityIdentifier("livePanel.waveform")
    }

    private var symbol: String {
        switch store.phase {
        case .pasted: "checkmark"
        case .error: "exclamationmark"
        default: store.panelState.icon
        }
    }
}

/// Five bars driven by the real input level.
struct LiveAudioMeter: View {
    let level: Float
    let color: Color

    /// The level spans -60 to 0 dB, but speech close to a mic sits near -30 dB, which lit only 2-3 bars.
    /// The scale now covers -50 dB (quiet room) to -20 dB (loud speech).
    static func displayLevel(_ level: Float) -> Float {
        max(0, min((level - 0.167) / 0.5, 1))
    }

    /// How many of the five bars are lit: 4 at -30 dB, none in silence.
    static func litBars(_ level: Float) -> Int {
        (0 ..< 5).filter { displayLevel(level) >= threshold(for: $0) }.count
    }

    private static func threshold(for index: Int) -> Float {
        Float(index + 1) / 7
    }

    private var shown: Float { Self.displayLevel(level) }

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0 ..< 5, id: \.self) { index in
                Capsule()
                    .fill(color.opacity(opacity(for: index)))
                    .frame(width: 3, height: height(for: index))
            }
        }
        .animation(DS.Motion.easeOut(DS.Motion.m15LevelMeter.duration), value: level)
    }

    private func height(for index: Int) -> CGFloat {
        let baseline: [CGFloat] = [8, 13, 18, 13, 8]
        let scaled = CGFloat(max(0.08, shown)) * baseline[index]
        return max(4, scaled)
    }

    private func opacity(for index: Int) -> Double {
        shown >= Self.threshold(for: index) ? 1 : 0.35
    }
}

/// "06:22", or the silence countdown in `warn`.
struct LivePanelTimer: View {
    let store: LiveDictationOverlayStore

    var body: some View {
        Group {
            if let secondsLeft = store.silenceCountdown {
                PanelTimer(text: String(localized: "Stopping in \(secondsLeft)s"), isWarning: true)
            } else {
                TimelineView(.periodic(from: store.startedAt, by: 1)) { timeline in
                    PanelTimer(text: Self.elapsed(from: store.startedAt, to: min(timeline.date, store.endedAt ?? timeline.date)))
                }
            }
        }
        .accessibilityIdentifier("livePanel.timer")
    }

    static func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// The transcript text with a spoken command highlighted, plus the "Command:" lines (today's logic).
struct LiveTranscriptContent: View {
    let store: LiveDictationOverlayStore

    var body: some View {
        if let command = store.voiceCommand, command.position != .trailing, store.isShowingConvertedPreview {
            commandLine("Command:", command)
        }
        transcriptText
            .foregroundStyle(store.hasText ? DS.Palette.text : DS.Palette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        if let command = store.voiceCommand {
            if store.phase == .pasted {
                commandLine("Removed command:", command)
            } else if command.position == .trailing, store.isShowingConvertedPreview {
                commandLine("Command:", command)
            }
        }
    }

    private var text: String {
        guard store.displayText.isEmpty else { return store.displayText }
        return store.backgroundHandoffDetail ?? String(localized: "Listening…")
    }

    private var transcriptText: Text {
        let text = text
        guard let command = store.voiceCommand, store.phase != .pasted, !store.isShowingConvertedPreview,
              let range = command.position == .trailing
              ? text.range(of: command.commandText, options: .backwards)
              : text.range(of: command.commandText)
        else { return Text(verbatim: text) }
        var attributed = AttributedString(text)
        if let commandRange = Range(range, in: attributed) {
            attributed[commandRange].foregroundColor = DS.Palette.accentText
            attributed[commandRange].backgroundColor = DS.Palette.tint
            attributed[commandRange].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(attributed)
    }

    private func commandLine(_ prefix: LocalizedStringKey, _ command: VoiceTranslationCommand) -> some View {
        HStack(spacing: 4) {
            Text(prefix).foregroundStyle(DS.Palette.secondary)
            Text(verbatim: command.commandText)
                .fontWeight(.semibold)
                .foregroundStyle(DS.Palette.accentText)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(DS.Palette.tint, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .font(DS.Font.caption)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// The caption line under a mode's row: 11.5 `secondary`.
struct LivePanelCaption: View {
    /// 11.5 pt at line height 16.7 (design-spec 7.2); one line has no leading of its own in SwiftUI.
    static let lineHeight: CGFloat = 16.7

    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(DS.Font.meta)
            .foregroundStyle(DS.Palette.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minHeight: Self.lineHeight)
            .help(text)
            .accessibilityIdentifier("livePanel.caption")
    }
}
