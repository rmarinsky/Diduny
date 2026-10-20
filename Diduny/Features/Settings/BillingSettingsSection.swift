import AppKit
import SwiftUI
import WebKit

@MainActor
struct BillingSettingsSection: View {
    let isLoggedIn: Bool
    @State private var billing = BillingService()
    @State private var interval: BillingInterval = .yearly
    @State private var confirmsCancellation = false
    @State private var showsPolicies = false
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
                        { chosen, mode in
                            Task {
                                if let url = await billing.checkout(chosen, paymentMode: mode) {
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
                    Button("Terms, refunds & privacy") { showsPolicies = true }
                        .buttonStyle(.link)
                    Spacer()
                    if isLoggedIn {
                        if billing.isLoading { ProgressView().controlSize(.small) }
                        Button("Check payment status") { Task { await refresh(sync: billing.checkoutAvailable) } }
                            .disabled(billing.isLoading)
                    }
                }.font(.callout)
            }.padding(.vertical, 8)
        }
        .sheet(isPresented: $showsPolicies) { BillingPolicySheet() }
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
        LabeledContent(
            "Subscription",
            value: state.billingInterval == .yearly ? String(localized: "Annual") : String(localized: "Monthly")
        )
        if let date = displayDate(state.activeUntil) { LabeledContent(
            state.status == "past_due" ? "Last paid period ended" : "Access until",
            value: date
        ) }
        if state.paymentMode == .oneTime {
            Text("One-time purchase. No automatic renewal or further subscription charges.")
                .font(.callout).foregroundStyle(.secondary)
        } else if state.cancelAtPeriodEnd {
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
    let checkout: (BillingInterval, BillingPaymentMode) -> Void
    @State private var reviewing = false
    @State private var showsPlans = false
    @State private var paymentMode: BillingPaymentMode = .recurring
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selected: BillingPlan? {
        if pending, let plan = state.pendingPlan { return plan }
        if paymentMode == .oneTime { return state.oneTimeAnnualPlan }
        return state.plans.first { $0.billingInterval == effectiveInterval }
    }

    private var effectiveMode: BillingPaymentMode {
        pending ? state.pendingPlan?.paymentMode ?? .recurring : paymentMode
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
                Text(reviewing ? "Review your purchase" : pending ? "Finish your payment" :
                    "More room for your voice")
                    .font(.title2.weight(.semibold))
                Text(pending ? "Your payment has not been confirmed. Continue the original checkout or check its status below."
                    : "Choose Pro for cloud transcription beyond the free allowance.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !showsPlans, !pending {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 52)).foregroundStyle(Color.accentColor.gradient)
                        .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                        .accessibilityHidden(true)
                    benefit(
                        "Keep your train of thought",
                        "Dictate longer without the free cloud allowance interrupting you.",
                        icon: "text.cursor"
                    )
                    benefit(
                        "Make conversations useful",
                        "Turn meeting recordings and audio files into text with cloud transcription.",
                        icon: "text.bubble"
                    )
                    benefit(
                        "Choose the way you work",
                        "Pro removes the cloud time limit. Local models remain free and unlimited.",
                        icon: "cloud"
                    )
                    Text(
                        "Occasional use? Your 2 free cloud hours each month may be enough. Choose Pro when you need more."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    Button("Explore Pro plans") { showsPlans = true }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .accessibilityIdentifier("billing.explore")
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            if showsPlans, !reviewing, !pending {
                Button("Back to benefits") { showsPlans = false }.buttonStyle(.link)
                HStack(alignment: .top, spacing: 12) {
                    ForEach(state.plans) { plan in
                        Button { paymentMode = .recurring; interval = plan.billingInterval } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(plan.billingInterval == .yearly ? "Annual" : "Monthly").font(.headline)
                                    Spacer(minLength: 4)
                                    Image(systemName: paymentMode == .recurring && interval == plan
                                        .billingInterval ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(paymentMode == .recurring && interval == plan
                                            .billingInterval ? Color
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
                                paymentMode == .recurring && interval == plan.billingInterval ? Color.accentColor
                                    .opacity(0.08) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(
                                    paymentMode == .recurring && interval == plan.billingInterval ? Color
                                        .accentColor : Color.secondary.opacity(0.3),
                                    lineWidth: paymentMode == .recurring && interval == plan.billingInterval ? 2 : 1
                                ))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                            .accessibilityLabel(
                                "\(plan.billingInterval == .yearly ? String(localized: "Annual") : String(localized: "Monthly")), \(plan.formattedPrice), \(plan.billingInterval == .yearly ? String(localized: "per year") : String(localized: "per month"))"
                            )
                            .accessibilityAddTraits(paymentMode == .recurring && interval == plan
                                .billingInterval ? .isSelected : [])
                            .accessibilityIdentifier("billing.plan.\(plan.billingInterval.rawValue)")
                            .disabled(isLoading)
                    }
                }
            }
            if showsPlans, !reviewing, !pending, let annual = state.oneTimeAnnualPlan {
                Button { interval = .yearly; paymentMode = .oneTime } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("One year, no renewal").font(.headline)
                            Text("\(annual.formattedPrice) once · 12 months of Pro").font(.callout)
                            Text("More payment methods, including up to 3 bank payments where available.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: paymentMode == .oneTime ? "checkmark.circle.fill" : "circle")
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Color.accentColor.opacity(paymentMode == .oneTime ? 0.08 : 0),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(paymentMode == .oneTime ? Color.accentColor : Color.secondary.opacity(0.3)))
                }.buttonStyle(.plain).disabled(isLoading)
                    .accessibilityIdentifier("billing.plan.one_time")
                    .accessibilityAddTraits(paymentMode == .oneTime ? .isSelected : [])
                Text(
                    "Monthly for flexibility. Annual for regular use. One-time annual if you prefer to decide again next year."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            if showsPlans || pending {
                if let selected {
                    if reviewing || pending {
                        LabeledContent(
                            "Payment period",
                            value: effectiveInterval == .yearly ? String(localized: "12 months") :
                                String(localized: "1 month")
                        )
                        if !pending || state.pendingPlan != nil {
                            LabeledContent("Total payment", value: selected.formattedPrice).font(.headline)
                        }
                    }
                    if pending, state.pendingPlan == nil {
                        Text(
                            "Review the original amount and renewal terms on WayForPay before paying. This checkout keeps its original price."
                        )
                        .font(.callout).foregroundStyle(.secondary)
                    } else if effectiveMode == .oneTime {
                        Text(
                            "\(selected.formattedPrice) paid once for 12 months. No automatic renewal. Bank installment payments, if selected, follow the bank’s schedule and do not renew Pro."
                        )
                        .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(
                            "\(selected.formattedPrice) charged \(effectiveInterval == .yearly ? String(localized: "once a year") : String(localized: "each month")). Renews automatically. Cancel renewal at any time in Account; access stays available until the paid period ends."
                        )
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if reviewing {
                        Text(
                            "By continuing, you accept the Diduny Pro terms for this plan and acknowledge the Privacy Policy. Optional usage statistics stay off unless you separately enable them in Account. Payment opens in your browser. Return here after payment to check your access."
                        )
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if checkoutAvailable {
                        HStack(spacing: 12) {
                            Button(reviewing || pending ? "Continue to WayForPay" :
                                (interval == .yearly ? "Review annual plan" : "Review monthly plan"))
                            {
                                if reviewing || pending { checkout(effectiveInterval, effectiveMode) }
                                else { reviewing = true }
                            }.buttonStyle(.borderedProminent).controlSize(.large)
                                .accessibilityIdentifier("billing.continue").disabled(isLoading)
                            if reviewing, !pending {
                                Button("Back to plans") { reviewing = false }.disabled(isLoading)
                            }
                        }
                    } else {
                        Label(
                            "Payments are temporarily unavailable. You can keep using the free plan and local models.",
                            systemImage: "clock"
                        )
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("billing.unavailable")
                    }
                } else {
                    Text("Prices could not be loaded. Check payment status to try again.").foregroundStyle(.secondary)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: showsPlans)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: reviewing)
        .onChange(of: interval) { _, _ in reviewing = false }
    }

    private func benefit(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor).frame(width: 25)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

@MainActor
private struct BillingPolicySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Terms, refunds & privacy").font(.headline)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            Divider()
            if failed {
                ContentUnavailableView {
                    Label("Could not load the policy", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Check your connection and try again.")
                } actions: {
                    Button("Try again") { failed = false; loading = true; attempt += 1 }
                }
            } else {
                BillingPolicyWebView(loading: $loading, failed: $failed).id(attempt)
            }
        }.frame(width: 680, height: 600)
    }
}

@MainActor
private struct BillingPolicyWebView: NSViewRepresentable {
    @Binding var loading: Bool
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: BillingService.publicPolicyURL, timeoutInterval: 20))
        return view
    }

    func updateNSView(_: WKWebView, context _: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator _: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: BillingPolicyWebView
        init(parent: BillingPolicyWebView) {
            self.parent = parent
        }

        func webView(_: WKWebView, didFinish _: WKNavigation!) {
            parent.loading = false
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError _: Error) {
            parent.loading = false; parent.failed = true
        }

        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
            parent.loading = false; parent.failed = true
        }

        func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void)
        {
            guard let url = action.request.url,
                  url.scheme == "https", url.host == "rmarinsky.com.ua",
                  url.user == nil, url.password == nil, url.port == nil || url.port == 443
            else {
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }

        func webView(_: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void)
        {
            if let http = response.response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                parent.loading = false; parent.failed = true; decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
    }
}
