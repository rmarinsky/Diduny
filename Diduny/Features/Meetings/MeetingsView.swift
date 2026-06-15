import SwiftUI

struct MeetingsView: View {
    @Environment(AppState.self) var appState
    @State private var storage = RecordingsLibraryStorage.shared
    @State private var playbackService = AudioPlaybackService.shared
    @State private var selectedRecording: Recording? = nil
    @State private var showBulkDeleteConfirmation = false
    @State private var isSelectionMode = false
    @State private var selectedMeetingIds = Set<UUID>()

    // Settings state
    @State private var autoRecordLargeMeetings = true
    @State private var organizerOnly = false
    @State private var autoShareTranscript = true
    @State private var alwaysAskBeforeRecording = false
    @State private var skippedCurrentMeetingPrompt = false

    private var isRecording: Bool {
        appState.meetingRecordingState == .recording || appState.meetingRecordingState == .processing
    }

    private var meetingRecordings: [Recording] {
        storage.recordings.filter { $0.type.isMeetingLike }
    }

    private var visibleMeetingRecordings: [Recording] {
        Array(meetingRecordings.prefix(10))
    }

    private var selectedVisibleCount: Int {
        visibleMeetingRecordings.filter { selectedMeetingIds.contains($0.id) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Meetings")
                    .font(.title2.bold())
                Spacer()
                Button {
                    toggleSelectionMode()
                } label: {
                    Label(isSelectionMode ? "Done" : "Select", systemImage: isSelectionMode ? "checkmark.circle" : "checklist")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(meetingRecordings.isEmpty)
                .accessibilityIdentifier("Toggle meeting selection")

                calendarStatusChip
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 12) {
                    if isRecording || !skippedCurrentMeetingPrompt {
                        upNextBanner
                    }
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
        .alert("Delete Selected Meetings", isPresented: $showBulkDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteSelectedMeetings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \(selectedMeetingIds.count) selected meeting recordings? This cannot be undone.")
        }
    }

    // MARK: - Calendar Status Chip

    private var calendarStatusChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text("Google Calendar")
                .font(.system(size: 12))
                .foregroundColor(.primary)
            Circle()
                .fill(Color.green)
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
                        MainWindowController.shared.toggleMeetingRecording()
                    }
                    .buttonStyle(BannerOutlineButtonStyle())
                    .help("Stop meeting recording")
                    .accessibilityIdentifier("Stop meeting recording")
                } else {
                    Button("Skip") {
                        skippedCurrentMeetingPrompt = true
                    }
                        .buttonStyle(BannerOutlineButtonStyle())
                        .help("Skip meeting recording prompt")
                        .accessibilityIdentifier("Skip meeting recording prompt")

                    Button("Record") {
                        MainWindowController.shared.toggleMeetingRecording()
                    }
                    .buttonStyle(BannerFilledButtonStyle())
                    .help("Start meeting recording")
                    .accessibilityIdentifier("Start meeting recording")
                }
            }
        }
        .padding(20)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                ruleRow(
                    label: "Auto-record meetings with 3 or more attendees",
                    isOn: $autoRecordLargeMeetings
                )

                Divider().padding(.horizontal, 16)

                ruleRow(
                    label: "Only record meetings I organize",
                    isOn: $organizerOnly
                )

                Divider().padding(.horizontal, 16)

                ruleRow(
                    label: "Auto-share transcript with attendees afterwards",
                    isOn: $autoShareTranscript
                )

                Divider().padding(.horizontal, 16)

                ruleRow(
                    label: "Always ask before recording",
                    isOn: $alwaysAskBeforeRecording
                )
            }
            .background(Color(.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
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

            if isSelectionMode {
                meetingSelectionBar
                    .padding(.bottom, 8)
            }

            VStack(spacing: 0) {
                ForEach(Array(visibleMeetingRecordings.enumerated()), id: \.element.id) { index, recording in
                    MeetingRow(
                        recording: recording,
                        isSelectionMode: isSelectionMode,
                        isSelected: selectedMeetingIds.contains(recording.id),
                        onToggleSelection: { toggleSelection(for: recording) }
                    ) {
                        if isSelectionMode {
                            toggleSelection(for: recording)
                        } else {
                            selectedRecording = recording
                        }
                    }
                    if index < visibleMeetingRecordings.count - 1 {
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

    private var meetingSelectionBar: some View {
        HStack(spacing: 8) {
            Label("\(selectedMeetingIds.count) selected", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()

            Button("Select Visible") {
                selectVisibleMeetings()
            }
            .buttonStyle(.link)
            .disabled(visibleMeetingRecordings.isEmpty || selectedVisibleCount == visibleMeetingRecordings.count)

            Button("Delete") {
                showBulkDeleteConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(selectedMeetingIds.isEmpty)
            .accessibilityIdentifier("Delete selected meetings")

            Button("Cancel") {
                cancelSelection()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func toggleSelectionMode() {
        isSelectionMode.toggle()
        if !isSelectionMode {
            selectedMeetingIds.removeAll()
        }
    }

    private func cancelSelection() {
        isSelectionMode = false
        selectedMeetingIds.removeAll()
    }

    private func toggleSelection(for recording: Recording) {
        if selectedMeetingIds.contains(recording.id) {
            selectedMeetingIds.remove(recording.id)
        } else {
            selectedMeetingIds.insert(recording.id)
        }
    }

    private func selectVisibleMeetings() {
        selectedMeetingIds.formUnion(visibleMeetingRecordings.map(\.id))
    }

    private func deleteSelectedMeetings() {
        let ids = selectedMeetingIds
        guard !ids.isEmpty else { return }
        if let playingId = playbackService.playingRecordingId, ids.contains(playingId) {
            playbackService.stop()
        }
        if let selectedRecording, ids.contains(selectedRecording.id) {
            self.selectedRecording = nil
        }
        storage.deleteRecordings(ids)
        cancelSelection()
    }
}

// MARK: - Meeting Row

private struct MeetingRow: View {
    let recording: Recording
    var isSelectionMode = false
    var isSelected = false
    var onToggleSelection: (() -> Void)? = nil
    let onTap: () -> Void

    @State private var playbackService = AudioPlaybackService.shared

    private var isPlaying: Bool {
        playbackService.playingRecordingId == recording.id && playbackService.isPlaying
    }

    var body: some View {
        HStack(spacing: 10) {
            if isSelectionMode {
                Button {
                    onToggleSelection?()
                } label: {
                    Label {
                        Text(isSelected ? "Deselect meeting" : "Select meeting")
                    } icon: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(isSelected ? Color("BrandAccentDeep") : .secondary)
                            .frame(width: 24, height: 24)
                    }
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help(isSelected ? "Deselect meeting" : "Select meeting")
                .accessibilityLabel(Text(isSelected ? "Deselect meeting" : "Select meeting"))
                .accessibilityIdentifier(isSelected ? "Meeting selected" : "Meeting not selected")
                .padding(.leading, 16)
            }

            // Time column
            Text(timeLabel)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .leading)
                .padding(.leading, isSelectionMode ? 0 : 16)

            // Accent line
            Rectangle()
                .fill(Color("BrandAccentDeep"))
                .frame(width: 3, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .padding(.trailing, 10)

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
                .help(isPlaying ? "Pause meeting playback" : "Play meeting playback")
                .accessibilityLabel(Text(isPlaying ? "Pause meeting playback" : "Play meeting playback"))
                .accessibilityIdentifier(isPlaying ? "Pause meeting playback" : "Play meeting playback")

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
        switch recording.type {
        case .meetingTranslation:
            return "Meeting translation — \(f.string(from: recording.createdAt))"
        case .meeting:
            return "Meeting — \(f.string(from: recording.createdAt))"
        case .voice, .translation, .fileTranscription:
            return recording.type.displayName
        }
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
