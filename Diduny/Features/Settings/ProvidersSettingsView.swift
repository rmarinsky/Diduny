import AppKit
import SwiftUI

/// Settings > Providers: built-in engines, bring-your-own-key provider cards, engine for each mode.
struct ProvidersSettingsView: View {
    @State private var resetJobs: [STTJob] = []
    private let registry = ProviderRegistry.shared

    var body: some View {
        PageScaffold(title: "Providers") {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                if !resetJobs.isEmpty {
                    Card {
                        HStack(alignment: .top) {
                            Label(
                                String(format: String(localized: "The key was removed. %@ now use Diduny Cloud."), Self.jobList(resetJobs)),
                                systemImage: "info.circle"
                            )
                            .font(DS.Font.body)
                            Spacer()
                            Button {
                                resetJobs = []
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Dismiss"))
                        }
                    }
                }

                EnginesByModeSection()

                // Parakeet V3 and Apple Speech get their Providers column at WP-56; until then this page is unchanged.
                ForEach(registry.modules.filter { !STTProviderID.onDeviceEngines.contains($0.id) }, id: \.id) { module in
                    if module.requiresKey {
                        ByokProviderSection(module: module, onRemoved: { resetJobs = $0 })
                    } else {
                        builtInSection(module)
                    }
                }
            }
        }
    }

    private func providerRow(_ content: some View) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
    }

    @ViewBuilder
    private func builtInSection(_ module: any STTProviderModule) -> some View {
        let isLocal = module.id == STTProviderID.localWhisper
        SettingsGroup(title: LocalizedStringKey(module.displayName)) {
            ProviderStatusPill(
                text: isLocal ? String(localized: "On this Mac") : String(localized: "Built in"),
                systemImage: isLocal ? "desktopcomputer" : "cloud",
                color: .secondary
            )
        } content: {
            providerRow(
                Text(isLocal ? "Audio never leaves your Mac." : "Included with your account. No key needed.")
                    .font(DS.Font.callout)
                    .foregroundStyle(.secondary)
            )
            ForEach(module.models, id: \.id) { model in
                RowSeparator()
                providerRow(ChipRow(chips: CapabilityChip.chips(for: model, requiresKey: false)))
            }
            RowSeparator()
            providerRow(
                Button(isLocal ? "Manage models" : "Account and quota") {
                    MainWindowController.shared.showWindow(section: isLocal ? .models : .account)
                }
                .buttonStyle(.bordered)
            )
        }
    }

    static func jobName(_ job: STTJob) -> String {
        switch job {
        case .dictation: String(localized: "Dictation")
        case .dictationTranslation: String(localized: "Dictation translation")
        case .meeting: String(localized: "Meetings")
        case .meetingTranslation: String(localized: "Meeting translation")
        case .file: String(localized: "File transcription")
        }
    }

    static func jobList(_ jobs: [STTJob]) -> String {
        ListFormatter.localizedString(byJoining: jobs.map(jobName))
    }
}

struct ProviderStatusPill: View {
    let text: String
    let systemImage: String?
    let color: Color
    var isLoading = false

    var body: some View {
        HStack(spacing: 3) {
            if isLoading {
                ProgressView().controlSize(.mini)
            } else if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text).fixedSize()
        }
        .font(DS.Font.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }
}

private struct ChipRow: View {
    let chips: [(String, Bool)]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { content }
            VStack(alignment: .leading, spacing: 4) { content }
        }
    }

    @ViewBuilder private var content: some View {
        ForEach(chips, id: \.0) { chip in
            CapabilityChip(text: chip.0, available: chip.1)
        }
    }
}

// MARK: - BYOK provider card

private struct ByokProviderSection: View {
    enum Status: Equatable {
        case noKey, saved, testing, ok(String), failed(ElevenLabsError)
    }

    enum UsageState: Equatable {
        case hidden, loading, loaded(ProviderUsage), unavailable
    }

    let module: any STTProviderModule
    let onRemoved: ([STTJob]) -> Void

