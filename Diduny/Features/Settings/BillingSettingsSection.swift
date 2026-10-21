import AppKit
import SwiftUI
import WebKit

@Observable
@MainActor
final class BillingOfferNavigation {
    enum PrimaryAction { case compare, continueFree, checkout }
    var showsPlans = false
    var reviewing = false
    var interval: BillingInterval = .monthly
    var product: BillingProduct = .pro
    var paymentMode: BillingPaymentMode = .recurring
    var primaryAction: PrimaryAction { reviewing ? .checkout : showsPlans ? .continueFree : .compare }
    func comparePlans() { showsPlans = true; reviewing = false }
    func purchaseSelection(_ state: BillingState) -> (product: BillingProduct, interval: BillingInterval, paymentMode: BillingPaymentMode) {
        if state.pendingOrderReference != nil {
            return (state.pendingPlan?.product ?? .pro,
                    state.pendingPlan?.billingInterval ?? state.pendingBillingInterval ?? interval,
                    state.pendingPlan?.paymentMode ?? .recurring)
        }
        return (product, product == .support ? .monthly : interval, product == .support ? .recurring : paymentMode)
    }
    func selectedPlan(_ state: BillingState) -> BillingPlan? {
        if let pending = state.pendingPlan, state.pendingOrderReference != nil { return pending }
        let selection = purchaseSelection(state)
        if selection.product == .support { return state.supportPlan }
        if selection.paymentMode == .oneTime { return state.oneTimeAnnualPlan }
        return state.plans.first { $0.billingInterval == selection.interval }
    }

}

@MainActor
struct BillingSettingsSection: View {
    let isLoggedIn: Bool
    @Environment(AppState.self) private var appState
    @State private var billing = BillingService()
    @State private var navigation: BillingOfferNavigation
    @State private var confirmsCancellation = false
    @State private var showsPolicies = false
    @State private var showsUpgrade = false
    @State private var confirmsPlanChange = false

    init(isLoggedIn: Bool, billing: BillingService? = nil, navigation: BillingOfferNavigation? = nil) {
        self.isLoggedIn = isLoggedIn
        _billing = State(initialValue: billing ?? BillingService())
        _navigation = State(initialValue: navigation ?? BillingOfferNavigation())
    }

