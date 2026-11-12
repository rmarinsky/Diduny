import Foundation

/// The fields every writer returns. Writers are asked for JSON with this schema so the
/// notes have no preamble or cut-off prose.
struct NotesDraft: Decodable {
    struct Decision: Decodable { var text: String; var time: String? }
    struct Action: Decodable { var owner: String?; var task: String; var deadline: String?; var time: String? }
    var summary: String
    var points: [String]?
    var topics: [String]?
    var decisions: [Decision]?
    var actionItems: [Action]?
    var openQuestions: [String]?

    /// Strict schema: every property required, no extra properties (Codex requires this).
    static let schema: [String: Any] = JSONSchema.object([
        "summary": JSONSchema.string,
        "points": JSONSchema.array(JSONSchema.string),
        "topics": JSONSchema.array(JSONSchema.string),
        "decisions": JSONSchema.array(JSONSchema.object(["text": JSONSchema.string, "time": JSONSchema.string])),
        "actionItems": JSONSchema.array(JSONSchema.object([
            "owner": JSONSchema.string, "task": JSONSchema.string,
            "deadline": JSONSchema.string, "time": JSONSchema.string
        ])),
        "openQuestions": JSONSchema.array(JSONSchema.string)
    ])

    static func decode(_ text: String) throws -> NotesDraft {
        try JSONSchema.decode(NotesDraft.self, from: text)
    }
}

/// The transcript check's answer: numbers of the items the transcript supports.
struct NotesCheckResult: Decodable {
    var supported: [Int]
    static let schema: [String: Any] = JSONSchema.object(["supported": JSONSchema.array(["type": "integer"])])
}

enum JSONSchema {
    static let string: [String: Any] = ["type": "string"]

    static func array(_ items: [String: Any]) -> [String: Any] {
        ["type": "array", "items": items]
    }

    static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "additionalProperties": false,
         "required": Array(properties.keys).sorted(), "properties": properties]
    }

    static func text(_ schema: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data(),
               as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some models wrap the JSON in a code fence or add a line before it.
        if let open = body.firstIndex(of: "{"), let close = body.lastIndex(of: "}") {
            body = String(body[open ... close])
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(body.utf8))
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
    var kind: NotesWriterKind { get }
    var displayName: String { get }
    /// Whole transcripts fit; local models get the transcript in parts.
    var partCharacters: Int? { get }
    /// Returns the model's answer as JSON text that follows `schema`.
    func complete(prompt: String, schema: [String: Any]) async throws -> String
}

// MARK: - Local servers and OpenAI-style APIs

/// Ollama (`/api/chat`), or LM Studio and other OpenAI-compatible servers (`/v1/chat/completions`).
struct LocalServerWriter: NotesWriter {
    let kind: NotesWriterKind
    let address: String
    let model: String

    var displayName: String { "\(kind == .openAICompatible ? String(localized: "Local server") : kind.label), \(model)" }
    var partCharacters: Int? { 24000 }

    func complete(prompt: String, schema: [String: Any]) async throws -> String {
        guard !model.isEmpty else { throw NotesError.server(String(localized: "Choose a model in Notes settings.")) }
        let messages = [["role": "user", "content": prompt]]
        if kind == .ollama {
            let reply = try await HTTPJSON.post(address + "/api/chat", body: [
                "model": model, "messages": messages, "stream": false, "format": schema,
                "options": ["num_ctx": 16384, "temperature": 0.2]
            ])
            guard let content = (reply["message"] as? [String: Any])?["content"] as? String else {
                throw NotesError.unreadableAnswer
            }
            return content
        }
        return try await OpenAIChat.complete(address: address, key: nil, model: model, prompt: prompt, schema: schema)
    }

    struct Model: Hashable {
        var name: String
        /// Bytes on disk, when the server reports it (Ollama does).
        var size: Int64?
    }

    /// Models the server has that can write text (embedding models are left out).
    static func models(kind: NotesWriterKind, address: String) async throws -> [Model] {
        let models: [Model]
        if kind == .ollama {
            let reply = try await HTTPJSON.get(address + "/api/tags")
            models = ((reply["models"] as? [[String: Any]]) ?? []).compactMap { row in
                (row["name"] as? String).map { Model(name: $0, size: (row["size"] as? NSNumber)?.int64Value) }
            }
        } else {
            let reply = try await HTTPJSON.get(address + "/v1/models")
            models = ((reply["data"] as? [[String: Any]]) ?? []).compactMap { ($0["id"] as? String).map { Model(name: $0) } }
        }
        return models.filter { !$0.name.lowercased().contains("embed") }
    }
}

