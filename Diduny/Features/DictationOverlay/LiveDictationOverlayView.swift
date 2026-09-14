import SwiftUI

struct LiveDictationOverlayView: View {
    let store: LiveDictationOverlayStore
    let onCopy: () -> Void
    let onStop: () -> Void
    let onDismiss: () -> Void
    let onMinimize: () -> Void
    let onDrag: () -> Void
    let onDragEnd: () -> Void
    @State private var autoPaste = SettingsStorage.shared.autoPaste
    private static let transcriptBottomID = "transcript-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            statusRow
            transcriptView

            if store.phase == .pasted {
                Toggle("Paste and close automatically", isOn: $autoPaste)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .onChange(of: autoPaste) { _, value in
                        SettingsStorage.shared.autoPaste = value
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            controls
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: panelShape)
        .overlay(panelShape.stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: store.phase)
    }

    private var header: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.pink, Color("BrandAccentDeep")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: store.mode.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .shadow(color: Color("BrandAccentDeep").opacity(0.28), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(store.title)
                    .font(.system(size: 13, weight: .bold))
                Text(store.statusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if store.phase != .pasted {
                ElapsedTimeLabel(startedAt: store.startedAt)

                Button(action: onMinimize) {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(
                            Color.primary.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .help("Hide to edge tab")
                .accessibilityLabel("Hide recording panel")
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .help("Drag to attach to another screen edge")
    }

    private var statusRow: some View {
        HStack(spacing: 9) {
            OverlayStatusIcon(store: store, statusColor: statusColor, iconName: iconName)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    statusBadge(store.providerLabel)
                    statusBadge(store.sourceLabel)
                }
                if let target = store.targetLabel {
                    statusBadge("→ \(target)")
                }
            }
        }
    }

    private func statusBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(displayText)
                        .font(.system(size: store.mode.isMeeting ? 12.5 : 12))
                        .foregroundStyle(store.hasText ? Color.primary.opacity(0.90) : Color.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentTransition(.opacity)

                    Color.clear
                        .frame(height: 1)
                        .id(Self.transcriptBottomID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
            }
            .scrollIndicators(store.mode.isMeeting ? .automatic : .hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
            }
            .onAppear { scrollTranscriptToBottom(proxy) }
            .onChange(of: store.displayText) { _, _ in scrollTranscriptToBottom(proxy) }
            .onChange(of: store.phase) { _, _ in scrollTranscriptToBottom(proxy) }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(action: onCopy) {
                Label(
                    store.copiedAt == nil ? "Copy" : "Copied",
                    systemImage: store.copiedAt == nil ? "doc.on.doc" : "checkmark"
                )
                .font(.system(size: 12.5, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: EdgeCommandPanelPlacement.liveControlHitTargetHeight)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(store.hasText ? Color.primary : Color.secondary.opacity(0.55))
            .background(
                Color.primary.opacity(store.hasText ? 0.06 : 0.03),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .disabled(!store.hasText)
            .help("Copy transcript")

            Button(action: store.phase == .pasted ? onDismiss : onStop) {
                HStack(spacing: 6) {
                    Image(systemName: stopButtonIcon)
                        .font(.system(size: 11, weight: .semibold))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(stopButtonTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)

                        if let cancelShortcut = store.cancelShortcutHint {
                            Text("Cancel  \(cancelShortcut)")
                                .font(.system(size: 8.5, weight: .medium))
                                .lineLimit(1)
                                .opacity(0.72)
                        }
                    }

                    Spacer(minLength: 2)

                    if let stopShortcut = store.stopShortcutHint {
                        shortcutKeycap(stopShortcut)
                    }
                }
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity, minHeight: EdgeCommandPanelPlacement.liveControlHitTargetHeight)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(store.phase == .pasted || store.canStop ? Color.white : Color.secondary.opacity(0.55))
            .background(stopButtonColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .disabled(!store.canStop && store.phase != .pasted)
            .help(stopButtonHelp)
            .accessibilityLabel(stopButtonTitle)
            .accessibilityHint(stopButtonHelp)
        }
    }

    private func shortcutKeycap(_ shortcut: String) -> some View {
        Text(shortcut)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(minHeight: 21)
            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            }
    }

    private var stopButtonTitle: String {
        switch store.phase {
        case .finalizing:
            "Finishing…"
        case .processing:
            "Processing…"
        case .pasted:
            "Close"
        default:
            "Stop"
        }
    }

    private var stopButtonIcon: String {
        switch store.phase {
        case .finalizing, .processing:
            "ellipsis"
        case .pasted:
            "xmark"
        default:
            "stop.fill"
        }
    }

    private var stopButtonHelp: String {
        if store.phase == .pasted {
            return "Close"
        }

        var parts = ["Stop and process recording"]
        if let stopShortcut = store.stopShortcutHint {
            parts.append("\(stopShortcut) also stops")
        }
        if let cancelShortcut = store.cancelShortcutHint {
            parts.append("\(cancelShortcut) cancels")
        }
        return parts.joined(separator: ". ")
    }

    private var displayText: String {
        store.displayText.isEmpty ? "Listening…" : store.displayText
    }

    private var stopButtonColor: Color {
        if store.phase == .pasted {
            return Color.primary.opacity(0.14)
        }
        if store.canStop {
            return Color("BrandAccentDeep").opacity(0.78)
        }
        return Color.primary.opacity(0.04)
    }

    private var statusColor: Color {
        switch store.phase {
        case .recording:
            Color("BrandAccentDeep")
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

    private func scrollTranscriptToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo(Self.transcriptBottomID, anchor: .bottom)
            }
        }
    }
}

private struct OverlayStatusIcon: View {
    let store: LiveDictationOverlayStore
    let statusColor: Color
    let iconName: String

    var body: some View {
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
}

private struct ElapsedTimeLabel: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
            Text(elapsedText(at: timeline.date))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func elapsedText(at date: Date) -> String {
        let elapsed = max(0, Int(date.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }
}

private struct LiveAudioMeter: View {
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
        .animation(.easeOut(duration: 0.10), value: level)
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