    var body: some View {
        Section("Plans & billing") {
            VStack(alignment: .leading, spacing: 18) {
                if isLoggedIn, let state = billing.state {
                    if state.pendingOrderReference == nil && (state.plan == "pro" || (state.plan == "support" && !showsUpgrade)) {
                        subscription(state)
                    }
                    if state.pendingOrderReference != nil {
                        Button("Change plan") { confirmsPlanChange = true }.disabled(billing.isLoading)
                    }
                    BillingOfferView(state: state, interval: Binding(get: { navigation.interval }, set: { navigation.interval = $0 }),
                                         checkoutAvailable: billing.checkoutAvailable,
                                         isLoading: billing.isLoading, initialSelection: appState.billingSelection, navigation: navigation)
                        { chosen, mode, product in
                            Task {
                                if let url = await billing.checkout(chosen, paymentMode: mode, product: product) {
                                    NSWorkspace.shared.open(url)
                                    await billing.refresh()
                                }
                            }
                        }
                } else if isLoggedIn {
                    Label(billing.isLoading ? "Loading subscription…" : "Subscription could not be loaded",
                          systemImage: "cloud")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Dictate. Follow meetings. Translate live.").font(.title3.weight(.semibold))
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
            if let pending { navigation.interval = pending }
        }
        .onChange(of: billing.state?.pendingOrderReference) { _, pending in
            if pending != nil { navigation.showsPlans = true; navigation.reviewing = true }
            else { navigation.comparePlans() }
        }
        .onChange(of: billing.state?.plan) { _, plan in
            if let plan, ["support", "pro"].contains(plan), billing.state?.pendingOrderReference == nil {
                navigation.comparePlans()
            }
        }
        .task(id: isLoggedIn) {
            billing.reset()
            if isLoggedIn { await billing.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if isLoggedIn { Task { await refresh(sync: billing.checkoutAvailable) } }
        }
        .confirmationDialog("Cancel this unpaid checkout?", isPresented: $confirmsPlanChange) {
            Button("Change plan") { Task { _ = await billing.abandonCheckout() } }
        } message: {
            Text("The server checks payment status first. Payments already processing must finish. Close the old payment tab before choosing another plan.")
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
        Label(
            state.status == "past_due" ? "Your renewal needs attention" : state
                .plan == "support" ? "Thank you for supporting Diduny" : "Diduny Pro is active",
            systemImage: state.status == "past_due" ? "exclamationmark.circle" : "checkmark.circle.fill"
        )
        .font(.title3.weight(.semibold))
        .foregroundStyle(state.status == "past_due" ? Color.orange : Color.green)
        if state.status == "past_due" {
            Text(
                "The renewal payment has not been confirmed. Your paid membership remains available during a short grace period. Check payment status below or contact support."
            )
            .font(.callout).foregroundStyle(.secondary)
            Link("Contact support", destination: URL(string: "mailto:roman@rmarinsky.com.ua")!)
        }
        if state.plan == "support" {
            Text("Pro is a separate purchase. Starting its checkout stops Support renewal. Pro begins after payment confirmation; the current Support payment is not credited.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Explore Pro plans") { showsUpgrade = true }
        }
        if state.community?.eligible == true {
            if let url = state.community?.inviteURL {
                Link("Join the supporter community", destination: url)
            } else {
                Text("Your community invitation is being prepared.").font(.callout).foregroundStyle(.secondary)
            }
            Link(
                "Suggest a feature",
                destination: URL(string: "mailto:roman@rmarinsky.com.ua?subject=Diduny%20feature%20suggestion")!
            )
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
                        NSWorkspace.shared.open(url)
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
    var initialSelection: BillingSelection?
    var navigation: BillingOfferNavigation = BillingOfferNavigation()
    let checkout: (BillingInterval, BillingPaymentMode, BillingProduct) -> Void
    private var reviewing: Bool { get { navigation.reviewing } nonmutating set { navigation.reviewing = newValue } }
    private var showsPlans: Bool { get { navigation.showsPlans } nonmutating set { navigation.showsPlans = newValue } }
    private var paymentMode: BillingPaymentMode { get { navigation.paymentMode } nonmutating set { navigation.paymentMode = newValue } }
    private var product: BillingProduct { get { navigation.product } nonmutating set { navigation.product = newValue } }
    @State private var showsLifetime = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selected: BillingPlan? { navigation.selectedPlan(state) }
    private var effectiveProduct: BillingProduct { navigation.purchaseSelection(state).product }
    private var effectiveMode: BillingPaymentMode { navigation.purchaseSelection(state).paymentMode }
    private var effectiveInterval: BillingInterval { navigation.purchaseSelection(state).interval }

    private var pending: Bool {
        state.pendingOrderReference != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(pending ? "Finish your payment" : reviewing ? "Review your purchase" :
                    "Dictate. Follow meetings. Translate live.")
                    .font(.title2.weight(.semibold))
                Text(pending ? "Your payment has not been confirmed. Continue the original checkout or check its status below."
                    : "All local processing is free and unlimited. Pro includes unlimited cloud processing.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !showsPlans, !reviewing, !pending, !["support", "pro"].contains(state.plan) {
                VStack(alignment: .leading, spacing: 18) {
                    benefit(
                        "Words appear as you speak",
                        "Dictate into the app you use and follow the cloud transcript while recording.",
                        icon: "text.cursor"
                    )
                    benefit(
                        "Follow the conversation live",
                        "See a live meeting transcript and return to your recording later.",
                        icon: "text.bubble"
                    )
                    benefit(
                        "Translate while you talk",
                        "Read live voice and meeting translations for languages supported by the cloud model.",
                        icon: "character.bubble"
                    )
                    Text(
                        "Local dictation, meetings, audio, video and YouTube transcription have no usage quota. Performance depends on your Mac and model."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    DidunyPrimaryButton(title: "Compare Free, Support and Pro", isEnabled: !isLoading) { navigation.comparePlans() }
                        .accessibilityIdentifier("billing.explore")
                }
            }
            if showsPlans || reviewing || pending || ["support", "pro"].contains(state.plan) {
                if !pending, !["support", "pro"].contains(state.plan) {
                    Button("Back to benefits") { showsPlans = false; reviewing = false }.buttonStyle(.link)
                }
                HStack {
                    Picker("Payment period", selection: $interval) {
                        Text("Monthly").tag(BillingInterval.monthly)
                        Text("Annual").tag(BillingInterval.yearly)
                    }.pickerStyle(.segmented)
                    Button("Lifetime · concept") { showsLifetime = true }
                        .popover(isPresented: $showsLifetime) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Lifetime is being considered").font(.headline)
                                Text(
                                    "The price and cloud allowance for a one-time lifetime license are not approved. This is not an available payment plan."
                                )
                            }.padding().frame(width: 300)
                        }
                }
                if state.hasTwoMonthsFree,
                   interval == .yearly { Text("2 months free").foregroundStyle(Color.accentColor) }
                planComparison
                Text("The period selector applies to Pro. Support remains monthly.").font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    "Free and Support include two shared cloud hours per calendar month for dictation, meeting transcription and speech translation."
                )
                .font(.callout).foregroundStyle(.secondary)
                DisclosureGroup("Compare local and cloud processing") { comparison }
                if let oneTime = state.oneTimeAnnualPlan {
                    DisclosureGroup("Prefer no automatic renewal?") {
                        Text("One-time annual Pro. No automatic renewal.").font(.callout)
                        Button(oneTime.formattedPrice) {
                            product = .pro; interval = .yearly; paymentMode = .oneTime; reviewing = true
                        }.accessibilityIdentifier("billing.plan.one_time").disabled(isLoading)
                    }
                }
            }
            if reviewing || pending {
                if let selected {
                    if reviewing || pending {
                        LabeledContent(
                            "Plan",
                            value: effectiveProduct == .support ? String(localized: "Support development") :
                                String(localized: "Diduny Pro")
                        )
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
                            "By continuing, you accept the terms for this plan and acknowledge the Privacy Policy. Optional usage statistics stay off unless you separately enable them in Account. Payment opens in your browser. Return here after payment to check your access."
                        )
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if checkoutAvailable {
                        HStack(spacing: 12) {
                            Button(reviewing || pending ? "Continue to WayForPay" :
                                (interval == .yearly ? "Review annual plan" : "Review monthly plan"))
                            {
                                if reviewing || pending { checkout(effectiveInterval, effectiveMode, effectiveProduct) }
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
        .task(id: initialSelection) {
            guard !pending, let selection = initialSelection else { return }
            product = selection.product; interval = selection.interval; paymentMode = selection.paymentMode
            showsPlans = true; reviewing = true
        }
    }

    private var planComparison: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    Text("Feature").bold().frame(width: 190, alignment: .leading)
                    column("Free", price: String(localized: "Free"))
                    column("Support development", price: state.supportPlan?.formattedPrice ?? "—")
                    column("Diduny Pro", price: state.plans.first { $0.billingInterval == interval }?.formattedPrice ?? "—", highlighted: true)
                }
                comparisonRow("Unlimited local models", "Unlimited", "Unlimited", "Unlimited")
                comparisonRow("Voice to text in your Mac apps", "Included", "Included", "Included")
                comparisonRow("Meeting recordings and local live preview", "Included", "Included", "Included")
                comparisonRow("Local audio, video and YouTube transcription", "Included", "Included", "Included")
                comparisonRow("Local speech translation into English", "Included", "Included", "Included")
                comparisonRow("Message formatting and transcript cleanup", "Included", "Included", "Included")
                comparisonRow("Cloud processing", "2 shared hours / month", "2 shared hours / month", "Unlimited")
                comparisonRow("Live meeting transcription", "Within cloud allowance", "Within cloud allowance", "Included")
                comparisonRow("Live voice and meeting translation", "Within cloud allowance", "Within cloud allowance", "Included")
                comparisonRow("Community participation and feature discussions", "—", "Invitation pending", "Invitation pending")
                GridRow {
                    Text("Choose a plan").frame(width: 190, alignment: .leading)
                    Button("Keep using Free") { showsPlans = false; reviewing = false }.frame(width: 125)
                    Button("Choose Support") { product = .support; paymentMode = .recurring; reviewing = true }
                        .frame(width: 125).disabled(isLoading || pending || state.supportPlan == nil || ["support","pro"].contains(state.plan))
                    Button("Choose Pro") { product = .pro; paymentMode = .recurring; reviewing = true }
                        .buttonStyle(.borderedProminent).tint(.blue)
                        .frame(width: 125).disabled(isLoading || pending || state.plan == "pro")
                }
            }.padding(16)
        }
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("billing.planComparison")
    }

    private func column(_ title: LocalizedStringKey, price: String, highlighted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(price).font(.headline)
        }.padding(10).frame(width: 125, alignment: .leading)
            .background(highlighted ? Color.blue.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(highlighted ? Color.blue.opacity(0.7) : Color.clear))
    }

    private func comparisonRow(_ title: LocalizedStringKey, _ free: LocalizedStringKey,
                               _ support: LocalizedStringKey, _ pro: LocalizedStringKey) -> some View {
        GridRow {
            Text(title).frame(width: 190, alignment: .leading)
            Text(free).frame(width: 125, alignment: .leading)
            Text(support).frame(width: 125, alignment: .leading)
            Text(pro).padding(.vertical, 7).padding(.horizontal, 8).frame(width: 125, alignment: .leading)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
        }.font(.callout)
    }

    private var comparison: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow { Text("Feature").bold(); Text("Local models").bold(); Text("Cloud models").bold() }
            GridRow { Text("Transcription"); Text("Unlimited local processing"); Text("Live text as you speak") }
            GridRow { Text("Meetings"); Text("Recording and optional live preview"); Text("Live meeting transcription")
            }
            GridRow {
                Text("Voice translation"); Text("Into English with multilingual Whisper"); Text(
                    "Live translation for supported languages"
                )
            }
            GridRow {
                Text("Meeting translation"); Text("Cloud processing required for live translation"); Text(
                    "Live meeting translation"
                )
            }
            GridRow {
                Text("Audio, video and YouTube"); Text("Local processing without a usage quota"); Text(
                    "Imported media currently uses local models"
                )
            }
        }.font(.caption).padding(.vertical, 10)
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
