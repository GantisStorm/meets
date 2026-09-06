import SwiftUI
import MeetsCore

struct InsightsView: View {
    let initialSection: InsightsSection
    let loadSnapshot: (InsightsRange) async throws -> InsightsSnapshot
    let onBack: () -> Void
    let backLabel: String
    /// Opens the Calendar dashboard page with a list filter applied
    /// ("all" | "upcoming" | "past" | "recorded" | "unrecorded").
    let onOpenCalendar: (String) -> Void

    private enum Segment: String, CaseIterable {
        case meetings
        case transcriptions
        case llm
        case calendar

        var title: String {
            switch self {
            case .meetings: return "Meetings"
            case .transcriptions: return "Transcriptions"
            case .llm: return "LLM"
            case .calendar: return "Calendar"
            }
        }

        var scrollAnchor: String { "insights.segment.\(rawValue)" }

        static let controlsAnchor = "insights.segment.controls"

        static func initial(for section: InsightsSection) -> Segment {
            switch section {
            case .meetings: return .meetings
            case .words, .pace: return .transcriptions
            }
        }
    }

    private let initialSegment: Segment
    @State private var segment: Segment
    @State private var range: InsightsRange = .twelveMonths
    @State private var snapshot: InsightsSnapshot?
    @State private var errorMessage: String?
    @State private var loadGeneration = 0
    @State private var isSharing = false
    @State private var initialScrollGate = InsightsInitialScrollGate()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        initialSection: InsightsSection,
        loadSnapshot: @escaping (InsightsRange) async throws -> InsightsSnapshot,
        onBack: @escaping () -> Void,
        backLabel: String,
        onOpenCalendar: @escaping (String) -> Void = { _ in }
    ) {
        self.initialSection = initialSection
        self.loadSnapshot = loadSnapshot
        self.onBack = onBack
        self.backLabel = backLabel
        self.onOpenCalendar = onOpenCalendar
        let segment = Segment.initial(for: initialSection)
        self.initialSegment = segment
        _segment = State(initialValue: segment)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    header
                    Picker("Insights", selection: $segment) {
                        ForEach(Segment.allCases, id: \.self) { value in
                            Text(value.title).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Insights")
                    .frame(width: 360)
                    .id(Segment.controlsAnchor)

                    Group {
                        if let snapshot {
                            switch segment {
                            case .meetings:
                                meetingsSegment(snapshot)
                            case .transcriptions:
                                transcriptionsSegment(snapshot)
                            case .llm:
                                llmSegment(snapshot)
                            case .calendar:
                                calendarSegment(snapshot)
                            }
                        } else if let errorMessage {
                            errorState(errorMessage)
                        } else {
                            loadingState
                        }
                    }
                    .id(segment.scrollAnchor)
                }
                .padding(28)
                .frame(maxWidth: 1240, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(insightsBackground)
            .onChange(of: segment) { _, _ in
                withAnimation(.easeInOut(duration: 0.28)) {
                    proxy.scrollTo(Segment.controlsAnchor, anchor: .top)
                }
            }
            .sheet(isPresented: $isSharing) {
                if let snapshot {
                    InsightsShareSheet(snapshot: snapshot, rangeLabel: range.label)
                }
            }
            .task(id: loadGeneration) {
                await refresh()
                guard initialScrollGate.consume(hasSnapshot: snapshot != nil) else { return }
                if reduceMotion {
                    proxy.scrollTo(initialSegment.scrollAnchor, anchor: .top)
                } else {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        proxy.scrollTo(initialSegment.scrollAnchor, anchor: .top)
                    }
                }
            }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                headerIdentity
                Spacer()
                rangeControls
            }
            VStack(alignment: .leading, spacing: 14) {
                headerIdentity
                rangeControls
            }
        }
    }

    private var headerIdentity: some View {
        HStack(spacing: 16) {
            Button(action: onBack) {
                Label(backLabel, systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(InsightsPalette.secondaryText)
            .keyboardShortcut(.cancelAction)

            Rectangle()
                .fill(MeetsTheme.surfaceBorder)
                .frame(width: 1, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("INSIGHTS")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(MeetsTheme.accent)
                Text("Private and on-device")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(InsightsPalette.secondaryText)
            }
        }
    }

    private var rangeControls: some View {
        HStack(spacing: 12) {
            Picker("Time range", selection: Binding(
                get: { range },
                set: { newValue in range = newValue; loadGeneration += 1 }
            )) {
                ForEach(InsightsRange.allCases, id: \.self) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Time range")
            .frame(width: 340)

            Button {
                loadGeneration += 1
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(InsightsPalette.secondaryText)
            .help("Refresh local insights")
            .accessibilityLabel("Refresh local insights")

            Button {
                isSharing = true
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(snapshot == nil)
            .help("Share an anonymous activity image")
            .accessibilityLabel("Share your activity")
        }
    }

    @ViewBuilder
    private func meetingsSegment(_ data: InsightsSnapshot) -> some View {
        meetingsHero(data)
        meetingActivityChart(data)
        foldersPanel(data)
        recurringPanel(data)
        meetingReadouts(data)
    }

    private func transcriptionsSegment(_ data: InsightsSnapshot) -> some View {
        Group {
            transcriptionsHero(data)
            transcriptionQualityPanel(data)
        }
    }

    private func llmSegment(_ data: InsightsSnapshot) -> some View {
        llmUsagePanel(data)
    }

    private func calendarSegment(_ data: InsightsSnapshot) -> some View {
        calendarInsightsPanel(data)
    }

    private func meetingsHero(_ data: InsightsSnapshot) -> some View {
        let stats = data.lifetimeMeetingStats
        return VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your time with Meets")
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(MeetsTheme.textPrimary)
                Text(format(stats.totalMeetings))
                    .font(.system(size: 58, weight: .bold, design: .rounded))
                    .tracking(-2.4)
                    .monospacedDigit()
                    .foregroundStyle(MeetsTheme.textPrimary)
                Text("Meetings recorded")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(InsightsPalette.secondaryText)
                if stats.totalDurationSeconds > 0 {
                    Text(heroDurationLine(stats))
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(InsightsPalette.tertiaryText)
                }
            }

            HStack(spacing: 0) {
                heroDatum("Completed", value: format(stats.completedMeetings))
                divider
                heroDatum("Failed", value: format(stats.failedMeetings))
                divider
                heroDatum("With recording", value: format(stats.meetingsWithRecording))
            }
        }
        .padding(26)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(MeetsTheme.backgroundRaised)
                LinearGradient(
                    colors: [MeetsTheme.accent.opacity(0.13), Color.cyan.opacity(0.025), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
        .overlay(panelBorder)
        .shadow(color: Color.black.opacity(0.12), radius: 24, y: 10)
    }

    private func heroDurationLine(_ stats: MeetingActivityStats) -> String {
        var components: [String] = []
        components.append("\(durationLine(stats.totalDurationSeconds)) recorded")
        if stats.averageDurationSeconds > 0 {
            components.append("\(durationLine(stats.averageDurationSeconds)) avg")
        }
        return components.joined(separator: " · ")
    }

    /// Hero for the Transcriptions segment: total recorded hours is the
    /// headline (not word count — a meetings app is about time captured).
    private func transcriptionsHero(_ data: InsightsSnapshot) -> some View {
        let stats = data.lifetimeMeetingStats
        let hours = stats.totalDurationSeconds / 3600
        let minutes = Int(stats.totalDurationSeconds) % 3600 / 60
        let heroValue: String
        if hours >= 1 {
            heroValue = hours >= 10
                ? "\(Int(hours))h"
                : String(format: "%.1fh", hours)
        } else {
            heroValue = "\(minutes)m"
        }
        return VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your time with Meets")
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(MeetsTheme.textPrimary)
                Text(heroValue)
                    .font(.system(size: 58, weight: .bold, design: .rounded))
                    .tracking(-2.4)
                    .monospacedDigit()
                    .foregroundStyle(MeetsTheme.textPrimary)
                Text("Recorded & transcribed")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(InsightsPalette.secondaryText)
            }

            HStack(spacing: 0) {
                heroDatum("Meetings", value: format(stats.totalMeetings))
                divider
                heroDatum("Avg length", value: stats.totalMeetings > 0 ? durationLine(stats.totalDurationSeconds / Double(stats.totalMeetings)) : "—")
                divider
                heroDatum("Words per hour", value: wordsPerHourLabel(stats))
            }
        }
        .padding(26)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(MeetsTheme.backgroundRaised)
                LinearGradient(
                    colors: [MeetsTheme.accent.opacity(0.13), Color.cyan.opacity(0.025), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
        .overlay(panelBorder)
        .shadow(color: Color.black.opacity(0.12), radius: 24, y: 10)
    }

    private func wordsPerHourLabel(_ stats: MeetingActivityStats) -> String {
        guard stats.totalDurationSeconds > 0 else { return "—" }
        let perHour = Double(stats.totalWords) / (stats.totalDurationSeconds / 3600)
        return format(Int(perHour.rounded()))
    }

    private func meetingActivityChart(_ data: InsightsSnapshot) -> some View {
        let buckets = data.meetingBuckets
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                panelTitle("MEETING ACTIVITY", subtitle: "Meetings per day")
                Spacer()
            }
            if buckets.isEmpty {
                emptyState(
                    icon: "chart.bar",
                    message: "No meeting activity for this time period."
                )
                .frame(height: 200)
            } else {
                MeetingBarChart(buckets: buckets)
                    .frame(height: 200)
            }
        }
        .insightsPanel()
    }

    private func foldersPanel(_ data: InsightsSnapshot) -> some View {
        let folders = data.folderStats
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                panelTitle("FOLDERS", subtitle: "Meetings by folder")
                Spacer()
            }
            if folders.isEmpty {
                emptyState(
                    icon: "folder",
                    message: "No folder activity for this time period."
                )
                .frame(minHeight: 120)
            } else {
                let maximum = folders.map(\.meetings).max() ?? 1
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(folders) { folder in
                        FolderStatRow(
                            name: folder.folderName,
                            count: folder.meetings,
                            maximum: maximum,
                            format: format
                        )
                    }
                }
            }
        }
        .insightsPanel()
    }

    private func recurringPanel(_ data: InsightsSnapshot) -> some View {
        let recurring = data.recurringMeetings
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                panelTitle("RECURRING MEETINGS", subtitle: "Titles you come back to")
                Spacer()
            }
            if recurring.isEmpty {
                emptyState(
                    icon: "repeat",
                    message: "No recurring meetings yet in this time period."
                )
                .frame(minHeight: 120)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(recurring) { item in
                        HStack(spacing: 12) {
                            Text(item.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(MeetsTheme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text(item.count == 1 ? "1 meeting" : "\(item.count.formatted()) meetings")
                                .font(.system(size: 12, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(InsightsPalette.secondaryText)
                        }
                    }
                }
            }
        }
        .insightsPanel()
    }

    private func meetingReadouts(_ data: InsightsSnapshot) -> some View {
        return VStack(alignment: .leading, spacing: 18) {
            panelTitle("HABITS", subtitle: "Consistency over the selected time period")
            VStack(alignment: .leading, spacing: 12) {
                readout("Current streak", "\(data.currentStreakDays) day\(data.currentStreakDays == 1 ? "" : "s")")
                readout("Longest streak", "\(data.longestStreakDays) day\(data.longestStreakDays == 1 ? "" : "s")")
                readout("Active days", "\(data.activeDaysInRange) day\(data.activeDaysInRange == 1 ? "" : "s")")
            }
        }
        .insightsPanel()
    }

    private func llmUsagePanel(_ data: InsightsSnapshot) -> some View {
        let stats = data.llmStats
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                panelTitle("LLM USAGE", subtitle: "Activity for the selected time period")
                Spacer()
            }
            if stats.totalRuns == 0 {
                emptyState(
                    icon: "brain",
                    message: "No LLM activity yet."
                )
                .frame(minHeight: 160)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(format(stats.totalRuns))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .tracking(-1.5)
                        .monospacedDigit()
                    Text("runs")
                        .foregroundStyle(InsightsPalette.tertiaryText)
                }
                VStack(alignment: .leading, spacing: 12) {
                    readout("Successful", format(stats.successfulRuns))
                    readout("Failed", format(stats.failedRuns))
                    if stats.totalCharacters > 0 {
                        readout("Characters processed", format(stats.totalCharacters))
                    }
                }
                if !data.llmUsageByDay.isEmpty {
                    LLMDailyBarChart(days: data.llmUsageByDay)
                        .frame(height: 90)
                        .padding(.top, 6)
                }
                if !stats.byKind.isEmpty {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("BY KIND")
                                .font(.system(size: 10, weight: .bold)).tracking(1.5)
                                .foregroundStyle(InsightsPalette.tertiaryText)
                            ForEach(kindRows(stats.byKind), id: \.0) { kind, count in
                                readout(kind, format(count))
                            }
                        }
                        if !stats.byBackend.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("BY BACKEND")
                                    .font(.system(size: 10, weight: .bold)).tracking(1.5)
                                    .foregroundStyle(InsightsPalette.tertiaryText)
                                ForEach(backendRows(stats.byBackend), id: \.0) { backend, count in
                                    readout(backend, format(count))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .insightsPanel()
    }

    private func calendarInsightsPanel(_ data: InsightsSnapshot) -> some View {
        let stats = data.calendarStats
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                panelTitle("CALENDAR INSIGHTS", subtitle: "Meetings vs your calendar for the selected time period")
                Spacer()
            }
            if stats.eventsInRange == 0 {
                emptyState(
                    icon: "calendar.badge.clock",
                    message: "No calendar events in this window. Events from your enabled calendars appear here."
                )
                .frame(minHeight: 160)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(format(stats.eventsInRange))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .tracking(-1.5)
                        .monospacedDigit()
                    Text("events")
                        .foregroundStyle(InsightsPalette.tertiaryText)
                }
                let recordedPct = Int((Double(stats.recordedEvents) / Double(stats.eventsInRange) * 100).rounded())
                let missedPct = Int((Double(stats.missedEvents) / Double(stats.eventsInRange) * 100).rounded())
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        usageLegend("Recorded", stats.recordedEvents, .cyan)
                        Spacer()
                        Text("\(recordedPct)%")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(InsightsPalette.secondaryText)
                    }
                    HStack {
                        usageLegend("Missed", stats.missedEvents, MeetsTheme.accent)
                        Spacer()
                        Text("\(missedPct)%")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(InsightsPalette.secondaryText)
                    }
                    readout("Upcoming", format(stats.upcomingEvents))
                    readout("Cancelled", format(stats.cancelledEvents))
                }
                HStack(spacing: 10) {
                    deepLinkButton("See recorded", filter: "recorded")
                    deepLinkButton("See missed", filter: "past")
                    deepLinkButton("See upcoming", filter: "upcoming")
                }
                .padding(.top, 6)
            }
        }
        .insightsPanel()
    }

    private func deepLinkButton(_ title: String, filter: String) -> some View {
        Button {
            onOpenCalendar(filter)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(MeetsTheme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(MeetsTheme.accent.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
        }
        .buttonStyle(.plain)
        .help("Open the Calendar page with this filter")
    }

    private func emptyState(icon: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(InsightsPalette.tertiaryText)
            Text(message)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(InsightsPalette.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func kindRows(_ byKind: [String: Int]) -> [(String, Int)] {
        byKind.map { (displayKind($0.key), $0.value) }.sorted { $0.0 < $1.0 }
    }

    private func backendRows(_ byBackend: [String: Int]) -> [(String, Int)] {
        byBackend.map { (displayBackend($0.key), $0.value) }.sorted { $0.0 < $1.0 }
    }

    private func displayKind(_ kind: String) -> String {
        switch kind.lowercased() {
        case "summary": return "Summaries"
        case "cleanup": return "Cleanups"
        case "title", "title_generation": return "Title generation"
        default:
            return kind.isEmpty ? "Other" : "\(kind) runs"
        }
    }

    private func displayBackend(_ backend: String) -> String {
        switch backend.lowercased() {
        case "chatgpt": return "ChatGPT"
        case "openai": return "OpenAI"
        case "openrouter": return "OpenRouter"
        case "ollama": return "Ollama"
        case "lmstudio": return "LM Studio"
        case "custom_llm": return "Custom LLM"
        case "local", "qwen3": return "Local model"
        default:
            return backend.isEmpty ? "Unknown backend" : backend
        }
    }

    private func durationLine(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let hours = Int(clamped) / 3600
        let minutes = Int(clamped) % 3600 / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private func percent(_ part: Int, of total: Int) -> String {
        "\(Int((Double(part) / Double(total) * 100).rounded()))%"
    }

    /// Transcription-value readouts for the selected time period — time
    /// captured, meeting shape, and the recording-rate signal. Words-era
    /// pace/avg-words metrics are gone: they added noise, not insight.
    private func transcriptionQualityPanel(_ data: InsightsSnapshot) -> some View {
        let stats = data.meetingStats
        let total = max(1, stats.totalMeetings)
        return VStack(alignment: .leading, spacing: 18) {
            panelTitle("CAPTURE", subtitle: "What this time period produced")
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    readout("Recorded", durationLine(stats.totalDurationSeconds))
                    readout("Meetings", format(stats.totalMeetings))
                    readout("Avg length", stats.totalMeetings > 0 ? durationLine(stats.totalDurationSeconds / Double(stats.totalMeetings)) : "—")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 12) {
                    readout("With audio", "\(stats.meetingsWithRecording) (\(percent(stats.meetingsWithRecording, of: total)))")
                    readout("Calendar-linked", "\(stats.meetingsLinkedToCalendar) (\(percent(stats.meetingsLinkedToCalendar, of: total)))")
                    readout("Follow-ups made", format(stats.followUpMeetings))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 12) {
                    readout("Failed", format(stats.failedMeetings))
                    readout("Audio imports", format(stats.importedMeetings))
                    readout("Words captured", format(stats.totalWords))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .insightsPanel()
    }

    private var loadingState: some View {
        VStack(spacing: 18) {
            InsightsLoadingStatus()
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 14)
                    .fill(MeetsTheme.backgroundRaised)
                    .frame(height: index == 0 ? 235 : 190)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 12) {
                            RoundedRectangle(cornerRadius: 3).fill(MeetsTheme.surfacePrimary).frame(width: 130, height: 12)
                            RoundedRectangle(cornerRadius: 5).fill(MeetsTheme.surfacePrimary).frame(width: 230, height: 30)
                        }.padding(24)
                    }
                    .opacity(0.72)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calculating local insights")
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(MeetsTheme.accent)
            Text("Insights could not be calculated")
                .font(MeetsTheme.title3())
            Text(message)
                .font(MeetsTheme.callout())
                .foregroundStyle(InsightsPalette.secondaryText)
            Button("Try Again") { loadGeneration += 1 }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .insightsPanel()
    }

    private func refresh() async {
        snapshot = nil
        errorMessage = nil
        do {
            let result = try await loadSnapshot(range)
            try Task.checkCancellation()
            snapshot = result
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var insightsBackground: some View {
        ZStack {
            MeetsTheme.backgroundBase
            LinearGradient(
                colors: [MeetsTheme.accent.opacity(0.045), .clear, Color.cyan.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }.ignoresSafeArea()
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
    }

    private var divider: some View {
        Rectangle().fill(MeetsTheme.surfaceBorder).frame(width: 1, height: 42)
    }

    private func heroDatum(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit()
            Text(label.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1.3).foregroundStyle(InsightsPalette.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
    }

    private func panelTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .bold)).tracking(1.8).foregroundStyle(MeetsTheme.textPrimary)
            Text(subtitle).font(.system(size: 12, weight: .regular)).foregroundStyle(InsightsPalette.secondaryText)
        }
    }

    private func usageLegend(_ label: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(InsightsPalette.secondaryText)
            Text(format(value)).fontWeight(.semibold).monospacedDigit()
        }.font(.system(size: 12))
    }

    private func readout(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(InsightsPalette.tertiaryText)
            Spacer()
            Text(value).foregroundStyle(MeetsTheme.textPrimary).monospacedDigit()
        }.font(.system(size: 12, weight: .medium))
    }

    private func format(_ value: Int) -> String { value.formatted(.number.notation(.compactName)) }
}

enum InsightsLoadingCopy {
    static let messages = [
        "Calculating your private activity history",
        "Insights are computed on this Mac and never uploaded",
        "Your transcripts and statistics stay under your control",
        "Insights cover meetings captured on this Mac",
    ]
}

private struct InsightsLoadingStatus: View {
    @State private var messageIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
                .tint(MeetsTheme.accent)

            VStack(alignment: .leading, spacing: 4) {
                Text("Building your Insights")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MeetsTheme.textPrimary)
                ZStack(alignment: .leading) {
                    Text(InsightsLoadingCopy.messages[messageIndex])
                        .id(messageIndex)
                        .transition(.opacity)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(InsightsPalette.secondaryText)
            }
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(MeetsTheme.accent.opacity(0.8))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(MeetsTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MeetsTheme.surfaceBorder))
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.28)) {
                    messageIndex = (messageIndex + 1) % InsightsLoadingCopy.messages.count
                }
            }
        }
    }
}

