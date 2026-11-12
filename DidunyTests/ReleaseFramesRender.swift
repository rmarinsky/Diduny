import AppKit
import SwiftUI
import Testing
@testable import Diduny

/// Renders the release GIF's stills from the app's own views with demo data only.
/// Runs only with DIDUNY_RENDER_FRAMES=<folder>; never reads the user's library.
@MainActor
struct ReleaseFramesRender {
    private let size = CGSize(width: 1000, height: 712)

    private func recording(_ title: String, minutes: Double, status: Recording.ProcessingStatus,
                           text: String? = nil, ago: TimeInterval) -> Recording {
        var recording = Recording(id: UUID(), createdAt: Date().addingTimeInterval(-ago), type: .meeting, audioFileName: "",
                                  durationSeconds: minutes * 60, fileSizeBytes: 1, status: status, transcriptionText: text,
                                  sourceDevice: nil)
        recording.title = title
        return recording
    }

    private func save(_ view: some View, _ name: String, to folder: URL) throws {
        let framed = view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: framed)
        host.appearance = NSAppearance(named: .aqua)
        let window = RetinaHostingWindow(hosting: host)
        defer { window.contentView = nil }
        host.frame = CGRect(origin: .zero, size: size)
        window.setContentSize(size)
        // Let SwiftUI settle state and lists before drawing.
        for _ in 0 ..< 5 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("\(name).png"))
    }

    @Test func renderFrames() throws {
        guard let path = ProcessInfo.processInfo.environment["DIDUNY_RENDER_FRAMES"] else { return }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let board = ProcessingBoard.shared

        let sync = recording("Weekly product sync", minutes: 48, status: .processing, ago: 1800)
        let review = recording("Design review with Olena", minutes: 31, status: .processing, ago: 5400)
        let oneOnOne = recording("1:1 with Taras", minutes: 24, status: .transcribed,
                                 text: "We went through the release plan.", ago: 9000)
        let done = recording("Hiring sync", minutes: 18, status: .transcribed, text: "Two candidates for the iOS role.", ago: 86400)
        board.start(sync.id, kind: .transcription, lane: .onThisMac)
        board.update(sync.id, progress: QueueProgress(stage: .transcribing, provider: .local, totalSeconds: 2880,
                                                      fraction: 0.62, processedSeconds: 1786, secondsLeft: 240))
        board.start(review.id, kind: .transcription, lane: .cloud)
        board.update(review.id, progress: QueueProgress(stage: .transcribing, provider: .cloud, totalSeconds: 1860,
                                                        fraction: 0.4, processedSeconds: 744, secondsLeft: 90))
        board.start(oneOnOne.id, kind: .notes, lane: .notes)
        board.update(oneOnOne.id, notes: .writing(part: 1, of: 2))
        defer { [sync, review, oneOnOne].forEach { board.finish($0.id, kind: board.work(for: $0.id)?.kind ?? .notes) } }
        let titles = Dictionary(uniqueKeysWithValues: [sync, review, oneOnOne].map { ($0.id, $0.displayTitle) })

        try save(PageScaffold(title: "Recordings", scrolls: false) {
            VStack(spacing: 0) {
                ForEach([sync, review, oneOnOne, done], id: \.id) { row in
                    RecordingRowView(recording: row, onOpen: {}, onTranscribe: {}, onDelete: {})
                    Divider()
                }
            }
            .padding(.horizontal, 24)
        }, "working_recordings", to: folder)

        var note = RecordingNote(
            id: UUID(), recordingID: done.id, createdAt: Date().addingTimeInterval(-80000), writer: "Claude Code, sonnet",
            template: .meeting, summary: "Two candidates for the iOS role. The team agreed to invite one to a second interview.",
            decisions: [.init(text: "Second interview with the first candidate", time: "12:40")],
            actionItems: [.init(owner: "Olena", task: "Send the take-home task", deadline: "Friday", time: "14:05")],
            openQuestions: []
        )
        note.additions = [.init(text: "Ask Taras to join the second interview.", addedAt: Date().addingTimeInterval(-3600), author: "Claude")]
        try save(PageScaffold(title: "Notes", scrolls: false) {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                NotesWorkStrip(titles: titles)
                Divider()
                Text(done.displayTitle).font(DS.Font.groupHeading)
                NoteBody(note: note, recording: done)
            }
            .padding(.horizontal, 24)
        }, "working_notes", to: folder)

        var organized = done
        organized.project = "Diduny iOS"
        organized.tags = ["hiring", "ios"]
        organized.people = ["Olena", "Taras"]
        organized.speakerNames = ["Speaker 1": "Olena", "Speaker 2": "Taras"]
        organized.transcriptSegments = [
            TimedTranscriptSegment(startMilliseconds: 0, endMilliseconds: 4000, speaker: "1", text: "Hi"),
            TimedTranscriptSegment(startMilliseconds: 4000, endMilliseconds: 8000, speaker: "2", text: "Hi"),
        ]
        try save(PageScaffold(title: "Hiring sync", scrolls: false) {
            RecordingOrganizeSection(recording: organized)
                .padding(.horizontal, 24)
        }, "organize", to: folder)
    }
}
