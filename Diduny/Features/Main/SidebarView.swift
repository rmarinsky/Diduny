import SwiftUI

struct SidebarView: View {
    @Binding var selectedSection: MainSection
    @Environment(AppState.self) var appState

    private let mainItems: [MainSection] = [.overview, .recordings, .meetings]
    private let settingsItems: [MainSection] = [.general, .audioDictation, .models, .shortcuts, .account]

    var body: some View {
        VStack(spacing: 0) {
            brandTile
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 12)

            List(selection: $selectedSection) {
                ForEach(mainItems, id: \.self) { section in
                    SidebarRow(section: section, isSelected: selectedSection == section)
                        .tag(section)
                        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                }

                Section {
                    ForEach(settingsItems, id: \.self) { section in
                        SidebarRow(section: section, isSelected: selectedSection == section)
                            .tag(section)
                            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                    }
                } header: {
                    Text("SETTINGS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                }
            }
            .listStyle(.sidebar)

            footerCTA
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
    }

    // MARK: - Brand Tile

    private var brandTile: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color("BrandAccentDeep").opacity(0.85), Color("BrandAccentDeep")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 32, height: 32)
                Image(systemName: "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Diduny")
                    .font(.system(size: 15, weight: .bold))
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
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.toggleRecording()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("Start Recording")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("⌘⌃D")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .opacity(0.7)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color("BrandAccentDeep"), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
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
        .background(
            isSelected
                ? Color("BrandAccentDeep")
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
