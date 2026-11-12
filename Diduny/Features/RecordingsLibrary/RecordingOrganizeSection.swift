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
                row(Text("Project"), text: $project, prompt: "None") { $0.project = project }
                row(Text("Tags"), text: $tags, prompt: "Comma-separated") { $0.tags = Self.list(tags) }
                row(Text("People"), text: $people, prompt: "Comma-separated") { $0.people = Self.list(people) }
                ForEach(Self.speakerLabels(recording), id: \.self) { label in
                    row(Text(verbatim: label), text: Binding(
                        get: { speakers[label] ?? "" },
                        set: { speakers[label] = $0 }
                    ), prompt: "Name") { $0.speakerNames = speakers }
                }
            }
            if saveFailed {
                Text("Diduny could not save the change.").font(DS.Font.callout).foregroundStyle(.red)
            }
        }
        .onAppear(perform: load)
        .onChange(of: recording.id) { load() }
    }

    private func row(_ title: Text, text: Binding<String>, prompt: LocalizedStringKey,
                     save: @escaping (inout Recording) -> Void) -> some View {
        GridRow {
            title.font(DS.Font.callout).foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            TextField(text: text, prompt: Text(prompt)) { title }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(maxWidth: 320)
                .onSubmit { commit(save) }
                .onChange(of: text.wrappedValue) { _, _ in saveFailed = false }
                .focusedValueLostCommit { commit(save) }
        }
    }

    private func commit(_ change: (inout Recording) -> Void) {
        saveFailed = !storage.updateOrganization(id: recording.id, change)
        if !saveFailed { load() }
    }

    private func load() {
        let current = storage.recordings.first { $0.id == recording.id } ?? recording
        project = current.project ?? ""
        tags = (current.tags ?? []).joined(separator: ", ")
        people = (current.people ?? []).joined(separator: ", ")
        speakers = current.speakerNames ?? [:]
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
