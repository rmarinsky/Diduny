import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The recording inspector: title (rename in place, one suggested name), player, then the result.
struct RecordingDetailView: View {
    let recording: Recording
    let parentBatchName: String?
    let onBack: (() -> Void)?
    let onClose: () -> Void
    let onNavigationGuardChanged: (((() -> Bool)?) -> Void)?
    let calendarActions: RecordingCalendarActions?
    @State private var trimEditor: AudioTrimEditorState?

    @State private var playbackService = AudioPlaybackService.shared
    @State private var queueService = RecordingQueueService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var storage = RecordingsLibraryStorage.shared
    @State private var title: String
    @State private var description: String
    @State private var isEditingDescription = false
    @State private var showsChooserAgain = false
    @State private var showDeleteConfirmation = false
    @State private var showDiscardConfirmation = false
    @State private var operationErrorMessage: String?
    @State private var isRecoveringAudio = false
    @FocusState private var titleFocused: Bool

    init(
        recording: Recording,
        parentBatchName: String? = nil,
        onBack: (() -> Void)? = nil,
        onClose: @escaping () -> Void,
        onNavigationGuardChanged: (((() -> Bool)?) -> Void)? = nil,
        calendarActions: RecordingCalendarActions? = nil
    ) {
        self.recording = recording
        self.parentBatchName = parentBatchName
        self.onBack = onBack
        self.onClose = onClose
        self.onNavigationGuardChanged = onNavigationGuardChanged
        self.calendarActions = calendarActions
        _title = State(initialValue: recording.displayTitle)
        _description = State(initialValue: recording.description ?? recording.remoteSource?.description ?? "")
    }

    private var currentRecording: Recording {
        storage.recordings.first(where: { $0.id == recording.id }) ?? recording
    }

    private var currentQueueProgress: QueueProgress? {
        guard queueService.currentRecordingId == currentRecording.id else { return nil }
        return queueService.currentProgress
    }

