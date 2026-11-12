import Foundation
import os

/// Applies the changes `diduny` asks for and keeps `agent_status.json` current.
/// The tool writes `AgentCommands/<id>.json`; this applies it on the main actor, writes
/// `AgentResults/<id>.json` and removes the command. Commands left while Diduny was closed run at launch.
/// Agents run a command only when the user asked in the conversation (the guide says so); the app
/// cannot tell, so every change is small, visible in the app, and none deletes anything.
@MainActor
final class AgentCommandCenter {
    static let shared = AgentCommandCenter()

    private let logger = Logger(subsystem: "ua.com.rmarinsky.diduny", category: "Agents")
    private let directory: URL
    private let storage: RecordingsLibraryStorage
    private let notes: NotesStore
    private let writeNotes: (UUID) -> Void
    private let retranscribe: (UUID, String?) -> Bool
    private let now: () -> Date
    private var source: DispatchSourceFileSystemObject?
    private var statusTimer: Timer?
    private var lastStatus: Data?

    init(
        storage: RecordingsLibraryStorage? = nil,
        notes: NotesStore? = nil,
        writeNotes: ((UUID) -> Void)? = nil,
        retranscribe: ((UUID, String?) -> Bool)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.storage = storage ?? .shared
        self.notes = notes ?? .shared
        directory = self.storage.appDirectory
        self.writeNotes = writeNotes ?? { NotesService.shared.write($0) }
        self.retranscribe = retranscribe ?? { id, model in
            RecordingQueueService.shared.enqueue([id], action: .transcribeDiarize, providerOverride: .local,
                                                 whisperModelOverride: model, engineOverride: .whisper)
        }
        self.now = now
    }

    var inboxURL: URL { directory.appendingPathComponent(AgentCommandProtocol.inboxFolder) }
    var resultsURL: URL { directory.appendingPathComponent(AgentCommandProtocol.resultsFolder) }

