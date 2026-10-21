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
        return (product, product != .pro ? .monthly : interval, product != .pro ? .recurring : paymentMode)
    }
    func selectedPlan(_ state: BillingState) -> BillingPlan? {
        if let pending = state.pendingPlan, state.pendingOrderReference != nil { return pending }
        let selection = purchaseSelection(state)
        if selection.product == .support { return state.supportPlan }
        if selection.product == .cloud { return state.cloudPlan }
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
                    if state.pendingOrderReference == nil && (state.plan == "pro" || (["support", "cloud"].contains(state.plan) && !showsUpgrade)) {
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
            if let plan, ["support", "cloud", "pro"].contains(plan), billing.state?.pendingOrderReference == nil {
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
                .plan == "support" ? "Thank you for supporting Diduny" : state.plan == "cloud" ? "Diduny Cloud is active" : "Diduny Pro is active",
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
        if ["support", "cloud"].contains(state.plan) {
            Text("A higher plan is a separate purchase. Starting checkout stops the current renewal. Your new plan begins after payment confirmation; the previous payment is not credited.")
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

            if !showsPlans, !reviewing, !pending, !["support", "cloud", "pro"].contains(state.plan) {
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
                    DidunyPrimaryButton(title: "Compare Free, Support, Cloud and Pro", isEnabled: !isLoading) { navigation.comparePlans() }
                        .accessibilityIdentifier("billing.explore")
                }
            }
            if showsPlans || reviewing || pending || ["support", "cloud", "pro"].contains(state.plan) {
                if !pending, !["support", "cloud", "pro"].contains(state.plan) {
                    Button("Back to benefits") { showsPlans = false; reviewing = false }.buttonStyle(.link)
                }
                HStack {
                    Picker("Payment period", selection: $interval) {
                        Text("Monthly").tag(BillingInterval.monthly)
                        Text("Annual").tag(BillingInterval.yearly)
                    }.pickerStyle(.segmented)

                }
                if state.hasTwoMonthsFree,
                   interval == .yearly { Text("2 months free").foregroundStyle(Color.accentColor) }
                planComparison
                Text("The period selector applies to Pro. Support and Cloud remain monthly.").font(.caption)
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
                                effectiveProduct == .cloud ? String(localized: "Diduny Cloud") : String(localized: "Diduny Pro")
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
        VStack(alignment: .leading, spacing: 16) {
            if let contrast = priceContrast {
                VStack(alignment: .leading, spacing: 6) {
                    Text(contrast.title).font(.headline)
                    Text(contrast.detail).font(.caption).foregroundStyle(.secondary)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    offerCard(title: "Free", price: Decimal(0).formatted(.currency(code: "UAH")), bill: "No payment required",
                        detail: "All local processing is free.", quota: "2 shared cloud hours / month",
                        items: ["Unlimited local models", "Dictation, meetings and files", "Cloud features within 2 hours"],
                        action: "Keep using Free", chosen: nil)
                    offerCard(title: "Support", price: state.supportPlan?.formattedPrice ?? "—", bill: "Billed monthly",
                        detail: "For people who have enough with local models.", quota: "2 shared cloud hours / month",
                        items: ["Everything in Free", "Support independent development", "Community invitation pending", "Suggest and discuss new features"],
                        action: "Choose Support", chosen: .support)
                    offerCard(title: "Cloud", price: state.cloudPlan?.formattedPrice ?? "—", bill: "Billed monthly",
                        detail: "Cloud for occasional use.", quota: "10 shared cloud hours / calendar month",
                        items: ["Unlimited local models", "Live text and speech translation", "10 hours shared by all cloud features"],
                        action: "Choose Cloud", chosen: .cloud)
                    offerCard(title: "Diduny Pro", price: proDisplayPrice, bill: proBillingDescription,
                        detail: "For everyday work with cloud models.", quota: "Cloud without an hourly limit",
                        items: ["All Cloud features", "No hourly quota", "Community invitation pending", "Suggest and discuss new features"],
                        action: "Choose Pro", chosen: .pro)
                }.padding(2)
            }.accessibilityIdentifier("billing.planComparison")
        }
    }

    private var priceContrast: (title: String, detail: String)? {
        guard let cloud = state.cloudPlan,
              let pro = state.plans.first(where: { $0.billingInterval == interval }),
              cloud.currency == pro.currency, cloud.amount > 0, pro.amount > 0 else { return nil }
        let equivalent = interval == .yearly ? pro.amount / 12 : pro.amount
        let delta = equivalent - cloud.amount
        guard delta > 0 else { return nil }
        let format = { (value: Decimal) in value.formatted(.currency(code: pro.currency)) }
        let extra = format(delta), cloudPrice = cloud.formattedPrice
        let proPrice = format(equivalent), total = pro.formattedPrice
        if interval == .monthly {
            return (String(localized: "Just \(extra) more per month for cloud without an hourly limit"),
                    String(localized: "Cloud: \(cloudPrice) for 10 hours. Pro: \(proPrice) without an hourly quota."))
        }
        return (String(localized: "Annual Pro: \(proPrice) per month, billed \(total) yearly"),
                String(localized: "\(extra) more per month than Cloud in equivalent cost. Pay \(total) upfront for the year."))
    }

    private var proBillingDescription: LocalizedStringKey {
        let total = state.plans.first { $0.billingInterval == interval }?.formattedPrice ?? "—"
        return interval == .yearly ? "\(total) billed yearly. Renews yearly." : "\(total) billed monthly. Renews monthly."
    }

    private var proDisplayPrice: String {
        guard let plan = state.plans.first(where: { $0.billingInterval == interval }) else { return "—" }
        let amount = interval == .yearly ? plan.amount / 12 : plan.amount
        return amount.formatted(.currency(code: plan.currency))
    }

    private func offerCard(title: LocalizedStringKey, price: String, bill: LocalizedStringKey,
                           detail: LocalizedStringKey, quota: LocalizedStringKey,
                           items: [LocalizedStringKey], action: LocalizedStringKey,
                           chosen: BillingProduct?) -> some View {
        let highlighted = chosen == .pro
        let unavailable = chosen == .support ? state.supportPlan == nil : chosen == .cloud ? state.cloudPlan == nil : false
        let activeBlocked = state.plan == "pro" || state.plan == chosen?.rawValue || (state.plan == "cloud" && chosen == .support)
        return VStack(alignment: .leading, spacing: 14) {
            Text(highlighted ? "No hourly limit" : " ").font(.caption).foregroundStyle(.secondary).frame(height: 16)
            Text(title).font(.headline).frame(height: 38, alignment: .topLeading)
            Text(price).font(.title2.weight(.semibold))
            Text(chosen == nil ? " " : "per month").font(.caption).foregroundStyle(.secondary)
            Text(bill).font(.caption).foregroundStyle(.secondary).frame(height: 48, alignment: .topLeading)
            Text(detail).font(.callout).foregroundStyle(.secondary).frame(height: 62, alignment: .topLeading)
            Text(quota).font(.callout.weight(.semibold)).frame(height: 50, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(height: 155, alignment: .topLeading)
            if highlighted {
                DidunyPrimaryButton(title: action, isEnabled: !isLoading && !pending && !activeBlocked && !unavailable) {
                    product = .pro; paymentMode = .recurring; reviewing = true
                }
            } else {
                Button(action) {
                    if let chosen { product = chosen; paymentMode = .recurring; reviewing = true }
                    else { showsPlans = false; reviewing = false }
                }.buttonStyle(.bordered).disabled(chosen != nil && (isLoading || pending || activeBlocked || unavailable))
            }
        }.padding(14).frame(width: 160, alignment: .leading)
            .background(highlighted ? Color.blue.opacity(0.22) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(highlighted ? Color.blue.opacity(0.65) : Color.secondary.opacity(0.18)))
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
