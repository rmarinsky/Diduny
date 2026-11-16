import SwiftUI

struct AccountSettingsView: View {
    // Proxy state
    @State private var proxyBaseURL: String = SettingsStorage.shared.proxyBaseURL
    @State private var isTestingProxy = false
    @State private var proxyTestResult: ProxyTestResult?
    @State private var isRefreshingConfig = false

    private var authService: AuthService {
        AuthService.shared
    }

    enum ProxyTestResult {
        case success
        case failure(String)
    }

    var body: some View {
        PageScaffold(title: "Account", subtitle: "Sign-in, plan and privacy.") { formContent }
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeneralGroup(heading: nil) {
                #if DEV_BUILD
                    SettingsLineRow(title: "Proxy URL") {
                        TextField("Proxy URL", text: $proxyBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                            .onChange(of: proxyBaseURL) { _, newValue in
                                SettingsStorage.shared.proxyBaseURL = newValue
                            }
                    }
                #endif

                AccountSignInView()

                #if DEV_BUILD
                    SettingsLineRow(title: "Test Connection", kind: .button) {
                        if isTestingProxy || isRefreshingConfig {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button("Test Connection") {
                            testProxyConnection()
                        }
                        .buttonStyle(.bordered)
                        .disabled(proxyBaseURL.isEmpty || isTestingProxy)

                        Button("Refresh Config") {
                            refreshRemoteConfig()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isRefreshingConfig)
                    }

                    if let result = proxyTestResult {
                        testResultView(result)
                    }
                #endif
            }

            BillingSettingsSection(isLoggedIn: authService.isLoggedIn)

            cloudUsageSection

            usageSection

            if authService.isLoggedIn { AnalyticsSettingsSection() }
        }
        .task(id: authService.userEmail) {
            if authService.isLoggedIn { await AnalyticsService.shared.refresh() }
            else { AnalyticsService.shared.reset() }
        }
        .onAppear {
            proxyBaseURL = SettingsStorage.shared.proxyBaseURL
            if authService.isLoggedIn {
                Task { await UsageService.shared.refresh() }
            }
        }
    }

    // MARK: - Cloud Usage Section

    @ViewBuilder
    private var cloudUsageSection: some View {
        if authService.isLoggedIn {
            GeneralGroup(heading: "Cloud usage") {
                let usageService = UsageService.shared

                if let usage = usageService.cachedUsage {
                    if usage.hasUnlimitedAccess {
                        SettingsLineRow(title: "Unlimited cloud access") {
                            Image(systemName: "infinity")
                                .foregroundStyle(DS.Palette.ok)
                                .accessibilityHidden(true)
                        }
                    } else {
                        SettingsLineRow(
                            title: LocalizedStringKey(String(
                                format: String(localized: "%.1fh / %.0fh used this month"),
                                locale: Locale.current,
                                usage.usedHours,
                                usage.limitHours ?? UsageService.freeCloudLimitHours
                            ))
                        ) {
                            ProgressView(value: min(usageService.usagePercent, 1.0))
                                .tint(usageProgressColor(usageService.usagePercent))
                                .frame(width: 120)
                            Text(usageService.formattedRemaining)
                                .font(DS.Font.meta)
                                .foregroundStyle(usageProgressColor(usageService.usagePercent))
                        }
                    }
                } else if usageService.isLoading {
                    SettingsLineRow(title: "Usage data not available", kind: .other) {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    SettingsLineRow(title: "Usage data not available") {}
                }

                SettingsLineRow(title: "Refresh", kind: .button, showsHairline: false) {
                    Button {
                        Task { await UsageService.shared.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(usageService.isLoading)
                }
            }
        }
    }

    private func usageProgressColor(_ percent: Double) -> Color {
        if percent < 0.5 { return DS.Palette.ok }
        if percent < 0.8 { return DS.Palette.warn }
        return DS.Palette.no
    }

    // MARK: - Usage Section

    private var usageSection: some View {
        GeneralGroup(heading: "Usage") {
            let statistics = RecordingStatistics(rows: RecordingsLibraryStorage.shared.usageStatRows)

            usageRow(label: "Total recording time", duration: statistics.totalDurationSeconds)
            usageRow(label: "Voice dictation", duration: statistics.voiceDurationSeconds)
            usageRow(label: "Translation", duration: statistics.translationDurationSeconds)
            usageRow(label: "Meetings", duration: statistics.meetingDurationSeconds)
            usageRow(label: "Imported files", duration: statistics.importedFileDurationSeconds)
            usageRow(label: "YouTube", duration: statistics.youtubeDurationSeconds)
            SettingsLineRow(
                title: "Total recordings",
                caption: "Recording time is tracked locally. This data will be used to show how much time Diduny has saved you.",
                showsHairline: false
            ) {
                Text("\(statistics.recordingCount)")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func usageRow(label: LocalizedStringKey, duration: TimeInterval) -> some View {
        SettingsLineRow(title: label) {
            Text(formatDuration(duration))
                .font(DS.Font.body)
                .foregroundStyle(DS.Palette.secondary)
                .monospacedDigit()
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, secs)
        } else if minutes > 0 {
            return String(format: "%dm %02ds", minutes, secs)
        } else {
            return String(format: "%ds", secs)
        }
    }

    // MARK: - Helpers

    private func testResultView(_ result: ProxyTestResult) -> some View {
        HStack {
            switch result {
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Connection successful")
                    .foregroundColor(.green)
            case let .failure(message):
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text(message)
                    .foregroundColor(.red)
            }
        }
        .font(.caption)
    }

    private func testProxyConnection() {
        isTestingProxy = true
        proxyTestResult = nil

        Task {
            let urlString = proxyBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: "\(urlString)/api/v1/health") else {
                await MainActor.run {
                    proxyTestResult = .failure(String(localized: "Invalid proxy URL"))
                    isTestingProxy = false
                }
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 10

            await AuthService.shared.authenticatedRequest(&request)

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                await MainActor.run {
                    if (200 ... 299).contains(statusCode) {
                        proxyTestResult = .success
                    } else if statusCode == 401 {
                        proxyTestResult = .failure("Unauthorized \u{2014} check proxy token")
                    } else {
                        proxyTestResult = .failure("Status \(statusCode)")
                    }
                    isTestingProxy = false
                }
            } catch {
                await MainActor.run {
                    proxyTestResult = .failure(error.localizedDescription)
                    isTestingProxy = false
                }
            }
        }
    }

    private func refreshRemoteConfig() {
        isRefreshingConfig = true

        Task {
            await RemoteConfigService.shared.forceRefresh()
            await MainActor.run {
                isRefreshingConfig = false
            }
        }
    }
}

#Preview {
    AccountSettingsView()
        .frame(width: 500, height: 600)
}
