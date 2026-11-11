import Foundation

/// The fields every writer returns. Writers are asked for JSON with this schema so the
/// notes have no preamble or cut-off prose.
struct NotesDraft: Decodable {
    struct Decision: Decodable { var text: String; var time: String? }
    struct Action: Decodable { var owner: String?; var task: String; var deadline: String?; var time: String? }
    var summary: String
    var points: [String]?
    var decisions: [Decision]?
    var actionItems: [Action]?
    var openQuestions: [String]?

    /// Strict schema: every property required, no extra properties (Codex requires this).
    static let schema: [String: Any] = {
        func object(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "additionalProperties": false,
             "required": Array(properties.keys).sorted(), "properties": properties]
        }
        let string: [String: Any] = ["type": "string"]
        func array(_ items: [String: Any]) -> [String: Any] { ["type": "array", "items": items] }
        return object([
            "summary": string,
            "points": array(string),
            "decisions": array(object(["text": string, "time": string])),
            "actionItems": array(object(["owner": string, "task": string, "deadline": string, "time": string])),
            "openQuestions": array(string)
        ])
    }()

    static var schemaJSON: String {
        String(decoding: try! JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), as: UTF8.self)
    }

    static func decode(_ text: String) throws -> NotesDraft {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Local models sometimes wrap the JSON in a code fence.
        if let open = body.firstIndex(of: "{"), let close = body.lastIndex(of: "}") {
            body = String(body[open ... close])
        }
        do {
            return try JSONDecoder().decode(NotesDraft.self, from: Data(body.utf8))
        } catch {
            throw NotesError.unreadableAnswer
        }
    }
}

enum NotesError: LocalizedError {
    case noWriter
    case noTranscript
    case notApproved(String)
    case notFound(String)
    case server(String)
    case tool(String)
    case unreadableAnswer
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noWriter: String(localized: "Choose who writes the notes in Notes settings.")
        case .noTranscript: String(localized: "This recording has no transcript yet.")
        case let .notApproved(name): String(localized: "\(name) is not allowed yet. Allow it in Notes settings.")
        case let .notFound(name): String(localized: "\(name) was not found on this Mac.")
        case let .server(message): message
        case let .tool(message): message
        case .unreadableAnswer: String(localized: "The model's answer could not be read as notes. Try again or pick another model.")
        case .timedOut: String(localized: "The model did not answer in time.")
        }
    }
}

protocol NotesWriter {
    var displayName: String { get }
    /// Whole transcripts fit; local models get the transcript in parts.
    var partCharacters: Int? { get }
    func write(prompt: String) async throws -> NotesDraft
}

// MARK: - Local servers

/// Ollama (`/api/chat`) or LM Studio (OpenAI-compatible `/v1/chat/completions`) on this Mac.
struct LocalServerWriter: NotesWriter {
    let kind: NotesWriterKind
    let address: String
    let model: String

    var displayName: String { "\(kind.label), \(model)" }
    var partCharacters: Int? { 24000 }

