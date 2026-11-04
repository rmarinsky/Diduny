import SwiftUI

struct BenchmarkView: View {
    @State private var runner = BenchmarkRunner.shared

    var body: some View {
        Group {
            if let run = runner.current {
                BenchmarkResultsView(run: run, runner: runner)
            } else {
                BenchmarkSetupView(runner: runner)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Setup

private struct BenchmarkSetupView: View {
    let runner: BenchmarkRunner
    @State private var storage = RecordingsLibraryStorage.shared
    @State private var selectedRecordings: Set<UUID> = []
    @State private var selectedEngines: Set<String> = []
    @State private var language = BenchmarkRunner.defaultLanguage
    @State private var engines: [any BenchmarkEngine] = BenchmarkEngineCatalog.all()

    private var playable: [Recording] {
        storage.recordings.filter { storage.hasPlayableAudio(for: $0) && $0.status != .recording }
    }

    private var ready: [any BenchmarkEngine] { engines.filter { $0.availability() == .ready } }
    private var unavailable: [any BenchmarkEngine] { engines.filter { $0.availability() != .ready } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Benchmark").font(.title2.bold())
                    Text("Compare transcription engines on your own recordings.").foregroundStyle(.secondary)
                }

                card(title: "Recordings", detail: recordingsDetail) {
                    if playable.isEmpty {
                        Text("No recordings yet. Record something first.").foregroundStyle(.secondary).padding(16)
                    }
                    ForEach(playable) { recording in
                        checkRow(isOn: selectedRecordings.contains(recording.id)) {
                            toggle(&selectedRecordings, recording.id)
                        } content: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(recording.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(recording.transcriptionText ?? "").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(duration(recording.effectiveDurationSeconds)).font(.system(size: 12, weight: .medium, design: .monospaced))
                                Text(recording.createdAt, style: .date).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                card(title: "Engines", detail: "Pick 2 or more") {
                    ForEach(ready, id: \.id) { engine in
                        checkRow(isOn: selectedEngines.contains(engine.id)) {
                            toggle(&selectedEngines, engine.id)
                        } content: {
                            engineLabel(engine)
                            Spacer()
                            Label("Ready", systemImage: "circle.fill").labelStyle(.titleAndIcon)
                                .font(.system(size: 12)).foregroundStyle(.green)
                        }
                    }
                    if !unavailable.isEmpty {
                        Text("Not available").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.quaternaryLabelColor).opacity(0.12))
                        ForEach(unavailable, id: \.id) { engine in
                            HStack(spacing: 12) {
                                Image(systemName: "square").foregroundStyle(.tertiary)
                                engineLabel(engine)
                                Spacer()
                                Text(reason(engine.availability())).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            .opacity(0.6)
                        }
                    }
                }

                HStack {
                    Picker("Language", selection: $language) {
                        ForEach(SettingsStorage.shared.favoriteLanguages, id: \.self) { code in
                            Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                        }
                    }
                    .frame(width: 220)
                    Spacer()
                    Button("Clear") { selectedRecordings = []; selectedEngines = [] }
                    Button(runTitle) {
                        let recs = playable.filter { selectedRecordings.contains($0.id) }
                        runner.start(recordings: recs, engines: ready.filter { selectedEngines.contains($0.id) }, language: language)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedRecordings.isEmpty || selectedEngines.count < 2)
                    .keyboardShortcut("r", modifiers: .command)
                }

                if !runner.runs.isEmpty {
                    card(title: "Past benchmarks", detail: "\(runner.runs.count)") {
                        ForEach(runner.runs) { run in
                            HStack {
                                Button {
                                    runner.open(run)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(run.createdAt, format: .dateTime.day().month().hour().minute())
                                            .font(.system(size: 13, weight: .semibold))
                                        Text("\(run.clips.count) recordings · \(run.engines.map(\.name).joined(separator: ", "))")
                                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button(role: .destructive) { runner.delete(run) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain).foregroundStyle(.red).help("Delete benchmark")
                            }
                            .padding(.horizontal, 16).padding(.vertical, 11)
                        }
                    }
                }
            }
            .padding(24)
        }
        .onAppear { engines = BenchmarkEngineCatalog.all() }
    }

    private var recordingsDetail: String {
        let total = playable.filter { selectedRecordings.contains($0.id) }.map(\.effectiveDurationSeconds).reduce(0, +)
        return "\(selectedRecordings.count) selected · \(duration(total))"
    }

    private var runTitle: String {
        "Run benchmark (\(selectedRecordings.count) × \(selectedEngines.count))"
    }

    private func reason(_ availability: BenchmarkAvailability) -> String {
        switch availability {
        case .ready: "Ready"
        case .notDownloaded: String(localized: "Not downloaded — open Local Models")
        case .noKey: String(localized: "No API key — open Providers")
        case .signedOut: String(localized: "Sign in to use")
        case .appleSiliconOnly: String(localized: "Apple Silicon only")
        case .notOnThisMac: String(localized: "Not available on this Mac")
        }
    }
}

private extension BenchmarkSetupView {
    func toggle(_ set: inout Set<UUID>, _ id: UUID) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    func toggle(_ set: inout Set<String>, _ id: String) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }
}

// MARK: - Results

private struct BenchmarkResultsView: View {
    let run: BenchmarkRun
    let runner: BenchmarkRunner
    @State private var filter: String = "all"
    @AppStorage("benchmarkStrictDiff") private var strict = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(runner.isRunning ? "Running benchmark" : "Benchmark results").font(.title2.bold())
                        Text("\(run.clips.count) recordings · \(run.engines.count) engines · \(duration(run.audioSeconds)) audio\(run.cancelled ? " · cancelled, partial" : "")")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if runner.isRunning {
                        ProgressView(value: Double(runner.progress.done), total: Double(max(runner.progress.total, 1)))
                            .frame(width: 160)
                        Button("Cancel") { runner.cancel() }
                    } else {
                        Picker("Reference", selection: Binding(get: { run.referenceEngineID }, set: { runner.setReference($0) })) {
                            ForEach(run.engines) { Text($0.name).tag($0.id) }
                        }
                        .frame(width: 220)
                        Button("New benchmark") { runner.close() }
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    ForEach(run.engines) { engine in summaryCard(engine) }
                }

                Text("Percent = share of Reference words this engine got different (lower is closer). Reference is the selected engine's text; for Diduny that is the text before server cleanup. Time = from Stop to final text; Diduny is replayed over the live socket like real dictation.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Picker("", selection: $filter) {
                        Text("All clips \(run.clips.count)").tag("all")
                        ForEach(run.engines.filter { $0.id != run.referenceEngineID }) { engine in
                            Text("\(engine.name) differs \(differingCount(engine.id))").tag(engine.id)
                        }
                        Text("Not voted \(run.clips.filter { run.votes[$0.id] == nil }.count)").tag("unvoted")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Toggle("Count punctuation and case", isOn: $strict)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                        .fixedSize()
                }

                if visibleClips.isEmpty {
                    Text("No clips differ for this filter.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                }

                VStack(spacing: 0) {
                    ForEach(visibleClips) { clip in
                        clipBlock(clip)
                        Divider()
                    }
                }
                .background(Color(.windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(.separatorColor), lineWidth: 0.5))
            }
            .padding(24)
        }
    }

    private var visibleClips: [BenchmarkRun.Clip] {
        run.clips.filter { clip in
            switch filter {
            case "all": return true
            case "unvoted": return run.votes[clip.id] == nil
            default:
                return differs(clip, filter)
            }
        }
    }

    private func diff(_ clip: BenchmarkRun.Clip, _ engineID: String) -> WordDiff.Result? {
        guard let text = run.cell(clip.id, engineID)?.text,
              let ref = run.cell(clip.id, run.referenceEngineID)?.text else { return nil }
        return WordDiff.compare(text, reference: ref, strict: strict)
    }

    private func differs(_ clip: BenchmarkRun.Clip, _ engineID: String) -> Bool {
        (diff(clip, engineID)?.errors ?? 0) > 0
    }

    private func differingCount(_ engineID: String) -> Int {
        run.clips.filter { differs($0, engineID) }.count
    }

    /// Engine filter selected → that clip shows only Reference and this engine.
    private var focusedEngines: [BenchmarkRun.Engine] {
        guard run.engines.contains(where: { $0.id == filter }) else { return run.engines }
        return run.engines.filter { $0.id == run.referenceEngineID || $0.id == filter }
    }

    private var bestEngine: String? {
        run.engines.compactMap { e in run.summary(for: e.id, strict: strict).rate.map { (e.id, $0) } }.min { $0.1 < $1.1 }?.0
    }

    private func summaryCard(_ engine: BenchmarkRun.Engine) -> some View {
        let s = run.summary(for: engine.id, strict: strict)
        let finished = run.clips.filter { run.cell($0.id, engine.id)?.text != nil }.count
        let isFocused = filter == engine.id
        let isBest = engine.id == bestEngine
        let isDefault = defaultSelection(for: engine.id).map { isCurrentDefault($0) } ?? false
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(engine.name).font(.system(size: 13, weight: .semibold))
                if isDefault { badge("Default") }
            }
            Text(s.rate.map { String(format: "%.1f%%", $0 * 100) } ?? String(localized: "Reference"))
                .font(.system(size: 22, weight: .bold))
            Text(s.rate == nil ? "Other engines are compared with it" : "of words differ from Reference · lower is closer")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(format: String(localized: "%.2f s avg from Stop to text"), s.seconds / Double(max(finished, 1))))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Text(String(format: "model load %.1f s · votes %d of %d", s.loadSeconds, s.votes, run.clips.count))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            if s.excluded > 0 {
                Text("\(s.excluded) clips excluded").font(.system(size: 11)).foregroundStyle(.orange)
            }
            if let selection = defaultSelection(for: engine.id), !isDefault {
                Button("Make default") {
                    SettingsStorage.shared.providerDefaults.setSelection(selection, for: .dictation)
                }
                .controlSize(.small)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(isBest || isFocused ? Color("BrandTintSoft") : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(isBest || isFocused ? Color.accentColor : Color(.separatorColor), lineWidth: isBest || isFocused ? 1.5 : 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            guard s.rate != nil else { return }
            filter = isFocused ? "all" : engine.id
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(s.rate != nil ? .isButton : [])
    }

    private func clipBlock(_ clip: BenchmarkRun.Clip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(clip.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(duration(clip.durationSeconds)).font(.system(size: 12, weight: .medium, design: .monospaced))
                Text(clip.createdAt, style: .date).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(focusedEngines) { engine in
                engineRow(clip, engine)
            }
            if focusedEngines.count == 2, let d = diff(clip, filter) {
                Text("\(d.errors) of \(d.referenceWords) words differ")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.leading, 120)
            }
            HStack(spacing: 4) {
                Text("Which is right?").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(run.engines) { engine in
                    let on = run.votes[clip.id] == engine.id
                    Button(engine.name) { runner.vote(clip: clip.id, engine: engine.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .foregroundStyle(on ? .white : .primary)
                        .background(on ? Color.accentColor : .clear, in: Capsule())
                        .overlay(Capsule().stroke(Color(.separatorColor), lineWidth: on ? 0 : 0.5))
                        .disabled(runner.isRunning)
                        .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.top, 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Which is right? \(clip.title)")
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func engineRow(_ clip: BenchmarkRun.Clip, _ engine: BenchmarkRun.Engine) -> some View {
        let cell = run.cell(clip.id, engine.id)
        let isRef = engine.id == run.referenceEngineID
        let diff = isRef ? nil : diff(clip, engine.id)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(engine.name).font(.system(size: 11, weight: .medium))
                .foregroundStyle(isRef ? Color("BrandAccentDeep") : .secondary)
                .frame(width: 110, alignment: .leading)
            Group {
                if let error = cell?.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                } else if let text = cell?.text {
                    if !isRef, let diff { Text(highlighted(diff)) } else { Text(text) }
                } else {
                    Text(runner.isRunning ? "Waiting…" : "Not run").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12.5))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(cell?.text != nil ? String(format: "%.2f s", cell!.seconds) : "—")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
            Text(isRef ? "—" : diff.map { String(format: "%.0f%%", $0.rate * 100) } ?? "—")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }
    }

    /// Reference words the engine dropped or misheard: red, struck through.
    /// What the engine wrote instead (or added): green.
    private func highlighted(_ diff: WordDiff.Result) -> AttributedString {
        func removed(_ w: String) -> AttributedString {
            var part = AttributedString(w)
            part.foregroundColor = .red
            part.backgroundColor = .red.opacity(0.14)
            part.strikethroughStyle = .single
            return part
        }
        func added(_ w: String) -> AttributedString {
            var part = AttributedString(w)
            part.foregroundColor = .green
            part.backgroundColor = .green.opacity(0.14)
            return part
        }
        var out = AttributedString()
        for (i, op) in diff.ops.enumerated() {
            if i > 0 { out += AttributedString(" ") }
            switch op {
            case let .equal(w): out += AttributedString(w)
            case let .substituted(w, ref): out += removed(ref) + AttributedString(" ") + added(w)
            case let .missing(w): out += removed(w)
            case let .inserted(w): out += added(w)
            }
        }
        return out
    }

    private func defaultSelection(for engineID: String) -> JobProviderSelection? {
        BenchmarkEngineCatalog.all().first { $0.id == engineID }?.defaultSelection
    }

    private func isCurrentDefault(_ selection: JobProviderSelection) -> Bool {
        SettingsStorage.shared.providerDefaults.selection(for: .dictation).providerID == selection.providerID
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Color("BrandAccentDeep"))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color("BrandTintSoft"), in: Capsule())
    }
}

// MARK: - Shared

private func duration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}

private func card(title: LocalizedStringKey, detail: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(spacing: 0) {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        Divider()
        content()
    }
    .background(Color(.windowBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(.separatorColor), lineWidth: 0.5))
}

private func checkRow(isOn: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> some View) -> some View {
    Button(action: action) {
        HStack(spacing: 12) {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .font(.system(size: 15))
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
            content()
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isOn ? .isSelected : [])
}

private func engineLabel(_ engine: any BenchmarkEngine) -> some View {
    HStack(spacing: 6) {
        Text(engine.name).font(.system(size: 13, weight: .semibold))
        Text(engine.kind == .cloud ? "Cloud" : engine.kind == .local ? "Local" : "On-device")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color(.quaternaryLabelColor).opacity(0.12), in: Capsule())
    }
}
