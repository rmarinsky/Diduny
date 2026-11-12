import SwiftUI

/// Project, tags, people and speaker names of one recording. Each field saves when you press
/// Return or leave it. Agents can set the project, tags and people when the user asks; speaker
/// names are set only here.
struct RecordingOrganizeSection: View {
    let recording: Recording
    @State private var storage = RecordingsLibraryStorage.shared
    @State private var project = ""
    @State private var tags = ""
    @State private var people = ""
    @State private var speakers: [String: String] = [:]
    @State private var saveFailed = false
    /// Fields typed in and not saved yet. Only these are saved, and only the others follow changes
    /// made elsewhere (an agent), so leaving a field never writes an old value over a newer one.
    @State private var edited: Set<String> = []

    private var stored: Recording { storage.recordings.first { $0.id == recording.id } ?? recording }

    /// What the fields show, from the stored recording.
    private struct Values: Equatable {
        var project = "", tags = "", people = ""
        var speakers: [String: String] = [:]
    }

    private var storedValues: Values {
        Values(project: stored.project ?? "", tags: (stored.tags ?? []).joined(separator: ", "),
               people: (stored.people ?? []).joined(separator: ", "), speakers: stored.speakerNames ?? [:])
    }

    /// Speaker labels the recognizer used, in order of first appearance.
    static func speakerLabels(_ recording: Recording) -> [String] {
        var seen = Set<String>()
        return (recording.transcriptSegments ?? []).compactMap(\.speakerLabel).filter { seen.insert($0).inserted }
    }

    static func list(_ text: String) -> [String] {
        text.split(separator: ",").map(String.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("Project and people").font(DS.Font.headline)
            Grid(alignment: .leading, horizontalSpacing: DS.Space.sm, verticalSpacing: DS.Space.xs) {
                row(Text("Project"), field: "project", text: $project, prompt: "None") { $0.project = project }
                row(Text("Tags"), field: "tags", text: $tags, prompt: "Comma-separated") { $0.tags = Self.list(tags) }
                row(Text("People"), field: "people", text: $people, prompt: "Comma-separated") { $0.people = Self.list(people) }
                ForEach(Self.speakerLabels(recording), id: \.self) { label in
                    row(Text(verbatim: label), field: "speaker:" + label, text: Binding(
                        get: { speakers[label] ?? "" },
                        set: { speakers[label] = $0 }
                    ), prompt: "Name") { $0.speakerNames = ($0.speakerNames ?? [:]).merging([label: speakers[label] ?? ""]) { $1 } }
                }
            }
            if saveFailed {
                Text("Diduny could not save the change.").font(DS.Font.callout).foregroundStyle(.red)
            }
        }
        .onAppear { edited = []; load() }
        .onChange(of: recording.id) { edited = []; load() }
        .onChange(of: storedValues) { load() }
    }

    private func row(_ title: Text, field: String, text: Binding<String>, prompt: LocalizedStringKey,
                     save: @escaping (inout Recording) -> Void) -> some View {
        GridRow {
            title.font(DS.Font.callout).foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            TextField(text: text, prompt: Text(prompt)) { title }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(maxWidth: 320)
                .onSubmit { commit(field, save) }
                .onChange(of: text.wrappedValue) { _, value in
                    saveFailed = false
                    // Typing or pasting makes the field edited; `load()` setting the stored value does not.
                    if value != storedText(field) { edited.insert(field) } else { edited.remove(field) }
                }
                .focusedValueLostCommit { commit(field, save) }
        }
    }

    private func commit(_ field: String, _ change: (inout Recording) -> Void) {
        guard edited.contains(field) else { return }
        saveFailed = !storage.updateOrganization(id: recording.id, change)
        if !saveFailed {
            edited.remove(field)
            load()
        }
    }

    private func storedText(_ field: String) -> String {
        let values = storedValues
        switch field {
        case "project": return values.project
        case "tags": return values.tags
        case "people": return values.people
        default: return values.speakers[String(field.dropFirst("speaker:".count))] ?? ""
        }
    }

    /// Shows the stored values in every field not being edited.
    private func load() {
        let values = storedValues
        if !edited.contains("project") { project = values.project }
        if !edited.contains("tags") { tags = values.tags }
        if !edited.contains("people") { people = values.people }
        for label in Set(Self.speakerLabels(recording)).union(values.speakers.keys) where !edited.contains("speaker:" + label) {
            speakers[label] = values.speakers[label]
        }
    }
}

private struct FocusLossCommit: ViewModifier {
    let action: () -> Void
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content.focused($focused).onChange(of: focused) { _, isFocused in
            if !isFocused { action() }
        }
    }
}

private extension View {
    func focusedValueLostCommit(_ action: @escaping () -> Void) -> some View {
        modifier(FocusLossCommit(action: action))
    }
}
