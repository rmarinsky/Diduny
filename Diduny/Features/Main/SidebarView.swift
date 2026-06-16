import SwiftUI

struct SidebarView: View {
    @Binding var selectedSection: MainSection
    @Environment(AppState.self) var appState

    let topInset: CGFloat

    private let mainItems: [MainSection] = [.overview, .recordings, .meetings]
    private let settingsItems: [MainSection] = [.general, .audioDictation, .models, .shortcuts, .account]

    init(selectedSection: Binding<MainSection>, topInset: CGFloat = 34) {
        _selectedSection = selectedSection
        self.topInset = topInset
    }

    var body: some View {
        VStack(spacing: 0) {
            brandTile
                .padding(.horizontal, 14)
                .padding(.top, topInset)
                .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(mainItems, id: \.self) { section in
                        sidebarRow(for: section)
                    }

                    Text("SETTINGS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.top, 14)
                        .padding(.bottom, 3)
                        .padding(.leading, 4)

                    ForEach(settingsItems, id: \.self) { section in
                        sidebarRow(for: section)
                    }
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)

            footerCTA
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
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

    private var footerCTA: some View {
        Button {
            MainWindowController.shared.toggleRecording()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("Start Recording")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("⌘⇧D")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .opacity(0.7)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color("BrandAccentDeep"), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Start Recording")
        .accessibilityLabel(Text("Start Recording"))
        .accessibilityIdentifier("Start Recording")
    }

    private func sidebarRow(for section: MainSection) -> some View {
        SidebarRow(section: section, isSelected: selectedSection == section)
            .onTapGesture {
                selectedSection = section
            }
            .focusable(false)
            .accessibilityLabel(Text(section.label))
            .accessibilityValue(Text(selectedSection == section ? "Selected" : ""))
            .accessibilityIdentifier("Sidebar \(section.label)")
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
                .foregroundColor(isSelected ? .white : .secondary)
            Text(section.label)
                .font(.system(size: 13))
                .foregroundColor(isSelected ? .white : .primary)
            Spacer()
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(
            isSelected
                ? Color("BrandAccentDeep")
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
    }
}
