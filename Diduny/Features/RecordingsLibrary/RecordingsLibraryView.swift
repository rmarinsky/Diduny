import SwiftUI

enum RecordingsInspectorSelection: Equatable {
    case recording(UUID, parentBatchID: UUID?)
    case batch(UUID)
    case batchComposer
    /// A calendar event of the day, by its occurrence key (`CalendarMeeting.reminderKey`).
    case event(String)
    /// A voice-note group of the day (`RecordingsDay.NotesGroup.key`).
    case notes(String)
    /// A group made with "Group" (`TranscriptionBatch.isRecordingGroup`).
    case group(UUID)
    /// Several recordings chosen with "Select several".
    case selection

    var parentBatchID: UUID? {
        guard case let .recording(_, parentBatchID) = self else { return nil }
        return parentBatchID
    }

    /// The list marks the recording open in the detail; selection mode has its own checkboxes.
    func marksRow(_ recordingID: UUID, isSelectionMode: Bool) -> Bool {
        guard !isSelectionMode else { return false }
        return opensRecording(recordingID)
    }

    func opensRecording(_ recordingID: UUID) -> Bool {
        guard case let .recording(id, _) = self else { return false }
        return id == recordingID
    }

    var backDestination: Self? {
        parentBatchID.map(Self.batch)
    }
}

struct RecordingsLibraryView: View {
    @State var storage = RecordingsLibraryStorage.shared
    @State var batchStorage = TranscriptionBatchStorage.shared
    @State var queueService = RecordingQueueService.shared
    @State var playbackService = AudioPlaybackService.shared
    @State private var searchText = ""
    @State private var searchIndex: [UUID: String] = [:]
    @State var segment: RecordingsSegment = .all
    /// Has Translation, YouTube and Batches, kept in the filter menu.
    @State var listFilter: RecordingTypeFilter?
    @State private var selectedCalendarIDs: Set<String> = []
    @State var inspectorSelection: RecordingsInspectorSelection?
    @State private var trimNavigationGuard: (() -> Bool)?
    @State var isSelectionMode = false
    @State var selectedRecordingIds = Set<UUID>()
    @State private var recordingToRetranscribe: Recording?
    @State private var batchLoadErrorMessage: String?
    @State var operationErrorMessage: String?
    @State var pendingDeletion: RecordingsDeletion?
    @State var flash: RecordingsFlash?
    @State var selectedDay = Date()
    @State var zoom: NotesZoom = .halfHour
    @State var expandedNotes: Set<String> = []
    @State var dayEvents: [CalendarMeeting] = []

    enum RecordingTypeFilter: String, CaseIterable {
        case all = "All"
        case meetings = "Meetings"
        case voiceNotes = "Voice notes"
        case hasTranslation = "Has Translation"
        case files = "Files"
        case youtube = "YouTube"
        case batches = "Batches"

        /// The filter menu beside the segments; the rest are the segments themselves.
        static let menuCases: [Self] = [.hasTranslation, .youtube, .batches]

        var showsBatches: Bool {
            self == .batches
        }

        var menuTitle: String {
            switch self {
            case .hasTranslation: String(localized: "Has translation")
            case .youtube: String(localized: "YouTube")
            case .batches: String(localized: "Batches")
            default: String(localized: String.LocalizationValue(rawValue))
            }
        }

        func matches(_ recording: Recording) -> Bool {
            switch self {
            case .all:
                true
            case .meetings:
                recording.type.isMeetingLike
            case .voiceNotes:
                recording.type == .voice || recording.type == .translation
            case .hasTranslation:
                recording.translationTargetLanguageCode != nil
                    || recording.type == .translation
                    || recording.type == .meetingTranslation
            case .files:
                recording.type == .fileTranscription && !recording.isYouTubeVideo
            case .youtube:
                recording.isYouTubeVideo
            case .batches:
                false
            }
        }
    }

    // MARK: - Derived

    private var matchingRecordings: [Recording] {
        storage.recordings.filter { recording in
            segment.matches(recording) && (listFilter?.matches(recording) ?? true)
                && recording.matchesCalendars(selectedCalendarIDs)
                && Recording.searchableText(searchIndex[recording.id] ?? recording.searchableText, matches: searchText)
        }
    }

