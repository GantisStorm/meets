import Foundation

public enum MeetingNotesState: String, Codable, Sendable {
    case missing
    case rawTranscriptFallback = "raw_transcript_fallback"
    case structuredNotes = "structured_notes"
}

public enum MeetingStatus: String, Codable, Sendable {
    case recording
    case processing
    case completed
    case noteOnly = "note_only"
    case failed
}

public enum MeetingTemplateKind: String, Codable, Sendable {
    case auto
    case builtin
    case custom
}

public enum MeetingRecordingSavePolicy: String, Codable, CaseIterable, Sendable {
    case never
    case prompt
    case always
}

public enum MeetingSource: String, Codable, Sendable {
    case meeting
    case audioImport = "audio_import"
}

public struct LiveTranscriptCheckpointEntry: Sendable, Equatable {
    public let timestampLabel: String
    public let speaker: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String

    public init(
        timestampLabel: String,
        speaker: String,
        startSeconds: Double,
        endSeconds: Double,
        text: String
    ) {
        self.timestampLabel = timestampLabel
        self.speaker = speaker
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
    }
}

public struct CalendarOccurrenceReference: Codable, Equatable, Sendable {
    /// Provider kinds persisted by this app. `.googleCalendar` is retained as
    /// a decodable value only so occurrences recorded by pre-EventKit builds
    /// still decode; the Google Calendar integration is removed and no new
    /// reference is ever created with this provider.
    public enum Provider: String, Codable, Sendable {
        case eventKit
        case googleCalendar
    }

    public let provider: Provider
    public let calendarID: String?
    public let eventID: String
    public let seriesID: String?
    public let originalStartTime: Date

    public init(
        provider: Provider,
        calendarID: String?,
        eventID: String,
        seriesID: String? = nil,
        originalStartTime: Date
    ) {
        self.provider = provider
        self.calendarID = calendarID
        self.eventID = eventID
        self.seriesID = seriesID
        self.originalStartTime = originalStartTime
    }

    /// Stable identity for one provider occurrence. Recurring instances use
    /// the series plus their immutable original start; one-off events use the
    /// provider event id so rescheduling does not create a new occurrence.
    public var identityKey: String {
        let calendarComponent = Self.component(calendarID ?? "")
        if let seriesID {
            let originalStartMilliseconds = Int64((originalStartTime.timeIntervalSince1970 * 1_000).rounded())
            return "v1|recurring|\(provider.rawValue)|\(calendarComponent)|\(Self.component(seriesID))|\(originalStartMilliseconds)"
        }
        return "v1|single|\(provider.rawValue)|\(calendarComponent)|\(Self.component(eventID))"
    }

    private static func component(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }
}

public struct MeetingRecord: Identifiable, Codable, Sendable {
    public let id: Int64
    public let title: String
    public let startTime: String
    public let durationSeconds: Double
    public let rawTranscript: String
    public let formattedNotes: String
    public let wordCount: Int
    public let folderID: Int64?
    public let calendarEventID: String?
    public let calendarOccurrence: CalendarOccurrenceReference?
    public let micAudioPath: String?
    public let systemAudioPath: String?
    public let savedRecordingPath: String?
    public let status: MeetingStatus
    public let manualNotes: String
    public let selectedTemplateID: String?
    public let selectedTemplateName: String?
    public let selectedTemplateKind: MeetingTemplateKind?
    public let selectedTemplatePrompt: String?
    public let source: MeetingSource
    /// Self-referencing link: the meeting this one is a follow-up to. A meeting
    /// can have multiple follow-ups; root meetings have nil.
    public let followUpToID: Int64?
    /// Aggregated on-screen context (app text + OCR) captured during the
    /// meeting; nil when screen context was disabled or nothing was captured.
    public let visualContext: String?

