import AVFoundation
@testable import Diduny
import XCTest

@MainActor
final class MeetingLiveLibraryRowTests: XCTestCase {
    private var directory: URL!
    private var storage: RecordingsLibraryStorage!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingLiveLibraryRowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let batchStorage = try TranscriptionBatchStorage(baseDirectory: directory)
        storage = RecordingsLibraryStorage(baseDirectory: directory, batchStorage: batchStorage)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testCalendarAssociationSurvivesFinalizationRecoveryAndReload() throws {
        let id = UUID()
        let event = CalendarMeeting(id: "event/occurrence", calendarID: "work", title: "Design review",
                                    start: Date(timeIntervalSince1970: 1_800_000_000),
                                    end: Date(timeIntervalSince1970: 1_800_003_600),
                                    meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        XCTAssertNotNil(storage.beginMeetingRecording(id: id, type: .meeting))
        XCTAssertTrue(storage.linkCalendarMeeting(id: id, meeting: event))
        let wav = directory.appendingPathComponent("calendar.wav")
        try Data("RIFF....WAVEfmt ".utf8).write(to: wav)
        XCTAssertTrue(storage.finalizeInProgressRecording(id: id, audioURL: wav, duration: 30,
                      endedAt: Date(), status: .unprocessed, forceSave: true))
        XCTAssertTrue(storage.markNeedsRecovery(id: id, durationSeconds: 31))
        let restored = RecordingsLibraryStorage(baseDirectory: directory,
                                                batchStorage: try TranscriptionBatchStorage(baseDirectory: directory))
        XCTAssertEqual(restored.recordings.first(where: { $0.id == id })?.calendarMeeting, event)
        XCTAssertTrue(restored.linkCalendarMeeting(id: id, meeting: nil))
        XCTAssertNil(restored.recordings.first(where: { $0.id == id })?.calendarMeeting)
        XCTAssertEqual(restored.recordings.first(where: { $0.id == id })?.calendarLinkDeclined, true,
                       "An unlinked recording is not linked again automatically")
    }

    func testLinkedCalendarMeetingNamesTheRecording() throws {
        let id = UUID()
        let event = CalendarMeeting(id: "event/occurrence", calendarID: "work", title: "Design review",
                                    start: Date(timeIntervalSince1970: 1_800_000_000),
                                    end: Date(timeIntervalSince1970: 1_800_003_600))
        XCTAssertNotNil(storage.beginMeetingRecording(id: id, type: .meeting))
        func recording() throws -> Recording { try XCTUnwrap(storage.recordings.first { $0.id == id }) }
        let typeName = Recording.RecordingType.meeting.displayName

        XCTAssertNil(try recording().specificTitle)
        XCTAssertEqual(try recording().displayTitle, typeName)
        XCTAssertTrue(RecordingRowView.title(for: try recording()).hasPrefix("Meeting — "),
                      "Without a name the library row falls back to the type and time")

        XCTAssertTrue(storage.linkCalendarMeeting(id: id, meeting: event))
        XCTAssertEqual(try recording().displayTitle, "Design review")
        XCTAssertEqual(RecordingRowView.title(for: try recording()), "Design review",
                       "The library row is named after the meeting, not the time it was recorded")

        XCTAssertTrue(storage.updateDetails(id: id, title: "Pilot kickoff", description: ""))
        XCTAssertEqual(try recording().displayTitle, "Pilot kickoff", "The person's own title wins over the calendar")
        XCTAssertEqual(RecordingRowView.title(for: try recording()), "Pilot kickoff")

        XCTAssertTrue(storage.updateDetails(id: id, title: "", description: ""))
        XCTAssertTrue(storage.linkCalendarMeeting(id: id, meeting: nil))
        XCTAssertEqual(try recording().displayTitle, typeName, "Unlinking takes the meeting's name with it")
        XCTAssertTrue(RecordingRowView.title(for: try recording()).hasPrefix("Meeting — "))

        var untitled = event
        untitled.title = "  "
        XCTAssertTrue(storage.linkCalendarMeeting(id: id, meeting: untitled))
        XCTAssertNil(try recording().specificTitle, "A blank event title does not name the recording")
        XCTAssertEqual(try recording().displayTitle, typeName)
    }

    func testRowButtonCopiesTheTranscriptAndTranscribesOnlyWithoutOne() {
        func recording(_ status: Recording.ProcessingStatus, text: String? = nil,
                       segments: [TimedTranscriptSegment]? = nil) -> Recording {
            Recording(id: UUID(), createdAt: Date(timeIntervalSince1970: 1_800_000_000), type: .meeting,
                      audioFileName: "a.wav", durationSeconds: 60, fileSizeBytes: 1, status: status,
                      transcriptionText: text, sourceDevice: nil, transcriptSegments: segments)
        }
        let segment = TimedTranscriptSegment(startMilliseconds: 65_000, speaker: "1", text: "Ship it")

        XCTAssertEqual(RecordingRowView.primaryAction(for: recording(.transcribed, text: "Ship it")), .copy("Ship it"))
        XCTAssertEqual(RecordingRowView.primaryAction(for: recording(.transcribed, text: "Ship it", segments: [segment])),
                       .copy("[01:05] Speaker 1: Ship it"), "Copies the transcript as shown, with time and speaker")
        XCTAssertEqual(RecordingRowView.primaryAction(for: recording(.unprocessed)), .transcribe,
                       "Without a transcript the button still transcribes")
        XCTAssertEqual(RecordingRowView.primaryAction(for: recording(.failed, text: "")), .transcribe)
        XCTAssertEqual(RecordingRowView.primaryAction(for: recording(.processing, text: "Ship it")), .hidden)
        XCTAssertEqual(RecordingRowView.primaryAction(for: recording(.recording)), .hidden)
        XCTAssertEqual(RecordingRowView.primaryAction(for: recording(.needsRecovery)), .hidden)
    }

    func testOlderTimeNamedMeetingRecordingsTakeTheNameOfTheMeetingRunningThen() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func record(_ id: UUID, at offset: TimeInterval, savedTitle: String? = nil) throws {
            XCTAssertNotNil(storage.beginMeetingRecording(id: id, type: .meeting, createdAt: start.addingTimeInterval(offset)))
            let wav = directory.appendingPathComponent("\(id).wav")
            try Data("RIFF....WAVEfmt ".utf8).write(to: wav)
            XCTAssertTrue(storage.finalizeInProgressRecording(id: id, audioURL: wav, duration: 1800,
                          endedAt: start.addingTimeInterval(offset + 1800), status: .unprocessed, forceSave: true))
            if let savedTitle { XCTAssertTrue(storage.updateDetails(id: id, title: savedTitle, description: "Notes")) }
        }
        func event(_ id: String, _ title: String, at offset: TimeInterval) -> CalendarMeeting {
            CalendarMeeting(id: id, calendarID: "work", title: title,
                            start: start.addingTimeInterval(offset), end: start.addingTimeInterval(offset + 1800))
        }
        // Older releases prefilled the title field with the type's name, so "Save Details" stored it,
        // in whichever language the app ran in then.
        let plain = UUID(), savedEnglish = UUID(), savedUkrainian = UUID(), named = UUID()
        try record(plain, at: 0)
        try record(savedEnglish, at: 7200, savedTitle: "Meeting")
        try record(savedUkrainian, at: 14400, savedTitle: "Зустріч")
        try record(named, at: 21600, savedTitle: "Board sync")
        let events = [event("standup", "Daily standup", at: 0), event("review", "Design review", at: 7200),
                      event("retro", "Sprint retro", at: 14400), event("planning", "Quarter planning", at: 21600)]
        XCTAssertTrue(RecordingRowView.title(for: try XCTUnwrap(storage.recordings.first { $0.id == plain })).hasPrefix("Meeting — "))

        let connection = CalendarConnection(defaults: UserDefaults(suiteName: "CalendarRename-\(UUID())")!, authorize: { true },
                                            read: { _ in ScheduledCalendarSnapshot(calendars: [.init(id: "work", title: "Work", source: "Test")], meetings: []) },
                                            readRange: { _, _, _ in events })
        defer { connection.disconnect() }
        await connection.connect()
        await CalendarRecordingLinker().run(storage: storage, connection: connection)

        let restored = RecordingsLibraryStorage(baseDirectory: directory, batchStorage: try TranscriptionBatchStorage(baseDirectory: directory))
        func rowTitle(_ id: UUID) throws -> String { RecordingRowView.title(for: try XCTUnwrap(restored.recordings.first { $0.id == id })) }
        XCTAssertEqual(try rowTitle(plain), "Daily standup", "An older recording is named after the meeting running then")
        XCTAssertEqual(try rowTitle(savedEnglish), "Design review", "A saved type name is not the person's title")
        XCTAssertEqual(try rowTitle(savedUkrainian), "Sprint retro", "Nor is the type name saved in another language")
        XCTAssertEqual(try rowTitle(named), "Board sync", "A title the person typed is kept")
        XCTAssertTrue(Recording.RecordingType.allCases.allSatisfy { $0.storedNamePlaceholders.contains($0.displayName) },
                      "Every type's name is recognized when it was saved as a title")
        var voiceNote = try XCTUnwrap(restored.recordings.first { $0.id == plain })
        voiceNote = Recording(id: voiceNote.id, createdAt: voiceNote.createdAt, type: .voice, audioFileName: voiceNote.audioFileName,
                              durationSeconds: voiceNote.durationSeconds, fileSizeBytes: voiceNote.fileSizeBytes,
                              status: voiceNote.status, sourceDevice: nil, title: "Meeting")
        XCTAssertEqual(voiceNote.displayTitle, "Meeting", "Another type's name is a real title")
    }