    /// Search and the menu filters list every matching recording, across days; otherwise the day is shown.
    private var showsList: Bool {
        !searchText.isEmpty || listFilter != nil
    }

    var recordingGroups: [RecordingsDayGroupInput] {
        batchStorage.batches.filter { $0.isRecordingGroup == true }
            .map { RecordingsDayGroupInput(id: $0.id, name: $0.name, recordingIDs: $0.recordingIDs) }
    }

    var currentDay: RecordingsDay {
        RecordingsDay.build(day: selectedDay, recordings: matchingRecordings,
                            events: segment == .all || segment == .meetings ? dayEvents : [],
                            groups: recordingGroups, zoom: zoom)
    }

    private func rebuildSearchIndex() {
        searchIndex = Dictionary(storage.recordings.map { ($0.id, $0.searchableText) },
                                 uniquingKeysWith: { first, _ in first })
    }

    private var calendarOptions: [CalendarFilterOption] {
        Recording.calendarFilterOptions(storage.recordings)
    }

    private var filteredBatches: [TranscriptionBatch] {
        batchStorage.batches.filter { $0.matches(searchText, recordings: storage.recordings) }
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            let inspectorWidth = Self.inspectorWidth(windowWidth: proxy.size.width + DS.Layout.sidebarWidth)
            HStack(spacing: 0) {
                PageScaffold(title: "Recordings", scrolls: false, columnMaxWidth: DS.Layout.wideColumnMaxWidth) {
                    headerActions
                } content: {
                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        filterToolbar
                        mainContent
                    }
                    .padding(.horizontal, DS.Layout.pagePadding)
                    .padding(.bottom, isSelectionMode ? 0 : DS.Layout.pagePadding)
                }
                .safeAreaInset(edge: .bottom) {
                    if isSelectionMode { selectionBar }
                }
                .frame(maxWidth: .infinity)

                if inspectorSelection != nil {
                    Divider()
                    inspectorContent
                        .frame(width: inspectorWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(DS.Palette.card)
                        .accessibilityIdentifier("recordings.inspector")
                }
            }
        }
        .onAppear {
            batchLoadErrorMessage = batchStorage.loadErrorMessage
            rebuildSearchIndex()
            openRequestedRecordingIfAvailable()
            openRequestedBatchComposerIfAvailable()
        }
        .task(id: Calendar.current.startOfDay(for: selectedDay)) { await loadDayEvents() }
        .onChange(of: MainWindowController.shared.requestedRecordingID) {
            openRequestedRecordingIfAvailable()
        }
        .onChange(of: storage.recordings) {
            openRequestedRecordingIfAvailable()
            rebuildSearchIndex()
        }
        .onChange(of: MainWindowController.shared.requestedBatchComposer) {
            openRequestedBatchComposerIfAvailable()
        }
        .alert(
            "Transcribe Again?",
            isPresented: Binding(
                get: { recordingToRetranscribe != nil },
                set: { if !$0 { recordingToRetranscribe = nil } }
            )
        ) {
            Button("Transcribe Again") {
                if let recordingToRetranscribe {
                    queueService.enqueue([recordingToRetranscribe.id], action: .transcribe)
                }
                recordingToRetranscribe = nil
            }
            Button("Cancel", role: .cancel) {
                recordingToRetranscribe = nil
            }
        } message: {
            Text("This adds a new transcript version. Earlier transcripts and source captions stay available.")
        }
        .alert(
            "Batches Couldn't Be Loaded",
            isPresented: Binding(
                get: { batchLoadErrorMessage != nil },
                set: { if !$0 { batchLoadErrorMessage = nil } }
            )
        ) {
            Button("OK") { batchLoadErrorMessage = nil }
        } message: {
            Text(batchLoadErrorMessage ?? "Unknown error")
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
        .sheet(item: $pendingDeletion) { deletion in
            RecordingsDeletionSheet(deletion: deletion, recordings: storage.recordings) {
                performDeletion(deletion)
            }
        }
    }

