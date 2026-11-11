import AppKit
import SwiftUI

/// Notes settings, laid out as in docs/design/meeting-notes/prototype.html.
struct NotesSettingsView: View {
    @State private var group = NotesSettings.group
    @State private var meetingTiming = NotesSettings.meetingTiming
    @State private var voiceTiming = NotesSettings.voiceTiming
    @State private var waitForPower = NotesSettings.waitForPower
    @State private var notify = NotesSettings.notifyWhenReady
    @State private var template = NotesSettings.meetingTemplate
    @State private var promptTemplate = NotesSettings.meetingTemplate
    @State private var sections = NotesSettings.sections
    @State private var language = NotesSettings.language
    @State private var length = NotesSettings.length
    @State private var terms = NotesSettings.terms
    @State private var useCalendarNames = NotesSettings.useCalendarNames
    @State private var prompt = NotesSettings.prompt(for: NotesSettings.meetingTemplate)
    @State private var check = NotesSettings.checkAgainstTranscript
    @State private var showTimes = NotesSettings.showTimes
    @State private var noOwner = NotesSettings.noOwner
    @State private var markNames = NotesSettings.markUnknownNames

    var body: some View {
        PageScaffold(title: "Notes settings", subtitle: "Diduny turns a transcript into a summary, decisions and action items") {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                whoSection
                switch group {
                case .local: LocalModelSection()
                case .subscription: SubscriptionSection()
                case .cloud, .off: EmptyView()
                }
                if group == .local || group == .subscription {
                    TestSection()
                    EarlierRecordingsSection()
                }
                whenSection
                contentsSection
                checkingSection
                Text("The model only reads the transcript and writes text. Claude Code, Codex and Gemini CLI run with their tools, plugins and file access off, in an empty folder.")
                    .font(DS.Font.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Who writes the notes

    private var whoSection: some View {
        SettingsGroup(title: "Who writes the notes") {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                radio(.local, "A model on this Mac", "The transcript stays on this Mac.")
                radio(.subscription, "An AI subscription you already have",
                      "Claude, ChatGPT or Gemini, through their app on this Mac. The transcript is sent to that company under your account.")
                radio(.cloud, "Diduny cloud", "Not available yet.", disabled: true)
                radio(.off, "Nobody", "The Notes block is hidden in recordings.")
            }
            .padding(DS.Space.lg)
        }
        .onChange(of: group) { _, value in NotesSettings.group = value }
    }

    private func radio(_ value: NotesWriterGroup, _ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, disabled: Bool = false) -> some View {
        RadioRow(isOn: group == value, title: title, subtitle: subtitle) { group = value }
            .disabled(disabled)
            .opacity(disabled ? 0.5 : 1)
    }

    // MARK: - When

    private var whenSection: some View {
        SettingsGroup(title: "When") {
            SettingRow(title: "Write notes for a meeting") {
                Picker("Write notes for a meeting", selection: $meetingTiming) {
                    ForEach(NotesMeetingTiming.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            RowSeparator()
            SettingRow(title: "Write notes for a voice note") {
                Picker("Write notes for a voice note", selection: $voiceTiming) {
                    ForEach(NotesVoiceTiming.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            RowSeparator()
            SettingRow(title: "Wait for the power adapter", subtitle: "On battery, notes wait in the queue.") {
                Toggle("Wait for the power adapter", isOn: $waitForPower).labelsHidden().toggleStyle(.switch)
            }
            RowSeparator()
            SettingRow(title: "Tell me when the notes are ready") {
                Toggle("Tell me when the notes are ready", isOn: $notify).labelsHidden().toggleStyle(.switch)
            }
            RowSeparator()
            Text("Writing always stops while you record, and continues afterwards. Automatic notes cover recordings made after you turn them on.")
                .font(DS.Font.callout).foregroundStyle(.secondary)
                .padding(DS.Space.lg)
        }
        .onChange(of: meetingTiming) { _, value in NotesSettings.meetingTiming = value }
        .onChange(of: voiceTiming) { _, value in NotesSettings.voiceTiming = value }
        .onChange(of: waitForPower) { _, value in NotesSettings.waitForPower = value }
        .onChange(of: notify) { _, value in
            NotesSettings.notifyWhenReady = value
            if value { NotesService.requestNotificationPermission() }
        }
    }

    // MARK: - What the notes contain

    private var contentsSection: some View {
        SettingsGroup(title: "What the notes contain") {
            SettingRow(title: "Template", subtitle: "For meetings. You can pick another one for a single recording.") {
                Picker("Template", selection: $template) {
                    ForEach([NotesTemplate.meeting, .oneOnOne, .interview]) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            RowSeparator()
            SettingRow(title: "Sections") {
                HStack(spacing: DS.Space.md) {
                    ForEach(NotesSection.allCases) { section in
                        Toggle(section.label, isOn: Binding(
                            get: { sections.contains(section) },
                            set: { on in if on { sections.insert(section) } else { sections.remove(section) } }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }
            RowSeparator()
            SettingRow(title: "Language of the notes") {
                Picker("Language of the notes", selection: $language) {
                    ForEach(NotesLanguage.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            RowSeparator()
            SettingRow(title: "Length") {
                Picker("Length", selection: $length) {
                    ForEach(NotesLength.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            RowSeparator()
            SettingRow(title: "Use names from the calendar event", subtitle: "Attendee names help the model spell people correctly.") {
                Toggle("Use names from the calendar event", isOn: $useCalendarNames).labelsHidden().toggleStyle(.switch)
            }
            RowSeparator()
            SettingRow(title: "Names and terms", subtitle: "Words the model must spell this way, separated by commas.") {
                TextField("Names and terms", text: $terms).labelsHidden().frame(width: 260)
            }
            RowSeparator()
            promptEditor
        }
        .onChange(of: template) { _, value in
            NotesSettings.meetingTemplate = value
            promptTemplate = value
        }
        .onChange(of: sections) { _, value in NotesSettings.sections = value }
        .onChange(of: language) { _, value in NotesSettings.language = value }
        .onChange(of: length) { _, value in NotesSettings.length = value }
        .onChange(of: terms) { _, value in NotesSettings.terms = value }
        .onChange(of: useCalendarNames) { _, value in NotesSettings.useCalendarNames = value }
    }

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Instructions for the model").font(DS.Font.body)
                    Text(NotesSettings.customPrompt(for: promptTemplate) != nil
                        ? "Changed by you. Test it on a recording before you rely on it."
                        : "Default for the \(promptTemplate.label) template. Language, people and terms are filled in from the rows above.")
                        .font(DS.Font.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Template", selection: $promptTemplate) {
                    ForEach(NotesTemplate.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            TextEditor(text: $prompt)
                .font(DS.Font.body)
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(DS.Space.xs)
                .background(DS.Palette.cardFill)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.Palette.cardBorder))
            HStack {
                Button("Restore the default") {
                    NotesSettings.setCustomPrompt(nil, for: promptTemplate)
                    prompt = promptTemplate.defaultPrompt
                }
                .disabled(NotesSettings.customPrompt(for: promptTemplate) == nil)
                Spacer()
            }
        }
        .padding(DS.Space.lg)
        .onChange(of: promptTemplate) { _, value in prompt = NotesSettings.prompt(for: value) }
        .onChange(of: prompt) { _, value in
            NotesSettings.setCustomPrompt(value == promptTemplate.defaultPrompt ? nil : value, for: promptTemplate)
        }
    }

    // MARK: - Checking the notes

    private var checkingSection: some View {
        SettingsGroup(title: "Checking the notes") {
            SettingRow(title: "Check decisions and action items against the transcript",
                       subtitle: "After writing, the model reads each item again with the transcript. Items the transcript does not support are removed and listed under the notes. Takes longer.") {
                Toggle("Check against the transcript", isOn: $check).labelsHidden().toggleStyle(.switch)
            }
            RowSeparator()
            SettingRow(title: "Show where each item was said",
                       subtitle: "A time next to the item plays the recording from that place.") {
                Toggle("Show where each item was said", isOn: $showTimes).labelsHidden().toggleStyle(.switch)
            }
            RowSeparator()
            SettingRow(title: "When nobody was named for a task") {
                Picker("When nobody was named for a task", selection: $noOwner) {
                    ForEach(NotesNoOwner.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            RowSeparator()
            SettingRow(title: "Mark names that are not in the calendar event or the terms",
                       subtitle: "They are often misheard words.") {
                Toggle("Mark unknown names", isOn: $markNames).labelsHidden().toggleStyle(.switch)
            }
        }
        .onChange(of: check) { _, value in NotesSettings.checkAgainstTranscript = value }
        .onChange(of: showTimes) { _, value in NotesSettings.showTimes = value }
        .onChange(of: noOwner) { _, value in NotesSettings.noOwner = value }
        .onChange(of: markNames) { _, value in NotesSettings.markUnknownNames = value }
    }
}

/// A radio button with a title and an explanation under it.
private struct RadioRow: View {
    let isOn: Bool
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isOn ? DS.Palette.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(DS.Font.body)
                    Text(subtitle).font(DS.Font.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

// MARK: - Model on this Mac

private struct LocalModelSection: View {
    @State private var server = NotesSettings.localServer
    @State private var address = ""
    @State private var model = ""
    @State private var models: [LocalServerWriter.Model] = []
    @State private var running: Bool?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            SettingsGroup(title: "Model on this Mac") {
                SettingRow(title: "Server") {
                    Picker("Server", selection: $server) {
                        ForEach(NotesWriterKind.localServers) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                if server == .openAICompatible {
                    RowSeparator()
                    SettingRow(title: "Address") {
                        TextField("Address", text: $address).labelsHidden().frame(width: 240)
                            .onSubmit { NotesSettings.setAddress(address, for: server); Task { await refresh() } }
                    }
                }
                RowSeparator()
                statusRow
                if running == true, !models.isEmpty {
                    RowSeparator()
                    SettingRow(title: "Model", subtitle: memoryNote) {
                        Picker("Model", selection: $model) {
                            ForEach(models, id: \.name) { Text(Self.label($0)).tag($0.name) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
            }
            Text("A long meeting is read in parts, so its length has no limit. Models smaller than 4B often miss names and decisions.")
                .font(DS.Font.callout).foregroundStyle(.secondary)
        }
        .task(id: server) { await refresh() }
        .onChange(of: server) { _, value in NotesSettings.localServer = value }
        .onChange(of: model) { _, value in NotesSettings.setModel(value, for: server) }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(alignment: .center, spacing: DS.Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                switch running {
                case nil:
                    Text("Checking...").font(DS.Font.body).foregroundStyle(.secondary)
                case true?:
                    Text("Running").font(DS.Font.body).foregroundStyle(.green)
                    Text(models.isEmpty ? "No models that can write notes. Download one in \(server.label)." : "\(models.count) models that can write notes")
                        .font(DS.Font.callout).foregroundStyle(.secondary)
                case false?:
                    Text("\(server.label) is not running on this Mac").font(DS.Font.body).foregroundStyle(.red)
                    Text("Open \(server.label), or install it and download a model. Diduny does not download the model itself.")
                        .font(DS.Font.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.lg)
            if running == false, let page = server.downloadPage {
                Button("Open \(page.host ?? "")") { NSWorkspace.shared.open(page) }
            }
            Button("Check again") { Task { await refresh() } }.disabled(checking)
        }
        .padding(.vertical, DS.Space.md)
        .padding(.horizontal, DS.Space.lg)
    }

    private var memoryNote: LocalizedStringKey? {
        guard let size = models.first(where: { $0.name == model })?.size else { return nil }
        let ram = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        let uses = max(1, Int((Double(size) / 1_000_000_000).rounded()))
        return "Uses about \(uses) GB of memory while it writes. This Mac has \(ram) GB."
    }

    private static func label(_ model: LocalServerWriter.Model) -> String {
        guard let size = model.size else { return model.name }
        return "\(model.name), \(String(format: "%.1f", Double(size) / 1_000_000_000)) GB"
    }

    private func refresh() async {
        checking = true
        defer { checking = false }
        address = NotesSettings.address(for: server)
        model = NotesSettings.model(for: server)
        do {
            models = try await LocalServerWriter.models(kind: server, address: address)
            running = true
            if !models.contains(where: { $0.name == model }), let first = models.first { model = first.name }
        } catch {
            models = []
            running = false
        }
    }
}

// MARK: - Your subscription

/// One radio list: the chosen tool's own settings open under it.
private struct SubscriptionSection: View {
    @State private var tool = NotesSettings.subscriptionTool
    @State private var refresh = 0

    var body: some View {
        SettingsGroup(title: "Your subscription") {
            ForEach([NotesWriterKind.claudeCode, .codex, .gemini], id: \.self) { kind in
                CLIToolRow(kind: kind, selected: $tool)
                RowSeparator()
            }
            APIKeyRows(selected: $tool)
            RowSeparator()
            HStack(spacing: DS.Space.lg) {
                Text("Diduny finds these apps on this Mac and never sees your password. It uses one only after you allow it.")
                    .font(DS.Font.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.lg)
                Button("Look again") { refresh += 1 }
            }
            .padding(.vertical, DS.Space.md)
            .padding(.horizontal, DS.Space.lg)
        }
        .id(refresh)
        .onChange(of: tool) { _, value in NotesSettings.subscriptionTool = value }
    }
}

/// Settings that open under the chosen tool, indented to its title.
private struct ToolDetail<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) { content() }
            .padding(.leading, DS.Space.lg + 16 + DS.Space.md)
            .padding(.trailing, DS.Space.lg)
            .padding(.bottom, DS.Space.md)
    }
}

private struct DetailLine<Control: View>: View {
    let label: LocalizedStringKey
    var note: LocalizedStringKey?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Text(label).font(DS.Font.callout).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            control()
            if let note { Text(note).font(DS.Font.callout).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
    }
}

private struct ModelTierPicker: View {
    let kind: NotesWriterKind
    @State private var tier: NotesModelTier = .standard

    var body: some View {
        Picker("Model", selection: $tier) {
            ForEach(NotesModelTier.allCases) { Text(Self.label($0, kind)).tag($0) }
        }
        .labelsHidden().fixedSize()
        .task(id: kind) { tier = NotesSettings.tier(for: kind) }
        .onChange(of: tier) { _, value in NotesSettings.setTier(value, for: kind) }
    }

    static func label(_ tier: NotesModelTier, _ kind: NotesWriterKind) -> String {
        if kind == .codex {
            switch tier {
            case .standard: return String(localized: "Your Codex default")
            case .faster: return String(localized: "Faster, thinks less")
            case .capable: return String(localized: "Thinks more, slower")
            }
        }
        switch tier {
        case .standard: return String(localized: "Sonnet, default")
        case .faster: return String(localized: "Haiku, faster and cheaper")
        case .capable: return String(localized: "Opus, most capable")
        }
    }
}

private struct CLIToolRow: View {
    let kind: NotesWriterKind
    @Binding var selected: NotesWriterKind
    @State private var path: String?
    @State private var version: String?
    @State private var searched = false
    @State private var approvedPath = ""
    @State private var askingApproval = false

    private var isApproved: Bool { path != nil && approvedPath == path }
    private var isSelected: Bool { selected == kind && isApproved }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: DS.Space.md) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? DS.Palette.accent : .secondary)
                    .opacity(isApproved ? 1 : 0.4)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.label).font(DS.Font.body)
                    Text(status).font(DS.Font.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Space.lg)
                if !searched {
                    ProgressView().controlSize(.small)
                } else if path == nil {
                    Button("Choose its location...") { chooseLocation() }
                } else if isApproved {
                    Button("Take back") {
                        NotesSettings.revokeApproval(kind)
                        approvedPath = ""
                    }
                } else {
                    Button("Allow...") { askingApproval = true }
                }
            }
            .padding(.vertical, DS.Space.md)
            .padding(.horizontal, DS.Space.lg)
            .contentShape(Rectangle())
            .onTapGesture { if isApproved { selected = kind } }
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            if isSelected, kind != .gemini {
                ToolDetail {
                    DetailLine(label: "Model", note: "Counts toward your \(kind.label) plan.") { ModelTierPicker(kind: kind) }
                }
            }
        }
        .task { await locate() }
        .alert("Allow \(kind.label) to write notes?", isPresented: $askingApproval) {
            Button("Allow") {
                guard let path else { return }
                NotesSettings.approve(kind, path: path)
                approvedPath = path
                selected = kind
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(approvalMessage)
        }
    }

    private var approvalMessage: String {
        let lockdown = kind == .gemini
            ? String(localized: "Diduny turns off its tools, extensions and MCP servers for these runs, whatever your Gemini settings say, and runs it in an empty folder.")
            : String(localized: "Diduny turns off the tool's tools, plugins and file access for these runs.")
        return String(localized: "The transcript of each recording you write notes for goes to \(kind.label).")
            + "\n" + String(localized: "\(kind.label) sends it to \(kind.vendor) under your account, and it counts toward your plan.")
            + "\n" + lockdown
    }

    private var status: String {
        guard searched else { return String(localized: "Looking for it...") }
        guard path != nil else { return String(localized: "Not found on this Mac.") }
        let found = version.map { String(localized: "Found, version \(Self.shortVersion($0)).") } ?? String(localized: "Found.")
        if isApproved, let date = NotesSettings.approvalDate(for: kind) {
            return found + " " + String(localized: "Allowed on \(date.formatted(.dateTime.day().month()))."
            )
        }
        return found + " " + String(localized: "Not allowed yet.")
    }

    /// "2.1.319 (Claude Code)" or "codex-cli 0.166.0" to "2.1.319" / "0.166.0".
    static func shortVersion(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "(" })
            .first { $0.first?.isNumber == true }.map(String.init) ?? text
    }

    private func locate() async {
        approvedPath = NotesSettings.approvedPath(for: kind) ?? ""
        path = await CLIRunner.locate(kind)
        if let path { version = await CLIRunner.version(path) }
        searched = true
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose the \(kind.executableName ?? "") program")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        NotesSettings.setCustomExecutablePath(url.path, for: kind)
        searched = false
        Task { await locate() }
    }
}

private struct APIKeyRows: View {
    @Binding var selected: NotesWriterKind
    @State private var provider = NotesSettings.apiProvider
    @State private var key = ""
    @State private var hasKey = NotesSettings.apiKey != nil
    @State private var address = NotesSettings.apiAddress
    @State private var model = NotesSettings.model(for: .apiKey)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: DS.Space.md) {
                Image(systemName: selected == .apiKey ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected == .apiKey ? DS.Palette.accent : .secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("API key").font(DS.Font.body)
                    Text("Paid per use, not by a plan.").font(DS.Font.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.Space.lg)
            }
            .padding(.vertical, DS.Space.md)
            .padding(.horizontal, DS.Space.lg)
            .contentShape(Rectangle())
            .onTapGesture { selected = .apiKey }
            .accessibilityAddTraits(selected == .apiKey ? [.isSelected] : [])
            if selected == .apiKey {
                ToolDetail {
                    DetailLine(label: "Service") {
                        Picker("Service", selection: $provider) {
                            ForEach(NotesAPIProvider.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    if provider == .other {
                        DetailLine(label: "Address") {
                            TextField("Address", text: $address, prompt: Text("https://...")).labelsHidden().frame(width: 240)
                        }
                    }
                    DetailLine(label: "Key", note: hasKey ? "Saved in the Keychain." : "Kept in the Keychain.") {
                        SecureField("Key", text: $key, prompt: Text(hasKey ? "Saved" : "Paste the key"))
                            .labelsHidden().frame(width: 220)
                            .onSubmit(saveKey)
                        if hasKey {
                            Button("Remove") {
                                NotesSettings.apiKey = nil
                                hasKey = false
                            }
                        } else {
                            Button("Save", action: saveKey).disabled(key.isEmpty)
                        }
                    }
                    DetailLine(label: "Model") {
                        if provider == .anthropic {
                            ModelTierPicker(kind: .apiKey)
                        } else {
                            TextField("Model name", text: $model, prompt: Text("Model name")).labelsHidden().frame(width: 200)
                        }
                    }
                }
            }
        }
        .onChange(of: provider) { _, value in NotesSettings.apiProvider = value }
        .onChange(of: address) { _, value in NotesSettings.apiAddress = value }
        .onChange(of: model) { _, value in NotesSettings.setModel(value, for: .apiKey) }
    }

    private func saveKey() {
        guard !key.isEmpty else { return }
        NotesSettings.apiKey = key
        key = ""
        hasKey = true
    }
}

// MARK: - Test

/// Runs the chosen writer on one recording; the notes are saved to that recording.
private struct TestSection: View {
    @State private var library = RecordingsLibraryStorage.shared
    @State private var service = NotesService.shared
    @State private var recordingID: UUID?

    private var kind: NotesWriterKind { NotesSettings.writer }

    private var candidates: [Recording] {
        Array(library.recordings.filter(NotesTranscript.hasTranscript).sorted { $0.createdAt > $1.createdAt }.prefix(30))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            SettingsGroup(title: "Test") {
                HStack(alignment: .center, spacing: DS.Space.lg) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Write test notes for one recording").font(DS.Font.body)
                        status
                    }
                    Spacer(minLength: DS.Space.lg)
                    if let recordingID, service.isBusy(recordingID) {
                        Button("Cancel") { service.cancel(recordingID) }
                    } else {
                        Button("Write test notes") { if let recordingID { service.write(recordingID, kind: kind) } }
                            .disabled(recordingID == nil || kind == .off)
                    }
                }
                .padding(.vertical, DS.Space.md)
                .padding(.horizontal, DS.Space.lg)
                RowSeparator()
                SettingRow(title: "Recording") {
                    Picker("Recording", selection: $recordingID) {
                        ForEach(candidates) { Text(Self.label($0)).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 380)
                }
            }
            Text("The test saves the notes to that recording, so you can open and read them.")
                .font(DS.Font.callout).foregroundStyle(.secondary)
        }
        .onAppear { if recordingID == nil { recordingID = candidates.first?.id } }
    }

    static func label(_ recording: Recording) -> String {
        let date = recording.createdAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "\(recording.displayTitle), \(date), \(max(1, Int(recording.effectiveDurationSeconds / 60))) min"
    }

    @ViewBuilder
    private var status: some View {
        let state = recordingID.flatMap { service.states[$0] }
        switch state {
        case .waiting?:
            line(service.waitingDescription(recordingID!) ?? String(localized: "Waiting."))
        case let .writing(part, total)?:
            line(total > 1 ? String(localized: "Writing, part \(part) of \(total).") : String(localized: "Writing."))
        case .checking?:
            line(String(localized: "Checking against the transcript."))
        case let .failed(message)?:
            Text(message).font(DS.Font.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        case nil:
            if let run = NotesSettings.lastRun(for: kind), let id = run.recordingID {
                HStack(spacing: DS.Space.xs) {
                    line(String(localized: "Written in \(Self.duration(run.seconds)) with \(run.writer) for a \(run.recordingMinutes) min recording."))
                    Button("Open the notes") { MainWindowController.shared.showRecording(id: id) }
                        .buttonStyle(.link).font(DS.Font.callout)
                }
            } else {
                line(String(localized: "Not run yet with \(kind.label)."))
            }
        }
    }

    private func line(_ text: String) -> some View {
        Text(text).font(DS.Font.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    static func duration(_ seconds: Int) -> String {
        if seconds >= 3600 { return "\(seconds / 3600) h \(seconds % 3600 / 60) min" }
        return seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(seconds) s"
    }
}

// MARK: - Earlier recordings

private struct EarlierRecordingsSection: View {
    enum Range: String, CaseIterable, Identifiable {
        case days30, days90, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .days30: String(localized: "Last 30 days")
            case .days90: String(localized: "Last 90 days")
            case .all: String(localized: "All time")
            }
        }
        var since: Date? {
            switch self {
            case .days30: Calendar.current.date(byAdding: .day, value: -30, to: Date())
            case .days90: Calendar.current.date(byAdding: .day, value: -90, to: Date())
            case .all: nil
            }
        }
    }

    @State private var service = NotesService.shared
    @State private var store = NotesStore.shared
    @State private var library = RecordingsLibraryStorage.shared
    @State private var meetingsOnly = true
    @State private var range: Range = .all
    @State private var oldestFirst = false
    @State private var confirming = false
    @State private var showFailed = false

    private var kind: NotesWriterKind { NotesSettings.writer }

    private var selection: [Recording] {
        let rows = service.recordingsWithoutNotes(meetingsOnly: meetingsOnly, since: range.since)
        return oldestFirst ? rows.reversed() : rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            SettingsGroup(title: "Earlier recordings") {
                if let state = service.backfill {
                    progress(state)
                } else {
                    setup
                }
            }
            Text("New notes appear in Notes as they are written. Recordings that already have notes are left as they are.")
                .font(DS.Font.callout).foregroundStyle(.secondary)
        }
        .alert(confirmTitle, isPresented: $confirming) {
            Button("Start") { service.startBackfill(selection.map(\.id)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    @ViewBuilder
    private var setup: some View {
        let meetings = service.recordingsWithoutNotes(meetingsOnly: true, since: nil).count
        let all = service.recordingsWithoutNotes(meetingsOnly: false, since: nil).count
        SettingRow(title: "\(meetings) meetings and \(all - meetings) voice notes have no notes") { EmptyView() }
        RowSeparator()
        SettingRow(title: "Which recordings") {
            Picker("Which recordings", selection: $meetingsOnly) {
                Text("Meetings, \(meetings)").tag(true)
                Text("Meetings and voice notes, \(all)").tag(false)
            }
            .labelsHidden().fixedSize()
        }
        RowSeparator()
        SettingRow(title: "From") {
            Picker("From", selection: $range) {
                ForEach(Range.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().fixedSize()
        }
        RowSeparator()
        SettingRow(title: "Order") {
            Picker("Order", selection: $oldestFirst) {
                Text("Newest first").tag(false)
                Text("Oldest first").tag(true)
            }
            .labelsHidden().fixedSize()
        }
        RowSeparator()
        HStack(spacing: DS.Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("How long it takes").font(DS.Font.body)
                Text(estimate).font(DS.Font.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.lg)
            Button("Write notes for \(selection.count) recordings") { confirming = true }
                .buttonStyle(.borderedProminent)
                .tint(DS.Palette.accent)
                .disabled(selection.isEmpty || kind == .off)
        }
        .padding(.vertical, DS.Space.md)
        .padding(.horizontal, DS.Space.lg)
    }

    private var totalMinutes: Double {
        selection.reduce(0) { $0 + $1.effectiveDurationSeconds } / 60
    }

    private var estimate: String {
        guard let rate = NotesSettings.secondsPerMinute(for: kind) else {
            return String(localized: "Run a test first to see an estimate. Writing stops while you record.")
        }
        let seconds = Int(rate * totalMinutes)
        return String(localized: "About \(TestSection.duration(seconds)), based on your last test. Writing stops while you record.")
    }

    private var confirmTitle: String {
        String(localized: "Write notes for \(selection.count) earlier recordings?")
    }

    private var confirmMessage: String {
        let whereText: String
        switch kind {
        case .ollama, .lmStudio, .openAICompatible:
            whereText = String(localized: "The transcripts stay on this Mac. The Mac is slow while a note is written, so notes are written only when it is idle and, if you chose so, on the power adapter.")
        case .apiKey:
            whereText = String(localized: "Each transcript goes to \(NotesSettings.apiProvider.label) with your key and is paid per use.")
        default:
            whereText = String(localized: "Each transcript goes to \(kind.vendor) under your account and counts toward your \(kind.label) plan. After 3 failures in a row, for example at the plan limit, writing pauses.")
        }
        return whereText + "\n\n" + estimate + "\n\n"
            + String(localized: "You can pause or stop at any time. Notes already written stay.")
    }

    @ViewBuilder
    private func progress(_ state: NotesService.Backfill) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                Text(title(state)).font(DS.Font.body).monospacedDigit()
                Spacer()
                Text(timeLeft(state)).font(DS.Font.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: Double(state.done), total: Double(max(state.total, 1)))
                .tint(DS.Palette.accent)
            Text(detail(state)).font(DS.Font.callout).foregroundStyle(state.pauseReason == nil ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.lg)
        RowSeparator()
        HStack(spacing: DS.Space.sm) {
            if !state.failed.isEmpty {
                Text("\(state.failed.count) failed.").font(DS.Font.callout).foregroundStyle(.secondary)
                Button(showFailed ? "Hide" : "Show") { showFailed.toggle() }.buttonStyle(.link).font(DS.Font.callout)
            }
            Spacer()
            if state.isFinished {
                if !state.failed.isEmpty { Button("Try the failed ones again") { service.retryFailedBackfill() } }
                Button("Done") { service.clearFinishedBackfill() }
            } else {
                Button(state.paused ? "Continue" : "Pause") {
                    if state.paused { service.resumeBackfill() } else { service.pauseBackfill() }
                }
                Button("Stop") { service.stopBackfill() }
            }
        }
        .padding(.vertical, DS.Space.md)
        .padding(.horizontal, DS.Space.lg)
        if showFailed, !state.failed.isEmpty {
            RowSeparator()
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(Array(state.failed.keys), id: \.self) { id in
                    let title = library.recordings.first { $0.id == id }?.displayTitle ?? String(localized: "Deleted recording")
                    Text("\(title): \(state.failed[id] ?? "")").font(DS.Font.callout).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(DS.Space.lg)
        }
    }

    private func title(_ state: NotesService.Backfill) -> String {
        if state.isFinished { return String(localized: "\(state.written) of \(state.total) written") }
        if state.paused { return String(localized: "Paused, \(state.written) of \(state.total) written") }
        return String(localized: "\(state.written) of \(state.total) written")
    }

    private func timeLeft(_ state: NotesService.Backfill) -> String {
        if let end = state.finishedAt { return String(localized: "Finished \(end.formatted(date: .omitted, time: .shortened))") }
        let left = state.total - state.done
        guard !state.paused, state.done > 0 else { return String(localized: "\(left) left") }
        let perItem = Date().timeIntervalSince(state.startedAt) / Double(state.done)
        return String(localized: "About \(TestSection.duration(Int(perItem * Double(left)))) left")
    }

    private func detail(_ state: NotesService.Backfill) -> String {
        if let reason = state.pauseReason { return reason }
        if state.isFinished { return String(localized: "Open Notes to read them.") }
        if state.paused { return String(localized: "Paused by you. Nothing is sent until you continue.") }
        if let current = state.currentTitle { return String(localized: "Now: \(current). Waits while you record.") }
        return String(localized: "Waiting to start. Writing stops while you record.")
    }
}
