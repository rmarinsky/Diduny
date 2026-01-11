import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            AudioSettingsView()
                .tabItem {
                    Label("Audio", systemImage: "mic")
                }

            MeetingSettingsView()
                .tabItem {
                    Label("Meetings", systemImage: "person.3")
                }

            PermissionsSettingsView()
                .tabItem {
                    Label("Permissions", systemImage: "lock.shield")
                }

            APISettingsView()
                .tabItem {
                    Label("API", systemImage: "key")
                }
        }
        .frame(width: 500, height: 650)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
