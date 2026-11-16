import SwiftUI

enum MainWindowLayout {
    static let sidebarWidth: CGFloat = DS.Layout.sidebarWidth
    static let sidebarTopInset: CGFloat = 34
}

/// Sidebar and page side by side. The page takes exactly what the sidebar leaves: a `minWidth` of 0 keeps
/// a too-wide page from widening the row, which would centre it and push the sidebar off the window.
struct MainWindowColumns<Sidebar: View, Detail: View>: View {
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        HStack(spacing: 0) {
            sidebar()
                .frame(width: MainWindowLayout.sidebarWidth)
                .background(DS.Palette.sidebar)

            Rectangle()
                .fill(Color(.separatorColor).opacity(0.35))
                .frame(width: 0.5)

            detail()
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .background(DS.Palette.window)
        }
    }
}

struct MainWindowView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioDeviceManager.self) var audioDeviceManager
    @State private var selectedSection: MainSection

    init(initialSection: MainSection = .overview) {
        _selectedSection = State(initialValue: initialSection)
    }

    var body: some View {
        MainWindowColumns {
            SidebarView(
                selectedSection: Binding(
                    get: { selectedSection },
                    set: { requestSection($0) }
                ),
                topInset: MainWindowLayout.sidebarTopInset
            )
        } detail: {
            detailView
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("section.\(selectedSection.rawValue)")
                .overlay(alignment: .topLeading) {
                    if selectedSection.tabs.count > 1 { tabSwitch }
                }
        }
        .background(DS.Palette.window)
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .frame(minWidth: 1000, minHeight: 680)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            MainWindowController.shared.refreshActivationPolicy()
        }
        .onChange(of: appState.shouldOpenSettings) { _, shouldOpen in
            if shouldOpen {
                requestSection(.general)
                appState.shouldOpenSettings = false
            }
        }
        .onChange(of: MainWindowController.shared.requestedSection) { _, section in
            if let section {
                requestSection(section)
                MainWindowController.shared.requestedSection = nil
            }
        }
    }

    private func requestSection(_ section: MainSection) {
        guard section != selectedSection else { return }
        guard RecordingTrimNavigation.shared.requestLeave() else { return }
        selectedSection = section
    }

    /// The pages of the open sidebar row. Sits above the page title, in the window's title bar zone.
    private var tabSwitch: some View {
        Picker(selectedSection.tabs[0].sidebarLabel, selection: Binding(
            get: { selectedSection },
            set: { requestSection($0) }
        )) {
            ForEach(selectedSection.tabs, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .accessibilityIdentifier("section.tabs")
        .padding(.top, DS.Space.md)
        .padding(.leading, DS.Layout.pagePadding)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .overview:
            OverviewView()
        case .recordings:
            RecordingsLibraryView()
                .environment(audioDeviceManager)
        case .notes:
            NotesView()
        case .clipboard:
            ClipboardView()
        case .benchmark:
            BenchmarkView()
        case .typingTest:
            TypingTestView()
        case .meetings:
            MeetingSettingsView()
        case .general:
            GeneralSettingsView()
        case .modes:
            ModesSettingsView()
        case .languages:
            LanguagesSettingsView()
        case .vocabulary:
            VocabularySettingsView()
        case .typing:
            TypingSettingsView()
        case .audioDictation:
            AudioSettingsView()
                .environment(audioDeviceManager)
        case .models:
            OfflineModelsSettingsView()
        case .providers:
            ProvidersSettingsView()
        case .account:
            AccountSettingsView()
        case .about:
            AboutSettingsView()
        }
    }
}