    @State private var keyInput = ""
    @State private var reveal = false
    @State private var isReplacing = false
    @State private var saveFailed = false
    @State private var status: Status = .noKey
    @State private var usage: UsageState = .hidden
    @State private var maskedKey: String?
    @State private var confirmRemove = false
    @State private var showDefaultsSheet = false
    @State private var guidanceExpanded = false

    private let keyStore = ProviderKeyStore.shared
    private static let dashboardURL = URL(string: "https://elevenlabs.io/app")!

    private var account: ElevenLabsAccountService {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return ElevenLabsAccountService(session: URLSession(configuration: config))
    }

    private func row(_ content: some View) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
    }

    var body: some View {
        SettingsGroup(title: LocalizedStringKey(module.displayName)) {
            pill
        } content: {
            row(keyRow)
            if saveFailed {
                RowSeparator()
                row(Text("Couldn't save the key to Keychain.").font(DS.Font.callout).foregroundStyle(.red))
            }
            if maskedKey != nil, !isReplacing {
                RowSeparator()
                row(
                    HStack {
                        Button("Test connection") { Task { await test() } }
                            .buttonStyle(.bordered)
                            .disabled(status == .testing)
                        Spacer()
                        Button("Remove", role: .destructive) { confirmRemove = true }
                            .buttonStyle(.bordered)
                    }
                )
                if let detail = statusDetail {
                    RowSeparator()
                    if case .failed = status {
                        row(Banner(message: Text(detail)))
                    } else {
                        row(Text(detail).font(DS.Font.callout).foregroundStyle(.secondary))
                    }
                }
                if showsDashboardLink {
                    RowSeparator()
                    row(
                        Link("Open ElevenLabs dashboard", destination: Self.dashboardURL)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    )
                }
                if usage != .hidden {
                    RowSeparator()
                    row(usageBlock)
                }
            }

            ForEach(module.models, id: \.id) { model in
                RowSeparator()
                row(
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.displayName).font(DS.Font.body)
                        ChipRow(chips: CapabilityChip.chips(for: model, requiresKey: true))
                    }
                )
            }

            RowSeparator()
            row(
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    Label(
                        "Translation goes through Diduny. ElevenLabs transcribes in the original language; the transcript text is then sent to Diduny to be translated and uses your Diduny quota. Audio and your key are never sent to Diduny.",
                        systemImage: "arrow.triangle.branch"
                    )
                    .font(DS.Font.callout)
                    Label(
                        "Diduny asks ElevenLabs to delete each file transcript after use. ElevenLabs may keep backups for up to 30 days and in its logs; zero retention is not supported. Live (realtime) transcripts are not claimed to be deleted. Audio is sent to ElevenLabs only for jobs set to ElevenLabs.",
                        systemImage: "hand.raised"
                    )
                    .font(DS.Font.caption)
                }
                .foregroundStyle(.secondary)
            )

            RowSeparator()
            row(
                DisclosureGroup("Before you start", isExpanded: $guidanceExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Create an API key in your ElevenLabs dashboard.")
                        Text("2. If you restrict the key, enable Speech to Text, and Usage (read) to see credits.")
                        Text("3. Accept the Scribe terms in your ElevenLabs dashboard before your first recording. Without this, ElevenLabs rejects live transcription.")
                        Link("Open ElevenLabs dashboard", destination: Self.dashboardURL)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .font(DS.Font.callout)
                    .padding(.top, DS.Space.sm)
                }
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(module.displayName))
        .onAppear(perform: load)
        .confirmationDialog("Remove the ElevenLabs key?", isPresented: $confirmRemove) {
            Button("Remove key", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeMessage)
        }
        .sheet(isPresented: $showDefaultsSheet) {
            ByokDefaultsSheet(module: module)
        }
    }

    // MARK: Key row

    @ViewBuilder private var keyRow: some View {
        if let maskedKey, !isReplacing {
            HStack {
                Text("API key")
                Spacer()
                Text(maskedKey).font(.body.monospaced()).foregroundStyle(.secondary)
                Button("Replace") {
                    keyInput = ""
                    isReplacing = true
                }
                .buttonStyle(.bordered)
            }
        } else {
            HStack {
                Group {
                    if reveal {
                        TextField("API key", text: $keyInput, prompt: Text("Paste your ElevenLabs API key"))
                    } else {
                        SecureField("API key", text: $keyInput, prompt: Text("Paste your ElevenLabs API key"))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
                Button {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        keyInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .accessibilityLabel(Text("Paste"))
                if !keyInput.isEmpty {
                    Button {
                        reveal.toggle()
                    } label: {
                        Image(systemName: reveal ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(reveal ? Text("Hide key") : Text("Show key"))
                }
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .tint(DS.Palette.accent)
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if isReplacing {
                    Button("Cancel") { isReplacing = false; keyInput = "" }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    // MARK: Status

    @ViewBuilder private var pill: some View {
        switch status {
        case .noKey:
            ProviderStatusPill(text: String(localized: "No key"), systemImage: "minus.circle", color: .secondary)
        case .saved:
            ProviderStatusPill(text: String(localized: "Key saved"), systemImage: "key.fill", color: .secondary)
        case .testing:
            ProviderStatusPill(text: String(localized: "Testing…"), systemImage: nil, color: .secondary, isLoading: true)
        case let .ok(plan):
            ProviderStatusPill(text: String(format: String(localized: "OK · %@"), plan), systemImage: "checkmark.circle.fill", color: .green)
        case let .failed(error):
            switch error {
            case .invalidKey:
                ProviderStatusPill(text: String(localized: "Invalid key"), systemImage: "xmark.circle.fill", color: .red)
            case .missingPermission:
                ProviderStatusPill(text: String(localized: "Missing permission"), systemImage: "lock.slash", color: .orange)
            case .termsNotAccepted:
                ProviderStatusPill(text: String(localized: "Terms not accepted"), systemImage: "exclamationmark.triangle.fill", color: .orange)
            case .network:
                ProviderStatusPill(text: String(localized: "Network error"), systemImage: "wifi.slash", color: .orange)
            default:
                ProviderStatusPill(text: String(localized: "Test failed"), systemImage: "exclamationmark.triangle.fill", color: .orange)
            }
        }
    }

    private var statusDetail: String? {
        switch status {
        case .noKey: nil
        case .saved: String(localized: "Not tested yet.")
        case .testing: String(localized: "Contacting ElevenLabs…")
        case .ok: String(localized: "Key works. Scribe terms are checked the first time you record.")
        case let .failed(error):
            switch error {
            case .invalidKey: String(localized: "ElevenLabs rejected this key. Check it and paste it again.")
            case .missingPermission: String(localized: "This key lacks the speech_to_text permission. Enable it for the key in the ElevenLabs dashboard.")
            case .termsNotAccepted: String(localized: "Accept the Scribe terms in your ElevenLabs dashboard, then test again.")
            case .network: String(localized: "Can't reach ElevenLabs. Your key is unchanged.")
            default: error.errorDescription
            }
        }
    }

    private var showsDashboardLink: Bool {
        switch status {
        case .ok, .failed(.missingPermission), .failed(.termsNotAccepted), .failed(.quotaExceeded): true
        default: false
        }
    }

    // MARK: Usage

    @ViewBuilder private var usageBlock: some View {
        switch usage {
        case .hidden:
            EmptyView()
        case .loading:
            Text("Usage").redacted(reason: .placeholder)
        case .unavailable:
            HStack {
                Text("Usage unavailable right now.").font(.caption).foregroundStyle(.secondary)
                Button("Try again") { Task { await loadUsage() } }.buttonStyle(.bordered).controlSize(.small)
            }
        case let .loaded(value):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Usage").font(.callout.weight(.medium))
                    Spacer()
                    Text(String(format: String(localized: "Plan: %@"), value.planName.capitalized))
                        .font(.caption).foregroundStyle(.secondary)
                }
                let used = value.creditsUsed.formatted()
                if value.creditsLimit > 0 {
                    let fraction = min(1, Double(value.creditsUsed) / Double(value.creditsLimit))
                    Text(String(format: String(localized: "Credits used: %@ of %@"), used, value.creditsLimit.formatted()))
                        .font(.caption)
                    HStack {
                        ProgressView(value: fraction)
                            .tint(fraction >= 1 ? .red : fraction >= 0.9 ? .orange : .accentColor)
                        Text(fraction.formatted(.percent.precision(.fractionLength(0)))).font(.caption.monospacedDigit())
                    }
                } else {
                    Text(String(format: String(localized: "Credits used: %@"), used)).font(.caption)
                }
                if let reset = value.resetsAt {
                    Text(String(format: String(localized: "Resets on %@"), reset.formatted(date: .long, time: .omitted)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Actions

    private var removeMessage: String {
        let affected = STTJob.allCases.filter {
            SettingsStorage.shared.providerDefaults.selection(for: $0).providerID == module.id
        }
        let base = String(localized: "The key will be erased from this Mac's Keychain.")
        guard !affected.isEmpty else { return base }
        return base + " " + String(
            format: String(localized: "%@ will switch back to Diduny Cloud."),
            ProvidersSettingsView.jobList(affected)
        )
    }

    private func load() {
        maskedKey = keyStore.maskedKey(for: module.id)
        guidanceExpanded = maskedKey == nil
        if maskedKey != nil {
            if status == .noKey { status = .saved }
            Task { await loadUsage() }
        } else {
            status = .noKey
        }
    }

    private func save() {
        do {
            try keyStore.save(keyInput, for: module.id)
        } catch {
            saveFailed = true
            return
        }
        saveFailed = false
        keyInput = ""
        let providerID = module.id
        Task { await RemoteDeletionQueue.shared.resetAuthNotice(for: providerID) }
        reveal = false
        isReplacing = false
        maskedKey = keyStore.maskedKey(for: module.id)
        guidanceExpanded = false
        Task {
            await test()
            if case .ok = status { showDefaultsSheet = true }
        }
    }

    private func test() async {
        guard let key = keyStore.key(for: module.id) else { return }
        status = .testing
        switch await account.testConnection(apiKey: key) {
        case let .ok(plan):
            status = .ok(plan.capitalized)
            await loadUsage()
        case let .failed(error):
            status = .failed(error)
            if error == .invalidKey { usage = .hidden }
        }
    }

    private func loadUsage() async {
        guard let key = keyStore.key(for: module.id) else { return }
        usage = .loading
        do {
            usage = .loaded(try await account.fetchUsage(apiKey: key))
        } catch {
            usage = .unavailable
        }
    }

    private func remove() {
        let affected = keyStore.remove(for: module.id, defaults: SettingsStorage.shared.providerDefaults)
        maskedKey = nil
        status = .noKey
        usage = .hidden
        guidanceExpanded = true
        if !affected.isEmpty { onRemoved(affected) }
    }
}

// MARK: - Key-added defaults sheet

private struct ByokDefaultsSheet: View {
    let module: any STTProviderModule
    @Environment(\.dismiss) private var dismiss
    @State private var checked: Set<STTJob> = []

    private struct Row: Identifiable {
        let job: STTJob
        let modelID: String
        let label: String
        var id: STTJob { job }
    }

    private var rows: [Row] {
        let context = EngineOptions.context()
        return STTJob.allCases.compactMap { job in
            let request = JobRequest(job: job, speakerLabels: job == .meeting || job == .file)
            for model in module.models {
                if case let .plan(plan) = JobRouter.plan(request, providerID: module.id, requiresKey: true, model: model, context: context) {
                    return Row(job: job, modelID: model.id, label: EngineOptions.planLabel(plan, job: job))
                }
            }
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(format: String(localized: "Use %@ by default?"), module.displayName)).font(.headline)
            Text("Nothing changes unless you choose. You can switch back in the pickers at any time.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(rows) { row in
                Toggle(isOn: Binding(
                    get: { checked.contains(row.job) },
                    set: { if $0 { checked.insert(row.job) } else { checked.remove(row.job) } }
                )) {
                    HStack {
                        Text(ProvidersSettingsView.jobName(row.job))
                        Spacer()
                        Text(row.label).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button("Not now") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    let defaults = SettingsStorage.shared.providerDefaults
                    for row in rows where checked.contains(row.job) {
                        defaults.setSelection(JobProviderSelection(providerID: module.id, modelID: row.modelID), for: row.job)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(checked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { if rows.isEmpty { dismiss() } }
    }
}