    private var hasPlayableAudio: Bool {
        storage.hasPlayableAudio(for: currentRecording)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(EdgeInsets(top: 16, leading: 16, bottom: 10, trailing: 16))
            player
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    result
                    if currentRecording.remoteSource != nil { youtubeSourceSection }
                    captionsSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .onDisappear { if trimEditor != nil { finishTrimming() } }
        .onExitCommand {
            if canLeaveTrimEditor() { onClose() }
        }
        .alert("Delete “\(currentRecording.displayTitle)”?", isPresented: $showDeleteConfirmation) {
            Button("Delete Recording", role: .destructive) {
                if playbackService.playingRecordingId == currentRecording.id {
                    playbackService.stop()
                }
                if storage.deleteRecording(currentRecording) {
                    finishTrimming()
                    onClose()
                } else {
                    operationErrorMessage = String(localized: "The recording and its files were left unchanged.")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the recording, stored media, transcript history, translations, and every batch reference.")
        }
        .alert("Discard this recording?", isPresented: $showDiscardConfirmation) {
            Button("Discard", role: .destructive) { recoverAudio(.discard) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved pieces of audio are deleted. This cannot be undone.")
        }
        .alert(
            "Recording Change Failed",
            isPresented: Binding(
                get: { operationErrorMessage != nil },
                set: { if !$0 { operationErrorMessage = nil } }
            )
        ) {
            Button("OK") { operationErrorMessage = nil }
        } message: {
            Text(operationErrorMessage ?? "Unknown error")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let onBack {
                Button { if canLeaveTrimEditor() { onBack() } } label: {
                    Label(parentBatchName ?? String(localized: "Back to Batch"), systemImage: "chevron.left")
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.secondary)
                .padding(.bottom, 2)
            }

            HStack(alignment: .top, spacing: DS.Space.sm) {
                TextField("Recording title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .focused($titleFocused)
                    .onSubmit { saveTitle() }
                    .onChange(of: titleFocused) { _, focused in if !focused { saveTitle() } }
                    .help("Click to rename")
                    .accessibilityIdentifier("recordings.detail.title")
                moreMenu
                Button {
                    if canLeaveTrimEditor() { onClose() }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
                .accessibilityIdentifier("Close recording detail")
            }

            if let suggestion = RecordingNameSuggestion.make(for: currentRecording),
               suggestion.name != currentRecording.customTitle
            {
                HStack(spacing: 4) {
                    Text(suggestion.source == .event ? String(localized: "Event title:") : String(localized: "Suggested from the transcript:"))
                    Button(suggestion.name) { title = suggestion.name; saveTitle() }
                        .buttonStyle(.link)
                        .lineLimit(1)
                        .accessibilityIdentifier("recordings.detail.suggestion")
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.secondary)
            }

            Text(verbatim: "\(formattedDate). \(formattedDuration)\(currentRecording.recoverySource != nil ? String(localized: ". Recovered from an interrupted session") : "")")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.secondary)

            calendarLine

            if isEditingDescription {
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(2 ... 4)
                    .font(DS.Font.callout)
                    .onSubmit { saveDescription() }
                HStack {
                    Spacer()
                    Button("Cancel") { description = currentRecording.description ?? ""; isEditingDescription = false }
                    Button("Save") { saveDescription() }
                }
                .controlSize(.small)
            } else if let text = currentRecording.description, !text.isEmpty {
                Text(text).font(DS.Font.caption).foregroundStyle(DS.Palette.secondary).lineLimit(3)
            }
        }
    }

    @ViewBuilder
    private var calendarLine: some View {
        if let calendarActions, !currentRecording.status.isInProgressCapture {
            Group {
                if let meeting = currentRecording.calendarMeeting {
                    HStack(spacing: 4) {
                        Text("Event: \(meeting.title), \(meeting.scheduleLine).").lineLimit(1)
                        Button("Detach") { calendarActions.detach() }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("recordings.detail.detach")
                        if let url = meeting.meetingURL, CalendarMeeting.isJoinURL(url) {
                            Button("Open meeting link") {
                                _ = AppDelegate.openMeetingLink(url, configuration: CalendarConnection.shared.configuration)
                            }
                            .buttonStyle(.link)
                        }
                    }
                } else if !calendarActions.overlapping.isEmpty {
                    ForEach(calendarActions.overlapping, id: \.reminderKey) { meeting in
                        HStack(spacing: 4) {
                            Text("At the same time: \(meeting.title).").lineLimit(1)
                            Button("Attach") { calendarActions.attach(meeting) }
                                .buttonStyle(.link)
                                .accessibilityIdentifier("recordings.detail.attach")
                        }
                    }
                } else if let candidates = currentRecording.calendarCandidates, !candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Which meeting was this?")
                        ForEach(candidates) { candidate in
                            Button(candidate.title + " · " + candidate.scheduleLine) { calendarActions.attach(candidate) }
                                .buttonStyle(.link)
                        }
                    }
                } else if CalendarConnection.shared.configuration.connected {
                    HStack(spacing: 4) {
                        Text("No calendar event.")
                        Button("Find one") { findCalendarEvent() }.buttonStyle(.link)
                    }
                }
            }
            .font(DS.Font.caption)
            .foregroundStyle(DS.Palette.secondary)
        }
    }

    private var moreMenu: some View {
        Menu {
            Button(currentRecording.description?.isEmpty == false ? String(localized: "Edit description") : String(localized: "Add description")) {
                isEditingDescription = true
            }
            Button("Save transcript as TXT…") {
                if let text = currentRecording.displayTranscriptText {
                    exportText(text, title: String(localized: "Save Transcript"),
                               defaultFileName: "\(currentRecording.displayTitle).txt")
                }
            }
            .disabled(currentRecording.displayTranscriptText == nil)
            if currentRecording.calendarMeeting != nil, let calendarActions {
                Button("Detach from event") { calendarActions.detach() }
            }
            Divider()
            Button("Delete recording…", role: .destructive) {
                if canLeaveTrimEditor() { showDeleteConfirmation = true }
            }
            .accessibilityIdentifier("recordings.detail.delete")
        } label: {
            Text("More")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(DS.Font.caption)
        .accessibilityIdentifier("recordings.detail.more")
    }

    private func saveTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != currentRecording.displayTitle else { return }
        // Clearing the field goes back to the derived name (event, file), never freezes it.
        if !storage.updateDetails(id: currentRecording.id, title: trimmed, description: currentRecording.description ?? "") {
            operationErrorMessage = String(localized: "The title and description were left unchanged.")
        }
        title = currentRecording.displayTitle
    }

    private func saveDescription() {
        if !storage.updateDetails(id: currentRecording.id, title: currentRecording.customTitle ?? "", description: description) {
            operationErrorMessage = String(localized: "The title and description were left unchanged.")
        }
        isEditingDescription = false
    }

    private func findCalendarEvent() {
        let recording = currentRecording
        let end = recording.resolvedEndedAt ?? recording.createdAt.addingTimeInterval(recording.durationSeconds)
        Task {
            switch await CalendarMeeting.findEvents(recordingStart: recording.createdAt, recordingEnd: end,
                                                    read: CalendarConnection.shared.readMeetings) {
            case let .found(overlapping):
                if !storage.setCalendarLink(id: recording.id, .init(meeting: nil, candidates: overlapping, declined: nil)) {
                    operationErrorMessage = String(localized: "The calendar link could not be saved.")
                }
            case .noOverlap:
                operationErrorMessage = String(localized: "No calendar event overlaps this recording.")
            case .readFailed:
                operationErrorMessage = String(localized: "Diduny couldn't read your calendar. Check calendar access in System Settings.")
            }
        }
    }

    // MARK: - Player

    @ViewBuilder
    private var player: some View {
        if let editor = trimEditor {
            RecordingTrimEditorView(
                editor: Binding(get: { trimEditor ?? editor }, set: { trimEditor = $0 }),
                recordingID: currentRecording.id,
                fileURL: storage.audioFileURL(for: currentRecording),
                onCancel: { finishTrimming() },
                onSave: { _ = saveTrim() }
            )
        } else {
            HStack(spacing: DS.Space.sm) {
                AudioPlaybackControlView(
                    recordingId: currentRecording.id,
                    fileURL: storage.audioFileURL(for: currentRecording),
                    durationHint: currentRecording.effectiveDurationSeconds,
                    trimRange: currentRecording.trimRange
                )
                .disabled(!hasPlayableAudio)
                if currentRecording.canTrimAudio, hasPlayableAudio {
                    Button("Trim…") {
                        playbackService.stop()
                        trimEditor = AudioTrimEditorState(
                            duration: currentRecording.durationSeconds,
                            savedRange: currentRecording.trimRange
                        )
                        onNavigationGuardChanged?(canLeaveTrimEditor)
                        RecordingTrimNavigation.shared.canLeave = canLeaveTrimEditor
                    }
                    .buttonStyle(.plain)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.secondary)
                    .accessibilityIdentifier("Trim recording")
                }
            }
        }
    }

    // MARK: - Result

    @ViewBuilder
    private var result: some View {
        let recording = currentRecording
        if recording.status == .needsRecovery {
            recoverySection
        } else if recording.status.isInProgressCapture {
            Text("Recording in progress — playback and transcription become available once it's finalized.")
                .font(DS.Font.callout)
                .foregroundStyle(DS.Palette.secondary)
        } else if recording.status == .processing {
            queueProgressView
            // While a new run works, the text the recording already has stays readable.
            if let text = recording.displayTranscriptText {
                Text(RecordingVersions(recording).current == nil ? String(localized: "Live text") : String(localized: "Current transcript, until the new one is ready"))
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundStyle(DS.Palette.secondary)
                    .padding(.top, DS.Space.xs)
                Text(text)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("recordings.detail.previousText")
            }
        } else if recording.status == .failed {
            Label(recording.errorMessage ?? String(localized: "Transcription failed"), systemImage: "exclamationmark.triangle.fill")
                .font(DS.Font.callout)
                .foregroundStyle(DS.Palette.no)
            chooser(heading: String(localized: "Try again"))
        } else if showsChooserAgain {
            chooser(heading: String(localized: "Transcribe again"), again: true)
        } else if !RecordingVersions(recording).originals.isEmpty {
            RecordingResultView(
                recording: recording,
                onTranscribeAgain: { showsChooserAgain = true },
                onError: { operationErrorMessage = $0 }
            )
            .disabled(trimEditor != nil)
        } else {
            chooser(heading: String(localized: "Make a transcript"))
        }
    }

    private func chooser(heading: String, again: Bool = false) -> some View {
        TranscribeChooserView(
            recording: currentRecording,
            heading: heading,
            isAgain: again,
            onCancel: again ? { showsChooserAgain = false } : nil
        ) { run in
            guard canLeaveTrimEditor() else { return }
            queueService.enqueue([currentRecording.id], action: run.action, whisperModelOverride: run.whisperModel,
                                 engineOverride: run.engine, speakerLabels: run.speakerLabels)
            showsChooserAgain = false
        }
        .disabled(trimEditor != nil)
    }

    private var queueProgressView: some View {
        let progress = currentQueueProgress
        let fraction = progress.flatMap(QueueProgressFormatter.barFraction)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                ProgressView().controlSize(.small)
                Text(
                    progress.map(QueueProgressFormatter.detailLine)
                        ?? (queueService.isQueued(currentRecording.id) ? String(localized: "Queued") : nil)
                        ?? String(localized: "Transcribing...")
                )
                .font(DS.Font.headline)
                .monospacedDigit()
                Spacer()
                if let timeLeft = progress.flatMap(QueueProgressFormatter.timeLeft) {
                    Text(timeLeft).font(DS.Font.caption).foregroundStyle(DS.Palette.secondary).monospacedDigit()
                }
            }
            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(DS.Palette.accent)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: fraction)
            }
            Text(currentRecording.displayTranscriptText == nil
                ? String(localized: "\(formattedDuration) of audio. The transcript appears here when it is ready. You can leave this screen.")
                : String(localized: "You can leave this screen."))
                .font(DS.Font.caption).foregroundStyle(DS.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One path, as the prototype reads: explanation, steps 1 and 2, "Recover audio". After it, the normal chooser.
    private var recoverySection: some View {
        let failure = currentRecording.recoveryFailureMessage
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(failure == nil ? String(localized: "This recording was interrupted") : String(localized: "Could not recover the audio"))
                .font(DS.Font.headline)
            Text(failure == nil
                ? String(localized: "Diduny saved about \(formattedDuration) of audio in pieces. Put them back together first, then you can listen and transcribe.")
                : String(localized: "The saved pieces stay on this Mac. Nothing was deleted. Try again, or contact support if it keeps failing."))
                .font(DS.Font.body)
                .fixedSize(horizontal: false, vertical: true)
            if let failure {
                Text(failure).font(DS.Font.caption).foregroundStyle(DS.Palette.no)
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("Recover the audio", systemImage: "1.circle.fill").fontWeight(.semibold)
                Label("Choose how to transcribe", systemImage: "2.circle").foregroundStyle(DS.Palette.secondary)
            }
            .font(DS.Font.callout)
            if isRecoveringAudio {
                HStack { ProgressView().controlSize(.small); Text("Recovering audio...") }
            } else {
                HStack(spacing: DS.Space.sm) {
                    Button(failure == nil ? String(localized: "Recover audio") : String(localized: "Try again")) { recoverAudio(.saveAudioOnly) }
                        .buttonStyle(.borderedProminent)
                        .tint(DS.Palette.accent)
                        .controlSize(.large)
                        .accessibilityIdentifier("recordings.detail.recover")
                    Button("Discard…", role: .destructive) { showDiscardConfirmation = true }
                        .controlSize(.large)
                }
                // Recover and transcribe at once, as before.
                Button("Recover and transcribe now") { recoverAudio(.processNow) }
                    .buttonStyle(.link)
                    .font(DS.Font.caption)
            }
        }
    }

    private func recoverAudio(_ action: MeetingRecoveryService.RecoveryAction) {
        isRecoveringAudio = true
        Task { @MainActor in
            // A failure is stored on the recording and shown in `recoverySection`.
            await MeetingRecoveryService.shared.resolve(recordingID: currentRecording.id, action: action)
            isRecoveringAudio = false
        }
    }

    // MARK: - Sources

    private var youtubeSourceSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let remoteSource = currentRecording.remoteSource {
                Text(remoteSource.title).font(DS.Font.calloutStrong).lineLimit(2)
                Link(remoteSource.canonicalURL.absoluteString, destination: remoteSource.canonicalURL)
                    .font(DS.Font.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let channel = remoteSource.channelName {
                    Text(channel).font(DS.Font.caption).foregroundStyle(DS.Palette.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(DS.Palette.box, in: RoundedRectangle(cornerRadius: DS.Radius.box))
    }

    @ViewBuilder
    private var captionsSection: some View {
        if let artifacts = currentRecording.sourceCaptionArtifacts, !artifacts.isEmpty {
            ForEach(Array(artifacts.enumerated()), id: \.offset) { _, artifact in
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    HStack {
                        Text(artifact.provenance == .youtubeAuthored ? String(localized: "YouTube Captions · Authored") : String(localized: "YouTube Captions · Automatic"))
                            .font(DS.Font.headline)
                        Spacer()
                        Button("Export…") { exportCaption(artifact) }
                        Button("Copy Captions") { ClipboardService.shared.copy(text: artifact.text, behavior: .raw) }
                    }
                    .controlSize(.small)
                    ScrollView {
                        Text(artifact.text).textSelection(.enabled).font(DS.Font.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 190)
                }
                .padding(10)
                .background(DS.Palette.box, in: RoundedRectangle(cornerRadius: DS.Radius.box))
            }
        }
    }

    // MARK: - Trim

    private func finishTrimming() {
        playbackService.stop()
        trimEditor = nil
        onNavigationGuardChanged?(nil)
        RecordingTrimNavigation.shared.canLeave = nil
    }

    @discardableResult
    private func saveTrim() -> Bool {
        guard var editor = trimEditor, editor.commitTimeFields() else { return false }
        guard storage.updateTrimRange(id: currentRecording.id, range: editor.rangeToSave) else {
            operationErrorMessage =
                String(localized: "The audio range could not be saved. The recording was left unchanged.")
            return false
        }
        finishTrimming()
        return true
    }

    private func canLeaveTrimEditor() -> Bool {
        guard let editor = trimEditor else { return true }
        guard editor.isDirty else { finishTrimming(); return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Save changes?")
        alert.informativeText = String(localized: "You changed the recording range.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Keep editing"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveTrim()
        case .alertSecondButtonReturn: finishTrimming(); return true
        default: return false
        }
    }

    // MARK: - Export and formatting

    private func exportCaption(_ artifact: TranscriptArtifact) {
        exportText(
            artifact.text,
            title: String(localized: "Export Source Captions"),
            defaultFileName: "YouTube Captions - \(artifact.languageCode).txt"
        )
    }

    private func exportText(_ text: String, title: String, defaultFileName: String) {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = defaultFileName
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            operationErrorMessage = "Could not save the text file: \(error.localizedDescription)"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var formattedDate: String {
        let start = Self.dateFormatter.string(from: currentRecording.createdAt)
        if currentRecording.status == .recording {
            return "\(start) – …"
        }
        if let ended = currentRecording.resolvedEndedAt {
            let endFormatter = DateFormatter()
            endFormatter.dateStyle = .none
            endFormatter.timeStyle = .short
            return "\(start) – \(endFormatter.string(from: ended))"
        }
        return start
    }

    private var formattedDuration: String {
        let totalSeconds: Int = if currentRecording.durationSeconds > 0 {
            Int(currentRecording.effectiveDurationSeconds)
        } else if let ended = currentRecording.resolvedEndedAt {
            max(0, Int(ended.timeIntervalSince(currentRecording.createdAt)))
        } else {
            0
        }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
