import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, shortcuts, audio, dictation, translation, meetings, account, about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .audio: "Audio"
        case .dictation: "Dictation"
        case .translation: "Translation"
        case .meetings: "Meetings"
        case .account: "Account"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gear"
        case .shortcuts: "keyboard"
        case .audio: "mic"
        case .dictation: "text.bubble"
        case .translation: "globe"
        case .meetings: "person.3"
        case .account: "person.crop.circle"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) var appState
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label(tab.label, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 200)
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .frame(width: 700, height: 550)
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
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsView()
        case .shortcuts:
            ShortcutsSettingsView()
        case .audio:
            AudioSettingsView()
        case .dictation:
            DictationSettingsView()
        case .translation:
            TranslationSettingsView()
        case .meetings:
            MeetingSettingsView()
        case .account:
            AccountSettingsView()
        case .about:
            AboutSettingsView()
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
