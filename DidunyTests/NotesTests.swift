import Foundation
import Testing
@testable import Diduny

@MainActor
struct NotesTests {
    private let answer = #"{"summary":"We agreed to ship.","points":[],"decisions":[{"text":"Ship on Friday","time":"01:10"}],"actionItems":[{"owner":"","task":"Write release notes","deadline":"","time":"02:00"}],"openQuestions":["Who tests?"]}"#

    @Test func decodesAnswerWrappedInCodeFence() throws {
        let draft = try NotesDraft.decode("```json\n\(answer)\n```")
        #expect(draft.summary == "We agreed to ship.")
        #expect(draft.decisions?.first?.time == "01:10")
        #expect(draft.actionItems?.first?.owner == "")
    }

    @Test func rejectsProse() {
        #expect(throws: NotesError.self) { try NotesDraft.decode("Here are your notes: none") }
    }

    @Test func readsClaudeArrayOutputAndStructuredOutput() throws {
        let stdout = #"[{"type":"system"},{"type":"result","is_error":false,"result":"","structured_output":"# + answer + "}]"
        let draft = try NotesDraft.decode(CLIWriter.parseClaude(.init(status: 0, stdout: stdout, stderr: "")))
        #expect(draft.openQuestions == ["Who tests?"])
    }

    @Test func surfacesClaudeError() {
        let stdout = #"{"type":"result","is_error":true,"result":"Not logged in"}"#
        #expect(throws: NotesError.self) { try CLIWriter.parseClaude(.init(status: 1, stdout: stdout, stderr: "")) }
    }

    @Test func splitsAtLineBreaksWithinLimit() {
        let text = (1 ... 10).map { "[00:\(String(format: "%02d", $0))] line \($0)" }.joined(separator: "\n")
        let parts = NotesService.split(text, limit: 40)
        #expect(parts.count > 1)
        #expect(parts.allSatisfy { $0.count <= 40 })
        #expect(parts.joined(separator: "\n") == text)
        #expect(NotesService.split(text, limit: nil) == [text])
    }

    @Test func cleansTypographicCharacters() {
        #expect(NotesService.clean("Ship \u{2014} \u{201C}now\u{201D}") == "Ship, \"now\"")
    }

    @Test func schemaRequiresEveryField() throws {
        let required = NotesDraft.schema["required"] as? [String]
        #expect(required == ["actionItems", "decisions", "openQuestions", "points", "summary", "topics"])
    }

    @Test func markdownListsOpenItemsWithoutOwner() {
        let note = RecordingNote(id: UUID(), recordingID: UUID(), createdAt: Date(), writer: "test", template: .meeting,
                                 summary: "S", decisions: [], actionItems: [.init(owner: "", task: "Do it", deadline: "", time: "")],
                                 openQuestions: [])
        #expect(note.markdown.contains("[ ] No owner: Do it"))
    }

    @Test func readsGeminiResponseAndError() throws {
        let ok = #"{"session_id":"x","response":"{\"supported\":[1,3]}"}"#
        let answer = try CLIWriter.parseGemini(.init(status: 0, stdout: ok, stderr: ""))
        #expect(try JSONSchema.decode(NotesCheckResult.self, from: answer).supported == [1, 3])
        let failed = #"{"error":{"message":"Sign in first"}}"#
        #expect(throws: NotesError.self) { try CLIWriter.parseGemini(.init(status: 1, stdout: failed, stderr: "")) }
    }

    @Test func readsTranscriptTimes() {
        #expect(NotesTranscript.seconds(from: "12:40") == 760)
        #expect(NotesTranscript.seconds(from: "[1:02:05]") == 3725)
        #expect(NotesTranscript.seconds(from: "soon") == nil)
    }
}
