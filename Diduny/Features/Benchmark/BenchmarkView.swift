import SwiftUI

struct BenchmarkView: View {
    @State private var runner = BenchmarkRunner.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let run = runner.current {
                BenchmarkResultsView(run: run, runner: runner)
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.985)))
            } else {
                BenchmarkSetupView(runner: runner)
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.985)))
            }
        }
        .animation(reduceMotion ? DS.Motion.reduced : DS.Motion.easeOut(0.2), value: runner.current == nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private enum BenchmarkLayout {
    static let recordingRowHeight: CGFloat = 32
}

// MARK: - Setup

private struct BenchmarkSetupView: View {
    let runner: BenchmarkRunner
    @State private var storage = RecordingsLibraryStorage.shared
    @State private var selectedRecordings: Set<UUID> = []
    @State private var selectedEngines: Set<String> = []
    @State private var language = BenchmarkRun.autoLanguage
    @State private var engines: [any BenchmarkEngine] = BenchmarkEngineCatalog.all()

    private var playable: [Recording] {
        storage.recordings.filter { storage.hasPlayableAudio(for: $0) && $0.status != .recording }
    }

    private var ready: [any BenchmarkEngine] { engines.filter { $0.availability() == .ready } }
    private var unavailable: [any BenchmarkEngine] { engines.filter { $0.availability() != .ready } }

    var body: some View {
        PageScaffold(title: "Benchmark", subtitle: "Compare transcription engines on your own recordings.") {
            Button(runTitle) {
                let recs = playable.filter { selectedRecordings.contains($0.id) }
                runner.start(recordings: recs, engines: ready.filter { selectedEngines.contains($0.id) }, language: language)
            }
            .buttonStyle(.borderedProminent)
            .tint(DS.Palette.accent)
            .disabled(selectedRecordings.isEmpty || selectedEngines.count < 2)
            .keyboardShortcut("r", modifiers: .command)
        } content: {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                card(title: "Recordings", detail: recordingsDetail) {
                    if playable.isEmpty {
                        Text("No recordings yet. Record something first.").foregroundStyle(.secondary).padding(DS.Space.lg)
                    } else {
                        // About 10 rows of 32 pt; longer libraries scroll inside the card.
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(playable) { recording in
                                    recordingRow(recording)
                                }
                            }
                        }
                        .frame(height: min(CGFloat(playable.count), 10) * BenchmarkLayout.recordingRowHeight)
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
                                .font(DS.Font.callout).foregroundStyle(.green)
                        }
                    }
                    if !unavailable.isEmpty {
                        Text("Not available").font(DS.Font.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.quaternaryLabelColor).opacity(0.12))
                        ForEach(unavailable, id: \.id) { engine in
                            HStack(spacing: DS.Space.md) {
                                Image(systemName: "square").foregroundStyle(.tertiary)
                                engineLabel(engine)
                                Spacer()
                                Text(reason(engine.availability())).font(DS.Font.callout).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
                            .opacity(0.6)
                        }
                    }
                }

                HStack {
                    Picker("Language", selection: $language) {
                        Text("Auto (per recording)").tag(BenchmarkRun.autoLanguage)
                        ForEach(SettingsStorage.shared.favoriteLanguages, id: \.self) { code in
                            Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                        }
                    }
                    .frame(width: 220)
                    Spacer()
                    Button("Clear") { selectedRecordings = []; selectedEngines = [] }
                        .buttonStyle(.bordered)
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
                                            .font(DS.Font.headline)
                                        Text("\(run.clips.count) recordings · \(run.engines.map(\.name).joined(separator: ", "))")
                                            .font(DS.Font.callout).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button(role: .destructive) { runner.delete(run) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain).foregroundStyle(.red).help("Delete benchmark")
                            }
                            .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
                        }
                    }
                }
            }
        }
        .onAppear { engines = BenchmarkEngineCatalog.all() }
    }

    /// Single-line 32 pt row: checkbox, "Title · date, time", truncated preview, monospaced duration.
    private func recordingRow(_ recording: Recording) -> some View {
        let isOn = selectedRecordings.contains(recording.id)
        return Button {
            toggle(&selectedRecordings, recording.id)
        } label: {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(DS.Font.body)
                    .foregroundStyle(isOn ? DS.Palette.accent : .secondary)
                HStack(spacing: DS.Space.xs) {
                    Text(recording.displayTitle).font(DS.Font.body.weight(.medium))
                    Text("· \(recording.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(DS.Font.caption).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
                Text(recording.transcriptionText ?? "")
                    .font(DS.Font.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(duration(recording.effectiveDurationSeconds))
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.Space.lg)
            .frame(height: BenchmarkLayout.recordingRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
        PageScaffold(
            title: runner.isRunning ? "Running benchmark" : "Benchmark results",
            subtitle: "\(run.clips.count) recordings · \(run.engines.count) engines · \(duration(run.audioSeconds)) audio\(run.cancelled ? " · cancelled, partial" : "")"
        ) {
            if runner.isRunning {
                ProgressView(value: Double(runner.progress.done), total: Double(max(runner.progress.total, 1)))
                    .tint(DS.Palette.accent)
                    .frame(width: 160)
                Button("Cancel") { runner.cancel() }
                    .buttonStyle(.bordered)
            } else {
                Picker("Reference", selection: Binding(get: { run.referenceEngineID }, set: { runner.setReference($0) })) {
                    ForEach(run.engines) { Text($0.name).tag($0.id) }
                }
                .frame(width: 220)
                Button("New benchmark") { runner.close() }
                    .buttonStyle(.bordered)
            }
        } content: {
VStack(alignment: .leading, spacing: DS.Space.md) {
                summaryTable

                if excludedClips > 0 && !runner.isRunning {
                    Text("\(excludedClips) clips excluded (empty or failed)")
                        .font(DS.Font.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: DS.Space.xs) {
                    Text("Difference = share of Reference words that changed. Speed = Stop to final text.")
                        .font(DS.Font.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    Image(systemName: "info.circle")
                        .font(DS.Font.caption).foregroundStyle(.secondary)
                        .help("Difference is the share of Reference words this engine got different (lower is closer). Reference is the selected engine's text; for Diduny that is the text before server cleanup. Speed is the time from Stop to final text; Diduny is replayed over the live socket like real dictation.")
                        .accessibilityLabel("About Difference and Speed")
                }

                HStack(spacing: DS.Space.md) {
                    Picker("Filter", selection: $filter) {
                        Text("\(String(localized: "All clips")) \(run.clips.count)").tag("all")
                        Text("\(String(localized: "Differences")) \(differingClipCount)").tag("diff")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                    Spacer(minLength: DS.Space.md)
                    Toggle("Count punctuation and case", isOn: $strict)
                        .toggleStyle(.checkbox)
                        .font(DS.Font.callout)
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
                .background(DS.Palette.cardFill)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.cardBorder, lineWidth: 1))
            }
        }
    }

private var visibleClips: [BenchmarkRun.Clip] {
        filter == "diff" ? run.clips.filter { clip in run.engines.contains { $0.id != run.referenceEngineID && differs(clip, $0.id) } } : run.clips
    }

    private var differingClipCount: Int {
        run.clips.filter { clip in run.engines.contains { $0.id != run.referenceEngineID && differs(clip, $0.id) } }.count
    }

    /// How the engine runs, so "Diduny" isn't read as just another model.
    private func modeLabel(_ engine: BenchmarkRun.Engine) -> String {
        if engine.id == "diduny" { return String(localized: "Realtime · cloud") }
        return engine.kind == .cloud ? String(localized: "Cloud") : String(localized: "On-device")
    }

    private func diff(_ clip: BenchmarkRun.Clip, _ engineID: String) -> WordDiff.Result? {
        guard let text = run.cell(clip.id, engineID)?.text,
              let ref = run.cell(clip.id, run.referenceEngineID)?.text else { return nil }
        return WordDiff.compare(text, reference: ref, strict: strict)
    }

    private func differs(_ clip: BenchmarkRun.Clip, _ engineID: String) -> Bool {
        (diff(clip, engineID)?.errors ?? 0) > 0
    }

    private var excludedClips: Int {
        run.engines.map { run.summary(for: $0.id, strict: strict).excluded }.max() ?? 0
    }

    // MARK: Summary table

    private enum Col {
        static let speed: CGFloat = 90
        static let difference: CGFloat = 100
        static let action: CGFloat = 130
        static let rowHeight: CGFloat = 40
    }

    private struct Row {
        let engine: BenchmarkRun.Engine
        let isReference: Bool
        let rate: Double?
        let averageSeconds: Double?
    }

    private var rows: [Row] {
        run.engines.map { engine in
            let s = run.summary(for: engine.id, strict: strict)
            let finished = run.clips.filter { run.cell($0.id, engine.id)?.text != nil }.count
            return Row(engine: engine, isReference: engine.id == run.referenceEngineID, rate: s.rate,
                       averageSeconds: finished > 0 ? s.seconds / Double(finished) : nil)
        }
    }

    private var summaryTable: some View {
        let rows = rows
        let timed = rows.compactMap(\.averageSeconds)
        let fastest = !runner.isRunning && timed.count > 1 ? timed.min() : nil
        return Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: DS.Space.md) {
                    Text("Engine").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Speed").frame(width: Col.speed, alignment: .trailing)
                    Text("Difference").frame(width: Col.difference, alignment: .trailing)
                    Color.clear.frame(width: Col.action, height: 1)
                }
                .font(DS.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
                ForEach(rows, id: \.engine.id) { row in
                    RowSeparator()
                    tableRow(row, isFastest: fastest != nil && row.averageSeconds == fastest)
                }
            }
        }
    }

    private func tableRow(_ row: Row, isFastest: Bool) -> some View {
        let pending = runner.isRunning
        let speed = row.averageSeconds.map { String(format: "%.2f s", $0) } ?? (pending ? "…" : "—")
        let difference: String = row.isReference ? String(localized: "Reference")
            : row.rate.map { String(format: "%.1f%%", $0 * 100) } ?? (pending ? "…" : "—")
        let selection = defaultSelection(for: row.engine.id)
        let isDefault = selection.map { isCurrentDefault($0) } ?? false
        return HStack(spacing: DS.Space.md) {
            HStack(spacing: DS.Space.sm) {
                Text(row.engine.name).font(DS.Font.headline).lineLimit(1)
                Text(modeLabel(row.engine))
                    .font(DS.Font.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color(.separatorColor).opacity(0.5), in: Capsule())
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(speed)
                .font(.system(size: 13, weight: isFastest ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(isFastest ? DS.Palette.accent : Color.primary)
                .frame(width: Col.speed, alignment: .trailing)
            Text(difference)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(row.isReference ? Color.secondary : Color.primary)
                .frame(width: Col.difference, alignment: .trailing)
            Group {
                if isDefault {
                    badge("Default")
                } else if let selection, !pending {
                    Button("Make default") {
                        SettingsStorage.shared.providerDefaults.setSelection(selection, for: .dictation)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Color.clear
                }
            }
            .frame(width: Col.action, alignment: .trailing)
        }
        .padding(.horizontal, DS.Space.lg)
        .frame(height: Col.rowHeight)
        .accessibilityElement(children: .combine)
    }

    
    private func clipBlock(_ clip: BenchmarkRun.Clip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(clip.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                if let code = run.clipLanguages?[clip.id] {
                    Text(code.uppercased()).font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color(.separatorColor), in: RoundedRectangle(cornerRadius: 4))
                        .help("Language Diduny detected for this recording")
                }
                Text(duration(clip.durationSeconds)).font(.system(size: 12, weight: .medium, design: .monospaced))
                Text(clip.createdAt, style: .date).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(run.engines) { engine in
                engineRow(clip, engine)
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
                    if !isRef, let diff, diff.rate > 0.6 {
                        // Word marks are noise when almost nothing matches: show the text as is.
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Mostly different from Reference").font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                            Text(text)
                        }
                    } else if !isRef, let diff { Text(highlighted(diff)) } else { Text(text) }
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
            Text(title).font(DS.Font.headline)
            Spacer()
            Text(detail).font(DS.Font.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
        RowSeparator()
        content()
    }
    .background(DS.Palette.cardFill)
    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.cardBorder, lineWidth: 1))
}

private func checkRow(isOn: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> some View) -> some View {
    Button(action: action) {
        HStack(spacing: 12) {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .font(.system(size: 15))
                .foregroundStyle(isOn ? DS.Palette.accent : .secondary)
            content()
        }
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
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
