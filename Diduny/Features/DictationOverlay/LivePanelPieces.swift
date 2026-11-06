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

/// Five bars driven by the real input level (today's meter, kept as is).
struct LiveAudioMeter: View {
    let level: Float
    let color: Color

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
        let scaled = CGFloat(max(0.08, min(level, 1))) * baseline[index]
        return max(4, scaled)
    }

    private func opacity(for index: Int) -> Double {
        let threshold = Float(index + 1) / 6
        return level >= threshold ? 1 : 0.35
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
        if let command = store.voiceCommand, command.position == .leading, store.isShowingConvertedPreview {
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
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(DS.Font.meta)
            .foregroundStyle(DS.Palette.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(text)
            .accessibilityIdentifier("livePanel.caption")
    }
}
