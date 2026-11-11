import Foundation

/// Settings that local agents may change through `~/.config/diduny/settings.json`.
/// Shared by the app (which applies them) and the `diduny` command line tool (which validates
/// before writing). Settings that could reroute audio (proxy and remote config addresses),
/// delete recordings (history retention), or change hotkeys, devices and permissions are
/// deliberately not here.
enum AgentSettings {
    enum Kind: Equatable {
        case text(maxLength: Int)
        case bool
        case number(ClosedRange<Double>)
        case choice([String])
        case words
        case languages
        case language(allowAuto: Bool)
    }

    struct Key: Equatable {
        let name: String
        let kind: Kind
        let help: String
    }

    static let keys: [Key] = [
        Key(name: "whisperPrompt", kind: .text(maxLength: 2000),
            help: "Words and spelling hints for local (Whisper) transcription."),
        Key(name: "whisperLanguage", kind: .language(allowAuto: true),
            help: "Language for local transcription, a code such as \"uk\", or \"auto\"."),
        Key(name: "speechLanguages", kind: .languages,
            help: "Languages you speak, as codes such as [\"uk\", \"en\"]. Helps cloud transcription."),
        Key(name: "translationTargetLanguages", kind: .languages,
            help: "Languages Diduny offers to translate into, as codes."),
        Key(name: "fillerWords", kind: .words,
            help: "Words removed from dictated text, such as \"um\"."),
        Key(name: "messageFormattingMode", kind: .choice(["normal", "chat"]),
            help: "\"chat\" formats pasted text for chat apps; \"normal\" leaves it as is."),
        Key(name: "dictationSilenceAutoStopEnabled", kind: .bool,
            help: "Stop dictation after a pause."),
        Key(name: "dictationSilenceAutoStopSeconds", kind: .number(1 ... 10),
            help: "Seconds of silence before dictation stops, 1 to 10."),
        Key(name: "meetingSilenceAutoStopEnabled", kind: .bool,
            help: "Stop a meeting recording after a long silence."),
        Key(name: "meetingSilenceAutoStopSeconds", kind: .number(10 ... 300),
            help: "Seconds of silence before a meeting recording stops, 10 to 300."),
        Key(name: "speakerIdentificationEnabled", kind: .bool,
            help: "Label speakers in meeting transcripts."),
        Key(name: "playSoundOnCompletion", kind: .bool,
            help: "Play a sound when a transcription is ready.")
    ]

    static func key(_ name: String) -> Key? {
        keys.first { $0.name == name }
    }

    /// `~/.config/diduny/settings.json` for the release build, `settings.dev.json` for DEV,
    /// `settings.test.json` for TEST, so the builds never overwrite each other's file.
    static func fileURL(bundleIdentifier: String) -> URL {
        let suffix = bundleIdentifier.hasSuffix(".dev") ? ".dev" : bundleIdentifier.hasSuffix(".test") ? ".test" : ""
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/diduny/settings\(suffix).json")
    }

    enum ValidationError: Error, CustomStringConvertible {
        case unknownKey(String)
        case invalid(String, String)

        var description: String {
            switch self {
            case let .unknownKey(name): "\(name): not a setting agents can change"
            case let .invalid(name, reason): "\(name): \(reason)"
            }
        }
    }

    /// Checks a JSON value and returns it normalized (trimmed text, lowercased codes).
    static func validate(_ name: String, _ value: Any) -> Result<Any, ValidationError> {
        guard let key = key(name) else { return .failure(.unknownKey(name)) }
        switch key.kind {
        case let .text(maxLength):
            guard let text = value as? String else { return .failure(.invalid(name, "must be text")) }
            guard text.count <= maxLength else { return .failure(.invalid(name, "longer than \(maxLength) characters")) }
            return .success(text)
        case .bool:
            guard isJSONBool(value), let flag = value as? Bool else { return .failure(.invalid(name, "must be true or false")) }
            return .success(flag)
        case let .number(range):
            guard !isJSONBool(value), let number = (value as? NSNumber)?.doubleValue else {
                return .failure(.invalid(name, "must be a number"))
            }
            guard range.contains(number) else {
                return .failure(.invalid(name, "must be from \(Int(range.lowerBound)) to \(Int(range.upperBound))"))
            }
            return .success(number)
        case let .choice(options):
            guard let text = value as? String, options.contains(text) else {
                return .failure(.invalid(name, "must be one of: \(options.joined(separator: ", "))"))
            }
            return .success(text)
        case .words:
            guard let words = value as? [String] else { return .failure(.invalid(name, "must be a list of text")) }
            return .success(words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        case .languages:
            guard let codes = value as? [String] else { return .failure(.invalid(name, "must be a list of language codes")) }
            var result: [String] = []
            for code in codes {
                guard let normalized = SupportedLanguage.normalizedCode(code) else {
                    return .failure(.invalid(name, "\"\(code)\" is not a supported language code"))
                }
                if !result.contains(normalized) { result.append(normalized) }
            }
            return .success(result)
        case let .language(allowAuto):
            guard let code = value as? String, let normalized = SupportedLanguage.normalizedCode(code, allowAuto: allowAuto) else {
                return .failure(.invalid(name, "must be a supported language code\(allowAuto ? " or \"auto\"" : "")"))
            }
            return .success(normalized)
        }
    }

    /// JSON `true`/`false`, not the numbers 1 and 0 (both bridge to Bool in Swift).
    static func isJSONBool(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// Parses a command line value for `diduny settings set`: true/false, a number,
    /// a JSON array, or comma-separated items for lists. Anything else is text.
    static func parseArgument(_ raw: String, for name: String) -> Any {
        guard let key = key(name) else { return raw }
        switch key.kind {
        case .bool:
            switch raw.lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: return raw
            }
        case .number:
            return Double(raw).map { NSNumber(value: $0) } ?? raw
        case .words, .languages:
            if raw.hasPrefix("["), let data = raw.data(using: .utf8),
               let array = try? JSONSerialization.jsonObject(with: data) as? [String] {
                return array
            }
            return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        default:
            return raw
        }
    }

    static let fileComment = "Diduny settings that local agents may change. Diduny applies valid changes within a second and rewrites this file with the settings in use. Invalid values are listed under \"problems\" and ignored. Run `diduny settings list` for what each setting does."

    /// The file's JSON: comment, settings and problems, with stable key order.
    static func fileData(settings: [String: Any], problems: [String]) -> Data {
        var object: [String: Any] = ["comment": fileComment, "settings": settings]
        if !problems.isEmpty { object["problems"] = problems }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return data + Data("\n".utf8)
    }

    /// The `settings` object of a file, or nil when the file is missing or not JSON.
    static func readSettings(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["settings"] as? [String: Any]
    }
}
