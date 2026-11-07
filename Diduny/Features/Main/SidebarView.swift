import KeyboardShortcuts
import SwiftUI

struct SidebarView: View {
    @Binding var selectedSection: MainSection
    @Environment(AppState.self) var appState

    let topInset: CGFloat
    @State private var dictationShortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)

    init(selectedSection: Binding<MainSection>, topInset: CGFloat = 34) {
        _selectedSection = selectedSection
        self.topInset = topInset
    }

    var body: some View {
        VStack(spacing: 0) {
            brandTile
                .padding(.horizontal, DS.Space.md)
                .padding(.top, topInset)
                .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(MainSection.mainItems, id: \.self) { section in
                        sidebarRow(for: section)
                    }

                    Text("Settings")
                        .font(DS.Font.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, DS.Space.md)
                        .padding(.bottom, DS.Space.xs)
                        .padding(.leading, DS.Space.xs)

                    ForEach(MainSection.settingsItems, id: \.self) { section in
                        sidebarRow(for: section)
                    }
                }
                .padding(.horizontal, DS.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)

            footerCTA
                .padding(.horizontal, DS.Space.md)
                .padding(.bottom, DS.Space.md)
        }
    }

    // MARK: - Brand Tile

    private var brandTile: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color("BrandTintSoft"))
                    .frame(width: 30, height: 30)
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color("BrandAccentDeep"))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Diduny")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.primary)
                proBadge
            }

            Spacer()
        }
    }

    private var proBadge: some View {
        Text("PRO")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(Color("ProBadgeText"))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color("ProBadgeBg"), in: Capsule())
    }

    // MARK: - Footer CTA

    /// The footer's shortcut text (design-spec 4.21); nil when the shortcut is removed.
    static func footerShortcutText(_ shortcut: KeyboardShortcuts.Shortcut?) -> String? {
        shortcut.map { String(describing: $0) }
    }

    private var footerCTA: some View {
        let shortcutText = Self.footerShortcutText(dictationShortcut)
        return Button {
            MainWindowController.shared.toggleRecording()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("Start recording")
                    .font(DS.Font.headline)
                Spacer()
                if let shortcutText {
                    Text(verbatim: shortcutText)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
            }
            .foregroundColor(.white)
            .padding(8)
            .frame(height: 32)
            .background(DS.Palette.accentFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle())
        .help("Start recording")
        .accessibilityLabel(Text("Start recording"))
        .accessibilityValue(Text(verbatim: shortcutText ?? ""))
        .accessibilityIdentifier("Start Recording")
        // KeyboardShortcuts stores shortcuts in UserDefaults; re-read on any change.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let current = KeyboardShortcuts.getShortcut(for: .toggleRecording)
            if current != dictationShortcut { dictationShortcut = current }
        }
    }

    private func sidebarRow(for section: MainSection) -> some View {
        Button {
            selectedSection = section
        } label: {
            SidebarRow(section: section, isSelected: selectedSection == section)
        }
        .buttonStyle(.plain)
        // The window gives the first row keyboard focus on open; its ring read as a second selection.
        .focusEffectDisabled()
        .accessibilityLabel(Text(section.label))
        .accessibilityValue(Text(selectedSection == section ? "Selected" : ""))
        .accessibilityIdentifier("Sidebar \(section.label)")
        .help(section.label)
    }
}

// MARK: - Sidebar Row

private struct SidebarRow: View {
    let section: MainSection
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: section.iconName)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 18)
                .foregroundColor(iconColor)
            Text(section.label)
                .font(.system(size: 13))
                .foregroundColor(textColor)
            Spacer()
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(
            isSelected
                ? DS.Palette.accentFill
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    private var iconColor: Color {
        isSelected ? .white : .secondary
    }

    private var textColor: Color {
        isSelected ? .white : .primary
    }
}