    func testPastMeetingRecordingsLinkToCalendarEventsWithoutOverridingThePerson() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func record(_ id: UUID, from: TimeInterval, to: TimeInterval) throws {
            XCTAssertNotNil(storage.beginMeetingRecording(id: id, type: .meeting, createdAt: start.addingTimeInterval(from)))
            let wav = directory.appendingPathComponent("\(id).wav")
            try Data("RIFF....WAVEfmt ".utf8).write(to: wav)
            XCTAssertTrue(storage.finalizeInProgressRecording(id: id, audioURL: wav, duration: to - from,
                          endedAt: start.addingTimeInterval(to), status: .unprocessed, forceSave: true))
        }
        let single = UUID(), double = UUID(), unlinked = UUID()
        try record(single, from: -120, to: 1800)
        try record(double, from: 7200, to: 10800)
        try record(unlinked, from: 20000, to: 21000)
        var review = CalendarMeeting(id: "review", calendarID: "work", title: "Design review",
                                     start: start, end: start.addingTimeInterval(1800))
        review.attendees = [CalendarAttendee(name: "Olena Kovalenko", email: "olena@example.com", response: .accepted)]
        review.notes = "Pilot scope"
        let first = CalendarMeeting(id: "a", calendarID: "work", title: "A", start: start.addingTimeInterval(7200), end: start.addingTimeInterval(9000))
        let second = CalendarMeeting(id: "b", calendarID: "work", title: "B", start: start.addingTimeInterval(9000), end: start.addingTimeInterval(10800))
        let unrelated = CalendarMeeting(id: "u", calendarID: "work", title: "U", start: start.addingTimeInterval(20000), end: start.addingTimeInterval(21000))
        XCTAssertTrue(storage.chooseCalendarMeeting(id: unlinked, meeting: nil), "The person removed this link earlier")

        var reads = 0
        let connection = CalendarConnection(defaults: UserDefaults(suiteName: "CalendarLinker-\(UUID())")!, authorize: { true },
                                            read: { _ in ScheduledCalendarSnapshot(calendars: [.init(id: "work", title: "Work", source: "Test")], meetings: []) },
                                            readRange: { selected, from, to in
                                                reads += 1
                                                XCTAssertEqual(selected, ["work"])
                                                XCTAssertLessThanOrEqual(from, start.addingTimeInterval(-120))
                                                XCTAssertGreaterThanOrEqual(to, start.addingTimeInterval(10800))
                                                return [review, first, second, unrelated]
                                            })
        defer { connection.disconnect() }
        await connection.connect()
        let linker = CalendarRecordingLinker()
        await linker.run(storage: storage, connection: connection)
        await linker.run(storage: storage, connection: connection)
        XCTAssertEqual(reads, 1, "Nothing changed, so the calendar is not read again")

        let restored = RecordingsLibraryStorage(baseDirectory: directory, batchStorage: try TranscriptionBatchStorage(baseDirectory: directory))
        let linked = try XCTUnwrap(restored.recordings.first { $0.id == single })
        XCTAssertEqual(linked.calendarMeeting, review, "The meeting details are kept with the recording")
        XCTAssertEqual(restored.recordings.first { $0.id == double }?.calendarCandidates, [first, second])
        XCTAssertNil(restored.recordings.first { $0.id == double }?.calendarMeeting)
        XCTAssertNil(restored.recordings.first { $0.id == unlinked }?.calendarMeeting)