struct InsightsInitialScrollGate {
    private(set) var hasScrolled = false

    mutating func consume(hasSnapshot: Bool) -> Bool {
        guard hasSnapshot, !hasScrolled else { return false }
        hasScrolled = true
        return true
    }
}

private enum InsightsPalette {
    static let secondaryText = Color.adaptiveAlpha(
        dark: .white, darkAlpha: 0.70,
        light: .black, lightAlpha: 0.72
    )
    static let tertiaryText = Color.adaptiveAlpha(
        dark: .white, darkAlpha: 0.52,
        light: .black, lightAlpha: 0.58
    )

    static func intensity(_ level: Int) -> Color {
        switch level {
        case 1: return MeetsTheme.accent.opacity(0.24)
        case 2: return MeetsTheme.accent.opacity(0.48)
        case 3: return Color.cyan.opacity(0.67)
        case 4...: return Color.cyan.opacity(0.95)
        default: return MeetsTheme.surfacePrimary.opacity(0.62)
        }
    }
}

private struct MeetingBarChart: View {
    let buckets: [MeetingActivityBucket]

    private let barWidth: CGFloat = 7
    private let barSpacing: CGFloat = 3
    private let chartHeight: CGFloat = 128

    private var maximum: Int {
        max(1, buckets.map(\.meetings).max() ?? 1)
    }

