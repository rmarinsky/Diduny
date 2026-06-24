import SwiftUI

private enum TypingTestLanguage: String, CaseIterable, Identifiable {
    case english
    case ukrainian

    var id: String { rawValue }

    var label: String {
        switch self {
        case .english: "English"
        case .ukrainian: "Ukrainian"
        }
    }

    var sampleText: String {
        switch self {
        case .english:
            "Diduny turns spoken ideas into polished text, so notes, messages, and drafts can move faster without breaking the flow of work."
        case .ukrainian:
            "Дідуня перетворює голос на охайний текст, щоб нотатки, повідомлення та чернетки з'являлися швидше і не ламали робочий ритм."
        }
    }
}

struct TypingTestView: View {
    @State private var selectedLanguage: TypingTestLanguage = .english
    @State private var typedText = ""
    @State private var startedAt: Date?
    @State private var completedAt: Date?
    @State private var now = Date()
    @State private var savedWordsPerMinute = SettingsStorage.shared.typingSpeedWordsPerMinute
    @State private var didSaveResult = false
    @State private var totalInsertionCount = 0
    @State private var incorrectInsertionCount = 0
    @State private var correctionCount = 0
    @State private var correctionTimeSeconds: TimeInterval = 0
    @State private var activeMistakeStartedAt: Date?
    @FocusState private var isInputFocused: Bool

    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var sampleText: String {
        selectedLanguage.sampleText
    }

    private var elapsedSeconds: TimeInterval {
        guard let startedAt else { return 0 }
        return (completedAt ?? now).timeIntervalSince(startedAt)
    }

    private var displayedCorrectionTimeSeconds: TimeInterval {
        guard let activeMistakeStartedAt else { return correctionTimeSeconds }
        return correctionTimeSeconds + now.timeIntervalSince(activeMistakeStartedAt)
    }

    private var measurement: TypingSpeedMeasurement {
        TypingSpeedMeasurement.evaluate(
            typedText: typedText,
            targetText: sampleText,
            elapsedSeconds: max(elapsedSeconds, 1),
            totalInsertionCount: totalInsertionCount,
            incorrectInsertionCount: incorrectInsertionCount,
            correctionCount: correctionCount,
            correctionTimeSeconds: displayedCorrectionTimeSeconds
        )
    }

    private var isExactComplete: Bool {
        typedText == sampleText
    }

    private var canSaveResult: Bool {
        isExactComplete && measurement.netWordsPerMinute >= 5
    }

