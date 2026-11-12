import Foundation

/// What Diduny is doing with each recording right now: transcribing, translating or writing notes.
/// The queue and the notes writer report here; Recordings, Notes and the menu read it.
@Observable
@MainActor
final class ProcessingBoard {
    static let shared = ProcessingBoard()

    struct Work: Equatable {
        enum Kind: Equatable {
            case transcription
            case translation
            case notes
        }

        enum Lane: Equatable {
            /// Whisper or another engine on this Mac: one recording at a time.
            case onThisMac
            /// Diduny Cloud or the user's own provider: several at once.
            case cloud
            case notes
        }

        var kind: Kind
        var lane: Lane
        /// Stage and progress of a transcription or translation.
        var progress: QueueProgress?
        /// Part and stage of notes being written.
        var notes: NotesService.JobState?
        var startedAt = Date()
    }

    /// Transcription (or translation) and notes are kept apart: a recording transcribed again while
    /// its notes are written shows both.
    private struct Key: Hashable {
        let recordingID: UUID
        let notes: Bool

        init(_ recordingID: UUID, _ kind: Work.Kind) {
            self.recordingID = recordingID
            notes = kind == .notes
        }
    }

    private var entries: [Key: Work] = [:]

    var isEmpty: Bool { entries.isEmpty }

    /// The transcription or translation of a recording, else its notes.
    func work(for recordingID: UUID) -> Work? {
        entries[Key(recordingID, .transcription)] ?? entries[Key(recordingID, .notes)]
    }

    /// Only work of this kind; `.translation` and `.transcription` share one place.
    func work(for recordingID: UUID, kind: Work.Kind) -> Work? {
        entries[Key(recordingID, kind)]
    }

    func start(_ recordingID: UUID, kind: Work.Kind, lane: Work.Lane) {
        entries[Key(recordingID, kind)] = Work(kind: kind, lane: lane)
    }

    func update(_ recordingID: UUID, progress: QueueProgress) {
        let key = Key(recordingID, .transcription)
        guard entries[key] != nil, entries[key]?.progress != progress else { return }
        entries[key]?.progress = progress
    }

    func update(_ recordingID: UUID, notes: NotesService.JobState) {
        let key = Key(recordingID, .notes)
        guard entries[key] != nil, entries[key]?.notes != notes else { return }
        entries[key]?.notes = notes
    }

    /// Ends one kind of work only, so finishing a transcription never clears notes being written.
    func finish(_ recordingID: UUID, kind: Work.Kind) {
        let key = Key(recordingID, kind)
        guard entries[key]?.kind == kind else { return }
        entries[key] = nil
    }

    /// One line for the menu and the Notes page, e.g. `Transcribing "Weekly sync" on this Mac, 62%`.
    static func line(_ work: Work, title: String) -> String {
        switch work.kind {
        case .transcription, .translation:
            let translating = work.kind == .translation
            var line = switch (translating, work.lane == .cloud) {
            case (false, false): String(localized: "Transcribing \"\(title)\" on this Mac")
            case (false, true): String(localized: "Transcribing \"\(title)\" in the cloud")
            case (true, false): String(localized: "Translating \"\(title)\" on this Mac")
            case (true, true): String(localized: "Translating \"\(title)\" in the cloud")
            }
            if let progress = work.progress, let percent = QueueProgressFormatter.percent(progress) {
                line += ", " + String(localized: "\(percent)%")
            }
            return line
        case .notes:
            switch work.notes {
            case let .writing(part, total) where total > 1:
                return String(localized: "Writing notes for \"\(title)\", part \(part) of \(total)")
            case .checking:
                return String(localized: "Checking notes for \"\(title)\"")
            default:
                return String(localized: "Writing notes for \"\(title)\"")
            }
        }
    }

    /// Recordings being worked on, oldest start first.
    var ordered: [(id: UUID, work: Work)] {
        entries.map { ($0.key.recordingID, $0.value) }.sorted { $0.work.startedAt < $1.work.startedAt }
    }
}
