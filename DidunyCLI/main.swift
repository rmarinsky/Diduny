import Foundation

/// `diduny`: read-only access to Diduny meetings for local agents, plus the settings agents
/// may change. Markdown by default, JSON with `--json`.

struct Arguments {
    var positional: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    init(_ raw: [String]) throws {
        let valued: Set<String> = ["--since", "--type", "--limit", "--library"]
        var index = 0
        while index < raw.count {
            let item = raw[index]
            if valued.contains(item) {
                guard index + 1 < raw.count else { throw CLIError("\(item) needs a value.") }
                options[item] = raw[index + 1]
                index += 2
            } else if item.hasPrefix("--"), let equals = item.firstIndex(of: "="), valued.contains(String(item[..<equals])) {
                options[String(item[..<equals])] = String(item[item.index(after: equals)...])
                index += 1
            } else if item.hasPrefix("--") || item == "-h" {
                flags.insert(item)
                index += 1
            } else {
                positional.append(item)
                index += 1
            }
        }
    }

    var json: Bool { flags.contains("--json") }
}

let commandName = (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent }) ?? "diduny"

let usage = """
Usage: \(commandName) <command>

  meetings list [--since 7d] [--type meetings|voice|translations|files|all] [--limit N] [--json]
  meetings show <id|latest> [--no-transcript] [--json]
  search "<text>" [--since 7d] [--type ...] [--limit N] [--json]
  audio <id|latest>
  guide                         Instructions for agents: how to find, read and summarize meetings
  settings list [--json]        Settings agents may change, with current values
  settings get <key>
  settings set <key> <value>
  version

Options: --library <folder> reads another Diduny library folder.
"""

func output(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

func run() throws {
    let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
    guard let command = args.positional.first, !args.flags.contains("--help"), !args.flags.contains("-h") else {
        output(usage + "\n")
        return
    }
    let library = Library.locate(override: args.options["--library"])
    let rest = Array(args.positional.dropFirst())

    switch command {
    case "guide":
        output(Guide.text(command: commandName))

    case "version", "--version":
        let version = Library.enclosingAppBundleIdentifier().map { _ in
            let app = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        } ?? "unknown"
        output("\(commandName) \(version), library \(library.directory.path)\n")

    case "meetings", "recordings":
        let sub = rest.first ?? "list"
        let recordings = try filtered(try library.load(), args)
        switch sub {
        case "list":
            let limit = Int(args.options["--limit"] ?? "") ?? 50
            let rows = Array(recordings.prefix(limit))
            output(args.json ? Render.json(rows.map(Render.summary)) : Render.listMarkdown(rows))
        case "show":
            guard rest.count > 1 else { throw CLIError("Usage: \(commandName) meetings show <id|latest>") }
            // An id is looked up across every type, so ids printed by `--type all` work too.
            let recording = try library.find(rest[1], in: rest[1] == "latest" ? recordings : try library.load())
            let path = library.audioURL(recording).path
            let full = !args.flags.contains("--no-transcript")
            output(args.json
                ? Render.json(Render.showJSON(recording, audioPath: path, includeTranscript: full))
                : Render.showMarkdown(recording, audioPath: path, includeTranscript: full))
        default:
            throw CLIError("Unknown: meetings \(sub). Use list or show.")
        }

    case "search":
        guard let query = rest.first, !query.isEmpty else { throw CLIError("Usage: \(commandName) search \"<text>\"") }
        let hits = Render.search(query, in: try filtered(try library.load(), args),
                                 limit: Int(args.options["--limit"] ?? "") ?? 100)
        if args.json {
            output(Render.json(hits.map { hit -> [String: Any] in
                var row: [String: Any] = ["id": hit.recording.id.uuidString, "shortId": Render.shortID(hit.recording),
                                          "title": hit.recording.displayTitle, "text": hit.text]
                if let time = hit.time { row["time"] = time }
                if let speaker = hit.speaker { row["speaker"] = speaker }
                return row
            }))
        } else {
            output(Render.searchMarkdown(hits, query: query))
        }

    case "audio":
        guard let reference = rest.first else { throw CLIError("Usage: \(commandName) audio <id|latest>") }
        let all = try library.load()
        let recording = try library.find(reference, in: reference == "latest" ? try filtered(all, args) : all)
        let url = library.audioURL(recording)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError("The audio file of this recording is not on this Mac (\(url.path)).")
        }
        output(url.path + "\n")

    case "settings":
        try SettingsCommand.run(rest, json: args.json, bundleIdentifier: library.bundleIdentifier)

    default:
        throw CLIError("Unknown command \(command).\n\n\(usage)")
    }
}

func filtered(_ recordings: [Recording], _ args: Arguments) throws -> [Recording] {
    let rawType = args.options["--type"] ?? "meetings"
    guard let type = TypeFilter(rawValue: rawType) else {
        throw CLIError("--type takes \(TypeFilter.allCases.map(\.rawValue).joined(separator: ", ")).")
    }
    let since = try args.options["--since"].map(parseSince)
    return recordings.filter { type.includes($0.type) && (since == nil || $0.createdAt >= since!) }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("\(commandName): \(error)\n".utf8))
    exit(1)
}
