import Charts
import SwiftUI

struct OverviewView: View {
    @State private var storage = RecordingsLibraryStorage.shared
    @State private var playbackService = AudioPlaybackService.shared
    @State private var timePeriod: TimePeriod = .month
    @State private var snapshot = Snapshot()
    @State private var barHeights: [Double] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedRecording: Recording? = nil
    @State private var typingSpeedWordsPerMinute = SettingsStorage.shared.typingSpeedWordsPerMinute

    enum TimePeriod: String, CaseIterable {
        case week = "Week"
        case month = "Month"
        case year = "Year"

        var daysBack: Int {
            switch self { case .week: 7; case .month: 30; case .year: 365 }
        }

        var chartTitle: String {
            switch self {
            case .week: String(
                    localized: "Time saved this week"
                ); case .month: String(
                    localized: "Time saved this month"
                ); case .year: String(localized: "Time saved this year")
            }
        }

        var chartSubtitle: String {
            switch self { case .week,
                 .month: String(localized: "minutes per day"); case .year: String(localized: "minutes per month") }
        }
    }

    // MARK: - Filtered recordings

    private var periodStart: Date {
        if timePeriod == .month { return Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date() }
        return Calendar.current.date(byAdding: .day, value: -timePeriod.daysBack, to: Date()) ?? Date()
    }

    /// Stats rows, including recordings history retention already removed.
    private var periodRecordings: [UsageStatRow] {
        storage.usageStatRows.filter { $0.createdAt >= periodStart }
    }

    // MARK: - Computed stats

    /// Stats are computed once per data/period change, not on every redraw:
    /// each pass word-splits every transcript, and the chart reads them per bar.
    struct Snapshot {
        var period = RecordingStatistics(recordings: [])
        var previousTimeSavedSeconds: Double = 0
        var series: [DayStat] = []
        var avgMinutes: Double = 0
        var maxMinutes: Double = 1
        var streak = 0
    }

    private func rebuildSnapshot() {
        let series = computeChartSeries()
        let nonEmpty = series.filter { !$0.isFuture && $0.minutes > 0 }
        snapshot = Snapshot(
            period: RecordingStatistics(rows: periodRecordings),
            previousTimeSavedSeconds: RecordingStatistics(rows: previousPeriodRecordings)
                .totalTimeSavedSeconds(wordsPerMinute: typingSpeedWordsPerMinute),
            series: series,
            avgMinutes: nonEmpty.isEmpty ? 0 : nonEmpty.reduce(0) { $0 + $1.minutes } / Double(nonEmpty.count),
            maxMinutes: series.map(\.minutes).max() ?? 1,
            streak: computeStreak()
        )
    }

    private var periodStatistics: RecordingStatistics { snapshot.period }

    private var typingTimeSavedSeconds: Double {
        periodStatistics.typingTimeSavedSeconds(wordsPerMinute: typingSpeedWordsPerMinute)
    }

    private var mediaTimeSavedSeconds: Double {
        periodStatistics.mediaTimeSavedSeconds
    }

    private var totalTimeSavedSeconds: Double {
        periodStatistics.totalTimeSavedSeconds(wordsPerMinute: typingSpeedWordsPerMinute)
    }

    private var totalHours: Double {
        totalTimeSavedSeconds / 3600
    }

    private var previousPeriodStart: Date {
        if timePeriod == .month { return Calendar.current.date(byAdding: .month, value: -1, to: periodStart) ?? Date() }
        return Calendar.current.date(byAdding: .day, value: -(timePeriod.daysBack * 2), to: Date()) ?? Date()
    }

    private var previousPeriodRecordings: [UsageStatRow] {
        storage.usageStatRows.filter { $0.createdAt >= previousPeriodStart && $0.createdAt < periodStart }
    }

    private var previousTimeSavedSeconds: Double { snapshot.previousTimeSavedSeconds }

    private var trendPercent: Int? {
        guard previousTimeSavedSeconds > 0 else { return nil }
        return Int(((totalTimeSavedSeconds - previousTimeSavedSeconds) / previousTimeSavedSeconds * 100).rounded())
    }

    private var comparisonLabel: String {
        switch timePeriod {
        case .week:
            return String(localized: "last week")
        case .month:
            let date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM"
            return formatter.string(from: date)
        case .year:
            let year = Calendar.current.component(.year, from: Date()) - 1
            return "\(year)"
        }
    }

    private var recordingCount: Int {
        periodStatistics.recordingCount
    }

    private var totalWords: Int {
        periodStatistics.transcribedWordCount
    }

    private var streak: Int { snapshot.streak }

