import SwiftUI

struct LiveTranscriptView: View {
    let store: LiveTranscriptStore

    @State private var recordingDuration: TimeInterval = 0
    @State private var timer: Timer?

    private let speakerColors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .mint
    ]

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            transcriptContent
            Divider()
            footerBar
        }
        .frame(minWidth: 350, minHeight: 300)
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            HStack(spacing: 6) {
                if store.isActive {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("Recording")
                        .font(.headline)
                } else {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 8, height: 8)
                    Text("Done")
                        .font(.headline)
                }
            }

            Spacer()

            if store.isActive {
                Text(formatDuration(recordingDuration))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            connectionIndicator
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var connectionIndicator: some View {
        switch store.connectionStatus {
        case .connected:
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
                .help("Connected")
        case .reconnecting:
            Circle()
                .fill(.yellow)
                .frame(width: 8, height: 8)
                .help("Reconnecting...")
        case .failed(let reason):
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .help("Disconnected: \(reason)")
        case .disconnected:
            Circle()
                .fill(.gray)
                .frame(width: 8, height: 8)
                .help("Disconnected")
        case .connecting:
            Circle()
                .fill(.yellow)
                .frame(width: 8, height: 8)
                .help("Connecting...")
        }
    }

    // MARK: - Transcript Content

    private var transcriptContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.segments) { segment in
                        segmentView(segment)
                    }

                    if !store.provisionalText.isEmpty {
                        provisionalView
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(16)
                .textSelection(.enabled)
            }
            .onChange(of: store.segments.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: store.provisionalText) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private func segmentView(_ segment: TranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(segment.timestamp)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                if let speaker = segment.speaker {
                    Text("Speaker \(speaker)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(colorForSpeaker(speaker))
                        )
                }
            }

            Text(segment.text.trimmingCharacters(in: .whitespaces))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var provisionalView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let speaker = store.provisionalSpeaker {
                HStack(spacing: 6) {
                    Text("Speaker \(speaker)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(colorForSpeaker(speaker))
                        )
                }
            }

            Text(store.provisionalText)
                .font(.body)
                .italic()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            Text("\(store.wordCount) words")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Copy") {
                let text = store.finalTranscriptText
                if !text.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.segments.isEmpty)

            Button("Save...") {
                saveTranscript()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.segments.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Helpers

    private func colorForSpeaker(_ speaker: String) -> Color {
        let index = Int(speaker) ?? speaker.hashValue
        return speakerColors[abs(index) % speakerColors.count]
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                recordingDuration += 1
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func saveTranscript() {
        let text = store.finalTranscriptText
        guard !text.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "meeting_transcript.txt"

        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