    func start() {
        try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: resultsURL, withIntermediateDirectories: true)
        processInbox()
        watch()
        writeStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { AgentCommandCenter.shared.writeStatus() }
        }
    }

    /// Applies every finished command file, oldest first. Files still being written end in `.tmp`.
    func processInbox() {
        let files = (try? FileManager.default.contentsOfDirectory(at: inboxURL, includingPropertiesForKeys: nil)) ?? []
        let commands = files.filter { $0.pathExtension == "json" }.compactMap { url -> (URL, AgentCommandProtocol.Command?) in
            (url, try? AgentCommandProtocol.decoder.decode(AgentCommandProtocol.Command.self, from: Data(contentsOf: url)))
        }
        for (url, command) in commands.sorted(by: { ($0.1?.createdAt ?? .distantPast) < ($1.1?.createdAt ?? .distantPast) }) {
            try? FileManager.default.removeItem(at: url)
            guard let command else {
                logger.error("Agent command file was not readable; removed")
                continue
            }
            let result = apply(command)
            logger.info("Agent command \(command.action.rawValue, privacy: .public): \(result.ok ? "done" : "refused", privacy: .public)")
            if let data = try? AgentCommandProtocol.encoder.encode(result) {
                try? data.write(to: resultsURL.appendingPathComponent("\(command.id.uuidString).json"), options: .atomic)
            }
        }
    }

    func apply(_ command: AgentCommandProtocol.Command) -> AgentCommandProtocol.Result {
        func done(_ message: String) -> AgentCommandProtocol.Result { .init(commandID: command.id, ok: true, message: message) }
        func refused(_ message: String) -> AgentCommandProtocol.Result { .init(commandID: command.id, ok: false, message: message) }

        guard let recording = storage.recordings.first(where: { $0.id == command.recordingID }) else {
            return refused("No recording with id \(command.recordingID.uuidString) in this library.")
        }
        let values = command.values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        func organize(_ change: (inout Recording) -> Void, _ message: String) -> AgentCommandProtocol.Result {
            storage.updateOrganization(id: recording.id, change) ? done(message) : refused("Diduny could not save the change.")
        }

        switch command.action {
        case .addToNotes:
            guard let text = values.first else { return refused("Give the text to add.") }
            guard notes.note(for: recording.id) != nil else {
                return refused("This recording has no notes yet. Write them first with `notes write`.")
            }
            do {
                try notes.append(.init(text: text, addedAt: now(), author: "Claude"), to: recording.id)
                return done("Added to the notes of \"\(recording.displayTitle)\", marked as added by Claude.")
            } catch {
                return refused("Diduny could not save the notes: \(error.localizedDescription)")
            }
        case .writeNotes:
            guard NotesService.isReady(recording) else { return refused("The recording has no finished transcript yet.") }
            guard NotesSettings.writer != .off else { return refused("No notes writer is chosen in Diduny's Notes settings.") }
            writeNotes(recording.id)
            return done("Notes for \"\(recording.displayTitle)\" are queued. `status` shows progress.")
        case .addTags:
            guard !values.isEmpty else { return refused("Give at least one tag.") }
            return organize({ $0.tags = ($0.tags ?? []) + values }, "Tags added.")
        case .removeTags:
            let remove = Set(values.map { $0.lowercased() })
            return organize({ $0.tags?.removeAll { remove.contains($0.lowercased()) } }, "Tags removed.")
        case .setProject:
            return organize({ $0.project = values.first }, values.isEmpty ? "Project cleared." : "Project set to \"\(values[0])\".")
        case .addPeople:
            guard !values.isEmpty else { return refused("Give at least one name.") }
            return organize({ $0.people = ($0.people ?? []) + values }, "People linked.")
        case .removePeople:
            let remove = Set(values.map { $0.lowercased() })
            return organize({ $0.people?.removeAll { remove.contains($0.lowercased()) } }, "People unlinked.")
        case .retranscribe:
            guard storage.hasPlayableAudio(for: recording) else { return refused("The audio of this recording is not on this Mac.") }
            guard !recording.status.isInProgressCapture, recording.status != .needsRecovery else {
                return refused("The recording is still being captured or needs recovery in Diduny first.")
            }
            return retranscribe(recording.id, command.model)
                ? done("Queued for Whisper on this Mac. The current transcript stays in the history. `status` shows progress.")
                : refused("Whisper could not start. Check that a Whisper model is downloaded in Diduny.")
        }
    }

    /// Writes the status file when what is running changed.
    func writeStatus() {
        let board = ProcessingBoard.shared
        let items = board.ordered.map { entry in
            AgentCommandProtocol.Status.Item(
                recordingID: entry.id,
                title: storage.recordings.first { $0.id == entry.id }?.displayTitle ?? "",
                kind: Self.name(entry.work.kind),
                lane: Self.name(entry.work.lane),
                stage: entry.work.progress?.stage.rawValue ?? entry.work.notes.map(Self.notesStage),
                percent: entry.work.progress.flatMap(QueueProgressFormatter.percent)
            )
        }
        let queued = RecordingQueueService.shared.queueCount
        let queuedNotes = NotesService.shared.queuedCount
        let fingerprint = try? AgentCommandProtocol.encoder.encode(
            AgentCommandProtocol.Status(updatedAt: .distantPast, working: items, queuedRecordings: queued, queuedNotes: queuedNotes))
        guard fingerprint != lastStatus else { return }
        lastStatus = fingerprint
        let status = AgentCommandProtocol.Status(updatedAt: now(), working: items, queuedRecordings: queued, queuedNotes: queuedNotes)
        if let data = try? AgentCommandProtocol.encoder.encode(status) {
            try? data.write(to: directory.appendingPathComponent(AgentCommandProtocol.statusFile), options: .atomic)
        }
    }

    private static func name(_ kind: ProcessingBoard.Work.Kind) -> String {
        switch kind {
        case .transcription: "transcription"
        case .translation: "translation"
        case .notes: "notes"
        }
    }

    private static func name(_ lane: ProcessingBoard.Work.Lane) -> String {
        switch lane {
        case .onThisMac: "onThisMac"
        case .cloud: "cloud"
        case .notes: "notes"
        }
    }

    private static func notesStage(_ state: NotesService.JobState) -> String {
        switch state {
        case let .writing(part, total): "writing part \(part) of \(total)"
        case .checking: "checking"
        case .waiting: "waiting"
        case .failed: "failed"
        }
    }

    /// Same folder watch as the agent settings file: the tool renames finished files into place.
    private func watch() {
        let descriptor = open(inboxURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.processInbox() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }
}