    private var totalMeetings: Int {
        buckets.reduce(0) { $0 + $1.meetings }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: barSpacing) {
                    ForEach(buckets) { bucket in
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(MeetsTheme.accent.opacity(0.78))
                                .frame(
                                    width: barWidth,
                                    height: barHeight(for: bucket.meetings)
                                )
                                .help(barHelp(bucket))
                                .accessibilityLabel(barHelp(bucket))
                            Text(bucket.bucketStart.formatted(.dateTime.day()))
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(InsightsPalette.tertiaryText)
                                .monospacedDigit()
                        }
                    }
                }
                .frame(height: chartHeight, alignment: .bottom)
            }
            HStack(spacing: 0) {
                Text(bucketRangeLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(InsightsPalette.tertiaryText)
                Spacer()
                Text(totalLabel)
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(InsightsPalette.tertiaryText)
            }
        }
    }

    private var bucketRangeLabel: String {
        guard let first = buckets.first?.bucketStart, let last = buckets.last?.bucketStart else { return "" }
        return "\(first.formatted(.dateTime.month(.abbreviated))) \(first.formatted(.dateTime.day())) – \(last.formatted(.dateTime.month(.abbreviated))) \(last.formatted(.dateTime.day()))"
    }

    private var totalLabel: String {
        totalMeetings == 1 ? "1 meeting" : "\(totalMeetings.formatted()) meetings"
    }

    private func barHeight(for count: Int) -> CGFloat {
        guard count > 0 else { return 2 }
        let ratio = CGFloat(count) / CGFloat(maximum)
        return max(3, (chartHeight - 24) * ratio)
    }

    private func barHelp(_ bucket: MeetingActivityBucket) -> String {
        let date = bucket.bucketStart.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        let meetings = bucket.meetings == 1 ? "1 meeting" : "\(bucket.meetings.formatted()) meetings"
        return "\(date), \(meetings)"
    }
}

