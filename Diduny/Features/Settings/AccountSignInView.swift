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
        VStack(alignment: .leading, spacing: 8) {
            switch authService.authState {
            case .loggedOut:
                if authService.showsMigrationNotice {
                    Label(
                        "Diduny's account system changed. Sign in again to continue using Diduny.",
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                HStack {
                    TextField("Your email address", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress)
                        .focused($focusedField, equals: .email)
                        .onSubmit(sendOtp)
                        .accessibilityLabel("Email address")
                        .accessibilityIdentifier("account.email")

                    Button("Send Code", action: sendOtp)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("account.sendCode")
                        .disabled(!AuthService.isValidEmail(email) || isLoading)
                }

            case .otpSent:
                Text("Enter the code sent to \(authService.pendingOtpEmail ?? email).")
                    .font(.callout)
                Text(
                    "Check your inbox and spam folder. You can paste the code or use a macOS code suggestion when available."
                )
                .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Enter 6-digit code", text: $otpCode)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.oneTimeCode)
                        .focused($focusedField, equals: .otp)
                        .onSubmit(verifyOtp)
                        .autocorrectionDisabled()
                        .accessibilityLabel("One-time code")
                        .accessibilityIdentifier("account.otp")

                    Button("Verify", action: verifyOtp)
                        .accessibilityIdentifier("account.verify")
                        .buttonStyle(.borderedProminent)
                        .disabled(otpCode.count != 6 || isLoading)

                    Button("Resend Code", action: resendOtp)
                        .buttonStyle(.bordered)
                        .disabled(isLoading)

                    Button("Change email", action: cancelOtp)
                        .buttonStyle(.bordered)
                }

            case .loggedIn:
                HStack {
                    Text(authService.userEmail
                        .map { String(localized: "Logged in as \($0)") } ?? String(localized: "Logged in"))
                        .foregroundColor(.secondary)

                    Spacer()

                    Button("Sign Out") {
                        Task { await authService.logout() }
                    }
                    .buttonStyle(.bordered)
                }

                Label("Credentials are stored in the macOS Keychain.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Signing in")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
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
    var body: some View {
        Section("Privacy") {
            Toggle("Share usage statistics", isOn: Binding(get: { analytics.enabled }, set: { value in
                Task { await analytics.setEnabled(value) }
            }))
            .disabled(analytics.isLoading && !analytics.enabled)
            Text(
                "Optional on Free and Pro. Shares duration, local/cloud mode and feature category linked to your account. No audio, text or file names. Cloud limits, payments and necessary security records are handled separately."
            )
            .font(.caption).foregroundStyle(.secondary)
            if let error = analytics.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            Button("Refresh sharing preference") { Task { await analytics.refresh() } }
                .disabled(analytics.isLoading)
        }
    }
}
