import Foundation

/// `diduny settings list|get|set`. Reads and writes only the agent settings file; Diduny
/// watches it and applies valid changes. The value is checked here before it is written.
enum SettingsCommand {
    static func run(_ args: [String], json: Bool, bundleIdentifier: String) throws {
        let url = AgentSettings.fileURL(bundleIdentifier: bundleIdentifier)
        let current = AgentSettings.readSettings(at: url)
        switch args.first ?? "list" {
        case "list":
            if json {
                output(Render.json(AgentSettings.keys.map { key -> [String: Any] in
                    var row: [String: Any] = ["key": key.name, "help": key.help]
                    if let value = current?[key.name] { row["value"] = value }
                    return row
                }))
                return
            }
            guard current != nil else {
                output("No settings file at \(url.path) yet. Open Diduny once; it writes the file.\n")
                return
            }
            var lines = ["Settings agents may change (\(url.path)):", ""]
            for key in AgentSettings.keys {
                lines.append("- \(key.name) = \(display(current?[key.name]))")
                lines.append("  \(key.help)")
            }
            output(lines.joined(separator: "\n") + "\n")
        case "get":
            guard args.count > 1 else { throw CLIError("Usage: diduny settings get <key>") }
            guard AgentSettings.key(args[1]) != nil else { throw CLIError(AgentSettings.ValidationError.unknownKey(args[1]).description) }
            output(display(current?[args[1]]) + "\n")
        case "set":
            guard args.count > 2 else { throw CLIError("Usage: diduny settings set <key> <value>") }
            let name = args[1]
            let raw = args.dropFirst(2).joined(separator: " ")
            let value: Any
            switch AgentSettings.validate(name, AgentSettings.parseArgument(raw, for: name)) {
            case let .success(valid): value = valid
            case let .failure(error): throw CLIError(error.description)
            }
            guard var settings = current else {
                throw CLIError("No settings file at \(url.path) yet. Open Diduny once; it writes the file.")
            }
            settings[name] = value
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AgentSettings.fileData(settings: settings, problems: []).write(to: url, options: .atomic)
            output("\(name) = \(display(value)). Diduny applies it within a second, or at its next launch.\n")
        default:
            throw CLIError("Unknown: settings \(args[0]). Use list, get or set.")
        }
    }

    static func display(_ value: Any?) -> String {
        switch value {
        case nil: "(not set)"
        case let text as String: "\"\(text)\""
        case let list as [String]: "[" + list.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): number.boolValue ? "true" : "false"
        case let number as NSNumber: number.stringValue
        default: "\(value!)"
        }
    }
}