/// Compact per-day LLM run bars (Phase 3).
private struct LLMDailyBarChart: View {
    let days: [LLMUsageDay]

    private let barWidth: CGFloat = 6
    private let barSpacing: CGFloat = 3

    private var maximum: Int {
        max(1, days.map(\.runs).max() ?? 1)
    }

    private var totalRuns: Int {
        days.reduce(0) { $0 + $1.runs }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: barSpacing) {
                    ForEach(days) { day in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(MeetsTheme.accent.opacity(0.7))
                                .frame(width: barWidth, height: barHeight(for: day.runs))
                                .help(barHelp(day))
                                .accessibilityLabel(barHelp(day))
                            Text(day.day.formatted(.dateTime.day()))
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(InsightsPalette.tertiaryText)
                                .monospacedDigit()
                        }
                    }
                }
                .frame(height: 64, alignment: .bottom)
            }
            Text(totalLabel)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(InsightsPalette.tertiaryText)
        }
    }

    private var totalLabel: String {
        totalRuns == 1 ? "1 run" : "\(totalRuns.formatted()) runs in this window"
    }

    private func barHeight(for count: Int) -> CGFloat {
        guard count > 0 else { return 2 }
        let ratio = CGFloat(count) / CGFloat(maximum)
        return max(3, (64 - 18) * ratio)
    }

    private func barHelp(_ day: LLMUsageDay) -> String {
        let date = day.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        let runs = day.runs == 1 ? "1 run" : "\(day.runs.formatted()) runs"
        return "\(date), \(runs)"
    }
}

private struct FolderStatRow: View {
    let name: String
    let count: Int
    let maximum: Int
    let format: (Int) -> String

    var body: some View {
        HStack(spacing: 12) {
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MeetsTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 150, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(MeetsTheme.surfacePrimary.opacity(0.6))
                    Capsule()
                        .fill(MeetsTheme.accent.opacity(0.75))
                        .frame(width: max(3, geometry.size.width * barRatio))
                }
            }
            .frame(height: 6)
            Text(format(count))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(InsightsPalette.secondaryText)
                .frame(width: 46, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(count.formatted()) meetings")
    }

    private var barRatio: CGFloat {
        guard maximum > 0 else { return 0 }
        return CGFloat(count) / CGFloat(maximum)
    }
}

private extension InsightsRange {
    var label: String {
        switch self {
        case .thirtyDays: return "30 days"
        case .ninetyDays: return "90 days"
        case .twelveMonths: return "12 months"
        case .allTime: return "All time"
        }
    }
}

private extension View {
    func insightsPanel() -> some View {
        self
            .padding(22)
            .background(MeetsTheme.backgroundRaised.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.07), radius: 14, y: 7)
    }
}
