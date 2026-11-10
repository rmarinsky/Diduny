import SwiftUI

/// A one-line result with Undo, after attach, detach, group and ungroup.
struct RecordingsFlash: Identifiable {
    let id = UUID()
    let text: String
    let undo: (() -> Void)?
}

struct RecordingsFlashRow: View {
    let flash: RecordingsFlash
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Text(flash.text).font(DS.Font.callout)
            Spacer(minLength: 0)
            if let undo = flash.undo {
                Button("Undo") { undo(); onDismiss() }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("recordings.flash.undo")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, DS.Space.sm)
        .background(DS.Palette.tint, in: RoundedRectangle(cornerRadius: DS.Radius.box))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recordings.flash")
    }
}

/// Every delete names exactly what it deletes.
struct RecordingsDeletion: Identifiable {
    let id = UUID()
    let recordingIDs: [UUID]
    /// Set when "Delete all" of a group: the group entry goes too.
    var groupID: UUID?
}

struct RecordingsDeletionSheet: View {
    let deletion: RecordingsDeletion
    let recordings: [Recording]
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var doomed: [Recording] {
        deletion.recordingIDs.compactMap { id in recordings.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(doomed.count == 1 ? String(localized: "Delete this recording?") : String(localized: "Delete \(doomed.count) recordings?"))
                .font(DS.Font.headline)
            Text("These are deleted with their audio, transcripts and translations. This cannot be undone.")
                .font(DS.Font.callout)
                .foregroundStyle(DS.Palette.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(doomed) { recording in
                        HStack {
                            Text(recording.displayTitle).lineLimit(1)
                            Spacer(minLength: DS.Space.sm)
                            Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(DS.Palette.secondary)
                                .monospacedDigit()
                        }
                        .font(DS.Font.callout)
                    }
                }
            }
            .frame(maxHeight: 220)
            .accessibilityIdentifier("recordings.delete.list")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(doomed.count == 1 ? String(localized: "Delete") : String(localized: "Delete \(doomed.count)"), role: .destructive) {
                    onDelete()
                    dismiss()
                }
                .accessibilityIdentifier("recordings.delete.confirm")
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 420)
    }
}

/// What the recording inspector can do with the calendar event, routed through the library for Undo.
struct RecordingCalendarActions {
    let overlapping: [CalendarMeeting]
    let attach: (CalendarMeeting) -> Void
    let detach: () -> Void
}

extension RecordingsLibraryView {
    // MARK: - Attach and detach

    func recordingCalendarActions(for recording: Recording) -> RecordingCalendarActions? {
        guard recording.type.canAttachCalendarEvent else { return nil }
        return RecordingCalendarActions(
            overlapping: RecordingsDay.overlappingEvents(for: recording, in: currentDay.items),
            attach: { attach(recording.id, to: $0) },
            detach: { detach(recording.id) }
        )
    }

    func attach(_ id: UUID, to meeting: CalendarMeeting) {
        guard let previous = storage.calendarLinkState(id: id), previous.meeting?.reminderKey != meeting.reminderKey else { return }
        let next = RecordingsLibraryStorage.CalendarLinkState(meeting: meeting, candidates: nil, declined: nil)
        guard storage.setCalendarLink(id: id, next) else {
            operationErrorMessage = String(localized: "The calendar link could not be saved.")
            return
        }
        flash = RecordingsFlash(text: String(localized: "Attached to \(meeting.title)."), undo: {
            storage.setCalendarLink(id: id, previous)
        })
    }

    func detach(_ id: UUID) {
        guard let previous = storage.calendarLinkState(id: id), let meeting = previous.meeting else { return }
        // Detaching means "no calendar event": automatic linking must not undo it.
        let next = RecordingsLibraryStorage.CalendarLinkState(meeting: nil, candidates: nil, declined: true)
        guard storage.setCalendarLink(id: id, next) else {
            operationErrorMessage = String(localized: "The calendar link could not be removed.")
            return
        }
        flash = RecordingsFlash(text: String(localized: "Detached from \(meeting.title)."), undo: {
            storage.setCalendarLink(id: id, previous)
        })
    }

    // MARK: - Selection

    func toggleSelectionMode() {
        isSelectionMode.toggle()
        if !isSelectionMode { cancelSelection() }
    }

    func cancelSelection() {
        isSelectionMode = false
        selectedRecordingIds.removeAll()
        if inspectorSelection == .selection { requestInspectorSelection(nil) }
    }

    func toggleSelection(_ id: UUID) {
        if selectedRecordingIds.contains(id) { selectedRecordingIds.remove(id) } else { selectedRecordingIds.insert(id) }
        if !selectedRecordingIds.isEmpty, inspectorSelection != .selection { requestInspectorSelection(.selection) }
    }

