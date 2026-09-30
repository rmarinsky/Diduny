import SwiftUI

private enum MainWindowLayout {
    static let sidebarWidth: CGFloat = 238
    static let sidebarTopInset: CGFloat = 34
    static let detailTopInset: CGFloat = 14
}

struct MainWindowView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioDeviceManager.self) var audioDeviceManager
    @State private var selectedSection: MainSection

    init(initialSection: MainSection = .overview) {
        _selectedSection = State(initialValue: initialSection)
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                selectedSection: Binding(
                    get: { selectedSection },
                    set: { requestSection($0) }
                ),
                topInset: MainWindowLayout.sidebarTopInset
            )
            .frame(width: MainWindowLayout.sidebarWidth)
            .background(.bar)

            Rectangle()
                .fill(Color(.separatorColor).opacity(0.35))
                .frame(width: 0.5)

            detailView
                .padding(.top, MainWindowLayout.detailTopInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(.windowBackgroundColor))
        }
        .background(Color(.windowBackgroundColor))
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .frame(minWidth: 1000, idealWidth: 1000, minHeight: 680, idealHeight: 680)
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

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .overview:
            OverviewView()
        case .recordings:
            RecordingsLibraryView()
                .environment(audioDeviceManager)
        case .typingTest:
            TypingTestView()
        case .meetings:
            MeetingSettingsView()
        case .general:
            GeneralSettingsView()
        case .audioDictation:
            AudioDictationSettingsView()
                .environment(audioDeviceManager)
        case .models:
            OfflineModelsSettingsView()
        case .shortcuts:
            ShortcutsSettingsView()
        case .speech:
            SpeechSettingsView()
        case .account:
            AccountSettingsView()
        }
    }
}
