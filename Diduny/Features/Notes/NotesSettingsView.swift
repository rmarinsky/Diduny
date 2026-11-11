import AppKit
import SwiftUI

struct NotesSettingsView: View {
    @State private var writer = NotesSettings.writer
    @State private var meetingTiming = NotesSettings.meetingTiming
    @State private var voiceTiming = NotesSettings.voiceTiming
    @State private var language = NotesSettings.language
    @State private var terms = NotesSettings.terms
    @State private var useCalendarNames = NotesSettings.useCalendarNames
    @State private var template: NotesTemplate = .meeting
    @State private var prompt = NotesSettings.prompt(for: .meeting)

    var body: some View {
        PageScaffold(title: "Notes settings") {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                SettingsGroup(title: "Who writes the notes") {
                    SettingRow(title: "Writer",
                               subtitle: "A model on this Mac keeps the transcript here. A subscription tool sends it to its vendor under your account.") {
                        Picker("Writer", selection: $writer) {
                            ForEach(NotesWriterKind.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }
                }
                .onChange(of: writer) { _, value in NotesSettings.writer = value }

                LocalServerSection(kind: .ollama)
                LocalServerSection(kind: .lmStudio)
                SubscriptionToolSection(kind: .claudeCode, writer: $writer)
                SubscriptionToolSection(kind: .codex, writer: $writer)

                SettingsGroup(title: "When") {
                    SettingRow(title: "Meetings") { timingPicker($meetingTiming) }
                    RowSeparator()
                    SettingRow(title: "Voice notes") { timingPicker($voiceTiming) }
                    RowSeparator()
                    Text("Automatic notes cover recordings made after you turn them on. Notes never start while you record.")
                        .font(DS.Font.callout)
                        .foregroundStyle(.secondary)
                        .padding(DS.Space.lg)
                }
                .onChange(of: meetingTiming) { _, value in NotesSettings.meetingTiming = value }
                .onChange(of: voiceTiming) { _, value in NotesSettings.voiceTiming = value }

                SettingsGroup(title: "What the notes contain") {
                    SettingRow(title: "Language", subtitle: "Empty: the language of the recording.") {
                        TextField("Language", text: $language, prompt: Text("Same as the recording"))
                            .labelsHidden()
                            .frame(width: 200)
                    }
                    RowSeparator()
                    SettingRow(title: "Names from the calendar event",
                               subtitle: "The model spells people's names the way the invitation does.") {
                        Toggle("Names from the calendar event", isOn: $useCalendarNames).labelsHidden().toggleStyle(.switch)
                    }
                    RowSeparator()
                    SettingRow(title: "Names and terms", subtitle: "Separated by commas, e.g. product names.") {
                        TextField("Names and terms", text: $terms).labelsHidden().frame(width: 240)
                    }
                }
                .onChange(of: language) { _, value in NotesSettings.language = value }
                .onChange(of: terms) { _, value in NotesSettings.terms = value }
                .onChange(of: useCalendarNames) { _, value in NotesSettings.useCalendarNames = value }

                promptSection
            }
        }
    }

    private func timingPicker(_ selection: Binding<NotesTiming>) -> some View {
        Picker("When", selection: selection) {
            ForEach(NotesTiming.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden()
        .frame(width: 260)
    }

    private var promptSection: some View {
        SettingsGroup(title: "Instructions for the model") {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Picker("Template", selection: $template) {
                    ForEach(NotesTemplate.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                TextEditor(text: $prompt)
                    .font(DS.Font.body)
                    .frame(minHeight: 220)
                    .scrollContentBackground(.hidden)
                    .padding(DS.Space.xs)
                    .background(DS.Palette.cardFill)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.Palette.cardBorder))
                HStack {
                    if NotesSettings.customPrompt(for: template) != nil {
                        Text("Changed by you. Test it on a recording before you rely on it.")
                            .font(DS.Font.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("{language}, {people} and {terms} are filled in from the rows above.")
                            .font(DS.Font.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore the default") {
                        NotesSettings.setCustomPrompt(nil, for: template)
                        prompt = template.defaultPrompt
                    }
                    .disabled(NotesSettings.customPrompt(for: template) == nil)
                }
            }
            .padding(DS.Space.lg)
        }
        .onChange(of: template) { _, value in prompt = NotesSettings.prompt(for: value) }
        .onChange(of: prompt) { _, value in
            NotesSettings.setCustomPrompt(value == template.defaultPrompt ? nil : value, for: template)
        }
    }
}

/// Address, status and model of Ollama or LM Studio.
private struct LocalServerSection: View {
    let kind: NotesWriterKind
    @State private var address = ""
    @State private var model = ""
    @State private var models: [String] = []
    @State private var status: String?
    @State private var checking = false

    var body: some View {
        SettingsGroup(title: LocalizedStringKey(kind.label)) {
            SettingRow(title: "Address") {
                TextField("Address", text: $address).labelsHidden().frame(width: 220)
                    .onSubmit { NotesSettings.setAddress(address, for: kind); Task { await check() } }
            }
            RowSeparator()
            SettingRow(title: "Status") {
                HStack(spacing: DS.Space.sm) {
                    Text(status ?? String(localized: "Checking..."))
                        .font(DS.Font.callout)
                        .foregroundStyle(models.isEmpty && status != nil ? Color.red : Color.secondary)
                    Button("Check again") { Task { await check() } }.disabled(checking)
                }
            }
            if !models.isEmpty {
                RowSeparator()
                SettingRow(title: "Model", subtitle: "Bigger models write better notes and need more memory.") {
                    Picker("Model", selection: $model) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
        }
        .task {
            address = NotesSettings.address(for: kind)
            model = NotesSettings.model(for: kind)
            await check()
        }
        .onChange(of: model) { _, value in NotesSettings.setModel(value, for: kind) }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        do {
            models = try await LocalServerWriter.models(kind: kind, address: address)
            status = models.isEmpty
                ? String(localized: "Running, no models downloaded")
                : String(localized: "Running")
            if !models.contains(model), let first = models.first { model = first }
        } catch {
            models = []
            status = String(localized: "Not running. Install \(kind.label) and start it.")
        }
    }
}

/// Claude Code or Codex: found on this Mac, allowed by the user, model alias.
private struct SubscriptionToolSection: View {
    let kind: NotesWriterKind
    @Binding var writer: NotesWriterKind
    @State private var path: String?
    @State private var version: String?
    @State private var searched = false
    @State private var model = ""
    @State private var askingApproval = false
    @State private var approvedPath = ""

    private var isApproved: Bool { path != nil && approvedPath == path }

    var body: some View {
        SettingsGroup(title: LocalizedStringKey(kind.label)) {
            SettingRow(title: "On this Mac", subtitle: subtitle) {
                HStack(spacing: DS.Space.sm) {
                    if path == nil {
                        Button("Choose its location...") { chooseLocation() }
                    } else if isApproved {
                        Button("Take back") {
                            NotesSettings.revokeApproval(kind)
                            approvedPath = ""
                            if writer == kind { writer = .off }
                        }
                    } else {
                        Button("Allow...") { askingApproval = true }
                    }
                }
            }
            if isApproved {
                RowSeparator()
                SettingRow(title: "Model", subtitle: "Empty uses the tool's default.") {
                    TextField("Model", text: $model, prompt: Text(kind == .claudeCode ? "sonnet" : "default"))
                        .labelsHidden()
                        .frame(width: 160)
                }
            }
        }
        .task { await locate() }
        .onChange(of: model) { _, value in NotesSettings.setModel(value, for: kind) }
        .alert("Allow \(kind.label) to write notes?", isPresented: $askingApproval) {
            Button("Allow") {
                guard let path else { return }
                NotesSettings.approve(kind, path: path)
                approvedPath = path
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            The transcript of each recording you write notes for goes to \(kind.label).
            \(kind.label) sends it to \(kind.vendor) under your account, and it counts toward your plan.
            Diduny turns off the tool's tools, plugins and file access for these runs.
            """)
        }
    }

    private var subtitle: LocalizedStringKey {
        guard searched else { return "Looking for it..." }
        guard let path else { return "Not found. Install it, or choose where it is." }
        let found = version.map { "\($0), \(path)" } ?? path
        if isApproved, let date = NotesSettings.approvalDate(for: kind) {
            return "\(found). Allowed on \(date.formatted(date: .abbreviated, time: .omitted))."
        }
        return "\(found). Not allowed yet."
    }

    private func locate() async {
        model = NotesSettings.model(for: kind)
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
        Task { await locate() }
    }
}
