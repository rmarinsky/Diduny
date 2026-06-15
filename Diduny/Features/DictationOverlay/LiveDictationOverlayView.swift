import SwiftUI

struct LiveDictationOverlayView: View {
    let store: LiveDictationOverlayStore
    let onCopy: () -> Void
    let onStop: () -> Void

    var body: some View {
        TimelineView(.periodic(from: store.startedAt, by: 1)) { timeline in
            HStack(spacing: 12) {
                statusIcon

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(store.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(store.statusText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(statusColor)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        Text(elapsedText(at: timeline.date))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(displayText)
                        .font(.system(size: 14))
                        .foregroundStyle(store.hasText ? Color.primary : Color.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentTransition(.opacity)
                }

                controls
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: 560, height: 96)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
            .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
        }
    }

    private var displayText: String {
        store.visibleText.isEmpty ? "Listening..." : store.visibleText
    }

    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.14))
                .frame(width: 38, height: 38)

            if store.phase == .recording {
                LiveAudioMeter(level: store.audioLevel, color: statusColor)
                    .frame(width: 26, height: 18)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
        }
        .frame(width: 38, height: 38)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button(action: onCopy) {
                Image(systemName: store.copiedAt == nil ? "doc.on.doc" : "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(store.hasText ? Color.primary : Color.secondary.opacity(0.6))
            .background(Color.primary.opacity(store.hasText ? 0.06 : 0.03), in: Circle())
            .disabled(!store.hasText)
            .help("Copy transcript")

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(store.canStop ? Color.white : Color.secondary.opacity(0.6))
            .background(store.canStop ? Color.red : Color.primary.opacity(0.05), in: Circle())
            .disabled(!store.canStop)
            .help("Stop recording")
        }
        .frame(width: 68)
    }

    private var statusColor: Color {
        switch store.phase {
        case .recording:
            .red
        case .starting, .finalizing, .processing:
            .orange
        case .pasted:
            .green
        case .error:
            .red
        case .info:
            .blue
        }
    }

    private var iconName: String {
        switch store.phase {
        case .pasted:
            "checkmark"
        case .error:
            "exclamationmark"
        default:
            store.mode.icon
        }
    }

    private func elapsedText(at date: Date) -> String {
        let elapsed = max(0, Int(date.timeIntervalSince(store.startedAt)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct LiveAudioMeter: View {
    let level: Float
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(color.opacity(opacity(for: index)))
                    .frame(width: 3, height: height(for: index))
            }
        }
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
