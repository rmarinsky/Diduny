import SwiftUI

struct MeetingsView: View {
    @Environment(AppState.self) var appState
    @State private var storage = RecordingsLibraryStorage.shared
    @State private var selectedRecording: Recording? = nil

    // Settings state
    @State private var meetingCloudModeEnabled: Bool = SettingsStorage.shared.meetingRealtimeTranscriptionEnabled
    @State private var audioSource = SettingsStorage.shared.meetingAudioSource

    private var isRecording: Bool {
        appState.meetingRecordingState == .recording || appState.meetingRecordingState == .processing
    }

    private var meetingRecordings: [Recording] {
        storage.recordings.filter { $0.type == .meeting }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Meetings")
                    .font(.title2.bold())
                Spacer()
                calendarStatusChip
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 12) {
                    upNextBanner
                    rulesCard
                    if !meetingRecordings.isEmpty {
                        pastMeetingsCard
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $selectedRecording) { recording in
            RecordingDetailView(recording: recording)
                .frame(minWidth: 640, idealWidth: 700, minHeight: 500)
        }
    }

    // MARK: - Calendar Status Chip

    private var calendarStatusChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text("Calendar")
                .font(.system(size: 12))
                .foregroundColor(.primary)
            Circle()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(.quaternaryLabelColor).opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
        )
    }

    // MARK: - UP NEXT Banner (the ONE tinted card)

    private var upNextBanner: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isRecording ? Color.white : Color.white.opacity(0.7))
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .fill(isRecording ? .red : .clear)
                                .frame(width: 6, height: 6)
                        )
                    Text(isRecording ? "RECORDING IN PROGRESS" : "UP NEXT")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .kerning(0.5)
                }

                Text(isRecording ? "Meeting recording active" : "Start a meeting recording")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)

                Text(isRecording
                    ? "Diduny is capturing system audio for transcription"
                    : "Record any call, webinar, or in-person meeting")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
            }

            Spacer()

            HStack(spacing: 8) {
                if isRecording {
                    Button("Stop") {
                        if let delegate = NSApp.delegate as? AppDelegate {
                            delegate.toggleMeetingRecording()
                        }
                    }
                    .buttonStyle(BannerOutlineButtonStyle())
                } else {
                    Button("Record") {
                        if let delegate = NSApp.delegate as? AppDelegate {
                            delegate.toggleMeetingRecording()
                        }
                    }
                    .buttonStyle(BannerFilledButtonStyle())
                }
            }
        }
        .padding(20)
        .background(Color("BrandAccentDeep"), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Rules Card

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MEETING SETTINGS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .kerning(0.5)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                // Provider toggle
                ruleRow(
                    label: "Cloud transcription (real-time)",
                    isOn: Binding(
                        get: { meetingCloudModeEnabled },
                        set: { v in
                            meetingCloudModeEnabled = v
                            SettingsStorage.shared.meetingRealtimeTranscriptionEnabled = v
                        }
                    )
                )

                Divider().padding(.horizontal, 16)

                // Audio source
                ruleRow(
                    label: "System audio + microphone",
                    isOn: Binding(
                        get: { audioSource == .systemPlusMicrophone },
                        set: { v in
                            audioSource = v ? .systemPlusMicrophone : .systemOnly
                            SettingsStorage.shared.meetingAudioSource = audioSource
                        }
                    )
                )

                Divider().padding(.horizontal, 16)

                HStack {
                    Text("Audio source")
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { audioSource },
                        set: { v in
                            audioSource = v
                            SettingsStorage.shared.meetingAudioSource = v
                        }
                    )) {
                        ForEach(MeetingAudioSource.allCases, id: \.self) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func ruleRow(label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.primary)
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .tint(Color("BrandAccentDeep"))
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Past Meetings Card

    private var pastMeetingsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PAST MEETINGS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .kerning(0.5)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(Array(meetingRecordings.prefix(10).enumerated()), id: \.element.id) { index, recording in
                    MeetingRow(recording: recording) {
                        selectedRecording = recording
                    }
                    if index < min(meetingRecordings.count, 10) - 1 {
                        Divider().padding(.horizontal, 16)
                    }
                }
            }
            .background(Color(.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
            )
        }
    }
}

// MARK: - Meeting Row

private struct MeetingRow: View {
    let recording: Recording
    let onTap: () -> Void

    @State private var playbackService = AudioPlaybackService.shared

    private var isPlaying: Bool {
        playbackService.playingRecordingId == recording.id && playbackService.isPlaying
    }

    var body: some View {
        HStack(spacing: 0) {
            // Time column
            Text(timeLabel)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .leading)
                .padding(.leading, 16)

            // Accent line
            Rectangle()
                .fill(Color("BrandAccentDeep"))
                .frame(width: 3, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .padding(.horizontal, 10)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(formattedDuration)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    if let chapters = recording.chapters, !chapters.isEmpty {
                        Text("·")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                        Text("\(chapters.count) chapter\(chapters.count == 1 ? "" : "s")")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    if recording.transcriptionText != nil {
                        Text("·")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                        Text("Transcribed")
                            .font(.system(size: 11))
                            .foregroundColor(Color("BrandAccentDeep"))
                    }
                }
            }

            Spacer()

            // Play button + date
            VStack(alignment: .trailing, spacing: 2) {
                Button {
                    playbackService.togglePlayback(
                        recordingId: recording.id,
                        fileURL: RecordingsLibraryStorage.shared.audioFileURL(for: recording)
                    )
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color(.quaternaryLabelColor).opacity(0.12))
                            .frame(width: 28, height: 28)
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color("BrandAccentDeep"))
                            .offset(x: isPlaying ? 0 : 0.5)
                    }
                }
                .buttonStyle(.plain)

                Text(relativeDay)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.trailing, 16)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var timeLabel: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: recording.createdAt)
    }

    private var rowTitle: String {
        if let text = recording.transcriptionText, !text.isEmpty {
            let words = text.split(separator: " ").prefix(5).joined(separator: " ")
            return words.count < text.count ? words + "…" : words
        }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return "Meeting — \(f.string(from: recording.createdAt))"
    }

    private var formattedDuration: String {
        let total = Int(recording.durationSeconds)
        let h = total / 3600; let m = (total % 3600) / 60; let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private var relativeDay: String {
        let cal = Calendar.current; let now = Date()
        if cal.isDateInToday(recording.createdAt) { return "Today" }
        if cal.isDateInYesterday(recording.createdAt) { return "Yesterday" }
        let d = cal.dateComponents([.day], from: recording.createdAt, to: now).day ?? 0
        if d < 7 { let f = DateFormatter(); f.dateFormat = "EEE"; return f.string(from: recording.createdAt) }
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none; return f.string(from: recording.createdAt)
    }
}

// MARK: - Banner Button Styles

private struct BannerFilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Color("BrandAccentDeep"))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

private struct BannerOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.7), lineWidth: 1.5)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