        let later = UUID()
        let laterStorage = restored
        XCTAssertNotNil(laterStorage.beginMeetingRecording(id: later, type: .meeting, createdAt: start.addingTimeInterval(30000)))
        let laterWav = directory.appendingPathComponent("later.wav")
        try Data("RIFF....WAVEfmt ".utf8).write(to: laterWav)
        XCTAssertTrue(laterStorage.finalizeInProgressRecording(id: later, audioURL: laterWav, duration: 600,
                      endedAt: start.addingTimeInterval(30600), status: .unprocessed, forceSave: true))
        var ranges: [(Date, Date)] = []
        let rangeConnection = CalendarConnection(defaults: UserDefaults(suiteName: "CalendarLinkerRange-\(UUID())")!, authorize: { true },
                                                 read: { _ in ScheduledCalendarSnapshot(calendars: [.init(id: "work", title: "Work", source: "Test")], meetings: []) },
                                                 readRange: { _, from, to in ranges.append((from, to)); return [] })
        defer { rangeConnection.disconnect() }
        await rangeConnection.connect()
        let laterLinker = CalendarRecordingLinker()
        await laterLinker.run(storage: laterStorage, connection: rangeConnection)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(ranges.first).0, start.addingTimeInterval(20000),
                           "Only the new recording's time is read, not back to the oldest recording")
        await laterLinker.run(storage: laterStorage, connection: rangeConnection)
        XCTAssertEqual(ranges.count, 1, "A recording that matched nothing is not read again")
        laterLinker.calendarChanged()
        await laterLinker.run(storage: laterStorage, connection: rangeConnection)
        XCTAssertEqual(ranges.count, 2, "After the calendar changes, an unmatched recording is tried again")

        XCTAssertTrue(restored.chooseCalendarMeeting(id: double, meeting: second))
        XCTAssertEqual(restored.recordings.first { $0.id == double }?.calendarMeeting, second)
        XCTAssertNil(restored.recordings.first { $0.id == double }?.calendarCandidates)
    }

    func test_beginMeetingRecording_createsRecordingStatusRowWithoutAudio() throws {
        let id = UUID()
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let result = storage.beginMeetingRecording(id: id, type: .meeting, createdAt: started)
        XCTAssertEqual(result, id)

        let row = try XCTUnwrap(storage.recordings.first(where: { $0.id == id }))
        XCTAssertEqual(row.status, .recording)
        XCTAssertEqual(row.createdAt, started)
        XCTAssertNil(row.endedAt)
        XCTAssertTrue(row.audioFileName.isEmpty)
        XCTAssertFalse(storage.hasPlayableAudio(for: row))
    }

    func test_beginMeetingRecording_saveFailurePreservesExistingRecoveryRow() throws {
        let id = UUID()
        _ = storage.beginMeetingRecording(id: id, type: .meeting)
        XCTAssertTrue(storage.markNeedsRecovery(id: id))
        let existing = try XCTUnwrap(storage.recordings.first(where: { $0.id == id }))

        let metadataURL = directory.appendingPathComponent("recordings_metadata.json")
        try FileManager.default.removeItem(at: metadataURL)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)

        XCTAssertNil(storage.beginMeetingRecording(id: id, type: .meeting))
        XCTAssertEqual(storage.recordings.first(where: { $0.id == id }), existing)
    }

    func test_rejectedMeetingStartClearsOnlyItsOwnedPendingState() async {
        let delegate = AppDelegate()
        delegate.meetingPipelineGeneration = 4
        delegate.appState.meetingRecordingState = .processing
        var requestedPermission = false
        await delegate.startMeetingRecording(provider: .local, pipelineGeneration: 4,
            canStart: { false }, ensureScreenRecordingPermission: { requestedPermission = true; return true })
        XCTAssertFalse(requestedPermission)
        XCTAssertEqual(delegate.appState.meetingRecordingState, .idle)

        delegate.meetingPipelineGeneration = 5
        delegate.appState.meetingRecordingState = .processing
        await delegate.startMeetingRecording(provider: .local, pipelineGeneration: 4,
            canStart: { false }, ensureScreenRecordingPermission: { requestedPermission = true; return true })
        XCTAssertEqual(delegate.appState.meetingRecordingState, .processing)
        XCTAssertFalse(requestedPermission)
        delegate.appState.meetingRecordingState = .idle
    }

    func test_abandonMeetingForRecovery_releasesRecorderSleepTokenAndKeepsRowRecoverable() async throws {
        let delegate = AppDelegate()
        let id = UUID()
        XCTAssertNotNil(storage.beginMeetingRecording(id: id, type: .meeting))
        delegate.appState.meetingRecordingState = .error
        delegate.meetingActivityToken = ProcessInfo.processInfo.beginActivity(
            options: .idleSystemSleepDisabled,
            reason: "test"
        )
        delegate.activeMeetingTranscriptionSessionID = UUID()
        var releaseCount = 0

        await delegate.abandonMeetingForRecovery(startedAt: Date().addingTimeInterval(-90), library: storage) {
            releaseCount += 1
            return id
        }

        XCTAssertEqual(releaseCount, 1, "The recorder must stop so the next meeting is not silently ignored")
        XCTAssertNil(delegate.meetingActivityToken, "Idle-sleep assertion must be released")
        XCTAssertNil(delegate.activeMeetingTranscriptionSessionID)
        let row = try XCTUnwrap(storage.recordings.first(where: { $0.id == id }))
        XCTAssertEqual(row.status, .needsRecovery)
        XCTAssertEqual(row.durationSeconds, 90, accuracy: 2)
        XCTAssertEqual(delegate.appState.meetingRecordingState, .error, "Error stays visible until its auto-reset")
    }

    func test_finalizeInProgressRecording_attachesAudioAndEndedAt() throws {
        let id = UUID()
        _ = storage.beginMeetingRecording(id: id, type: .meeting)

        let wav = directory.appendingPathComponent("source.wav")
        try Data("RIFF....WAVEfmt ".utf8).write(to: wav)

        let ended = Date()
        let ok = storage.finalizeInProgressRecording(
            id: id,
            audioURL: wav,
            duration: 42,
            endedAt: ended,
            status: .processing,
            forceSave: true
        )
        XCTAssertTrue(ok)

        let row = try XCTUnwrap(storage.recordings.first(where: { $0.id == id }))
        XCTAssertEqual(row.status, .processing)
        XCTAssertEqual(row.durationSeconds, 42, accuracy: 0.001)
        XCTAssertEqual(row.endedAt?.timeIntervalSince1970 ?? 0, ended.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertFalse(row.audioFileName.isEmpty)
        XCTAssertTrue(storage.hasPlayableAudio(for: row))
    }

    func test_resetInterruptedProcessingStates_promotesRecordingToNeedsRecovery() {
        var recordings = [
            Recording(
                id: UUID(),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                endedAt: nil,
                type: .meeting,
                audioFileName: "",
                durationSeconds: 0,
                fileSizeBytes: 0,
                status: .recording,
                sourceDevice: nil
            )
        ]
        let didReset = RecordingsLibraryStorage.resetInterruptedProcessingStates(in: &recordings)
        XCTAssertTrue(didReset)
        XCTAssertEqual(recordings[0].status, .needsRecovery)
        XCTAssertEqual(recordings[0].recoverySource, .orphanedSession)
        XCTAssertNotNil(recordings[0].endedAt)
    }

    func test_legacyJSON_endedAtIsNil() throws {
        let legacyJSON = """
        [
          {
            "id": "12345678-1234-1234-1234-123456789ABC",
            "createdAt": "2025-11-01T10:00:00Z",
            "type": "meeting",
            "audioFileName": "12345678-1234-1234-1234-123456789ABC.wav",
            "durationSeconds": 3600.0,
            "fileSizeBytes": 675000000,
            "status": "transcribed"
          }
        ]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let recordings = try decoder.decode([Recording].self, from: data)
        XCTAssertNil(recordings[0].endedAt)
        XCTAssertNil(recordings[0].statusDetail)
        let resolvedEndedAt = try XCTUnwrap(recordings[0].resolvedEndedAt)
        XCTAssertEqual(
            resolvedEndedAt.timeIntervalSince1970,
            recordings[0].createdAt.addingTimeInterval(3600).timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func test_markNeedsRecovery_setsStatusAndSource() throws {
        let id = UUID()
        _ = storage.beginMeetingRecording(id: id, type: .meetingTranslation)
        let ended = Date()
        XCTAssertTrue(storage.markNeedsRecovery(id: id, endedAt: ended, durationSeconds: 12))
        let row = try XCTUnwrap(storage.recordings.first(where: { $0.id == id }))
        XCTAssertEqual(row.status, .needsRecovery)
        XCTAssertEqual(row.recoverySource, .orphanedSession)
        XCTAssertEqual(row.durationSeconds, 12, accuracy: 0.001)
    }

    func test_promoteOrphanedMeeting_doesNotReportFailedPersistence() async throws {
        let id = UUID()
        XCTAssertEqual(storage.beginMeetingRecording(id: id, type: .meeting), id)
        let inProgressStore = try InProgressRecordingStore(
            baseDirectory: directory.appendingPathComponent("InProgressRecordings")
        )
        _ = try await inProgressStore.directoryURL(for: id)

        let metadataURL = directory.appendingPathComponent("recordings_metadata.json")
        try FileManager.default.removeItem(at: metadataURL)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)

        let promoted = await AppDelegate().promoteOrphanedInProgressMeetings(
            store: inProgressStore,
            storage: storage
        )

        XCTAssertFalse(promoted.contains(id))
        XCTAssertEqual(storage.recordings.first(where: { $0.id == id })?.status, .recording)
    }

    func test_recoveryStitchFailureKeepsRowRecoverable() async throws {
        let id = UUID()
        let inProgressStore = try InProgressRecordingStore(
            baseDirectory: directory.appendingPathComponent("InProgressRecordings")
        )
        let recoveryService = MeetingRecoveryService(
            storage: storage,
            inProgressStore: inProgressStore
        )
        XCTAssertEqual(storage.beginMeetingRecording(id: id, type: .meeting), id)
        XCTAssertTrue(storage.markNeedsRecovery(id: id))

        let resolved = await recoveryService.resolve(
            recordingID: id,
            action: .saveAudioOnly
        )

        XCTAssertFalse(resolved)
        let row = try XCTUnwrap(storage.recordings.first(where: { $0.id == id }))
        XCTAssertEqual(row.status, .needsRecovery)
        XCTAssertEqual(row.statusDetail, "Could not recover meeting audio")
    }

    /// A session killed mid-recording: the audio is on disk, the WAV header says "no samples".
    private func writeKilledChunk(to url: URL, seconds: Int) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16000))
            buffer.frameLength = 16000
            for _ in 0 ..< seconds { try file.write(from: buffer) }
        }
        var bytes = try Data(contentsOf: url)
        let dataTag = try XCTUnwrap(bytes.range(of: Data("data".utf8))).lowerBound
        bytes.replaceSubrange(dataTag + 4 ..< dataTag + 8, with: Data(count: 4))
        try bytes.write(to: url)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 0, "Fixture must match a killed writer")
    }

    func test_recoveryOfKilledSession_savesPlayableAudioAndLeavesNeedsRecovery() async throws {
        let id = UUID()
        let inProgressStore = try InProgressRecordingStore(
            baseDirectory: directory.appendingPathComponent("InProgressRecordings")
        )
        let recoveryService = MeetingRecoveryService(storage: storage, inProgressStore: inProgressStore)
        XCTAssertEqual(storage.beginMeetingRecording(id: id, type: .meeting), id)
        XCTAssertTrue(storage.markNeedsRecovery(id: id))
        try writeKilledChunk(to: try await inProgressStore.chunkURL(for: id), seconds: 3)

        let resolved = await recoveryService.resolve(recordingID: id, action: .saveAudioOnly)

        XCTAssertTrue(resolved)
        let row = try XCTUnwrap(storage.recordings.first(where: { $0.id == id }))
        XCTAssertEqual(row.status, .unprocessed)
        XCTAssertNil(row.statusDetail)
        XCTAssertTrue(storage.hasPlayableAudio(for: row))
        XCTAssertEqual(row.durationSeconds, 3, accuracy: 0.01)
    }

    func test_unrecoverableChunkIsKeptAndRowReportsTheFailure() async throws {
        let id = UUID()
        let inProgressStore = try InProgressRecordingStore(
            baseDirectory: directory.appendingPathComponent("InProgressRecordings")
        )
        let recoveryService = MeetingRecoveryService(storage: storage, inProgressStore: inProgressStore)
        XCTAssertEqual(storage.beginMeetingRecording(id: id, type: .meeting), id)
        XCTAssertTrue(storage.markNeedsRecovery(id: id))
        let chunk = try await inProgressStore.chunkURL(for: id)
        let garbage = Data("not audio".utf8)
        try garbage.write(to: chunk)

        let resolved = await recoveryService.resolve(recordingID: id, action: .processNow)

        XCTAssertFalse(resolved)
        let row = try XCTUnwrap(storage.recordings.first(where: { $0.id == id }))
        XCTAssertEqual(row.status, .needsRecovery)
        XCTAssertEqual(row.statusDetail, "Could not recover meeting audio")
        XCTAssertEqual(try Data(contentsOf: chunk), garbage, "The source chunk is never changed by a failed attempt")
    }

    func test_deleteRecording_removesRecoveryRowWithoutAttachedAudio() throws {
        let id = UUID()
        _ = storage.beginMeetingRecording(id: id, type: .meeting)
        XCTAssertTrue(storage.markNeedsRecovery(id: id))
        let row = try XCTUnwrap(storage.recordings.first(where: { $0.id == id }))

        XCTAssertTrue(storage.deleteRecording(row))
        XCTAssertFalse(storage.recordings.contains(where: { $0.id == id }))
    }

    func test_deleteRecording_rejectsActiveMeetingCapture() throws {
        let id = UUID()
        let inProgressDirectory = directory
            .appendingPathComponent("InProgressRecordings")
            .appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(
            at: inProgressDirectory,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(storage.beginMeetingRecording(id: id, type: .meeting), id)
        let row = try XCTUnwrap(storage.recordings.first(where: { $0.id == id }))

        XCTAssertFalse(storage.deleteRecording(row))
        XCTAssertTrue(storage.recordings.contains(where: { $0.id == id }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inProgressDirectory.path))
    }

    func test_deleteCancelledInProgressRecording_removesLiveRowAndRawDirectory() throws {
        let id = UUID()
        let inProgressDirectory = directory
            .appendingPathComponent("InProgressRecordings")
            .appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(
            at: inProgressDirectory,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(storage.beginMeetingRecording(id: id, type: .meeting), id)
        let row = try XCTUnwrap(storage.recordings.first(where: { $0.id == id }))

        XCTAssertTrue(storage.deleteCancelledInProgressRecording(row))
        XCTAssertFalse(storage.recordings.contains(where: { $0.id == id }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inProgressDirectory.path))
    }

    func test_deleteRecordings_cleansInProgressDirectory() async throws {
        let id = UUID()
        let inProgressStore = try InProgressRecordingStore(
            baseDirectory: directory.appendingPathComponent("InProgressRecordings")
        )
        let inProgressDirectory = try await inProgressStore.directoryURL(for: id)
        try Data("chunk".utf8).write(
            to: inProgressDirectory.appendingPathComponent("chunk_001.wav")
        )
        _ = storage.beginMeetingRecording(id: id, type: .meeting)
        XCTAssertTrue(storage.markNeedsRecovery(id: id))

        XCTAssertTrue(storage.deleteRecordings(Set([id])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inProgressDirectory.path))
    }

    func test_startupRetriesPendingDeletionCleanup() throws {
        let appDirectory = directory.appendingPathComponent("PendingDeletionCleanup")
        let inProgressDirectory = appDirectory
            .appendingPathComponent("InProgressRecordings")
            .appendingPathComponent(".meeting.deleting-test")
        try FileManager.default.createDirectory(
            at: inProgressDirectory,
            withIntermediateDirectories: true
        )
        try Data("chunk".utf8).write(
            to: inProgressDirectory.appendingPathComponent("chunk_001.wav")
        )
        let cleanupURL = appDirectory.appendingPathComponent("recordings_delete_cleanup.json")
        try JSONEncoder().encode([inProgressDirectory.path]).write(to: cleanupURL)
        try Data("[]".utf8).write(
            to: appDirectory.appendingPathComponent("recordings_metadata.json")
        )
        let batchStorage = try TranscriptionBatchStorage(baseDirectory: appDirectory)

        _ = RecordingsLibraryStorage(
            baseDirectory: appDirectory,
            batchStorage: batchStorage
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: inProgressDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanupURL.path))
    }

    func test_startupRejectsPendingDeletionOutsideOwnedDirectories() throws {
        let appDirectory = directory.appendingPathComponent("InvalidPendingDeletionCleanup")
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        let unrelatedFile = directory.appendingPathComponent(".unrelated.deleting-test")
        try Data("keep".utf8).write(to: unrelatedFile)
        let cleanupURL = appDirectory.appendingPathComponent("recordings_delete_cleanup.json")
        try JSONEncoder().encode([unrelatedFile.path]).write(to: cleanupURL)
        try Data("[]".utf8).write(
            to: appDirectory.appendingPathComponent("recordings_metadata.json")
        )
        let batchStorage = try TranscriptionBatchStorage(baseDirectory: appDirectory)

        _ = RecordingsLibraryStorage(
            baseDirectory: appDirectory,
            batchStorage: batchStorage
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleanupURL.path))
    }

    func test_nextDeletionAlsoRetriesPreviouslyPendingCleanup() throws {
        let inProgressRoot = directory.appendingPathComponent("InProgressRecordings")
        let previouslyStaged = inProgressRoot.appendingPathComponent(".previous.deleting-test")
        try FileManager.default.createDirectory(at: previouslyStaged, withIntermediateDirectories: true)
        try Data("old chunk".utf8).write(
            to: previouslyStaged.appendingPathComponent("chunk_001.wav")
        )
        try JSONEncoder().encode([previouslyStaged.path]).write(
            to: directory.appendingPathComponent("recordings_delete_cleanup.json")
        )

        let id = UUID()
        let currentDirectory = inProgressRoot.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        XCTAssertEqual(storage.beginMeetingRecording(id: id, type: .meeting), id)
        XCTAssertTrue(storage.markNeedsRecovery(id: id))

        XCTAssertTrue(storage.deleteRecordings(Set([id])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previouslyStaged.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("recordings_delete_cleanup.json").path
        ))
    }

    func test_deleteRemainsCommittedWhenRecoveryJournalCannotBeRemoved() throws {
        let appDirectory = directory.appendingPathComponent("RecoveryJournalRemovalFailure")
        let batchStorage = try TranscriptionBatchStorage(baseDirectory: appDirectory)
        let storage = RecordingsLibraryStorage(
            baseDirectory: appDirectory,
            batchStorage: batchStorage,
            deletionRecoveryRemover: { _ in throw CocoaError(.fileWriteNoPermission) }
        )
        let id = UUID()
        let inProgressDirectory = appDirectory
            .appendingPathComponent("InProgressRecordings")
            .appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(
            at: inProgressDirectory,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(storage.beginMeetingRecording(id: id, type: .meeting), id)
        let batch = try batchStorage.create(name: "Meeting", recordingIDs: [id])
        let row = try XCTUnwrap(storage.recordings.first(where: { $0.id == id }))

        XCTAssertTrue(storage.deleteCancelledInProgressRecording(row))
        XCTAssertFalse(storage.recordings.contains(where: { $0.id == id }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inProgressDirectory.path))
        XCTAssertEqual(
            batchStorage.batches.first(where: { $0.id == batch.id })?.recordingIDs,
            []
        )

        let reloadedStorage = RecordingsLibraryStorage(
            baseDirectory: appDirectory,
            batchStorage: batchStorage
        )
        XCTAssertFalse(reloadedStorage.recordings.contains(where: { $0.id == id }))
        XCTAssertEqual(
            batchStorage.batches.first(where: { $0.id == batch.id })?.recordingIDs,
            []
        )
    }

    func test_deleteDoesNotOverwriteUnresolvedRecoveryJournal() throws {
        let id = UUID()
        let inProgressDirectory = directory
            .appendingPathComponent("InProgressRecordings")
            .appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(
            at: inProgressDirectory,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(storage.beginMeetingRecording(id: id, type: .meeting), id)
        let row = try XCTUnwrap(storage.recordings.first(where: { $0.id == id }))
        let recovery = RecordingDeletionRecovery(
            recordings: storage.recordings,
            stagedFiles: []
        )
        try JSONEncoder().encode(recovery).write(
            to: directory.appendingPathComponent("recordings_delete_recovery.json")
        )

        XCTAssertFalse(storage.deleteCancelledInProgressRecording(row))
        XCTAssertTrue(storage.recordings.contains(where: { $0.id == id }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inProgressDirectory.path))
    }

    func test_unresolvedDeletionJournalBlocksNewRecordingSave() throws {
        let recovery = RecordingDeletionRecovery(
            recordings: storage.recordings,
            stagedFiles: []
        )
        try JSONEncoder().encode(recovery).write(
            to: directory.appendingPathComponent("recordings_delete_recovery.json")
        )

        let savedID = storage.saveRecording(
            audioData: Data("new".utf8),
            type: .meeting,
            duration: 1,
            forceSave: true
        )

        XCTAssertNil(savedID)
        XCTAssertTrue(storage.recordings.isEmpty)
    }

    func test_deleteCanRetryAfterTransientMetadataWriteFailure() throws {
        let appDirectory = directory.appendingPathComponent("TransientMetadataFailure")
        let batchStorage = try TranscriptionBatchStorage(baseDirectory: appDirectory)
        var failNextWrite = false
        let storage = RecordingsLibraryStorage(
            baseDirectory: appDirectory,
            batchStorage: batchStorage,
            synchronousMetadataWriter: { recordings, url in
                if failNextWrite {
                    failNextWrite = false
                    return false
                }
                do {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    try encoder.encode(recordings).write(to: url, options: .atomic)
                    return true
                } catch {
                    return false
                }
            }
        )
        let id = UUID()
        XCTAssertEqual(storage.beginMeetingRecording(id: id, type: .meeting), id)
        XCTAssertTrue(storage.markNeedsRecovery(id: id))
        failNextWrite = true

        XCTAssertFalse(storage.deleteRecordings(Set([id])))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: appDirectory.appendingPathComponent("recordings_delete_recovery.json").path
        ))
        XCTAssertTrue(storage.deleteRecordings(Set([id])))
    }

    func test_recoveryDuration_clampsFutureStartToZero() {
        let endedAt = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            AppDelegate.recoveryDuration(
                startedAt: endedAt.addingTimeInterval(5),
                endedAt: endedAt
            ),
            0
        )
    }

    func test_recoveryDuration_preservesElapsedTimeAndMissingStart() {
        let endedAt = Date(timeIntervalSince1970: 1_700_000_010)

        XCTAssertEqual(
            AppDelegate.recoveryDuration(
                startedAt: endedAt.addingTimeInterval(-10),
                endedAt: endedAt
            ),
            10
        )
        XCTAssertNil(AppDelegate.recoveryDuration(startedAt: nil, endedAt: endedAt))
    }


    func test_cloudUsageRejection_switchesActiveMeetingToLocal() {
        let delegate = AppDelegate()
        let sessionID = UUID()
        delegate.activeMeetingTranscriptionSessionID = sessionID
        delegate.activeMeetingTranscriptionProvider = .cloud

        XCTAssertTrue(delegate.fallBackMeetingToLocalIfUsageUnavailable(
            RealtimeTranscriptionError.usageLimitExceeded(usedHours: 5, limitHours: 5),
            sessionID: sessionID
        ))
        XCTAssertEqual(delegate.activeMeetingTranscriptionProvider, .local)

        XCTAssertFalse(delegate.fallBackMeetingToLocalIfUsageUnavailable(
            RealtimeTranscriptionError.connectionFailed("offline"),
            sessionID: sessionID
        ))
        XCTAssertEqual(delegate.activeMeetingTranscriptionProvider, .local)

        let nextSessionID = UUID()
        delegate.activeMeetingTranscriptionSessionID = nextSessionID
        delegate.activeMeetingTranscriptionProvider = .cloud
        XCTAssertFalse(delegate.fallBackMeetingToLocalIfUsageUnavailable(
            RealtimeTranscriptionError.usageLimitExceeded(usedHours: 5, limitHours: 5),
            sessionID: sessionID
        ))
        XCTAssertEqual(delegate.activeMeetingTranscriptionProvider, .cloud)
    }

    func test_delayedCloudUsageRejection_staysBoundToOriginalMeetingCallback() async {
        let delegate = AppDelegate()
        let service = CloudRealtimeService()
        let originalSessionID = UUID()
        let nextSessionID = UUID()
        let originalCallbackCalled = expectation(description: "Original callback receives delayed rejection")
        let nextCallbackCalled = expectation(description: "Next callback must not receive stale rejection")
        nextCallbackCalled.isInverted = true
        let originalStatusCalled = expectation(description: "Original status callback receives delayed rejection")
        let nextStatusCalled = expectation(description: "Next status callback must not receive stale rejection")
        nextStatusCalled.isInverted = true
        var originalStatusApplied: Bool?
        var resumeUsage: CheckedContinuation<UsageResponse?, Never>?
        let usageLoadStarted = expectation(description: "Usage load started")

        delegate.activeMeetingTranscriptionSessionID = originalSessionID
        delegate.activeMeetingTranscriptionProvider = .cloud
        service.setConnectionHandlers(
            onError: { error in
                Task { @MainActor in
                    _ = delegate.fallBackMeetingToLocalIfUsageUnavailable(
                        error,
                        sessionID: originalSessionID
                    )
                    originalCallbackCalled.fulfill()
                }
            },
            onConnectionStatusChanged: { status in
                Task { @MainActor in
                    originalStatusApplied = delegate.applyMeetingRealtimeConnectionStatus(
                        status,
                        sessionID: originalSessionID,
                        store: nil
                    )
                    originalStatusCalled.fulfill()
                }
            }
        )

        let notificationTask = service.reportUsageLimit(
            loadCachedUsage: {
                await withCheckedContinuation { continuation in
                    resumeUsage = continuation
                    usageLoadStarted.fulfill()
                }
            },
            refreshUsage: {}
        )
        await fulfillment(of: [usageLoadStarted], timeout: 1)

        delegate.activeMeetingTranscriptionSessionID = nextSessionID
        delegate.activeMeetingTranscriptionProvider = .cloud
        service.setConnectionHandlers(
            onError: { _ in nextCallbackCalled.fulfill() },
            onConnectionStatusChanged: { _ in nextStatusCalled.fulfill() }
        )
        resumeUsage?.resume(returning: nil)

        await notificationTask.value
        await fulfillment(
            of: [originalCallbackCalled, originalStatusCalled, nextCallbackCalled, nextStatusCalled],
            timeout: 0.1
        )
        XCTAssertEqual(delegate.activeMeetingTranscriptionProvider, .cloud)
        XCTAssertEqual(originalStatusApplied, false)
    }

    func test_repeatedCancelDuringRecorderInitialization_cannotTearDownRestart() async throws {
        let delegate = AppDelegate()
        var resumeRecorderStart: CheckedContinuation<Void, Never>?
        let recorderStartBegan = expectation(description: "Recorder initialization started")
        let restartedSessionID = UUID()
        var cancellationCount = 0
        let cancelAndRestart = {
            cancellationCount += 1
            delegate.appState.meetingRecordingState = .idle
            delegate.meetingPipelineGeneration &+= 1
            delegate.activeMeetingTranscriptionSessionID = restartedSessionID
            delegate.activeMeetingTranscriptionProvider = .local
            delegate.appState.meetingRecordingState = .processing
        }

        delegate.appState.meetingRecordingState = .processing
        let firstStart = Task {
            await delegate.startMeetingRecording(
                provider: .local,
                canStart: { true },
                ensureScreenRecordingPermission: { true },
                startRecorder: {
                    await withCheckedContinuation { continuation in
                        resumeRecorderStart = continuation
                        recorderStartBegan.fulfill()
                    }
                }
            )
        }
        delegate.meetingPipelineTask = firstStart
        await fulfillment(of: [recorderStartBegan], timeout: 1)
        let firstSessionID = try XCTUnwrap(delegate.activeMeetingTranscriptionSessionID)

        delegate.toggleMeetingRecording(provider: .local, cancelPipeline: cancelAndRestart)
        delegate.toggleMeetingRecording(provider: .local, cancelPipeline: cancelAndRestart)
        let latestCancellationTask = try XCTUnwrap(delegate.meetingPipelineTask)
        await Task.yield()

        XCTAssertEqual(delegate.appState.meetingRecordingState, .processing)
        XCTAssertEqual(delegate.activeMeetingTranscriptionSessionID, firstSessionID)

        resumeRecorderStart?.resume()
        await latestCancellationTask.value

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(delegate.appState.meetingRecordingState, .processing)
        XCTAssertEqual(delegate.activeMeetingTranscriptionSessionID, restartedSessionID)
        XCTAssertEqual(delegate.activeMeetingTranscriptionProvider, .local)
        XCTAssertNotEqual(restartedSessionID, firstSessionID)

        delegate.appState.meetingRecordingState = .idle
        delegate.activeMeetingTranscriptionSessionID = nil
        delegate.activeMeetingTranscriptionProvider = nil
    }

    func test_feedbackCancelDuringRecorderInitialization_finishesBeforeRestart() async throws {
        let delegate = AppDelegate()
        var resumeRecorderStart: CheckedContinuation<Void, Never>?
        let recorderStartBegan = expectation(description: "Recorder initialization started")
        let feedbackCancelFinished = expectation(description: "Feedback cancel finished")
        feedbackCancelFinished.isInverted = true

        delegate.appState.meetingRecordingState = .processing
        let firstStart = Task {
            await delegate.startMeetingRecording(
                provider: .local,
                canStart: { true },
                ensureScreenRecordingPermission: { true },
                startRecorder: {
                    await withCheckedContinuation { continuation in
                        resumeRecorderStart = continuation
                        recorderStartBegan.fulfill()
                    }
                }
            )
        }
        delegate.meetingPipelineTask = firstStart
        await fulfillment(of: [recorderStartBegan], timeout: 1)
        let firstSessionID = try XCTUnwrap(delegate.activeMeetingTranscriptionSessionID)

        let feedbackCancel = Task {
            await delegate.stopActiveRecordingFromFeedback()
            feedbackCancelFinished.fulfill()
        }
        await fulfillment(of: [feedbackCancelFinished], timeout: 0.05)
        XCTAssertEqual(delegate.appState.meetingRecordingState, .processing)
        XCTAssertEqual(delegate.activeMeetingTranscriptionSessionID, firstSessionID)

        resumeRecorderStart?.resume()
        await feedbackCancel.value
        XCTAssertEqual(delegate.appState.meetingRecordingState, .idle)

        var resumeRestartPermission: CheckedContinuation<Bool, Never>?
        let restartPermissionBegan = expectation(description: "Restart permission started")
        delegate.meetingPipelineGeneration &+= 1
        delegate.appState.meetingRecordingState = .processing
        let restartedStart = Task {
            await delegate.startMeetingRecording(
                provider: .local,
                canStart: { true },
                ensureScreenRecordingPermission: {
                    await withCheckedContinuation { continuation in
                        resumeRestartPermission = continuation
                        restartPermissionBegan.fulfill()
                    }
                }
            )
        }
        delegate.meetingPipelineTask = restartedStart
        await fulfillment(of: [restartPermissionBegan], timeout: 1)
        let restartedSessionID = try XCTUnwrap(delegate.activeMeetingTranscriptionSessionID)

        await Task.yield()
        XCTAssertEqual(delegate.appState.meetingRecordingState, .processing)
        XCTAssertEqual(delegate.activeMeetingTranscriptionSessionID, restartedSessionID)

        restartedStart.cancel()
        resumeRestartPermission?.resume(returning: true)
        await restartedStart.value
        delegate.appState.meetingRecordingState = .idle
        delegate.activeMeetingTranscriptionSessionID = nil
        delegate.activeMeetingTranscriptionProvider = nil
    }

    func test_explicitCancelWhileRecording_usesCancellationPipelineOnce() async throws {
        let delegate = AppDelegate()
        var cancellationCount = 0
        delegate.appState.meetingRecordingState = .recording

        let cancellationTask = try XCTUnwrap(delegate.cancelMeetingPipeline {
            cancellationCount += 1
            delegate.appState.meetingRecordingState = .idle
        })
        await cancellationTask.value

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(delegate.appState.meetingRecordingState, .idle)
    }

    func test_cancelledStartDuringPermissionWait_neverStartsRecorder() async {
        let delegate = AppDelegate()
        var resumePermission: CheckedContinuation<Bool, Never>?
        let permissionStarted = expectation(description: "Permission request started")

        delegate.appState.meetingRecordingState = .processing
        let start = Task {
            await delegate.startMeetingRecording(
                provider: .local,
                canStart: { true },
                ensureScreenRecordingPermission: {
                    await withCheckedContinuation { continuation in
                        resumePermission = continuation
                        permissionStarted.fulfill()
                    }
                }
            )
        }
        await fulfillment(of: [permissionStarted], timeout: 1)

        start.cancel()
        resumePermission?.resume(returning: true)
        await start.value

        XCTAssertFalse(delegate.meetingRecorderService.isRecording)
        XCTAssertNil(delegate.activeMeetingTranscriptionSessionID)
        XCTAssertNil(delegate.activeMeetingTranscriptionProvider)
        delegate.appState.meetingRecordingState = .idle
    }

    func test_meetingProviderResolution_usesCachedEligibilityWithoutNetworkPreflight() {
        let exhausted = UsageResponse(
            isWhitelisted: false,
            usedHours: 2,
            limitHours: 2,
            remainingHours: 0,
            usedMs: 7_200_000,
            limitMs: 7_200_000,
            remainingMs: 0
        )

        XCTAssertEqual(AppDelegate.resolveMeetingTranscriptionProvider(
            requestedProvider: .cloud,
            hasStoredSession: false,
            cachedUsage: nil
        ), .local)
        XCTAssertEqual(AppDelegate.resolveMeetingTranscriptionProvider(
            requestedProvider: .cloud,
            hasStoredSession: true,
            cachedUsage: exhausted
        ), .local)
        XCTAssertEqual(AppDelegate.resolveMeetingTranscriptionProvider(
            requestedProvider: .cloud,
            hasStoredSession: true,
            cachedUsage: nil
        ), .cloud)
        XCTAssertEqual(AppDelegate.resolveMeetingTranscriptionProvider(
            requestedProvider: .local,
            hasStoredSession: false,
            cachedUsage: exhausted
        ), .local)
    }



    func test_signedOutLocalQueueRequiresLoginAndPreservesAudio() throws {
        let id = try XCTUnwrap(storage.saveRecording(audioData: Data("RIFF....WAVEfmt ".utf8), type: .meeting, duration: 42, forceSave: true))
        let queue = RecordingQueueService(storage: storage, startsAutomatically: false, localModelIsAvailable: { _ in true }, hasSession: { false })
        queue.enqueue([id], action: .transcribe, providerOverride: .local)
        XCTAssertEqual(queue.queueCount, 0)
        let recording = try XCTUnwrap(storage.recordings.first { $0.id == id })
        XCTAssertEqual(recording.status, .failed)
        XCTAssertTrue(storage.hasPlayableAudio(for: recording))
    }

    func test_localQueue_marksRecordingProcessingWithoutLosingAudio() throws {
        let id = try XCTUnwrap(storage.saveRecording(
            audioData: Data("RIFF....WAVEfmt ".utf8),
            type: .meeting,
            duration: 42,
            forceSave: true
        ))
        let queue = RecordingQueueService(
            storage: storage,
            startsAutomatically: false,
            localModelIsAvailable: { _ in true },
            hasSession: { true }
        )

        queue.enqueue([id], action: .transcribe, providerOverride: .local)

        XCTAssertEqual(queue.queueCount, 1)
        let queued = try XCTUnwrap(storage.recordings.first(where: { $0.id == id }))
        XCTAssertEqual(queued.status, .processing)
        XCTAssertTrue(storage.hasPlayableAudio(for: queued))

        queue.cancelAll()
        let cancelled = try XCTUnwrap(storage.recordings.first(where: { $0.id == id }))
        XCTAssertEqual(cancelled.status, .unprocessed)
        XCTAssertTrue(storage.hasPlayableAudio(for: cancelled))
    }

    /// WP-43: a Record only start from the prompt never streams live, even when Cloud is requested.
    func test_recordOnlyStart_recordsOnThisMacWithoutLiveTranscript() async throws {
        let delegate = AppDelegate()
        delegate.appState.meetingRecordingState = .processing
        await delegate.startMeetingRecording(
            provider: .cloud,
            recordOnly: true,
            canStart: { true },
            ensureScreenRecordingPermission: { true },
            startRecorder: {}
        )
        XCTAssertEqual(delegate.activeMeetingTranscriptionProvider, .local)
        XCTAssertNil(delegate.meetingRealtimeService)
        // Record only keeps an empty, inactive store; nothing streams.
        XCTAssertNil(delegate.localMeetingStreamingService)
        XCTAssertEqual(delegate.appState.liveTranscriptStore?.isActive, false)

        if let token = delegate.meetingActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            delegate.meetingActivityToken = nil
        }
        delegate.appState.meetingRecordingState = .idle
        delegate.activeMeetingTranscriptionSessionID = nil
        delegate.activeMeetingTranscriptionProvider = nil
    }
}
