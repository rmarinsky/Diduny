import AppKit
import Foundation

/// Changes go through the app: the tool drops a command file, Diduny applies it and answers.
/// The tool never writes the library or the notes itself.
enum AppCommands {
    static func isAppRunning(_ bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    static func send(_ command: AgentCommandProtocol.Command, library: Library, timeout: TimeInterval = 15) throws -> String {
        let inbox = library.directory.appendingPathComponent(AgentCommandProtocol.inboxFolder)
        let results = library.directory.appendingPathComponent(AgentCommandProtocol.resultsFolder)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        // Written under another name, then renamed: Diduny only reads finished `.json` files.
        let partial = inbox.appendingPathComponent("\(command.id.uuidString).json.tmp")
        try AgentCommandProtocol.encoder.encode(command).write(to: partial)
        try FileManager.default.moveItem(at: partial, to: inbox.appendingPathComponent("\(command.id.uuidString).json"))

        guard isAppRunning(library.bundleIdentifier) else {
            return "Diduny is not running. It applies this when it starts.\n"
        }
        let resultURL = results.appendingPathComponent("\(command.id.uuidString).json")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: resultURL),
               let result = try? AgentCommandProtocol.decoder.decode(AgentCommandProtocol.Result.self, from: data) {
                try? FileManager.default.removeItem(at: resultURL)
                guard result.ok else { throw CLIError(result.message) }
                return result.message + "\n"
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return "Sent. Diduny did not answer within \(Int(timeout)) s; it applies the change when it can.\n"
    }

    static func status(library: Library, json: Bool) throws -> String {
        let running = isAppRunning(library.bundleIdentifier)
        let url = library.directory.appendingPathComponent(AgentCommandProtocol.statusFile)
        let status = (try? Data(contentsOf: url)).flatMap { try? AgentCommandProtocol.decoder.decode(AgentCommandProtocol.Status.self, from: $0) }
        if json {
            var row: [String: Any] = ["appRunning": running]
            if running, let status {
                row["queuedRecordings"] = status.queuedRecordings
                row["queuedNotes"] = status.queuedNotes
                row["working"] = status.working.map { item -> [String: Any] in
                    var entry: [String: Any] = ["id": item.recordingID.uuidString, "title": item.title, "kind": item.kind, "lane": item.lane]
                    if let stage = item.stage { entry["stage"] = stage }
                    if let percent = item.percent { entry["percent"] = percent }
                    return entry
                }
            }
            return Render.json(row)
        }
        guard running else { return "Diduny is not running, so nothing is being processed.\n" }
        guard let status, !status.working.isEmpty || status.queuedRecordings > 0 || status.queuedNotes > 0 else {
            return "Diduny is idle.\n"
        }
        var lines = status.working.map { item -> String in
            let what = switch item.kind {
            case "notes": "Writing notes"
            case "translation": "Translating"
            default: "Transcribing"
            }
            let where_ = item.lane == "cloud" ? " in the cloud" : item.lane == "onThisMac" ? " on this Mac" : ""
            let detail = [item.stage, item.percent.map { "\($0)%" }].compactMap { $0 }.joined(separator: ", ")
            return "- \(what)\(where_): \(item.title) (\(String(item.recordingID.uuidString.prefix(8)).lowercased()))"
                + (detail.isEmpty ? "" : ", \(detail)")
        }
        if status.queuedRecordings > 0 { lines.append("- \(status.queuedRecordings) recording(s) waiting to be transcribed") }
        if status.queuedNotes > 0 { lines.append("- \(status.queuedNotes) recording(s) waiting for notes") }
        return Render.untrusted("status", lines.joined(separator: "\n")) + "\n"
    }
}

/// `diduny notes show|add|write`. Reads `notes.json`; changes go through the app.
enum NotesCommand {
    static func run(_ rest: [String], args: Arguments, library: Library) throws {
        guard let sub = rest.first, rest.count > 1 else {
            throw CLIError("Usage: \(commandName) notes show|add|write <id> ...")
        }
        let all = try library.load()
        let recording = try library.find(rest[1], in: rest[1] == "latest" ? try filtered(all, args) : all)
        switch sub {
        case "show":
            guard let note = try note(for: recording.id, library: library) else {
                output("No notes for this recording yet. `\(commandName) notes write \(Render.shortID(recording))` writes them.\n")
                return
            }
            output(args.json ? Render.json(note) : markdown(note, recording: recording))
        case "add":
            let text = rest.dropFirst(2).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw CLIError("Usage: \(commandName) notes add <id> \"<text>\"") }
            output(try AppCommands.send(.init(action: .addToNotes, recordingID: recording.id, values: [text]), library: library))
        case "write":
            output(try AppCommands.send(.init(action: .writeNotes, recordingID: recording.id), library: library))
        default:
            throw CLIError("Unknown: notes \(sub). Use show, add or write.")
        }
    }

    static func note(for id: UUID, library: Library) throws -> [String: Any]? {
        let url = library.directory.appendingPathComponent("notes.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let notes = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CLIError("Could not read \(url.path).")
        }
        return notes.first { ($0["recordingID"] as? String)?.lowercased() == id.uuidString.lowercased() }
    }

    static func markdown(_ note: [String: Any], recording: Recording) -> String {
        func strings(_ key: String) -> [String] { note[key] as? [String] ?? [] }
        func items(_ key: String) -> [[String: Any]] { note[key] as? [[String: Any]] ?? [] }
        var out: [String] = []
        out += ["## Summary", note["summary"] as? String ?? ""]
        func section(_ title: String, _ rows: [String]) {
            guard !rows.isEmpty else { return }
            out += ["", "## \(title)"] + rows.map { "- \($0)" }
        }
        section("Topics", strings("topics"))
        section("Points", strings("points"))
        section("Decisions", items("decisions").map { item in
            let time = item["time"] as? String ?? ""
            return (item["text"] as? String ?? "") + (time.isEmpty ? "" : " [\(time)]")
        })
        section("Action items", items("actionItems").map { item in
            let owner = (item["owner"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "No owner"
            let deadline = item["deadline"] as? String ?? ""
            let time = item["time"] as? String ?? ""
            return "[\((item["done"] as? Bool) == true ? "x" : " ")] \(owner): \(item["task"] as? String ?? "")"
                + (deadline.isEmpty ? "" : ", \(deadline)") + (time.isEmpty ? "" : " [\(time)]")
        })
        section("Open questions", strings("openQuestions"))
        for addition in items("additions") {
            out += ["", "## Added by \(addition["author"] as? String ?? "an agent"), \(addition["addedAt"] as? String ?? "")",
                    addition["text"] as? String ?? ""]
        }
        let header = "# Notes for \(Render.shortID(recording)), written by \(note["writer"] as? String ?? "a model")\n\n"
        // Notes are a model's summary of what other people said.
        return header + Render.untrusted("notes", out.joined(separator: "\n")) + "\n"
    }
}
