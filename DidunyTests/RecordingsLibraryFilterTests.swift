@testable import Diduny
import XCTest

final class RecordingsLibraryFilterTests: XCTestCase {
    func test_persistedLibraryDetectionUsesMetadataOrRecordingFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertFalse(RecordingsLibraryStorage.hasPersistedLibrary(in: directory))

        let metadata = directory.appendingPathComponent("recordings_metadata.json")
        try Data("[]".utf8).write(to: metadata)
        XCTAssertTrue(RecordingsLibraryStorage.hasPersistedLibrary(in: directory))

        try FileManager.default.removeItem(at: metadata)
        let recordings = directory.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try Data([0]).write(to: recordings.appendingPathComponent("recording.wav"))
        XCTAssertTrue(RecordingsLibraryStorage.hasPersistedLibrary(in: directory))
    }

    @MainActor
    func test_batchComposerActionTargetsRecordingsWithSharedTitle() {
        let controller = MainWindowController.shared
        controller.requestedSection = nil
        controller.requestedBatchComposer = false
        defer {
            controller.requestedSection = nil
            controller.requestedBatchComposer = false
        }

        controller.requestBatchComposer()

        XCTAssertEqual(MainWindowController.batchComposerActionTitle, "Batch Files and URLs…")
        XCTAssertEqual(controller.requestedSection, .recordings)
        XCTAssertTrue(controller.requestedBatchComposer)
    }

    func test_filesFilterMatchesOnlyImportedFileTranscriptions() {
        let file = makeRecording(remoteSource: nil)
        let youtube = makeRecording(remoteSource: makeYouTubeSource())

        XCTAssertTrue(RecordingsLibraryView.RecordingTypeFilter.files.matches(file))
        XCTAssertFalse(RecordingsLibraryView.RecordingTypeFilter.files.matches(youtube))
        XCTAssertTrue(RecordingsLibraryView.RecordingTypeFilter.youtube.matches(youtube))
        XCTAssertFalse(RecordingsLibraryView.RecordingTypeFilter.youtube.matches(file))
    }

    func test_youtubeRecordingHasDistinctLibraryPresentation() {
        let recording = makeRecording(remoteSource: makeYouTubeSource())

        XCTAssertEqual(recording.libraryDisplayName, "YouTube Video")
        XCTAssertEqual(recording.libraryIconName, "play.rectangle.fill")
    }

    func test_importedFilesAndYouTubeRequireLocalTranscription() {
        let file = makeRecording(remoteSource: nil)
        let youtube = makeRecording(remoteSource: makeYouTubeSource())
        let voice = makeRecording(type: .voice, remoteSource: nil)

        XCTAssertTrue(file.requiresLocalTranscription)
        XCTAssertTrue(youtube.requiresLocalTranscription)
        XCTAssertFalse(voice.requiresLocalTranscription)
    }

    func test_hasTranslationMatchesAttachedTranslationArtifact() {
        var recording = makeRecording(remoteSource: nil)
        XCTAssertFalse(RecordingsLibraryView.RecordingTypeFilter.hasTranslation.matches(recording))

        recording.translationTargetLanguageCode = "en"

        XCTAssertTrue(RecordingsLibraryView.RecordingTypeFilter.hasTranslation.matches(recording))
    }

    func test_batchesFilterShowsBatchesInsteadOfIndividualRecordings() {
        let recording = makeRecording(remoteSource: nil)

        XCTAssertTrue(RecordingsLibraryView.RecordingTypeFilter.batches.showsBatches)
        XCTAssertFalse(RecordingsLibraryView.RecordingTypeFilter.batches.matches(recording))
    }

    func test_recordingOpenedFromBatchCanNavigateBackButDirectRecordingCannot() {
        let batchID = UUID()
        let recordingID = UUID()
        let nested = RecordingsInspectorSelection.recording(
            recordingID,
            parentBatchID: batchID
        )
        let direct = RecordingsInspectorSelection.recording(
            recordingID,
            parentBatchID: nil
        )

        XCTAssertEqual(nested.parentBatchID, batchID)
        XCTAssertEqual(nested.backDestination, .batch(batchID))
        XCTAssertNil(direct.parentBatchID)
        XCTAssertNil(direct.backDestination)
    }

    func test_batchComposerIsAnInspectorDestination() {
        let selection = RecordingsInspectorSelection.batchComposer

        XCTAssertNil(selection.parentBatchID)
        XCTAssertNil(selection.backDestination)
    }

    func test_meetingSearchMatchesPeopleEmailsAgendaAndWordsSaid() {
        var meeting = makeRecording(type: .meeting, remoteSource: nil)
        meeting.transcriptionText = "we agreed to ship the pilot on Friday"
        var event = CalendarMeeting(id: "e", calendarID: "work", title: "Neovolta: BA AI Automation",
                                    start: Date(), end: Date().addingTimeInterval(1800))
        event.calendarTitle = "Work"
        event.notes = "Scope the automation pilot"
        event.location = "Room 4"
        event.attendees = [CalendarAttendee(name: "Olena Kovalenko", email: "olena.k@neovolta.com", response: .accepted)]
        meeting.calendarMeeting = event
        for query in ["olena", "KOVALENKO", "olena.k@neovolta", "neovolta: ba", "automation pilot", "room 4", "ship the pilot"] {
            XCTAssertTrue(meeting.matchesSearch(query), query)
        }
        XCTAssertFalse(meeting.matchesSearch("taras"))
        XCTAssertTrue(meeting.matchesSearch(""))
    }

    func test_calendarFilterListsCalendarsOfLinkedRecordingsAndNarrowsResults() {
        let calendar = { (id: String, title: String) -> Recording in
            var recording = self.makeRecording(type: .meeting, remoteSource: nil)
            var event = CalendarMeeting(id: id + "-event", calendarID: id, title: title, start: Date(), end: Date().addingTimeInterval(600))
            event.calendarTitle = title
            event.calendarColorRGB = 0x112233
            recording.calendarMeeting = event
            return recording
        }
        let work = calendar("work", "Work"), training = calendar("training", "Training"), work2 = calendar("work", "Work")
        let unlinked = makeRecording(type: .meeting, remoteSource: nil)
        let options = Recording.calendarFilterOptions([work, training, unlinked, work2])
        XCTAssertEqual(options.map(\.id), ["training", "work"], "Sorted by name, one per calendar")
        XCTAssertEqual(options.first?.colorRGB, 0x112233)
        XCTAssertTrue(work.matchesCalendars([]), "No calendar chosen shows everything")
        XCTAssertTrue(unlinked.matchesCalendars([]))
        XCTAssertTrue(work.matchesCalendars(["work"]))
        XCTAssertFalse(training.matchesCalendars(["work"]))
        XCTAssertFalse(unlinked.matchesCalendars(["work"]))
    }

    private func makeRecording(
        type: Recording.RecordingType = .fileTranscription,
        remoteSource: RemoteMediaSourceMetadata?
    ) -> Recording {
        Recording(
            id: UUID(),
            createdAt: Date(),
            type: type,
            audioFileName: "video.m4a",
            durationSeconds: 120,
            fileSizeBytes: 42,
            status: .transcribed,
            transcriptionText: "Transcript",
            sourceDevice: nil,
            sourceFileName: "Video",
            remoteSource: remoteSource
        )
    }

    private func makeYouTubeSource() -> RemoteMediaSourceMetadata {
        RemoteMediaSourceMetadata(
            provider: YouTubeRemoteMediaSource.provider,
            mediaID: "dQw4w9WgXcQ",
            canonicalURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!,
            title: "Video",
            channelName: "Channel"
        )
    }
}