    var selectedRecordings: [Recording] {
        storage.recordings.filter { selectedRecordingIds.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
    }

    var selectionBar: some View {
        HStack(spacing: DS.Space.sm) {
            Text("\(selectedRecordingIds.count) selected")
                .font(DS.Font.calloutStrong)
                .foregroundStyle(DS.Palette.secondary)
            Spacer()
            Button("Group") { groupSelected() }
                .disabled(selectedRecordingIds.count < 2)
                .accessibilityIdentifier("recordings.selection.group")
            Button("Delete…", role: .destructive) { requestDelete(selectedRecordings.map(\.id)) }
                .disabled(selectedRecordingIds.isEmpty)
                .accessibilityIdentifier("recordings.selection.delete")
            Button("Done") { cancelSelection() }
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
        .background(DS.Palette.window)
        .overlay(alignment: .top) { Divider() }
        .accessibilityIdentifier("recordings.selection.bar")
    }

    var selectionInspector: some View {
        RecordingsInspectorShell(title: String(localized: "\(selectedRecordingIds.count) selected"),
                                 subtitle: nil, onClose: { cancelSelection() }) {
            ForEach(selectedRecordings) { recording in
                RecordingsInspectorLine(recording: recording, title: recording.displayTitle) {
                    toggleSelection(recording.id)
                } trailing: {
                    Button("Remove") { toggleSelection(recording.id) }.buttonStyle(.link)
                }
            }
            Text("Group: one item on the day. The recordings stay as they are, and you can ungroup at any time.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.secondary)
                .padding(.top, DS.Space.sm)
            HStack {
                Button("Create group") { groupSelected() }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.Palette.accent)
                    .disabled(selectedRecordingIds.count < 2)
                Button("Delete…", role: .destructive) { requestDelete(selectedRecordings.map(\.id)) }
                    .disabled(selectedRecordingIds.isEmpty)
            }
            .padding(.top, DS.Space.sm)
        }
    }

    // MARK: - Groups

    func groupSelected() {
        let members = selectedRecordings
        guard members.count > 1 else { return }
        // A recording sits in one group at most; moving it silently would change another group.
        let grouped = Set(batchStorage.batches.filter { $0.isRecordingGroup == true }.flatMap(\.recordingIDs))
        if let taken = members.first(where: { grouped.contains($0.id) }) {
            operationErrorMessage = String(localized: "“\(taken.displayTitle)” is already in a group. Ungroup it first.")
            return
        }
        let name = members.compactMap(\.calendarMeeting?.title).first ?? members[0].displayTitle
        do {
            let group = try batchStorage.createRecordingGroup(name: name, recordingIDs: members.map(\.id))
            isSelectionMode = false
            selectedRecordingIds.removeAll()
            requestInspectorSelection(.group(group.id))
            flash = RecordingsFlash(text: String(localized: "Grouped \(members.count) recordings."), undo: {
                do { try batchStorage.ungroup(batchID: group.id) } catch {
                    operationErrorMessage = String(localized: "The group could not be removed.")
                    return
                }
                if inspectorSelection == .group(group.id) { requestInspectorSelection(nil) }
            })
        } catch {
            operationErrorMessage = String(localized: "The group could not be saved.")
        }
    }

    /// Removes the group only. Never `deleteBatch`, which deletes the recordings.
    func ungroup(_ group: TranscriptionBatch) {
        do {
            try batchStorage.ungroup(batchID: group.id)
            requestInspectorSelection(nil)
            flash = RecordingsFlash(text: String(localized: "Ungrouped. The recordings are kept."), undo: {
                try? batchStorage.restoreGroup(group)
            })
        } catch {
            operationErrorMessage = String(localized: "The group could not be removed.")
        }
    }

    // MARK: - Delete

    func requestDelete(_ ids: [UUID], groupID: UUID? = nil) {
        guard !ids.isEmpty, RecordingTrimNavigation.shared.requestLeave() else { return }
        pendingDeletion = RecordingsDeletion(recordingIDs: ids, groupID: groupID)
    }

    func performDeletion(_ deletion: RecordingsDeletion) {
        let ids = Set(deletion.recordingIDs)
        if let playing = playbackService.playingRecordingId, ids.contains(playing) { playbackService.stop() }
        let closesInspector: Bool = switch inspectorSelection {
        case let .recording(id, _): ids.contains(id)
        case let .group(id): id == deletion.groupID
        default: false
        }
        if closesInspector { requestInspectorSelection(nil) }
        guard storage.deleteRecordings(ids) else {
            operationErrorMessage = String(localized: "The recordings and their files were left unchanged.")
            return
        }
        if let groupID = deletion.groupID {
            do { try batchStorage.ungroup(batchID: groupID) } catch {
                operationErrorMessage = String(localized: "The recordings were deleted, but the empty group could not be removed.")
            }
        }
        selectedRecordingIds.subtract(ids)
        if isSelectionMode, selectedRecordingIds.isEmpty { cancelSelection() }
    }

    // MARK: - Event, notes and group inspectors

    @ViewBuilder
    func eventInspector(key: String) -> some View {
        let items = currentDay.items
        if let event = items.lazy.compactMap({ item -> RecordingsDay.Event? in
            if case let .event(event, _, _) = item, event.key == key { return event }
            return nil
        }).first {
            let meeting = event.meeting
            let nearby = items.flatMap(\.recordings).filter { recording in
                !event.attached.contains(recording) && recording.calendarMeeting == nil
                    && recording.createdAt >= meeting.start && recording.createdAt < meeting.end
            }
            RecordingsInspectorShell(
                title: meeting.title,
                subtitle: String(localized: "Calendar event. \(meeting.calendarTitle ?? ""), \(meeting.scheduleLine)"),
                onClose: { requestInspectorSelection(nil) }
            ) {
                if let flash { RecordingsFlashRow(flash: flash) { self.flash = nil } }
                if event.attached.isEmpty {
                    Text("Not recorded. No recording is attached to this event.").font(DS.Font.body)
                }
                ForEach(event.attached) { recording in
                    RecordingsInspectorLine(recording: recording, title: recording.displayTitle) {
                        requestInspectorSelection(.recording(recording.id, parentBatchID: nil))
                    } trailing: {
                        Button("Detach") { detach(recording.id) }.accessibilityIdentifier("recordings.event.detach")
                    }
                }
                if !nearby.isEmpty {
                    RecordingsSectionHeading(title: String(localized: "At the same time, not attached"))
                    ForEach(nearby) { recording in
                        RecordingsInspectorLine(recording: recording, title: recording.displayTitle) {
                            requestInspectorSelection(.recording(recording.id, parentBatchID: nil))
                        } trailing: {
                            Button("Attach") { attach(recording.id, to: meeting) }
                                .accessibilityIdentifier("recordings.event.attach")
                        }
                    }
                } else {
                    Text("To attach a recording, drag it onto the event, or use Attach in the recording.")
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.secondary).padding(.top, DS.Space.sm)
                }
            }
        }
    }

    @ViewBuilder
    func notesInspector(key: String) -> some View {
        if let group = currentDay.items.lazy.compactMap({ item -> RecordingsDay.NotesGroup? in
            if case let .notes(group, _, _) = item, group.key == key { return group }
            return nil
        }).first {
            RecordingsNotesInspector(group: group, onOpen: { requestInspectorSelection(.recording($0, parentBatchID: nil)) },
                                     onClose: { requestInspectorSelection(nil) })
        }
    }

    @ViewBuilder
    func groupInspector(id: UUID) -> some View {
        if let batch = batchStorage.batches.first(where: { $0.id == id }) {
            let members = batch.recordingIDs.compactMap { id in storage.recordings.first { $0.id == id } }
                .sorted { $0.createdAt < $1.createdAt }
            let missing = members.filter(\.needsTranscript)
            RecordingsInspectorShell(
                title: batch.name,
                subtitle: String(localized: "\(members.count) recordings, \(Duration.seconds(members.reduce(0) { $0 + $1.durationSeconds }).formatted(.time(pattern: .hourMinuteSecond))) in total"),
                onClose: { requestInspectorSelection(nil) },
                menu: {
                    Button("Ungroup, keep recordings") { ungroup(batch) }
                        .accessibilityIdentifier("recordings.group.ungroup")
                    Divider()
                    Button("Delete all \(members.count) recordings…", role: .destructive) {
                        requestDelete(members.map(\.id), groupID: batch.id)
                    }
                    .accessibilityIdentifier("recordings.group.deleteAll")
                }
            ) {
                if let flash { RecordingsFlashRow(flash: flash) { self.flash = nil } }
                ForEach(Array(members.enumerated()), id: \.element.id) { index, recording in
                    RecordingsInspectorLine(recording: recording, title: String(localized: "Part \(index + 1)")) {
                        requestInspectorSelection(.recording(recording.id, parentBatchID: nil))
                    } trailing: { EmptyView() }
                }
                HStack {
                    Button(missing.isEmpty ? String(localized: "Transcribe all again")
                        : String(localized: "Transcribe \(missing.count) without transcript")) {
                        queueService.enqueue((missing.isEmpty ? members : missing).map(\.id), action: .transcribe)
                    }
                    Button("Copy all") { ClipboardService.shared.copy(text: RecordingsTranscriptText.joined(members), behavior: .raw) }
                        .disabled(members.allSatisfy { $0.displayTranscriptText == nil })
                }
                .padding(.vertical, DS.Space.sm)
                RecordingsSectionHeading(title: String(localized: "Transcript"))
                ForEach(Array(members.enumerated()), id: \.element.id) { index, recording in
                    Text(verbatim: "\(String(localized: "Part \(index + 1)")), \(recording.createdAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Palette.secondary)
                        .padding(.top, DS.Space.sm)
                    Text(recording.displayTranscriptText ?? String(localized: "Not transcribed yet."))
                        .font(DS.Font.body)
                        .foregroundStyle(recording.displayTranscriptText == nil ? DS.Palette.secondary : DS.Palette.text)
                        .textSelection(.enabled)
                }
                Text("The recordings stay as they are. Ungroup at any time; nothing is lost.")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.secondary).padding(.top, DS.Space.md)
            }
        }
    }
}

enum RecordingsTranscriptText {
    /// Time-ordered text of several recordings, each under its time.
    static func joined(_ recordings: [Recording]) -> String {
        recordings.compactMap { recording in
            recording.displayTranscriptText.map {
                recording.createdAt.formatted(date: .omitted, time: .shortened) + "\n" + $0
            }
        }
        .joined(separator: "\n\n")
    }
}
