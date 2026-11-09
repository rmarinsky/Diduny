import AppKit
import SwiftUI

/// Settings > Providers (design-spec 7.9; 03 1 to 3): the comparison table, the legend, and "Add ElevenLabs"
/// only while no key is saved. The key itself is managed in the key popup. Per-mode engines live in Settings > Modes.
struct ProvidersSettingsView: View {
    @State private var hasKey: Bool
    @State private var addKey = AddKeyState(keyStore: ProviderKeyStore.shared, account: ElevenLabsAccountService.settings)
    @State private var showDefaultsSheet = false

    private let keyStore = ProviderKeyStore.shared

    init(hasKey: Bool = ProviderKeyStore.shared.hasKey(for: STTProviderID.elevenLabs)) {
        _hasKey = State(initialValue: hasKey)
    }

    private static let dashboardURL = URL(string: "https://elevenlabs.io/app")!

    var body: some View {
        PageScaffold(title: "Providers", subtitle: "What each engine does by itself, and what Diduny adds on top of it.",
                     columnMaxWidth: DS.Layout.wideColumnMaxWidth) {
            VStack(alignment: .leading, spacing: 0) {
                ProviderComparisonTable(
                    model: ProviderTableModel.current(hasKey: hasKey),
                    openPopup: openPopup,
                    openAccount: { MainWindowController.shared.showWindow(section: .account) },
                    openLocalModels: { MainWindowController.shared.showWindow(section: .models) }
                )
                ProviderLegend().padding(.top, DS.Space.md)
                if !hasKey {
                    addKeySection.padding(.top, 22)
                }
            }
        }
        .sheet(isPresented: $showDefaultsSheet) {
            if let module = ProviderRegistry.shared.module(id: STTProviderID.elevenLabs) {
                ByokDefaultsSheet(module: module)
            }
        }
    }

    // MARK: Add ElevenLabs

    private var addKeySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add ElevenLabs")
                .font(DS.Font.groupHeading)
                .foregroundStyle(DS.Palette.text)
                .padding(.bottom, DS.Space.sm)
            HStack(spacing: DS.Space.sm) {
                SecureField("ElevenLabs API key", text: $addKey.input, prompt: Text("Paste your ElevenLabs API key"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(addKey.phase == .checking)
                    .onSubmit(save)
                    .accessibilityIdentifier("providers.addKey.field")
                if addKey.phase == .checking {
                    HStack(spacing: DS.Space.xs) {
                        ProgressView().controlSize(.small)
                        Text("Checking...").font(DS.Font.callout).foregroundStyle(DS.Palette.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("providers.addKey.status")
                } else {
                    Button("Save", action: save)
                        .buttonStyle(.borderedProminent)
                        .tint(DS.Palette.accentFill)
                        .disabled(!addKey.canSave)
                        .accessibilityIdentifier("providers.addKey.save")
                }
            }
            .padding(.top, 6)
            if let message = addKey.message {
                Label(message, systemImage: "xmark.circle")
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Palette.no)
                    .padding(.top, 6)
                    .accessibilityIdentifier("providers.addKey.status")
            }
            Text("ElevenLabs transcribes with your key and bills you. Audio and the key are not sent to Diduny.")
                .font(DS.Font.callout)
                .foregroundStyle(DS.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            // Default 12 (implementation-plan 2.2): the retention notice and "Before you start" stay here.
            ElevenLabsKeyGuidance(dashboardURL: Self.dashboardURL).padding(.top, DS.Space.md)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("providers.addKey")
    }

    private func save() {
        Task {
            guard await addKey.save() else { return }
            hasKey = true
            showDefaultsSheet = true
        }
    }

    // MARK: Popups

    private func openPopup(_ name: String, anchor: FloatingSurfaceAnchor, fromKeyboard: Bool) {
        guard let frame = anchor.screenFrame else { return }
        let presenter = FloatingSurfacePresenter.shared
        if name == "key" {
            let state = KeyPopupState(
                keyStore: keyStore, account: ElevenLabsAccountService.settings,
                defaults: SettingsStorage.shared.providerDefaults
            )
            state.onRemoved = { _ in hasKey = false }
            presenter.togglePopup(
                owner: "providers.key", name: name, anchor: frame, parent: anchor.window, fromKeyboard: fromKeyboard
            ) { close in
                ElevenLabsKeyPopup(state: state, close: close) { NSWorkspace.shared.open(Self.dashboardURL) }
            }
            return
        }
        let model = ProviderTableModel.current(hasKey: hasKey)
        guard let column = model.columns.first(where: { "languages.\($0.id.rawValue)" == name }) else { return }
        let popup = LanguagePopupModel(caps: column.caps, yourLanguages: SettingsStorage.shared.yourLanguages)
        presenter.togglePopup(
            owner: "providers.\(name)", name: name, anchor: frame, parent: anchor.window, fromKeyboard: fromKeyboard
        ) { close in
            LanguageListPopup(model: popup, close: close)
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
}

/// Today's retention notice and "Before you start" steps, under "Add ElevenLabs" (default 12).
private struct ElevenLabsKeyGuidance: View {
    let dashboardURL: URL
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Label(
                "Diduny asks ElevenLabs to delete each file transcript after use. ElevenLabs may keep backups for up to 30 days and in its logs; zero retention is not supported. Live (realtime) transcripts are not claimed to be deleted. Audio is sent to ElevenLabs only for jobs set to ElevenLabs.",
                systemImage: "hand.raised"
            )
            .font(DS.Font.caption)
            .foregroundStyle(DS.Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Before you start", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Create an API key in your ElevenLabs dashboard.")
                    Text("2. If you restrict the key, enable Speech to Text, and Usage (read) to see credits.")
                    Text("3. Accept the Scribe terms in your ElevenLabs dashboard before your first recording. Without this, ElevenLabs rejects live transcription.")
                    Link("Open ElevenLabs dashboard", destination: dashboardURL)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .font(DS.Font.callout)
                .padding(.top, DS.Space.sm)
            }
        }
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