final class RecordingStatisticsTests: XCTestCase {
    func test_usageDurationsPartitionEveryRecordingExactlyOnce() {
        let recordings = [
            makeRecording(type: .voice, duration: 10),
            makeRecording(type: .translation, duration: 20),
            makeRecording(type: .meeting, duration: 30),
            makeRecording(type: .meetingTranslation, duration: 40),
            makeRecording(type: .meeting, duration: 5, remoteSource: makeYouTubeSource()),
            makeRecording(type: .fileTranscription, duration: 50),
            makeRecording(type: .fileTranscription, duration: 60, remoteSource: makeYouTubeSource())
        ]

        let statistics = RecordingStatistics(recordings: recordings)

        XCTAssertEqual(statistics.voiceDurationSeconds, 10)
        XCTAssertEqual(statistics.translationDurationSeconds, 20)
        XCTAssertEqual(statistics.meetingDurationSeconds, 75)
        XCTAssertEqual(statistics.importedFileDurationSeconds, 50)
        XCTAssertEqual(statistics.youtubeDurationSeconds, 60)
        XCTAssertEqual(statistics.totalDurationSeconds, 215)
        XCTAssertEqual(
            statistics.voiceDurationSeconds
                + statistics.translationDurationSeconds
                + statistics.meetingDurationSeconds
                + statistics.importedFileDurationSeconds
                + statistics.youtubeDurationSeconds,
            statistics.totalDurationSeconds
        )
    }

    func test_timeSavedPreservesTypingMathAndAddsOnlyReadableMediaDuration() {
        let voice = makeRecording(
            type: .voice,
            duration: 60,
            transcriptionText: words(count: 100)
        )
        let readableFile = makeRecording(
            type: .fileTranscription,
            duration: 300,
            status: .failed,
            transcriptionText: "Readable media transcript"
        )
        let unreadableYouTube = makeRecording(
            type: .fileTranscription,
            duration: 400,
            status: .transcribed,
            transcriptionText: " \n\t ",
            remoteSource: makeYouTubeSource()
        )
        let statistics = RecordingStatistics(recordings: [voice, readableFile, unreadableYouTube])

        XCTAssertEqual(
            RecordingStatistics(recordings: [voice]).typingTimeSavedSeconds(wordsPerMinute: 50),
            60
        )
        XCTAssertEqual(statistics.typingTimeSavedSeconds(wordsPerMinute: 50), 60)
        XCTAssertEqual(statistics.mediaTimeSavedSeconds, 300)
        XCTAssertEqual(statistics.totalTimeSavedSeconds(wordsPerMinute: 50), 360)
        XCTAssertEqual(statistics.transcribedWordCount, 103)
    }

    private func makeRecording(
        type: Recording.RecordingType,
        duration: TimeInterval,
        status: Recording.ProcessingStatus = .transcribed,
        transcriptionText: String? = "Transcript",
        remoteSource: RemoteMediaSourceMetadata? = nil
    ) -> Recording {
        Recording(
            id: UUID(),
            createdAt: Date(),
            type: type,
            audioFileName: "recording.m4a",
            durationSeconds: duration,
            fileSizeBytes: 42,
            status: status,
            transcriptionText: transcriptionText,
            sourceDevice: nil,
            remoteSource: remoteSource
        )
    }

    private func words(count: Int) -> String {
        Array(repeating: "word", count: count).joined(separator: " ")
    }

    private func makeYouTubeSource() -> RemoteMediaSourceMetadata {
        RemoteMediaSourceMetadata(
            provider: YouTubeRemoteMediaSource.provider,
            mediaID: "video-id",
            canonicalURL: URL(string: "https://www.youtube.com/watch?v=video-id")!,
            title: "Video",
            channelName: "Channel"
        )
    }
}
