import SwiftUI

struct AccountSignInView: View {
    private enum Field {
        case email
        case otp
    }

    @State private var email = ""
    @State private var otpCode = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @FocusState private var focusedField: Field?

    private let authService: AuthService

    @MainActor
    init(authService: AuthService = .shared) {
        self.authService = authService
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch authService.authState {
            case .loggedOut:
                if authService.showsMigrationNotice {
                    Label(
                        "Diduny's account system changed. Sign in again to continue using Diduny.",
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.secondary)
                    .padding(.vertical, 9)
                }

                SettingsLineRow(title: "Sign in with an email code", kind: .button) {
                    TextField("Your email address", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress)
                        .focused($focusedField, equals: .email)
                        .onSubmit(sendOtp)
                        .frame(width: 200)
                        .accessibilityLabel("Email address")
                        .accessibilityIdentifier("account.email")

                    Button("Send Code", action: sendOtp)
                        .buttonStyle(.borderedProminent)
                        .tint(DS.Palette.accent)
                        .accessibilityIdentifier("account.sendCode")
                        .disabled(!AuthService.isValidEmail(email) || isLoading)
                }

            case .otpSent:
                SettingsLineRow(
                    title: "Enter the code sent to \(authService.pendingOtpEmail ?? email).",
                    caption: "Check your inbox and spam folder. You can paste the code or use a macOS code suggestion when available.",
                    kind: .button
                ) {
                    TextField("Enter 6-digit code", text: $otpCode)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.oneTimeCode)
                        .focused($focusedField, equals: .otp)
                        .onSubmit(verifyOtp)
                        .autocorrectionDisabled()
                        .frame(width: 140)
                        .accessibilityLabel("One-time code")
                        .accessibilityIdentifier("account.otp")

                    Button("Verify", action: verifyOtp)
                        .accessibilityIdentifier("account.verify")
                        .buttonStyle(.borderedProminent)
                        .tint(DS.Palette.accent)
                        .disabled(otpCode.count != 6 || isLoading)

                    Button("Resend Code", action: resendOtp)
                        .buttonStyle(.bordered)
                        .disabled(isLoading)

                    Button("Change email", action: cancelOtp)
                        .buttonStyle(.bordered)
                }

            case .loggedIn:
                SettingsLineRow(
                    title: authService.userEmail
                        .map { "Logged in as \($0)" } ?? "Logged in",
                    caption: "Credentials are stored in the macOS Keychain.",
                    kind: .button
                ) {
                    Button("Sign Out", role: .destructive) {
                        Task { await authService.logout() }
                    }
                    .buttonStyle(.bordered)
                }
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, 9)
                    .accessibilityLabel("Signing in")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.no)
                    .padding(.vertical, 9)
                    .accessibilityIdentifier("account.error")
            }
        }
        .onAppear(perform: focusCurrentField)
        .onChange(of: authService.authState) { _, _ in
            focusCurrentField()
        }
        .onChange(of: otpCode) { _, value in
            let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
            if digits != value { otpCode = digits }
        }
    }

    private func sendOtp() {
        guard !isLoading, AuthService.isValidEmail(email) else { return }
        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await authService.sendOtp(email: email)
            } catch AuthError.invalidEmail {
                errorMessage = String(localized: "Enter a valid email address.")
            } catch {
                errorMessage = String(localized: "Couldn't send a code. Try again.")
            }
            isLoading = false
        }
    }

    private func verifyOtp() {
        guard !isLoading, otpCode.count == 6 else { return }
        isLoading = true
        errorMessage = nil

        Task {
            do {
                guard let destination = authService.pendingOtpEmail else {
                    throw AuthError.notAuthenticated
                }
                try await authService.verifyOtp(email: destination, code: otpCode)
                otpCode = ""
                email = ""
                if authService === AuthService.shared { await AnalyticsService.shared.refresh() }
            } catch {
                errorMessage = String(localized: "That code couldn't be verified. Send a new one and try again.")
            }
            isLoading = false
        }
    }

    private func cancelOtp() {
        otpCode = ""
        errorMessage = nil
        authService.cancelOtpFlow()
    }

    private func resendOtp() {
        guard !isLoading else { return }
        otpCode = ""
        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await authService.resendOtp()
            } catch {
                errorMessage = String(localized: "Couldn't send a new code. Try again.")
            }
            isLoading = false
        }
    }

    private func focusCurrentField() {
        focusedField = authService.authState == .otpSent ? .otp : .email
    }
}

@MainActor
struct AnalyticsSettingsSection: View {
    var analytics: AnalyticsService = .shared
    var settings: SettingsStorage = .shared
    /// SettingsStorage is not observable; this mirrors the toggle so it redraws.
    @State private var featureUsageOn = true
    var body: some View {
        GeneralGroup(heading: "Privacy") {
            SettingsLineRow(
                title: "Share usage statistics",
                caption: "Optional on Free and Pro. Shares duration, local/cloud mode, feature category and the transcription engine, plus app launches, unexpected quits and error codes with the Diduny version, macOS version and Mac chip type (Apple silicon or Intel), linked to your account and kept for 30 days (error codes 90 days). No audio, text or file names. Cloud limits, payments and necessary security records are handled separately.",
                kind: .toggle
            ) {
                SettingsSwitch(title: "Share usage statistics", isOn: Binding(get: { analytics.enabled }, set: { value in
                    Task { await analytics.setEnabled(value) }
                }))
                .disabled(analytics.isLoading && !analytics.enabled)
            }
            if analytics.enabled, analytics.engineTimeVisible {
                note("The Diduny team sees how much time this account spends on each transcription engine and model, to help with support. Turn off sharing to stop it.")
            }
            SettingsLineRow(
                title: "Share anonymous feature usage",
                caption: "On by default. Counts which features and shortcuts are used each day, so we know what to improve. Sent once a day while you are signed in, so only Diduny accounts can send counts; the server stores the daily totals without your account, and nothing you say or type.",
                kind: .toggle
            ) {
                SettingsSwitch(title: "Share anonymous feature usage", isOn: Binding(
                    get: { featureUsageOn },
                    set: { value in
                        settings.shareFeatureUsage = value
                        if !value { FeatureUsageCounter.shared.discardPending() }
                        featureUsageOn = value
                    }
                ))
                .onAppear { featureUsageOn = settings.shareFeatureUsage }
            }
            if let error = analytics.errorMessage {
                Text(error).font(DS.Font.meta).foregroundStyle(DS.Palette.no).padding(.vertical, 9)
            }
            SettingsLineRow(title: "Refresh sharing preference", kind: .button, showsHairline: false) {
                Button("Refresh") { Task { await analytics.refresh() } }
                    .buttonStyle(.bordered)
                    .disabled(analytics.isLoading)
            }
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text).font(DS.Font.meta).foregroundStyle(DS.Palette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 9)
    }
}
