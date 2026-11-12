import Foundation
import Testing
@testable import Diduny

/// Stages 3 and 4: changes `diduny` asks for, applied by the app; project, tags and people on recordings.
@MainActor
@Suite(.serialized)
struct AgentCommandsTests {
    private struct Fixture {
        let folder: URL
        let storage: RecordingsLibraryStorage
        let notes: NotesStore
        let id: UUID
    }

    private func fixture() throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AgentCommands-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let storage = RecordingsLibraryStorage(baseDirectory: folder, batchStorage: try TranscriptionBatchStorage(baseDirectory: folder))
        let id = try #require(storage.saveRecording(audioData: Data("RIFF....WAVEfmt ".utf8), type: .meeting, duration: 42, forceSave: true))
        return Fixture(folder: folder, storage: storage, notes: NotesStore(directory: folder), id: id)
    }

    private func note(_ recordingID: UUID) -> RecordingNote {
        RecordingNote(id: UUID(), recordingID: recordingID, createdAt: Date(), writer: "test", template: .meeting,
                      summary: "We agreed.", decisions: [], actionItems: [], openQuestions: [])
    }

    private func center(_ f: Fixture, retranscribed: ((UUID, String?) -> Bool)? = nil,
                        modelReady: Bool = true) -> AgentCommandCenter {
        AgentCommandCenter(storage: f.storage, notes: f.notes, writeNotes: { _ in },
                           retranscribe: retranscribed ?? { _, _ in true }, whisperModelReady: { _ in modelReady },
                           now: { Date(timeIntervalSince1970: 100) })
    }

    @Test func addingToNotesAppendsABlockMarkedAsClaudesAndKeepsTheRest() throws {
        let f = try fixture()
        try f.notes.save(note(f.id))
        let result = center(f).apply(.init(action: .addToNotes, recordingID: f.id, values: ["Follow up with Olena."]))
        #expect(result.ok)
        let saved = try #require(f.notes.note(for: f.id))
        #expect(saved.summary == "We agreed.")
        #expect(saved.additions?.map(\.text) == ["Follow up with Olena."])
        #expect(saved.additions?.first?.author == "Claude")
        #expect(saved.markdown.contains("Follow up with Olena."))
        // Kept on disk for the next launch.
        #expect(NotesStore(directory: f.folder).note(for: f.id)?.additions?.count == 1)
    }

    @Test func addingToNotesOfARecordingWithoutNotesIsRefused() throws {
        let f = try fixture()
        let result = center(f).apply(.init(action: .addToNotes, recordingID: f.id, values: ["text"]))
        #expect(!result.ok)
        #expect(f.notes.note(for: f.id) == nil)
    }

    @Test func unknownRecordingIsRefused() throws {
        let f = try fixture()
        #expect(!center(f).apply(.init(action: .addTags, recordingID: UUID(), values: ["x"])).ok)
    }

    @Test func tagsProjectAndPeopleAreCleanedAndSaved() throws {
        let f = try fixture()
        let center = center(f)
        #expect(center.apply(.init(action: .addTags, recordingID: f.id, values: ["hiring", " Hiring ", "q4"])).ok)
        #expect(center.apply(.init(action: .removeTags, recordingID: f.id, values: ["Q4"])).ok)
        #expect(center.apply(.init(action: .setProject, recordingID: f.id, values: ["Diduny"])).ok)
        #expect(center.apply(.init(action: .addPeople, recordingID: f.id, values: ["Olena Petrenko"])).ok)

        let reloaded = RecordingsLibraryStorage(baseDirectory: f.folder, batchStorage: try TranscriptionBatchStorage(baseDirectory: f.folder))
        let recording = try #require(reloaded.recordings.first { $0.id == f.id })
        #expect(recording.tags == ["hiring"])
        #expect(recording.project == "Diduny")
        #expect(recording.people == ["Olena Petrenko"])
        #expect(recording.involves(person: "olena"))
        #expect(Recording.searchableText(recording.searchableText, matches: "diduny"))

        #expect(center.apply(.init(action: .setProject, recordingID: f.id, values: [])).ok)
        #expect(f.storage.recordings.first { $0.id == f.id }?.project == nil)
    }

    @Test func retranscribeGoesToWhisperWithTheModelAsked() throws {
        let f = try fixture()
        var asked: (UUID, String?)?
        let result = center(f, retranscribed: { asked = ($0, $1); return true })
            .apply(.init(action: .retranscribe, recordingID: f.id, model: "large-v3-turbo"))
        #expect(result.ok)
        #expect(asked?.0 == f.id)
        #expect(asked?.1 == "large-v3-turbo")
    }

    @Test func inboxCommandIsAppliedAnsweredAndRemoved() throws {
        let f = try fixture()
        let center = center(f)
        try FileManager.default.createDirectory(at: center.inboxURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: center.resultsURL, withIntermediateDirectories: true)
        let command = AgentCommandProtocol.Command(action: .addTags, recordingID: f.id, values: ["design"])
        let file = center.inboxURL.appendingPathComponent("\(command.id.uuidString).json")
        try AgentCommandProtocol.encoder.encode(command).write(to: file)
        let partial = center.inboxURL.appendingPathComponent("\(UUID().uuidString).json.tmp")
        try Data("{".utf8).write(to: partial)

        center.processInbox()

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: partial.path), "a file still being written is left alone")
        let answer = try AgentCommandProtocol.decoder.decode(AgentCommandProtocol.Result.self, from: Data(contentsOf:
            center.resultsURL.appendingPathComponent("\(command.id.uuidString).json")))
        #expect(answer.ok)
        #expect(f.storage.recordings.first { $0.id == f.id }?.tags == ["design"])
    }

    @Test func speakerNamesAndPeopleMakeUpTheRecordingsPeople() throws {
        let f = try fixture()
        #expect(f.storage.updateOrganization(id: f.id) {
            $0.people = ["Taras"]
            $0.speakerNames = ["Speaker 1": "Olena", "Speaker 2": " "]
        })
        let recording = try #require(f.storage.recordings.first { $0.id == f.id })
        #expect(recording.speakerNames == ["Speaker 1": "Olena"])
        #expect(recording.allPeople == ["Taras", "Olena"])
        #expect(recording.involves(person: "olena"))
        #expect(!recording.involves(person: "Ivan"))
    }

    /// The hand-written rebuilds in the storage keep the new fields.
    @Test func interruptedCaptureResetKeepsProjectAndPeople() {
        var recording = Recording(id: UUID(), createdAt: Date(), type: .meeting, audioFileName: "a.m4a", durationSeconds: 10,
                                  fileSizeBytes: 1, status: .recording, sourceDevice: nil)
        recording.project = "Diduny"
        recording.tags = ["hiring"]
        recording.people = ["Olena"]
        recording.speakerNames = ["Speaker 1": "Olena"]
        var rows = [recording]
        #expect(RecordingsLibraryStorage.resetInterruptedProcessingStates(in: &rows))
        #expect(rows[0].status != .recording)
        #expect(rows[0].project == "Diduny")
        #expect(rows[0].tags == ["hiring"])
        #expect(rows[0].people == ["Olena"])
        #expect(rows[0].speakerNames == ["Speaker 1": "Olena"])
    }

    @Test func theSameCommandAddsToNotesOnce() throws {
        let f = try fixture()
        try f.notes.save(note(f.id))
        let command = AgentCommandProtocol.Command(action: .addToNotes, recordingID: f.id, values: ["Once."])
        #expect(center(f).apply(command).ok)
        #expect(center(f).apply(command).ok)
        #expect(f.notes.note(for: f.id)?.additions?.count == 1)
    }

    @Test func retranscribeWithAMissingModelLeavesTheRecordingAlone() throws {
        let f = try fixture()
        f.storage.completeTranscription(id: f.id, status: .transcribed, text: "done", segments: nil, kind: .cloud)
        var queued = false
        let result = center(f, retranscribed: { _, _ in queued = true; return true }, modelReady: false)
            .apply(.init(action: .retranscribe, recordingID: f.id, model: "large-v9"))
        #expect(!result.ok)
        #expect(!queued)
        #expect(f.storage.recordings.first { $0.id == f.id }?.status == .transcribed)
    }

    /// A command stays in the inbox until its answer is saved; one with an answer is not applied again.
    @Test func answeredCommandIsNotAppliedAgain() throws {
        let f = try fixture()
        let center = center(f)
        try FileManager.default.createDirectory(at: center.inboxURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: center.resultsURL, withIntermediateDirectories: true)
        let command = AgentCommandProtocol.Command(action: .addTags, recordingID: f.id, values: ["once"])
        let file = center.inboxURL.appendingPathComponent("\(command.id.uuidString).json")
        try AgentCommandProtocol.encoder.encode(command).write(to: file)
        try AgentCommandProtocol.encoder.encode(AgentCommandProtocol.Result(commandID: command.id, ok: true, message: "done"))
            .write(to: center.resultsURL.appendingPathComponent("\(command.id.uuidString).json"))

        center.processInbox()

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(f.storage.recordings.first { $0.id == f.id }?.tags == nil)
    }

    /// `tag` then `untag` sent within one second while Diduny was closed: the tag ends up removed.
    @Test func commandsWithinOneSecondKeepTheirOrder() throws {
        let f = try fixture()
        let center = center(f)
        try FileManager.default.createDirectory(at: center.inboxURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: center.resultsURL, withIntermediateDirectories: true)
        let second = Date(timeIntervalSince1970: 2_000_000_000)
        var tag = AgentCommandProtocol.Command(action: .addTags, recordingID: f.id, values: ["x"], createdAt: second)
        tag.order = second.timeIntervalSince1970 + 0.1
        var untag = AgentCommandProtocol.Command(action: .removeTags, recordingID: f.id, values: ["x"], createdAt: second)
        untag.order = second.timeIntervalSince1970 + 0.2
        // Written in reverse so file order cannot decide.
        for command in [untag, tag] {
            try AgentCommandProtocol.encoder.encode(command).write(to: center.inboxURL.appendingPathComponent("\(command.id.uuidString).json"))
        }
        center.processInbox()
        #expect(f.storage.recordings.first { $0.id == f.id }?.tags == nil)
    }
}
