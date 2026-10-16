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
            VStack(alignment: .leading, spacing: 18) {
                if isLoggedIn, let state = billing.state {
                    if state.plan == "pro" {
                        subscription(state)
                    } else {
                        BillingOfferView(state: state, interval: $interval,
                                         checkoutAvailable: billing.checkoutAvailable,
                                         isLoading: billing.isLoading)
                        { chosen in
                            Task {
                                if let url = await billing.checkout(chosen) {
                                    openURL(url)
                                    await billing.refresh()
                                }
                            }
                        }
                    }
                } else if isLoggedIn {
                    Label(billing.isLoading ? "Loading subscription…" : "Subscription could not be loaded",
                          systemImage: "cloud")
                        .foregroundStyle(.secondary)
                } else {
                    Text("More room for your voice").font(.title3.weight(.semibold))
                    Text("Sign in to view subscription prices and upgrade.").foregroundStyle(.secondary)
                }

                if let error = billing.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .accessibilityIdentifier("billing.error")
                }
                Divider()
                Text(
                    "Always free: local models with no hourly limit, plus 2 hours of cloud transcription per calendar month."
                )
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Link("Terms, refunds & privacy", destination: BillingService.publicPolicyURL)
                    Spacer()
                    if isLoggedIn {
                        if billing.isLoading { ProgressView().controlSize(.small) }
                        Button("Check payment status") { Task { await refresh(sync: billing.checkoutAvailable) } }
                            .disabled(billing.isLoading)
                    }
                }.font(.callout)
            }.padding(.vertical, 8)
        }
        .onChange(of: billing.state?.pendingBillingInterval) { _, pending in
            if let pending { interval = pending }
        }
        .task(id: isLoggedIn) {
            billing.reset()
            if isLoggedIn { await billing.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if isLoggedIn { Task { await refresh(sync: billing.checkoutAvailable) } }
        }
        .confirmationDialog("Cancel automatic renewal?", isPresented: $confirmsCancellation) {
            Button("Cancel renewal", role: .destructive) { Task { await billing.setRenewal(enabled: false) } }
        } message: {
            Text(
                "No further payments will be scheduled. Your paid access stays available until the end of the current period."
            )
        }
    }

    @ViewBuilder private func subscription(_ state: BillingState) -> some View {
        Label(state.status == "past_due" ? "Your renewal needs attention" : "Diduny Pro is active",
              systemImage: state.status == "past_due" ? "exclamationmark.circle" : "checkmark.circle.fill")
            .font(.title3.weight(.semibold))
            .foregroundStyle(state.status == "past_due" ? Color.orange : Color.green)
        if state.status == "past_due" {
            Text(
                "The renewal payment has not been confirmed. Pro remains available during a short grace period. Check payment status below or contact support."
            )
            .font(.callout).foregroundStyle(.secondary)
            Link("Contact support", destination: URL(string: "mailto:roman@rmarinsky.com.ua")!)
        }
        LabeledContent("Subscription", value: state.billingInterval == .yearly ? "Annual" : "Monthly")
        if let date = displayDate(state.activeUntil) { LabeledContent(
            state.status == "past_due" ? "Last paid period ended" : "Access until",
            value: date
        ) }
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
            }.disabled(billing.isLoading)
        } else {
            if let date = displayDate(state.renewsAt) { LabeledContent("Next payment", value: date) }
            Button("Cancel automatic renewal", role: .destructive) { confirmsCancellation = true }
                .disabled(billing.isLoading)
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
        guard let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// Purchase presentation stays separate from network state so every step can be rendered with controlled data.
@MainActor
struct BillingOfferView: View {
    let state: BillingState
    @Binding var interval: BillingInterval
    let checkoutAvailable: Bool
    let isLoading: Bool
    let checkout: (BillingInterval) -> Void
    @State private var reviewing = false

    private var selected: BillingPlan? {
        if pending, let plan = state.pendingPlan { return plan }
        return state.plans.first { $0.billingInterval == effectiveInterval }
    }

    private var effectiveInterval: BillingInterval {
        pending ? state.pendingBillingInterval ?? interval : interval
    }

    private var pending: Bool {
        state.pendingOrderReference != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(reviewing ? "Review your subscription" : pending ? "Finish your payment" :
                    "More room for your voice")
                    .font(.title2.weight(.semibold))
                Text(pending ? "Your payment has not been confirmed. Continue the original checkout or check its status below."
                    : "Choose Pro for cloud transcription beyond the free allowance.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !reviewing, !pending {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(state.plans) { plan in
                        Button { interval = plan.billingInterval } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(plan.billingInterval == .yearly ? "Annual" : "Monthly").font(.headline)
                                    Spacer(minLength: 4)
                                    Image(systemName: interval == plan
                                        .billingInterval ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(interval == plan.billingInterval ? Color
                                            .accentColor : .secondary)
                                }
                                Text(plan.formattedPrice).font(.title2.weight(.semibold))
                                Text(plan.billingInterval == .yearly ? "Billed once per year" : "Billed every month")
                                    .font(.callout).foregroundStyle(.secondary)
                                if plan.billingInterval == .yearly, state.hasTwoMonthsFree {
                                    Text("2 months free").font(.callout.weight(.medium))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            .background(
                                interval == plan.billingInterval ? Color.accentColor.opacity(0.08) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(
                                    interval == plan.billingInterval ? Color.accentColor : Color.secondary.opacity(0.3),
                                    lineWidth: interval == plan.billingInterval ? 2 : 1
                                ))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                            .accessibilityLabel(
                                "\(plan.billingInterval == .yearly ? "Annual" : "Monthly"), \(plan.formattedPrice), \(plan.billingInterval == .yearly ? "per year" : "per month")"
                            )
                            .accessibilityAddTraits(interval == plan.billingInterval ? .isSelected : [])
                            .accessibilityIdentifier("billing.plan.\(plan.billingInterval.rawValue)")
                            .disabled(isLoading)
                    }
                }
            }
            if let selected {
                if reviewing || pending {
                    LabeledContent("Payment period", value: effectiveInterval == .yearly ? "12 months" : "1 month")
                    if !pending || state.pendingPlan != nil {
                        LabeledContent("Total payment", value: selected.formattedPrice).font(.headline)
                    }
                }
                if pending, state.pendingPlan == nil {
                    Text(
                        "Review the original amount and renewal terms on WayForPay before paying. This checkout keeps its original price."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(
                        "\(selected.formattedPrice) charged \(effectiveInterval == .yearly ? "once a year" : "each month"). Renews automatically. Cancel renewal at any time in Account; access stays available until the paid period ends."
                    )
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if reviewing {
                    Text(
                        "Payment opens in your browser. Pro activates after payment is confirmed. Return here to check the status."
                    )
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if checkoutAvailable {
                    HStack(spacing: 12) {
                        Button(reviewing || pending ? "Continue to WayForPay" :
                            "Review \(interval == .yearly ? "annual" : "monthly") plan")
                        {
                            if reviewing || pending { checkout(effectiveInterval) } else { reviewing = true }
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                            .accessibilityIdentifier("billing.continue").disabled(isLoading)
                        if reviewing, !pending {
                            Button("Back to plans") { reviewing = false }.disabled(isLoading)
                        }
                    }
                } else {
                    Label("Payments are temporarily unavailable. You can keep using the free plan and local models.",
                          systemImage: "clock")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("billing.unavailable")
                }
            } else {
                Text("Prices could not be loaded. Check payment status to try again.").foregroundStyle(.secondary)
            }
        }
        .onChange(of: interval) { _, _ in reviewing = false }
    }
}