    public init(
        id: Int64,
        title: String,
        startTime: String,
        durationSeconds: Double,
        rawTranscript: String,
        formattedNotes: String,
        wordCount: Int,
        folderID: Int64?,
        calendarEventID: String? = nil,
        calendarOccurrence: CalendarOccurrenceReference? = nil,
        micAudioPath: String? = nil,
        systemAudioPath: String? = nil,
        savedRecordingPath: String? = nil,
        status: MeetingStatus = .completed,
        manualNotes: String = "",
        selectedTemplateID: String? = nil,
        selectedTemplateName: String? = nil,
        selectedTemplateKind: MeetingTemplateKind? = nil,
        selectedTemplatePrompt: String? = nil,
        source: MeetingSource = .meeting,
        followUpToID: Int64? = nil,
        visualContext: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startTime = startTime
        self.durationSeconds = durationSeconds
        self.rawTranscript = rawTranscript
        self.formattedNotes = formattedNotes
        self.wordCount = wordCount
        self.folderID = folderID
        self.calendarEventID = calendarEventID
        self.calendarOccurrence = calendarOccurrence
        self.micAudioPath = micAudioPath
        self.systemAudioPath = systemAudioPath
        self.savedRecordingPath = savedRecordingPath
        self.status = status
        self.manualNotes = manualNotes
        self.selectedTemplateID = selectedTemplateID
        self.selectedTemplateName = selectedTemplateName
        self.selectedTemplateKind = selectedTemplateKind
        self.selectedTemplatePrompt = selectedTemplatePrompt
        self.source = source
        self.followUpToID = followUpToID
        self.visualContext = visualContext
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case startTime
        case durationSeconds
        case rawTranscript
        case formattedNotes
        case wordCount
        case folderID
        case calendarEventID
        case calendarOccurrence
        case micAudioPath
        case systemAudioPath
        case savedRecordingPath
        case status
        case manualNotes
        case selectedTemplateID
        case selectedTemplateName
        case selectedTemplateKind
        case selectedTemplatePrompt
        case source
        case followUpToID
        case visualContext
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(Int64.self, forKey: .id),
            title: try c.decode(String.self, forKey: .title),
            startTime: try c.decode(String.self, forKey: .startTime),
            durationSeconds: try c.decode(Double.self, forKey: .durationSeconds),
            rawTranscript: try c.decode(String.self, forKey: .rawTranscript),
            formattedNotes: try c.decode(String.self, forKey: .formattedNotes),
            wordCount: try c.decode(Int.self, forKey: .wordCount),
            folderID: try c.decodeIfPresent(Int64.self, forKey: .folderID),
            calendarEventID: try c.decodeIfPresent(String.self, forKey: .calendarEventID),
            calendarOccurrence: try c.decodeIfPresent(CalendarOccurrenceReference.self, forKey: .calendarOccurrence),
            micAudioPath: try c.decodeIfPresent(String.self, forKey: .micAudioPath),
            systemAudioPath: try c.decodeIfPresent(String.self, forKey: .systemAudioPath),
            savedRecordingPath: try c.decodeIfPresent(String.self, forKey: .savedRecordingPath),
            status: (try? c.decode(MeetingStatus.self, forKey: .status)) ?? .completed,
            manualNotes: (try? c.decode(String.self, forKey: .manualNotes)) ?? "",
            selectedTemplateID: try c.decodeIfPresent(String.self, forKey: .selectedTemplateID),
            selectedTemplateName: try c.decodeIfPresent(String.self, forKey: .selectedTemplateName),
            selectedTemplateKind: try c.decodeIfPresent(MeetingTemplateKind.self, forKey: .selectedTemplateKind),
            selectedTemplatePrompt: try c.decodeIfPresent(String.self, forKey: .selectedTemplatePrompt),
            source: (try? c.decode(MeetingSource.self, forKey: .source)) ?? .meeting,
            followUpToID: try c.decodeIfPresent(Int64.self, forKey: .followUpToID),
            visualContext: try c.decodeIfPresent(String.self, forKey: .visualContext)
        )
    }

    public var notesState: MeetingNotesState {
        let trimmed = formattedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .missing }
        let normalized = trimmed.lowercased()
        if normalized == "## raw transcript" || normalized.hasPrefix("## raw transcript\n") {
            return .rawTranscriptFallback
        }
        return .structuredNotes
    }

    public var appliedTemplateID: String {
        let trimmed = selectedTemplateID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "auto" : trimmed
    }

    public var appliedTemplateName: String {
        let trimmed = selectedTemplateName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Auto" : trimmed
    }

    public var appliedTemplateKind: MeetingTemplateKind {
        selectedTemplateKind ?? .auto
    }
}