enum OpenAIChat {
    static func complete(address: String, key: String?, model: String, prompt: String, schema: [String: Any]) async throws -> String {
        let reply = try await HTTPJSON.post(address + "/v1/chat/completions", body: [
            "model": model, "temperature": 0.2,
            "messages": [["role": "user", "content": prompt]],
            "response_format": ["type": "json_schema", "json_schema": ["name": "notes", "strict": true, "schema": schema]]
        ], headers: key.map { ["Authorization": "Bearer \($0)"] } ?? [:])
        guard let content = (((reply["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any])?["content"] as? String else {
            throw NotesError.unreadableAnswer
        }
        return content
    }
}

/// An API key the user entered: Anthropic Messages API (a forced tool call returns the JSON),
/// OpenAI, or another OpenAI-compatible address. Paid per use.
struct APIKeyWriter: NotesWriter {
    let provider: NotesAPIProvider
    let key: String
    let model: String
    let address: String

    var kind: NotesWriterKind { .apiKey }
    var displayName: String { "\(provider.label), \(model)" }
    var partCharacters: Int? { nil }

    func complete(prompt: String, schema: [String: Any]) async throws -> String {
        switch provider {
        case .anthropic:
            // Current models reject a forced tool_choice, so the JSON comes from structured
            // outputs: the first text block is valid JSON that follows the schema.
            let reply = try await HTTPJSON.post("https://api.anthropic.com/v1/messages", body: [
                "model": model, "max_tokens": 16000,
                "messages": [["role": "user", "content": prompt]],
                "output_config": ["format": ["type": "json_schema", "schema": schema]]
            ], headers: ["x-api-key": key, "anthropic-version": "2023-06-01"])
            if reply["stop_reason"] as? String == "refusal" {
                throw NotesError.server(String(localized: "The model declined to write notes for this recording."))
            }
            let text = ((reply["content"] as? [[String: Any]]) ?? []).first { $0["type"] as? String == "text" }?["text"] as? String
            guard let text else { throw NotesError.unreadableAnswer }
            return text
        case .openAI:
            return try await OpenAIChat.complete(address: "https://api.openai.com", key: key, model: model, prompt: prompt, schema: schema)
        case .other:
            return try await OpenAIChat.complete(address: address, key: key, model: model, prompt: prompt, schema: schema)
        }
    }
}

enum HTTPJSON {
    static func get(_ url: String) async throws -> [String: Any] {
        guard let url = URL(string: url) else { throw NotesError.server(String(localized: "The address is not valid.")) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        return try await send(request)
    }

    static func post(_ url: String, body: [String: Any], headers: [String: String] = [:]) async throws -> [String: Any] {
        guard let url = URL(string: url) else { throw NotesError.server(String(localized: "The address is not valid.")) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
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
            throw NotesError.server(String(localized: "No answer from \(request.url?.host ?? "the server")."))
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

/// Runs `claude -p`, `codex exec` or `gemini -p` headless. Claude Code and Codex run with tools,
/// MCP servers, hooks and saved sessions off, following pingdotgg/t3code. Gemini CLI has no
/// read-only switch without an experimental setting, so it runs in an empty folder with
/// extensions off and no tool approvals. The prompt goes on stdin.
struct CLIWriter: NotesWriter {
    let kind: NotesWriterKind
    let executable: String
    let tier: NotesModelTier

    var displayName: String {
        switch kind {
        case .claudeCode: "Claude Code, \(tier.claudeAlias)"
        case .codex: tier == .standard ? "Codex" : "Codex, \(tier.label.lowercased())"
        default: kind.label
        }
    }

    var partCharacters: Int? { nil }

    func complete(prompt: String, schema: [String: Any]) async throws -> String {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("diduny-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        switch kind {
        case .claudeCode:
            let arguments = ["-p", "--output-format", "json", "--json-schema", JSONSchema.text(schema),
                             "--model", tier.claudeAlias,
                             "--tools", "", "--disable-slash-commands", "--strict-mcp-config",
                             "--permission-mode", "dontAsk", "--settings", #"{"disableAllHooks":true}"#,
                             "--no-session-persistence"]
            let run = try await CLIRunner.run(executable, arguments, stdin: prompt, in: work)
            return try Self.parseClaude(run)
        case .codex:
            let schemaURL = work.appendingPathComponent("schema.json")
            let answerURL = work.appendingPathComponent("answer.json")
            try Data(JSONSchema.text(schema).utf8).write(to: schemaURL)
            var arguments = ["exec", "--ephemeral", "--skip-git-repo-check", "-s", "read-only"] + Self.codexLockdown
                + ["--output-schema", schemaURL.path, "--output-last-message", answerURL.path]
            if let mcpOff = try await Self.codexMCPServersOff(executable: executable, in: work) { arguments += ["--config", mcpOff] }
            if let effort = tier.codexEffort { arguments += ["--config", "model_reasoning_effort=\"\(effort)\""] }
            arguments.append("-")
            let run = try await CLIRunner.run(executable, arguments, stdin: prompt, in: work)
            guard let answer = try? String(contentsOf: answerURL, encoding: .utf8), !answer.isEmpty else {
                throw NotesError.tool(run.errorSummary)
            }
            return answer
        case .gemini:
            // The transcript is untrusted text, so Gemini runs with no tools at all, whatever the
            // user's own Gemini settings say: `--approval-mode default` overrides an auto-approve
            // default (headless default mode drops every tool that needs approval), and a system
            // settings file, which Gemini CLI applies over user and workspace settings, limits the
            // core tools to one that does not exist.
            let settingsURL = work.appendingPathComponent("gemini-system-settings.json")
            try Data(#"{"tools":{"core":["diduny_no_tools"]},"general":{"defaultApprovalMode":"default"}}"#.utf8)
                .write(to: settingsURL)
            var environment = await CLIRunner.environment()
            environment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"] = settingsURL.path
            let arguments = ["-o", "json", "--approval-mode", "default", "-e", "none",
                             "--allowed-mcp-server-names", "diduny-none",
                             "-p", "Answer only with one JSON object that follows this JSON schema, with no other text: "
                                 + JSONSchema.text(schema)]
            let run = try await CLIRunner.run(executable, arguments, stdin: prompt, in: work, environment: environment)
            return try Self.parseGemini(run)
        default:
            throw NotesError.noWriter
        }
    }

    /// Settings that keep Codex from reading files, running commands or fetching pages.
    /// No shell and no web search: a transcript that contains instructions must not be able to
    /// make Codex read files or fetch pages. Checked with codex-cli 0.166.0: without
    /// unified_exec off it still runs shell commands.
    static let codexLockdown: [String] = [
        "--config", "features.plugins=false", "--config", "features.apps=false",
        "--config", "features.shell_tool=false", "--config", "features.unified_exec=false",
        "--config", "features.browser_use=false", "--config", "features.computer_use=false",
        "--config", "features.in_app_browser=false", "--config", "features.code_mode_host=false",
        "--config", "web_search=\"disabled\""
    ]

    /// Every MCP server Codex would load, from Codex itself (`codex mcp list --json`, which
    /// also covers servers from plugins and every TOML form), turned off by name. Codex is then
    /// asked again with the override applied; if any server is still on, the run is refused.
    /// `mcp_servers={}` merges instead of replacing, so servers must be named.
    static func codexMCPServersOff(executable: String, in work: URL) async throws -> String? {
        func enabledServers(_ extra: [String]) async throws -> [String] {
            let run = try await CLIRunner.run(executable, ["mcp", "list", "--json"] + codexLockdown + extra,
                                              stdin: nil, in: work, timeout: 30)
            guard run.status == 0,
                  let list = (try? JSONSerialization.jsonObject(with: Data(run.stdout.utf8))) as? [[String: Any]] else {
                throw NotesError.tool(String(localized: "Diduny could not check Codex's MCP servers, so it did not send the transcript. \(run.errorSummary)"))
            }
            return list.filter { $0["enabled"] as? Bool != false }.compactMap { $0["name"] as? String }
        }
        let names = try await enabledServers([])
        guard !names.isEmpty else { return nil }
        let override = "mcp_servers={" + names.map { "\(tomlString($0))={enabled=false}" }.joined(separator: ",") + "}"
        let stillOn = try await enabledServers(["--config", override])
        guard stillOn.isEmpty else {
            throw NotesError.tool(String(localized: "Diduny could not turn off these Codex MCP servers, so it did not send the transcript: \(stillOn.joined(separator: ", ")). Turn them off in Codex or choose another writer."))
        }
        return override
    }

    /// A TOML basic string: quotes and backslashes escaped.
    static func tomlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Older CLIs print one result object; newer ones print every message as an array.
    static func parseClaude(_ run: CLIRunner.Result) throws -> String {
        let json = try? JSONSerialization.jsonObject(with: Data(run.stdout.utf8))
        let result = (json as? [String: Any])
            ?? (json as? [[String: Any]])?.last(where: { $0["type"] as? String == "result" })
        guard let result else { throw NotesError.tool(run.errorSummary) }
        if result["is_error"] as? Bool == true {
            throw NotesError.tool((result["result"] as? String) ?? run.errorSummary)
        }
        if let structured = result["structured_output"],
           let data = try? JSONSerialization.data(withJSONObject: structured) {
            return String(decoding: data, as: UTF8.self)
        }
        return result["result"] as? String ?? ""
    }

    /// `gemini -o json` prints `{"response": ...}` or `{"error": {"message": ...}}`.
    static func parseGemini(_ run: CLIRunner.Result) throws -> String {
        let body = run.stdout.firstIndex(of: "{").map { String(run.stdout[$0...]) } ?? run.stdout
        guard let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            throw NotesError.tool(run.errorSummary)
        }
        if let error = json["error"] as? [String: Any] {
            throw NotesError.tool(error["message"] as? String ?? run.errorSummary)
        }
        guard let response = json["response"] as? String else { throw NotesError.tool(run.errorSummary) }
        return response
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
        let control = LaunchControl()
        running.insert(control)
        defer { running.remove(control) }
        // Cancel (the notes block's Cancel button) stops the tool, and a cancel that comes
        // before the launch keeps it from starting, so no transcript is sent.
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await launch(control, executable, arguments, stdin: stdin, in: directory, environment: env, timeout: timeout)
        } onCancel: {
            control.cancel()
        }
    }

    /// Tools running now, so quitting Diduny can stop them instead of leaving them behind.
    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var controls: [ObjectIdentifier: LaunchControl] = [:]
        func insert(_ control: LaunchControl) { lock.withLock { controls[ObjectIdentifier(control)] = control } }
        func remove(_ control: LaunchControl) { lock.withLock { controls[ObjectIdentifier(control)] = nil } }
        var all: [LaunchControl] { lock.withLock { Array(controls.values) } }
    }

    private static let running = Running()

    static var runningCount: Int { running.all.count }

    /// Stops every tool Diduny started (notes writers), on quit. Their notes are not saved.
    static func terminateAll() {
        running.all.forEach { $0.cancel() }
    }

    /// Output read on other threads; a reader that is still running after the bounded wait
    /// cannot race the result.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data()
        private var errData = Data()
        func setOut(_ data: Data) { lock.lock(); outData = data; lock.unlock() }
        func setErr(_ data: Data) { lock.lock(); errData = data; lock.unlock() }
        var out: Data { lock.lock(); defer { lock.unlock() }; return outData }
        var err: Data { lock.lock(); defer { lock.unlock() }; return errData }
    }

    /// Shared between the cancel handler, the timeout and the launch thread.
    private final class LaunchControl: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private var timedOut = false

        /// Both flags read together under the lock, after the process ended.
        var outcome: (cancelled: Bool, timedOut: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (cancelled, timedOut)
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
            stop()
        }

        func timeOut() {
            lock.lock()
            timedOut = true
            lock.unlock()
            stop()
        }

        /// SIGTERM first; a tool that ignores it gets SIGKILL 5 s later, which it cannot ignore.
        private func stop() {
            lock.lock()
            let running = process
            lock.unlock()
            guard let running, running.isRunning else { return }
            running.terminate()
            let pid = running.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if running.isRunning { kill(pid, SIGKILL) }
            }
        }

        /// Starts the process unless a cancel already came in.
        func start(_ process: Process) throws {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { throw CancellationError() }
            try process.run()
            self.process = process
        }
    }

    private static func launch(
        _ control: LaunchControl,
        _ executable: String,
        _ arguments: [String],
        stdin: String?,
        in directory: URL?,
        environment env: [String: String],
        timeout: TimeInterval
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
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
                // A tool that exits before reading the prompt must fail the job, not kill
                // Diduny with SIGPIPE.
                _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                do {
                    try control.start(process)
                } catch {
                    try? input.fileHandleForWriting.close()
                    continuation.resume(throwing: error is CancellationError ? error : NotesError.notFound(executable))
                    return
                }
                // The timeout runs from launch, so a tool that stops reading stdin is still stopped.
                let timer = DispatchWorkItem { control.timeOut() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let collected = Collected()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { collected.setOut(output.fileHandleForReading.readDataToEndOfFile()); group.leave() }
                group.enter()
                DispatchQueue.global().async { collected.setErr(errors.fileHandleForReading.readDataToEndOfFile()); group.leave() }
                // The prompt goes on its own thread: a full pipe blocks it, not the timeout.
                DispatchQueue.global().async {
                    if let stdin { try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8)) }
                    try? input.fileHandleForWriting.close()
                }
                process.waitUntilExit()
                timer.cancel()
                // A child the tool started can keep the pipes open after the tool exits; the
                // result does not wait for it forever.
                _ = group.wait(timeout: .now() + 10)
                let outcome = control.outcome
                if outcome.cancelled {
                    continuation.resume(throwing: CancellationError())
                } else if outcome.timedOut {
                    continuation.resume(throwing: NotesError.timedOut)
                } else {
                    continuation.resume(returning: Result(status: process.terminationStatus,
                                                          stdout: String(decoding: collected.out, as: UTF8.self),
                                                          stderr: String(decoding: collected.err, as: UTF8.self)))
                }
            }
        }
    }
}
