import SwiftUI

struct AccountSettingsView: View {
    // Proxy state
    @State private var proxyBaseURL: String = SettingsStorage.shared.proxyBaseURL
    @State private var isTestingProxy = false
    @State private var proxyTestResult: ProxyTestResult?
    @State private var isRefreshingConfig = false

    // Auth state
    @State private var authEmail: String = ""
    @State private var otpCode: String = ""
    @State private var authError: String?
    @State private var isAuthLoading = false
    private var authService: AuthService { AuthService.shared }

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

                switch authService.authState {
                case .loggedOut:
                    HStack {
                        TextField("Email", text: $authEmail)
                            .textFieldStyle(.roundedBorder)

                        Button("Send Code") {
                            sendOtp()
                        }
                        .buttonStyle(.bordered)
                        .disabled(authEmail.isEmpty || isAuthLoading)
                    }

                case .otpSent:
                    HStack {
                        TextField("Enter OTP code", text: $otpCode)
                            .textFieldStyle(.roundedBorder)

                        Button("Verify") {
                            verifyOtp()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(otpCode.isEmpty || isAuthLoading)

                        Button("Cancel") {
                            Task { await authService.logout() }
                        }
                        .buttonStyle(.bordered)
                    }

                case .loggedIn:
                    HStack {
                        if let email = authService.userEmail {
                            Text("Logged in as \(email)")
                                .foregroundColor(.secondary)
                        } else {
                            Text("Logged in")
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button("Logout") {
                            Task { await authService.logout() }
                        }
                        .buttonStyle(.bordered)
                    }

                    Label("Your credentials are stored securely in the macOS Keychain and never leave your device.", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if isAuthLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                if let error = authError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

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

            cloudUsageSection

            usageSection
        }
        .formStyle(.grouped)
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
                    if usage.isWhitelisted {
                        HStack {
                            Image(systemName: "infinity")
                                .foregroundColor(.green)
                            Text("Unlimited (whitelisted)")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: min(usageService.usagePercent, 1.0))
                                .tint(usageProgressColor(usageService.usagePercent))

                            HStack {
                                Text(String(format: "%.1fh / %.0fh used this month",
                                            usage.usedHours,
                                            usage.limitHours ?? 5))
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

    @ViewBuilder
    private var usageSection: some View {
        Section("Usage") {
            let recordings = RecordingsLibraryStorage.shared.recordings

            let totalDuration = recordings.reduce(0.0) { $0 + $1.durationSeconds }
            let voiceDuration = recordings.filter { $0.type == .voice }.reduce(0.0) { $0 + $1.durationSeconds }
            let translationDuration = recordings.filter { $0.type == .translation }.reduce(0.0) { $0 + $1.durationSeconds }
            let meetingDuration = recordings.filter { $0.type == .meeting }.reduce(0.0) { $0 + $1.durationSeconds }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "clock.fill")
                        .foregroundColor(.accentColor)
                    Text("Total recording time")
                    Spacer()
                    Text(formatDuration(totalDuration))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }

                Divider()

                usageRow(icon: "mic.fill", label: "Voice dictation", duration: voiceDuration, color: .blue)
                usageRow(icon: "globe", label: "Translation", duration: translationDuration, color: .green)
                usageRow(icon: "person.3.fill", label: "Meetings", duration: meetingDuration, color: .orange)

                Divider()

                HStack {
                    Image(systemName: "number")
                        .foregroundColor(.secondary)
                    Text("Total recordings")
                    Spacer()
                    Text("\(recordings.count)")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
            }

            Text("Recording time is tracked locally. This data will be used to show how much time Diduny has saved you.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func usageRow(icon: String, label: String, duration: TimeInterval, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 16)
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(formatDuration(duration))
                .monospacedDigit()
                .foregroundColor(.secondary)
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

    @ViewBuilder
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
                    proxyTestResult = .failure("Invalid proxy URL")
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

    private func sendOtp() {
        isAuthLoading = true
        authError = nil

        Task {
            do {
                try await authService.sendOtp(email: authEmail)
            } catch {
                authError = error.localizedDescription
            }
            isAuthLoading = false
        }
    }

    private func verifyOtp() {
        isAuthLoading = true
        authError = nil

        Task {
            do {
                try await authService.verifyOtp(email: authEmail, code: otpCode)
                otpCode = ""
                authEmail = ""
            } catch {
                authError = error.localizedDescription
            }
            isAuthLoading = false
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
