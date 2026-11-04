import SwiftUI

/// One entry in a per-job "Engine" picker.
struct EngineOption: Identifiable, Equatable {
    /// "diduny-cloud", "local-whisper", or "<providerID>/<modelID>" for BYOK models.
    let id: String
    let title: String
    /// Non-nil = listed but disabled, with this reason.
    let disabledReason: String?
    let hint: String?
}

/// Builds picker entries for a job. Diduny Cloud and Local Whisper are always listed (as today);
/// BYOK models appear only when their key is stored, disabled with a reason when the router says unsupported.
@MainActor
enum EngineOptions {
    static func translationAvailability() -> (signedIn: Bool, available: Bool) {
        let signedIn = AuthService.hasStoredSession
        let available = UsageService.canOfferCloudTranscription(
            hasStoredSession: signedIn,
            usage: UsageService.shared.cachedUsage
        )
        return (signedIn, available)
    }

    static let byokJobs: Set<STTJob> = [.dictation, .dictationTranslation, .meeting]
    /// Parakeet and Apple run after Stop, so they are offered where the flow transcribes the saved capture.
    static let onDeviceJobs: Set<STTJob> = [.dictation, .dictationTranslation, .meeting, .meetingTranslation, .file]

    /// Parakeet V3 / Apple entries: listed when ready on this Mac; translation adds the Diduny text step.
    static func onDeviceOptions(for job: STTJob, context: RoutingContext, signedIn: Bool) -> [EngineOption] {
        let engines: [(String, any BenchmarkEngine)] = [
            (STTProviderID.parakeet, ParakeetBenchmarkEngine()),
            (STTProviderID.appleSpeech, AppleBenchmarkEngine())
        ]
        return engines.compactMap { id, engine in
            guard engine.availability() == .ready else { return nil }
            // Apple streams live text for dictation and meetings; Parakeet transcribes after Stop (like Handy).
            let translates = job == .dictationTranslation || job == .meetingTranslation
            let live = id == STTProviderID.appleSpeech && job != .file && job != .meetingTranslation
            let plan = ExecutionPlan(mode: live ? .live : .afterStop, translation: translates ? .didunyStep : .none)
            if translates, !context.didunyTranslationAvailable {
                return EngineOption(id: id, title: engine.name, disabledReason: reasonText(.translationNeedsDiduny, signedIn: signedIn), hint: nil)
            }
            return EngineOption(id: id, title: "\(engine.name) · \(planLabel(plan, job: job))", disabledReason: nil,
                                hint: (live ? String(localized: "Runs on this Mac. Text appears while you speak.") : String(localized: "Runs on this Mac after you press Stop.")) + (translates ? " " + String(localized: "Diduny translates the text and uses your Diduny quota.") : ""))
        }
    }

    static func context(keyStore: ProviderKeyStore = .shared, registry: ProviderRegistry = .shared) -> RoutingContext {
        RoutingContext(
            providersWithKey: Set(registry.modules.filter { keyStore.hasKey(for: $0.id) }.map(\.id)),
            didunyTranslationAvailable: translationAvailability().available
        )
    }

    static func options(
        for request: JobRequest,
        registry: ProviderRegistry = .shared,
        context: RoutingContext,
        signedIn: Bool
    ) -> [EngineOption] {
        let diduny = EngineOption(id: STTProviderID.didunyCloud, title: builtInTitle("Diduny Cloud", job: request.job, local: false), disabledReason: nil, hint: nil)
        // Live two-way meeting translation runs only on Diduny Cloud.
        guard request.job != .meetingTranslation else {
            // Own engines: Parakeet / Apple transcribe after Stop, then the final text is translated once.
            return [diduny] + onDeviceOptions(for: .meetingTranslation, context: context, signedIn: signedIn) + registry.modules.filter { $0.requiresKey && context.providersWithKey.contains($0.id) }.map {
                EngineOption(id: "\($0.id)/\($0.models.first?.id ?? "")", title: $0.displayName, disabledReason: String(localized: "can't translate live"), hint: nil)
            }
        }
        var result = [
            diduny,
            EngineOption(id: STTProviderID.localWhisper, title: builtInTitle("Local Whisper", job: request.job, local: true), disabledReason: nil, hint: nil)
        ]
        if onDeviceJobs.contains(request.job) {
            result += onDeviceOptions(for: request.job, context: context, signedIn: signedIn)
        }
        // BYOK engines run only where the recording flow is wired to them (dictation, dictation translation, live meetings).
        guard byokJobs.contains(request.job) else { return result }
        for module in registry.modules where module.requiresKey && context.providersWithKey.contains(module.id) {
            for model in module.models {
                let name = "\(module.displayName) \(model.displayName)"
                let id = "\(module.id)/\(model.id)"
                switch JobRouter.plan(request, providerID: module.id, requiresKey: true, model: model, context: context) {
                case let .plan(plan):
                    // Meetings are wired for live streaming only.
                    if request.job == .meeting, plan.mode != .live { continue }
                    result.append(EngineOption(id: id, title: "\(name) · \(planLabel(plan, job: request.job))", disabledReason: nil, hint: hint(plan, job: request.job)))
                case .unsupported(.noUsableMode):
                    continue
                case let .unsupported(reason):
                    result.append(EngineOption(id: id, title: name, disabledReason: reasonText(reason, signedIn: signedIn), hint: nil))
                }
            }
        }
        return result
    }