    func write(prompt: String) async throws -> NotesDraft {
        guard !model.isEmpty else { throw NotesError.server(String(localized: "Choose a model in Notes settings.")) }
        let messages = [["role": "user", "content": prompt]]
        let path: String
        let body: [String: Any]
        if kind == .ollama {
            path = "/api/chat"
            body = ["model": model, "messages": messages, "stream": false, "format": NotesDraft.schema,
                    "options": ["num_ctx": 16384, "temperature": 0.2]]
        } else {
            path = "/v1/chat/completions"
            body = ["model": model, "messages": messages, "temperature": 0.2,
                    "response_format": ["type": "json_schema",
                                        "json_schema": ["name": "notes", "strict": true, "schema": NotesDraft.schema]]]
        }
        let reply = try await Self.post(address + path, body: body)
        let content: String? = kind == .ollama
            ? (reply["message"] as? [String: Any])?["content"] as? String
            : (((reply["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any])?["content"] as? String
        guard let content else { throw NotesError.unreadableAnswer }
        return try NotesDraft.decode(content)
    }

    /// Model names the server has, for the picker.
    static func models(kind: NotesWriterKind, address: String) async throws -> [String] {
        if kind == .ollama {
            let reply = try await get(address + "/api/tags")
            return ((reply["models"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        }
        let reply = try await get(address + "/v1/models")
        return ((reply["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
    }

    private static func get(_ url: String) async throws -> [String: Any] {
        guard let url = URL(string: url) else { throw NotesError.server(String(localized: "The address is not valid.")) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        return try await send(request)
    }

    private static func post(_ url: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: url) else { throw NotesError.server(String(localized: "The address is not valid.")) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 1800
        return try await send(request)
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NotesError.server(String(localized: "The server is not running at \(request.url?.host ?? ""):\(request.url?.port ?? 0)."))
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
            let message = (json["error"] as? String) ?? ((json["error"] as? [String: Any])?["message"] as? String)
            throw NotesError.server(message ?? String(localized: "The server answered with error \(status)."))
        }
        return json
    }
}

// MARK: - Subscription CLIs

/// Runs `claude -p` or `codex exec` headless with tools, MCP servers, hooks and saved
/// sessions switched off, following pingdotgg/t3code. The prompt goes on stdin.
struct CLIWriter: NotesWriter {
    let kind: NotesWriterKind
    let executable: String
    let model: String

    var displayName: String { model.isEmpty ? kind.label : "\(kind.label), \(model)" }
    var partCharacters: Int? { nil }

    func write(prompt: String) async throws -> NotesDraft {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("diduny-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        switch kind {
        case .claudeCode:
            var arguments = ["-p", "--output-format", "json", "--json-schema", NotesDraft.schemaJSON,
                             "--tools", "", "--disable-slash-commands", "--strict-mcp-config",
                             "--permission-mode", "dontAsk", "--settings", #"{"disableAllHooks":true}"#,
                             "--no-session-persistence"]
            if !model.isEmpty { arguments += ["--model", model] }
            let run = try await CLIRunner.run(executable, arguments, stdin: prompt, in: work)
            return try Self.parseClaude(run)
        case .codex:
            let schemaURL = work.appendingPathComponent("schema.json")
            let answerURL = work.appendingPathComponent("answer.json")
            try Data(NotesDraft.schemaJSON.utf8).write(to: schemaURL)
            var arguments = ["exec", "--ephemeral", "--skip-git-repo-check", "-s", "read-only",
                             "--config", "features.plugins=false", "--config", "features.apps=false",
                             "--output-schema", schemaURL.path, "--output-last-message", answerURL.path]
            if let mcpOff = Self.codexMCPServersOff() { arguments += ["--config", mcpOff] }
            if !model.isEmpty { arguments += ["--model", model] }
            arguments.append("-")
            let run = try await CLIRunner.run(executable, arguments, stdin: prompt, in: work)
            guard let answer = try? String(contentsOf: answerURL, encoding: .utf8), !answer.isEmpty else {
                throw NotesError.tool(run.errorSummary)
            }
            return try NotesDraft.decode(answer)
        default:
            throw NotesError.noWriter
        }
    }

    /// `mcp_servers={}` merges instead of replacing, so each configured server is turned off by name.
    static func codexMCPServersOff() -> String? {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "\(NSHomeDirectory())/.codex"
        guard let config = try? String(contentsOfFile: "\(home)/config.toml", encoding: .utf8) else { return nil }
        var names: [String] = []
        for line in config.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[mcp_servers."), trimmed.hasSuffix("]") else { continue }
            var name = String(trimmed.dropFirst("[mcp_servers.".count).dropLast())
            if name.contains("."), !name.hasPrefix("\"") { continue } // a sub-table such as [mcp_servers.x.env]
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !names.contains(name) { names.append(name) }
        }
        guard !names.isEmpty else { return nil }
        return "mcp_servers={" + names.map { "\"\($0)\"={enabled=false}" }.joined(separator: ",") + "}"
    }

    /// Older CLIs print one result object; newer ones print every message as an array.
    static func parseClaude(_ run: CLIRunner.Result) throws -> NotesDraft {
        let json = try? JSONSerialization.jsonObject(with: Data(run.stdout.utf8))
        let result = (json as? [String: Any])
            ?? (json as? [[String: Any]])?.last(where: { $0["type"] as? String == "result" })
        guard let result else { throw NotesError.tool(run.errorSummary) }
        if result["is_error"] as? Bool == true {
            throw NotesError.tool((result["result"] as? String) ?? run.errorSummary)
        }
        if let structured = result["structured_output"],
           let data = try? JSONSerialization.data(withJSONObject: structured),
           let draft = try? JSONDecoder().decode(NotesDraft.self, from: data) {
            return draft
        }
        return try NotesDraft.decode(result["result"] as? String ?? "")
    }
}

enum CLIRunner {
    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String

        var errorSummary: String {
            let text = stderr.nilIfBlank ?? stdout.nilIfBlank ?? String(localized: "The tool stopped with code \(status).")
            return String(text.suffix(400))
        }
    }

    static let timeout: TimeInterval = 900

    /// PATH of the user's login shell, so tools installed by Homebrew, npm or the vendor's
    /// installer are found. `HOME` is left as is: changing it hides the tool's Keychain login.
    static func environment() async -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("CLAUDECODE") && !$0.key.hasPrefix("CLAUDE_CODE_")
        }
        if let path = await loginShellPATH() { env["PATH"] = path }
        return env
    }

    private static var cachedPATH: String?

    static func loginShellPATH() async -> String? {
        if let cachedPATH { return cachedPATH }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let run = try? await run(shell, ["-ilc", "printf %s \"$PATH\""], stdin: nil, in: nil,
                                 environment: ProcessInfo.processInfo.environment, timeout: 10)
        let path = run?.stdout.split(separator: "\n").last.map(String.init)?.nilIfBlank
        cachedPATH = path
        return path
    }

    /// The tool's full path: the user's chosen location, else the login shell's PATH.
    static func locate(_ kind: NotesWriterKind) async -> String? {
        if let custom = NotesSettings.customExecutablePath(for: kind),
           FileManager.default.isExecutableFile(atPath: custom) { return custom }
        guard let name = kind.executableName else { return nil }
        let path = await loginShellPATH() ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        let extra = ["\(NSHomeDirectory())/.local/bin", "\(NSHomeDirectory())/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]
        for directory in path.split(separator: ":").map(String.init) + extra {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func version(_ executable: String) async -> String? {
        let run = try? await run(executable, ["--version"], stdin: nil, in: nil, timeout: 15)
        guard let run, run.status == 0 else { return nil }
        return run.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        stdin: String?,
        in directory: URL?,
        environment: [String: String]? = nil,
        timeout: TimeInterval = timeout
    ) async throws -> Result {
        let env: [String: String] = if let environment { environment } else { await self.environment() }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = env
                if let directory { process.currentDirectoryURL = directory }
                let input = Pipe()
                let output = Pipe()
                let errors = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = errors
                var outData = Data()
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { outData = output.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter()
                DispatchQueue.global().async { errData = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: NotesError.notFound(executable))
                    return
                }
                if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
                try? input.fileHandleForWriting.close()
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                process.waitUntilExit()
                timer.cancel()
                group.wait()
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: NotesError.timedOut)
                    return
                }
                continuation.resume(returning: Result(status: process.terminationStatus,
                                                      stdout: String(decoding: outData, as: UTF8.self),
                                                      stderr: String(decoding: errData, as: UTF8.self)))
            }
        }
    }
}
