import Charts
import SwiftUI

struct OverviewView: View {
    @State private var storage = RecordingsLibraryStorage.shared
    @State private var playbackService = AudioPlaybackService.shared
    @State private var timePeriod: TimePeriod = .week
    @State private var selectedRecording: Recording? = nil

    enum TimePeriod: String, CaseIterable {
        case week = "Week"
        case month = "Month"
        case year = "Year"

        var calendarComponent: Calendar.Component {
            switch self { case .week: .weekOfYear; case .month: .month; case .year: .year }
        }
        var daysBack: Int { switch self { case .week: 7; case .month: 30; case .year: 365 } }
        var chartTitle: String { switch self { case .week: "Spoken this week"; case .month: "Spoken this month"; case .year: "Spoken this year" } }
        var chartSubtitle: String { switch self { case .week, .month: "minutes per day"; case .year: "minutes per month" } }
    }

    // MARK: - Filtered recordings

    private var periodStart: Date {
        Calendar.current.date(byAdding: .day, value: -timePeriod.daysBack, to: Date()) ?? Date()
    }

    private var periodRecordings: [Recording] {
        storage.recordings.filter { $0.createdAt >= periodStart }
    }

    // MARK: - Computed stats

    private var totalSeconds: Double {
        periodRecordings.reduce(0) { $0 + $1.durationSeconds }
    }

    private var totalHours: Double { totalSeconds / 3600 }

    private var recordingCount: Int { periodRecordings.count }

    private var totalWords: Int {
        periodRecordings.compactMap(\.transcriptionText).reduce(0) { $0 + $1.split(separator: " ").count }
    }

    private var avgWordsPerMin: Int {
        let withText = periodRecordings.filter { ($0.transcriptionText?.isEmpty == false) }
        guard !withText.isEmpty else { return 0 }
        let words = withText.compactMap(\.transcriptionText).reduce(0) { $0 + $1.split(separator: " ").count }
        let mins = withText.reduce(0) { $0 + $1.durationSeconds } / 60
        guard mins > 0 else { return 0 }
        return Int(Double(words) / mins)
    }

    private var streak: Int {
        let cal = Calendar.current
        var count = 0
        var day = cal.startOfDay(for: Date())
        let allDays = Set(storage.recordings.map { cal.startOfDay(for: $0.createdAt) })
        while allDays.contains(day) {
            count += 1
            day = cal.date(byAdding: .day, value: -1, to: day) ?? day.addingTimeInterval(-86400)
        }
        return count
    }

    // MARK: - Daily series for chart

    struct DayStat: Identifiable {
        let id: Date
        let minutes: Double
        let isToday: Bool
        let isFuture: Bool
        let label: String
    }