    private static func builtInTitle(_ name: String, job: STTJob, local: Bool) -> String {
        switch (job, local) {
        case (.file, false): "\(name) · " + String(localized: "after upload")
        case (.file, true): name
        case (.dictationTranslation, true): "\(name) · " + String(localized: "after Stop (English only)")
        case (_, true): "\(name) · " + String(localized: "live preview")
        case (_, false): "\(name) · " + String(localized: "live")
        }
    }

    static func planLabel(_ plan: ExecutionPlan, job: STTJob) -> String {
        var parts: [String] = []
        switch plan.mode {
        case .live: parts.append(String(localized: "live"))
        case .afterStop: parts.append(String(localized: "after Stop"))
        case .batch, .chunked: parts.append(String(localized: "after upload"))
        }
        if plan.translation == .didunyStep { parts[0] += " + " + String(localized: "Diduny translation") }
        if plan.speakerLabels { parts.append(String(localized: "speaker labels")) }
        if plan.noSpeakerLabelsNote || (job == .meeting && !plan.speakerLabels) {
            parts.append(String(localized: "no speaker labels"))
        }
        return parts.joined(separator: " · ")
    }

    private static func hint(_ plan: ExecutionPlan, job: STTJob) -> String {
        if plan.translation == .didunyStep {
            return String(localized: "Transcribed by the provider; Diduny translates the text and uses your Diduny quota.")
        }
        switch (job, plan.mode) {
        case (.meeting, _) where !plan.speakerLabels:
            return String(localized: "No speaker labels with this engine. Meetings are transcribed live and not re-processed afterwards.")
        case (_, .live):
            return String(localized: "Text appears while you speak. Final text is pasted right after Stop.")
        case (_, .afterStop):
            return String(localized: "Slower: the recording is transcribed after you press Stop.")
        default:
            return String(localized: "Speaker labels available for files.")
        }
    }

    static func reasonText(_ reason: UnsupportedReason, signedIn: Bool) -> String {
        switch reason {
        case .translationNeedsDiduny:
            signedIn ? String(localized: "Diduny quota used up") : String(localized: "needs Diduny sign-in")
        case let .language(code):
            String(format: String(localized: "can't transcribe %@"), code)
        case .fileTooLong:
            String(localized: "file too long")
        case .noKey, .noUsableMode:
            String(localized: "unavailable")
        }
    }
}

/// Menu-style per-job engine picker. Diduny Cloud / Local Whisper keep writing the existing legacy setting,
/// so behaviour for users without a key is unchanged; a BYOK choice is stored in the per-job default.
struct EnginePickerRow: View {
    let label: LocalizedStringKey
    let request: JobRequest
    let legacyIsLocal: () -> Bool
    let setLegacyLocal: (Bool) -> Void
    var showsManageLink = true
    /// When set, the label sits on the left and the menu is right-aligned at this fixed width,
    /// so a column of rows lines up.
    var menuWidth: CGFloat?

    @State private var selection = ""
    @State private var options: [EngineOption] = []

    private var defaults: ProviderDefaultsStore { SettingsStorage.shared.providerDefaults }

