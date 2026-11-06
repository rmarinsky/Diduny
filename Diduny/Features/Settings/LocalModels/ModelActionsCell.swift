import SwiftUI

/// Local models actions cell (design-spec 4.12): the whole life of a model in one trailing line.
struct ModelActionsCell: View {
    let row: LocalModelRow
    let state: ModelActionState
    let model: LocalModelsModel

    @FocusState private var keepFocused: Bool

    private func id(_ action: String) -> String { "models.action.\(row.id).\(action)" }

    var body: some View {
        HStack(spacing: 6) {
            content
            if state.showsTrash {
                TrashButton(accessibilityLabel: "Delete \(row.name)") { model.askToDelete(row) }
                    .accessibilityIdentifier(id("delete"))
            }
        }
        .lineLimit(1)
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onChange(of: state) { _, new in
            if case .askingDelete = new { keepFocused = true }
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .download:
            button("Download", id: "download") { model.download(row) }
        case let .downloading(percent):
            Text(verbatim: "\(percent)%")
                .font(DS.Font.meta)
                .monospacedDigit()
                .foregroundStyle(DS.Palette.secondary)
                .accessibilityIdentifier(id("percent"))
            button("Cancel", id: "cancel") { model.cancel(row) }
        case .use:
            button("Use", id: "use") { model.use(row) }
        case .active:
            status("Active", color: DS.Palette.accentText, id: "active")
        case .ready:
            status("Ready", color: DS.Palette.ok, id: "ready")
        case .builtIn:
            secondary("Built in", id: "builtIn")
        case .notOnThisMac:
            secondary("Not on this Mac", id: "builtIn")
        case let .failed(message):
            status("Failed", color: DS.Palette.no, id: "failed")
                .help(message)
            button("Retry", id: "retry") { model.download(row) }
                .help(message)
        case let .askingDelete(size):
            Button(role: .destructive) { model.confirmDelete(row) } label: {
                Text("Delete \(size)").font(DS.Font.calloutStrong).foregroundStyle(DS.Palette.no)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(id("confirmDelete"))
            button("Keep", id: "keep") { model.keep() }
                .focused($keepFocused)
        }
    }

    private func button(_ title: LocalizedStringKey, id action: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Text(title).font(DS.Font.calloutStrong) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(id(action))
    }

    private func status(_ title: LocalizedStringKey, color: Color, id action: String) -> some View {
        Text(title).font(DS.Font.calloutStrong).foregroundStyle(color).accessibilityIdentifier(id(action))
    }

    private func secondary(_ title: LocalizedStringKey, id action: String) -> some View {
        Text(title).font(DS.Font.meta).foregroundStyle(DS.Palette.secondary).accessibilityIdentifier(id(action))
    }
}