public struct MeetingParticipant: Identifiable, Equatable, Sendable {
    public let meetingID: Int64
    public let participantIdentifier: String
    public let displayName: String
    public let emailAddress: String?
    public let insertionOrder: Int

    public var id: String {
        "\(meetingID):\(participantIdentifier)"
    }

    public init(
        meetingID: Int64,
        participantIdentifier: String,
        displayName: String,
        emailAddress: String? = nil,
        insertionOrder: Int
    ) {
        self.meetingID = meetingID
        self.participantIdentifier = participantIdentifier
        self.displayName = displayName
        self.emailAddress = emailAddress
        self.insertionOrder = insertionOrder
    }
}

public struct MeetingParticipantDraft: Equatable, Sendable {
    public let participantIdentifier: String
    public let displayName: String
    public let emailAddress: String?

    public init(
        participantIdentifier: String,
        displayName: String,
        emailAddress: String? = nil
    ) {
        self.participantIdentifier = participantIdentifier
        self.displayName = displayName
        self.emailAddress = emailAddress
    }
}

/// One explicit "Add to Event" attachment between a meeting and a calendar
/// event. A meeting may carry many of these (multi-link), while
/// `MeetingRecord.calendarEventID` remains the meeting's single *primary*
/// event — the one a recording was created from. Link rows are the source of
/// truth for extra events attached later from the meeting detail view.
public struct MeetingEventLink: Identifiable, Equatable, Sendable {
    public let meetingID: Int64
    public let eventID: String
    public let calendarID: String?
    public let occurrenceKey: String?
    public let addedAt: Date

    public var id: String {
        "\(meetingID):\(eventID)"
    }

    public init(
        meetingID: Int64,
        eventID: String,
        calendarID: String? = nil,
        occurrenceKey: String? = nil,
        addedAt: Date
    ) {
        self.meetingID = meetingID
        self.eventID = eventID
        self.calendarID = calendarID
        self.occurrenceKey = occurrenceKey
        self.addedAt = addedAt
    }
}

public struct MeetingFolder: Identifiable, Codable, Sendable {
    public let id: Int64
    public var name: String
    public let parentID: Int64?
    public let createdAt: String

    public init(id: Int64, name: String, parentID: Int64? = nil, createdAt: String) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.createdAt = createdAt
    }
}

public struct MeetingStats: Codable, Sendable {
    public let totalWords: Int
    public let totalMeetings: Int
    public let averageWPM: Double

    public init(totalWords: Int, totalMeetings: Int, averageWPM: Double) {
        self.totalWords = totalWords
        self.totalMeetings = totalMeetings
        self.averageWPM = averageWPM
    }
}

public enum InsightsRange: String, CaseIterable, Codable, Sendable {
    case thirtyDays
    case ninetyDays
    case twelveMonths
    case allTime

    public func startDate(now: Date, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .thirtyDays:
            return calendar.date(byAdding: .day, value: -29, to: today)
        case .ninetyDays:
            return calendar.date(byAdding: .day, value: -89, to: today)
        case .twelveMonths:
            return calendar.date(byAdding: .year, value: -1, to: today)
        case .allTime:
            return nil
        }
    }
}

public struct InsightsTotals: Codable, Sendable, Equatable {
    public let meetingWords: Int
    public let meetings: Int
    public let averageWPM: Double

    public init(meetingWords: Int, meetings: Int, averageWPM: Double) {
        self.meetingWords = meetingWords
        self.meetings = meetings
        self.averageWPM = averageWPM
    }
}

public struct InsightsDailyActivity: Codable, Sendable, Equatable, Identifiable {
    public var id: Date { date }
    public let date: Date
    public let words: Int
    public let meetings: Int

    public init(date: Date, words: Int, meetings: Int) {
        self.date = date
        self.words = words
        self.meetings = meetings
    }
}

public struct InsightsWordFrequency: Codable, Sendable, Equatable, Identifiable {
    public var id: String { word }
    public let word: String
    public let count: Int

    public init(word: String, count: Int) {
        self.word = word
        self.count = count
    }
}

// MARK: - Insights v2 (trinity aggregates)