    var body: some View {
        Group {
            if let menuWidth {
                HStack {
                    Text(label)
                    Spacer(minLength: DS.Space.md)
                    picker.labelsHidden().fixedSize().frame(width: menuWidth, alignment: .leading)
                }
            } else {
                picker
            }

            if let hint = options.first(where: { $0.id == selection })?.hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            if showsManageLink {
                Button("Manage providers") {
                    MainWindowController.shared.showWindow(section: .providers)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .onAppear(perform: reload)
    }

    private var picker: some View {
        Picker(label, selection: $selection) {
            ForEach(options) { option in
                if let reason = option.disabledReason {
                    Text("\(option.title) — \(reason)").tag(option.id).selectionDisabled()
                } else {
                    Text(option.title).tag(option.id)
                }
            }
        }
        .pickerStyle(.menu)
        .accessibilityValue(options.first { $0.id == selection }?.title ?? "")
        .onChange(of: selection) { _, value in apply(value) }
    }

    private func reload() {
        let context = EngineOptions.context()
        options = EngineOptions.options(
            for: request,
            context: context,
            signedIn: EngineOptions.translationAvailability().signedIn
        )
        let stored = defaults.selection(for: request.job)
        let byokID = STTProviderID.onDeviceEngines.contains(stored.providerID)
            ? stored.providerID : stored.modelID.map { "\(stored.providerID)/\($0)" }
        if let byokID, options.contains(where: { $0.id == byokID && $0.disabledReason == nil }) {
            selection = byokID
        } else {
            selection = legacyIsLocal() ? STTProviderID.localWhisper : STTProviderID.didunyCloud
        }
    }

    private func apply(_ id: String) {
        EngineOptions.apply(id, job: request.job, setLegacyLocal: setLegacyLocal)
    }
}

extension EngineOptions {
    /// Stores a picker choice for a job. Diduny Cloud / Local Whisper also write the legacy Cloud/Local setting.
    static func apply(_ id: String, job: STTJob, setLegacyLocal: (Bool) -> Void) {
        let defaults = SettingsStorage.shared.providerDefaults
        let request = JobRequest(job: job)
        switch id {
        case STTProviderID.didunyCloud, STTProviderID.localWhisper:
            defaults.setSelection(.didunyCloud, for: request.job)
            setLegacyLocal(id == STTProviderID.localWhisper)
        case let onDevice where STTProviderID.onDeviceEngines.contains(onDevice):
            // Legacy "local" first: no live cloud stream, the capture is transcribed on this Mac after Stop.
            // (For files the legacy setter writes the selection, so it must run before ours.)
            setLegacyLocal(true)
            defaults.setSelection(JobProviderSelection(providerID: onDevice, modelID: nil), for: request.job)
        default:
            let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            defaults.setSelection(JobProviderSelection(providerID: parts[0], modelID: parts[1]), for: request.job)
        }
    }
}

/// Meetings live-translation hint when the Diduny translation step is not available (signed out / no quota).
struct DidunyTranslationGateNotice: View {
    var body: some View {
        let availability = EngineOptions.translationAvailability()
        if !availability.available {
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    availability.signedIn
                        ? "Translation uses Diduny quota, which is used up. Upgrade to enable it. Transcription with your own provider still works."
                        : "Translation uses Diduny. Sign in to enable it. Transcription with your own provider still works.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button(availability.signedIn ? "Upgrade" : "Sign in") {
                    MainWindowController.shared.showWindow(section: .account)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }
}

/// Capability chip: available = tinted with a checkmark; not available = outlined with a minus.
struct CapabilityChip: View {
    let text: String
    let available: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: available ? "checkmark" : "minus").font(.system(size: 8, weight: .bold))
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(available ? Color.accentColor : Color.secondary)
        .background(available ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
        .overlay(Capsule().strokeBorder(available ? Color.clear : Color.secondary, lineWidth: 0.5))
        .accessibilityLabel(available ? text : String(format: String(localized: "%@, not available"), text))
    }

    /// Chips come from the capability declaration only, never from the provider id.
    static func chips(for model: STTModel, requiresKey: Bool) -> [(String, Bool)] {
        let caps = model.capabilities
        var chips: [(String, Bool)] = []
        if caps.realtime != nil { chips.append((String(localized: "Live"), true)) }
        if caps.batch != nil { chips.append((String(localized: "After Stop"), true)) }
        let diarization = (caps.realtime?.diarization ?? false) || (caps.batch?.diarization ?? false)
        if diarization {
            if let max = caps.batch?.maxSpeakers {
                chips.append((String(format: String(localized: "Speaker labels · up to %lld"), Int64(max)), true))
            } else {
                chips.append((String(localized: "Speaker labels"), true))
            }
        } else {
            chips.append((String(localized: "No speaker labels"), false))
        }
        let native = caps.realtime?.translation ?? caps.batch?.translation
        if let native {
            chips.append((native.twoWay ? String(localized: "Translation") : String(localized: "English only"), true))
        } else if requiresKey {
            chips.append((String(localized: "Translation via Diduny"), true))
        }
        return chips
    }
}

/// Recording-time error surface for a BYOK failure. The recording is always kept; the Diduny Cloud
/// action is one-off, explicit, and never triggered automatically.
struct RecordingErrorBanner: View {
    let error: ElevenLabsError
    let onFix: () -> Void
    let onUseDidunyCloud: () -> Void

    var body: some View {
        let availability = EngineOptions.translationAvailability()
        VStack(alignment: .leading, spacing: 6) {
            Label(error.errorDescription ?? "", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Your recording is saved.").font(.callout)
            HStack {
                Button(fixTitle, action: onFix).buttonStyle(.borderedProminent)
                Button("Use Diduny Cloud for this recording", action: onUseDidunyCloud)
                    .disabled(!availability.available)
            }
            Text(
                !availability.signedIn ? "Sign in to use Diduny Cloud"
                    : !availability.available ? "Diduny quota used up"
                    : "Uses your Diduny quota for this recording only. Your defaults don't change."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    private var fixTitle: LocalizedStringKey {
        switch error {
        case .invalidKey, .missingPermission: "Open Providers"
        case .termsNotAccepted, .quotaExceeded, .planOrModelNotAvailable: "Open ElevenLabs dashboard"
        default: "Retry"
        }
    }
}

/// One place to pick the engine for every mode, with a shortcut that sets the same engine for all of them.
struct EnginesByModeSection: View {
    private static let menuWidth: CGFloat = 300
    private struct Mode {
        let job: STTJob
        let label: LocalizedStringKey
        let request: JobRequest
        let legacyIsLocal: () -> Bool
        let setLegacyLocal: (Bool) -> Void
    }

    @State private var refresh = UUID()
    @State private var allChoice = ""
    @State private var note: String?

    private let modes: [Mode] = {
        let s = SettingsStorage.shared
        return [
            Mode(job: .dictation, label: "Dictation", request: JobRequest(job: .dictation),
                 legacyIsLocal: { s.transcriptionProvider == .local },
                 setLegacyLocal: { s.transcriptionProvider = $0 ? .local : .cloud }),
            Mode(job: .dictationTranslation, label: "Dictation translation", request: JobRequest(job: .dictationTranslation),
                 legacyIsLocal: { s.translationProvider == .local },
                 setLegacyLocal: { s.translationProvider = $0 ? .local : .cloud }),
            Mode(job: .meeting, label: "Meetings", request: JobRequest(job: .meeting, speakerLabels: true),
                 legacyIsLocal: { !s.meetingRealtimeTranscriptionEnabled },
                 setLegacyLocal: { s.meetingRealtimeTranscriptionEnabled = !$0 }),
            Mode(job: .meetingTranslation, label: "Meeting translation", request: JobRequest(job: .meetingTranslation),
                 legacyIsLocal: { false }, setLegacyLocal: { _ in }),
            Mode(job: .file, label: "Files", request: JobRequest(job: .file),
                 legacyIsLocal: { s.providerDefaults.selection(for: .file).providerID == STTProviderID.localWhisper },
                 setLegacyLocal: { isLocal in
                     s.providerDefaults.setSelection(
                         JobProviderSelection(providerID: isLocal ? STTProviderID.localWhisper : STTProviderID.didunyCloud, modelID: nil),
                         for: .file
                     )
                 }),
        ]
    }()

    private var allOptions: [EngineOption] {
        let context = EngineOptions.context()
        let signedIn = EngineOptions.translationAvailability().signedIn
        var seen = Set<String>()
        return modes.flatMap { EngineOptions.options(for: $0.request, context: context, signedIn: signedIn) }
            .filter { $0.disabledReason == nil && seen.insert($0.id).inserted }
            .map { EngineOption(id: $0.id, title: String($0.title.split(separator: "·").first ?? "").trimmingCharacters(in: .whitespaces), disabledReason: nil, hint: nil) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            SettingsGroup(title: "Engine for each mode") {
                SettingRow(title: "Use for all modes") {
                    Picker("Use for all modes", selection: $allChoice) {
                        Text("Choose an engine").tag("")
                        ForEach(allOptions) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .frame(width: Self.menuWidth, alignment: .leading)
                }
                .onChange(of: allChoice) { _, id in applyAll(id) }
                if let note {
                    RowSeparator()
                    Text(note).font(DS.Font.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
                }
                ForEach(Array(modes.enumerated()), id: \.offset) { _, mode in
                    RowSeparator()
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        EnginePickerRow(label: mode.label, request: mode.request, legacyIsLocal: mode.legacyIsLocal,
                                        setLegacyLocal: mode.setLegacyLocal, showsManageLink: false,
                                        menuWidth: Self.menuWidth)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Space.lg)
                    .padding(.vertical, DS.Space.md)
                }
                .id(refresh)
            }
            Text("Pick one engine for everything, then change any single mode.")
                .font(DS.Font.callout).foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.xs)
        }
    }

    private func applyAll(_ id: String) {
        guard !id.isEmpty else { return }
        let context = EngineOptions.context()
        let signedIn = EngineOptions.translationAvailability().signedIn
        var skipped = false
        for mode in modes {
            let options = EngineOptions.options(for: mode.request, context: context, signedIn: signedIn)
            if options.contains(where: { $0.id == id && $0.disabledReason == nil }) {
                EngineOptions.apply(id, job: mode.job, setLegacyLocal: mode.setLegacyLocal)
            } else {
                skipped = true
            }
        }
        note = !skipped ? nil : String(localized: "Not available for some modes; they keep their engine.")
        allChoice = ""
        refresh = UUID()
    }
}