    /// 480 inside the window, 560 from a 1700-wide window. The window never resizes itself.
    static func inspectorWidth(windowWidth: CGFloat) -> CGFloat {
        windowWidth >= 1700 ? 560 : 480
    }

    @ViewBuilder
    private var mainContent: some View {
        if listFilter?.showsBatches == true {
            if batchStorage.batches.isEmpty {
                batchesEmptyState
            } else if filteredBatches.isEmpty {
                noResultsState
            } else {
                batchesCard
            }
        } else if storage.recordings.isEmpty, dayEvents.isEmpty {
            emptyState
        } else if showsList {
            if matchingRecordings.isEmpty { noResultsState } else { recordingsCard }
        } else {
            if let flash { RecordingsFlashRow(flash: flash) { self.flash = nil } }
            RecordingsDayView(
                day: currentDay,
                selectedDay: $selectedDay,
                daysWithRecordings: RecordingsWeek.daysWithRecordings(storage.recordings),
                zoom: $zoom,
                expandedNotes: $expandedNotes,
                openSelection: inspectorSelection,
                isSelectionMode: isSelectionMode,
                selectedRecordingIDs: selectedRecordingIds,
                actions: dayActions
            ) { recording in
                recordingRow(recording)
            }
        }
    }

    private var dayActions: RecordingsDayActions {
        RecordingsDayActions(
            openRecording: { requestInspectorSelection(.recording($0, parentBatchID: nil)) },
            openEvent: { requestInspectorSelection(.event($0)) },
            openNotes: { requestInspectorSelection(.notes($0)) },
            openGroup: { requestInspectorSelection(.group($0)) },
            attach: { attach($0, to: $1) },
            detach: { detach($0) },
            toggleSelection: { toggleSelection($0) }
        )
    }