/// Meeting-infrastructure aggregate for a time window.
public struct MeetingActivityStats: Codable, Sendable, Equatable {
    public let totalMeetings: Int
    public let completedMeetings: Int
    public let failedMeetings: Int
    public let recordingMeetings: Int
    public let totalDurationSeconds: Double
    public let averageDurationSeconds: Double
    public let totalWords: Int
    public let meetingsWithRecording: Int
    public let meetingsLinkedToCalendar: Int
    public let followUpMeetings: Int
    public let importedMeetings: Int

    public init(
        totalMeetings: Int = 0,
        completedMeetings: Int = 0,
        failedMeetings: Int = 0,
        recordingMeetings: Int = 0,
        totalDurationSeconds: Double = 0,
        averageDurationSeconds: Double = 0,
        totalWords: Int = 0,
        meetingsWithRecording: Int = 0,
        meetingsLinkedToCalendar: Int = 0,
        followUpMeetings: Int = 0,
        importedMeetings: Int = 0
    ) {
        self.totalMeetings = totalMeetings
        self.completedMeetings = completedMeetings
        self.failedMeetings = failedMeetings
        self.recordingMeetings = recordingMeetings
        self.totalDurationSeconds = totalDurationSeconds
        self.averageDurationSeconds = averageDurationSeconds
        self.totalWords = totalWords
        self.meetingsWithRecording = meetingsWithRecording
        self.meetingsLinkedToCalendar = meetingsLinkedToCalendar
        self.followUpMeetings = followUpMeetings
        self.importedMeetings = importedMeetings
    }
}

/// One bucket (day/week/month) of meeting activity for charts.
public struct MeetingActivityBucket: Codable, Sendable, Equatable, Identifiable {
    public var id: Date { bucketStart }
    public let bucketStart: Date
    public let meetings: Int
    public let durationSeconds: Double
    public let words: Int

    public init(bucketStart: Date, meetings: Int, durationSeconds: Double, words: Int) {
        self.bucketStart = bucketStart
        self.meetings = meetings
        self.durationSeconds = durationSeconds
        self.words = words
    }
}

/// Folder-scoped meeting counts.
public struct MeetingFolderStat: Codable, Sendable, Equatable, Identifiable {
    public let folderID: Int64
    public let folderName: String
    public let meetings: Int

    public init(folderID: Int64, folderName: String, meetings: Int) {
        self.folderID = folderID
        self.folderName = folderName
        self.meetings = meetings
    }

    public var id: Int64 { folderID }
}

/// Status mix + calendar linkage for the selected window.
public struct MeetingCalendarLinkageStats: Codable, Sendable, Equatable {
    public let eventsInRange: Int
    public let recordedEvents: Int
    public let missedEvents: Int
    public let upcomingEvents: Int
    public let cancelledEvents: Int

    public init(eventsInRange: Int = 0, recordedEvents: Int = 0, missedEvents: Int = 0, upcomingEvents: Int = 0, cancelledEvents: Int = 0) {
        self.eventsInRange = eventsInRange
        self.recordedEvents = recordedEvents
        self.missedEvents = missedEvents
        self.upcomingEvents = upcomingEvents
        self.cancelledEvents = cancelledEvents
    }
}

/// One LLM (summary/cleanup/title) run recorded in the usage log.
public struct LLMUsageRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: Int64
    public let kind: String
    public let backend: String
    public let model: String
    public let timestamp: Date
    public let status: String
    public let retryCount: Int
    public let characters: Int

    public init(id: Int64 = 0, kind: String, backend: String, model: String, timestamp: Date, status: String, retryCount: Int = 0, characters: Int = 0) {
        self.id = id
        self.kind = kind
        self.backend = backend
        self.model = model
        self.timestamp = timestamp
        self.status = status
        self.retryCount = retryCount
        self.characters = characters
    }
}

/// Aggregate of LLM usage for a window.
public struct LLMUsageStats: Codable, Sendable, Equatable {
    public let totalRuns: Int
    public let successfulRuns: Int
    public let failedRuns: Int
    public let totalCharacters: Int
    public let byKind: [String: Int]
    public let byBackend: [String: Int]

    public init(totalRuns: Int = 0, successfulRuns: Int = 0, failedRuns: Int = 0, totalCharacters: Int = 0, byKind: [String: Int] = [:], byBackend: [String: Int] = [:]) {
        self.totalRuns = totalRuns
        self.successfulRuns = successfulRuns
        self.failedRuns = failedRuns
        self.totalCharacters = totalCharacters
        self.byKind = byKind
        self.byBackend = byBackend
    }
}

