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
    var onClose: () -> Void

    @State private var selectedLanguage: TypingTestLanguage = .english
    @State private var typedText = ""
    @State private var startedAt: Date?
    @State private var completedAt: Date?
    @State private var now = Date()
    @State private var savedWordsPerMinute = SettingsStorage.shared.typingSpeedWordsPerMinute
    @State private var didSaveResult = false
    @FocusState private var isInputFocused: Bool

    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var sampleText: String {
        selectedLanguage.sampleText
    }

    private var elapsedSeconds: TimeInterval {
        guard let startedAt else { return 0 }
        return (completedAt ?? now).timeIntervalSince(startedAt)
    }

    private var measurement: TypingSpeedMeasurement {
        TypingSpeedMeasurement.evaluate(
            typedText: typedText,
            targetText: sampleText,
            elapsedSeconds: max(elapsedSeconds, 1)
        )
    }

    private var canSaveResult: Bool {
        measurement.completion >= 1 && measurement.netWordsPerMinute >= 5
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                metrics
                samplePanel
                inputPanel
                footer
            }
            .padding(20)
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
        .onChange(of: typedText) { _, newValue in
            handleInputChange(newValue)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Typing Speed Test")
                    .font(.system(size: 17, weight: .semibold))
                Text("\(formatWordsPerMinute(savedWordsPerMinute)) WPM saved")
                    .font(.caption)
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
        .padding(.horizontal, 20)
        .padding(.top, 16)
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
                metricTile(
                    title: "Progress",
                    value: "\(formatPercent(measurement.completion))%",
                    icon: "chart.line.uptrend.xyaxis"
                )
            }
        }
    }

    private var samplePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sample")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            Text(sampleText)
                .font(.system(size: 15))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            ProgressView(value: measurement.completion)
                .tint(Color("BrandAccentDeep"))
        }
    }

    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Input")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if didSaveResult {
                    Text("Saved")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .transition(.opacity)
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $typedText)
                    .focused($isInputFocused)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 130)

                if typedText.isEmpty {
                    Text("Start typing")
                        .font(.system(size: 15))
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

            Spacer()

            Button("Close", action: onClose)
                .keyboardShortcut("w", modifiers: .command)

            Button {
                saveResult()
            } label: {
                Label("Save Result", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color("BrandAccentDeep"))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSaveResult)
        }
    }

    private var inputBorderColor: Color {
        if typedText.isEmpty { return Color.secondary.opacity(0.18) }
        if measurement.completion >= 1 {
            return measurement.accuracy >= 0.95 ? Color.green.opacity(0.55) : Color.orange.opacity(0.65)
        }
        return Color("BrandAccentDeep").opacity(0.35)
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
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func handleInputChange(_ text: String) {
        didSaveResult = false

        if startedAt == nil, !text.isEmpty {
            startedAt = Date()
            completedAt = nil
        }

        if text.isEmpty {
            startedAt = nil
            completedAt = nil
            return
        }

        if completedAt == nil, text.count >= sampleText.count {
            completedAt = Date()
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