    private func loadDayEvents() async {
        let start = Calendar.current.startOfDay(for: selectedDay)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return }
        // Without calendar access the day still shows the events stored in linked recordings.
        dayEvents = (try? await CalendarConnection.shared.readMeetings(from: start, to: end)) ?? []
    }

    // MARK: - Header

    private var headerActions: some View {
        HStack(spacing: DS.Space.sm) {
            if listFilter?.showsBatches != true {
                Button {
                    toggleSelectionMode()
                } label: {
                    Text(isSelectionMode ? String(localized: "Done") : String(localized: "Select several"))
                }
                .buttonStyle(.bordered)
                .disabled(storage.recordings.isEmpty)
                .accessibilityIdentifier("recordings.selectSeveral")
            }

            Button {
                requestInspectorSelection(.batchComposer)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(DS.Palette.accent)
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .help("Add files and links (⇧⌘B)")
            .accessibilityLabel(Text("Add files and links"))
            .accessibilityIdentifier("recordings.addFiles")
        }
    }

    private func openRequestedBatchComposerIfAvailable() {
        let controller = MainWindowController.shared
        guard controller.requestedBatchComposer else { return }
        controller.requestedBatchComposer = false
        requestInspectorSelection(.batchComposer)
    }

    // MARK: - Filter Toolbar

    private var filterToolbar: some View {
        HStack(spacing: DS.Space.md) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(DS.Font.body)
                TextField(listFilter?.showsBatches == true ? String(localized: "Search batches") : String(localized: "Search meetings, people and transcripts"),
                          text: $searchText)
                    .textFieldStyle(.plain)
                    .font(DS.Font.body)
                    .accessibilityIdentifier("recordings.search")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(DS.Font.callout)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Space.md)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(DS.Palette.box, in: RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous))

            if listFilter?.showsBatches != true {
                ModeSegments(
                    items: RecordingsSegment.allCases.map { segment in
                        .init(id: segment, title: LocalizedStringKey(segment.titleKey),
                              accessibilityID: "recordings.filter.\(segment.rawValue)")
                    },
                    selection: $segment,
                    accessibilityLabel: "Show"
                )
                .fixedSize()
            }

            filterMenu
        }
    }

    /// Has translation, YouTube, Batches and the calendars: reachable, but out of the way.
    private var filterMenu: some View {
        Menu {
            ForEach(RecordingTypeFilter.menuCases, id: \.self) { filter in
                Toggle(filter.menuTitle, isOn: Binding(
                    get: { listFilter == filter },
                    set: { listFilter = $0 ? filter : nil }
                ))
            }
            if !calendarOptions.isEmpty || !selectedCalendarIDs.isEmpty {
                Divider()
                Button {
                    selectedCalendarIDs = []
                } label: {
                    Label("All calendars", systemImage: selectedCalendarIDs.isEmpty ? "checkmark" : "")
                }
                ForEach(calendarOptions, id: \.id) { option in
                    Toggle(option.title, isOn: Binding(
                        get: { selectedCalendarIDs.contains(option.id) },
                        set: { isOn in
                            if isOn { selectedCalendarIDs.insert(option.id) } else { selectedCalendarIDs.remove(option.id) }
                        }
                    ))
                }
            }
        } label: {
            Image(systemName: listFilter == nil && selectedCalendarIDs.isEmpty
                ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More filters")
        .accessibilityLabel(Text("More filters"))
        .accessibilityIdentifier("recordings.filter.more")
    }

    // MARK: - Lists

    func recordingRow(_ recording: Recording) -> some View {
        RecordingRowView(
            recording: recording,
            onOpen: {
                if isSelectionMode {
                    toggleSelection(recording.id)
                } else {
                    requestInspectorSelection(.recording(recording.id, parentBatchID: nil))
                }
            },
            onTranscribe: { transcribe(recording) },
            onDelete: { requestDelete([recording.id]) },
            onProcessRecovery: recording.status == .needsRecovery
                ? { resolveRecovery(recording, action: .processNow) }
                : nil,
            onSaveRecoveryAudio: recording.status == .needsRecovery
                ? { resolveRecovery(recording, action: .saveAudioOnly) }
                : nil,
            isSelectionMode: isSelectionMode,
            isSelected: selectedRecordingIds.contains(recording.id),
            onToggleSelection: { toggleSelection(recording.id) },
            isOpenInDetail: inspectorSelection?.marksRow(recording.id, isSelectionMode: isSelectionMode) ?? false
        )
        .contextMenu { recordingContextMenu(for: recording) }
    }

    private var recordingsCard: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                let recordings = matchingRecordings
                ForEach(Array(recordings.enumerated()), id: \.element.id) { index, recording in
                    recordingRow(recording)
                    if index < recordings.count - 1 {
                        Divider()
                            .padding(.horizontal, 16)
                    }
                }
            }
        }
        .background(DS.Palette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(DS.Palette.cardBorder, lineWidth: 1)
        )
    }

    private var batchesCard: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(filteredBatches.enumerated()), id: \.element.id) { index, batch in
                    Button {
                        requestInspectorSelection(batch.isRecordingGroup == true ? .group(batch.id) : .batch(batch.id))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 32, height: 32)
                                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(batch.name).font(.headline).foregroundStyle(.primary)
                                Text(batch.description.isEmpty ? String(localized: "No description") : batch
                                    .description)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text("\(batch.recordingIDs.count) recordings")
                                Text(batch.status(in: storage.recordings).rawValue)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(inspectorSelection == .batch(batch.id) || inspectorSelection == .group(batch.id)
                            ? DS.Palette.tint : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < filteredBatches.count - 1 { Divider().padding(.horizontal, 16) }
                }
            }
        }
        .background(DS.Palette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(DS.Palette.cardBorder, lineWidth: 1)
        }
    }

    // MARK: - Inspector

    func requestInspectorSelection(_ next: RecordingsInspectorSelection?) {
        guard next != inspectorSelection else { return }
        guard trimNavigationGuard?() ?? true else { return }
        trimNavigationGuard = nil
        flash = nil
        inspectorSelection = next
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch inspectorSelection {
        case let .recording(id, parentBatchID):
            if let recording = storage.recordings.first(where: { $0.id == id }) {
                RecordingDetailView(
                    recording: recording,
                    parentBatchName: parentBatchID.flatMap { id in
                        batchStorage.batches.first(where: { $0.id == id })?.name
                    },
                    onBack: parentBatchID == nil ? nil : {
                        requestInspectorSelection(inspectorSelection?.backDestination)
                    },
                    onClose: { requestInspectorSelection(nil) },
                    onNavigationGuardChanged: { trimNavigationGuard = $0 },
                    calendarActions: recordingCalendarActions(for: recording)
                )
                .id(recording.id)
            }
        case let .batch(id):
            if let batch = batchStorage.batches.first(where: { $0.id == id }) {
                TranscriptionBatchInspectorView(
                    batch: batch,
                    onOpenRecording: { recordingID in
                        requestInspectorSelection(.recording(recordingID, parentBatchID: id))
                    },
                    onClose: { requestInspectorSelection(nil) }
                )
            }
        case .batchComposer:
            NewTranscriptionBatchPanel(
                recordings: storage.recordings,
                onCreated: { batchID in
                    requestInspectorSelection(.batch(batchID))
                },
                onClose: { requestInspectorSelection(nil) }
            )
        case let .event(key):
            eventInspector(key: key)
        case let .notes(key):
            notesInspector(key: key)
        case let .group(id):
            groupInspector(id: id)
        case .selection:
            selectionInspector
        case nil:
            EmptyView()
        }
    }

    private func openRequestedRecordingIfAvailable() {
        let controller = MainWindowController.shared
        guard let id = controller.requestedRecordingID,
              let recording = storage.recordings.first(where: { $0.id == id })
        else { return }

        // A deep link opens the recording on its own day, highlighted.
        searchText = ""
        listFilter = nil
        selectedDay = recording.createdAt
        requestInspectorSelection(.recording(recording.id, parentBatchID: nil))
        controller.requestedRecordingID = nil
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func recordingContextMenu(for recording: Recording) -> some View {
        if recording.status == .needsRecovery {
            Button("Process Now") {
                resolveRecovery(recording, action: .processNow)
            }
            Button("Save Audio Only") {
                resolveRecovery(recording, action: .saveAudioOnly)
            }
            Button("Discard Recovery", role: .destructive) {
                resolveRecovery(recording, action: .discard)
            }
            Divider()
        }

        Button(recording.remoteSource == nil ? "Transcribe" : "Transcribe Again…") {
            transcribe(recording)
        }
        .disabled(recording.status == .processing || recording.status.isInProgressCapture)

        if let text = recording.displayTranscriptText {
            Divider()
            Button("Copy Text") {
                ClipboardService.shared.copy(text: text, behavior: recording.type.clipboardCopyBehavior)
            }
        }

        Divider()

        Button("Delete…", role: .destructive) {
            requestDelete([recording.id])
        }
    }

    func transcribe(_ recording: Recording) {
        guard RecordingTrimNavigation.shared.requestLeave() else { return }
        if recording.remoteSource != nil,
           !(recording.transcriptionText?.isEmpty ?? true)
        {
            recordingToRetranscribe = recording
        } else {
            queueService.enqueue([recording.id], action: .transcribe)
        }
    }

    func resolveRecovery(
        _ recording: Recording,
        action: MeetingRecoveryService.RecoveryAction
    ) {
        Task { @MainActor in
            let outcome = await MeetingRecoveryService.shared.resolve(
                recordingID: recording.id,
                action: action
            )
            if outcome == .failed, action != .discard {
                DictationOverlayController.shared.showInfo(
                    message: String(localized: "Could not recover meeting audio"),
                    duration: 3
                )
            }
        }
    }

    // MARK: - Empty States

    private var emptyState: some View {
        EmptyState(
            icon: "waveform.circle",
            title: "No Recordings Yet",
            message: "Start a meeting with Option Command M, or add files and links with the plus button."
        )
    }

    private var noResultsState: some View {
        EmptyState(icon: "magnifyingglass", title: "No Results")
    }

    private var batchesEmptyState: some View {
        EmptyState(
            icon: "square.stack.3d.up",
            title: "No Batches Yet",
            message: "Create a batch to group related recordings and transcripts."
        )
    }
}

extension RecordingsSegment {
    /// Localization key for `ModeSegments`.
    var titleKey: String {
        switch self {
        case .all: "All"
        case .meetings: "Meetings"
        case .notes: "Notes"
        case .filesAndLinks: "Files and links"
        }
    }
}
