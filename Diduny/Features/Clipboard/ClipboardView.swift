import AppKit
import SwiftUI

/// The Clipboard page: what was copied and what Diduny pasted, by day, with its settings below.
struct ClipboardView: View {
    @State private var model: ClipboardPageModel
    @FocusState private var keepIsFocused: Bool

    init(model: ClipboardPageModel? = nil) {
        _model = State(initialValue: model ?? ClipboardPageModel())
    }

    var body: some View {
        PageScaffold(
            title: "Clipboard",
            subtitle: "Everything you copied and everything Diduny pasted, so you can bring an earlier one back."
        ) {
            let days = model.days
            LazyVStack(alignment: .leading, spacing: 0) {
                searchRow
                if model.isEmpty {
                    note("Nothing here yet. Copy something, or dictate.", id: "clipboard.empty")
                } else if days.isEmpty {
                    note("No results", id: "clipboard.noResults")
                }
                ForEach(days) { day in
                    group(Text(verbatim: day.title))
                    ForEach(day.entries) { entry in
                        ClipboardEntryRow(
                            entry: entry, thumbnailURL: model.thumbnailURL(for: entry), isCopied: model.copiedID == entry.id,
                            onCopy: { model.copy(entry) }, onDelete: { model.delete(entry) }
                        )
                    }
                }
                group(Text("Settings"))
                settingsRows
            }
        }
        .onDisappear { model.isAskingToClear = false }
    }

    // MARK: - Search and filter

    private var searchRow: some View {
        HStack(spacing: DS.Space.lg) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DS.Palette.secondary)
                    .font(DS.Font.body)
                    .accessibilityHidden(true)
                TextField("Search the clipboard", text: $model.query, prompt: Text("Search text and apps"))
                    .textFieldStyle(.plain)
                    .font(DS.Font.body)
                    .accessibilityIdentifier("clipboard.search")
            }
            .padding(.horizontal, DS.Space.md)
            .frame(height: DS.Size.keyInput)
            .frame(maxWidth: .infinity)
            .background(DS.Palette.box, in: RoundedRectangle(cornerRadius: DS.Radius.keyInput, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.keyInput, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: 1)
            )

            Picker("Show", selection: $model.filter) {
                ForEach(ClipboardPageModel.Filter.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .accessibilityIdentifier("clipboard.filter")
        }
        .padding(.vertical, 9)
    }

    /// One line of secondary text in place of the day groups.
    private func note(_ text: LocalizedStringKey, id: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text)
                .font(DS.Font.meta)
                .foregroundStyle(DS.Palette.secondary)
                .padding(.vertical, 9)
                .accessibilityIdentifier(id)
            Rectangle().fill(DS.Palette.line).frame(height: 1)
        }
    }

    /// Group heading (spec 4.10): 18 above, 15 semibold, 2 below, as on General.
    private func group(_ title: Text) -> some View {
        title
            .font(DS.Font.groupHeading)
            .foregroundStyle(DS.Palette.text)
            .padding(.top, 18)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Settings

    @ViewBuilder private var settingsRows: some View {
        SettingsLineRow(title: "Keep the clipboard for", kind: .popUp) {
            Picker("Keep the clipboard for", selection: Binding(
                get: { model.retention }, set: { model.setRetention($0) }
            )) {
                ForEach(ClipboardRetention.allCases) { Text(verbatim: $0.displayName).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
            .accessibilityIdentifier("clipboard.retention")
        }
        SettingsLineRow(title: "Keep screenshots", caption: "Screenshots take more space than text.", kind: .toggle) {
            SettingsSwitch(title: "Keep screenshots", isOn: Binding(
                get: { model.keepScreenshots }, set: { model.setKeepScreenshots($0) }
            ))
            .accessibilityIdentifier("clipboard.keepScreenshots")
        }
        SettingsLineRow(title: "Keep what Diduny pastes", caption: "Dictated and translated text.", kind: .toggle) {
            SettingsSwitch(title: "Keep what Diduny pastes", isOn: Binding(
                get: { model.keepDidunyPastes }, set: { model.setKeepDidunyPastes($0) }
            ))
            .accessibilityIdentifier("clipboard.keepDidunyPastes")
        }
        SettingsLineRow(
            title: "Skip password managers",
            caption: "Nothing copied in 1Password, Keychain and similar apps is kept.",
            kind: .toggle
        ) {
            SettingsSwitch(title: "Skip password managers", isOn: Binding(
                get: { model.skipPasswordManagers }, set: { model.setSkipPasswordManagers($0) }
            ))
            .accessibilityIdentifier("clipboard.skipPasswordManagers")
        }
        // The question is in the row itself: "Clear" becomes "Clear everything" and "Keep".
        SettingsLineRow(title: "Clear the clipboard history", kind: .button, showsHairline: false) {
            if model.isAskingToClear {
                Button(role: .destructive) { model.clearEverything() } label: {
                    Text("Clear everything").foregroundStyle(DS.Palette.no)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("clipboard.clear.confirm")
                Button("Keep") { model.isAskingToClear = false }
                    .buttonStyle(.bordered)
                    .focused($keepIsFocused)
                    .accessibilityIdentifier("clipboard.clear.keep")
            } else {
                Button(role: .destructive) {
                    model.isAskingToClear = true
                    keepIsFocused = true
                } label: {
                    Text("Clear").foregroundStyle(DS.Palette.no)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("clipboard.clear")
            }
        }
    }
}

/// One entry: the `SettingsLineRow` measures with content that is not a localization key.
private struct ClipboardEntryRow: View {
    let entry: ClipboardEntry
    let thumbnailURL: URL?
    let isCopied: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: DS.Space.lg) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.Space.md) {
                        if entry.kind == .image { ClipboardThumbnail(url: thumbnailURL) }
                        Text(verbatim: ClipboardPageModel.title(for: entry))
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Palette.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 440, alignment: .leading)
                    }
                    Text(verbatim: ClipboardPageModel.caption(for: entry))
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.secondary)
                        .lineLimit(1)
                        .padding(.vertical, DS.Font.LineSpacing.rowCaption / 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                HStack(spacing: DS.Space.sm) {
                    Text(verbatim: ClipboardPageModel.time(for: entry))
                        .font(DS.Font.meta)
                        .monospacedDigit()
                        .foregroundStyle(DS.Palette.secondary)
                    Button(action: onCopy) {
                        // Both labels take part in the layout, so the width does not change.
                        ZStack {
                            Text("Copy").hidden()
                            Text("Copied").hidden()
                            Text(isCopied ? "Copied" : "Copy")
                                .contentTransition(.opacity)
                                .animation(
                                    reduceMotion ? nil : DS.Motion.easeOut(DS.Motion.m17CopyLabel.duration), value: isCopied
                                )
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("clipboard.entry.copy")
                    TrashButton(accessibilityLabel: "Delete this item", action: onDelete)
                        .accessibilityIdentifier("clipboard.entry.delete")
                }
                .fixedSize()
            }
            .padding(.vertical, 9)
            Rectangle().fill(DS.Palette.line).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipboard.entry.\(entry.kind.rawValue)")
    }
}

/// 132 x 78: the small file made at capture, scaled to fill. The full image is never decoded here.
private struct ClipboardThumbnail: View {
    let url: URL?

    @State private var image: NSImage?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.previewDrawing, style: .continuous)
    }

    var body: some View {
        ZStack {
            DS.Palette.box
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: 132, height: 78)
        .clipShape(shape)
        .overlay(shape.strokeBorder(DS.Palette.line, lineWidth: 1))
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { return }
            image = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
        }
    }
}
