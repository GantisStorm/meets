import Foundation
import Observation
import MeetsCore

enum DashboardTab: String, CaseIterable {
    case meetings
    case calendar
    case insights
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
    case permissions
    case recording
    case calendar
    case notes
    case ai
    case advanced
    case appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .permissions: return "Permissions"
        case .recording: return "Recording"
        case .calendar: return "Calendar"
        case .notes: return "Notes"
        case .ai: return "AI"
        case .advanced: return "Advanced"
        case .appearance: return "Appearance"
        }
    }

    /// The pane's own glyph: the switcher's narrow form and the pane's
    /// introduction draw the same one.
    var iconName: String {
        switch self {
        case .general: return "gearshape"
        case .permissions: return "hand.raised"
        case .recording: return "record.circle"
        case .calendar: return "calendar"
        case .notes: return "doc.text"
        case .ai: return "sparkles"
        case .advanced: return "terminal"
        case .appearance: return "paintbrush"
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

enum ICloudBridgeState: Equatable {
    case notConfigured
    case checkingICloud
    case syncing
    case active
    case needsICloud
    case needsReconnection
    case needsAccountReplacement
    case error
}

enum ICloudBridgeCompanionDiscoveryState: Equatable {
    case idle
    case waiting
    case timedOut
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
    /// Complete browse index for the current folder scope: one lightweight
    /// entry per meeting, no transcripts. `meetingRows` stays the recently
    /// loaded full records; the browser combines both so shelves keep every
    /// follow-up member without reading the whole library's notes.
    var meetingBrowserEntries: [MeetingBrowserEntry] = []
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
    var interactionPermissionSnapshot: InteractionPermissionSnapshot?
    /// Permission requests currently settling; drives the "waiting" row state.
    var pendingPermissionRequests: Set<InteractionPermissionKind> = []
    /// Requests that fell back to System Settings, keyed by permission.
    var permissionHints: [InteractionPermissionKind: PermissionRequestHint] = [:]

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
    var openRouterTranscriptionModels: [SummaryModelPreset] = []
    var openRouterTranscriptionCatalogState: OpenRouterModelCatalogLoadState = .idle
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