    private var dailySeries: [DayStat] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let days = (0 ..< timePeriod.daysBack).map {
            cal.date(byAdding: .day, value: -(timePeriod.daysBack - 1 - $0), to: today)!
        }
        let byDay = Dictionary(grouping: periodRecordings) { cal.startOfDay(for: $0.createdAt) }
        let formatter = DateFormatter()
        formatter.dateFormat = timePeriod == .year ? "MMM" : "EEE"
        return days.map { day in
            let mins = (byDay[day] ?? []).reduce(0) { $0 + $1.durationSeconds } / 60
            return DayStat(
                id: day,
                minutes: mins,
                isToday: day == today,
                isFuture: day > today,
                label: formatter.string(from: day)
            )
        }
    }

    private var avgMinutes: Double {
        let nonEmpty = dailySeries.filter { !$0.isFuture && $0.minutes > 0 }
        guard !nonEmpty.isEmpty else { return 0 }
        return nonEmpty.reduce(0) { $0 + $1.minutes } / Double(nonEmpty.count)
    }

    private var maxMinutes: Double {
        dailySeries.map(\.minutes).max() ?? 1
    }

    // MARK: - Hero description

    private var heroDescription: String {
        let workDays = totalHours / 8.0
        if workDays >= 1 {
            return String(format: "≈ %.1f work days — a short novel, dictated", workDays)
        }
        let mins = Int(totalSeconds / 60)
        return "≈ \(mins) minutes of speaking time"
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Overview")
                    .font(.title2.bold())
                Spacer()
                Picker("", selection: $timePeriod) {
                    ForEach(TimePeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 12) {
                    heroCard
                    metricGrid
                    chartCard
                    recentCard
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $selectedRecording) { recording in
            RecordingDetailView(recording: recording)
                .frame(minWidth: 640, idealWidth: 700, minHeight: 500)
        }
    }

    // MARK: - Hero Card

    private var heroCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("TIME NOT TYPED · THIS \(timePeriod.rawValue.uppercased())")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color("BrandAccentDeep"))
                    .kerning(0.5)

                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", totalHours))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    Text("hrs")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                }

                Text(heroDescription)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("↑ trending")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color("BrandAccentDeep"))
                waveformRibbon
            }
        }
        .padding(20)
        .background(Color("BrandTintSoft"), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color("BrandTintBorder"), lineWidth: 1)
        )
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
                    label: "Recordings spoken"
                )
                MetricCard(
                    icon: "text.alignleft",
                    value: totalWords >= 1000
                        ? String(format: "%.1fk", Double(totalWords) / 1000)
                        : "\(totalWords)",
                    label: "Words dictated"
                )
                MetricCard(
                    icon: "dial.medium",
                    value: "\(avgWordsPerMin)",
                    label: "Avg words / min"
                )
                MetricCard(
                    icon: nil,
                    value: "\(streak)-day",
                    label: streak > 0 ? streakSubtitle : "Start today",
                    isStreak: true,
                    streakCount: streak
                )
            }
        }
    }

    private var streakSubtitle: String {
        "streak"
    }

    // MARK: - Chart Card

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(timePeriod.chartTitle)
                .font(.system(size: 14, weight: .semibold))
            Text(timePeriod.chartSubtitle)
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Chart {
                if avgMinutes > 0 {
                    RuleMark(y: .value("Avg", avgMinutes))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .annotation(position: .trailing) {
                            Text(String(format: "avg %dm", Int(avgMinutes)))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                }

                ForEach(dailySeries) { day in
                    if day.isFuture || day.minutes == 0 {
                        BarMark(
                            x: .value("Day", day.label),
                            y: .value("Min", max(avgMinutes * 0.05, 3))
                        )
                        .foregroundStyle(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    } else {
                        let opacity = 0.25 + 0.6 * (day.minutes / max(maxMinutes, 1))
                        BarMark(
                            x: .value("Day", day.label),
                            y: .value("Min", day.minutes)
                        )
                        .foregroundStyle(
                            day.isToday
                                ? Color("BrandAccentDeep")
                                : Color("BrandAccentDeep").opacity(opacity)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .annotation(position: .top) {
                            if day.isToday && day.minutes > 0 {
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
        .padding(20)
        .background(Color(.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
        )
    }

    // MARK: - Recent Card

    private var recentCard: some View {
        let recent = Array(storage.recordings.prefix(3))
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent recordings")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("See all ›") {
                    MainWindowController.shared.showWindow(section: .recordings)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
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
        .background(Color(.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
        )
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
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(Color("BrandAccentDeep"))
            } else if isStreak {
                streakDots
            }

            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundColor(.primary)

            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
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
                    fileURL: RecordingsLibraryStorage.shared.audioFileURL(for: recording)
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
        if let text = recording.transcriptionText, !text.isEmpty {
            let words = text.split(separator: " ").prefix(6).joined(separator: " ")
            return words.count < text.count ? words + "…" : words
        }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        switch recording.type {
        case .voice: return "Voice note — \(f.string(from: recording.createdAt))"
        case .translation: return "Translation — \(f.string(from: recording.createdAt))"
        case .meeting: return "Meeting — \(f.string(from: recording.createdAt))"
        case .fileTranscription: return "File — \(f.string(from: recording.createdAt))"
        }
    }

    private var formattedDuration: String {
        let total = Int(recording.durationSeconds)
        let m = total / 60; let s = total % 60
        return String(format: "%dm %02ds", m, s)
    }

    private var relativeDay: String {
        let cal = Calendar.current; let now = Date()
        if cal.isDateInToday(recording.createdAt) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return "Today, \(f.string(from: recording.createdAt))"
        }
        if cal.isDateInYesterday(recording.createdAt) { return "Yesterday" }
        let d = cal.dateComponents([.day], from: recording.createdAt, to: now).day ?? 0
        if d < 7 { let f = DateFormatter(); f.dateFormat = "EEE"; return f.string(from: recording.createdAt) }
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none
        return f.string(from: recording.createdAt)
    }
}