    private var extraTypedText: String {
        let typed = Array(typedText)
        let targetCount = Array(sampleText).count
        guard typed.count > targetCount else { return "" }
        return String(typed.dropFirst(targetCount))
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    metrics
                    referencePanel
                    inputPanel
                    footer
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            isInputFocused = true
        }
        .onReceive(timer) { value in
            now = value
        }
        .onChange(of: selectedLanguage) { _, _ in
            resetTest()
        }
        .onChange(of: typedText) { oldValue, newValue in
            handleInputChange(oldValue: oldValue, newValue: newValue)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Typing Speed Test")
                    .font(.system(size: 22, weight: .bold))
                Text("Saved baseline: \(formatWordsPerMinute(savedWordsPerMinute)) WPM")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Picker("Language", selection: $selectedLanguage) {
                ForEach(TypingTestLanguage.allCases) { language in
                    Text(language.label).tag(language)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 220)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var metrics: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                metricTile(
                    title: "Net speed",
                    value: "\(formatWordsPerMinute(measurement.netWordsPerMinute)) WPM",
                    icon: "speedometer"
                )
                metricTile(
                    title: "Accuracy",
                    value: "\(formatPercent(measurement.accuracy))%",
                    icon: "checkmark.circle"
                )
                metricTile(
                    title: "Elapsed",
                    value: formatElapsed(elapsedSeconds),
                    icon: "timer"
                )
            }

            GridRow {
                metricTile(
                    title: "Fix time",
                    value: formatElapsed(displayedCorrectionTimeSeconds),
                    icon: "wrench.adjustable"
                )
                metricTile(
                    title: "Errors",
                    value: "\(incorrectInsertionCount)",
                    icon: "exclamationmark.triangle"
                )
                metricTile(
                    title: "Edits",
                    value: "\(correctionCount)",
                    icon: "delete.left"
                )
            }
        }
    }

    private var referencePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Reference")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(formatPercent(measurement.completion))% complete")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            Text(annotatedSampleText)
                .font(.system(size: 16))
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            if !extraTypedText.isEmpty {
                Text("Extra input: \(extraTypedText)")
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .lineLimit(2)
            }

            ProgressView(value: measurement.completion)
                .tint(Color("BrandAccentDeep"))
        }
    }

    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Input")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if didSaveResult {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .transition(.opacity)
                } else if measurement.activeMistakeCount > 0 {
                    Label("\(measurement.activeMistakeCount) active", systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $typedText)
                    .focused($isInputFocused)
                    .font(.system(size: 16))
                    .lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 176)

                if typedText.isEmpty {
                    Text("Repeat the reference text exactly")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(inputBorderColor, lineWidth: 1)
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                resetTest()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }

            Text(footerStatus)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer()

            Button {
                saveResult()
            } label: {
                Label("Save Baseline", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color("BrandAccentDeep"))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSaveResult)
        }
    }

    private var footerStatus: String {
        if isExactComplete {
            return "Exact match. Saving uses net WPM, including corrections."
        }
        if measurement.activeMistakeCount > 0 {
            return "Fix highlighted characters before saving."
        }
        return "Accuracy includes mistyped characters even after they are corrected."
    }

    private var inputBorderColor: Color {
        if typedText.isEmpty { return Color.secondary.opacity(0.18) }
        if isExactComplete { return Color.green.opacity(0.55) }
        if measurement.activeMistakeCount > 0 { return Color.red.opacity(0.55) }
        return Color("BrandAccentDeep").opacity(0.35)
    }

    private var annotatedSampleText: AttributedString {
        let targetCharacters = Array(sampleText)
        let typedCharacters = Array(typedText)
        var result = AttributedString()

        for index in targetCharacters.indices {
            var segment = AttributedString(String(targetCharacters[index]))

            if typedCharacters.indices.contains(index) {
                if typedCharacters[index] == targetCharacters[index] {
                    segment.foregroundColor = Color.green
                    segment.backgroundColor = Color.green.opacity(0.16)
                } else {
                    segment.foregroundColor = Color.red
                    segment.backgroundColor = Color.red.opacity(0.16)
                }
            } else if index == typedCharacters.count {
                segment.foregroundColor = .primary
                segment.backgroundColor = Color("BrandAccentDeep").opacity(0.14)
            } else {
                segment.foregroundColor = .secondary
            }

            result.append(segment)
        }

        return result
    }

    private func metricTile(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color("BrandAccentDeep"))
                .frame(width: 24, height: 24)
                .background(Color("BrandAccentDeep").opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 62)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func handleInputChange(oldValue: String, newValue: String) {
        didSaveResult = false
        let eventDate = Date()

        recordEdit(from: oldValue, to: newValue)

        if startedAt == nil, !newValue.isEmpty {
            startedAt = eventDate
            completedAt = nil
        }

        if newValue.isEmpty {
            startedAt = nil
            completedAt = nil
            correctionTimeSeconds = 0
            activeMistakeStartedAt = nil
            return
        }

        updateCorrectionClock(for: newValue, at: eventDate)

        if completedAt == nil, newValue == sampleText {
            completedAt = eventDate
        } else if newValue != sampleText {
            completedAt = nil
        }
    }

    private func recordEdit(from oldValue: String, to newValue: String) {
        let oldCharacters = Array(oldValue)
        let newCharacters = Array(newValue)
        let targetCharacters = Array(sampleText)
        let diff = replacementDiff(from: oldCharacters, to: newCharacters)

        correctionCount += diff.removedCount
        totalInsertionCount += diff.insertedCharacters.count

        for pair in diff.insertedCharacters {
            guard targetCharacters.indices.contains(pair.index),
                  targetCharacters[pair.index] == pair.character
            else {
                incorrectInsertionCount += 1
                continue
            }
        }
    }

    private func replacementDiff(
        from oldCharacters: [Character],
        to newCharacters: [Character]
    ) -> (removedCount: Int, insertedCharacters: [(index: Int, character: Character)]) {
        var prefixCount = 0
        while prefixCount < oldCharacters.count,
              prefixCount < newCharacters.count,
              oldCharacters[prefixCount] == newCharacters[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        while oldCharacters.count - suffixCount > prefixCount,
              newCharacters.count - suffixCount > prefixCount,
              oldCharacters[oldCharacters.count - suffixCount - 1] == newCharacters[newCharacters.count - suffixCount - 1] {
            suffixCount += 1
        }

        let removedCount = max(oldCharacters.count - prefixCount - suffixCount, 0)
        let insertedEnd = max(newCharacters.count - suffixCount, prefixCount)
        let insertedCharacters = (prefixCount ..< insertedEnd).map { index in
            (index: index, character: newCharacters[index])
        }

        return (removedCount, insertedCharacters)
    }

    private func updateCorrectionClock(for text: String, at date: Date) {
        let hasMistake = activeMistakeCount(in: text) > 0

        if hasMistake, activeMistakeStartedAt == nil {
            activeMistakeStartedAt = date
        } else if !hasMistake, let startedAt = activeMistakeStartedAt {
            correctionTimeSeconds += max(date.timeIntervalSince(startedAt), 0)
            activeMistakeStartedAt = nil
        }
    }

    private func activeMistakeCount(in text: String) -> Int {
        let typedCharacters = Array(text)
        let targetCharacters = Array(sampleText)

        return typedCharacters.enumerated().reduce(0) { count, pair in
            guard targetCharacters.indices.contains(pair.offset),
                  targetCharacters[pair.offset] == pair.element
            else {
                return count + 1
            }
            return count
        }
    }

    private func saveResult() {
        let sanitized = SettingsStorage.sanitizedTypingSpeedWordsPerMinute(measurement.netWordsPerMinute)
        SettingsStorage.shared.typingSpeedWordsPerMinute = sanitized
        savedWordsPerMinute = sanitized
        didSaveResult = true
    }

    private func resetTest() {
        typedText = ""
        startedAt = nil
        completedAt = nil
        now = Date()
        didSaveResult = false
        totalInsertionCount = 0
        incorrectInsertionCount = 0
        correctionCount = 0
        correctionTimeSeconds = 0
        activeMistakeStartedAt = nil
        isInputFocused = true
    }

    private func formatWordsPerMinute(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.0f", value * 100)
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
