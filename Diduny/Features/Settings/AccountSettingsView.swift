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
        Form {
            Section("Account") {
                #if DEV_BUILD
                    HStack {
                        TextField("Proxy URL", text: $proxyBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: proxyBaseURL) { _, newValue in
                                SettingsStorage.shared.proxyBaseURL = newValue
                            }
                    }
                #endif

                AccountSignInView()

                #if DEV_BUILD
                    HStack(spacing: 8) {
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

                        if isTestingProxy || isRefreshingConfig {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Spacer()
                    }

                    if let result = proxyTestResult {
                        testResultView(result)
                    }
                #endif
            }

            BillingSettingsSection(isLoggedIn: authService.isLoggedIn)

            if authService.isLoggedIn { AnalyticsSettingsSection() }
            cloudUsageSection

            usageSection
        }
        .formStyle(.grouped)
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
            Section("Cloud Usage") {
                let usageService = UsageService.shared

                if let usage = usageService.cachedUsage {
                    if usage.hasUnlimitedAccess {
                        HStack {
                            Image(systemName: "infinity")
                                .foregroundColor(.green)
                            Text("Unlimited cloud access")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: min(usageService.usagePercent, 1.0))
                                .tint(usageProgressColor(usageService.usagePercent))

                            HStack {
                                Text(String(
                                    format: String(localized: "%.1fh / %.0fh used this month"),
                                    locale: Locale.current,
                                    usage.usedHours,
                                    usage.limitHours ?? UsageService.freeCloudLimitHours
                                ))
                                .font(.caption)
                                .foregroundColor(.secondary)

                                Spacer()

                                Text(usageService.formattedRemaining)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(usageProgressColor(usageService.usagePercent))
                            }
                        }
                    }
                } else if usageService.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Usage data not available")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Spacer()
                    Button {
                        Task { await UsageService.shared.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(usageService.isLoading)
                }
            }
        }
    }

    private func usageProgressColor(_ percent: Double) -> Color {
        if percent < 0.5 { return .green }
        if percent < 0.8 { return .yellow }
        return .red
    }

    // MARK: - Usage Section

    private var usageSection: some View {
        Section("Usage") {
            let recordings = RecordingsLibraryStorage.shared.recordings
            let statistics = RecordingStatistics(recordings: recordings)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "clock.fill")
                        .foregroundColor(.accentColor)
                        .accessibilityHidden(true)
                    Text("Total recording time")
                    Spacer()
                    Text(formatDuration(statistics.totalDurationSeconds))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)

                Divider()

                usageRow(
                    icon: "mic.fill",
                    label: "Voice dictation",
                    duration: statistics.voiceDurationSeconds,
                    color: Color("BrandAccentDeep")
                )
                usageRow(
                    icon: "globe",
                    label: "Translation",
                    duration: statistics.translationDurationSeconds,
                    color: .green
                )
                usageRow(
                    icon: "person.3.fill",
                    label: "Meetings",
                    duration: statistics.meetingDurationSeconds,
                    color: .orange
                )
                usageRow(
                    icon: "doc.fill",
                    label: String(localized: "Imported files"),
                    duration: statistics.importedFileDurationSeconds,
                    color: .brown
                )
                usageRow(
                    icon: "play.rectangle.fill",
                    label: String(localized: "YouTube"),
                    duration: statistics.youtubeDurationSeconds,
                    color: .red
                )

                Divider()

                HStack {
                    Image(systemName: "number")
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                    Text("Total recordings")
                    Spacer()
                    Text("\(statistics.recordingCount)")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }

            Text(
                "Recording time is tracked locally. This data will be used to show how much time Diduny has saved you."
            )
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    private func usageRow(icon: String, label: String, duration: TimeInterval, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(label))
                .foregroundColor(.secondary)
            Spacer()
            Text(formatDuration(duration))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
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