/// Per-day LLM usage for charts.
public struct LLMUsageDay: Codable, Sendable, Equatable, Identifiable {
    public var id: Date { day }
    public let day: Date
    public let runs: Int

    public init(day: Date, runs: Int) {
        self.day = day
        self.runs = runs
    }
}

/// Top recurring meeting titles.
public struct RecurringMeetingStat: Codable, Sendable, Equatable, Identifiable {
    public var id: String { title }
    public let title: String
    public let count: Int

    public init(title: String, count: Int) {
        self.title = title
        self.count = count
    }
}

public struct InsightsSnapshot: Codable, Sendable, Equatable {
    public let range: InsightsRange
    public let generatedAt: Date
    public let lifetime: InsightsTotals
    public let selected: InsightsTotals
    public let dailyActivity: [InsightsDailyActivity]
    public let currentStreakDays: Int
    public let longestStreakDays: Int
    public let activeDaysInRange: Int
    public let meetingWords: [InsightsWordFrequency]
    // v2 — meeting infrastructure (defaulted so existing callers stay valid)
    public let meetingStats: MeetingActivityStats
    public let lifetimeMeetingStats: MeetingActivityStats
    public let meetingBuckets: [MeetingActivityBucket]
    public let folderStats: [MeetingFolderStat]
    public let recurringMeetings: [RecurringMeetingStat]
    // v2 — calendar linkage
    public let calendarStats: MeetingCalendarLinkageStats
    // v2 — LLM usage
    public let llmStats: LLMUsageStats
    public let llmUsageByDay: [LLMUsageDay]

    public init(
        range: InsightsRange,
        generatedAt: Date,
        lifetime: InsightsTotals,
        selected: InsightsTotals,
        dailyActivity: [InsightsDailyActivity],
        currentStreakDays: Int,
        longestStreakDays: Int,
        activeDaysInRange: Int,
        meetingWords: [InsightsWordFrequency],
        meetingStats: MeetingActivityStats = MeetingActivityStats(),
        lifetimeMeetingStats: MeetingActivityStats = MeetingActivityStats(),
        meetingBuckets: [MeetingActivityBucket] = [],
        folderStats: [MeetingFolderStat] = [],
        recurringMeetings: [RecurringMeetingStat] = [],
        calendarStats: MeetingCalendarLinkageStats = MeetingCalendarLinkageStats(),
        llmStats: LLMUsageStats = LLMUsageStats(),
        llmUsageByDay: [LLMUsageDay] = []
    ) {
        self.range = range
        self.generatedAt = generatedAt
        self.lifetime = lifetime
        self.selected = selected
        self.dailyActivity = dailyActivity
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
        self.activeDaysInRange = activeDaysInRange
        self.meetingWords = meetingWords
        self.meetingStats = meetingStats
        self.lifetimeMeetingStats = lifetimeMeetingStats
        self.meetingBuckets = meetingBuckets
        self.folderStats = folderStats
        self.recurringMeetings = recurringMeetings
        self.calendarStats = calendarStats
        self.llmStats = llmStats
        self.llmUsageByDay = llmUsageByDay
    }

    /// Returns a copy with replaced calendar linkage stats (computed in the
    /// app layer from live EventKit state; the store cannot see calendars).
    public func replacing(calendarStats newStats: MeetingCalendarLinkageStats) -> InsightsSnapshot {
        InsightsSnapshot(
            range: range,
            generatedAt: generatedAt,
            lifetime: lifetime,
            selected: selected,
            dailyActivity: dailyActivity,
            currentStreakDays: currentStreakDays,
            longestStreakDays: longestStreakDays,
            activeDaysInRange: activeDaysInRange,
            meetingWords: meetingWords,
            meetingStats: meetingStats,
            lifetimeMeetingStats: lifetimeMeetingStats,
            meetingBuckets: meetingBuckets,
            folderStats: folderStats,
            recurringMeetings: recurringMeetings,
            calendarStats: newStats,
            llmStats: llmStats,
            llmUsageByDay: llmUsageByDay
        )
    }
}
