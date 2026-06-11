import SwiftUI

struct MainWindowView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioDeviceManager.self) var audioDeviceManager
    @State private var selectedSection: MainSection = .overview

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
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.refreshActivationPolicy()
            } else {
                NSApp.setActivationPolicy(.accessory)
            }
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
            MeetingsPlaceholderView()
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

// MARK: - Meetings placeholder (D6 will replace this)

struct MeetingsPlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar")
                .font(.system(size: 48))
                .foregroundColor(Color("BrandTintSoft"))
            Text("Meetings")
                .font(.title2.bold())
            Text("Coming in D6")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
