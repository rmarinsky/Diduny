import SwiftUI

struct MainWindowView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioDeviceManager.self) var audioDeviceManager
    @State private var selectedSection: MainSection

    init(initialSection: MainSection = .overview) {
        _selectedSection = State(initialValue: initialSection)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(selectedSection: $selectedSection)
                .navigationSplitViewColumnWidth(min: 210, ideal: 238, max: 280)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .toolbar(removing: .sidebarToggle)
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
                selectedSection = .general
                appState.shouldOpenSettings = false
            }
        }
        .onChange(of: MainWindowController.shared.requestedSection) { _, section in
            if let section {
                selectedSection = section
                MainWindowController.shared.requestedSection = nil
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .overview:
            OverviewView()
        case .recordings:
            RecordingsLibraryView()
                .environment(audioDeviceManager)
        case .meetings:
            MeetingsView()
        case .general:
            GeneralSettingsView()
        case .audioDictation:
            AudioDictationSettingsView()
                .environment(audioDeviceManager)
        case .models:
            OfflineModelsSettingsView()
        case .shortcuts:
            ShortcutsSettingsView()
        case .account:
            AccountSettingsView()
        }
    }
}
