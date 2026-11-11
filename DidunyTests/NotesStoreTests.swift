import Foundation
import Testing
@testable import Diduny

@MainActor
struct NotesStoreTests {
    private func note(_ recordingID: UUID = UUID()) -> RecordingNote {
        RecordingNote(id: UUID(), recordingID: recordingID, createdAt: Date(), writer: "test", template: .meeting,
                      summary: "S", decisions: [], actionItems: [], openQuestions: [])
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func failedSaveThrowsAndKeepsNotes() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotesStore(directory: dir)
        try store.save(note())
        // A folder where the file should be makes the write fail.
        let file = dir.appendingPathComponent("notes.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try store.save(note()) }
        #expect(store.notes.count == 1)
    }

    @Test func unreadableFileIsMovedAsideNotOverwritten() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json".utf8).write(to: dir.appendingPathComponent("notes.json"))
        let store = NotesStore(directory: dir)
        #expect(store.notes.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.hasPrefix("notes.unreadable-") })
    }

    @Test func pruneKeepsNotesOfListedRecordings() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotesStore(directory: dir)
        let kept = UUID()
        try store.save(note(kept))
        try store.save(note())
        store.prune(keeping: [kept])
        #expect(store.notes.map(\.recordingID) == [kept])
    }

    @Test func tomlStringEscapesQuotes() {
        #expect(CLIWriter.tomlString(#"a"b\c"#) == #""a\"b\\c""#)
    }
}
