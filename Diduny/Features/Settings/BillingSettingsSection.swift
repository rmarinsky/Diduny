import AppKit
import SwiftUI

@MainActor
struct BillingSettingsSection: View {
    let isLoggedIn: Bool
    @State private var billing = BillingService()
    @State private var interval: BillingInterval = .yearly
    @State private var confirmsCancellation = false
    @Environment(\.openURL) private var openURL

    init(isLoggedIn: Bool, billing: BillingService? = nil) {
        self.isLoggedIn = isLoggedIn
        _billing = State(initialValue: billing ?? BillingService())
    }

    var body: some View {
        Section("Diduny Pro") {
            Text(
                "Local models are free with no hourly limit. Cloud transcription includes 2 free hours per calendar month."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            if isLoggedIn {
                if let state = billing.state {
                    if state.plan == "pro" {
                        LabeledContent("Subscription", value: state.billingInterval == .yearly ? "Annual" : "Monthly")
                        if let date = displayDate(state.activeUntil) {
                            LabeledContent("Access until", value: date)
                        }
                        if state.cancelAtPeriodEnd {
                            Text("Automatic renewal is off. Your paid access stays available until the date above.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Resume automatic renewal") {
                                Task {
                                    if let url = await billing.setRenewal(enabled: true) {
                                        openURL(url)
                                        await billing.refresh()
                                    }
                                }
                            }
                        } else {
                            if let date = displayDate(state.renewsAt) { LabeledContent("Next payment", value: date) }
                            Button("Cancel automatic renewal", role: .destructive) { confirmsCancellation = true }
                        }
                    } else {
                        Picker("Payment period", selection: $interval) {
                            Text("Monthly").tag(BillingInterval.monthly)
                            Text("Annual").tag(BillingInterval.yearly)
                        }.pickerStyle(.segmented)
                            .disabled(state.pendingOrderReference != nil)
                        if let selected = state.plans.first(where: { $0.billingInterval == interval }) {
                            LabeledContent(
                                "Payment",
                                value: "\(selected.formattedPrice) / \(interval == .yearly ? "year" : "month")"
                            )
                            if interval == .yearly {
                                Text("12 months for the price of 10. Two months free.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Text(
                                "Payment renews automatically \(interval == .yearly ? "every year" : "every month"). Cancel renewal at any time; paid access stays available until the end of the period."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                            Button("Continue to WayForPay") {
                                Task {
                                    if let url = await billing.checkout(interval) {
                                        openURL(url)
                                        await billing.refresh()
                                    }
                                }
                            }.buttonStyle(.borderedProminent)
                        }
                        if state.pendingOrderReference != nil {
                            Text(
                                "A checkout is pending. Continue with its original payment period, or refresh after payment. A different period becomes available when it expires."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = billing.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    Button("Refresh subscription") { Task { await refresh(sync: true) } }
                    if billing.isLoading { ProgressView().controlSize(.small) }
                }
            } else {
                Text("Sign in to view subscription prices and upgrade.").foregroundStyle(.secondary)
            }
        }
        .onChange(of: billing.state?.pendingBillingInterval) { _, pending in
            if let pending { interval = pending }
        }
        .disabled(billing.isLoading)
        .task(id: isLoggedIn) {
            billing.reset()
            if isLoggedIn { await billing.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if isLoggedIn { Task { await refresh(sync: true) } }
        }
        .confirmationDialog("Cancel automatic renewal?", isPresented: $confirmsCancellation) {
            Button("Cancel renewal", role: .destructive) { Task { await billing.setRenewal(enabled: false) } }
        } message: {
            Text(
                "No further payments will be scheduled. Your paid access stays available until the end of the current period."
            )
        }
    }

    private func refresh(sync: Bool) async {
        await billing.refresh(sync: sync)
        await UsageService.shared.refresh()
    }

    private func displayDate(_ value: String?) -> String? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
