import AppKit
import Foundation

/// Changes go through the app: the tool drops a command file, Diduny applies it and answers.
/// The tool never writes the library or the notes itself.
enum AppCommands {
    static func isAppRunning(_ bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    static func send(_ command: AgentCommandProtocol.Command, library: Library, timeout: TimeInterval = 15) throws -> String {
        guard library.isAppLibrary else {
            throw CLIError("Changes work only in the library of the Diduny app this tool ships in. A --library or DIDUNY_LIBRARY folder can be read, not changed.")
        }
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

/// Words and replacements the running Diduny app keeps. The tool only asks; the app writes them.
enum VocabularyCommand {
    static func run(_ args: [String], library: Library) throws {
        guard args.first == "accept", args.count >= 3 else {
            throw CLIError("Usage: \(commandName) vocabulary accept word \"<word>\" | rule \"<from>\" \"<to>\"")
        }
        switch args[1] {
        case "word":
            let word = args.dropFirst(2).joined(separator: " ")
            output(try AppCommands.send(.init(action: .addVocabularyWord, values: [word]), library: library))
        case "rule":
            guard args.count >= 4 else {
                throw CLIError("Usage: \(commandName) vocabulary accept rule \"<from>\" \"<to>\"")
            }
            output(try AppCommands.send(.init(action: .addReplacement, values: [args[2], args[3]]), library: library))
        default:
            throw CLIError("Usage: \(commandName) vocabulary accept word \"<word>\" | rule \"<from>\" \"<to>\"")
        }
    }
}

/// The typing log on this Mac: what was typed, what it became, and how often.
enum TypingCommand {
    static func run(_ args: [String], options: Arguments, library: Library) throws {
        let sub = args.first ?? "summary"
        let since = try options.options["--since"].map(parseSince)
        let events = TypingLog.events(in: library.directory, since: since)
        switch sub {
        case "list":
            let kind = options.options["--kind"]
            let allowed = kind.map { $0 == "undos" ? "undone" : $0 == "replacements" ? "replaced" : $0 }
            if let allowed, !["hint", "replaced", "kept", "undone"].contains(allowed) {
                throw CLIError("--kind takes hints, replacements, undos or kept.")
            }
            let limit = Int(options.options["--limit"] ?? "") ?? 200
            let rows = events.filter { allowed == nil || $0.kind == allowed }.sorted { $0.at > $1.at }.prefix(limit)
            if options.json {
                output(Render.json(rows.map(Self.eventJSON)))
                return
            }
            let lines = rows.map { event in
                "\(Render.date(event.at))  \(event.kind)  \(event.from) → \(event.to)  \(event.origin)"
                    + (event.app.map { "  \($0)" } ?? "")
            }
            output(Render.untrusted("typing", lines.isEmpty ? "No typing rows in this range." : lines.joined(separator: "\n")) + "\n")
        case "summary", "review":
            let saved = AppPreferences.vocabulary(bundleIdentifier: library.bundleIdentifier)
            let extras = AppPreferences.extras(directory: library.directory)
            let libraryContext = recordingsContext(library)
            let blobs = libraryContext.blobs + saved.terms
            let pairs = TypingReview.pairs(from: events, context: blobs, savedTerms: saved.terms, savedRules: saved.rules.map(\.from))
            let shown = sub == "review" ? pairs.filter { $0.suggestion == "rule" || $0.suggestion == "vocabulary" } : pairs
            if options.json {
                var packet: [String: Any] = ["pairs": shown.map(Self.pairJSON)]
                if sub == "review" {
                    packet["vocabulary"] = saved.terms
                    packet["rules"] = saved.rules.map { ["from": $0.from, "to": $0.to] }
                    packet["projects"] = libraryContext.projects
                    packet["people"] = libraryContext.people
                    packet["tags"] = libraryContext.tags
                    packet["pending"] = extras.pending.map(Self.pendingJSON)
                    packet["ignored"] = extras.ignored
                    packet["removedAuto"] = extras.removedAuto
                    packet["omitted"] = pairs.count - shown.count
                }
                output(Render.json(packet))
                return
            }
            var lines = shown.map { pair in
                var line = "\(pair.from) → \(pair.to)  \(pair.origin)  \(pair.replacements) replacements, \(pair.hints) hints, \(pair.kept) kept, \(pair.undos) undos, \(pair.days) days, last \(Render.date(pair.last))"
                if !pair.apps.isEmpty { line += "  " + pair.apps.joined(separator: ", ") }
                line += "  \(pair.suggestion)"
                if !pair.term.isEmpty { line += " \"\(pair.term)\"" }
                return line
            }
            if sub == "review" {
                lines.append("")
                lines.append("Vocabulary: " + (saved.terms.isEmpty ? "(none)" : saved.terms.joined(separator: ", ")))
                lines.append("Rules: " + (saved.rules.isEmpty ? "(none)" : saved.rules.map { "\($0.from) → \($0.to)" }.joined(separator: ", ")))
                lines.append("Projects: " + (libraryContext.projects.isEmpty ? "(none)" : libraryContext.projects.joined(separator: ", ")))
                lines.append("People: " + (libraryContext.people.isEmpty ? "(none)" : libraryContext.people.joined(separator: ", ")))
                lines.append("Tags: " + (libraryContext.tags.isEmpty ? "(none)" : libraryContext.tags.joined(separator: ", ")))
                let pending = extras.pending.map(Self.pendingText)
                lines.append("Pending: " + (pending.isEmpty ? "(none)" : pending.joined(separator: "; ")))
                lines.append("\(pairs.count - shown.count) other pairs are one-offs, often undone, cut off, or already saved.")
            }
            let body = lines.isEmpty ? "No typing rows in this range." : lines.joined(separator: "\n")
            output(Render.untrusted("typing", body) + "\n")
        default:
            throw CLIError("Unknown: typing \(sub). Use list, summary or review.")
        }
    }

    private static func recordingsContext(_ library: Library) -> (blobs: [String], projects: [String], people: [String], tags: [String]) {
        let recordings = (try? library.load()) ?? []
        var blobs: [String] = []
        var projects = Set<String>()
        var people = Set<String>()
        var tags = Set<String>()
        for recording in recordings {
            if let project = recording.project, !project.isEmpty {
                projects.insert(project)
                blobs.append(project)
            }
            for tag in recording.tags ?? [] where !tag.isEmpty { tags.insert(tag) }
            for person in recording.allPeople where !person.isEmpty { people.insert(person) }
            blobs.append(contentsOf: recording.tags ?? [])
            blobs.append(contentsOf: recording.allPeople)
            blobs.append(recording.displayTitle)
        }
        let sort: (String, String) -> Bool = { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return (blobs, projects.sorted(by: sort), people.sorted(by: sort), tags.sorted(by: sort))
    }

    private static func eventJSON(_ event: TypingEvent) -> [String: Any] {
        var row: [String: Any] = [
            "at": Render.date(event.at), "kind": event.kind, "from": event.from, "to": event.to, "origin": event.origin
        ]
        if let app = event.app { row["app"] = app }
        if event.truncated { row["truncated"] = true }
        return row
    }

    private static func pairJSON(_ pair: TypingPair) -> [String: Any] {
        var row: [String: Any] = [
            "from": pair.from, "to": pair.to, "origin": pair.origin,
            "replacements": pair.replacements, "hints": pair.hints, "kept": pair.kept, "undos": pair.undos,
            "days": pair.days, "last": Render.date(pair.last), "apps": pair.apps,
            "suggestion": pair.suggestion
        ]
        if !pair.term.isEmpty { row["term"] = pair.term }
        if pair.truncated { row["truncated"] = true }
        return row
    }

    private static func pendingJSON(_ item: VocabularyPendingItem) -> [String: Any] {
        switch item.kind {
        case let .word(word):
            return ["kind": "word", "word": word, "count": item.evidence.count, "days": item.evidence.days]
        case let .replacement(from, to):
            return ["kind": "replacement", "from": from, "to": to, "count": item.evidence.count, "days": item.evidence.days]
        }
    }

    private static func pendingText(_ item: VocabularyPendingItem) -> String {
        switch item.kind {
        case let .word(word): "word \(word)"
        case let .replacement(from, to): "\(from) → \(to)"
        }
    }
}

/// Reads the typing files and the vocabulary the app already saved. Never writes them.
enum TypingLog {
    static func events(in directory: URL, since: Date?) -> [TypingEvent] {
        let folder = directory.appendingPathComponent("Typing")
        return read(folder.appendingPathComponent("auto-fix-decisions.jsonl")).compactMap { decision($0, since: since) }
            + read(folder.appendingPathComponent("replacement-history.jsonl")).compactMap { undo($0, since: since) }
    }

    private static func read(_ url: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    private static func decision(_ row: [String: Any], since: Date?) -> TypingEvent? {
        if (row["aggregateOnly"] as? Bool) == true { return nil }
        guard let at = (row["timestamp"] as? String).flatMap(TypingReview.parseDate),
              since == nil || at >= since!,
              let from = row["source"] as? String, !from.isEmpty else { return nil }
        let to = (row["selectedCandidate"] as? String) ?? ""
        let kind: String
        switch row["outcome"] as? String {
        case "replaced", "ruleApplied":
            guard !to.isEmpty else { return nil }
            kind = "replaced"
        case "proposed":
            guard !to.isEmpty else { return nil }
            kind = "hint"
        case "skipped" where (row["signalKind"] as? String) == "spellingSuggestion":
            kind = "kept"
        default:
            return nil
        }
        return TypingEvent(
            at: at, kind: kind, from: from, to: to, origin: originName(row["candidateOrigin"] as? String),
            app: row["bundleID"] as? String, truncated: truncated(from) || truncated(to)
        )
    }

    private static func undo(_ row: [String: Any], since: Date?) -> TypingEvent? {
        guard (row["kind"] as? String) == "autoFixUndone",
              let at = (row["timestamp"] as? String).flatMap(TypingReview.parseDate),
              since == nil || at >= since!,
              let from = row["original"] as? String, let to = row["converted"] as? String else { return nil }
        let marked = (row["originalTruncated"] as? Bool) == true || (row["convertedTruncated"] as? Bool) == true
        return TypingEvent(
            at: at, kind: "undone", from: from, to: to, origin: "unknown",
            app: row["bundleID"] as? String, truncated: marked || truncated(from) || truncated(to)
        )
    }

    private static func originName(_ raw: String?) -> String {
        switch raw {
        case "keyboardLayout": "layout"
        case "spelling": "spelling"
        case "customRule": "rule"
        default: "unknown"
        }
    }

    private static func truncated(_ text: String) -> Bool {
        text.contains("…") || text.count >= 80
    }
}

enum AppPreferences {
    static func vocabulary(bundleIdentifier: String) -> (terms: [String], rules: [(from: String, to: String)]) {
        CFPreferencesAppSynchronize(bundleIdentifier as CFString)
        let terms = CFPreferencesCopyAppValue("speechVocabularyTerms" as CFString, bundleIdentifier as CFString) as? [String] ?? []
        guard let data = CFPreferencesCopyAppValue("typing.customReplaceRules" as CFString, bundleIdentifier as CFString) as? Data else {
            return (terms, [])
        }
        struct Rule: Decodable { var source: String; var target: String }
        let rules = ((try? JSONDecoder().decode([Rule].self, from: data)) ?? []).map { (from: $0.source, to: $0.target) }
        return (terms, rules)
    }

    static func extras(directory: URL) -> VocabularyExtras {
        let url = directory.appendingPathComponent("vocabulary_extras.json")
        guard let data = try? Data(contentsOf: url),
              let extras = try? JSONDecoder().decode(VocabularyExtras.self, from: data) else { return VocabularyExtras() }
        return extras
    }
}
