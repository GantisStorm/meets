import Foundation
import Observation
import MuesliCore

enum DashboardTab: String, CaseIterable {
    case meetings
    case calendar
    case insights
    case dictionary
    case models
    case settings
    case about
}

enum InsightsSection: String, CaseIterable, Sendable {
    case words
    case pace
    case meetings
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case meetings
    case appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .meetings: return "Meetings"
        case .appearance: return "Appearance"
        }
    }
}

enum ModelsCategory: String, CaseIterable, Identifiable {
    case transcription
    case streaming

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcription: return "Transcription"
        case .streaming: return "Live Meetings"
        }
    }
}

enum MeetingsNavigationState: Equatable {
    case browser
    case document(Int64)
}

enum SparkleUpdateStatus: Equatable {
    case idle
    case checking
    case busy(message: String)
    case available(version: String)
    case downloaded(version: String)
    case installing(version: String)
    case upToDate
    case disabled(message: String)
    case failed(message: String)
}

struct ActiveMeetingAudioWarning: Equatable {
    let meetingID: Int64
    let message: String
}

enum OpenRouterModelCatalogLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
@Observable
final class AppState {
    // Dashboard data
    var meetingRows: [MeetingRecord] = []
    var totalMeetingCount: Int = 0
    var meetingCountsByFolder: [Int64: Int] = [:]
    var directMeetingCountsByFolder: [Int64: Int] = [:]
    var selectedMeetingID: Int64?
    var selectedMeetingRecord: MeetingRecord?
    var folders: [MeetingFolder] = []
    /// Explicit "Add to Event" attachments (meeting ↔ calendar event),
    /// loaded in one pass by `syncAppState`. Indexed in views to determine
    /// which events a meeting is attached to beyond its primary
    /// `calendarEventID`.
    var meetingEventLinks: [MeetingEventLink] = []
    var selectedFolderID: Int64?  // nil = "All Meetings"
    var meetingsNavigationState: MeetingsNavigationState = .browser
    var meetingNotesFocusRequest = 0
    var isMeetingTemplatesManagerPresented: Bool = false
    var meetingStats: MeetingStats = MeetingStats(totalWords: 0, totalMeetings: 0, averageWPM: 0)

    // Config-driven state
    var selectedBackend: BackendOption = .whisper
    var selectedMeetingTranscriptionBackend: BackendOption = .whisper
    var selectedMeetingSummaryBackend: MeetingSummaryBackendOption = .chatGPT
    var config: AppConfig = AppConfig()
    var launchAtLoginRegistrationState: LaunchAtLoginRegistrationState = .disabled

    // Live status
    var isMeetingRecording: Bool = false
    var isMeetingRecordingPaused: Bool = false
    var isMeetingStarting: Bool = false
    var meetingStartStatus: String?
    var liveMeetingTranscript: String = ""
    var liveMeetingTranscriptOwnerID: Int64? = nil
    /// Provisional streaming tails for the live transcript view, one per
    /// source; owner-gated by `liveMeetingTranscriptOwnerID` like the transcript.
    var liveMeetingPartialYou: String = ""
    var liveMeetingPartialOthers: String = ""
    var activeMeetingAudioWarning: ActiveMeetingAudioWarning?
    var isChatGPTAuthenticated: Bool = false
    var isOpenRouterAuthenticated: Bool = false
    var isOpenRouterEnvironmentManaged: Bool = false
    var hasStoredOpenRouterCredential: Bool = false
    var openRouterSummaryModels: [SummaryModelPreset] = []
    var openRouterSummaryCatalogState: OpenRouterModelCatalogLoadState = .idle
    var calendarAuthorization: CalendarAuthState = .unknown
    var isCalendarPageLoading: Bool = false
    var eventKitCalendars: [EKCalendarModel] = []
    var calendarAccounts: [EKAccountModel] = []
    var calendarEvents: [UnifiedCalendarEvent] = []
    var upcomingCalendarEvents: [UnifiedCalendarEvent] = []
    var hiddenCalendarEventIDs: Set<String> = []
    var sparkleUpdateStatus: SparkleUpdateStatus = .idle
    var sparkleLastCheckedAt: Date?
    var contributionMilestonePrompt: ContributionMilestonePrompt?
    var pendingDiagnosticIncident: DiagnosticIncident?
    var modelPreparationTitle: String?
    var modelPreparationDetail: String?
    var modelPreparationProgress: Double?
    var isModelPreparingAfterDownload: Bool = false
    var modelPreparationIsComplete: Bool = false

    // Search
    var searchQuery: String = ""
    var searchResultMeetings: [MeetingRecord] = []
    var focusSearchField: Bool = false
    var isSearchActive: Bool { !searchQuery.isEmpty }

    // Navigation
    var selectedTab: DashboardTab = .meetings
    /// Set by the Insights Calendar segment to deep-link the Calendar page
    /// into a filtered list state ("recorded" | "missed" | "upcoming" |
    /// "all"). CalendarPageView consumes + clears it.
    var calendarDeepLinkFilter: String?
    var insightsBackLabel: String {
        "Back to Meetings"
    }
    var insightsInitialSection: InsightsSection = .meetings
    var selectedSettingsPane: SettingsPane = .general
    var selectedModelsCategory: ModelsCategory = .transcription

    // Computed
    var selectedMeeting: MeetingRecord? {
        guard let id = selectedMeetingID else { return nil }
        if let row = meetingRows.first(where: { $0.id == id }) {
            return row
        }
        guard selectedMeetingRecord?.id == id else { return nil }
        return selectedMeetingRecord
    }
}