    private func computeStreak() -> Int {
        let cal = Calendar.current
        var count = 0
        var day = cal.startOfDay(for: Date())
        let allDays = Set(storage.usageStatRows.map { cal.startOfDay(for: $0.createdAt) })
        while allDays.contains(day) {
            count += 1
            day = cal.date(byAdding: .day, value: -1, to: day) ?? day.addingTimeInterval(-86400)
        }
        return count
    }

    // MARK: - Series for chart

    struct DayStat: Identifiable {
        let id: Date
        let minutes: Double
        let isToday: Bool
        let isFuture: Bool
        let label: String
    }

    private var chartSeries: [DayStat] { snapshot.series }

    /// Grows bars from zero, left to right; the whole wave stays within ~0.3s of stagger.
    private func revealBars() {
        let series = chartSeries
        barHeights = Array(repeating: 0, count: series.count)
        guard !reduceMotion else { return syncBars() }
        let step = min(0.03, 0.3 / Double(max(series.count, 1)))
        for (index, day) in series.enumerated() {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85).delay(Double(index) * step)) {
                barHeights[index] = day.minutes
            }
        }
    }

    private func syncBars() {
        barHeights = chartSeries.map(\.minutes)
    }

    private func barHeight(_ index: Int, _ day: DayStat) -> Double {
        barHeights.indices.contains(index) ? barHeights[index] : day.minutes
    }

    private func computeChartSeries() -> [DayStat] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        if timePeriod == .year {
            let currentMonth = cal.date(from: cal.dateComponents([.year, .month], from: today))!
            let months = (0 ..< 12).reversed().compactMap {
                cal.date(byAdding: .month, value: -$0, to: currentMonth)
            }
            let byMonth = Dictionary(grouping: periodRecordings) {
                cal.date(from: cal.dateComponents([.year, .month], from: $0.createdAt))!
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM"
            return months.map { month in
                DayStat(
                    id: month,
                    minutes: RecordingStatistics(rows: byMonth[month] ?? [])
                        .totalTimeSavedSeconds(wordsPerMinute: typingSpeedWordsPerMinute) / 60,
                    isToday: month == currentMonth,
                    isFuture: false,
                    label: formatter.string(from: month)
                )
            }
        }

        let days: [Date] = if timePeriod == .month {
            // Whole calendar month; days after today render as future placeholders.
            (cal.range(of: .day, in: .month, for: today) ?? 1 ..< 31).compactMap {
                cal.date(byAdding: .day, value: $0 - 1, to: periodStart)
            }
        } else {
            (0 ..< timePeriod.daysBack).map {
                cal.date(byAdding: .day, value: -(timePeriod.daysBack - 1 - $0), to: today)!
            }
        }
        let byDay = Dictionary(grouping: periodRecordings) { cal.startOfDay(for: $0.createdAt) }
        let formatter = DateFormatter()
        formatter.dateFormat = timePeriod == .month ? "d" : "EEE"
        return days.map { day in
            let mins = RecordingStatistics(rows: byDay[day] ?? [])
                .totalTimeSavedSeconds(wordsPerMinute: typingSpeedWordsPerMinute) / 60
            return DayStat(
                id: day,
                minutes: mins,
                isToday: day == today,
                isFuture: day > today,
                label: formatter.string(from: day)
            )
        }
    }

    private var avgMinutes: Double { snapshot.avgMinutes }

    private var maxMinutes: Double { snapshot.maxMinutes }

    // MARK: - Hero description

    private var heroDescription: String {
        guard totalTimeSavedSeconds > 0 else {
            return String(localized: "Based on \(formatWordsPerMinute(typingSpeedWordsPerMinute)) WPM typing baseline")
        }

        return String(
            localized: "\(formatDurationCompact(typingTimeSavedSeconds)) typing · \(formatDurationCompact(mediaTimeSavedSeconds)) media"
        )
    }

    // MARK: - Body

    var body: some View {
        PageScaffold(title: "Overview") {
            Picker("", selection: $timePeriod) {
                ForEach(TimePeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
        } content: {
            VStack(spacing: DS.Space.md) {
                OverviewLaunchCard()
                heroCard
                metricGrid
                chartCard
                recentCard
            }
        }
        .sheet(item: Binding(
            get: { selectedRecording },
            set: { next in
                guard next?.id != selectedRecording?.id else { return }
                guard RecordingTrimNavigation.shared.requestLeave() else { return }
                selectedRecording = next
            }
        )) { recording in
            RecordingDetailView(recording: recording, onClose: { selectedRecording = nil })
                .frame(minWidth: 640, idealWidth: 700, minHeight: 500)
                .interactiveDismissDisabled(RecordingTrimNavigation.shared.isEditing)
        }
        .onReceive(NotificationCenter.default.publisher(for: .typingSpeedSettingsChanged)) { _ in
            typingSpeedWordsPerMinute = SettingsStorage.shared.typingSpeedWordsPerMinute
        }
        .onAppear { rebuildSnapshot(); revealBars() }
        .onChange(of: timePeriod) { rebuildSnapshot(); revealBars() }
        .onChange(of: storage.recordings) { rebuildSnapshot(); syncBars() }
        .onChange(of: typingSpeedWordsPerMinute) { rebuildSnapshot(); syncBars() }
    }

    // MARK: - Hero Card

    private var heroCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    "TIME SAVED · THIS \(NSLocalizedString(timePeriod.rawValue, comment: "Overview period").uppercased())"
                )
                .font(DS.Font.caption.weight(.semibold))
                .foregroundColor(DS.Palette.accent)
                .kerning(0.5)

                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", totalHours))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    Text("hrs")
                        .font(DS.Font.headline)
                        .foregroundColor(.primary)
                }

                Text(heroDescription)
                    .font(DS.Font.callout)
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                trendView
                waveformRibbon
            }
        }
        .padding(DS.Space.lg)
        .background(Color("BrandTintSoft"), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color("BrandTintBorder"), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var trendView: some View {
        if let value = trendPercent {
            let arrow = value >= 0 ? "↗" : "↘"
            let magnitude = abs(value)
            (Text(arrow).foregroundColor(value >= 0 ? .green : .red) +
                Text(" \(magnitude)% vs \(comparisonLabel)").foregroundColor(.secondary))
                .font(.system(size: 12, weight: .medium))
        }
    }

    private var waveformRibbon: some View {
        let heights: [Double] = [0.3, 0.5, 0.4, 0.7, 1.0, 0.8, 0.6, 0.9, 0.5, 0.3, 0.6, 0.4]
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color("BrandAccentDeep").opacity(0.25 + 0.6 * h))
                    .frame(width: 4, height: CGFloat(h) * 44)
            }
        }
        .frame(height: 44)
    }

    // MARK: - Metric Grid

    private var metricGrid: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                MetricCard(
                    icon: "waveform",
                    value: "\(recordingCount)",
                    label: "Recordings"
                )
                MetricCard(
                    icon: "text.alignleft",
                    value: totalWords >= 1000
                        ? String(format: "%.1fk", Double(totalWords) / 1000)
                        : "\(totalWords)",
                    label: String(localized: "Words transcribed")
                )
                MetricCard(
                    icon: "dial.medium",
                    value: "\(formatWordsPerMinute(typingSpeedWordsPerMinute))",
                    label: "Typing speed WPM"
                )
                MetricCard(
                    icon: nil,
                    value: String(localized: "\(streak)-day streak"),
                    label: streak > 0 ? streakSubtitle : String(localized: "Start today"),
                    isStreak: true,
                    streakCount: streak
                )
            }
        }
    }

    private var streakSubtitle: String {
        String(localized: "\(max(0, 14 - streak)) days to milestone")
    }

    // MARK: - Chart Card

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(timePeriod.chartTitle)
                .font(DS.Font.headline)
            Text(timePeriod.chartSubtitle)
                .font(DS.Font.callout)
                .foregroundColor(.secondary)

            Chart {
                if avgMinutes > 0 {
                    RuleMark(y: .value("Avg", avgMinutes))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .annotation(position: .trailing) {
                            Text(String(format: String(localized: "avg %dm"), locale: Locale.current, Int(avgMinutes)))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                }

                ForEach(Array(chartSeries.enumerated()), id: \.element.id) { index, day in
                    if day.isFuture || day.minutes == 0 {
                        BarMark(
                            x: .value("Day", day.label),
                            y: .value("Min", max(avgMinutes * 0.05, 3))
                        )
                        .foregroundStyle(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .accessibilityHidden(true)
                    } else {
                        let opacity = 0.25 + 0.6 * (day.minutes / max(maxMinutes, 1))
                        BarMark(
                            x: .value("Day", day.label),
                            y: .value("Min", barHeight(index, day))
                        )
                        .foregroundStyle(
                            day.isToday
                                ? Color("BrandAccentDeep")
                                : Color("BrandAccentDeep").opacity(opacity)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .annotation(position: .top) {
                            if day.isToday, day.minutes > 0, barHeight(index, day) >= day.minutes {
                                Text(String(format: "%dm", Int(day.minutes)))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Color("BrandAccentDeep"))
                            }
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondary)
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 120)
            .padding(.top, 8)
        }
        .padding(DS.Space.lg)
        .background(DS.Palette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(DS.Palette.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Recent Card

    private var recentCard: some View {
        let recent = Array(storage.recordings.prefix(3))
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent recordings")
                    .font(DS.Font.headline)
                Spacer()
                Button("See all ›") {
                    MainWindowController.shared.showWindow(section: .recordings)
                }
                .buttonStyle(.plain)
                .font(DS.Font.callout)
                .foregroundColor(Color("BrandAccentDeep"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if recent.isEmpty {
                Text("No recordings yet")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            } else {
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, recording in
                    RecentRow(recording: recording, playbackService: playbackService) {
                        selectedRecording = recording
                    }
                    if index < recent.count - 1 {
                        Divider().padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .background(DS.Palette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(DS.Palette.cardBorder, lineWidth: 1)
        )
    }

    private func formatWordsPerMinute(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    private func formatDurationCompact(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        if totalMinutes >= 60 {
            let hours = Double(totalMinutes) / 60
            return String(format: String(localized: "≈ %.1f hrs"), locale: Locale.current, hours)
        }
        return String(localized: "≈ \(totalMinutes) min")
    }
}

// MARK: - Metric Card

private struct MetricCard: View {
    let icon: String?
    let value: String
    let label: String
    var isStreak: Bool = false
    var streakCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let icon {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color("BrandTintSoft"))
                        .frame(width: 26, height: 26)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color("BrandAccentDeep"))
                }
            } else if isStreak {
                streakDots
            }

            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Text(LocalizedStringKey(label))
                .font(DS.Font.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            isStreak ? Color("BrandTintSoft") : DS.Palette.cardFill
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(DS.Palette.cardBorder, lineWidth: 1)
        )
    }

    private var streakDots: some View {
        HStack(spacing: 4) {
            ForEach(0 ..< min(streakCount, 7), id: \.self) { _ in
                Circle()
                    .fill(Color("BrandAccentDeep"))
                    .frame(width: 6, height: 6)
            }
        }
    }
}

// MARK: - Recent Row

private struct RecentRow: View {
    let recording: Recording
    let playbackService: AudioPlaybackService
    let onTap: () -> Void

    private var isPlaying: Bool {
        playbackService.playingRecordingId == recording.id && playbackService.isPlaying
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                playbackService.togglePlayback(
                    recordingId: recording.id,
                    fileURL: RecordingsLibraryStorage.shared.audioFileURL(for: recording),
                    trimRange: recording.trimRange
                )
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(.quaternaryLabelColor).opacity(0.12))
                        .frame(width: 28, height: 28)
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color("BrandAccentDeep"))
                        .offset(x: isPlaying ? 0 : 0.5)
                }
            }
            .buttonStyle(.plain)

            Text(rowTitle)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(formattedDuration)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                Text(relativeDay)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var rowTitle: String {
        if let specificTitle = recording.specificTitle { return specificTitle }
        if let text = recording.transcriptionText, !text.isEmpty {
            let words = text.split(separator: " ").prefix(6).joined(separator: " ")
            return words.count < text.count ? words + "…" : words
        }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        switch recording.type {
        case .voice: return String(localized: "Voice note — \(f.string(from: recording.createdAt))")
        case .translation: return String(localized: "Translation — \(f.string(from: recording.createdAt))")
        case .meeting: return String(localized: "Meeting — \(f.string(from: recording.createdAt))")
        case .meetingTranslation: return String(
                localized: "Meeting translation — \(f.string(from: recording.createdAt))"
            )
        case .fileTranscription: return String(localized: "File — \(f.string(from: recording.createdAt))")
        }
    }

    private var formattedDuration: String {
        let total = Int(recording.effectiveDurationSeconds)
        let m = total / 60; let s = total % 60
        return String(format: String(localized: "%dm %02ds"), locale: Locale.current, m, s)
    }

    private var relativeDay: String {
        let cal = Calendar.current; let now = Date()
        if cal.isDateInToday(recording.createdAt) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return String(localized: "Today, \(f.string(from: recording.createdAt))")
        }
        if cal.isDateInYesterday(recording.createdAt) { return String(localized: "Yesterday") }
        let d = cal.dateComponents([.day], from: recording.createdAt, to: now).day ?? 0
        if d < 7 { let f = DateFormatter(); f.dateFormat = "EEE"; return f.string(from: recording.createdAt) }
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none
        return f.string(from: recording.createdAt)
    }
}
