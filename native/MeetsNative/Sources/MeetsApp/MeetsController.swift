import AppKit
import AVFoundation
import CoreAudio
import EventKit
import Foundation
import Sparkle
import TelemetryDeck
import MeetsCore
import os


struct MeetingResummarizationPlan: Equatable {
    let promptTitle: String
    let persistedTitle: String
}

enum MeetingResummarizationPolicy {
    static func plan(for meeting: MeetingRecord) -> MeetingResummarizationPlan {
        let trimmed = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptTitle = trimmed.isEmpty ? "Meeting" : trimmed
        return MeetingResummarizationPlan(
            promptTitle: promptTitle,
            persistedTitle: meeting.title
        )
    }
}

enum MeetingSummaryPersistenceError: Error, LocalizedError {
    case failedToSaveSummary(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .failedToSaveSummary(let underlying):
            let detail = underlying.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "The updated meeting notes could not be saved."
            }
            return "The updated meeting notes could not be saved. \(detail)"
        }
    }
}

enum MeetingTemplateSelectionError: Error, LocalizedError {
    case templateNoLongerExists

    var errorDescription: String? {
        switch self {
        case .templateNoLongerExists:
            return "That template no longer exists. Choose another template and try again."
        }
    }
}

enum MeetingCompletionNotificationPolicy {
    static func shouldShow(
        hasPresentedMeetingCandidate: Bool,
        isShowingCalendarNotification: Bool,
        isMeetingNotificationVisible: Bool
    ) -> Bool {
        !hasPresentedMeetingCandidate
            && !isShowingCalendarNotification
            && !isMeetingNotificationVisible
    }
}

struct PendingMeetingCompletionNotification {
    let meetingID: Int64?
    let title: String
}

private struct CalendarParticipantReconciliationSnapshot: Sendable {
    let occurrence: CalendarOccurrenceReference
    let startDate: Date
    let participants: [MeetingParticipantDraft]
}

private enum CalendarAttendeePersistenceMode: Sendable, Equatable {
    case attach
    case reconcile
}

enum MeetingRetranscriptionError: Error, LocalizedError {
    case controllerUnavailable
    case recordingUnavailable
    case noDownloadedTranscriptionModel
    case emptyTranscript
    case failedToSave(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .controllerUnavailable:
            return "Meeting re-transcription could not continue because Meets is no longer available."
        case .recordingUnavailable:
            return "The saved meeting recording is no longer available on disk."
        case .noDownloadedTranscriptionModel:
            return "Download a transcription model before re-transcribing this meeting."
        case .emptyTranscript:
            return "Re-transcription finished, but no speech was detected in the saved recording."
        case .failedToSave(let underlying):
            return "The re-transcribed meeting could not be saved. \(underlying.localizedDescription)"
        }
    }
}

enum MeetingLifecycleError: Error, LocalizedError {
    case failedToSaveRecording(underlying: Error)
    case failedToDeleteRecording(underlying: Error)
    case failedToDeleteMeeting(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .failedToSaveRecording(let underlying):
            return "The meeting finished transcribing, but the recording could not be saved. \(underlying.localizedDescription)"
        case .failedToDeleteRecording(let underlying):
            return "The saved meeting recording could not be deleted, so the meeting was left in place. \(underlying.localizedDescription)"
        case .failedToDeleteMeeting(let underlying):
            return "The meeting could not be deleted. \(underlying.localizedDescription)"
        }
    }
}

struct CompletedMeetingPersistenceResult {
    let meetingID: Int64
    let recordingSaveError: MeetingLifecycleError?
}

struct MeetingRecordingSaveRequest: Sendable {
    let tempURL: URL
    let meetingTitle: String
    let startedAt: Date
    let supportDirectory: URL
    let fileFormat: MeetingRecordingFileFormat
}

enum MeetingRecordingSavePlan {
    case none
    case discard(tempURL: URL)
    case save(MeetingRecordingSaveRequest)
    case failed(MeetingLifecycleError)
}

struct PreparedMeetingRecordingSave {
    let path: String?
    let error: MeetingLifecycleError?

    static let none = PreparedMeetingRecordingSave(path: nil, error: nil)
}

@MainActor
public final class MeetsController: NSObject {
    /// Weak backreference to the running controller for AppIntents, which are
    /// instantiated fresh by the system per invocation and have no other way
    /// to reach in-process state. Set in `start()`, cleared implicitly on dealloc.
    /// Public (and the handful of members below it) because App Intents live
    /// in the separate MeetsAppShell executable module, not this library.
    public static weak var current: MeetsController?

    private static let pendingScreenContextEnableKey = "settings.pendingScreenContextEnable"
    private static let pendingScreenContextRequestedAtKey = "settings.pendingScreenContextRequestedAt"
    private static let screenContextGrantIntentTimeout: TimeInterval = 15 * 60
    private let runtime: RuntimePaths
    private let configStore: ConfigStore
    private let dictationStore: DictationStore
    private let meetingHookDispatcher: MeetingHookDispatching
    private let meetingMarkdownAutoExporter: MeetingMarkdownAutoExporting
    /// Zero-device cloud-folder mirror: copies completed meetings into a folder
    /// the user's cloud app already syncs (no accounts/API keys/entitlements).
    private let cloudMirror = MeetingCloudMirror()
    private let launchAtLoginCoordinator: LaunchAtLoginCoordinator
    let transcriptionCoordinator = TranscriptionCoordinator()
    /// Local Qwen3 GGUF cleanup engine, created on first use and reused across
    /// meeting transcript cleanups so the model stays warm. Stored as Any
    /// because Qwen3PostProcessor is macOS 15+ gated.
    private var qwen3PostProcessor: Any?
    private let meetingRecordingHotkeyMonitor = HotkeyMonitor()
    private let dictationAudioRoutingController: DictationAudioRouting

    private lazy var diagnosticIncidentReporter = DiagnosticIncidentReporter(
        appState: appState,
        automaticPromptEnabled: { [weak self] in
            self?.config.enableAutomaticDiagnosticIssuePrompts ?? false
        },
        onPrompt: { [weak self] _ in
            self?.presentHistoryWindow(tab: .about)
        }
    )
    private let indicator: FloatingIndicatorController
    private let calendarMonitor = CalendarMonitor()
    private let calendarEventQuery = CalendarEventQuery()
    private let meetingMonitor = MeetingMonitor()
    private let meetingNotification = MeetingNotificationController()
    private let meetingSourceWindowLocator = MeetingSourceWindowLocator()

    private let chatGPTAuth = ChatGPTAuthManager.shared
    private let openRouterAuth: OpenRouterAuthManager
    private let openRouterModelCatalogClient: OpenRouterModelCatalogClient
    private var calendarCheckTimer: Timer?
    private var calendarMonitoringStarted = false
    private var meetingStartingNowTimers = [String: Timer]()
    private var notifiedUpcomingEventIDs = Set<String>()
    private var autoRecordedCalendarEventIDs = Set<String>()
    private var meetingFeatureMonitorsAllowed = false
    private var meetingDetectionMonitorStarted = false
    private var interactionPermissionMonitoringClientIDs = Set<UUID>()
    private var interactionPermissionMonitoringRevision = 0
    private lazy var interactionPermissionMonitor = InteractionPermissionMonitor { [weak self] snapshot in
        self?.applyInteractionPermissionSnapshot(snapshot)
    }
    /// Every permission request goes through this coordinator, so the one-shot
    /// system APIs fire once per intent and an un-granted outcome opens the
    /// System Settings pane instead of silently doing nothing.
    lazy var permissionRequests = PermissionRequestCoordinator(
        appState: appState,
        snapshotSource: self
    )

    func beginInteractionPermissionMonitoring(clientID: UUID) {
        guard interactionPermissionMonitoringClientIDs.insert(clientID).inserted else { return }
        synchronizeInteractionPermissionMonitoringClients()
    }

    func endInteractionPermissionMonitoring(clientID: UUID) {
        guard interactionPermissionMonitoringClientIDs.remove(clientID) != nil else { return }
        synchronizeInteractionPermissionMonitoringClients()
    }

    private func synchronizeInteractionPermissionMonitoringClients() {
        interactionPermissionMonitoringRevision += 1
        let clientIDs = interactionPermissionMonitoringClientIDs
        let revision = interactionPermissionMonitoringRevision
        let monitor = interactionPermissionMonitor
        Task {
            await monitor.updateClients(clientIDs, revision: revision)
        }
    }

    func refreshInteractionPermissionSnapshot() {
        let monitor = interactionPermissionMonitor
        Task {
            await monitor.refresh()
        }
    }

    private func applyInteractionPermissionSnapshot(_ snapshot: InteractionPermissionSnapshot) {
        guard appState.interactionPermissionSnapshot != snapshot else { return }
        appState.interactionPermissionSnapshot = snapshot
        permissionRequests.handleSnapshot(snapshot)

        reconcilePendingScreenContextPermission(snapshot)
    }

    private func reconcilePendingScreenContextPermission(_ snapshot: InteractionPermissionSnapshot) {
        let defaults = UserDefaults.standard
        let isPending = defaults.bool(forKey: Self.pendingScreenContextEnableKey)
        let requestedAt = defaults.double(forKey: Self.pendingScreenContextRequestedAtKey)

        if snapshot.accessibility, isPending, requestScreenContextEnable() {
            clearPendingScreenContextPermission(defaults: defaults)
        }

        let pendingRequestExpired = isPending
            && (requestedAt <= 0
                || Date().timeIntervalSince1970 - requestedAt > Self.screenContextGrantIntentTimeout)
        if !snapshot.accessibility, pendingRequestExpired {
            clearPendingScreenContextPermission(defaults: defaults)
        }

        if !snapshot.accessibility, config.enableScreenContext {
            clearPendingScreenContextPermission(defaults: defaults)
            updateConfig { $0.enableScreenContext = false }
        }
    }

    private func clearPendingScreenContextPermission(defaults: UserDefaults) {
        defaults.set(false, forKey: Self.pendingScreenContextEnableKey)
        defaults.set(0, forKey: Self.pendingScreenContextRequestedAtKey)
    }

    func requestScreenContextEnable() -> Bool {
        guard AXIsProcessTrusted() else {
            updateConfig { $0.enableScreenContext = false }
            permissionRequests.request(.accessibility)
            return false
        }

        updateConfig { $0.enableScreenContext = true }
        return true
    }


    private var searchTask: Task<Void, Never>?
    private var onboardingModelPreparationTask: Task<Void, Never>?
    private var openRouterSummaryCatalogTask: Task<Void, Never>?
    private var maraudersMapCountdown: MaraudersMapCountdownController?

    private var statusBarController: StatusBarController?
    private var historyWindowController: RecentHistoryWindowController?
    private var preferencesWindowController: PreferencesWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private lazy var systemPermissionGuideController: AccessibilityPermissionGuideController = {
        let guide = AccessibilityPermissionGuideController()
        guide.onPresentationChanged = { [weak self] presentation in
            self?.onboardingWindowController?.applySystemSettingsGuidePresentation(presentation)
        }
        return guide
    }()
    var updaterController: SPUStandardUpdaterController?
    private var busyStatusGeneration = 0

    let appState = AppState()

    private(set) var config: AppConfig
    private(set) var selectedBackend: BackendOption
    private(set) var selectedMeetingTranscriptionBackend: BackendOption
    private(set) var selectedMeetingSummaryBackend: MeetingSummaryBackendOption
    private var activeMeetingSession: MeetingSession?
    private weak var preparingMeetingSession: MeetingSession?
    private var activeMeetingID: Int64?
    /// Set when a meeting stops, so telemetry events legitimately emitted by
    /// the stopping session (after activeMeetingID becomes nil) still pass the
    /// session-identity gate. Replaced on the next meeting start.
    private var micEpisodeTelemetryGate = RecentMeetingIdentityGate()
    private var liveMeetingTranscriptGeneration: UUID?
    private var activeMeetingAudioWarning: ActiveMeetingAudioWarning?
    private var liveMeetingTitleCache: [Int64: String] = [:]
    private var liveManualNotesCache: [Int64: String] = [:]
    private var liveManualNotesLastPersistedAt: [Int64: Date] = [:]
    private var liveManualNotesLastPersistedValue: [Int64: String] = [:]
    private var liveManualNotesPersistWorkItems: [Int64: DispatchWorkItem] = [:]
    private var calendarAttendeePersistenceTasks: [
        Int64: (generation: UUID, task: Task<Bool, Never>)
    ] = [:]
    private let liveManualNotesPersistInterval: TimeInterval = 0.75
    private var staleLiveMeetingRecoveryFailures = Set<Int64>()

    private var openWindowCount = 0
    private var lastExternalApp: NSRunningApplication?
    private var workspaceObserver: NSObjectProtocol?
    private var dataDidChangeObserver: NSObjectProtocol?
    private var isStartingMeetingRecording = false
    private var meetingStartStatus: String?
    private var isShowingCalendarNotification = false
    private var presentedMeetingCandidate: MeetingCandidate?
    private var meetingEndTimer: Timer?
    private var activeMeetingCalendarEndDate: Date?
    private var latestMeetingActivityCandidate: MeetingCandidate?
    private var latestMeetingActivityCandidateObservedAt: Date?
    private var activeMeetingAutoStop = MeetingAutoStopTracker()
    private var activeMeetingSignalLossResponse: MeetingSignalLossResponse = .none
    private var meetingSignalLossPromptState = MeetingSignalLossPromptState()
    private let meetingAutoStopGracePeriod: TimeInterval = 20
    private var meetingActivity: NSObjectProtocol?
    private var isStoppingMeetingRecording = false
    private var isPresentingMeetingTerminationConfirmation = false
    private var isTerminatingAfterMeetingConfirmation = false
    private var backgroundMeetingProcessingCount = 0
    private var meetingProcessingStages: [UUID: MeetingProcessingStage] = [:]
    private var pendingMeetingCompletionNotification: PendingMeetingCompletionNotification?
    private var contributionMilestonePromptDismissedThisLaunch = false
    private var contributionMilestonePromptSeenIDsThisLaunch: Set<String> = []
    private var meetingStartTask: Task<Void, Never>?
    private var meetingStartMeetingID: Int64?
    private var importTask: Task<Void, Never>?
    private var importSessionID: UUID?
    private var canceledMeetingStartIDs = Set<Int64>()
    /// Coalescing + dedupe for `handleCalendarEventChange`: EventKit change
    /// notifications arrive in bursts. Each call bumps the token; the caller
    /// that still owns the token after the settle window runs the sync pass.
    private var calendarChangeLastRunEventTitles: [String: String] = [:]
    private var calendarChangeDebounceToken = 0
    /// Prior transcript captured when resuming a finished meeting, keyed by meeting id.
    /// Present only while a resume is in flight; consumed at stop to merge old + new
    /// transcript, and cleared on success or restored-on-failure.
    private var pendingResumePriorTranscript: [Int64: String] = [:]
    private var hasStarted = false

    init(
        runtime: RuntimePaths,
        dictationStore: DictationStore? = nil,
        configStore: ConfigStore = ConfigStore(),
        meetingHookDispatcher: MeetingHookDispatching = MeetingHookRunner(),
        meetingMarkdownAutoExporter: MeetingMarkdownAutoExporting = MeetingMarkdownAutoExporter(),
        launchAtLoginManager: LaunchAtLoginManaging = SystemLaunchAtLoginManager(),
        dictationAudioRoutingController: DictationAudioRouting = DictationAudioRouteController(),
        openRouterAuth: OpenRouterAuthManager? = nil,
        openRouterModelCatalogClient: OpenRouterModelCatalogClient = OpenRouterModelCatalogClient()
    ) {
        self.configStore = configStore
        self.openRouterAuth = openRouterAuth ?? .shared
        self.openRouterModelCatalogClient = openRouterModelCatalogClient
        var loadedConfig = configStore.load()
        let loadedBackend = BackendOption.all.first(where: {
            $0.backend == loadedConfig.sttBackend && $0.model == loadedConfig.sttModel
        }) ?? .whisper
        self.runtime = runtime
        self.dictationStore = dictationStore ?? DictationStore(
            databaseURL: MeetsPaths.defaultDatabaseURL(appName: AppIdentity.supportDirectoryName)
        )
        self.meetingHookDispatcher = meetingHookDispatcher
        self.meetingMarkdownAutoExporter = meetingMarkdownAutoExporter
        self.launchAtLoginCoordinator = LaunchAtLoginCoordinator(manager: launchAtLoginManager)
        self.dictationAudioRoutingController = dictationAudioRoutingController
        self.dictationAudioRoutingController.selectedMeetingInputDeviceUID = loadedConfig.meetingInputDeviceUID
        self.config = loadedConfig
        if loadedConfig.recordingColorHex != "1e1e2e" {
            MeetsTheme.accentOverrideHex = loadedConfig.recordingColorHex
        }
        self.selectedBackend = loadedBackend
        let configuredMeetingBackend = BackendOption.resolve(
            backend: loadedConfig.meetingTranscriptionBackend,
            model: loadedConfig.meetingTranscriptionModel
        )
        self.selectedMeetingTranscriptionBackend = Self.availableMeetingTranscriptionBackend(
            config: loadedConfig,
            dictationBackend: self.selectedBackend,
            downloadedOptions: BackendOption.downloaded
        ) ?? Self.fallbackMeetingTranscriptionBackend(
            configured: configuredMeetingBackend,
            dictationBackend: self.selectedBackend
        )
        self.selectedMeetingSummaryBackend = MeetingSummaryBackendOption.all.first(where: {
            $0.backend == loadedConfig.meetingSummaryBackend
        }) ?? .chatGPT
        self.indicator = FloatingIndicatorController(configStore: configStore)
        super.init()

        dictationAudioRoutingController.onMeetingPreferredInputDeviceChanged = { [weak self] deviceID in
            Task { @MainActor [weak self] in
                self?.applyMeetingInputDevice(deviceID)
            }
        }
    }

    func start() {
        hasStarted = true
        MeetsController.current = self
        do {
            try dictationStore.migrateIfNeeded()
            try dictationStore.markRunningComputerUseTracesInterrupted()
        } catch {
            fputs("[meets] startup error: \(error)\n", stderr)
        }
        recoverStaleLiveMeetings()
        normalizeMeetingTranscriptionSelectionForAvailability()
        SoundController.prewarmLifecycleSounds()

        // Clean up phantom aggregate devices left by a previous crash
        CoreAudioSystemRecorder.cleanupStaleDevices()

        syncLaunchAtLoginConfigWithSystem()

        // Clean up leftover audio temp files from previous sessions.
        cleanupTemporaryDirectory(
            named: "meets-system-audio",
            logDescription: "leftover temp audio files"
        )
        cleanupTemporaryDirectory(
            named: "meets-meeting-recordings",
            logDescription: "leftover temp meeting recording files"
        )
        cleanupHistoricalMeetingWaveformCacheFilesIfNeeded()

        meetingRecordingHotkeyMonitor.onStart = { [weak self] in
            DispatchQueue.main.async { self?.toggleMeetingRecording() }
        }
        meetingRecordingHotkeyMonitor.onToggleStart = { [weak self] in
            DispatchQueue.main.async { self?.toggleMeetingRecording() }
        }
        meetingRecordingHotkeyMonitor.onToggleStop = { [weak self] in
            DispatchQueue.main.async { self?.toggleMeetingRecording() }
        }
        meetingRecordingHotkeyMonitor.onCancel = { [weak self] in
            DispatchQueue.main.async { self?.stopMeetingRecording() }
        }

        let canRunMainApp = config.hasCompletedOnboarding
            && hasRequiredStartupPermissions(for: config.resolvedOnboardingUseCase)
        meetingFeatureMonitorsAllowed = canRunMainApp

        if canRunMainApp {
            startMeetingRecordingHotkeyMonitorIfNeeded()
        }
        indicator.onStopMeeting = { [weak self] in self?.stopMeetingRecording() }
        indicator.onDiscardMeeting = { [weak self] in self?.discardMeetingWithConfirmation() }
        indicator.onToggleMeetingPause = { [weak self] in self?.toggleMeetingRecordingPause() }
        indicator.onOpenMeetingNotes = { [weak self] in self?.openActiveMeetingNotes() }

        indicator.onPositionSaved = { [weak self] center in
            self?.updateConfig {
                $0.indicatorAnchor = .custom
                $0.indicatorOrigin = CGPointCodable(x: center.x, y: center.y)
            }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app != NSRunningApplication.current
            else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastExternalApp = app
            }
        }
        dataDidChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: MeetsNotifications.dataDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.historyWindowController?.reload()
                self.syncAppState()
            }
        }
        statusBarController = StatusBarController(controller: self, runtime: runtime)
        preferencesWindowController = PreferencesWindowController(controller: self)
        historyWindowController = RecentHistoryWindowController(controller: self)
        refreshUI()

        meetingMonitor.calendarEventProvider = { [weak self] in
            self?.currentOrNearbyCachedCalendarEvent()
        }
        meetingMonitor.detectionEnabledProvider = { [weak self] in
            guard let self else { return false }
            return self.config.showMeetingDetectionNotification
                || self.activeMeetingAutoStop.isArmed
        }
        meetingMonitor.mutedDetectionBundleIDsProvider = { [weak self] in
            Set(self?.config.mutedMeetingDetectionAppBundleIDs ?? [])
        }
        meetingMonitor.customMeetingAppsProvider = { [weak self] in
            self?.customMeetingDetectionAppTable() ?? [:]
        }
        meetingMonitor.recordingLifecycleProvider = { [weak self] in
            guard let self else { return .idle }
            return MeetingRecordingLifecycleSnapshot(
                phase: self.activeMeetingSession?.capturePhase ?? .stopped,
                sessionID: self.activeMeetingID,
                autoStopSource: self.activeMeetingAutoStop.source
            )
        }
        meetingMonitor.selfAudioActivityActiveProvider = { [weak self] in
            guard let self else { return false }
            return self.isMeetingRecording()
        }
        meetingMonitor.isCalendarNotificationVisibleProvider = { [weak self] in
            self?.isShowingCalendarNotification ?? false
        }
        meetingMonitor.promptVisibilityProvider = { [weak self] in
            guard let self else {
                return MeetingPromptVisibility(isVisible: false, currentPromptID: nil, shownAt: nil)
            }
            return MeetingPromptVisibility(
                isVisible: self.meetingNotification.isVisible,
                currentPromptID: self.meetingNotification.currentPromptID,
                shownAt: self.meetingNotification.shownAt
            )
        }
        meetingMonitor.onActivityCandidateChanged = { [weak self] candidate in
            self?.handleMeetingActivityCandidate(candidate)
        }
        meetingMonitor.onPromptCandidateChanged = { [weak self] candidate in
            guard let self else { return }
            if let candidate {
                self.presentMeetingDetection(candidate)
            } else {
                self.dismissPresentedMeetingDetection()
            }
        }

        // Calendar monitor populates the "Coming Up" section even when
        // meeting detection is turned off for meeting use cases. Also keep it
        // running for existing users who enabled meeting feature settings before
        // onboarding use cases existed.
        syncCalendarMonitor()

        // Surface EventKit authorization/calendars to app state without
        // prompting: the prompt fires on first explicit calendar use.
        Task { [weak self] in
            await self?.refreshCalendarAccess()
        }

        // Defer permission-triggering monitors until after onboarding
        if canRunMainApp && shouldRunMeetingFeatureMonitors {
            startMeetingFeatureMonitors(includeMaraudersMap: true)
        }

        if canRunMainApp {
            Task { [weak self] in
                guard let self else { return }
                let includesMeetings = self.config.resolvedOnboardingUseCase.includesMeetings
                if #available(macOS 15, *) {
                    await self.transcriptionCoordinator.setNemotron35PromptId(
                        self.config.resolvedNemotron35Language.promptId
                    )
                }
                if includesMeetings {
                    await self.transcriptionCoordinator.preload(
                        backend: self.selectedMeetingTranscriptionBackend,
                        includeMeetingHelpers: false,
                        appleSpeechLanguage: self.config.resolvedAppleSpeechLanguage
                    )
                }
                await MainActor.run {
                    self.refreshUI()
                }
            }
        }

        if !canRunMainApp, !config.hasCompletedOnboarding {
            if let progress = OnboardingProgress.load() {
                showOnboarding(resumeFrom: progress)
            } else {
                showOnboarding()
            }
        } else if config.openDashboardOnLaunch {
            openHistoryWindow()
        }

        if canRunMainApp {
            PostInstallChecker.check()
        }
    }

    func shutdown() async {
        systemPermissionGuideController.dismiss()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        if let dataDidChangeObserver {
            DistributedNotificationCenter.default().removeObserver(dataDidChangeObserver)
            self.dataDidChangeObserver = nil
        }
        meetingRecordingHotkeyMonitor.stop()

        let attendeePersistenceTasks = calendarAttendeePersistenceTasks.values.map(\.task)
        calendarAttendeePersistenceTasks.removeAll()
        for task in attendeePersistenceTasks {
            _ = await task.value
        }
        calendarEventQuery.invalidate()
        calendarMonitor.stop()
        calendarCheckTimer?.invalidate()
        calendarCheckTimer = nil
        calendarMonitoringStarted = false
        meetingStartingNowTimers.values.forEach { $0.invalidate() }
        meetingStartingNowTimers.removeAll()
        notifiedUpcomingEventIDs.removeAll()
        autoRecordedCalendarEventIDs.removeAll()
        meetingFeatureMonitorsAllowed = false
        disarmMeetingAutoStop()
        meetingMonitor.stop()
        meetingDetectionMonitorStarted = false
        dismissPresentedMeetingDetection()
        meetingNotification.close()
        activeMeetingSession?.discard()
        activeMeetingSession = nil
        if let activeMeetingID {
            resolveLiveMeetingAfterStopFailure(id: activeMeetingID)
            self.activeMeetingID = nil
        }
        activeMeetingAudioWarning = nil
        endMeetingActivity()
        await transcriptionCoordinator.shutdown()
        indicator.close()
        CoreAudioSystemRecorder.cleanupStaleDevices()
    }


    func meeting(id: Int64) -> MeetingRecord? {
        if let row = appState.meetingRows.first(where: { $0.id == id }) {
            return row
        }
        return try? dictationStore.meeting(id: id)
    }

    func transcriptWords(for meetingID: Int64) -> [TranscriptWordTiming] {
        (try? dictationStore.transcriptWords(meetingID: meetingID)) ?? []
    }



    func meetingStats() -> MeetingStats {
        (try? dictationStore.meetingStats()) ?? MeetingStats(totalWords: 0, totalMeetings: 0, averageWPM: 0)
    }

    func openInsights(section: InsightsSection) {
        appState.insightsInitialSection = section
        appState.selectedTab = .insights
    }

    /// Deep-links from the Insights Calendar segment into the Calendar page
    /// in List mode with the given filter applied ("all" | "upcoming" |
    /// "past" | "recorded" | "unrecorded").
    func openCalendarWithFilter(_ filter: String) {
        if appState.isSearchActive {
            clearSearch()
        }
        appState.calendarDeepLinkFilter = filter
        appState.selectedTab = .calendar
    }

    func showModels(category: ModelsCategory) {
        if appState.isSearchActive {
            clearSearch()
        }
        appState.selectedModelsCategory = category
        appState.selectedTab = .models
    }

    func closeInsights() {
        appState.selectedTab = .meetings
    }

    func insightsSnapshot(range: InsightsRange) async throws -> InsightsSnapshot {
        let databaseURL = dictationStore.resolvedDatabaseURL
        // Compute calendar linkage on the main actor (appState is
        // MainActor-isolated); the store cannot see live calendars.
        let now = Date()
        let calendar = Calendar.current
        let startDate = range.startDate(now: now, calendar: calendar)
        let events = appState.calendarEvents
        let meetings = appState.meetingRows
        let disabled = Set(config.disabledCalendarIDs)
        let calendarStats: MeetingCalendarLinkageStats = {
            let filtered = events.filter { event in
                guard let cid = event.calendarID else { return true }
                return !disabled.contains(cid)
            }
            let inWindow = filtered.filter { event in
                if let startDate {
                    return event.endDate >= startDate
                }
                return true
            }
            var recorded = 0
            var missed = 0
            var upcoming = 0
            var cancelled = 0
            for event in inWindow {
                if event.isCancelled || event.isDeclined {
                    cancelled += 1
                    continue
                }
                let linkage = MeetingEventLinkage.derive(
                    event: event,
                    meetings: meetings,
                    now: now
                )
                switch linkage.state {
                case .recording, .processing, .completed:
                    recorded += 1
                case .missed:
                    missed += 1
                case .upcoming, .now:
                    upcoming += 1
                case .cancelledEvent, .noEvent:
                    break
                }
            }
            return MeetingCalendarLinkageStats(
                eventsInRange: inWindow.count,
                recordedEvents: recorded,
                missedEvents: missed,
                upcomingEvents: upcoming,
                cancelledEvents: cancelled
            )
        }()

        let snapshot = try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try DictationStore(databaseURL: databaseURL).insightsSnapshot(range: range)
        }.value
        return snapshot.replacing(calendarStats: calendarStats)
    }

    func refreshIndicatorPresentation() {
        indicator.refreshPresentation(config: config)
        indicator.refreshMeetingTranscriptPreference(config: config)
    }

    func refreshUI() {
        statusBarController?.setStatus("Idle")
        statusBarController?.refresh()
        historyWindowController?.updateBackendLabel()
        historyWindowController?.applyThemeAppearance()
        historyWindowController?.reload()
        preferencesWindowController?.refresh()
        refreshIndicatorPresentation()
        syncAppState()
    }

    func syncAppState() {
        appState.meetingRows = (try? dictationStore.recentMeetings(
            limit: 200,
            folderID: appState.selectedFolderID
        )) ?? []
        // Complete, text-free index for the same scope. Without it a follow-up
        // whose relative sits outside the recent 200 would render without its
        // parent; with it the browser can rebuild every thread in scope while
        // `meetingRows` keeps supplying full records to the loaded window.
        appState.meetingBrowserEntries = (try? dictationStore.meetingBrowserEntries(
            folderID: appState.selectedFolderID
        )) ?? []
        // Single cheap pass so views can index extra "Add to Event"
        // attachments without per-meeting queries.
        appState.meetingEventLinks = (try? dictationStore.allMeetingEventLinks()) ?? []
        let counts = (try? dictationStore.meetingCounts())
            ?? (total: 0, byFolder: [:], directByFolder: [:])
        appState.totalMeetingCount = counts.total
        appState.meetingCountsByFolder = counts.byFolder
        appState.directMeetingCountsByFolder = counts.directByFolder
        if let selectedMeetingID = appState.selectedMeetingID {
            appState.selectedMeetingRecord = appState.meetingRows.first(where: { $0.id == selectedMeetingID })
                ?? meeting(id: selectedMeetingID)
        } else {
            appState.selectedMeetingRecord = nil
        }
        let allFolders = (try? dictationStore.listFolders()) ?? []
        if config.folderOrder.isEmpty && !allFolders.isEmpty {
            config.folderOrder = allFolders.map(\.id)
            configStore.save(config)
        }
        let order = config.folderOrder
        // Sort folders into a depth-first tree order so children appear beneath parents.
        appState.folders = Self.treeOrderedFolders(allFolders, order: order)
        appState.meetingStats = meetingStats()
        refreshContributionMilestonePrompt(
            totalMeetings: appState.meetingStats.totalMeetings
        )
        appState.selectedBackend = selectedBackend
        appState.selectedMeetingTranscriptionBackend = selectedMeetingTranscriptionBackend
        appState.selectedMeetingSummaryBackend = selectedMeetingSummaryBackend
        appState.config = config
        appState.isMeetingRecording = isMeetingRecording()
        appState.isMeetingRecordingPaused = isMeetingRecordingPaused()
        appState.isMeetingStarting = isStartingMeetingRecording
        appState.meetingStartStatus = meetingStartStatus
        appState.activeMeetingAudioWarning = activeMeetingAudioWarning
        indicator.setMeetingRecordingPaused(appState.isMeetingRecordingPaused, config: config)
        appState.isChatGPTAuthenticated = chatGPTAuth.isAuthenticated
        appState.isOpenRouterAuthenticated = openRouterAuth.isAuthenticated
        appState.isOpenRouterEnvironmentManaged = openRouterAuth.hasEnvironmentCredential
        appState.hasStoredOpenRouterCredential = openRouterAuth.hasStoredCredential

        // Keep appState in sync with persisted hidden event IDs
        let persisted = Set(config.hiddenCalendarEventIDs)
        if appState.hiddenCalendarEventIDs != persisted {
            appState.hiddenCalendarEventIDs = persisted
        }
    }

    func recoverStaleLiveMeetings() {
        guard !isMeetingRecording(),
              !isStartingMeetingRecording else { return }
        let meetings: [MeetingRecord]
        do {
            meetings = try dictationStore.staleLiveMeetings()
        } catch {
            fputs("[meets] failed to load stale live meetings: \(error)\n", stderr)
            return
        }

        for meeting in meetings {
            do {
                let recovered = try dictationStore.recoverLiveMeetingFromTranscriptCheckpoints(id: meeting.id)
                if recovered {
                } else {
                    try updateMeetingStatusAndScheduleSyncThrowing(id: meeting.id, status: .failed)
                }
                staleLiveMeetingRecoveryFailures.remove(meeting.id)
            } catch {
                staleLiveMeetingRecoveryFailures.insert(meeting.id)
                fputs("[meets] failed to recover stale meeting \(meeting.id): \(error)\n", stderr)
            }
        }

        if !meetings.isEmpty {
            syncAppState()
        }
    }

    func performSearch(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.searchQuery = trimmed
        guard !trimmed.isEmpty else {
            appState.searchResultMeetings = []
            return
        }
        let store = self.dictationStore
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let meetings = await Task.detached(priority: .userInitiated) {
                (try? store.searchMeetings(query: trimmed)) ?? []
            }.value
            guard !Task.isCancelled, let self else { return }
            self.appState.searchResultMeetings = meetings
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        appState.searchQuery = ""
        appState.searchResultMeetings = []
    }

    private static func availableMeetingTranscriptionBackend(
        config: AppConfig,
        dictationBackend: BackendOption,
        downloadedOptions: [BackendOption] = BackendOption.downloaded
    ) -> BackendOption? {
        let meetingOptions = downloadedOptions.filter(\.supportsMeetingTranscription)
        let fallback = dictationBackend.supportsMeetingTranscription ? dictationBackend : nil
        return BackendOption.resolveDownloaded(
            backend: config.meetingTranscriptionBackend,
            model: config.meetingTranscriptionModel,
            fallback: fallback,
            downloadedOptions: meetingOptions
        )
    }

    private static func fallbackMeetingTranscriptionBackend(
        configured: BackendOption?,
        dictationBackend: BackendOption
    ) -> BackendOption {
        if let configured, configured.supportsMeetingTranscription {
            return configured
        }
        if dictationBackend.supportsMeetingTranscription {
            return dictationBackend
        }
        return BackendOption.all.first(where: \.supportsMeetingTranscription) ?? .whisper
    }

    @discardableResult
    private func normalizeMeetingTranscriptionSelectionForAvailability(
        downloadedOptions: [BackendOption] = BackendOption.downloaded
    ) -> BackendOption? {
        let dictationBackend = BackendOption.resolve(
            backend: config.sttBackend,
            model: config.sttModel
        ) ?? selectedBackend
        guard let resolved = Self.availableMeetingTranscriptionBackend(
            config: config,
            dictationBackend: dictationBackend,
            downloadedOptions: downloadedOptions
        ) else {
            selectedMeetingTranscriptionBackend = Self.fallbackMeetingTranscriptionBackend(
                configured: BackendOption.resolve(
                    backend: config.meetingTranscriptionBackend,
                    model: config.meetingTranscriptionModel
                ),
                dictationBackend: dictationBackend
            )
            appState.selectedMeetingTranscriptionBackend = selectedMeetingTranscriptionBackend
            appState.config = config
            return nil
        }

        selectedMeetingTranscriptionBackend = resolved
        activeMeetingSession?.updateBackend(resolved)
        if config.meetingTranscriptionBackend != resolved.backend ||
            config.meetingTranscriptionModel != resolved.model {
            config.meetingTranscriptionBackend = resolved.backend
            config.meetingTranscriptionModel = resolved.model
            configStore.save(config)
            fputs("[meets] meeting transcription model unavailable; switched to \(resolved.label)\n", stderr)
        }
        appState.selectedMeetingTranscriptionBackend = resolved
        appState.config = config
        return resolved
    }

    @discardableResult
    func refreshMeetingTranscriptionSelectionForAvailability() -> BackendOption? {
        normalizeMeetingTranscriptionSelectionForAvailability()
    }

    func updateConfig(
        _ mutate: (inout AppConfig) -> Void
    ) {
        let wasUsingAppleSpeech = selectedBackend.backend == "apple-speech"
            || selectedMeetingTranscriptionBackend.backend == "apple-speech"
            || (config.enableLiveStreamingPartials && config.resolvedMeetingLiveCaptionBackend == .appleSpeech)
        let previousAppleSpeechLanguage = config.resolvedAppleSpeechLanguage
        let wasUsingAppleSpeechLive = config.enableLiveStreamingPartials
            && config.resolvedMeetingLiveCaptionBackend == .appleSpeech
        let previousMeetingInputDeviceUID = config.meetingInputDeviceUID
        let previousMeetingRecordingHotkeyTriggerThresholdMS = config.meetingRecordingHotkeyTriggerThresholdMS
        let previousEnableLiveStreamingPartials = config.enableLiveStreamingPartials
        mutate(&config)
        if previousEnableLiveStreamingPartials, !config.enableLiveStreamingPartials {
            activeMeetingSession?.stopStreamingPartials()
            clearLiveMeetingPartialTails()
        }
        config.meetingRecordingHotkeyTriggerThresholdMS = HotkeyTriggerTiming.clampedMilliseconds(config.meetingRecordingHotkeyTriggerThresholdMS)
        let hotkeyTriggerThresholdChanged = config.meetingRecordingHotkeyTriggerThresholdMS != previousMeetingRecordingHotkeyTriggerThresholdMS
        MeetsTheme.accentOverrideHex = config.recordingColorHex == "1e1e2e" ? nil : config.recordingColorHex
        selectedBackend = BackendOption.all.first(where: {
            $0.backend == config.sttBackend && $0.model == config.sttModel
        }) ?? .whisper

        let configuredMeetingTranscriptionBackend = BackendOption.all.first(where: {
            $0.backend == config.meetingTranscriptionBackend && $0.model == config.meetingTranscriptionModel
        })
        selectedMeetingTranscriptionBackend = Self.availableMeetingTranscriptionBackend(
            config: config,
            dictationBackend: selectedBackend
        ) ?? Self.fallbackMeetingTranscriptionBackend(
            configured: configuredMeetingTranscriptionBackend,
            dictationBackend: selectedBackend
        )
        if config.meetingTranscriptionBackend != selectedMeetingTranscriptionBackend.backend ||
            config.meetingTranscriptionModel != selectedMeetingTranscriptionBackend.model {
            config.meetingTranscriptionBackend = selectedMeetingTranscriptionBackend.backend
            config.meetingTranscriptionModel = selectedMeetingTranscriptionBackend.model
        }
        let isUsingAppleSpeech = selectedBackend.backend == "apple-speech"
            || selectedMeetingTranscriptionBackend.backend == "apple-speech"
            || (config.enableLiveStreamingPartials && config.resolvedMeetingLiveCaptionBackend == .appleSpeech)
        if wasUsingAppleSpeech && !isUsingAppleSpeech {
            Task { [weak self] in
                await self?.transcriptionCoordinator.unloadAppleSpeechTranscriber()
            }
        }
        if previousAppleSpeechLanguage != config.resolvedAppleSpeechLanguage
            || (isUsingAppleSpeech && (!wasUsingAppleSpeech
            || (!wasUsingAppleSpeechLive && config.enableLiveStreamingPartials
                && config.resolvedMeetingLiveCaptionBackend == .appleSpeech))) {
            let language = config.resolvedAppleSpeechLanguage
            Task { [weak self] in
                guard let self, self.config.resolvedAppleSpeechLanguage == language,
                      #available(macOS 26.0, *) else { return }
                do {
                    try await AppleSpeechAnalyzerTranscriber.shared.prepareSelectedLanguage(
                        AppleSpeechLanguageOption.requestedLocale(for: language))
                } catch {
                    fputs("[meets] Apple Speech selection preparation failed: \(error)\n", stderr)
                }
            }
        }
        configStore.save(config)
        selectedMeetingSummaryBackend = MeetingSummaryBackendOption.all.first(where: {
            $0.backend == config.meetingSummaryBackend
        }) ?? .chatGPT
        if hotkeyTriggerThresholdChanged {
            configureHotkeyMonitorTiming()
        }
        if previousMeetingInputDeviceUID != config.meetingInputDeviceUID {
            dictationAudioRoutingController.selectedMeetingInputDeviceUID = config.meetingInputDeviceUID
            applyMeetingInputDevice(dictationAudioRoutingController.preferredInputDeviceIDForMeeting())
        }
        syncAppState()
    }

    // MARK: - Cloud Sync

    /// Cloud folders available to mirror into, most useful first (iCloud,
    /// Dropbox, then CloudStorage providers). Pure local file checks — safe on
    /// the main actor and fast enough to call on every settings render.
    func cloudSyncLocations() -> [CloudSyncLocation] {
        CloudSyncDetector.detect()
    }

    /// Persists the cloud-mirror configuration. Mirroring takes effect on the
    /// next completed meeting (or the next "Sync Now").
    func setCloudSync(enabled: Bool, folderPath: String, includesAudio: Bool) {
        let trimmedFolder = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        updateConfig { config in
            config.cloudSyncEnabled = enabled
            config.cloudSyncFolderPath = trimmedFolder
            config.cloudSyncIncludesAudio = includesAudio
        }
    }

    /// Mirrors the given completed meeting into the configured cloud folder.
    /// No-op when cloud sync is off or the folder path is not configured.
    func mirrorCompletedMeeting(record: MeetingRecord) async {
        guard config.cloudSyncEnabled,
              cloudMirror.isCloudSyncConfigured(config) else { return }
        await cloudMirror.mirror(meeting: record, config: config)
    }

    /// Mirrors every meeting in the store into the configured cloud folder
    /// ("Sync Now"). Returns a human-readable status line, or nil when nothing
    /// was mirrored (feature off / no destination / no meetings).
    func syncAllToCloud() async -> String? {
        guard cloudMirror.isCloudSyncConfigured(config) else { return nil }
        guard let meetings = try? dictationStore.recentMeetings() else { return nil }
        guard !meetings.isEmpty else { return nil }
        let mirroredCount = await cloudMirror.mirrorAllMeetings(meetings: meetings, config: config)
        guard mirroredCount > 0 else { return nil }
        let total = meetings.count
        return "Mirrored \(mirroredCount) of \(total) meeting\(total == 1 ? "" : "s") to cloud folder"
    }

    /// Applies the configured theme to app-level chrome. The fullscreen
    /// titlebar, menus, and panels resolve against `NSApp.appearance` rather
    /// than any individual window's appearance, so syncing only the window
    /// leaves fullscreen chrome following the OS theme instead of the app's.
    /// Also refreshes the dashboard window's own appearance.
    func applyAppThemeAppearance() {
        // NSApp is an implicitly unwrapped optional and is nil under `swift test`, where no
        // NSApplication is ever created. Touching it there traps and takes the whole test
        // bundle down, so bind it rather than forcing it.
        if let app = NSApp {
            app.appearance = NSAppearance(
                named: RecentHistoryWindowController.appearanceName(for: config.darkMode)
            )
        }
        historyWindowController?.applyThemeAppearance()
    }


    private func clearLiveMeetingPartialTails() {
        appState.liveMeetingPartialYou = ""
        appState.liveMeetingPartialOthers = ""
        indicator.updateMeetingTranscript(
            transcript: appState.liveMeetingTranscript,
            partialYou: "",
            partialOthers: ""
        )
    }

    private func clearLiveMeetingTranscript(ownerID: Int64? = nil, generation: UUID? = nil) {
        if let ownerID, appState.liveMeetingTranscriptOwnerID != ownerID { return }
        if let generation, liveMeetingTranscriptGeneration != generation { return }
        appState.liveMeetingTranscript = ""
        appState.liveMeetingPartialYou = ""
        appState.liveMeetingPartialOthers = ""
        appState.liveMeetingTranscriptOwnerID = nil
        liveMeetingTranscriptGeneration = nil
        indicator.updateMeetingTranscript(transcript: "", partialYou: "", partialOthers: "")
    }

    private func isCurrentLiveMeetingTranscriptSession(ownerID: Int64, generation: UUID) -> Bool {
        appState.liveMeetingTranscriptOwnerID == ownerID
            && liveMeetingTranscriptGeneration == generation
    }

    private func refreshContributionMilestonePrompt(totalMeetings: Int) {
        let resolvedNextMeetingMilestone = ContributionMilestonePolicy.resolvedNextMilestone(
            storedNextMilestone: config.contributionPromptNextMeetingCount,
            totalMeetings: totalMeetings,
            githubStarClicked: config.contributionGitHubStarClicked,
            buyMeCoffeeClicked: config.contributionBuyMeCoffeeClicked
        )

        if config.contributionPromptNextMeetingCount != resolvedNextMeetingMilestone {
            config.contributionPromptNextMeetingCount = resolvedNextMeetingMilestone
            configStore.save(config)
        }

        appState.config = config
        appState.contributionMilestonePrompt = ContributionMilestonePolicy.prompt(
            totalMeetings: totalMeetings,
            nextMilestone: resolvedNextMeetingMilestone,
            githubStarClicked: config.contributionGitHubStarClicked,
            buyMeCoffeeClicked: config.contributionBuyMeCoffeeClicked,
            dismissedThisLaunch: contributionMilestonePromptDismissedThisLaunch
        )
    }

    func recordContributionMilestonePromptSeen() {
        guard let prompt = appState.contributionMilestonePrompt,
              contributionMilestonePromptSeenIDsThisLaunch.insert(prompt.id).inserted else { return }
        TelemetryDeck.signal("contribution_prompt_seen", parameters: [
            "kind": prompt.kind.rawValue,
            "count": "\(prompt.count)",
            "github_star_clicked": "\(config.contributionGitHubStarClicked)",
            "buy_me_coffee_clicked": "\(config.contributionBuyMeCoffeeClicked)",
        ])
    }

    func dismissContributionMilestonePrompt() {
        guard let prompt = appState.contributionMilestonePrompt else { return }
        contributionMilestonePromptDismissedThisLaunch = true
        appState.contributionMilestonePrompt = nil
        let nextMilestone = ContributionMilestonePolicy.nextMilestone(
            after: appState.meetingStats.totalMeetings
        )
        config.contributionPromptNextMeetingCount = nextMilestone
        configStore.save(config)
        appState.config = config
        TelemetryDeck.signal("contribution_prompt_dismissed", parameters: [
            "kind": prompt.kind.rawValue,
            "count": "\(prompt.count)",
        ])
    }

    func openContributionMilestoneAction(_ action: ContributionMilestoneAction) {
        guard let prompt = appState.contributionMilestonePrompt else { return }
        if let supportURL = action.supportURL {
            NSWorkspace.shared.open(supportURL)
        }
        // CTA clicks intentionally dismiss for this launch; any remaining CTA can reappear next launch.
        contributionMilestonePromptDismissedThisLaunch = true
        TelemetryDeck.signal("contribution_prompt_action_clicked", parameters: [
            "action": action.rawValue,
            "kind": prompt.kind.rawValue,
            "count": "\(prompt.count)",
        ])

        updateConfig { config in
            switch action {
            case .githubStar:
                config.contributionGitHubStarClicked = true
            case .buyMeCoffee:
                config.contributionBuyMeCoffeeClicked = true
            }
            if config.contributionGitHubStarClicked && config.contributionBuyMeCoffeeClicked {
                config.contributionPromptNextMeetingCount = nil
            }
        }
        refreshContributionMilestonePrompt(
            totalMeetings: appState.meetingStats.totalMeetings
        )
    }

    func openContributionSidebarShare(_ action: ContributionMilestoneAction) {
        updateConfig { config in
            switch action {
            case .githubStar, .buyMeCoffee:
                break
            }
        }
        refreshContributionMilestonePrompt(
            totalMeetings: appState.meetingStats.totalMeetings
        )
        TelemetryDeck.signal("contribution_sidebar_share_clicked", parameters: [
            "action": action.rawValue,
        ])
    }

    func selectMeetingInputDeviceUID(_ uid: String?) {
        updateConfig { $0.meetingInputDeviceUID = uid }
    }

    private func applyMeetingInputDevice(_ deviceID: AudioObjectID?) {
        preparingMeetingSession?.setPreferredMicrophoneInputDeviceID(deviceID)
        if activeMeetingSession !== preparingMeetingSession {
            activeMeetingSession?.setPreferredMicrophoneInputDeviceID(deviceID)
        }
    }

    func updateUpcomingMeetingsWindow(dayCount: Int) {
        let resolvedDayCount = UpcomingMeetingsWindow.resolve(dayCount: dayCount).dayCount
        guard config.upcomingMeetingsDayCount != resolvedDayCount else { return }

        updateConfig { $0.upcomingMeetingsDayCount = resolvedDayCount }
        Task {
            let refreshed = await refreshUpcomingCalendarEvents()
            guard refreshed else { return }
            checkUpcomingCalendarNotifications()
            meetingMonitor.refreshState(trigger: .calendarChanged)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let result = launchAtLoginCoordinator.setEnabled(enabled, config: config)
        if let error = result.error {
            fputs("[launch-at-login] failed to set enabled=\(enabled): \(error)\n", stderr)
        }
        appState.launchAtLoginRegistrationState = result.registrationState
        updateConfig { $0.launchAtLogin = result.config.launchAtLogin }
        if enabled, result.registrationState == .requiresApproval {
            launchAtLoginCoordinator.openSystemSettingsLoginItems()
        }
    }

    func openLaunchAtLoginSettings() {
        launchAtLoginCoordinator.openSystemSettingsLoginItems()
    }

    func refreshLaunchAtLoginState() {
        let result = launchAtLoginCoordinator.refreshStatus(config: config)
        appState.launchAtLoginRegistrationState = result.registrationState
        let refreshed = result.config
        guard refreshed.launchAtLogin != config.launchAtLogin else { return }
        updateConfig { $0.launchAtLogin = refreshed.launchAtLogin }
    }

    private func syncLaunchAtLoginConfigWithSystem() {
        let result = launchAtLoginCoordinator.reconcileOnStartup(config: config)
        if let error = result.error {
            fputs("[launch-at-login] failed to apply saved launch-at-login setting: \(error)\n", stderr)
        }
        appState.launchAtLoginRegistrationState = result.registrationState
        let reconciled = result.config
        guard reconciled.launchAtLogin != config.launchAtLogin else { return }
        updateConfig { $0.launchAtLogin = reconciled.launchAtLogin }
    }

    func selectBackend(_ option: BackendOption) {
        guard option.supportsMeetingTranscription else {
            presentErrorAlert(
                title: "Model unavailable",
                message: "\(option.label) cannot be used for meeting transcription."
            )
            return
        }
        updateConfig {
            $0.sttBackend = option.backend
            $0.sttModel = option.model
        }
        Task { [weak self] in
            guard let self else { return }
            // Push the selected Nemotron 3.5 language before preload so the loaded
            // transcriber is conditioned on the right prompt_id.
            await self.transcriptionCoordinator.setNemotron35PromptId(self.config.resolvedNemotron35Language.promptId)
            let needsWarmup = option.backend == "whisper"
            if needsWarmup {
                await MainActor.run {
                    self.indicator.showLoading("Warming up...")
                }
            }
            await self.transcriptionCoordinator.preload(
                backend: option,
                includeMeetingHelpers: self.config.resolvedOnboardingUseCase.includesMeetings,
                appleSpeechLanguage: self.config.resolvedAppleSpeechLanguage
            )
            await MainActor.run {
                if needsWarmup {
                    self.indicator.hideLoading()
                }
                self.statusBarController?.refresh()
                self.historyWindowController?.updateBackendLabel()
            }
        }
    }

    // MARK: - Transcription Languages

    func setNemotron35Language(_ language: Nemotron35Language) async {
        updateConfig { $0.nemotron35Language = language.rawValue }
        await transcriptionCoordinator.setNemotron35PromptId(language.promptId)
    }

    func selectMeetingTranscriptionBackend(_ option: BackendOption, requireDownloaded: Bool = true) {
        guard option.supportsMeetingTranscription else {
            presentErrorAlert(
                title: "Meeting model unavailable",
                message: "\(option.label) is optimized for dictation and cannot be used for meeting transcription."
            )
            normalizeMeetingTranscriptionSelectionForAvailability()
            return
        }
        guard !requireDownloaded || option.isDownloaded else {
            presentErrorAlert(
                title: "Meeting model unavailable",
                message: "Download \(option.label) before using it for meeting transcription."
            )
            normalizeMeetingTranscriptionSelectionForAvailability()
            return
        }
        if !requireDownloaded {
            config.meetingTranscriptionBackend = option.backend
            config.meetingTranscriptionModel = option.model
            configStore.save(config)
            selectedMeetingTranscriptionBackend = option
            appState.selectedMeetingTranscriptionBackend = option
            appState.config = config
            activeMeetingSession?.updateBackend(option)
            syncAppState()
            return
        }
        updateConfig {
            $0.meetingTranscriptionBackend = option.backend
            $0.meetingTranscriptionModel = option.model
        }
        activeMeetingSession?.updateBackend(option)
        Task { [weak self] in
            guard let self else { return }
            await self.transcriptionCoordinator.preload(
                backend: option,
                includeMeetingHelpers: true,
                appleSpeechLanguage: self.config.resolvedAppleSpeechLanguage
            )
            await MainActor.run {
                self.statusBarController?.refresh()
            }
        }
    }

    func selectCohereLanguage(_ language: CohereTranscribeLanguage) {
        updateConfig {
            $0.cohereLanguage = language.rawValue
        }
    }

    func selectQwen3AsrLanguage(_ language: Qwen3AsrLanguage) {
        updateConfig {
            $0.qwen3AsrLanguage = language.rawValue
        }
    }

    func selectParakeetLanguage(_ language: ParakeetLanguage) {
        updateConfig {
            $0.parakeetLanguage = language.rawValue
        }
    }

    func selectBodhanLanguage(_ language: BodhanLanguage) {
        updateConfig {
            $0.bodhanLanguage = language.rawValue
        }
    }

    func selectWhisperLanguage(_ language: WhisperKitLanguage) {
        updateConfig {
            $0.whisperLanguage = language.rawValue
        }
    }

    func selectAppleSpeechLanguage(_ identifier: String) {
        let normalized = AppleSpeechLanguageOption.normalize(identifier)
        guard normalized != config.resolvedAppleSpeechLanguage else { return }
        updateConfig { $0.appleSpeechLanguage = normalized }

        Task { [weak self] in
            guard let self else { return }
            await self.transcriptionCoordinator.unloadAppleSpeechTranscriber()
            let usesAppleSpeech = self.selectedBackend.backend == "apple-speech"
                || self.selectedMeetingTranscriptionBackend.backend == "apple-speech"
            guard usesAppleSpeech else { return }
            await self.transcriptionCoordinator.preload(
                backend: .appleSpeechAnalyzer,
                includeMeetingHelpers: false,
                appleSpeechLanguage: normalized
            )
        }
    }

    func setPostProcessorEnabled(_ enabled: Bool) {
        updateConfig {
            $0.enablePostProcessor = enabled
            if enabled && $0.activePostProcessorId.isEmpty {
                $0.activePostProcessorId = PostProcessorOption.defaultOption.id
            }
        }
    }

    func selectPostProcessorBackend(_ option: TranscriptCleanupBackendOption) {
        updateConfig {
            $0.postProcessorBackend = option.backend
        }
    }

    func selectPostProcessor(_ option: PostProcessorOption) {
        updateConfig {
            $0.activePostProcessorId = option.id
            if option.inputFormat == .s1Mini {
                $0.postProcessorSystemPrompt = PostProcessorOption.s1MiniSystemPrompt
            } else if $0.activeTranscriptCleanupPromptId == TranscriptCleanupPrompts.defaultID {
                $0.postProcessorSystemPrompt = PostProcessorOption.defaultSystemPrompt
            }
        }
    }

    /// Downloads a local GGUF cleanup model to its cache path. Progress is
    /// reported on the main actor via the callback.
    func downloadPostProcessorModel(
        _ option: PostProcessorOption,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let fileURL = option.modelURL
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let (tempURL, response) = try await URLSession.shared.download(from: option.downloadURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        // Streamed copy so progress is observable.
        let source = try FileHandle(forReadingFrom: tempURL)
        defer { try? source.close() }
        let total = (try? source.seekToEnd()) ?? 0
        try source.seek(toFileOffset: 0)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let destination = try FileHandle(forWritingTo: fileURL)
        defer { try? destination.close() }
        var downloaded: UInt64 = 0
        while true {
            let chunk = try source.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            try destination.write(contentsOf: chunk)
            downloaded += UInt64(chunk.count)
            if total > 0 {
                await MainActor.run { progress(min(Double(downloaded) / Double(total), 1.0)) }
            }
        }
        await MainActor.run { progress(1.0) }
    }

    func deletePostProcessorModel(_ option: PostProcessorOption) {
        try? FileManager.default.removeItem(at: option.modelURL)
        if config.activePostProcessorId == option.id {
            updateConfig { $0.activePostProcessorId = PostProcessorOption.defaultOption.id }
        }
    }

    func selectGemma4PostProcessor(_ model: Gemma4LiteRTModel) {
        updateConfig {
            $0.postProcessorGemmaModel = model.repoID
            $0.postProcessorBackend = TranscriptCleanupBackendOption.gemma4LiteRT.backend
        }
    }

    func selectTranscriptCleanupPrompt(id: String) {
        let preset = TranscriptCleanupPrompts.resolve(id: id, custom: config.customTranscriptCleanupPrompts)
        updateConfig {
            $0.activeTranscriptCleanupPromptId = preset.id
            $0.postProcessorSystemPrompt = preset.prompt
        }
    }

    func createTranscriptCleanupPrompt(name: String, prompt: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return }
        let preset = CustomTranscriptCleanupPrompt(name: trimmedName, prompt: trimmedPrompt)
        updateConfig {
            $0.customTranscriptCleanupPrompts.append(preset)
            $0.activeTranscriptCleanupPromptId = preset.id
            $0.postProcessorSystemPrompt = preset.prompt
        }
    }

    func updateTranscriptCleanupPrompt(id: String, name: String, prompt: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return }
        updateConfig {
            guard let index = $0.customTranscriptCleanupPrompts.firstIndex(where: { $0.id == id }) else { return }
            $0.customTranscriptCleanupPrompts[index].name = trimmedName
            $0.customTranscriptCleanupPrompts[index].prompt = trimmedPrompt
            if $0.activeTranscriptCleanupPromptId == id {
                $0.postProcessorSystemPrompt = trimmedPrompt
            }
        }
    }

    func deleteTranscriptCleanupPrompt(id: String) {
        updateConfig {
            $0.customTranscriptCleanupPrompts.removeAll { $0.id == id }
            if $0.activeTranscriptCleanupPromptId == id {
                $0.activeTranscriptCleanupPromptId = TranscriptCleanupPrompts.defaultID
                $0.postProcessorSystemPrompt = PostProcessorOption.defaultSystemPrompt
            }
        }
    }

    func selectMeetingSummaryBackend(_ option: MeetingSummaryBackendOption) {
        updateConfig {
            $0.meetingSummaryBackend = option.backend
        }
    }

    func availableMeetingTemplates() -> [MeetingTemplateDefinition] {
        MeetingTemplates.allDefinitions(customTemplates: config.customMeetingTemplates)
    }

    func builtInMeetingTemplates() -> [MeetingTemplateDefinition] {
        MeetingTemplates.builtIns
    }

    func customMeetingTemplates() -> [CustomMeetingTemplate] {
        config.customMeetingTemplates
    }

    func defaultMeetingTemplate() -> MeetingTemplateSnapshot {
        MeetingTemplates.resolveSnapshot(
            id: config.defaultMeetingTemplateID,
            customTemplates: config.customMeetingTemplates
        )
    }

    func meetingTemplateSnapshot(for meeting: MeetingRecord) -> MeetingTemplateSnapshot {
        MeetingTemplates.snapshot(
            for: meeting,
            customTemplates: config.customMeetingTemplates,
            defaultTemplateID: config.defaultMeetingTemplateID
        )
    }

    func updateDefaultMeetingTemplate(id: String) {
        let resolved = MeetingTemplates.resolveSnapshot(id: id, customTemplates: config.customMeetingTemplates)
        updateConfig {
            $0.defaultMeetingTemplateID = resolved.id
        }
    }

    func createCustomMeetingTemplate(name: String, prompt: String, icon: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return }
        updateConfig {
            $0.customMeetingTemplates.append(
                CustomMeetingTemplate(
                    name: trimmedName,
                    prompt: trimmedPrompt,
                    icon: MeetingTemplates.normalizedCustomIcon(named: icon)
                )
            )
        }
    }

    func updateCustomMeetingTemplate(id: String, name: String, prompt: String, icon: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return }
        updateConfig {
            guard let index = $0.customMeetingTemplates.firstIndex(where: { $0.id == id }) else { return }
            $0.customMeetingTemplates[index].name = trimmedName
            $0.customMeetingTemplates[index].prompt = trimmedPrompt
            $0.customMeetingTemplates[index].icon = MeetingTemplates.normalizedCustomIcon(named: icon)
        }
    }

    func deleteCustomMeetingTemplate(id: String) {
        updateConfig {
            $0.customMeetingTemplates.removeAll { $0.id == id }
            if $0.defaultMeetingTemplateID == id {
                $0.defaultMeetingTemplateID = MeetingTemplates.autoID
            }
        }
    }

    /// Returns nil on success, or an error message on failure.
    func signInWithChatGPT(selectMeetingSummaryBackend shouldSelectMeetingSummaryBackend: Bool = true) async -> String? {
        do {
            try await chatGPTAuth.signIn()
            if shouldSelectMeetingSummaryBackend {
                selectMeetingSummaryBackend(.chatGPT)
            }
            syncAppState()
            return nil
        } catch {
            fputs("[meets] ChatGPT sign-in failed: \(error)\n", stderr)
            return error.localizedDescription
        }
    }

    func signOutChatGPT() {
        chatGPTAuth.signOut()
        if selectedMeetingSummaryBackend == .chatGPT {
            selectMeetingSummaryBackend(.openAI)
        }
        syncAppState()
    }

    /// Returns nil on success, or an error message on failure.
    func signInWithOpenRouter(
        selectMeetingSummaryBackend shouldSelectMeetingSummaryBackend: Bool = true
    ) async -> String? {
        do {
            try await openRouterAuth.signIn()
            if shouldSelectMeetingSummaryBackend {
                selectMeetingSummaryBackend(.openRouter)
            }
            syncAppState()
            return nil
        } catch {
            fputs("[meets] OpenRouter sign-in failed: \(error.localizedDescription)\n", stderr)
            return error.localizedDescription
        }
    }

    /// Stores a legacy/manual OpenRouter key in the same protected credential
    /// file used by the browser sign-in flow.
    func storeManualOpenRouterAPIKey(
        _ apiKey: String,
        selectMeetingSummaryBackend shouldSelectMeetingSummaryBackend: Bool = true
    ) -> String? {
        do {
            try openRouterAuth.storeManualAPIKey(apiKey)
            if shouldSelectMeetingSummaryBackend {
                selectMeetingSummaryBackend(.openRouter)
            }
            syncAppState()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func signOutOpenRouter() -> String? {
        do {
            try openRouterAuth.signOut()
        } catch {
            syncAppState()
            return error.localizedDescription
        }

        guard !openRouterAuth.isAuthenticated else {
            syncAppState()
            return nil
        }

        if selectedMeetingSummaryBackend == .openRouter {
            // Match ChatGPT sign-out: move summaries to the existing API-key fallback.
            selectMeetingSummaryBackend(.openAI)
        }
        syncAppState()
        return nil
    }

    func manageOpenRouterKey() {
        guard let url = openRouterAuth.manageKeyURL else { return }
        NSWorkspace.shared.open(url)
    }

    func loadOpenRouterModels(_ scope: OpenRouterModelCatalogScope, force: Bool = false) {
        switch scope {
        case .text:
            guard force || (
                appState.openRouterSummaryModels.isEmpty
                    && appState.openRouterSummaryCatalogState == .idle
            ) else { return }
            guard openRouterSummaryCatalogTask == nil else { return }
            appState.openRouterSummaryCatalogState = .loading
            openRouterSummaryCatalogTask = Task { [weak self] in
                guard let self else { return }
                defer { self.openRouterSummaryCatalogTask = nil }
                do {
                    let models = try await self.openRouterModelCatalogClient.load(.text)
                    self.appState.openRouterSummaryModels = models
                    self.appState.openRouterSummaryCatalogState = models.isEmpty
                        ? .failed("No free text models found")
                        : .loaded
                } catch is CancellationError {
                    self.appState.openRouterSummaryCatalogState = .idle
                } catch {
                    self.appState.openRouterSummaryCatalogState = .failed("Could not load")
                }
            }
        }
    }

    // MARK: - Calendar Access & EventKit Calendars

    private var calendarEventKitManager: CalendarEventKitManager {
        .shared
    }

    /// Re-reads EventKit authorization into appState without prompting.
    /// Cheap and synchronous — safe to call from the Settings permission
    /// polling loop so the Calendar row stays current.
    func syncCalendarAuthorizationState() {
        appState.calendarAuthorization = calendarEventKitManager.authorizationState
    }

    /// Called from the onboarding calendar step after the user changes
    /// calendar access: re-sync authorization, restart the monitor, and pull
    /// the fresh calendar/account list and upcoming events.
    func calendarAccessDidChange() async {
        syncCalendarAuthorizationState()
        syncCalendarMonitor()
        await refreshCalendarAccess()
        _ = await refreshUpcomingCalendarEvents()
    }

    /// Re-reads EventKit authorization and the calendar/account list into
    /// appState. Prompts for full access ONLY when requestIfUndetermined is
    /// set (explicit Grant buttons); every passive call (startup, polling,
    /// sheet refreshes) syncs silently so the system dialog never ambushes
    /// the user outside the permissions step.
    func refreshCalendarAccess(requestIfUndetermined: Bool = false) async {
        let manager = calendarEventKitManager
        switch manager.authorizationState {
        case .unknown:
            guard requestIfUndetermined else {
                appState.calendarAuthorization = .unknown
                return
            }
            let granted = await manager.requestFullAccessToEvents()
            appState.calendarAuthorization = granted ? .fullAccess : .denied
            if granted {
                await refreshEventKitCalendars()
            }
        case .denied, .writeOnly, .fullAccess:
            appState.calendarAuthorization = manager.authorizationState
            if manager.canReadEvents {
                await refreshEventKitCalendars()
            }
        }
    }

    /// Refreshes `appState.eventKitCalendars` and `appState.calendarAccounts`
    /// from EventKit without blocking the main actor on the synchronous store
    /// enumeration. Snapshot happens on a utility thread; the manager's
    /// long-lived EKEventStore is intentionally NOT used there (EventKit
    /// stores are not thread-safe), so this enumerates via a fresh store.
    func refreshEventKitCalendars() async {
        let snapshot: (calendars: [EKCalendarModel], accounts: [EKAccountModel]) = await Task.detached(priority: .utility) {
            let store = EKEventStore()
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess
                || EKEventStore.authorizationStatus(for: .event) == .authorized else {
                return (calendars: [], accounts: [])
            }
            let calendars = store.calendars(for: .event)
            let accounts = Set(calendars.compactMap(\.source))
            return (
                calendars: calendars.map { EKCalendarModel.from($0, source: $0.source) },
                accounts: accounts.map(EKAccountModel.from)
            )
        }.value
        guard !Task.isCancelled else { return }
        appState.eventKitCalendars = snapshot.calendars
        appState.calendarAccounts = snapshot.accounts
    }

    /// Enables or disables a calendar for Meets (Coming Up, notifications,
    /// meeting detection) by persisting its EK calendar identifier in
    /// AppConfig.disabledCalendarIDs, then refreshes the event list.
    func setCalendarEnabled(id: String, enabled: Bool) {
        updateConfig { config in
            var disabled = Set(config.disabledCalendarIDs)
            if enabled {
                disabled.remove(id)
            } else {
                disabled.insert(id)
            }
            config.disabledCalendarIDs = disabled.sorted()
        }
        Task { await refreshUpcomingCalendarEvents() }
    }

    /// Deletes a calendar (and its events) from the user's Calendar. Refuses
    /// immutable/read-only calendars (Birthdays, subscriptions, Exchange or
    /// linked Internet Account calendars). Returns an error message when the
    /// deletion cannot be performed, nil on success.
    func deleteCalendar(id: String) async -> String? {
        let removed: String? = await Task.detached(priority: .userInitiated) {
            let store = EKEventStore()
            guard let calendar = store.calendar(withIdentifier: id) else {
                return "Could not find that calendar."
            }
            guard !calendar.isImmutable, calendar.allowsContentModifications else {
                return "macOS does not allow deleting this calendar. Remove it in Calendar or System Settings instead."
            }
            do {
                try store.removeCalendar(calendar, commit: true)
                return nil
            } catch {
                return "Could not delete the calendar: \(error.localizedDescription)"
            }
        }.value
        guard !Task.isCancelled else { return nil }
        if removed == nil {
            await refreshEventKitCalendars()
            await refreshCalendarEvents()
        }
        return removed
    }

    /// Opens System Settings > Internet Accounts, where users connect Google,
    /// Exchange, CalDAV, or iCloud accounts to macOS Calendar.
    func openSystemCalendarAccountSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Fetches calendar events for the past year and the coming year from
    /// EventKit into `appState.calendarEvents`, applying the currently
    /// disabled-calendar filter. All-day events are excluded (they are not
    /// useful for meeting recording). Populates `isCalendarPageLoading`
    /// around the fetch.
    func refreshCalendarEvents() async {
        appState.isCalendarPageLoading = true
        await fetchCalendarEventsIntoAppState()
        appState.isCalendarPageLoading = false
    }

    /// Fetches calendar events into `appState.calendarEvents` without toggling
    /// the page loading flag — used by background sync passes
    /// (`applyCalendarTitleSyncPass`) that must not flash the Calendar page's
    /// spinner on every EventKit change notification.
    func fetchCalendarEventsIntoAppState() async {
        let disabledIDs = Set(config.disabledCalendarIDs)
        let now = Date()
        let calendar = Calendar.current
        let pastStart = calendar.date(byAdding: .year, value: -1, to: now) ?? now
        let futureEnd = calendar.date(byAdding: .year, value: 1, to: now) ?? now
        let events: [UnifiedCalendarEvent] = await Task.detached(priority: .utility) { [disabledIDs] in
            let store = EKEventStore()
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess
                || EKEventStore.authorizationStatus(for: .event) == .authorized else { return [] }
            return Self.calendarEvents(store: store, from: pastStart, to: futureEnd, disabledIDs: disabledIDs)
        }.value
        guard !Task.isCancelled else { return }
        appState.calendarEvents = events
    }

    /// Enumerates EventKit events into UnifiedCalendarEvents on a background
    /// thread (static + nonisolated so the detached task does not touch
    /// MainActor-isolated state).
    private nonisolated static func calendarEvents(
        store: EKEventStore,
        from start: Date,
        to end: Date,
        disabledIDs: Set<String>
    ) -> [UnifiedCalendarEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        // All-day events are kept: the Add-to-Event picker and linkage need
        // them (many users' calendars are mostly all-day). Surfaces that
        // assume timed events filter them out themselves.
        let unified: [UnifiedCalendarEvent] = store.events(matching: predicate).compactMap { event -> UnifiedCalendarEvent? in
            guard let startDate = event.startDate, let endDate = event.endDate else { return nil }
            let eventID = event.eventIdentifier ?? UUID().uuidString
            return UnifiedCalendarEvent(
                id: eventID,
                title: event.title ?? "Meeting",
                startDate: startDate,
                endDate: endDate,
                isAllDay: event.isAllDay,
                source: .eventKit,
                calendarID: event.calendar?.calendarIdentifier,
                calendarOccurrence: CalendarMonitor.occurrenceReference(
                    for: event,
                    eventID: eventID,
                    startDate: startDate
                ),
                meetingURL: CalendarMonitor.extractMeetingURL(from: event),
                attendees: CalendarMonitor.attendees(from: event),
                location: event.location,
                isCancelled: event.status == .canceled,
                isDeclined: Self.isDeclined(event)
            )
        }
        return UnifiedCalendarEvent
            .filter(unified, disabledCalendarIDs: disabledIDs)
            .filter { $0.startDate < end && $0.endDate > start }
            .sorted { $0.startDate < $1.startDate }
    }

    /// True when the current user declined the event. Matches the current
    /// user's attendee entry (EKParticipant.isCurrentUser).
    private nonisolated static func isDeclined(_ event: EKEvent) -> Bool {
        guard let attendees = event.attendees, !attendees.isEmpty else { return false }
        for attendee in attendees where attendee.participantStatus == .declined {
            if attendee.isCurrentUser {
                return true
            }
            if let organizerURL = event.organizer?.url, attendee.url == organizerURL {
                return true
            }
        }
        return false
    }

    @discardableResult
    func refreshUpcomingCalendarEvents() async -> Bool {
        let refreshNow = Date()
        let refreshStartOfDay = Calendar.current.startOfDay(for: refreshNow)
        let disabledIDs = Set(config.disabledCalendarIDs)
        let dayCount = UpcomingMeetingsWindow.resolve(dayCount: config.upcomingMeetingsDayCount).dayCount
        let ekEvents = calendarMonitor.upcomingEvents(
            daysAhead: dayCount,
            disabledCalendarIDs: disabledIDs,
            now: refreshNow
        )
        var observedEventIDs = Set(ekEvents.map(\.id))
        let canConfirmMissingEventKitEvents = calendarMonitor.canConfirmMissingEvents

        let currentDisabledIDs = Set(config.disabledCalendarIDs)
        let currentDayCount = UpcomingMeetingsWindow.resolve(dayCount: config.upcomingMeetingsDayCount).dayCount
        let currentStartOfDay = Calendar.current.startOfDay(for: Date())
        guard dayCount == currentDayCount,
              disabledIDs == currentDisabledIDs,
              refreshStartOfDay == currentStartOfDay else {
            return false
        }

        appState.upcomingCalendarEvents = ekEvents

        // Prune hidden IDs only when the widest supported window still cannot see the event.
        observedEventIDs.formUnion(ekEvents.map(\.id))
        let sourceHints = config.hiddenCalendarEventSourceHints
        let canPruneHiddenEvents = disabledIDs.isEmpty
        let staleIDs = UpcomingMeetingsWindow.staleHiddenEventIDs(
            hiddenIDs: appState.hiddenCalendarEventIDs,
            visibleEventIDs: observedEventIDs,
            dayCount: dayCount,
            canConfirmMissingEvents: canPruneHiddenEvents && canConfirmMissingEventKitEvents,
            canConfirmMissingEventID: { eventID in
                guard canPruneHiddenEvents else { return false }
                // Legacy Google-sourced events cannot be confirmed missing
                // (the API is gone); EventKit-sourced ones can.
                switch sourceHints[eventID].flatMap(UnifiedCalendarEvent.CalendarSource.init(rawValue:)) {
                case .some(.eventKit):
                    return canConfirmMissingEventKitEvents
                case .some(.googleCalendar), .none:
                    return false
                }
            }
        )
        if !staleIDs.isEmpty {
            appState.hiddenCalendarEventIDs.subtract(staleIDs)
            updateConfig {
                $0.hiddenCalendarEventIDs = self.appState.hiddenCalendarEventIDs.sorted()
                $0.hiddenCalendarEventSourceHints = $0.hiddenCalendarEventSourceHints.filter {
                    !staleIDs.contains($0.key)
                }
            }
        }

        statusBarController?.updateMenuBarTitle()
        return true
    }

    /// Reconciles only EventKit-backed meetings that have not started. This is
    /// called from EKEventStoreChangedNotification, so participant freshness
    /// remains event-driven.
    func reconcilePendingEventKitCalendarAttendees(
        events: [UnifiedCalendarEvent],
        now: Date = Date()
    ) async {
        let snapshots = events.compactMap { event -> CalendarParticipantReconciliationSnapshot? in
            guard event.source == .eventKit, event.startDate > now else { return nil }
            return CalendarParticipantReconciliationSnapshot(
                occurrence: event.resolvedCalendarOccurrence,
                startDate: event.startDate,
                participants: event.attendees.map(\.participantDraft)
            )
        }
        guard !snapshots.isEmpty else { return }

        let databaseURL = dictationStore.resolvedDatabaseURL
        let matches = await Task.detached(priority: .utility) {
            let store = DictationStore(databaseURL: databaseURL)
            return snapshots.compactMap { snapshot -> (Int64, [MeetingParticipantDraft])? in
                guard snapshot.startDate > now,
                      let meeting = try? store.meetingByCalendarOccurrence(snapshot.occurrence),
                      meeting.status != .recording,
                      meeting.status != .processing else {
                    return nil
                }
                return (meeting.id, snapshot.participants)
            }
        }.value

        let activeMeetingIDs = Set([activeMeetingID, meetingStartMeetingID].compactMap { $0 })
        for (meetingID, participants) in matches where !activeMeetingIDs.contains(meetingID) {
            persistCalendarParticipants(participants, meetingID: meetingID, mode: .reconcile)
        }
    }

    func startCalendarMonitoring() {
        // Event-driven: refresh when macOS reports calendar changes.
        // EKEventStoreChangedNotification is delivered via NotificationCenter,
        // which is immune to App Nap timer suspension in LSUIElement apps.
        calendarMonitor.onCalendarChanged = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshEventKitCalendars()
                let refreshed = await self.refreshUpcomingCalendarEvents()
                guard refreshed else { return }
                await self.reconcilePendingEventKitCalendarAttendees(
                    events: self.appState.upcomingCalendarEvents
                )
                self.checkUpcomingCalendarNotifications()
                self.meetingMonitor.refreshState(trigger: .calendarChanged)
                // Calendar title edits propagate to linked meeting titles.
                // Coalesced + idempotent; cheap when nothing changed.
                _ = await self.handleCalendarEventChange()
            }
        }

        // 60s fallback timer: re-checks EventKit and fires time-based
        // notification triggers. EKEventStoreChangedNotification is the
        // primary reactive path; this timer covers cases the notification
        // misses (e.g. App Nap suspension windows on older macOS).
        calendarCheckTimer?.invalidate()
        calendarCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.calendarMonitor.start()
                await self.refreshEventKitCalendars()
                let refreshed = await self.refreshUpcomingCalendarEvents()
                guard refreshed else { return }
                self.checkUpcomingCalendarNotifications()
                self.meetingMonitor.refreshState(trigger: .calendarChanged)
            }
        }

        // Run one initial reconciliation so changes made while Meets was not
        // running are reflected without waiting for another EventKit change.
        Task { @MainActor in
            await self.refreshEventKitCalendars()
            let refreshed = await self.refreshUpcomingCalendarEvents()
            guard refreshed else { return }
            await self.reconcilePendingEventKitCalendarAttendees(
                events: self.appState.upcomingCalendarEvents
            )
            self.checkUpcomingCalendarNotifications()
            self.meetingMonitor.refreshState(trigger: .calendarChanged)
        }
    }

    private func syncCalendarMonitor() {
        let shouldRun = meetingFeatureMonitorsAllowed && shouldRunCalendarMonitor
        if shouldRun && !calendarMonitoringStarted {
            calendarMonitor.start()
            startCalendarMonitoring()
            calendarMonitoringStarted = true
        } else if !shouldRun && calendarMonitoringStarted {
            calendarMonitor.stop()
            calendarCheckTimer?.invalidate()
            calendarCheckTimer = nil
            calendarMonitoringStarted = false
        }
    }

    private func currentOrNearbyCachedCalendarEvent() -> CalendarEventContext? {
        selectCurrentOrNearbyCachedCalendarEvent(from: appState.upcomingCalendarEvents)
    }

    private func startMeetingFeatureMonitors(includeMaraudersMap: Bool) {
        if includeMaraudersMap, config.maraudersMapUnlocked {
            startMaraudersMapMonitoring()
        }
        syncMeetingDetectionMonitor()
    }

    private var shouldRunMeetingFeatureMonitors: Bool {
        config.showMeetingDetectionNotification
            || config.showScheduledMeetingNotifications
            || config.autoRecordMeetings
    }

    private var shouldRunCalendarMonitor: Bool {
        config.resolvedOnboardingUseCase.includesMeetings || shouldRunMeetingFeatureMonitors
    }

    /// Parses the persisted "bundleID|Display Name" entries into a lookup
    /// table for the meeting detector.
    func customMeetingDetectionAppTable() -> [String: String] {
        var table: [String: String] = [:]
        for entry in config.customMeetingDetectionApps {
            let parts = entry.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let bundleID = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            let name = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : bundleID
            guard !bundleID.isEmpty else { continue }
            table[bundleID] = name.isEmpty ? bundleID : name
        }
        return table
    }

    /// Adds or replaces a custom meeting app entry; removes when `name` is empty.
    func setCustomMeetingApp(bundleID: String, name: String) {
        let trimmedID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return }
        var entries = config.customMeetingDetectionApps.filter {
            !$0.hasPrefix(trimmedID + "|") && $0 != trimmedID
        }
        if !trimmedName.isEmpty {
            entries.append("\(trimmedID)|\(trimmedName)")
        }
        updateConfig { $0.customMeetingDetectionApps = entries.sorted() }
    }

    private func syncMeetingDetectionMonitor() {
        let shouldRun = meetingFeatureMonitorsAllowed
            && (config.showMeetingDetectionNotification || activeMeetingAutoStop.isArmed)
        if shouldRun && !meetingDetectionMonitorStarted {
            meetingMonitor.start()
            meetingDetectionMonitorStarted = true
        } else if !shouldRun && meetingDetectionMonitorStarted {
            meetingMonitor.stop()
            meetingDetectionMonitorStarted = false
            dismissPresentedMeetingDetection()
        }
    }

    /// Check all upcoming calendar events (EventKit) for events entering the configured prompt window.
    /// With a pre-start lead time, shows a notification when the event enters that window and schedules a second
    /// "Meeting starting now" notification at event start time. With the default start-time policy, waits until
    /// the event has started so calendar prompts do not fire before the user is expected to join.
    /// This is the single notification path for all calendar sources.
    /// Composite dedup key: same event rescheduled to a new time gets a fresh notification.
    private func notificationKey(id: String, startDate: Date) -> String {
        "\(id)|\(Int(startDate.timeIntervalSince1970))"
    }

    private func checkUpcomingCalendarNotifications() {
        guard !isMeetingRecording(),
              !isStartingMeetingRecording else { return }

        let now = Date()
        let leadTime = config.scheduledMeetingNotificationLeadTime.seconds

        // Prune stale entries (events that started more than 1 hour ago)
        let cutoff = now.addingTimeInterval(-3600)
        notifiedUpcomingEventIDs = notifiedUpcomingEventIDs.filter { key in
            guard let tsString = key.split(separator: "|").last,
                  let ts = TimeInterval(tsString) else { return false }
            return Date(timeIntervalSince1970: ts) > cutoff
        }
        autoRecordedCalendarEventIDs = autoRecordedCalendarEventIDs.filter { key in
            guard let tsString = key.split(separator: "|").last,
                  let ts = TimeInterval(tsString) else { return false }
            return Date(timeIntervalSince1970: ts) > cutoff
        }

        if config.autoRecordMeetings {
            let autoRecordCandidates = ScheduledMeetingNotificationPolicy.autoRecordCandidates(
                from: appState.upcomingCalendarEvents,
                now: now,
                hiddenEventIDs: appState.hiddenCalendarEventIDs
            )
            for event in autoRecordCandidates {
                let key = notificationKey(id: event.id, startDate: event.startDate)
                guard !autoRecordedCalendarEventIDs.contains(key) else { continue }
                autoRecordedCalendarEventIDs.insert(key)

                startMeetingRecording(
                    title: event.title,
                    calendarOccurrence: event.resolvedCalendarOccurrence,
                    openDocument: false,
                    endDate: event.endDate,
                    autoStopSource: event.meetingURL.flatMap { MeetingAutoStopSource(meetingURL: $0) },
                    startOrigin: .calendarAutoRecord
                )
                return
            }
        }

        guard config.showScheduledMeetingNotifications else { return }

        let notificationCandidates = ScheduledMeetingNotificationPolicy.upcomingCandidates(
            from: appState.upcomingCalendarEvents,
            now: now,
            hiddenEventIDs: appState.hiddenCalendarEventIDs,
            leadTime: leadTime
        )
        for event in notificationCandidates {
            let key = notificationKey(id: event.id, startDate: event.startDate)
            guard !notifiedUpcomingEventIDs.contains(key) else { continue }

            notifiedUpcomingEventIDs.insert(key)

            let upcomingEvent = UpcomingMeetingEvent(
                id: event.id,
                title: event.title,
                startDate: event.startDate,
                calendarOccurrence: event.resolvedCalendarOccurrence,
                meetingURL: event.meetingURL
            )

            // Show "starts in X min" notification now
            handleUpcomingMeeting(upcomingEvent)

            // Schedule a second "Meeting starting now" notification at event start time for pre-start prompts.
            let delay = event.startDate.timeIntervalSinceNow
            if leadTime > 0, delay > 15 { // Only if there's enough gap after the first notification auto-dismisses
                let eventID = event.id
                let startDate = event.startDate
                meetingStartingNowTimers[key]?.invalidate()
                meetingStartingNowTimers[key] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.meetingStartingNowTimers.removeValue(forKey: key)
                        guard !self.isMeetingRecording(),
                              let event = ScheduledMeetingNotificationPolicy.startingNowCandidate(
                                from: self.appState.upcomingCalendarEvents,
                                eventID: eventID,
                                startDate: startDate,
                                hiddenEventIDs: self.appState.hiddenCalendarEventIDs
                              ) else { return }
                        self.showMeetingStartingNowNotification(
                            title: event.title,
                            calendarOccurrence: event.resolvedCalendarOccurrence,
                            meetingURL: event.meetingURL,
                            endDate: event.endDate
                        )
                    }
                }
            }

            return // Show one notification at a time
        }
    }

    /// Show a "Meeting starting now" notification — independent of Marauder's Map.
    private func showMeetingStartingNowNotification(
        title: String,
        calendarOccurrence: CalendarOccurrenceReference?,
        meetingURL: URL?,
        endDate: Date?
    ) {
        guard ScheduledMeetingNotificationPolicy.shouldShowStartingNowPrompt(meetingURL: meetingURL),
              config.showScheduledMeetingNotifications,
              !isMeetingRecording(),
              !isStartingMeetingRecording else { return }
        isShowingCalendarNotification = true

        meetingNotification.show(
            title: "Meeting starting now",
            subtitle: title,
            meetingURL: meetingURL,
            dismissAfter: 30,
            defaultAction: config.meetingJoinDefaultAction,
            onStartRecording: { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                self.recordOnly(
                    title: title,
                    meetingURL: meetingURL,
                    endDate: endDate,
                    calendarOccurrence: calendarOccurrence,
                    presentation: .backgroundPill
                )
            },
            onJoinAndRecord: meetingURL != nil ? { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                self.joinAndRecord(
                    title: title,
                    meetingURL: meetingURL!,
                    endDate: endDate,
                    calendarOccurrence: calendarOccurrence,
                    presentation: .backgroundPill
                )
            } : nil,
            onJoinOnly: meetingURL != nil ? { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                self.joinOnly(meetingURL: meetingURL!, endDate: endDate)
            } : nil,
            onDismiss: { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                let remaining = endDate.map { max($0.timeIntervalSinceNow, 120) } ?? 120
                self.meetingMonitor.suppress(for: remaining)
                self.meetingMonitor.refreshState()
            },
            onClose: { [weak self] in
                self?.isShowingCalendarNotification = false
                self?.showPendingMeetingCompletionNotificationIfPossible()
            }
        )
    }

    @discardableResult
    func updateMeetingRecordingHotkey(_ hotkey: HotkeyConfig) -> ShortcutHotkeyUpdateResult {
        let result = ShortcutHotkeyPolicy.validateMeetingRecordingHotkey(hotkey)
        guard result.didUpdate else {
            fputs("[hotkeys] rejected meeting recording hotkey due to conflict\n", stderr)
            return result
        }
        updateConfig { $0.meetingRecordingHotkey = hotkey }
        meetingRecordingHotkeyMonitor.configure(hotkey)
        return result
    }

    @discardableResult
    func updateMeetingRecordingHotkeyEnabled(_ enabled: Bool) -> ShortcutHotkeyUpdateResult {
        if enabled {
            let result = ShortcutHotkeyPolicy.validateMeetingRecordingHotkey(config.meetingRecordingHotkey)
            guard result.didUpdate else { return result }
            updateConfig { $0.enableMeetingRecordingHotkey = true }
            startMeetingRecordingHotkeyMonitorIfNeeded()
            return result
        } else {
            updateConfig { $0.enableMeetingRecordingHotkey = false }
            meetingRecordingHotkeyMonitor.stop()
            return .updated
        }
    }

    func showOnboarding(resumeFrom progress: OnboardingProgress? = nil) {
        let wc = OnboardingWindowController(controller: self, resumeProgress: progress)
        self.onboardingWindowController = wc
        wc.show()
    }

    @MainActor
    func bringOnboardingToFront() {
        onboardingWindowController?.bringToFront()
    }

    @MainActor
    func yieldOnboardingFocusToSystemSettings(using behavior: OnboardingSystemSettingsYieldBehavior) {
        onboardingWindowController?.yieldFocusToSystemSettings(using: behavior)
    }

    @MainActor
    func beginSystemPermissionGuide(for permission: PermissionDragGuidePermission) {
        systemPermissionGuideController.showWhenSystemSettingsIsAvailable(for: permission)
    }

    @MainActor
    func dismissSystemPermissionGuide() {
        systemPermissionGuideController.dismiss()
    }

    @MainActor
    func prepareOnboardingForNativePermissionPrompt() {
        onboardingWindowController?.prepareForNativePermissionPrompt()
    }

    func continueModelPreparationAfterOnboarding(
        _ backend: BackendOption,
        onboardingUseCase: OnboardingUseCase,
        initialProgress: Double?,
        initialStatus: String?,
        isPreparing: Bool
    ) {
        onboardingModelPreparationTask?.cancel()
        updateModelPreparationStatus(
            title: "Preparing \(backend.label)",
            detail: initialStatus ?? "Preparing \(backend.label)...",
            progress: initialProgress,
            isPreparing: isPreparing
        )

        onboardingModelPreparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.downloadModelForOnboarding(
                    backend,
                    onboardingUseCase: onboardingUseCase
                ) { progress, status in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.applyModelPreparationProgress(
                            progress,
                            status: status,
                            backend: backend
                        )
                    }
                }
                await MainActor.run {
                    self.onboardingModelPreparationTask = nil
                    self.clearModelPreparationStatus()
                    SoundController.playModelReady(enabled: self.config.soundEnabled)
                    self.statusBarController?.refresh()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.onboardingModelPreparationTask = nil
                }
            } catch {
                await MainActor.run {
                    self.onboardingModelPreparationTask = nil
                    self.updateModelPreparationStatus(
                        title: backend.isDownloaded ? "Model setup paused" : "Download paused",
                        detail: self.modelPreparationFailureMessage(for: backend),
                        progress: nil,
                        isPreparing: false
                    )
                }
                fputs("[meets] post-onboarding model preparation failed: \(error)\n", stderr)
            }
        }
    }

    func relaunchApp() {
        let bundlePath = Bundle.main.bundleURL.path
        // Defer to next run-loop to escape any SwiftUI animation context
        DispatchQueue.main.async {
            // Launch a detached process that waits for us to die, then reopens the app.
            // Uses /bin/sh only for the sleep; the path is passed as a positional arg
            // to avoid shell interpolation of special characters.
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-c", "sleep 1; open -- \"$1\"", "--", bundlePath]
            do {
                try shell.run()
            } catch {
                fputs("[meets] relaunch failed: \(error)\n", stderr)
            }
            // Use exit(0) instead of NSApp.terminate(nil) — terminate can be
            // blocked by SwiftUI animation contexts or applicationShouldTerminate,
            // leaving the old process alive with stale floating indicator and
            // status bar icon.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                exit(0)
            }
        }
    }

    // MARK: - Dictation Test Mode (onboarding)

    /// When set, handleStop routes transcribed text to this callback instead of pasting.
    /// Lifecycle sounds are suppressed, while the floating indicator stays live so
    /// onboarding exercises the same recording feedback as normal dictation.
    func downloadModelForOnboarding(
        _ backend: BackendOption,
        onboardingUseCase: OnboardingUseCase,
        progress: @escaping (Double, String?) -> Void,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        let wasDownloaded = backend.isDownloaded
        progress(
            wasDownloaded ? 0.75 : 0.0,
            wasDownloaded ? "Warming up \(backend.label)..." : "Downloading \(backend.label)..."
        )
        try await transcriptionCoordinator.preloadRequired(
            backend: backend,
            includeMeetingHelpers: onboardingUseCase.includesMeetings,
            meetingHelperTrigger: .onboarding,
            appleSpeechLanguage: config.resolvedAppleSpeechLanguage,
            progress: { value, status in
                if wasDownloaded,
                   value < 0.85,
                   status?.localizedCaseInsensitiveContains("preparing") == true {
                    return
                }
                if status?.localizedCaseInsensitiveContains("download") == true {
                    progress(value, "\(status ?? "Downloading \(backend.label)...")")
                } else if value >= 0.9 {
                    progress(value, status ?? "Warming up \(backend.label)...")
                } else {
                    progress(value, status ?? "Preparing \(backend.label)...")
                }
            },
            progressSnapshot: progressSnapshot
        )
        guard backend.isDownloaded else {
            throw NSError(
                domain: "MeetsOnboardingModelDownload",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(backend.label) was not downloaded successfully."]
            )
        }
        progress(1.0, "\(backend.label) ready")
    }

    private func applyModelPreparationProgress(_ progress: Double, status: String?, backend: BackendOption) {
        let detail = status ?? "Preparing \(backend.label)..."
        let lowercasedDetail = detail.lowercased()
        let isPreparing = lowercasedDetail.contains("compiling")
            || lowercasedDetail.contains("warming")
            || lowercasedDetail.contains("readying")

        if isPreparing {
            updateModelPreparationStatus(
                title: "Preparing \(backend.label)",
                detail: "Optimizing \(backend.label) for this Mac...",
                progress: nil,
                isPreparing: true
            )
            return
        }

        updateModelPreparationStatus(
            title: "Preparing \(backend.label)",
            detail: detail,
            progress: progress,
            isPreparing: false
        )
    }

    private func updateModelPreparationStatus(
        title: String,
        detail: String?,
        progress: Double?,
        isPreparing: Bool
    ) {
        appState.modelPreparationTitle = title
        appState.modelPreparationDetail = detail
        appState.modelPreparationProgress = progress.map { min(max($0, 0), 1) }
        appState.isModelPreparingAfterDownload = isPreparing
        if !isPreparing && progress == nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(12))
                guard appState.modelPreparationTitle == title,
                      appState.modelPreparationProgress == nil,
                      !appState.isModelPreparingAfterDownload else { return }
                appState.modelPreparationTitle = nil
                appState.modelPreparationDetail = nil
            }
        }
    }

    /// A finished preparation shows nothing: the sidebar card only reports work
    /// that is still in flight, so completion clears it.
    private func clearModelPreparationStatus() {
        appState.modelPreparationTitle = nil
        appState.modelPreparationDetail = nil
        appState.modelPreparationProgress = nil
        appState.isModelPreparingAfterDownload = false
    }

    private func modelPreparationFailureMessage(for backend: BackendOption) -> String {
        backend.isDownloaded
            ? "Model setup failed. Restart Meets or retry from Models."
            : "Download failed. Check your connection and retry."
    }

    func completeOnboarding(
        userName: String,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage,
        hotkey: HotkeyConfig,
        onboardingUseCase: OnboardingUseCase,
        summaryBackend: MeetingSummaryBackendOption?,
        apiKey: String?
    ) {
        var shouldRetainLegacyOpenRouterKey = false
        if summaryBackend == .openRouter,
           let apiKey,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            shouldRetainLegacyOpenRouterKey = storeManualOpenRouterAPIKey(
                apiKey,
                selectMeetingSummaryBackend: false
            ) != nil
        }
        updateConfig { config in
            config.hasCompletedOnboarding = true
            config.userName = userName
            config.sttBackend = backend.backend
            config.sttModel = backend.model
            config.cohereLanguage = cohereLanguage.rawValue
            config.meetingTranscriptionBackend = backend.backend
            config.meetingTranscriptionModel = backend.model
            config.meetingRecordingHotkey = hotkey
            config.enableMeetingRecordingHotkey = true
            config.onboardingUseCase = onboardingUseCase.rawValue
            if let summaryBackend {
                config.meetingSummaryBackend = summaryBackend.backend
            }
            if let apiKey, !apiKey.isEmpty {
                if summaryBackend == .openAI {
                    config.openAIAPIKey = apiKey
                } else if summaryBackend == .openRouter,
                          shouldRetainLegacyOpenRouterKey {
                    // ConfigStore retries the migration and preserves this
                    // fallback if protected credential storage remains unavailable.
                    config.openRouterAPIKey = apiKey
                }
            }
        }
        selectBackend(backend)
        startMeetingRecordingHotkeyMonitorIfNeeded()

        systemPermissionGuideController.dismiss()
        onboardingWindowController?.close()
        onboardingWindowController = nil
        if hasRequiredStartupPermissions(for: onboardingUseCase) {
            meetingFeatureMonitorsAllowed = true
            syncCalendarMonitor()
            // Start monitors that were deferred during onboarding
            if shouldRunMeetingFeatureMonitors {
                startMeetingFeatureMonitors(includeMaraudersMap: false)
            }
            TelemetryDeck.signal("onboarding.completed", parameters: [
                "use_case": onboardingUseCase.rawValue,
                "voice_notes_selected": onboardingUseCase.includesVoiceNotes ? "true" : "false",
                "dictation_selected": onboardingUseCase.includesDictation ? "true" : "false",
                "meetings_selected": onboardingUseCase.includesMeetings ? "true" : "false",
                "microphone_granted": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "true" : "false",
                "accessibility_granted": AXIsProcessTrusted() ? "true" : "false",
                "input_monitoring_granted": CGPreflightListenEventAccess() ? "true" : "false",
            ])
            let completionTab = OnboardingFlow.completionTab(for: onboardingUseCase)
            openHistoryWindow(tab: completionTab)
        } else {
            openHistoryWindow(tab: OnboardingFlow.completionTab(for: onboardingUseCase))
        }
    }

    @objc func openHistoryWindow() {
        showActiveMeetingDocumentIfNeeded()
        presentHistoryWindow()
    }

    private func presentHistoryWindow(whenReady readyAction: (() -> Void)? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.historyWindowController?.show(whenReady: readyAction)
        }
    }

    func openHistoryWindow(tab: DashboardTab) {
        presentHistoryWindow(tab: tab)
    }

    private func presentHistoryWindow(
        tab: DashboardTab,
        presentation: DashboardWindowPresentation = .restored
    ) {
        appState.selectedTab = tab
        syncAppState()
        DispatchQueue.main.async { [weak self] in
            self?.historyWindowController?.show(presentation: presentation)
        }
    }

    private func hasRequiredStartupPermissions(for useCase: OnboardingUseCase) -> Bool {
        OnboardingPermissionGate.hasRequiredPermissions(
            OnboardingPermissionSnapshot(
                microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                accessibility: AXIsProcessTrusted(),
                inputMonitoring: CGPreflightListenEventAccess(),
                systemAudio: false,
                screenRecording: false
            ),
            for: useCase
        )
    }

    func showMeetingsHome(folderID: Int64? = nil) {
        appState.selectedTab = .meetings
        appState.selectedFolderID = folderID
        appState.meetingsNavigationState = .browser
        syncAppState()
    }

    func showMeetingDocument(id: Int64) {
        guard let record = meeting(id: id) else { return }
        appState.selectedMeetingID = id
        appState.selectedMeetingRecord = record
        appState.meetingsNavigationState = .document(id)
        appState.selectedTab = .meetings
        presentHistoryWindow()
    }

    private func showActiveMeetingDocumentIfNeeded() {
        guard let activeMeetingID,
              isMeetingRecording() || isStartingMeetingRecording else {
            return
        }
        showMeetingDocument(id: activeMeetingID)
    }

    func openActiveMeetingNotes() {
        guard let activeMeetingID,
              isMeetingRecording() || isStartingMeetingRecording else { return }
        showMeetingDocument(id: activeMeetingID)
        appState.meetingNotesFocusRequest &+= 1
        presentHistoryWindow()
    }

    /// Requests Apple notification authorization if never asked. Called when
    /// either notification toggle flips on; show() backstops it anyway.
    func ensureMeetingNotificationAuth() {
        meetingNotification.ensureNotificationAuthorization()
    }

    /// Opens the templates manager as a sheet over whatever is showing
    /// (Settings, Meetings, an open meeting). Previously this forced the
    /// Meetings tab first because the sheet was hosted there.
    func showMeetingTemplatesManager() {
        appState.isMeetingTemplatesManagerPresented = true
    }

    @objc func openPreferences() {
        openHistoryWindow(tab: .settings)
    }

    @objc func openSettingsTab() {
        openHistoryWindow(tab: .settings)
    }

    @objc func focusSearchField() {
        presentHistoryWindow()
        DispatchQueue.main.async { [weak self] in
            self?.appState.focusSearchField = true
        }
    }

    @objc func checkForUpdates() {
        presentStandardUpdateCheck()
    }

    private func presentStandardUpdateCheck() {
        guard let updaterController else {
            appState.sparkleUpdateStatus = .disabled(message: "Update checks are disabled for this build.")
            return
        }
        let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        activateApplicationForSparkle()
        // Always enter Sparkle's standard path. Sparkle uses this same call to
        // refocus existing updater UI, so local availability gates would make
        // in-app buttons less reliable than the status-bar action.
        updaterController.checkForUpdates(nil)
        focusUpdaterWindowsCreatedAfterUpdateAction(excluding: existingWindows)
    }

    private func focusUpdaterWindowsCreatedAfterUpdateAction(excluding existingWindows: Set<ObjectIdentifier>) {
        for delay in [80_000_000, 240_000_000, 600_000_000, 1_200_000_000, 2_500_000_000] {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay))
                self?.focusUpdaterWindows(excluding: existingWindows)
            }
        }
    }

    private func focusUpdaterWindows(excluding existingWindows: Set<ObjectIdentifier>) {
        let updaterWindows = NSApplication.shared.windows.filter { window in
            guard window.isVisible else { return false }
            return !existingWindows.contains(ObjectIdentifier(window)) && isLikelyUpdaterWindow(window)
        }
        guard !updaterWindows.isEmpty else { return }

        activateApplicationForSparkle()
        for window in updaterWindows {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func isLikelyUpdaterWindow(_ window: NSWindow) -> Bool {
        let className = String(describing: type(of: window))
        if className.localizedCaseInsensitiveContains("SPU") ||
            className.localizedCaseInsensitiveContains("SU") ||
            className.localizedCaseInsensitiveContains("Sparkle") {
            return true
        }

        // Sparkle's standard UI can present through AppKit alert/window
        // classes. Keep this semantic fallback narrow and only apply it to
        // windows created after the update action.
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        if title.localizedCaseInsensitiveContains("update") ||
            title.localizedCaseInsensitiveContains("updater") ||
            title.localizedCaseInsensitiveContains("new version") ||
            title.localizedCaseInsensitiveContains("available") {
            return true
        }
        return false
    }

    private func showBusyStatus(_ message: String, restoring previousStatus: SparkleUpdateStatus) {
        busyStatusGeneration += 1
        let generation = busyStatusGeneration
        let restoreStatus = nonBusyStatus(previousStatus)
        appState.sparkleUpdateStatus = .busy(message: message)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.busyStatusGeneration == generation else { return }
            guard case .busy = self.appState.sparkleUpdateStatus else { return }
            self.appState.sparkleUpdateStatus = restoreStatus
        }
    }

    private func nonBusyStatus(_ status: SparkleUpdateStatus) -> SparkleUpdateStatus {
        if case .busy = status {
            return .idle
        }
        return status
    }

    @MainActor
    private func activateApplicationForSparkle() {
        // Sparkle UI is opened from an LSUIElement menu-bar app. This is a
        // user-initiated update action, so use strong activation even though
        // AppKit deprecated the argumented API on macOS 14.
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc func copyRecentMeeting(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String {
            copyToClipboard(text)
        }
    }

    @objc func selectMeetingSummaryBackendFromMenu(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String,
              let option = MeetingSummaryBackendOption.all.first(where: { $0.label == label }) else { return }
        if option == .chatGPT, !chatGPTAuth.isAuthenticated {
            Task { await signInWithChatGPT() }
            return
        }
        selectMeetingSummaryBackend(option)
    }

    private func summaryParticipantNames(meetingID: Int64) async -> [String] {
        do {
            return try await meetingParticipants(meetingID: meetingID).map(\.displayName)
        } catch {
            fputs("[summary] failed to load participants for meeting \(meetingID): \(error.localizedDescription)\n", stderr)
            return []
        }
    }

    func canUseSummaryProvider(_ provider: MeetingSummaryBackendOption) -> Bool {
        switch provider {
        case .chatGPT: return appState.isChatGPTAuthenticated
        case .openAI: return !resolvedOpenAIAPIKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .openRouter:
            return appState.isOpenRouterAuthenticated || !config.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .ollama: return true
        case .lmStudio: return MeetingSummaryClient.lmStudioHasRequiredSettings(config: config)
        case .customLLM: return MeetingSummaryClient.customLLMHasRequiredSettings(config: config)
        case .acpAgent: return MeetingSummaryClient.acpAgentHasRequiredSettings(config: config)
        case .appleIntelligence: return AppleIntelligenceBackend.status.isAvailable
        default: return false
        }
    }

    private func resolvedOpenAIAPIKey() -> String {
        let configuredKey = config.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredKey.isEmpty { return configuredKey }
        let environmentKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return environmentKey
    }

    func resummarize(meeting: MeetingRecord, summaryConfig: AppConfig? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        let templateSnapshot = meetingTemplateSnapshot(for: meeting)
        resummarize(meeting: meeting, using: templateSnapshot, summaryConfig: summaryConfig, completion: completion)
    }

    func applyMeetingTemplate(id: String, to meeting: MeetingRecord, summaryConfig: AppConfig? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let templateSnapshot = MeetingTemplates.resolveExactSnapshot(
            id: id,
            customTemplates: config.customMeetingTemplates
        ) else {
            completion(.failure(MeetingTemplateSelectionError.templateNoLongerExists))
            return
        }
        resummarize(meeting: meeting, using: templateSnapshot, summaryConfig: summaryConfig, completion: completion)
    }

    func resummarize(meeting: MeetingRecord, completion: @escaping (Result<Void, Error>) -> Void) {
        let templateSnapshot = meetingTemplateSnapshot(for: meeting)
        resummarize(meeting: meeting, using: templateSnapshot, completion: completion)
    }

    func applyMeetingTemplate(id: String, to meeting: MeetingRecord, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let templateSnapshot = MeetingTemplates.resolveExactSnapshot(
            id: id,
            customTemplates: config.customMeetingTemplates
        ) else {
            completion(.failure(MeetingTemplateSelectionError.templateNoLongerExists))
            return
        }
        resummarize(meeting: meeting, using: templateSnapshot, completion: completion)
    }

    private func resummarize(
        meeting: MeetingRecord,
        using templateSnapshot: MeetingTemplateSnapshot,
        summaryConfig: AppConfig? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let effectiveSummaryConfig = summaryConfig ?? config
        Task { [weak self] in
            guard let self else { return }
            let plan = MeetingResummarizationPolicy.plan(for: meeting)
            let participantNames = await self.summaryParticipantNames(meetingID: meeting.id)
            do {
                let notes = try await MeetingSummaryClient.summarize(
                    transcript: meeting.rawTranscript,
                    meetingTitle: plan.promptTitle,
                    config: effectiveSummaryConfig,
                    template: templateSnapshot,
                    existingNotes: self.notesContextForResummary(meeting),
                    manualNotesToRetain: effectiveSummaryConfig.includeNotesInSummary ? meeting.manualNotes : nil,
                    participantNames: participantNames
                )
                try self.dictationStore.updateMeetingSummary(
                    id: meeting.id,
                    title: plan.persistedTitle,
                    formattedNotes: notes,
                    selectedTemplateID: templateSnapshot.id,
                    selectedTemplateName: templateSnapshot.name,
                    selectedTemplateKind: templateSnapshot.kind,
                    selectedTemplatePrompt: templateSnapshot.prompt
                )
                self.logLLMUsage(
                    kind: "summary",
                    backend: effectiveSummaryConfig.meetingSummaryBackend,
                    model: effectiveSummaryConfig.meetingSummaryModel,
                    status: "success",
                    characters: meeting.rawTranscript.count,
                    meetingID: meeting.id
                )
                await MainActor.run {
                    self.syncAppState()
                    self.historyWindowController?.reload()
                    completion(.success(()))
                }
            } catch {
                fputs("[meets] failed to generate or persist meeting summary: \(error)\n", stderr)
                self.logLLMUsage(
                    kind: "summary",
                    backend: effectiveSummaryConfig.meetingSummaryBackend,
                    model: effectiveSummaryConfig.meetingSummaryModel,
                    status: "failed",
                    characters: meeting.rawTranscript.count,
                    meetingID: meeting.id
                )
                await MainActor.run {
                    if error is MeetingSummaryError {
                        completion(.failure(error))
                    } else {
                        completion(.failure(MeetingSummaryPersistenceError.failedToSaveSummary(underlying: error)))
                    }
                }
            }
        }
    }

    func retranscribe(meeting: MeetingRecord, completion: @escaping (Result<Void, Error>) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else {
                completion(.failure(MeetingRetranscriptionError.controllerUnavailable))
                return
            }
            var didSetProcessing = false
            do {
                guard let savedRecordingPath = meeting.savedRecordingPath,
                      !savedRecordingPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MeetingRetranscriptionError.recordingUnavailable
                }
                let recordingURL = URL(fileURLWithPath: savedRecordingPath)
                guard FileManager.default.fileExists(atPath: recordingURL.path) else {
                    throw MeetingRetranscriptionError.recordingUnavailable
                }
                guard let backend = self.normalizeMeetingTranscriptionSelectionForAvailability() else {
                    throw MeetingRetranscriptionError.noDownloadedTranscriptionModel
                }

                try self.updateMeetingStatusAndScheduleSyncThrowing(id: meeting.id, status: .processing)
                didSetProcessing = true
                self.syncAppState()
                self.historyWindowController?.reload()

                try await self.transcriptionCoordinator.preloadRequired(
                    backend: backend,
                    includeMeetingHelpers: true,
                    meetingHelperTrigger: .retranscription,
                    appleSpeechLanguage: self.config.resolvedAppleSpeechLanguage
                )
                let transcription = try await self.transcriptionCoordinator.transcribeMeeting(
                    at: recordingURL,
                    backend: backend,
                    cohereLanguage: self.config.resolvedCohereLanguage,
                    bodhanLanguage: self.config.resolvedBodhanLanguage,
                    whisperLanguage: self.config.resolvedWhisperLanguage,
                    qwen3AsrLanguage: self.config.resolvedQwen3AsrLanguage,
                    parakeetLanguage: self.config.resolvedParakeetLanguage,
                    appleSpeechLanguage: self.config.resolvedAppleSpeechLanguage
                )
                let rawTranscript = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawTranscript.isEmpty else {
                    throw MeetingRetranscriptionError.emptyTranscript
                }

                let templateSnapshot = self.meetingTemplateSnapshot(for: meeting)
                let formattedNotes: String
                do {
                    formattedNotes = try await MeetingSummaryClient.summarize(
                        transcript: rawTranscript,
                        meetingTitle: meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Meeting" : meeting.title,
                        config: self.config,
                        template: templateSnapshot,
                        existingNotes: self.notesContextForResummary(meeting),
                        manualNotesToRetain: config.includeNotesInSummary ? meeting.manualNotes : nil
                    )
                    self.logLLMUsage(
                        kind: "summary",
                        backend: self.config.meetingSummaryBackend,
                        model: self.config.meetingSummaryModel,
                        status: "success",
                        characters: rawTranscript.count,
                        meetingID: meeting.id
                    )
                } catch {
                    fputs("[meets] re-transcription summary generation failed: \(error)\n", stderr)
                    self.logLLMUsage(
                        kind: "summary",
                        backend: self.config.meetingSummaryBackend,
                        model: self.config.meetingSummaryModel,
                        status: "failed",
                        characters: rawTranscript.count,
                        meetingID: meeting.id
                    )
                    formattedNotes = MeetingSummaryClient.summaryFailureNotes(
                        transcript: rawTranscript,
                        meetingTitle: meeting.title,
                        error: error,
                        manualNotes: config.includeNotesInSummary ? meeting.manualNotes : nil
                    )
                }

                do {
                    try self.dictationStore.updateMeetingTranscriptAndSummary(
                        id: meeting.id,
                        rawTranscript: rawTranscript,
                        formattedNotes: formattedNotes,
                        selectedTemplateID: templateSnapshot.id,
                        selectedTemplateName: templateSnapshot.name,
                        selectedTemplateKind: templateSnapshot.kind,
                        selectedTemplatePrompt: templateSnapshot.prompt
                    )
                } catch {
                    throw MeetingRetranscriptionError.failedToSave(underlying: error)
                }

                // No diarization runs on this path, so every word is unattributed.
                try? self.dictationStore.replaceTranscriptWords(
                    meetingID: meeting.id,
                    words: TranscriptWordTimingBuilder.tagged(transcription.words) { _ in "" }
                )

                self.syncAppState()
                self.historyWindowController?.reload()
                completion(.success(()))
            } catch {
                fputs("[meets] failed to re-transcribe meeting \(meeting.id): \(error)\n", stderr)
                if let status = Self.retranscriptionFailureStatus(
                    originalStatus: meeting.status,
                    didSetProcessing: didSetProcessing,
                    error: error
                ) {
                    self.updateMeetingStatusAndScheduleSync(id: meeting.id, status: status)
                }
                self.syncAppState()
                self.historyWindowController?.reload()
                completion(.failure(error))
            }
        }
    }

    static func retranscriptionFailureStatus(
        originalStatus: MeetingStatus,
        didSetProcessing: Bool,
        error: Error
    ) -> MeetingStatus? {
        guard didSetProcessing else { return nil }
        if let retranscriptionError = error as? MeetingRetranscriptionError {
            switch retranscriptionError {
            case .emptyTranscript, .failedToSave:
                return originalStatus
            case .controllerUnavailable, .recordingUnavailable, .noDownloadedTranscriptionModel:
                break
            }
        }
        return .failed
    }

    // MARK: - Meeting Editing

    func meetingParticipants(meetingID: Int64) async throws -> [MeetingParticipant] {
        await waitForCalendarAttendeePersistence(meetingID: meetingID)
        let databaseURL = dictationStore.resolvedDatabaseURL
        return try await Task.detached(priority: .userInitiated) {
            try DictationStore(databaseURL: databaseURL).listMeetingParticipants(meetingID: meetingID)
        }.value
    }

    func attachMeetingParticipant(
        meetingID: Int64,
        participant: MeetingParticipantDraft
    ) async throws {
        let databaseURL = dictationStore.resolvedDatabaseURL
        try await Task.detached(priority: .userInitiated) {
            try DictationStore(databaseURL: databaseURL).attachMeetingParticipant(
                meetingID: meetingID,
                participant: participant
            )
        }.value
    }

    func removeMeetingParticipant(
        meetingID: Int64,
        participantIdentifier: String
    ) async throws {
        let databaseURL = dictationStore.resolvedDatabaseURL
        try await Task.detached(priority: .userInitiated) {
            try DictationStore(databaseURL: databaseURL).removeMeetingParticipant(
                meetingID: meetingID,
                participantIdentifier: participantIdentifier
            )
        }.value
    }

    private func persistCalendarAttendees(
        _ attendees: [CalendarAttendee],
        meetingID: Int64,
        mode: CalendarAttendeePersistenceMode = .attach
    ) {
        persistCalendarParticipants(
            attendees.map(\.participantDraft),
            meetingID: meetingID,
            mode: mode
        )
    }

    private func persistCalendarAttendees(
        for occurrence: CalendarOccurrenceReference?,
        meetingID: Int64
    ) {
        guard let occurrence, occurrence.provider == .eventKit else { return }

        if let cached = appState.upcomingCalendarEvents.first(where: {
            $0.source == .eventKit && $0.resolvedCalendarOccurrence.identityKey == occurrence.identityKey
        }) {
            persistCalendarAttendees(cached.attendees, meetingID: meetingID)
            return
        }

        Task { [weak self] in
            let attendees = await Task.detached(priority: .utility) {
                CalendarMonitor.attendees(for: occurrence)
            }.value
            self?.persistCalendarAttendees(attendees, meetingID: meetingID)
        }
    }

    private func persistCalendarParticipants(
        _ participants: [MeetingParticipantDraft],
        meetingID: Int64,
        mode: CalendarAttendeePersistenceMode
    ) {
        guard mode == .reconcile || !participants.isEmpty else { return }

        let databaseURL = dictationStore.resolvedDatabaseURL
        let previousTask = calendarAttendeePersistenceTasks[meetingID]?.task
        let generation = UUID()
        let task = Task.detached(priority: .utility) {
            _ = await previousTask?.value
            do {
                let store = DictationStore(databaseURL: databaseURL)
                switch mode {
                case .attach:
                    try store.attachCalendarMeetingParticipants(
                        meetingID: meetingID,
                        participants: participants
                    )
                case .reconcile:
                    try store.reconcileCalendarMeetingParticipants(
                        meetingID: meetingID,
                        participants: participants
                    )
                }
                return true
            } catch {
                fputs(
                    "[calendar] failed to save attendees for meeting \(meetingID): \(error)\n",
                    stderr
                )
                return false
            }
        }
        calendarAttendeePersistenceTasks[meetingID] = (generation, task)

        Task { [weak self] in
            let didPersist = await task.value
            guard let self,
                  self.calendarAttendeePersistenceTasks[meetingID]?.generation == generation else {
                return
            }
            self.calendarAttendeePersistenceTasks.removeValue(forKey: meetingID)
            if didPersist {
                NotificationCenter.default.post(
                    name: .meetingParticipantsDidChange,
                    object: meetingID
                )
            }
        }
    }

    private func waitForCalendarAttendeePersistence(meetingID: Int64) async {
        while let pending = calendarAttendeePersistenceTasks[meetingID] {
            _ = await pending.task.value
            guard let current = calendarAttendeePersistenceTasks[meetingID],
                  current.generation != pending.generation else {
                return
            }
        }
    }

    private func notesContextForResummary(_ meeting: MeetingRecord) -> String? {
        Self.notesContextForResummary(meeting)
    }

    static func notesContextForResummary(_ meeting: MeetingRecord) -> String? {
        guard meeting.notesState == .structuredNotes else { return nil }
        let trimmed = stripManualNotesSection(from: meeting.formattedNotes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func stripManualNotesSection(from notes: String) -> String {
        let markers = [
            "\n\n### Written notes\n\n",
            "\n### Written notes\n\n",
            "### Written notes\n\n",
            "\n\n## Manual Notes\n\n",
            "\n## Manual Notes\n\n",
            "## Manual Notes\n\n"
        ]
        for marker in markers {
            if let range = notes.range(of: marker, options: [.backwards]) {
                return String(notes[..<range.lowerBound])
            }
        }
        return notes
    }

    func updateMeetingTitle(id: Int64, title: String) {
        liveMeetingTitleCache[id] = title
        do {
            try dictationStore.updateMeetingTitle(id: id, title: title)
            liveMeetingTitleCache[id] = nil
        } catch {
            fputs("[meets] failed to update meeting title \(id): \(error)\n", stderr)
        }
        syncAppState()
    }

    func cacheMeetingTitle(id: Int64, title: String) {
        liveMeetingTitleCache[id] = title
    }

    // MARK: - Calendar Event Linkage (record + title sync)
    //
    // Mutation entry points for the calendar ↔ meeting linkage core
    // (MeetingCalendarLinkage.swift). Callee-driven: views derive state via
    // `MeetingEventLinkage` and call these to act on it.

    /// Records the given calendar event as a meeting. Refuses when recording
    /// is already running/starting or the calendar cannot be read (no full
    /// access). Returns false when the recording did not start — callers can
    /// then surface the app's existing error/status UI.
    /// - Parameters:
    ///   - event: The calendar event to record. Its title, occurrence
    ///     identity, and end date (for auto-stop) seed the recording.
    /// - Returns: True when the recording started, false otherwise (already
    ///   recording, no calendar access, model missing, ...).
    @discardableResult
    /// Starts a recording for a calendar event. Completed events normally
    /// refuse (single-pick `canRecord` gate); `allowAdditionalRecording`
    /// bypasses that gate so an event can hold multiple recordings — the
    /// placeholder check below still prevents duplicating an empty entry.
    func recordCalendarEvent(_ event: UnifiedCalendarEvent, allowAdditionalRecording: Bool = false) async -> Bool {
        guard calendarEventKitManager.canReadEvents else {
            fputs("[calendar-linkage] recordCalendarEvent declined: no calendar read access\n", stderr)
            return false
        }
        let linkage = MeetingEventLinkage.derive(
            event: event,
            meetings: appState.meetingRows,
            now: Date(),
            isCurrentlyRecording: isMeetingRecording() || isStartingMeetingRecording
        )
        guard linkage.canRecord || allowAdditionalRecording else {
            fputs("[calendar-linkage] recordCalendarEvent declined: event not recordable (state=\(linkage.state.tintName))\n", stderr)
            return false
        }
        // Recordings are per-occurrence; an event the user recorded before can
        // be recorded again, but a placeholder meeting created from this event
        // (CalendarPage's "add to meetings") is idempotent — never open a
        // second live session for an event that only has an empty placeholder.
        let occurrence = event.resolvedCalendarOccurrence
        if let existing = try? dictationStore.meetingByCalendarOccurrence(occurrence),
           existing.calendarOccurrence != nil,
           existing.rawTranscript.isEmpty,
           existing.formattedNotes.isEmpty,
           existing.status == .noteOnly || existing.status == .completed {
            fputs("[calendar-linkage] event already has a placeholder meeting \(existing.id); opening it instead of recording\n", stderr)
            showMeetingDocument(id: existing.id)
            return false
        }

        let didStart = startMeetingRecordingFromEntryPoint(
            title: event.title,
            calendarEventID: event.id,
            calendarOccurrence: occurrence,
            endDate: event.endDate,
            autoStopSource: event.meetingURL.flatMap { MeetingAutoStopSource(meetingURL: $0) },
            presentation: .foregroundNotes,
            startOrigin: .calendarEvent
        )
        if didStart {
            fputs("[calendar-linkage] started recording for calendar event \(event.id) (\(event.title))\n", stderr)
        }
        return didStart
    }

    /// Renames a calendar event directly in EventKit, keeping the app's
    /// calendar copy authoritative for its own meeting title sync. The
    /// rename persists through the shared `CalendarEventKitManager` store;
    /// the calendar page refreshes from the resulting
    /// `EKEventStoreChanged` notification. Cancelled/declined events are not
    /// renamed (they can belong to another organizer). Returns false when
    /// the event cannot be resolved or saved.
    func renameCalendarEvent(_ event: UnifiedCalendarEvent, to newTitle: String) -> Bool {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !event.isCancelled,
              !event.isDeclined,
              calendarEventKitManager.canReadEvents,
              let ekEvent = calendarEventKitManager.store.event(withIdentifier: event.id) else {
            return false
        }
        guard ekEvent.status != .canceled else { return false }
        ekEvent.title = trimmed
        do {
            try calendarEventKitManager.store.save(ekEvent, span: .thisEvent, commit: true)
            return true
        } catch {
            fputs("[calendar-linkage] failed to rename calendar event \(event.id): \(error)\n", stderr)
            return false
        }
    }

    /// Renames a stored meeting's title to a calendar event's title — only
    /// when the meeting's title is a stale copy of the calendar's previous
    /// title (see `MeetingCalendarLinkage.titleSyncDecision`). Never touches
    /// user-authored titles; otherwise a no-op.
    func syncMeetingTitleWithCalendarEvent(meetingID: Int64, event: UnifiedCalendarEvent) async {
        guard let meeting = meeting(id: meetingID) else {
            fputs("[calendar-linkage] syncMeetingTitle: meeting \(meetingID) not found\n", stderr)
            return
        }
        await syncMeetingTitleWithCalendarEventIfNeeded(meeting: meeting, event: event)
    }

    /// Called when EventKit reports calendar changes. EventKit delivers many
    /// notifications per user edit, so the pass itself is coalesced: while
    /// change notifications keep arriving (a 0.75s settle window), each call
    /// bumps the token and only the call that still owns it after the window
    /// runs the diff. The pass refreshes the event list, compares it against
    /// what the previous pass observed, and propagates a changed event title
    /// to meetings that still carry the *old* calendar title. User-authored
    /// titles are never overwritten: a meeting title that does not equal the
    /// event's pre-change title is left alone. Idempotent: re-running without
    /// an event change applies nothing.
    /// - Returns: The number of meetings whose titles were updated.
    @discardableResult
    func handleCalendarEventChange() async -> Int {
        let token = calendarChangeDebounceToken &+ 1
        calendarChangeDebounceToken = token

        do {
            try await Task.sleep(for: .milliseconds(750))
        } catch {
            return 0 // cancelled
        }
        guard calendarChangeDebounceToken == token else {
            return 0 // a newer change superseded this call — it will sync
        }
        return await applyCalendarTitleSyncPass()
    }

    /// The diffing half of `handleCalendarEventChange`. Refreshes
    /// `appState.calendarEvents`, records each observed event's current title
    /// as the "old" title for the next pass, and renames meetings whose stored
    /// title equals that old title to the event's new title. Public so tests
    /// can drive a sync pass without touching EventKit.
    /// - Returns: Number of meetings whose titles were updated.
    @discardableResult
    func applyCalendarTitleSyncPass() async -> Int {
        let previousTitles = calendarChangeLastRunEventTitles
        await fetchCalendarEventsIntoAppState()
        let events = appState.calendarEvents

        // Record current titles first so a later event change is diffed
        // against exactly this snapshot — even if a rename below mutates
        // meeting titles, the next pass still knows what the calendar said
        // before that rename.
        var observedTitles: [String: String] = [:]
        for event in events {
            if event.isCancelled || event.isDeclined { continue }
            observedTitles[event.id] = event.title
        }
        calendarChangeLastRunEventTitles = observedTitles

        var updatedCount = 0
        for meeting in appState.meetingRows {
            // A live session owns its title until stop() persists the final
            // one; renaming mid-recording would be clobbered or corrupt the
            // stop flow. Processed meetings are excluded for the same reason.
            guard meeting.status != .recording, meeting.status != .processing else { continue }
            guard let event = Self.event(in: events, matching: meeting) else { continue }
            guard event.title != meeting.title else { continue }

            // Only a title known from a *previous* pass can be an "old"
            // calendar title. The meeting's stored title must equal it
            // exactly (a pure calendar copy); any user-authored divergence
            // stops the sync. First pass after launch sees no previous
            // titles, so nothing is renamed until the calendar next changes.
            guard let oldTitle = previousTitles[event.id],
                  meeting.title == oldTitle,
                  MeetingCalendarLinkage.titleSyncDecision(
                      event: event,
                      meeting: meeting,
                      oldTitle: oldTitle
                  ) else { continue }

            updateMeetingTitle(id: meeting.id, title: event.title)
            updatedCount += 1
        }
        if updatedCount > 0 {
            syncAppState()
        }
        return updatedCount
    }

    /// Matches a stored meeting to the calendar event it was recorded from
    /// (same key rules as `MeetingCalendarLinkage.linkedMeeting`, without the
    /// title-window fallback: title sync must never guess).
    private static func event(
        in events: [UnifiedCalendarEvent],
        matching meeting: MeetingRecord
    ) -> UnifiedCalendarEvent? {
        guard meeting.calendarEventID != nil || meeting.calendarOccurrence != nil else { return nil }
        let occurrenceKey = meeting.calendarOccurrence?.identityKey
        let ids = [meeting.calendarEventID, meeting.calendarOccurrence?.eventID].compactMap { $0 }

        // Prefer the exact occurrence (recurring instances), then stored ids.
        if let occurrenceKey {
            if let match = events.first(where: {
                $0.resolvedCalendarOccurrence.identityKey == occurrenceKey
            }) {
                return match
            }
        }
        return events.first { event in
            ids.contains(event.id)
        }
    }

    /// Per-meeting title sync core for the explicit (non-diff) path, driven
    /// from the Calendar UI. True when a rename was applied.
    private func syncMeetingTitleWithCalendarEventIfNeeded(
        meeting: MeetingRecord,
        event: UnifiedCalendarEvent
    ) async -> Bool {
        guard meeting.title != event.title,
              MeetingCalendarLinkage.titleSyncDecision(
                  event: event,
                  meeting: meeting,
                  oldTitle: nil // no pre-change snapshot; fresh-copy heuristic
              ) else {
            return false
        }
        updateMeetingTitle(id: meeting.id, title: event.title)
        return true
    }

    // MARK: - Meeting ↔ Event explicit attachments ("Add to Event")

    /// Attaches any meeting to a calendar event (multi-link). The first
    /// attached event becomes the meeting's *primary* `calendarEventID` when
    /// the meeting has none yet, so calendar↔meeting linkage keeps working
    /// for meetings that never recorded from a calendar row. Every attach
    /// also auto-adds the event's attendees to the meeting (calendar source,
    /// deduped by participant identifier).
    func linkMeetingToEvent(meetingID: Int64, event: UnifiedCalendarEvent) async {
        guard let meeting = meeting(id: meetingID) else { return }
        let occurrence = event.resolvedCalendarOccurrence
        // Primary matches only for the same instance: a meeting recorded
        // from Thursday must still be attachable to Tuesday (same bare
        // series id, different occurrence). Meetings without any recorded
        // occurrence keep the legacy bare-id match.
        let alreadyPrimary: Bool = {
            guard meeting.calendarEventID == event.id
                || meeting.calendarOccurrence?.eventID == event.id else { return false }
            guard let recordedOccurrence = meeting.calendarOccurrence else { return true }
            return recordedOccurrence.identityKey == occurrence.identityKey
        }()
        let alreadyLinked = appState.meetingEventLinks.contains {
            $0.meetingID == meetingID
                && $0.eventID == event.id
                && $0.occurrenceKey == occurrence.identityKey
        }
        guard !alreadyPrimary, !alreadyLinked else { return }

        do {
            if meeting.calendarEventID == nil, meeting.calendarOccurrence == nil {
                // This meeting has no recorded calendar identity at all
                // (quick/manual meeting): the first attached event becomes the
                // primary one so calendar rows can find and open it.
                try dictationStore.updateMeetingCalendarLink(
                    id: meetingID,
                    eventID: event.id,
                    occurrence: occurrence
                )
            }
            try dictationStore.addMeetingEventLink(
                meetingID: meetingID,
                eventID: event.id,
                calendarID: event.calendarID,
                occurrenceKey: occurrence.identityKey
            )
            syncAppState()
            fputs("[meets] linked meeting \(meetingID) to calendar event \(event.id) (\(event.title))\n", stderr)
        } catch {
            fputs("[meets] failed to link meeting \(meetingID) to calendar event \(event.id): \(error)\n", stderr)
            return
        }

        // Auto-add the event's attendees as calendar-sourced people. Runs
        // through the same coalesced persistence queue the recording flow
        // uses, so People UI stays consistent and duplicate attachments are
        // collapsed by identifier.
        let participants = event.attendees.map(\.participantDraft)
        guard !participants.isEmpty else { return }
        persistCalendarParticipants(participants, meetingID: meetingID, mode: .attach)
    }

    /// Detaches a meeting from an event attached via "Add to Event". The
    /// meeting's primary calendar identity (recorded from an event) is never
    /// removed through this path; only explicit link rows are deleted.
    /// Occurrence-scoped link identities for one meeting: the inline recorded
    /// occurrence key plus every explicit row's occurrence key. The picker
    /// matches rows against these so checking one recurring instance does not
    /// check its whole series. (Rows predating occurrence keys match through
    /// the legacy bare-id fallback in the view, single events only.)
    func eventLinkIdentityKeys(toMeeting meeting: MeetingRecord) -> Set<String> {
        var keys = Set<String>()
        if let key = meeting.calendarOccurrence?.identityKey { keys.insert(key) }
        for link in meetingEventLinks(meetingID: meeting.id) {
            if let key = link.occurrenceKey { keys.insert(key) }
        }
        return keys
    }

    /// Detaches one event instance. When this removes the meeting's last
    /// attachment of any kind *and* the inline primary points at the same
    /// instance, the primary is cleared too so the meeting is genuinely
    /// eventless (recorded provenance otherwise keeps it checked forever).
    /// A nil occurrenceKey keeps the legacy rows-only behavior.
    func unlinkMeetingFromEvent(meetingID: Int64, eventID: String, occurrenceKey: String? = nil) async {
        do {
            try dictationStore.removeMeetingEventLink(
                meetingID: meetingID,
                eventID: eventID,
                occurrenceKey: occurrenceKey
            )
            if let occurrenceKey,
               let meeting = meeting(id: meetingID),
               (try? dictationStore.meetingEventLinks(meetingID: meetingID))?.isEmpty ?? false,
               meeting.calendarEventID == eventID,
               meeting.calendarOccurrence?.identityKey ?? occurrenceKey == occurrenceKey {
                try dictationStore.clearMeetingCalendarLink(id: meetingID)
                fputs("[meets] cleared primary calendar link for meeting \(meetingID) (last attachment removed)\n", stderr)
            }
            syncAppState()
            fputs("[meets] unlinked meeting \(meetingID) from calendar event \(eventID)\n", stderr)
        } catch {
            fputs("[meets] failed to unlink meeting \(meetingID) from calendar event \(eventID): \(error)\n", stderr)
        }
    }

    /// The explicit "Add to Event" attachments for one meeting (excludes its
    /// primary calendar event).
    func meetingEventLinks(meetingID: Int64) -> [MeetingEventLink] {
        appState.meetingEventLinks.filter { $0.meetingID == meetingID }
    }

    /// Event ids (calendar identifiers) a meeting is attached to through any
    /// channel: primary recorded event, recorded occurrence, and explicit
    /// "Add to Event" link rows. Used by UI to show a meeting as linked.
    func eventIDsLinked(toMeeting meeting: MeetingRecord) -> Set<String> {
        var ids = Set<String>()
        if let id = meeting.calendarEventID { ids.insert(id) }
        if let eventID = meeting.calendarOccurrence?.eventID { ids.insert(eventID) }
        for link in meetingEventLinks(meetingID: meeting.id) {
            ids.insert(link.eventID)
        }
        return ids
    }

    /// Meetings attached to the given event (by stored id or explicit link
    /// row). Display-side answer to "which meetings exist for this event";
    /// `MeetingCalendarLinkage.linkedMeeting` receives these as
    /// `additionalLinkedMeetingIDs`.
    func meetingIDsLinked(toEvent event: UnifiedCalendarEvent) -> Set<Int64> {
        let key = event.resolvedCalendarOccurrence.identityKey
        let linkIDs = appState.meetingEventLinks
            .filter { link in
                link.occurrenceKey.map({ $0 == key }) ?? (link.eventID == event.id)
                    || appState.meetingRows.contains {
                        $0.id == link.meetingID
                            && link.occurrenceKey != nil
                            && $0.calendarOccurrence?.identityKey == link.occurrenceKey
                    }
            }
            .map(\.meetingID)
        return Set(linkIDs)
    }

    func updateMeetingNotes(id: Int64, notes: String) {
        try? dictationStore.updateMeetingNotes(id: id, formattedNotes: notes)
        syncAppState()
    }

    func updateMeetingTranscript(id: Int64, transcript: String) {
        do {
            try dictationStore.updateMeetingTranscript(id: id, rawTranscript: transcript)
        } catch {
            fputs("[meets] failed to update meeting transcript \(id): \(error)\n", stderr)
        }
        syncAppState()
    }

    /// Cleans a meeting's stored transcript with the configured LLM cleanup
    /// backend (local Qwen3 GGUF on macOS 15+, or a hosted ChatGPT/OpenAI/
    /// OpenRouter/Ollama/LM Studio/custom backend). Returns the cleaned text.
    func cleanMeetingTranscript(id: Int64) async throws -> String {
        guard let meeting = meeting(id: id) else {
            throw TranscriptCleanupError.missingConfiguration("Meeting not found.")
        }
        let text = meeting.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriptCleanupError.missingConfiguration("Meeting has no transcript to clean.")
        }
        let backend = TranscriptCleanupBackendOption.resolved(config.postProcessorBackend)
        let systemPrompt = config.postProcessorSystemPrompt

        if backend.isGemma4LiteRT {
            throw TranscriptCleanupError.missingConfiguration(
                "Gemma 4 cleanup is not available in this build. Choose Local Model or a hosted backend."
            )
        }
        if backend.isLocal {
            guard #available(macOS 15, *) else {
                throw TranscriptCleanupError.missingConfiguration("Local cleanup requires macOS 15 or later.")
            }
            let option = PostProcessorOption.runtimeOption(id: config.activePostProcessorId)
            guard let option else {
                throw TranscriptCleanupError.missingConfiguration("No local cleanup model downloaded.")
            }
            let processor: Qwen3PostProcessor
            if let existing = qwen3PostProcessor as? Qwen3PostProcessor {
                processor = existing
            } else {
                let created = Qwen3PostProcessor(
                    modelURL: option.modelURL,
                    systemPrompt: systemPrompt,
                    inputFormat: option.inputFormat
                )
                qwen3PostProcessor = created
                processor = created
            }
            await processor.reconfigure(
                modelURL: option.modelURL,
                systemPrompt: systemPrompt,
                inputFormat: option.inputFormat
            )
            let cleaned = try await processor.process(
                text,
                appContext: nil,
                configuration: Qwen3PostProcessor.Configuration(
                    modelURL: option.modelURL,
                    systemPrompt: systemPrompt,
                    inputFormat: option.inputFormat
                )
            )
            let result = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else {
                throw TranscriptCleanupError.rejectedOutput
            }
            logLLMUsage(
                kind: "cleanup",
                backend: backend.backend,
                model: option.label,
                status: "success",
                characters: text.count,
                meetingID: id
            )
            return result
        }

        do {
            let result = try await TranscriptCleanupClient.clean(
                text: text,
                systemPrompt: systemPrompt,
                appContext: nil,
                backend: backend,
                config: config
            )
            let cleaned = result.cleanedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                throw TranscriptCleanupError.emptyResponse(backend.label)
            }
            logLLMUsage(
                kind: "cleanup",
                backend: backend.backend,
                model: config.postProcessorChatGPTModel.isEmpty ? config.activePostProcessorId : config.postProcessorChatGPTModel,
                status: "success",
                characters: text.count,
                meetingID: id
            )
            return cleaned
        } catch {
            logLLMUsage(
                kind: "cleanup",
                backend: backend.backend,
                model: config.postProcessorChatGPTModel.isEmpty ? config.activePostProcessorId : config.postProcessorChatGPTModel,
                status: "failed",
                characters: text.count,
                meetingID: id
            )
            throw error
        }
    }

    /// Records one LLM-pillar usage event into the local llm_usage_log table
    /// (read by Insights). Fire-and-forget; failures are silent.
    private func logLLMUsage(
        kind: String,
        backend: String,
        model: String,
        status: String,
        retryCount: Int = 0,
        characters: Int = 0,
        meetingID: Int64? = nil
    ) {
        dictationStore.recordLLMUsage(
            kind: kind,
            backend: backend,
            model: model,
            status: status,
            retryCount: retryCount,
            characters: characters,
            meetingID: meetingID
        )
    }

    /// Cleans and persists the meeting transcript. Called from the meeting
    /// detail view's Clean up Transcript action.
    func applyTranscriptCleanup(id: Int64) async throws {
        let cleaned = try await cleanMeetingTranscript(id: id)
        try await MainActor.run {
            updateMeetingTranscript(id: id, transcript: cleaned)
        }

    }


    func updateMeetingManualNotes(id: Int64, notes: String) {
        liveManualNotesPersistWorkItems[id]?.cancel()
        liveManualNotesPersistWorkItems[id] = nil
        liveManualNotesCache[id] = notes
        do {
            try dictationStore.updateMeetingManualNotes(id: id, manualNotes: notes)
            markMeetingManualNotesPersisted(id: id, notes: notes)
        } catch {
            fputs("[meets] failed to update manual notes for \(id): \(error)\n", stderr)
        }
        syncAppState()
    }

    /// Per-meeting preference: include this meeting's written notes when the AI
    /// summary is generated (prompt input + retained in the generated notes).
    func cacheMeetingManualNotes(id: Int64, notes: String) {
        liveManualNotesCache[id] = notes
        scheduleCachedMeetingManualNotesPersistence(id: id)
    }

    func flushCachedMeetingManualNotes(id: Int64, sync: Bool = true) {
        liveManualNotesPersistWorkItems[id]?.cancel()
        liveManualNotesPersistWorkItems[id] = nil
        guard let notes = liveManualNotesCache[id] else { return }
        persistCachedMeetingManualNotes(id: id, notes: notes, sync: sync)
    }

    func hasPersistedMeetingManualNotes(id: Int64, notes: String) -> Bool {
        if liveManualNotesLastPersistedValue[id] == notes {
            return true
        }
        return (try? dictationStore.meeting(id: id)?.manualNotes) == notes
    }

    private func scheduleCachedMeetingManualNotesPersistence(id: Int64) {
        guard let notes = liveManualNotesCache[id] else { return }
        if shouldPersistCachedMeetingManualNotesImmediately(id: id, notes: notes) {
            flushCachedMeetingManualNotes(id: id, sync: false)
            return
        }

        let lastPersistedAt = liveManualNotesLastPersistedAt[id] ?? .distantPast
        let delay = max(liveManualNotesPersistInterval - Date().timeIntervalSince(lastPersistedAt), 0)
        liveManualNotesPersistWorkItems[id]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.flushCachedMeetingManualNotes(id: id, sync: false)
        }
        liveManualNotesPersistWorkItems[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func shouldPersistCachedMeetingManualNotesImmediately(id: Int64, notes: String) -> Bool {
        if liveManualNotesLastPersistedValue[id] == nil { return true }
        if notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        let lastPersistedAt = liveManualNotesLastPersistedAt[id] ?? .distantPast
        return Date().timeIntervalSince(lastPersistedAt) >= liveManualNotesPersistInterval
    }

    private func persistCachedMeetingManualNotes(id: Int64, notes: String, sync: Bool) {
        if liveManualNotesLastPersistedValue[id] == notes {
            if sync {
                syncAppState()
            }
            return
        }
        do {
            try dictationStore.updateMeetingManualNotes(id: id, manualNotes: notes)
            markMeetingManualNotesPersisted(id: id, notes: notes)
        } catch {
            fputs("[meets] failed to persist manual notes for \(id): \(error)\n", stderr)
        }
        if sync {
            syncAppState()
        }
    }

    private func markMeetingManualNotesPersisted(id: Int64, notes: String) {
        liveManualNotesLastPersistedAt[id] = Date()
        liveManualNotesLastPersistedValue[id] = notes
    }

    private func clearCachedMeetingManualNotes(id: Int64) {
        liveManualNotesPersistWorkItems[id]?.cancel()
        liveManualNotesPersistWorkItems[id] = nil
        liveManualNotesCache[id] = nil
        liveManualNotesLastPersistedAt[id] = nil
        liveManualNotesLastPersistedValue[id] = nil
    }

    private func clearCachedMeetingTitle(id: Int64) {
        liveMeetingTitleCache[id] = nil
    }

    private func flushCachedMeetingTitle(id: Int64) {
        guard let title = liveMeetingTitleCache[id] else { return }
        do {
            try dictationStore.updateMeetingTitle(id: id, title: title)
            liveMeetingTitleCache[id] = nil
        } catch {
            fputs("[meets] failed to flush cached meeting title \(id): \(error)\n", stderr)
        }
    }

    private func clearAllCachedMeetingManualNotes() {
        liveManualNotesPersistWorkItems.values.forEach { $0.cancel() }
        liveManualNotesPersistWorkItems.removeAll()
        liveManualNotesCache.removeAll()
        liveManualNotesLastPersistedAt.removeAll()
        liveManualNotesLastPersistedValue.removeAll()
    }

    private func clearAllCachedMeetingTitles() {
        liveMeetingTitleCache.removeAll()
    }

    private func manualNotesForLiveMeeting(id: Int64) -> String {
        if let cached = liveManualNotesCache[id] {
            return cached
        }
        return (try? dictationStore.meeting(id: id)?.manualNotes) ?? ""
    }

    // MARK: - Folder Management

    nonisolated static func treeOrderedFolders(_ folders: [MeetingFolder], order: [Int64]) -> [MeetingFolder] {
        let orderedFolders = folders.sorted { a, b in
            let ai = order.firstIndex(of: a.id) ?? Int.max
            let bi = order.firstIndex(of: b.id) ?? Int.max
            if ai != bi { return ai < bi }
            return a.id < b.id
        }
        var childrenMap: [Int64?: [MeetingFolder]] = [:]
        for folder in folders {
            childrenMap[folder.parentID, default: []].append(folder)
        }
        // Sort siblings by folderOrder index, then by id as fallback.
        for key in childrenMap.keys {
            childrenMap[key]?.sort { a, b in
                let ai = order.firstIndex(of: a.id) ?? Int.max
                let bi = order.firstIndex(of: b.id) ?? Int.max
                if ai != bi { return ai < bi }
                return a.id < b.id
            }
        }
        var result: [MeetingFolder] = []
        var visited: Set<Int64> = []
        func visit(_ parentID: Int64?) {
            for folder in childrenMap[parentID] ?? [] {
                guard visited.insert(folder.id).inserted else { continue }
                result.append(folder)
                visit(folder.id)
            }
        }
        visit(nil)
        // Include orphaned folders and closed cycles so corrupt hierarchy data never hides folders.
        for folder in orderedFolders where !visited.contains(folder.id) {
            visited.insert(folder.id)
            result.append(folder)
            visit(folder.id)
        }
        return result
    }

    @discardableResult
    func createFolder(name: String) -> Int64? {
        let id = try? dictationStore.createFolder(name: name)
        syncAppState()
        return id
    }

    func renameFolder(id: Int64, name: String) {
        try? dictationStore.renameFolder(id: id, name: name)
        syncAppState()
    }

    func reorderFolders(ids: [Int64]) {
        updateConfig { $0.folderOrder = ids }
        syncAppState()
    }

    @discardableResult
    func createSubfolder(name: String, parentID: Int64) -> Int64? {
        let id = try? dictationStore.createFolder(name: name, parentID: parentID)
        syncAppState()
        return id
    }

    func moveFolder(id: Int64, toParent newParentID: Int64?) {
        try? dictationStore.moveFolder(id: id, toParent: newParentID)
        syncAppState()
    }

    func createFolderAndMoveMeeting(name: String, meetingID: Int64) {
        guard let folderID = try? dictationStore.createFolder(name: name) else { return }
        try? dictationStore.moveMeetingFamily(rootID: meetingID, toFolder: folderID)
        syncAppState()
    }

    func deleteFolder(id: Int64) {
        try? dictationStore.deleteFolder(id: id)
        if appState.selectedFolderID == id {
            appState.selectedFolderID = nil
        }
        syncAppState()
    }

    func hideCalendarEvent(_ event: UnifiedCalendarEvent) {
        appState.hiddenCalendarEventIDs.insert(event.id)
        updateConfig {
            $0.hiddenCalendarEventIDs = self.appState.hiddenCalendarEventIDs.sorted()
            $0.hiddenCalendarEventSourceHints[event.id] = event.source.rawValue
        }
        statusBarController?.refresh()
    }

    func createMeetingFromCalendarEvent(_ event: UnifiedCalendarEvent, folderID: Int64?) {
        let occurrence = event.resolvedCalendarOccurrence
        // Calendar placeholders are idempotent per occurrence. Recordings are
        // intentionally not: users may record the same occurrence more than once.
        if let existing = try? dictationStore.meetingByCalendarOccurrence(occurrence) {
            if let folderID {
                try? dictationStore.moveMeeting(id: existing.id, toFolder: folderID)
            }
            syncAppState()
            fputs("[meets] calendar event already exists as meeting \(existing.id), moved to folder\n", stderr)
            return
        }

        do {
            let meetingID = try dictationStore.insertMeeting(
                title: event.title,
                calendarEventID: event.id,
                startTime: event.startDate,
                endTime: event.endDate,
                rawTranscript: "",
                formattedNotes: "",
                micAudioPath: nil,
                systemAudioPath: nil,
                calendarOccurrence: occurrence
            )
            persistCalendarAttendees(event.attendees, meetingID: meetingID)
            if let folderID {
                try? dictationStore.moveMeeting(id: meetingID, toFolder: folderID)
            }
            syncAppState()
            fputs("[meets] created meeting from calendar event: \(event.title) (folder=\(folderID.map(String.init) ?? "none"))\n", stderr)
        } catch {
            fputs("[meets] failed to create meeting from calendar event: \(error)\n", stderr)
        }
    }

    /// Moves a meeting to a folder (or unfiles it with nil). The meeting's whole
    /// follow-up subtree moves with it, at every depth.
    func moveMeeting(id: Int64, toFolder folderID: Int64?) {
        try? dictationStore.moveMeetingFamily(rootID: id, toFolder: folderID)
        syncAppState()
    }

    func deleteMeeting(id: Int64) {
        guard let meeting = meeting(id: id) else { return }
        guard canDeleteMeeting(meeting) else { return }

        do {
            // Delete the retained file first so a failed file removal does not orphan
            // user-visible recording data after the meeting row disappears.
            if let savedRecordingPath = meeting.savedRecordingPath,
               try shouldDeleteSavedMeetingRecording(at: savedRecordingPath, excluding: id) {
                try deleteSavedMeetingRecording(at: savedRecordingPath)
            }
            try dictationStore.deleteMeeting(id: id)
            cleanupOrphanedMeetingWaveformCacheFiles()
        } catch let error as MeetingLifecycleError {
            presentErrorAlert(title: "Couldn't Delete Meeting", message: error.localizedDescription)
            return
        } catch {
            presentErrorAlert(
                title: "Couldn't Delete Meeting",
                message: MeetingLifecycleError.failedToDeleteMeeting(underlying: error).localizedDescription
            )
            return
        }

        if appState.selectedMeetingID == id {
            appState.selectedMeetingID = nil
            appState.selectedMeetingRecord = nil
            if case .document(let selectedID) = appState.meetingsNavigationState, selectedID == id {
                appState.meetingsNavigationState = .browser
            }
        }
        clearCachedMeetingManualNotes(id: id)
        clearCachedMeetingTitle(id: id)
        staleLiveMeetingRecoveryFailures.remove(id)

        historyWindowController?.reload()
        statusBarController?.refresh()
        syncAppState()
    }

    func canDeleteMeeting(_ meeting: MeetingRecord) -> Bool {
        canDeleteMeeting(id: meeting.id, status: meeting.status)
    }

    /// Same policy as `canDeleteMeeting(_:)` for browser rows that only carry a
    /// lightweight index entry, so rendering a row does not resolve a full
    /// record per row.
    func canDeleteMeeting(id: Int64, status: MeetingStatus) -> Bool {
        guard id != activeMeetingID else { return false }
        if staleLiveMeetingRecoveryFailures.contains(id) {
            return true
        }
        switch status {
        case .recording, .processing:
            return false
        case .completed, .noteOnly, .failed:
            return true
        }
    }

    func activeLiveMeetingRecord() -> MeetingRecord? {
        guard let activeMeetingID,
              isMeetingRecording() || isStartingMeetingRecording else {
            return nil
        }
        return meeting(id: activeMeetingID)
    }

    func clearMeetingHistory() {
        guard !isMeetingRecording(), !isStartingMeetingRecording, backgroundMeetingProcessingCount == 0 else {
            presentErrorAlert(
                title: "Couldn't Clear Meeting History",
                message: "A meeting is recording or still being processed. Please wait before clearing saved meetings."
            )
            return
        }

        do {
            try? clearSavedMeetingWaveformCache()
            try clearSavedMeetingRecordingsDirectory()
        } catch {
            presentErrorAlert(
                title: "Couldn't Clear Meeting History",
                message: "Saved meeting audio files could not be deleted, so meeting history was left in place. \(error.localizedDescription)"
            )
            return
        }

        try? dictationStore.clearMeetings()
        clearAllCachedMeetingManualNotes()
        clearAllCachedMeetingTitles()
        appState.selectedMeetingID = nil
        appState.selectedMeetingRecord = nil
        appState.meetingsNavigationState = .browser
        statusBarController?.refresh()
        historyWindowController?.reload()
        syncAppState()
    }

    public func isMeetingRecording() -> Bool {
        activeMeetingSession?.isRecording == true || isStoppingMeetingRecording
    }

    func isMeetingRecordingPaused() -> Bool {
        activeMeetingSession?.isPaused == true
    }

    private var meetingTerminationState: MeetingTerminationState {
        MeetingTerminationPolicy.state(
            isStarting: isStartingMeetingRecording,
            hasActiveSession: activeMeetingSession != nil,
            isRecording: activeMeetingSession?.isRecording == true,
            isStopping: isStoppingMeetingRecording || backgroundMeetingProcessingCount > 0
        )
    }

    @MainActor
    func shouldTerminateApplication() -> Bool {
        let state = meetingTerminationState
        let messageText: String
        let informativeText: String

        if isTerminatingAfterMeetingConfirmation {
            isTerminatingAfterMeetingConfirmation = false
            return true
        }

        switch state {
        case .none:
            return true
        case .starting:
            messageText = "Meeting recording is starting"
            informativeText = "Quitting now will cancel the meeting recording before it has been saved."
        case .recording:
            messageText = "Meeting recording in progress"
            informativeText = "Quitting now will stop the meeting recording and the current transcript may be lost. Stop the recording first if you want Meets to save notes."
        case .processing:
            messageText = "Meeting transcription in progress"
            informativeText = "Quitting now will interrupt transcription and the meeting notes may not be saved."
        }

        guard !isPresentingMeetingTerminationConfirmation else {
            return false
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "Keep Meets Running")
        alert.addButton(withTitle: "Quit Anyway")

        isPresentingMeetingTerminationConfirmation = true
        let didPresent = presentAlert(alert, fallbackLogContext: "meeting termination confirmation") { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPresentingMeetingTerminationConfirmation = false
                guard response == .alertSecondButtonReturn else { return }
                self.discardMeetingStateForTermination()
                self.isTerminatingAfterMeetingConfirmation = true
                NSApp.terminate(nil)
            }
        }
        if !didPresent {
            isPresentingMeetingTerminationConfirmation = false
        }

        return false
    }

    private func discardMeetingStateForTermination() {
        activeMeetingSession?.discard()
        activeMeetingSession = nil
        preparingMeetingSession?.discard()
        preparingMeetingSession = nil
        clearLiveMeetingTranscript()
        disarmMeetingAutoStop()
        if let meetingStartMeetingID {
            canceledMeetingStartIDs.insert(meetingStartMeetingID)
            resolveLiveMeetingAfterStartFailure(id: meetingStartMeetingID)
        }
        meetingStartTask?.cancel()
        meetingStartTask = nil
        meetingStartMeetingID = nil
        isStartingMeetingRecording = false
        isStoppingMeetingRecording = false
        updateMeetingStartStatus(nil)
        updateMeetingNotificationVisibility()
        endMeetingActivity()
        syncAppState()
    }

    @objc func toggleMeetingRecording() {
        if isMeetingRecording() {
            stopMeetingRecording()
        } else {
            let wasMeetingRecording = isMeetingRecording()
            startMeetingRecordingFromEntryPoint()
            if !isMeetingRecording() && !isStartingMeetingRecording && !wasMeetingRecording {
                meetingRecordingHotkeyMonitor.cancelToggleMode()
            }
        }
    }

    @objc func startMeetingRecordingFromMenuBar() {
        startMeetingRecordingFromEntryPoint(
            dashboardWindowPresentation: .compactMeetingTrailing
        )
    }

    @objc func toggleMeetingRecordingPause() {
        if isMeetingRecordingPaused() {
            resumeMeetingRecording()
        } else {
            pauseMeetingRecording()
        }
    }

    func pauseMeetingRecording() {
        guard let activeMeetingSession,
              activeMeetingSession.isRecording,
              !activeMeetingSession.isPaused,
              !isStoppingMeetingRecording else { return }
        activeMeetingSession.pause()
        indicator.setMeetingRecordingPaused(true, config: config)
        statusBarController?.setStatus("Meeting paused")
        statusBarController?.refresh()
        syncAppState()
    }

    func resumeMeetingRecording() {
        guard let activeMeetingSession,
              activeMeetingSession.isRecording,
              activeMeetingSession.isPaused,
              !isStoppingMeetingRecording else { return }
        activeMeetingSession.resume()
        indicator.setMeetingRecordingPaused(false, config: config)
        statusBarController?.setStatus("Meeting: \(activeMeetingDisplayTitle())")
        statusBarController?.refresh()
        syncAppState()
    }

    @objc func startMeetingFromCalendarMenuItem(_ sender: NSMenuItem) {
        if let payload = sender.representedObject as? CalendarMenuMeetingPayload {
            startMeetingRecordingFromEntryPoint(
                title: payload.title,
                calendarOccurrence: payload.calendarOccurrence,
                endDate: payload.endDate,
                autoStopSource: payload.autoStopSource,
                startOrigin: .scheduledMeetingPrompt,
                dashboardWindowPresentation: .compactMeetingTrailing
            )
            return
        }

        guard let title = sender.representedObject as? String else { return }
        startMeetingRecordingFromEntryPoint(
            title: title,
            dashboardWindowPresentation: .compactMeetingTrailing
        )
    }

    @discardableResult
    func startMeetingRecordingFromEntryPoint(
        title: String = "Meeting",
        calendarEventID: String? = nil,
        calendarOccurrence: CalendarOccurrenceReference? = nil,
        endDate: Date? = nil,
        autoStopSource: MeetingAutoStopSource? = nil,
        presentation: MeetingStartPresentation = .foregroundNotes,
        startOrigin: MeetingRecordingStartOrigin = .manual,
        dashboardWindowPresentation: DashboardWindowPresentation = .restored
    ) -> Bool {
        if isMeetingRecording() {
            if presentation.presentsHistoryWindow {
                presentHistoryWindow(
                    tab: .meetings,
                    presentation: dashboardWindowPresentation
                )
            }
            return false
        }
        guard !isStartingMeetingRecording else { return false }
        let didStart = startMeetingRecording(
            title: title,
            calendarEventID: calendarEventID,
            calendarOccurrence: calendarOccurrence,
            openDocument: presentation.opensMeetingDocument,
            endDate: endDate,
            autoStopSource: autoStopSource,
            startOrigin: startOrigin
        )
        guard didStart else { return false }
        if presentation.presentsHistoryWindow {
            presentHistoryWindow(
                tab: .meetings,
                presentation: dashboardWindowPresentation
            )
        }
        return true
    }

    @discardableResult
    func startMeetingRecording(
        title: String = "Meeting",
        calendarEventID: String? = nil,
        calendarOccurrence: CalendarOccurrenceReference? = nil,
        openDocument: Bool = false,
        endDate: Date? = nil,
        autoStopSource: MeetingAutoStopSource? = nil,
        startOrigin: MeetingRecordingStartOrigin = .manual,
        followUpToID: Int64? = nil,
        inheritedFolderID: Int64? = nil,
        previousMeetingNotes: String? = nil
    ) -> Bool {
        guard !isMeetingRecording(), !isStartingMeetingRecording else { return false }
        guard let meetingBackend = normalizeMeetingTranscriptionSelectionForAvailability() else {
            presentErrorAlert(
                title: "Meeting failed to start",
                message: "Download a transcription model before recording a meeting."
            )
            return false
        }
        let templateSnapshot = defaultMeetingTemplate()
        let resolvedCalendarEventID = calendarOccurrence?.eventID ?? calendarEventID
        let meetingID: Int64
        do {
            meetingID = try dictationStore.createLiveMeeting(
                title: title,
                calendarEventID: resolvedCalendarEventID,
                startTime: Date(),
                selectedTemplateID: templateSnapshot.id,
                selectedTemplateName: templateSnapshot.name,
                selectedTemplateKind: templateSnapshot.kind,
                selectedTemplatePrompt: templateSnapshot.prompt,
                folderID: inheritedFolderID,
                followUpToID: followUpToID,
                calendarOccurrence: calendarOccurrence
            )
            persistCalendarAttendees(for: calendarOccurrence, meetingID: meetingID)
            activeMeetingID = meetingID
            activeMeetingAudioWarning = nil
            syncAppState()
            if openDocument {
                showMeetingDocument(id: meetingID)
            }
        } catch {
            fputs("[meets] failed to create live meeting: \(error)\n", stderr)
            recordDiagnosticIncident(
                kind: .meetingStartFailed,
                stage: .createLiveMeeting,
                backend: meetingBackend,
                error: error
            )
            presentErrorAlert(title: "Meeting failed to start", message: error.localizedDescription)
            return false
        }
        armMeetingAutoStop(
            source: startOrigin.signalLossSource(
                explicitSource: autoStopSource,
                recentSource: recentMeetingAutoStopSource()
            ),
            response: startOrigin.signalLossResponse
        )
        isStartingMeetingRecording = true
        meetingStartMeetingID = meetingID
        updateMeetingStartStatus("Meeting transcription will start shortly.")
        indicator.setState(.preparing, config: config)
        beginMeetingActivity(reason: "Recording and transcribing a meeting")
        meetingMonitor.suppressWhileActive()
        meetingMonitor.refreshState()
        updateMeetingNotificationVisibility()

        meetingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try Task.checkCancellation()
                try await self.startMeetingRecordingWithSystemAudioRecovery(
                    title: title,
                    calendarEventID: resolvedCalendarEventID,
                    meetingID: meetingID,
                    backend: meetingBackend,
                    templateSnapshot: templateSnapshot,
                    endDate: endDate,
                    previousMeetingNotes: previousMeetingNotes
                )
            } catch is CancellationError {
                if self.meetingStartMeetingID == meetingID {
                    self.disarmMeetingAutoStop()
                    self.resolveLiveMeetingAfterStartFailure(id: meetingID)
                    self.cancelMeetingRecordingHotkeyToggleAfterFailedStart(meetingID: meetingID)
                    self.meetingMonitor.resumeAfterCooldown()
                    self.meetingMonitor.refreshState()
                    self.statusBarController?.setStatus("Idle")
                    self.statusBarController?.refresh()
                    self.indicator.setState(.idle, config: self.config)
                    self.endMeetingActivity()
                }
            } catch {
                if self.meetingStartMeetingID == meetingID {
                    fputs("[meets] failed to start meeting: \(error)\n", stderr)
                    _ = self.recordDiagnosticIncident(
                        kind: .meetingStartFailed,
                        stage: .startMeetingRecording,
                        backend: meetingBackend,
                        error: error
                    )
                    self.disarmMeetingAutoStop()
                    self.resolveLiveMeetingAfterStartFailure(id: meetingID)
                    self.cancelMeetingRecordingHotkeyToggleAfterFailedStart(meetingID: meetingID)
                    self.meetingMonitor.resumeAfterCooldown()
                    self.meetingMonitor.refreshState()
                    self.statusBarController?.setStatus("Idle")
                    self.statusBarController?.refresh()
                    self.indicator.setState(.idle, config: self.config)
                    self.endMeetingActivity()

                    self.presentMeetingStartFailureAlert(error: error)
                }
            }
            self.finishMeetingStartAttempt(meetingID: meetingID)
        }
        return true
    }

    func startQuickNoteMeeting() {
        startMeetingRecordingFromEntryPoint(title: "Meeting")
    }

    /// Whether a finished meeting can be resumed right now (used to gate the UI control too).
    func canResumeFinishedMeeting(_ meeting: MeetingRecord) -> Bool {
        MeetingResumePolicy.canResume(status: meeting.status)
    }

    /// Whether `meeting` can spawn a follow-up meeting right now (also gates the UI control).
    func canStartFollowUpMeeting(_ meeting: MeetingRecord) -> Bool {
        canStartFollowUpMeeting(status: meeting.status, isFollowUp: meeting.followUpToID != nil)
    }

    /// Same policy as `canStartFollowUpMeeting(_:)` for browser rows that only
    /// carry a lightweight index entry; `isFollowUp` comes from the row's
    /// `followUpToID`.
    func canStartFollowUpMeeting(status: MeetingStatus, isFollowUp: Bool) -> Bool {
        MeetingFollowUpPolicy.canStartFollowUp(status: status, isFollowUp: isFollowUp)
    }

    /// Starts a *new* meeting linked into `meetingID`'s thread (vs. resume, which
    /// reopens the same row). Follow-ups attach to the selected meeting, so a
    /// meeting can have more than one follow-up, but a follow-up can never be the
    /// parent of another: the guard below routes through
    /// `canStartFollowUpMeeting(_:)` and refuses follow-ups of follow-ups. The
    /// new meeting inherits the predecessor's folder and carries its notes into
    /// the summary prompt so open action items follow the thread.
    func startFollowUpMeeting(fromMeetingID meetingID: Int64) {
        guard !isMeetingRecording(), !isStartingMeetingRecording else { return }
        guard let predecessor = meeting(id: meetingID),
              canStartFollowUpMeeting(predecessor) else { return }
        startMeetingRecording(
            title: MeetingFollowUpPolicy.followUpTitle(from: predecessor.title),
            openDocument: true,
            followUpToID: predecessor.id,
            inheritedFolderID: predecessor.folderID,
            previousMeetingNotes: MeetingFollowUpPolicy.carriedContext(from: predecessor)
        )
    }

    /// Thread parent, direct child follow-ups, and total size for the
    /// detail-view breadcrumb/list.
    /// Returns nil for meetings that are not part of a follow-up thread.
    func meetingThreadContext(for meetingID: Int64) -> MeetingThreadContext? {
        do {
            guard let navigation = try dictationStore.meetingThreadNavigation(containing: meetingID) else { return nil }
            return MeetingThreadContext(
                predecessor: navigation.predecessorID.flatMap { meeting(id: $0) },
                successors: navigation.successorIDs.compactMap { meeting(id: $0) },
                count: navigation.count
            )
        } catch {
            fputs("[meets] failed to resolve meeting thread for \(meetingID): \(error)\n", stderr)
            return nil
        }
    }

    /// Reopens a finished meeting and appends more recording onto the *same* row
    /// (vs. `startMeetingRecording`, which creates a new row). Mirrors the start
    /// scaffolding but skips `createLiveMeeting` and reuses the existing meeting id.
    /// Named distinctly from `MeetingSession.resume()` (the in-session un-pause).
    func resumeFinishedMeeting(meetingID: Int64) {
        guard !isMeetingRecording(), !isStartingMeetingRecording else { return }
        guard let meeting = meeting(id: meetingID), canResumeFinishedMeeting(meeting) else { return }
        guard let meetingBackend = normalizeMeetingTranscriptionSelectionForAvailability() else {
            presentErrorAlert(
                title: "Resume failed",
                message: "Download a transcription model before recording."
            )
            return
        }

        let priorTranscript: String
        do {
            priorTranscript = try dictationStore.prepareMeetingForResume(id: meetingID)
        } catch {
            fputs("[meets] failed to prepare meeting resume \(meetingID): \(error)\n", stderr)
            presentErrorAlert(title: "Resume failed", message: error.localizedDescription)
            return
        }
        pendingResumePriorTranscript[meetingID] = priorTranscript
        let previousMeetingNotes = meeting.followUpToID
            .flatMap { self.meeting(id: $0) }
            .flatMap { MeetingFollowUpPolicy.carriedContext(from: $0) }

        // REUSE the existing row — do NOT call createLiveMeeting.
        activeMeetingID = meetingID
        activeMeetingAudioWarning = nil
        syncAppState()

        armMeetingAutoStop(
            source: MeetingRecordingStartOrigin.manual.signalLossSource(
                explicitSource: nil,
                recentSource: recentMeetingAutoStopSource()
            ),
            response: MeetingRecordingStartOrigin.manual.signalLossResponse
        )
        isStartingMeetingRecording = true
        meetingStartMeetingID = meetingID
        updateMeetingStartStatus("Resuming meeting recording…")
        indicator.setState(.preparing, config: config)
        beginMeetingActivity(reason: "Recording and transcribing a meeting")
        meetingMonitor.suppressWhileActive()
        meetingMonitor.refreshState()
        updateMeetingNotificationVisibility()

        meetingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await self.startMeetingRecordingWithSystemAudioRecovery(
                    title: meeting.title,
                    calendarEventID: meeting.calendarEventID,
                    meetingID: meetingID,
                    backend: meetingBackend,
                    templateSnapshot: self.meetingTemplateSnapshot(for: meeting),
                    endDate: nil,
                    previousMeetingNotes: previousMeetingNotes
                )
            } catch is CancellationError {
                if self.meetingStartMeetingID == meetingID {
                    self.disarmMeetingAutoStop()
                    self.resolveLiveMeetingAfterStartFailure(id: meetingID)
                    self.cancelMeetingRecordingHotkeyToggleAfterFailedStart(meetingID: meetingID)
                    self.meetingMonitor.resumeAfterCooldown()
                    self.meetingMonitor.refreshState()
                    self.statusBarController?.setStatus("Idle")
                    self.statusBarController?.refresh()
                    self.indicator.setState(.idle, config: self.config)
                    self.endMeetingActivity()
                }
            } catch {
                if self.meetingStartMeetingID == meetingID {
                    fputs("[meets] failed to resume meeting: \(error)\n", stderr)
                    self.disarmMeetingAutoStop()
                    self.resolveLiveMeetingAfterStartFailure(id: meetingID)
                    self.cancelMeetingRecordingHotkeyToggleAfterFailedStart(meetingID: meetingID)
                    self.meetingMonitor.resumeAfterCooldown()
                    self.meetingMonitor.refreshState()
                    self.statusBarController?.setStatus("Idle")
                    self.statusBarController?.refresh()
                    self.indicator.setState(.idle, config: self.config)
                    self.endMeetingActivity()
                    self.presentMeetingStartFailureAlert(error: error)
                }
            }
            self.finishMeetingStartAttempt(meetingID: meetingID)
        }
    }

    // MARK: - Audio File Import

    /// Presents a file picker and imports an audio file for offline transcription.
    func importAudioFile() {
        guard !isMeetingRecording(), !isStartingMeetingRecording else { return }
        guard normalizeMeetingTranscriptionSelectionForAvailability() != nil else {
            presentErrorAlert(
                title: "Import Failed",
                message: "Download a transcription model before importing audio files."
            )
            return
        }

        isStartingMeetingRecording = true
        let sessionID = UUID()
        importSessionID = sessionID

        importTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let sourceURL = await AudioFileImportController.selectFile() else {
                self.isStartingMeetingRecording = false
                self.importTask = nil
                self.importSessionID = nil
                self.syncAppState()
                return
            }
            await self.importAudioFile(from: sourceURL, sessionID: sessionID)
        }
    }

    /// Imports an audio file from a URL (drag-and-drop or file picker).
    func importAudioFileFromURL(_ url: URL) {
        guard !isMeetingRecording(), !isStartingMeetingRecording else { return }
        guard AudioFileImportController.isSupportedFileURL(url) else {
            presentErrorAlert(
                title: "Import Failed",
                message: "This audio file format is not supported."
            )
            return
        }
        guard normalizeMeetingTranscriptionSelectionForAvailability() != nil else {
            presentErrorAlert(
                title: "Import Failed",
                message: "Download a transcription model before importing audio files."
            )
            return
        }

        isStartingMeetingRecording = true
        let sessionID = UUID()
        importSessionID = sessionID

        importTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.importAudioFile(from: url, sessionID: sessionID)
        }
    }

    private func importAudioFile(from sourceURL: URL, sessionID: UUID) async {
        let filename = sourceURL.deletingPathExtension().lastPathComponent
        let title = filename.isEmpty ? "Imported Recording" : filename

        self.updateImportProgressStatus("Importing audio file...", sessionID: sessionID)
        self.beginMeetingActivity(reason: "Importing audio file for transcription")

        do {
            let result = try await AudioFileImportController.importAudioFile(
                sourceURL: sourceURL,
                title: title,
                controller: self,
                progress: { [weak self] status in
                    Task { @MainActor in
                        guard let self,
                              self.importSessionID == sessionID else { return }
                        self.updateImportProgressStatus(status, sessionID: sessionID)
                    }
                }
            )

            await MainActor.run {
                self.importTask = nil
                self.importSessionID = nil
                self.isStartingMeetingRecording = false
                self.updateMeetingStartStatus(nil)
                self.indicator.hideLoading()
                self.endMeetingActivity()
                self.statusBarController?.setStatus("Idle")
                self.statusBarController?.refresh()
                self.syncAppState()
                self.historyWindowController?.reload()
                self.showMeetingDocument(id: result.meetingID)
                TelemetryDeck.signal("meeting.imported")
            }
        } catch is CancellationError {
            await MainActor.run {
                self.importTask = nil
                self.importSessionID = nil
                self.isStartingMeetingRecording = false
                self.updateMeetingStartStatus(nil)
                self.indicator.hideLoading()
                self.endMeetingActivity()
                self.statusBarController?.setStatus("Idle")
                self.statusBarController?.refresh()
                self.syncAppState()
            }
        } catch {
            await MainActor.run {
                self.importTask = nil
                self.importSessionID = nil
                self.isStartingMeetingRecording = false
                self.updateMeetingStartStatus(nil)
                self.indicator.hideLoading()
                self.endMeetingActivity()
                self.statusBarController?.setStatus("Idle")
                self.statusBarController?.refresh()
                self.syncAppState()
                self.presentErrorAlert(
                    title: "Import Failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    func audioFileImportContext() -> AudioFileImportController.ImportContext {
        AudioFileImportController.ImportContext(
            config: config,
            backend: selectedMeetingTranscriptionBackend,
            transcriptionCoordinator: transcriptionCoordinator,
            templateSnapshot: defaultMeetingTemplate()
        )
    }

    func persistImportedAudioMeeting(
        title: String,
        calendarEventID: String?,
        startTime: Date,
        endTime: Date,
        rawTranscript: String,
        formattedNotes: String,
        micAudioPath: String?,
        systemAudioPath: String?,
        savedRecordingPath: String?,
        selectedTemplateID: String?,
        selectedTemplateName: String?,
        selectedTemplateKind: MeetingTemplateKind?,
        selectedTemplatePrompt: String?
    ) throws -> Int64 {
        let meetingID = try dictationStore.insertMeeting(
            title: title,
            calendarEventID: calendarEventID,
            startTime: startTime,
            endTime: endTime,
            rawTranscript: rawTranscript,
            formattedNotes: formattedNotes,
            micAudioPath: micAudioPath,
            systemAudioPath: systemAudioPath,
            savedRecordingPath: savedRecordingPath,
            selectedTemplateID: selectedTemplateID,
            selectedTemplateName: selectedTemplateName,
            selectedTemplateKind: selectedTemplateKind,
            selectedTemplatePrompt: selectedTemplatePrompt,
            source: .audioImport
        )
        meetingHookDispatcher.dispatchCompletedMeetingHook(
            meetingID: meetingID,
            completedAt: endTime,
            config: config
        )
        return meetingID
    }

    func cancelMeetingPreparation() {
        guard isStartingMeetingRecording, activeMeetingSession == nil else { return }

        if let meetingID = meetingStartMeetingID {
            // Live meeting start cancellation
            canceledMeetingStartIDs.insert(meetingID)
            meetingStartTask?.cancel()
            preparingMeetingSession?.stopStreamingPartials()
            clearLiveMeetingTranscript(ownerID: meetingID)
            resolveLiveMeetingAfterStartFailure(id: meetingID)
            cancelMeetingRecordingHotkeyToggleAfterFailedStart(meetingID: meetingID)
            meetingMonitor.resumeAfterCooldown()
            meetingMonitor.refreshState()
            meetingStartTask = nil
            meetingStartMeetingID = nil
        } else {
            // Audio import cancellation
            importTask?.cancel()
            importTask = nil
            importSessionID = nil
            indicator.hideLoading()
        }

        statusBarController?.setStatus("Idle")
        statusBarController?.refresh()
        indicator.setState(.idle, config: config)
        endMeetingActivity()
        disarmMeetingAutoStop()
        meetingStartTask = nil
        meetingStartMeetingID = nil
        isStartingMeetingRecording = false
        updateMeetingStartStatus(nil)
        updateMeetingNotificationVisibility()
        syncAppState()
    }

    private func finishMeetingStartAttempt(meetingID: Int64) {
        guard meetingStartMeetingID == meetingID else { return }
        let didStartActiveSession = activeMeetingID == meetingID && activeMeetingSession != nil
        canceledMeetingStartIDs.remove(meetingID)
        meetingStartTask = nil
        meetingStartMeetingID = nil
        isStartingMeetingRecording = false
        updateMeetingStartStatus(nil)
        updateMeetingNotificationVisibility()
        if !didStartActiveSession {
            meetingRecordingHotkeyMonitor.cancelToggleMode()
        }
        syncAppState()
    }

    private func cancelMeetingRecordingHotkeyToggleAfterFailedStart(meetingID: Int64) {
        guard meetingStartMeetingID == meetingID else { return }
        guard activeMeetingID != meetingID || activeMeetingSession == nil else { return }
        meetingRecordingHotkeyMonitor.cancelToggleMode()
    }

    private func startMeetingRecordingWithSystemAudioRecovery(
        title: String,
        calendarEventID: String?,
        meetingID: Int64,
        backend: BackendOption,
        templateSnapshot: MeetingTemplateSnapshot,
        endDate: Date?,
        previousMeetingNotes: String? = nil
    ) async throws {
        var shouldRetryAfterPermissionRequest = config.useCoreAudioTap
        statusBarController?.setStatus("Meeting transcription will start shortly.")
        statusBarController?.refresh()
        try Task.checkCancellation()
        try await transcriptionCoordinator.preloadRequired(
            backend: backend,
            includeMeetingHelpers: true,
            meetingHelperTrigger: .meetingStart,
            appleSpeechLanguage: config.resolvedAppleSpeechLanguage
        )
        try Task.checkCancellation()
        try checkMeetingStartStillCurrent(meetingID)

        while true {
            try Task.checkCancellation()
            try checkMeetingStartStillCurrent(meetingID)
            let routeSnapshot = dictationAudioRoutingController.meetingInputRouteSnapshot()
            let meetingMicRecorder = RouteAwareMeetingMicRecorder(
                routeSnapshotProvider: { routeSnapshot }
            )
            meetingMicRecorder.preferredInputDeviceID = routeSnapshot.preferredInputDeviceID
            let meetingSession = MeetingSession(
                title: title,
                calendarEventID: calendarEventID,
                backend: backend,
                runtime: runtime,
                config: config,
                templateSnapshot: templateSnapshot,
                transcriptionCoordinator: transcriptionCoordinator,
                meetingMicRecorder: meetingMicRecorder
            )
            let transcriptGeneration = UUID()
            meetingSession.previousMeetingNotes = previousMeetingNotes

            do {
                preparingMeetingSession = meetingSession
                defer {
                    if preparingMeetingSession === meetingSession {
                        preparingMeetingSession = nil
                    }
                }
                meetingSession.manualNotesProvider = { [weak self] in
                    await MainActor.run {
                        guard let self else { return nil }
                        return self.manualNotesForLiveMeeting(id: meetingID)
                    }
                }
                meetingSession.includeNotesInSummaryProvider = { [weak self] in
                    await MainActor.run {
                        guard let self else { return false }
                        return self.config.includeNotesInSummary
                    }
                }
                meetingSession.liveTitleProvider = { [weak self] in
                    await MainActor.run {
                        guard let self else { return nil }
                        return self.liveMeetingTitle(id: meetingID)
                    }
                }
                meetingSession.onChunkTranscribed = { [weak self, weak meetingSession] segments, speaker in
                    Task { @MainActor [weak self, weak meetingSession] in
                        guard let self else { return }
                        guard self.isCurrentLiveMeetingTranscriptSession(
                            ownerID: meetingID,
                            generation: transcriptGeneration
                        ) else { return }
                        let liveTranscriptStart = meetingSession?.startTime ?? Date()
                        let liveTranscriptCalendar = Calendar(identifier: .gregorian)
                        let entries = segments.compactMap { segment -> LiveTranscriptCheckpointEntry? in
                            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return nil }
                            let timestampDate = liveTranscriptStart.addingTimeInterval(segment.start)
                            let components = liveTranscriptCalendar.dateComponents([.hour, .minute, .second], from: timestampDate)
                            let timestamp = String(
                                format: "%02d:%02d:%02d",
                                components.hour ?? 0,
                                components.minute ?? 0,
                                components.second ?? 0
                            )
                            return LiveTranscriptCheckpointEntry(
                                timestampLabel: timestamp,
                                speaker: speaker,
                                startSeconds: segment.start,
                                endSeconds: segment.end,
                                text: text
                            )
                        }
                        guard !entries.isEmpty else { return }
                        do {
                            try self.dictationStore.appendLiveTranscriptCheckpoints(meetingID: meetingID, entries: entries)
                        } catch {
                            fputs("[meets] failed to checkpoint live transcript for meeting \(meetingID): \(error)\n", stderr)
                        }
                        // Live view is arrival-order closed captions. Recovery reads checkpoints sorted
                        // by segment timestamps, so the durable fallback stays temporally ordered.
                        let lines = entries.map { "[\($0.timestampLabel)] \($0.speaker): \($0.text)" }
                        self.appState.liveMeetingTranscript += lines.joined(separator: "\n") + "\n"
                        self.indicator.updateMeetingTranscript(
                            transcript: self.appState.liveMeetingTranscript,
                            partialYou: self.appState.liveMeetingPartialYou,
                            partialOthers: self.appState.liveMeetingPartialOthers
                        )
                    }
                }
                meetingSession.onPartialTranscript = { [weak self] speaker, tail in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard self.isCurrentLiveMeetingTranscriptSession(
                            ownerID: meetingID,
                            generation: transcriptGeneration
                        ) else { return }
                        if speaker == "You" {
                            guard self.appState.liveMeetingPartialYou != tail else { return }
                            self.appState.liveMeetingPartialYou = tail
                        } else {
                            guard self.appState.liveMeetingPartialOthers != tail else { return }
                            self.appState.liveMeetingPartialOthers = tail
                        }
                        self.indicator.updateMeetingTranscript(
                            transcript: self.appState.liveMeetingTranscript,
                            partialYou: self.appState.liveMeetingPartialYou,
                            partialOthers: self.appState.liveMeetingPartialOthers
                        )
                    }
                }
                appState.liveMeetingTranscriptOwnerID = meetingID
                liveMeetingTranscriptGeneration = transcriptGeneration
                appState.liveMeetingTranscript = ""
                appState.liveMeetingPartialYou = ""
                appState.liveMeetingPartialOthers = ""
                indicator.updateMeetingTranscript(
                    transcript: "",
                    partialYou: "",
                    partialOthers: ""
                )
                let micHealthWarningLock = NSLock()
                var lastForwardedMicHealthWarning: String?
                // Authorize this session's episode telemetry for its whole
                // lifetime, including the terminal event emitted after the
                // active-meeting identity has moved on during stop/discard.
                micEpisodeTelemetryGate.authorize(meetingID)
                meetingSession.onMicHealthChanged = { [weak self] snapshot in
                    let warningMessage = snapshot.warningMessage
                    micHealthWarningLock.lock()
                    let shouldForward = warningMessage != lastForwardedMicHealthWarning
                    lastForwardedMicHealthWarning = warningMessage
                    micHealthWarningLock.unlock()
                    guard shouldForward else { return }
                    Task { @MainActor in
                        guard let self,
                              self.activeMeetingID == meetingID || self.meetingStartMeetingID == meetingID else { return }
                        self.updateActiveMeetingAudioWarning(meetingID: meetingID, health: snapshot)
                    }
                }
                // Episode-level telemetry replaces per-flap error events:
                // exactly one degraded/recovered signal pair per degradation
                // episode, and an error only when the meeting ends unrecovered.
                meetingSession.onMicHealthUserMuted = { [weak self] in
                    Task { @MainActor in
                        guard let self, self.micEpisodeTelemetryGate.allows(meetingID) else { return }
                        TelemetryDeck.signal(MeetingMicHealthEpisodeKind.userMuted.rawValue, parameters: [:])
                    }
                }
                meetingSession.onSystemAudioHealthEpisode = { [weak self] event in
                    Task { @MainActor in
                        guard let self, self.micEpisodeTelemetryGate.allows(meetingID) else { return }
                        let parameters: [String: String] = [
                            "reason": event.reason,
                            "duration_ms": String(Int(event.durationSeconds * 1000)),
                            "recovery_attempts": String(event.recoveryAttempts),
                        ]
                        switch event.kind {
                        case .degraded, .recovered:
                            TelemetryDeck.signal(event.kind.rawValue, parameters: parameters)
                        case .unrecovered:
                            TelemetryDeck.signal(event.kind.rawValue, parameters: parameters)
                            self.recordDiagnosticIncident(
                                kind: .meetingSystemAudioCaptureFailed,
                                severity: .warning,
                                stage: .meetingSystemAudioCapture,
                                promptUser: false
                            )
                        }
                    }
                }
                meetingSession.onMicHealthEpisode = { [weak self] event in
                    Task { @MainActor in
                        guard let self else { return }
                        // Terminal events legitimately arrive while the meeting
                        // is stopping: stopMeetingRecording clears
                        // activeMeetingID before MeetingSession.stop() runs, so
                        // also accept the most recently stopped meeting.
                        guard self.micEpisodeTelemetryGate.allows(meetingID) else { return }
                        var parameters: [String: String] = [
                            "episode_id": event.episodeID.uuidString,
                            "reason": event.reason,
                            "state": event.state,
                            "duration_ms": String(Int(event.durationSeconds * 1000)),
                            "flap_count": String(event.flapCount),
                            "recovery_attempts": String(event.recoveryAttempts),
                            "handoff_promotions": String(event.handoffPromotions),
                            "recovery_credited": String(event.recoveryCredited),
                        ]
                        if let outcome = event.lastHandoffOutcome {
                            parameters["last_handoff_outcome"] = outcome.rawValue
                        }
                        if let recorderKind = event.context.recorderKind {
                            parameters["recorder_kind"] = recorderKind
                        }
                        if let routeCategory = event.context.routeCategory {
                            parameters["route_category"] = routeCategory
                        }
                        if let resolved = event.context.selectedInputResolved {
                            parameters["selected_input_resolved"] = String(resolved)
                        }
                        switch event.kind {
                        case .degraded, .recovered:
                            TelemetryDeck.signal(event.kind.rawValue, parameters: parameters)
                        case .unrecovered:
                            // Rich episode signal with full classification, plus
                            // the legacy error incident for dashboard continuity.
                            TelemetryDeck.signal(event.kind.rawValue, parameters: parameters)
                            self.recordDiagnosticIncident(
                                kind: .meetingMicrophoneCaptureFailed,
                                severity: .warning,
                                stage: .meetingMicrophoneCapture,
                                promptUser: false
                            )
                        case .userMuted:
                            // Emitted via onMicHealthUserMuted, not the episode
                            // stream; nothing to do here.
                            break
                        }
                    }
                }
                try await meetingSession.start()
                if Task.isCancelled || canceledMeetingStartIDs.contains(meetingID) {
                    throw CancellationError()
                }
                activeMeetingSession = meetingSession
                activeMeetingID = meetingID
                activeMeetingAutoStop.markRecordingStarted(now: Date())
                meetingMonitor.suppressWhileActive()
                meetingMonitor.refreshState()
                statusBarController?.setStatus("Meeting: \(title)")
                indicator.powerProvider = { [weak meetingSession] in
                    meetingSession?.currentPower() ?? -160
                }
                indicator.setMeetingRecording(true, config: config)
                statusBarController?.refresh()
                syncAppState()
                scheduleMeetingEndNotification(endDate: endDate, title: title)
                return
            } catch {
                clearLiveMeetingTranscript(ownerID: meetingID, generation: transcriptGeneration)
                meetingSession.discard()
                guard shouldRetryAfterPermissionRequest,
                      case .tapCreationFailed = error as? CoreAudioSystemRecorder.RecorderError else {
                    throw error
                }

                shouldRetryAfterPermissionRequest = false
                try Task.checkCancellation()
                try checkMeetingStartStillCurrent(meetingID)
                updateMeetingStartStatus("Requesting system audio permission...")
                statusBarController?.setStatus("Requesting system audio permission...")
                statusBarController?.refresh()
                let granted = await CoreAudioSystemRecorder.requestSystemAudioAccess()
                try Task.checkCancellation()
                try checkMeetingStartStillCurrent(meetingID)
                if granted {
                    updateMeetingStartStatus("Retrying meeting start...")
                    statusBarController?.setStatus("Retrying meeting start...")
                    statusBarController?.refresh()
                    continue
                }
                throw error
            }
        }
    }

    private func checkMeetingStartStillCurrent(_ meetingID: Int64) throws {
        if canceledMeetingStartIDs.contains(meetingID) || meetingStartMeetingID != meetingID {
            throw CancellationError()
        }
    }

    /// Open meeting URL, start transcription, schedule end notification, and suppress detection.
    /// Single entry point for "Join & Transcribe" from both notification panel and Coming Up section.
    func joinAndRecord(
        title: String,
        meetingURL: URL,
        endDate: Date?,
        calendarOccurrence: CalendarOccurrenceReference? = nil,
        presentation: MeetingStartPresentation = .foregroundNotes
    ) {
        NSWorkspace.shared.open(meetingURL)
        startMeetingRecordingFromEntryPoint(
            title: title,
            calendarOccurrence: calendarOccurrence,
            endDate: endDate,
            autoStopSource: MeetingAutoStopSource(meetingURL: meetingURL),
            presentation: presentation,
            startOrigin: .joinAndRecord
        )
    }

    /// Start transcription without opening the meeting URL — for people who join calls in
    /// a separate browser or client.
    /// Single entry point for "Transcribe Only" from both notification panel and Coming Up section.
    func recordOnly(
        title: String,
        meetingURL: URL?,
        endDate: Date?,
        calendarOccurrence: CalendarOccurrenceReference? = nil,
        presentation: MeetingStartPresentation = .foregroundNotes
    ) {
        startMeetingRecordingFromEntryPoint(
            title: title,
            calendarOccurrence: calendarOccurrence,
            endDate: endDate,
            autoStopSource: meetingURL.flatMap { MeetingAutoStopSource(meetingURL: $0) },
            presentation: presentation,
            startOrigin: .scheduledMeetingPrompt
        )
    }

    /// Open meeting URL and suppress detection for the event duration.
    /// Single entry point for "Join Only" from both notification panel and Coming Up section.
    func joinOnly(meetingURL: URL, endDate: Date?) {
        let remaining = endDate.map { max($0.timeIntervalSinceNow, 120) } ?? 120
        meetingMonitor.suppress(for: remaining)
        meetingMonitor.refreshState()
        NSWorkspace.shared.open(meetingURL)
    }

    enum MeetingDiscardResolution: Equatable {
        case discardRecording
        case keepManualNotes
        case deleteDraft
    }

    private struct MeetingDiscardAccessory {
        let view: NSView
        let manualNotesCheckbox: NSButton
    }

    private final class MeetingDiscardAccessoryView: NSView {
        var titleUpdater: AnyObject?
    }

    private final class MeetingDiscardButtonTitleUpdater: NSObject {
        weak var discardButton: NSButton?

        init(discardButton: NSButton?) {
            self.discardButton = discardButton
        }

        @MainActor @objc func manualNotesCheckboxChanged(_ sender: NSButton) {
            discardButton?.title = sender.state == .on ? "Discard" : "Discard Recording"
        }
    }

    @objc func discardMeetingWithConfirmation() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        let hasManualNotes = activeMeetingID.map { id in
            !manualNotesForLiveMeeting(id: id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false
        alert.messageText = "Discard recording?"
        alert.alertStyle = .warning
        var manualNotesCheckbox: NSButton?
        if hasManualNotes {
            alert.informativeText = "This will stop the meeting. Choose whether to delete the written notes too."
            let accessory = Self.makeDiscardMeetingAccessoryView()
            manualNotesCheckbox = accessory.manualNotesCheckbox
            alert.accessoryView = accessory.view
            alert.addButton(withTitle: "Discard Recording")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            let titleUpdater = MeetingDiscardButtonTitleUpdater(discardButton: alert.buttons.first)
            manualNotesCheckbox?.target = titleUpdater
            manualNotesCheckbox?.action = #selector(MeetingDiscardButtonTitleUpdater.manualNotesCheckboxChanged(_:))
            (accessory.view as? MeetingDiscardAccessoryView)?.titleUpdater = titleUpdater
        } else {
            alert.informativeText = "This will stop the meeting recording and delete all captured audio. This cannot be undone."
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
        }
        presentDiscardMeetingAlert(alert, manualNotesCheckbox: manualNotesCheckbox)
    }

    private static func makeDiscardMeetingAccessoryView() -> MeetingDiscardAccessory {
        let label = NSTextField(labelWithString: "Will delete:")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .secondaryLabelColor

        let recordingCheckbox = NSButton(checkboxWithTitle: "Recording audio", target: nil, action: nil)
        recordingCheckbox.state = .on
        recordingCheckbox.isEnabled = false

        let notesCheckbox = NSButton(checkboxWithTitle: "Manual notes", target: nil, action: nil)
        notesCheckbox.state = .off

        let container = MeetingDiscardAccessoryView(frame: NSRect(x: 0, y: 0, width: 230, height: 76))
        let stack = NSStackView(views: [label, recordingCheckbox, notesCheckbox])
        stack.frame = container.bounds
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.autoresizingMask = [.width, .height]
        container.addSubview(stack)
        return MeetingDiscardAccessory(view: container, manualNotesCheckbox: notesCheckbox)
    }

    private func presentDiscardMeetingAlert(_ alert: NSAlert, manualNotesCheckbox: NSButton?, attempt: Int = 0) {
        if let window = confirmationAnchorWindow() {
            beginDiscardMeetingAlert(alert, for: window, manualNotesCheckbox: manualNotesCheckbox)
            return
        }

        showActiveMeetingDocumentIfNeeded()
        historyWindowController?.show()
        if let window = confirmationAnchorWindow() {
            beginDiscardMeetingAlert(alert, for: window, manualNotesCheckbox: manualNotesCheckbox)
            return
        }

        guard attempt < 20 else {
            NSLog("Unable to present discard meeting confirmation: no anchor window became available")
            NSSound.beep()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, alert] in
            self?.presentDiscardMeetingAlert(alert, manualNotesCheckbox: manualNotesCheckbox, attempt: attempt + 1)
        }
    }

    private func beginDiscardMeetingAlert(_ alert: NSAlert, for window: NSWindow, manualNotesCheckbox: NSButton?) {
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let resolution = Self.discardResolution(
                for: response,
                deleteManualNotes: manualNotesCheckbox.map { $0.state == .on }
            ) else { return }
            Task { @MainActor [weak self] in
                self?.discardMeetingRecording(resolution: resolution)
            }
        }
    }

    static func discardResolution(for response: NSApplication.ModalResponse, deleteManualNotes: Bool?) -> MeetingDiscardResolution? {
        guard response == .alertFirstButtonReturn else { return nil }
        if let deleteManualNotes {
            return deleteManualNotes ? .deleteDraft : .keepManualNotes
        }
        return .discardRecording
    }

    private func confirmationAnchorWindow() -> NSWindow? {
        NSApp.windows.first { window in
            isUsableSheetHost(window, allowPanel: false)
        } ?? NSApp.windows.first { window in
            isUsableSheetHost(window, allowPanel: true)
        }
    }

    private func isUsableSheetHost(_ window: NSWindow, allowPanel: Bool) -> Bool {
        window.isVisible &&
            !window.isMiniaturized &&
            window.canBecomeKey &&
            (allowPanel || !(window is NSPanel))
    }

    private func discardMeetingRecording(resolution: MeetingDiscardResolution = .discardRecording) {
        meetingRecordingHotkeyMonitor.cancelToggleMode()
        clearLiveMeetingTranscript()
        guard let sessionToDiscard = activeMeetingSession else {
            // Fallback recovery: reset indicator if session is nil
            guard !isStartingMeetingRecording else { return }
            disarmMeetingAutoStop()
            indicator.setMeetingRecording(false, config: config)
            if let meetingID = activeMeetingID {
                micEpisodeTelemetryGate.authorize(meetingID)
                activeMeetingID = nil
                if activeMeetingAudioWarning?.meetingID == meetingID {
                    activeMeetingAudioWarning = nil
                }
                resolveLiveMeetingAfterDiscard(id: meetingID, resolution: resolution)
            } else {
                finishDiscardMeetingRecording()
            }
            return
        }
        sessionToDiscard.discard()
        disarmMeetingAutoStop()
        self.activeMeetingSession = nil
        indicator.setMeetingRecording(false, config: config)
        if let meetingID = activeMeetingID {
            // Preserve identity for episode terminal telemetry emitted by the
            // discarding session (it hops to the main actor asynchronously).
            micEpisodeTelemetryGate.authorize(meetingID)
            activeMeetingID = nil
            if activeMeetingAudioWarning?.meetingID == meetingID {
                activeMeetingAudioWarning = nil
            }
            resolveLiveMeetingAfterDiscard(id: meetingID, resolution: resolution)
        } else {
            finishDiscardMeetingRecording()
        }
    }

    private func finishDiscardMeetingRecording() {
        isStoppingMeetingRecording = false
        endMeetingActivity()
        meetingMonitor.resumeAfterCooldown()
        meetingMonitor.refreshState()
        indicator.setState(.idle, config: config)
        statusBarController?.refresh()
        syncAppState()
        updateMeetingNotificationVisibility()
    }

    private func resolveLiveMeetingAfterDiscard(id: Int64, resolution: MeetingDiscardResolution) {
        if restoreResumedMeetingIfNeeded(id: id) {
            finishDiscardMeetingRecording()
            return
        }

        switch resolution {
        case .keepManualNotes:
            keepManualNotesAfterDiscard(id: id)
        case .deleteDraft:
            deleteManualNotesDraftAfterDiscard(id: id)
        case .discardRecording:
            let manualNotes = manualNotesForLiveMeeting(id: id)
            if manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                deleteManualNotesDraftAfterDiscard(id: id)
            } else {
                // Defensive fallback: the UI routes manual-note meetings through
                // explicit Keep Notes/Delete Draft choices. If notes appear after
                // the simpler discard alert was built, preserve user-written text.
                keepManualNotesAfterDiscard(id: id)
            }
        }
        finishDiscardMeetingRecording()
    }

    private func deleteManualNotesDraftAfterDiscard(id: Int64) {
        deleteMeetingDraftAndScheduleSync(id: id)
        clearCachedMeetingManualNotes(id: id)
        clearCachedMeetingTitle(id: id)
        if appState.selectedMeetingID == id {
            appState.selectedMeetingID = nil
            appState.selectedMeetingRecord = nil
            appState.meetingsNavigationState = .browser
        }
    }

    private func keepManualNotesAfterDiscard(id: Int64) {
        flushCachedMeetingTitle(id: id)
        flushCachedMeetingManualNotes(id: id, sync: false)
        updateMeetingStatusAndScheduleSync(id: id, status: .noteOnly)
        clearCachedMeetingManualNotes(id: id)
        clearCachedMeetingTitle(id: id)
    }

    /// If `id` is a resume in flight, restore it to its prior `.completed` state
    /// instead of deleting/failing it — the meeting pre-existed and must not be lost.
    /// Returns true when it handled the meeting.
    @discardableResult
    private func restoreResumedMeetingIfNeeded(id: Int64) -> Bool {
        let hadPendingResume = pendingResumePriorTranscript[id] != nil
        do {
            let restored = try dictationStore.restoreResumedMeetingIfNeeded(id: id)
            guard restored || hadPendingResume else { return false }
            if restored {
            } else {
                updateMeetingStatusAndScheduleSync(id: id, status: .completed)
            }
        } catch {
            fputs("[meets] failed to restore resumed meeting \(id): \(error)\n", stderr)
            guard hadPendingResume else { return false }
            updateMeetingStatusAndScheduleSync(id: id, status: .completed)
        }
        pendingResumePriorTranscript[id] = nil
        if activeMeetingID == id {
            activeMeetingID = nil
        }
        if activeMeetingAudioWarning?.meetingID == id {
            activeMeetingAudioWarning = nil
        }
        syncAppState()
        return true
    }

    private func resolveLiveMeetingAfterStartFailure(id: Int64) {
        if restoreResumedMeetingIfNeeded(id: id) { return }
        let manualNotes = manualNotesForLiveMeeting(id: id)
        if manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deleteMeetingDraftAndScheduleSync(id: id)
            clearCachedMeetingManualNotes(id: id)
            clearCachedMeetingTitle(id: id)
            if appState.selectedMeetingID == id {
                appState.selectedMeetingID = nil
                appState.selectedMeetingRecord = nil
                appState.meetingsNavigationState = .browser
            }
        } else {
            flushCachedMeetingTitle(id: id)
            flushCachedMeetingManualNotes(id: id, sync: false)
            updateMeetingStatusAndScheduleSync(id: id, status: .failed)
            clearCachedMeetingManualNotes(id: id)
            clearCachedMeetingTitle(id: id)
        }
        if activeMeetingID == id {
            activeMeetingID = nil
        }
        if activeMeetingAudioWarning?.meetingID == id {
            activeMeetingAudioWarning = nil
        }
        syncAppState()
    }

    private func resolveLiveMeetingAfterStopFailure(id: Int64) {
        if restoreResumedMeetingIfNeeded(id: id) { return }
        let manualNotes = manualNotesForLiveMeeting(id: id)
        if manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deleteMeetingDraftAndScheduleSync(id: id)
            clearCachedMeetingManualNotes(id: id)
            clearCachedMeetingTitle(id: id)
            if appState.selectedMeetingID == id {
                appState.selectedMeetingID = nil
                appState.selectedMeetingRecord = nil
                appState.meetingsNavigationState = .browser
            }
        } else {
            flushCachedMeetingTitle(id: id)
            flushCachedMeetingManualNotes(id: id, sync: false)
            updateMeetingStatusAndScheduleSync(id: id, status: .failed)
            clearCachedMeetingManualNotes(id: id)
            clearCachedMeetingTitle(id: id)
        }
        if activeMeetingAudioWarning?.meetingID == id {
            activeMeetingAudioWarning = nil
        }
        syncAppState()
    }

    private func deleteMeetingDraftAndScheduleSync(id: Int64) {
        do {
            try dictationStore.deleteMeeting(id: id)
        } catch {
            fputs("[meets] failed to delete meeting draft \(id): \(error)\n", stderr)
        }
    }

    private func updateMeetingStatusAndScheduleSync(id: Int64, status: MeetingStatus) {
        do {
            try updateMeetingStatusAndScheduleSyncThrowing(id: id, status: status)
        } catch {
            fputs("[meets] failed to update meeting \(id) status to \(status.rawValue): \(error)\n", stderr)
        }
    }

    private func updateMeetingStatusAndScheduleSyncThrowing(id: Int64, status: MeetingStatus) throws {
        try dictationStore.updateMeetingStatus(id: id, status: status)
    }

    func openManualDiagnosticReport() {
        diagnosticIncidentReporter.recordManualReport()
    }

    func setAutomaticDiagnosticIssuePrompts(_ enabled: Bool) {
        updateConfig { $0.enableAutomaticDiagnosticIssuePrompts = enabled }
        if !enabled,
           let pending = appState.pendingDiagnosticIncident,
           pending.kind != .manualReport {
            diagnosticIncidentReporter.dismissCurrentPrompt()
        }
    }

    func dismissDiagnosticIncidentPrompt() {
        diagnosticIncidentReporter.dismissCurrentPrompt()
    }

    func openDiagnosticIncidentIssue(_ incident: DiagnosticIncident) {
        let url = incident.githubIssueURL ?? DiagnosticIncident.githubIssueFallbackURL
        diagnosticIncidentReporter.dismissCurrentPrompt()
        DispatchQueue.main.async {
            guard let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
                NSWorkspace.shared.open(url)
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration) { _, error in
                if let error {
                    fputs("[meets] failed to open diagnostic issue URL with activation: \(error)\n", stderr)
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    @discardableResult
    private func recordDiagnosticIncident(
        kind: DiagnosticIncidentKind,
        severity: DiagnosticIncidentSeverity = .error,
        stage: DiagnosticIncidentStage,
        backend: BackendOption? = nil,
        error: Error? = nil,
        promptUser: Bool = true
    ) -> DiagnosticIncident {
        diagnosticIncidentReporter.record(
            kind: kind,
            severity: severity,
            stage: stage,
            backend: backend,
            error: error,
            promptUser: promptUser
        )
    }

    private func updateActiveMeetingAudioWarning(meetingID: Int64, health: MeetingMicHealthSnapshot) {
        let nextWarning = health.warningMessage.map {
            ActiveMeetingAudioWarning(meetingID: meetingID, message: $0)
        }
        guard activeMeetingAudioWarning != nextWarning else { return }
        activeMeetingAudioWarning = nextWarning
        syncAppState()
    }

    func stopMeetingRecording() {
        meetingRecordingHotkeyMonitor.cancelToggleMode()
        guard !isStoppingMeetingRecording else { return }
        guard let sessionToStop = activeMeetingSession else {
            // Fallback recovery: reset indicator if session is nil
            guard !isStartingMeetingRecording else { return }
            disarmMeetingAutoStop()
            if let activeMeetingID {
                resolveLiveMeetingAfterStopFailure(id: activeMeetingID)
                if activeMeetingAudioWarning?.meetingID == activeMeetingID {
                    activeMeetingAudioWarning = nil
                }
                self.activeMeetingID = nil
            }
            indicator.setMeetingRecording(false, config: config)
            isStoppingMeetingRecording = false
            endMeetingActivity()
            indicator.setState(.idle, config: config)
            return
        }
        isStoppingMeetingRecording = true
        disarmMeetingAutoStop()
        meetingEndTimer?.invalidate()
        meetingEndTimer = nil
        meetingNotification.close()
        let liveMeetingID = activeMeetingID
        if let liveMeetingID {
            // Freeze the manual-notes value this stop will summarize AND
            // persist. The live cache is a UI-coalesced debounce target and
            // can still be mutated while transcription runs below; the
            // session's stop flow must read one immutable snapshot or the
            // typed notes can vanish from both the summary and the saved row.
            sessionToStop.stopManualNotesSnapshot = manualNotesForLiveMeeting(id: liveMeetingID)
            // Freeze the include-notes preference at the same moment; the live
            // meeting's checkbox can still be toggled while transcription runs.
            sessionToStop.includeNotesInSummarySnapshot = config.includeNotesInSummary
            flushCachedMeetingManualNotes(id: liveMeetingID, sync: false)
            flushCachedMeetingTitle(id: liveMeetingID)
            updateMeetingStatusAndScheduleSync(id: liveMeetingID, status: .processing)
            syncAppState()
        }
        indicator.setMeetingRecording(false, config: config)
        let processingID = UUID()
        setMeetingProcessingStage(.transcribingAudio, processingID: processingID)
        sessionToStop.onProgress = { [weak self] stage in
            Task { @MainActor [weak self] in
                guard let self, self.meetingProcessingStages[processingID] != nil else { return }
                self.setMeetingProcessingStage(
                    stage,
                    processingID: processingID,
                    updatePresentation: !self.isMeetingRecording() && !self.isStartingMeetingRecording
                )
            }
        }

        // Unblock new recordings immediately — transcription runs in the background
        activeMeetingSession = nil
        if let activeMeetingID {
            micEpisodeTelemetryGate.authorize(activeMeetingID)
        }
        activeMeetingID = nil
        if let liveMeetingID, activeMeetingAudioWarning?.meetingID == liveMeetingID {
            activeMeetingAudioWarning = nil
        }
        isStoppingMeetingRecording = false
        backgroundMeetingProcessingCount += 1
        meetingMonitor.resumeAfterCooldown()
        meetingMonitor.refreshState()

        Task { [weak self] in
            guard let self else { return }
            var meetingTitle = "Meeting"
            var completedMeetingID: Int64?
            var meetingResult: MeetingSessionResult?
            var failedLiveMeetingID: Int64?
            do {
                let stopped = try await sessionToStop.stop()
                let result = await self.mergedResumeResult(for: stopped, meetingID: liveMeetingID)
                meetingResult = result
                meetingTitle = result.title
                await MainActor.run {
                    self.setMeetingProcessingStatus("Finalizing")
                }
                let recordingSaveDecision = await self.recordingSaveDecision(for: result)
                let preparedRecordingSave = await self.prepareMeetingRecordingSave(
                    for: result,
                    saveDecision: recordingSaveDecision
                )
                let persistenceResult = try await MainActor.run {
                    try self.persistCompletedMeetingResultAndDispatchHook(
                        result,
                        existingMeetingID: liveMeetingID,
                        preparedRecordingSave: preparedRecordingSave
                    )
                }
                completedMeetingID = persistenceResult.meetingID
                if let recordingSaveError = persistenceResult.recordingSaveError {
                    await MainActor.run {
                        self.recordDiagnosticIncident(
                            kind: .meetingRecordingSaveFailed,
                            stage: .saveMeetingRecording,
                            backend: self.selectedMeetingTranscriptionBackend,
                            error: recordingSaveError
                        )
                        self.presentErrorAlert(title: "Meeting Recording", message: recordingSaveError.localizedDescription)
                    }
                }
            } catch {
                fputs("[meets] meeting transcription failed: \(error)\n", stderr)
                await MainActor.run {
                    _ = self.recordDiagnosticIncident(
                        kind: .meetingProcessingFailed,
                        stage: .meetingStopProcessing,
                        backend: self.selectedMeetingTranscriptionBackend,
                        error: error
                    )
                }
                let message: String
                if let lifecycleError = error as? MeetingLifecycleError {
                    message = lifecycleError.localizedDescription
                } else {
                    message = error.localizedDescription
                }
                failedLiveMeetingID = liveMeetingID
                await MainActor.run {
                    self.presentErrorAlert(title: "Meeting Recording", message: message)
                }
            }
            await MainActor.run {
                self.removeMeetingProcessing(processingID: processingID)
                self.backgroundMeetingProcessingCount -= 1
                if let failedLiveMeetingID {
                    self.resolveLiveMeetingAfterStopFailure(id: failedLiveMeetingID)
                } else if let liveMeetingID {
                    // Resume merged + persisted successfully — drop the prior-transcript marker.
                    self.pendingResumePriorTranscript[liveMeetingID] = nil
                }
                if !self.isMeetingRecording()
                    && !self.isStartingMeetingRecording
                    && self.backgroundMeetingProcessingCount == 0 {
                    self.statusBarController?.setStatus("Idle")
                    self.statusBarController?.refresh()
                    self.indicator.setState(.idle, config: self.config)
                }
                self.endMeetingActivity()
                self.historyWindowController?.reload()
                self.syncAppState()
                self.clearLiveMeetingTranscript(ownerID: liveMeetingID)
                if let meetingResult {
                    self.cleanupTemporaryMeetingAudioFiles(for: meetingResult)
                }
                TelemetryDeck.signal("meeting.completed")

                self.enqueueOrShowMeetingCompletionNotification(
                    meetingID: completedMeetingID,
                    title: meetingTitle
                )
                self.updateMeetingNotificationVisibility()
            }
        }
    }

    func revealMeetingRecordingInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            presentErrorAlert(
                title: "Recording Not Found",
                message: "The saved meeting recording is no longer available on disk."
            )
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func persistCompletedMeetingResult(
        _ result: MeetingSessionResult,
        existingMeetingID: Int64? = nil,
        preparedRecordingSave: PreparedMeetingRecordingSave
    ) throws -> CompletedMeetingPersistenceResult {
        let meetingID: Int64
        let savedRecordingPath = preparedRecordingSave.path
        let recordingSaveError = preparedRecordingSave.error
        // The snapshot captured at stop time is the authoritative raw-notes
        // value: it is what the summary fused, so the saved row must match or
        // the typed notes vanish from the completed meeting.
        let finalManualNotes = result.manualNotes

        if let existingMeetingID {
            let persistedTitle = completedLiveMeetingTitle(for: result, existingMeetingID: existingMeetingID)
            let durationOverride = pendingResumePriorTranscript[existingMeetingID] == nil
                ? nil
                : result.durationSeconds
            try dictationStore.completeLiveMeeting(
                id: existingMeetingID,
                title: persistedTitle,
                calendarEventID: result.calendarEventID,
                startTime: result.startTime,
                endTime: result.endTime,
                durationSeconds: durationOverride,
                rawTranscript: result.rawTranscript,
                formattedNotes: result.formattedNotes,
                manualNotes: finalManualNotes,
                micAudioPath: nil,
                systemAudioPath: nil,
                savedRecordingPath: savedRecordingPath,
                selectedTemplateID: result.templateSnapshot.id,
                selectedTemplateName: result.templateSnapshot.name,
                selectedTemplateKind: result.templateSnapshot.kind,
                selectedTemplatePrompt: result.templateSnapshot.prompt,
                visualContext: result.visualContext
            )
            meetingID = existingMeetingID
            clearCachedMeetingManualNotes(id: existingMeetingID)
            clearCachedMeetingTitle(id: existingMeetingID)
        } else {
            meetingID = try dictationStore.insertMeeting(
                title: result.title,
                calendarEventID: result.calendarEventID,
                startTime: result.startTime,
                endTime: result.endTime,
                rawTranscript: result.rawTranscript,
                formattedNotes: result.formattedNotes,
                micAudioPath: nil,
                systemAudioPath: nil,
                savedRecordingPath: savedRecordingPath,
                selectedTemplateID: result.templateSnapshot.id,
                selectedTemplateName: result.templateSnapshot.name,
                selectedTemplateKind: result.templateSnapshot.kind,
                selectedTemplatePrompt: result.templateSnapshot.prompt,
                visualContext: result.visualContext
            )
        }
        try? dictationStore.replaceTranscriptWords(meetingID: meetingID, words: result.transcriptWords)
        return CompletedMeetingPersistenceResult(meetingID: meetingID, recordingSaveError: recordingSaveError)
    }

    private func liveMeetingTitle(id: Int64) -> String? {
        if let cached = liveMeetingTitleCache[id] {
            return cached
        }
        return try? dictationStore.meeting(id: id)?.title
    }

    private func activeMeetingDisplayTitle() -> String {
        guard let activeMeetingID,
              let title = liveMeetingTitle(id: activeMeetingID)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return "Meeting"
        }
        return title
    }

    private func completedLiveMeetingTitle(for result: MeetingSessionResult, existingMeetingID: Int64) -> String {
        guard let liveTitle = liveMeetingTitle(id: existingMeetingID)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !liveTitle.isEmpty,
              liveTitle != result.originalTitle.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return result.title
        }
        return liveTitle
    }

    func persistCompletedMeetingResultAndDispatchHook(
        _ result: MeetingSessionResult,
        existingMeetingID: Int64? = nil,
        preparedRecordingSave: PreparedMeetingRecordingSave
    ) throws -> CompletedMeetingPersistenceResult {
        let persistenceResult = try persistCompletedMeetingResult(
            result,
            existingMeetingID: existingMeetingID,
            preparedRecordingSave: preparedRecordingSave
        )
        meetingHookDispatcher.dispatchCompletedMeetingHook(
            meetingID: persistenceResult.meetingID,
            completedAt: result.endTime,
            config: config
        )
        if config.autoExportMarkdownEnabled || config.cloudSyncEnabled {
            do {
                if let record = try dictationStore.meeting(id: persistenceResult.meetingID) {
                    if config.autoExportMarkdownEnabled {
                        meetingMarkdownAutoExporter.exportIfConfigured(meeting: record, config: config)
                    }
                    if config.cloudSyncEnabled {
                        let cloudSyncConfig = config
                        Task { [weak self] in
                            await self?.cloudMirror.mirror(meeting: record, config: cloudSyncConfig)
                        }
                    }
                } else {
                    meetingMarkdownAutoExporter.recordMeetingLookupFailure(
                        meetingID: persistenceResult.meetingID,
                        error: nil
                    )
                }
            } catch {
                meetingMarkdownAutoExporter.recordMeetingLookupFailure(
                    meetingID: persistenceResult.meetingID,
                    error: error
                )
            }
        }
        return persistenceResult
    }

    /// For a resumed meeting, concatenates the prior transcript with the newly
    /// recorded one and regenerates the summary when new transcript content exists.
    /// Returns the stop result unchanged when this meeting is not a resume. Does not
    /// clear the pending-transcript marker — that happens on successful persist or
    /// failure restore.
    private func mergedResumeResult(
        for result: MeetingSessionResult,
        meetingID: Int64?
    ) async -> MeetingSessionResult {
        guard let meetingID,
              let prior = pendingResumePriorTranscript[meetingID] else {
            return result
        }
        // The stop-time snapshot captured on the session is authoritative for
        // what was typed during this resumed session. Fall back to the live
        // cache (which may still hold an earlier value for direct callers).
        let manualNotes = result.manualNotes.isEmpty
            ? manualNotesForLiveMeeting(id: meetingID)
            : result.manualNotes
        let combined = MeetingResumePolicy.combinedResumeTranscript(
            prior: prior,
            new: result.rawTranscript
        )
        let originalMeeting = meeting(id: meetingID)
        let originalStart = originalMeeting
            .flatMap { ISO8601DateFormatter().date(from: $0.startTime) }
        let accumulatedDuration = (originalMeeting?.durationSeconds ?? 0) + result.durationSeconds
        // Include notes only when the persisted meeting opted in.
        let includeNotes = config.includeNotesInSummary
        // Persisting the resumed session's context alone would overwrite what
        // earlier sessions of this meeting captured.
        let mergedVisualContext = MeetingResumePolicy.combinedResumeVisualContext(
            prior: originalMeeting?.visualContext,
            new: result.visualContext
        )

        guard MeetingResumePolicy.hasNewTranscriptContent(prior: prior, new: result.rawTranscript) else {
            return result.overriding(
                startTime: originalStart,
                durationSeconds: accumulatedDuration,
                rawTranscript: combined,
                formattedNotes: originalMeeting?.formattedNotes ?? result.formattedNotes,
                visualContext: mergedVisualContext
            )
        }

        let regeneratedNotes: String
        do {
            regeneratedNotes = try await MeetingSummaryClient.summarize(
                transcript: combined,
                meetingTitle: result.title,
                config: config,
                template: result.templateSnapshot,
                existingNotes: nil,
                manualNotesToRetain: includeNotes ? manualNotes : nil,
                visualContext: mergedVisualContext
            )
        } catch {
            fputs("[meets] resume summary regeneration failed: \(error.localizedDescription)\n", stderr)
            regeneratedNotes = MeetingSummaryClient.summaryFailureNotes(
                transcript: combined,
                meetingTitle: result.title,
                error: error,
                manualNotes: includeNotes ? manualNotes : nil
            )
        }
        return result.overriding(
            startTime: originalStart,
            durationSeconds: accumulatedDuration,
            rawTranscript: combined,
            formattedNotes: regeneratedNotes,
            visualContext: mergedVisualContext
        )
    }

    private func meetingRecordingSavePlan(
        for result: MeetingSessionResult,
        saveDecision: Bool? = nil
    ) -> MeetingRecordingSavePlan {
        let shouldSave: Bool
        if let saveDecision {
            shouldSave = saveDecision
        } else {
            switch config.meetingRecordingSavePolicy {
            case .never:
                shouldSave = false
            case .always:
                shouldSave = true
            case .prompt:
                shouldSave = result.retainedRecordingError != nil
            }
        }

        guard shouldSave else {
            if let retainedRecordingURL = result.retainedRecordingURL {
                return .discard(tempURL: retainedRecordingURL)
            }
            return .none
        }

        if let retainedRecordingError = result.retainedRecordingError {
            return .failed(.failedToSaveRecording(underlying: retainedRecordingError))
        }

        guard let retainedRecordingURL = result.retainedRecordingURL else {
            return .none
        }

        return .save(MeetingRecordingSaveRequest(
            tempURL: retainedRecordingURL,
            meetingTitle: result.title,
            startedAt: result.startTime,
            supportDirectory: configStore.supportDirectory(),
            fileFormat: config.resolvedMeetingRecordingFileFormat
        ))
    }

    func prepareMeetingRecordingSave(
        for result: MeetingSessionResult,
        saveDecision: Bool? = nil
    ) async -> PreparedMeetingRecordingSave {
        let plan = meetingRecordingSavePlan(for: result, saveDecision: saveDecision)
        return await Self.prepareMeetingRecordingSave(plan)
    }

    private nonisolated static func prepareMeetingRecordingSave(
        _ plan: MeetingRecordingSavePlan
    ) async -> PreparedMeetingRecordingSave {
        switch plan {
        case .none:
            return PreparedMeetingRecordingSave(path: nil, error: nil)
        case .discard(let tempURL):
            try? FileManager.default.removeItem(at: tempURL)
            return PreparedMeetingRecordingSave(path: nil, error: nil)
        case .failed(let error):
            return PreparedMeetingRecordingSave(path: nil, error: error)
        case .save(let request):
            do {
                let outputURL = try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
                    from: request.tempURL,
                    meetingTitle: request.meetingTitle,
                    startedAt: request.startedAt,
                    supportDirectory: request.supportDirectory,
                    fileFormat: request.fileFormat
                )
                return PreparedMeetingRecordingSave(path: outputURL.path, error: nil)
            } catch {
                return PreparedMeetingRecordingSave(
                    path: nil,
                    error: .failedToSaveRecording(underlying: error)
                )
            }
        }

    }

    private func cleanupTemporaryMeetingAudioFiles(for result: MeetingSessionResult) {
        if let retainedRecordingURL = result.retainedRecordingURL {
            try? FileManager.default.removeItem(at: retainedRecordingURL)
        }
        if let systemRecordingURL = result.systemRecordingURL {
            try? FileManager.default.removeItem(at: systemRecordingURL)
        }
    }

    private func cleanupTemporaryDirectory(named directoryName: String, logDescription: String) {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for file in files {
            try? FileManager.default.removeItem(at: file)
        }

        if !files.isEmpty {
            fputs("[meets] cleaned up \(files.count) \(logDescription)\n", stderr)
        }
    }

    func cleanupHistoricalMeetingWaveformCacheFilesIfNeeded() {
        guard !config.waveformCacheOrphanCleanupMigrationApplied else { return }
        guard cleanupOrphanedMeetingWaveformCacheFiles() else { return }
        guard cleanupLegacyJSONMeetingWaveformCacheFiles() else { return }
        config.waveformCacheOrphanCleanupMigrationApplied = true
        appState.config = config
        configStore.save(config)
    }

    @discardableResult
    private func cleanupOrphanedMeetingWaveformCacheFiles() -> Bool {
        let meetings: [MeetingRecord]
        do {
            meetings = try dictationStore.recentMeetings(limit: nil)
        } catch {
            return false
        }
        let recordingURLs = meetings.compactMap { savedRecordingURL(from: $0.savedRecordingPath) }
        let result = RecordingWaveformCacheFiles.sweepOrphanedCachedWaveforms(
            retainedRecordingURLs: recordingURLs,
            supportDirectory: configStore.supportDirectory()
        )
        if case .skipped = result {
            return false
        }
        return true
    }

    private func cleanupLegacyJSONMeetingWaveformCacheFiles() -> Bool {
        let result = RecordingWaveformCacheFiles.removeLegacyJSONWaveformCaches(
            supportDirectory: configStore.supportDirectory()
        )
        if case .skipped = result {
            return false
        }
        return true
    }

    private func clearSavedMeetingRecordingsDirectory() throws {
        let recordingsDirectory = configStore.supportDirectory()
            .appendingPathComponent("meeting-recordings", isDirectory: true)
        guard FileManager.default.fileExists(atPath: recordingsDirectory.path) else { return }
        try FileManager.default.removeItem(at: recordingsDirectory)
    }

    private func clearSavedMeetingWaveformCache() throws {
        try RecordingWaveformCacheFiles.removeAllCachedWaveforms(
            supportDirectory: configStore.supportDirectory()
        )
    }

    private func deleteSavedMeetingRecording(at path: String) throws {
        guard let url = savedRecordingURL(from: path) else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            // Waveform cache is derived data; recording deletion must still proceed if cache cleanup fails.
            try? RecordingWaveformCacheFiles.removeCachedWaveform(
                for: url,
                supportDirectory: configStore.supportDirectory()
            )
            try FileManager.default.removeItem(at: url)
        } catch {
            throw MeetingLifecycleError.failedToDeleteRecording(underlying: error)
        }
    }

    private func shouldDeleteSavedMeetingRecording(at path: String, excluding meetingID: Int64) throws -> Bool {
        guard let url = savedRecordingURL(from: path) else { return false }
        let targetPath = url.standardizedFileURL.path
        let meetings = try dictationStore.recentMeetings(limit: nil)
        return !meetings.contains { meeting in
            guard meeting.id != meetingID,
                  let otherURL = savedRecordingURL(from: meeting.savedRecordingPath) else {
                return false
            }
            return otherURL.standardizedFileURL.path == targetPath
        }
    }

    private func savedRecordingURL(from path: String?) -> URL? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed)
    }

    @MainActor
    private func recordingSaveDecision(for result: MeetingSessionResult) async -> Bool? {
        guard config.meetingRecordingSavePolicy == .prompt else { return nil }
        guard result.retainedRecordingURL != nil, result.retainedRecordingError == nil else { return nil }
        return await promptToSaveMeetingRecording(for: result.title)
    }

    @MainActor
    private func promptToSaveMeetingRecording(for title: String) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Save meeting recording?"
        alert.informativeText = "Keep a merged audio file for \"\(title)\" so you can inspect it later in Finder."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save Recording")
        alert.addButton(withTitle: "Don't Save")
        guard let window = alertPresentationWindow(showHistoryIfNeeded: true) else {
            fputs("[meets] no window available for recording save prompt; saving recording by default\n", stderr)
            return true
        }

        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    @MainActor
    private func alertPresentationWindow(showHistoryIfNeeded: Bool = true) -> NSWindow? {
        if let window = historyWindowController?.presentationWindow,
           isUsableSheetHost(window, allowPanel: false) {
            return window
        }

        if showHistoryIfNeeded {
            historyWindowController?.show()
        }

        if let window = historyWindowController?.presentationWindow,
           isUsableSheetHost(window, allowPanel: false) {
            return window
        }

        return NSApp.windows.first { window in
            isUsableSheetHost(window, allowPanel: false)
        } ?? NSApp.windows.first { window in
            isUsableSheetHost(window, allowPanel: true)
        }
    }

    @discardableResult
    private func presentAlert(
        _ alert: NSAlert,
        fallbackLogContext: String,
        completion: ((NSApplication.ModalResponse) -> Void)? = nil
    ) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = alertPresentationWindow(showHistoryIfNeeded: true) else {
            fputs(
                "[meets] unable to present \(fallbackLogContext) alert: \(alert.messageText) - \(alert.informativeText)\n",
                stderr
            )
            statusBarController?.setStatus(alert.messageText)
            statusBarController?.refresh()
            NSSound.beep()
            return false
        }

        alert.beginSheetModal(for: window) { response in
            completion?(response)
        }
        return true
    }

    private func presentMeetingStartFailureAlert(error: Error) {
        let isSystemAudioError = error is CoreAudioSystemRecorder.RecorderError
        let alert = NSAlert()
        alert.alertStyle = .warning
        if isSystemAudioError {
            alert.messageText = "System audio capture failed"
            alert.informativeText = "Could not start system audio recording. Open System Settings > Privacy & Security > Screen & System Audio Recording and enable \(AppIdentity.displayName) under \"System Audio Recording Only\".\n\nError: \(error.localizedDescription)"
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "OK")
        } else {
            alert.messageText = "Meeting failed to start"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
        }

        presentAlert(alert, fallbackLogContext: "meeting start failure") { response in
            guard isSystemAudioError, response == .alertFirstButtonReturn else { return }
            CoreAudioSystemRecorder.openSystemAudioSettings()
        }
    }

    private func presentErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        presentAlert(alert, fallbackLogContext: title)
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func noteWindowOpened() {
        openWindowCount += 1
        if NSApplication.shared.activationPolicy() != .regular {
            NSApplication.shared.setActivationPolicy(.regular)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func noteWindowClosed() {
        openWindowCount = max(0, openWindowCount - 1)
        if openWindowCount == 0 {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    private func configureHotkeyMonitorTiming() {
        meetingRecordingHotkeyMonitor.configureTriggerThreshold(milliseconds: config.meetingRecordingHotkeyTriggerThresholdMS)
    }

    private func startMeetingRecordingHotkeyMonitorIfNeeded() {
        guard config.enableMeetingRecordingHotkey else {
            meetingRecordingHotkeyMonitor.stop()
            return
        }
        let validation = ShortcutHotkeyPolicy.validateMeetingRecordingHotkey(
            config.meetingRecordingHotkey
        )
        guard validation.didUpdate else {
            meetingRecordingHotkeyMonitor.stop()
            fputs("[meetings] meeting recording hotkey disabled because it conflicts with another active shortcut\n", stderr)
            return
        }
        meetingRecordingHotkeyMonitor.doubleTapEnabled = false
        meetingRecordingHotkeyMonitor.configure(config.meetingRecordingHotkey)
        meetingRecordingHotkeyMonitor.start()
    }

    private func beginMeetingActivity(reason: String) {
        guard meetingActivity == nil else { return }
        meetingActivity = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiatedAllowingIdleSystemSleep,
                .suddenTerminationDisabled,
                .automaticTerminationDisabled,
            ],
            reason: reason
        )
    }

    private func updateMeetingStartStatus(_ status: String?) {
        meetingStartStatus = status
        appState.isMeetingStarting = isStartingMeetingRecording
        appState.meetingStartStatus = status
    }

    private func updateImportProgressStatus(_ status: String, sessionID: UUID) {
        guard importTask != nil,
              importSessionID == sessionID,
              isStartingMeetingRecording else { return }
        updateMeetingStartStatus(status)
        statusBarController?.setStatus(status)
        statusBarController?.refresh()
        indicator.showLoading(status)
    }

    private func endMeetingActivity() {
        guard backgroundMeetingProcessingCount == 0,
              activeMeetingSession?.isRecording != true else { return }
        guard let activity = meetingActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        meetingActivity = nil
    }

    private func dismissPresentedMeetingDetection() {
        guard let candidate = presentedMeetingCandidate else { return }
        presentedMeetingCandidate = nil
        meetingMonitor.markPromptClosed(candidate)
        if !isShowingCalendarNotification,
           meetingNotification.currentPromptID == candidate.id {
            meetingNotification.close()
        }
        showPendingMeetingCompletionNotificationIfPossible()
    }

    private func updateMeetingNotificationVisibility() {
        meetingMonitor.refreshState()
        showPendingMeetingCompletionNotificationIfPossible()
    }

    private func enqueueOrShowMeetingCompletionNotification(meetingID: Int64?, title: String) {
        let notification = PendingMeetingCompletionNotification(meetingID: meetingID, title: title)
        guard canShowMeetingCompletionNotification else {
            pendingMeetingCompletionNotification = notification
            return
        }
        showMeetingCompletionNotification(notification)
    }

    private func showPendingMeetingCompletionNotificationIfPossible() {
        guard let notification = pendingMeetingCompletionNotification,
              canShowMeetingCompletionNotification else { return }
        pendingMeetingCompletionNotification = nil
        showMeetingCompletionNotification(notification)
    }

    private var canShowMeetingCompletionNotification: Bool {
        MeetingCompletionNotificationPolicy.shouldShow(
            hasPresentedMeetingCandidate: presentedMeetingCandidate != nil,
            isShowingCalendarNotification: isShowingCalendarNotification,
            isMeetingNotificationVisible: meetingNotification.isVisible
        )
    }

    private func showMeetingCompletionNotification(_ notification: PendingMeetingCompletionNotification) {
        meetingNotification.show(
            title: "Transcription complete",
            subtitle: notification.title,
            actionLabel: "View Notes",
            onStartRecording: { [weak self] in
                guard let self else { return }
                if let meetingID = notification.meetingID {
                    self.showMeetingDocument(id: meetingID)
                }
                self.syncAppState()
                self.historyWindowController?.show()
            },
            onClose: { [weak self] in
                self?.showPendingMeetingCompletionNotificationIfPossible()
            }
        )
    }

    private func armMeetingAutoStop(
        source: MeetingAutoStopSource?,
        response: MeetingSignalLossResponse = .autoStopAfterWarning
    ) {
        activeMeetingAutoStop.arm(source: source)
        activeMeetingSignalLossResponse = source == nil ? .none : response
        meetingSignalLossPromptState.resetForRecording()
        syncMeetingDetectionMonitor()
    }

    private func recentMeetingAutoStopSource() -> MeetingAutoStopSource? {
        guard let candidate = latestMeetingActivityCandidate,
              let observedAt = latestMeetingActivityCandidateObservedAt,
              Date().timeIntervalSince(observedAt) <= 15 else {
            return nil
        }
        guard !isMutedMeetingDetectionCandidate(candidate) else {
            latestMeetingActivityCandidate = nil
            latestMeetingActivityCandidateObservedAt = nil
            return nil
        }
        return MeetingAutoStopSource(candidate: candidate)
    }

    private func isMutedMeetingDetectionCandidate(_ candidate: MeetingCandidate) -> Bool {
        guard let sourceBundleID = candidate.sourceBundleID else { return false }
        return isMutedMeetingDetectionBundleID(sourceBundleID)
    }

    private func isMutedMeetingDetectionBundleID(_ bundleID: String) -> Bool {
        config.mutedMeetingDetectionAppBundleIDs.contains(bundleID)
    }

    private func disarmMeetingAutoStop() {
        activeMeetingAutoStop.disarm()
        activeMeetingSignalLossResponse = .none
        meetingSignalLossPromptState.resetForRecording()
        latestMeetingActivityCandidate = nil
        latestMeetingActivityCandidateObservedAt = nil
        syncMeetingDetectionMonitor()
    }

    private func handleMeetingActivityCandidate(_ candidate: MeetingCandidate?) {
        if !activeMeetingAutoStop.isArmed,
           !isMeetingRecording(),
           !isStartingMeetingRecording {
            if let candidate {
                latestMeetingActivityCandidate = candidate
                latestMeetingActivityCandidateObservedAt = Date()
            } else {
                latestMeetingActivityCandidate = nil
                latestMeetingActivityCandidateObservedAt = nil
            }
        }

        if activeMeetingAutoStop.isArmed,
           isStartingMeetingRecording,
           !isStoppingMeetingRecording {
            activeMeetingAutoStop.observeBeforeRecordingStarted(candidate: candidate)
            return
        }

        guard activeMeetingAutoStop.isArmed,
              activeMeetingSession?.isRecording == true,
              !isStoppingMeetingRecording else {
            return
        }
        if let sourceBundleID = activeMeetingAutoStop.source?.sourceBundleID,
           isMutedMeetingDetectionBundleID(sourceBundleID) {
            return
        }

        let now = Date()
        let matchedSource = candidate.flatMap { candidate in
            activeMeetingAutoStop.source.map { source in
                MeetingAutoStopPolicy.matches(candidate: candidate, source: source)
            }
        } ?? false
        if matchedSource {
            meetingSignalLossPromptState.markSourceRecovered()
            dismissMeetingSignalLossPromptIfVisible(for: activeMeetingID)
        }
        if activeMeetingAutoStop.observe(
            candidate: candidate,
            now: now,
            gracePeriod: meetingAutoStopGracePeriod
        ) {
            presentMeetingSignalLossPromptIfNeeded()
        }
    }

    private func meetingSignalLossPromptID(for meetingID: Int64?) -> String {
        meetingID.map { "meeting-signal-lost:\($0)" } ?? "meeting-signal-lost"
    }

    private func dismissMeetingSignalLossPromptIfVisible(for meetingID: Int64?) {
        guard meetingNotification.isVisible,
              meetingNotification.currentPromptID == meetingSignalLossPromptID(for: meetingID) else {
            return
        }
        meetingNotification.close()
    }

    private func presentMeetingSignalLossPromptIfNeeded() {
        guard activeMeetingSignalLossResponse != .none,
              meetingSignalLossPromptState.canPresentPrompt,
              activeMeetingSession?.isRecording == true,
              !isStoppingMeetingRecording else { return }

        let meetingID = activeMeetingID
        let promptID = meetingSignalLossPromptID(for: meetingID)
        guard meetingNotification.currentPromptID != promptID || !meetingNotification.isVisible else { return }

        meetingSignalLossPromptState.markPromptPresented()
        let response = activeMeetingSignalLossResponse
        let didShow = meetingNotification.show(
            promptID: promptID,
            title: "Meeting signal lost",
            subtitle: "Still transcribing. Stop if the meeting ended.",
            actionLabel: "Stop Transcribing",
            dismissAfter: 30,
            // MeetingNotificationController uses onStartRecording as its generic
            // primary-action slot; here the primary action is stopping transcription.
            onStartRecording: { [weak self] in
                guard let self, self.activeMeetingID == meetingID else { return }
                self.stopMeetingRecording()
            },
            onDismiss: { [weak self] in
                guard let self, self.activeMeetingID == meetingID else { return }
                self.meetingSignalLossPromptState.markDismissedByUser()
            },
            onAutoDismiss: { [weak self] in
                guard let self else { return }
                guard self.activeMeetingID == meetingID else { return }
                self.meetingSignalLossPromptState.markAutoDismissed()
                guard response == .autoStopAfterWarning else { return }
                fputs("[meeting] auto-stopping recording after meeting source disappeared and warning timed out\n", stderr)
                self.stopMeetingRecording()
            }
        )

        if !didShow, response == .autoStopAfterWarning {
            fputs("[meeting] auto-stopping recording after meeting source disappeared; warning unavailable\n", stderr)
            stopMeetingRecording()
        }
    }

    private func presentMeetingDetection(_ candidate: MeetingCandidate) {
        guard config.showMeetingDetectionNotification,
              !isShowingCalendarNotification,
              !isMeetingRecording(),
              !isStartingMeetingRecording else { return }

        guard meetingNotification.currentPromptID != candidate.id || !meetingNotification.isVisible else {
            presentedMeetingCandidate = candidate
            return
        }

        let title = candidate.subtitle
        presentedMeetingCandidate = candidate
        let didShow = meetingNotification.show(
            promptID: candidate.id,
            title: "Meeting detected",
            subtitle: title,
            onStartRecording: { [weak self] in
                guard let self else { return }
                let calendarEvent = candidate.evidence.contains(.calendarEvent)
                    ? self.currentOrNearbyCachedCalendarEvent()
                    : nil
                if self.startMeetingRecordingFromEntryPoint(
                    title: title,
                    calendarOccurrence: calendarEvent?.calendarOccurrence,
                    autoStopSource: MeetingAutoStopSource(candidate: candidate),
                    presentation: .backgroundPill,
                    startOrigin: .detectedPrompt
                ) {
                    self.meetingMonitor.markRecordingStarted(candidate)
                    self.presentedMeetingCandidate = nil
                    self.showPendingMeetingCompletionNotificationIfPossible()
                } else {
                    self.meetingMonitor.refreshState()
                }
            },
            onDismiss: { [weak self] in
                guard let self else { return }
                self.presentedMeetingCandidate = nil
                self.meetingMonitor.markPromptUserDismissed(candidate)
                self.meetingMonitor.refreshState()
                self.showPendingMeetingCompletionNotificationIfPossible()
            },
            onAutoDismiss: { [weak self] in
                guard let self else { return }
                self.meetingMonitor.markPromptAutoDismissed(candidate)
                if self.presentedMeetingCandidate == candidate {
                    self.presentedMeetingCandidate = nil
                }
                self.meetingMonitor.refreshState()
                self.showPendingMeetingCompletionNotificationIfPossible()
            },
            onClose: { [weak self] in
                guard let self, self.presentedMeetingCandidate == candidate else { return }
                self.presentedMeetingCandidate = nil
                self.meetingMonitor.markPromptClosed(candidate)
                self.showPendingMeetingCompletionNotificationIfPossible()
            }
        )
        if didShow {
            meetingMonitor.markPromptShown(candidate)
        } else if presentedMeetingCandidate == candidate {
            presentedMeetingCandidate = nil
        }
    }

    @MainActor
    private func setMeetingProcessingStage(
        _ stage: MeetingProcessingStage,
        processingID: UUID,
        updatePresentation: Bool = true
    ) {
        meetingProcessingStages[processingID] = stage

        guard updatePresentation else { return }
        let presentationStage = meetingProcessingStages.values.first(where: { !$0.allowsDictation }) ?? stage
        presentMeetingProcessingStage(presentationStage)
    }

    @MainActor
    private func removeMeetingProcessing(processingID: UUID) {
        meetingProcessingStages[processingID] = nil
    }

    @MainActor
    private func presentMeetingProcessingStage(_ stage: MeetingProcessingStage) {
        switch stage {
        case .stoppingCapture:
            setMeetingProcessingStatus("Finishing")
        case .transcribingAudio:
            setMeetingProcessingStatus("Transcribing")
        case .cleaningAudio:
            setMeetingProcessingStatus("Cleaning")
        case .generatingTitle:
            setMeetingProcessingStatus("Titling")
        case .summarizingNotes:
            setMeetingProcessingStatus("Summarizing")
        }
    }

    @MainActor
    private func setMeetingProcessingStatus(_ status: String) {
        statusBarController?.setStatus(status)
        statusBarController?.refresh()
        indicator.setTranscribingTitle(status, config: config)
        indicator.setState(.transcribing, config: config)
    }


    /// Streaming RNNT dictation backend (handsfree live text at cursor).


    /// Meeting recording start for Shortcuts/App Intents. Thin public wrapper
    /// around `startMeetingRecording` so that method's internal enum-typed
    /// parameters don't need to become part of the public API surface.
    @discardableResult
    public func startMeetingRecordingForShortcuts(title: String = "Meeting") -> Bool {
        guard config.hasCompletedOnboarding else { return false }
        return startMeetingRecordingFromEntryPoint(
            title: title,
            presentation: .backgroundPill
        )
    }

    /// Meeting recording stop for Shortcuts/App Intents. Cancels a pending
    /// meeting start through the same `cancelMeetingPreparation()` path the
    /// UI uses, stops an already-active recording, or returns false when no
    /// meeting is starting or recording.
    @discardableResult
    public func stopMeetingRecordingForShortcuts() -> Bool {
        if isStartingMeetingRecording, activeMeetingSession == nil {
            cancelMeetingPreparation()
            return true
        }
        guard isMeetingRecording() else { return false }
        stopMeetingRecording()
        return true
    }


    // MARK: - Marauder's Map

    private func checkMaraudersMapActivation(_ text: String) {
        guard !config.maraudersMapUnlocked else { return }
        guard MaraudersMapDetector.containsActivationPhrase(text) else { return }

        fputs("[meets] Marauder's Map unlocked!\n", stderr)
        updateConfig { $0.maraudersMapUnlocked = true }
        SoundController.playMaraudersMapUnlock()
        indicator.showWarning("Mischief Managed", icon: "\u{26A1}", duration: 3.0)
        startMaraudersMapMonitoring()
    }

    private func startMaraudersMapMonitoring() {
        guard config.maraudersMapUnlocked else { return }

        let countdown = MaraudersMapCountdownController()
        self.maraudersMapCountdown = countdown

        countdown.startMonitoring(
            eventProvider: { [weak self] in
                guard let self else { return nil }
                let now = Date()
                let hidden = self.appState.hiddenCalendarEventIDs
                guard let event = (self.appState.upcomingCalendarEvents
                    .filter {
                        ScheduledMeetingNotificationPolicy.isJoinableMeeting($0, hiddenEventIDs: hidden)
                            && $0.startDate > now
                    }
                    .min(by: { $0.startDate < $1.startDate })) else { return nil }
                return (id: event.id, title: event.title, startDate: event.startDate)
            },
            audioClipID: config.maraudersMapAudioClip,
            customAudioPath: config.maraudersMapCustomAudioPath,
            onStatusBarUpdate: { [weak self] text in
                self?.statusBarController?.setCountdownOverride(text)
            },
            onCountdownFinished: { [weak self] info in
                guard let self, !self.isMeetingRecording() else { return }
                // Cancel any scheduled "starting now" timer for this event.
                // Match by event ID prefix so deleted/cancelled events (no longer
                // in upcomingCalendarEvents) still get their timers cancelled.
                let prefix = "\(info.id)|"
                let matchingTimerKeys = self.meetingStartingNowTimers.keys.filter { $0.hasPrefix(prefix) }
                for key in matchingTimerKeys {
                    guard let timer = self.meetingStartingNowTimers[key] else { continue }
                    timer.invalidate()
                    self.meetingStartingNowTimers.removeValue(forKey: key)
                }
                guard let event = ScheduledMeetingNotificationPolicy.startingNowCandidate(
                    from: self.appState.upcomingCalendarEvents,
                    eventID: info.id,
                    startDate: info.startDate,
                    hiddenEventIDs: self.appState.hiddenCalendarEventIDs
                ) else { return }
                // Reuse the same notification method as the timer path
                self.showMeetingStartingNowNotification(
                    title: event.title,
                    calendarOccurrence: event.resolvedCalendarOccurrence,
                    meetingURL: event.meetingURL,
                    endDate: event.endDate
                )
            }
        )
    }

    func updateMaraudersMapAudioClip() {
        maraudersMapCountdown?.updateAudioClip(config.maraudersMapAudioClip, customPath: config.maraudersMapCustomAudioPath)
    }

    func resetMaraudersMap() {
        maraudersMapCountdown?.stopMonitoring()
        maraudersMapCountdown = nil
        updateConfig {
            $0.maraudersMapUnlocked = false
            $0.maraudersMapAudioClip = "bbc_world_news"
            $0.maraudersMapCustomAudioPath = nil
        }
    }

    private func handleUpcomingMeeting(_ event: UpcomingMeetingEvent) {
        // Look up end date and meeting URL from unified calendar events
        let calendarEvent = appState.upcomingCalendarEvents
            .first(where: { $0.id == event.id && $0.startDate == event.startDate })
        let calendarEndDate = calendarEvent?.endDate
        let meetingURL = event.meetingURL ?? calendarEvent?.meetingURL
        let calendarOccurrence = event.calendarOccurrence ?? calendarEvent?.resolvedCalendarOccurrence

        // Show notification panel for calendar events (if not auto-recording)
        guard config.showScheduledMeetingNotifications,
              !isMeetingRecording(),
              !isStartingMeetingRecording else {
            return
        }
        isShowingCalendarNotification = true

        let minutesUntil = Int(ceil(event.startDate.timeIntervalSinceNow / 60))
        let timeLabel: String
        if minutesUntil > 0 {
            timeLabel = "starts in \(minutesUntil) min"
        } else if minutesUntil == 0 {
            timeLabel = "starting now"
        } else {
            timeLabel = "started \(abs(minutesUntil)) min ago"
        }

        let title = event.title
        let notificationTitle = minutesUntil <= 0 ? "Meeting starting now" : "Upcoming meeting"
        meetingNotification.show(
            title: notificationTitle,
            subtitle: "\(title) · \(timeLabel)",
            meetingURL: meetingURL,
            defaultAction: config.meetingJoinDefaultAction,
            onStartRecording: { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                self.recordOnly(
                    title: title,
                    meetingURL: meetingURL,
                    endDate: calendarEndDate,
                    calendarOccurrence: calendarOccurrence,
                    presentation: .backgroundPill
                )
            },
            onJoinAndRecord: meetingURL != nil ? { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                self.joinAndRecord(
                    title: title,
                    meetingURL: meetingURL!,
                    endDate: calendarEndDate,
                    calendarOccurrence: calendarOccurrence,
                    presentation: .backgroundPill
                )
            } : nil,
            onJoinOnly: meetingURL != nil ? { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                self.joinOnly(meetingURL: meetingURL!, endDate: calendarEndDate)
            } : nil,
            onDismiss: { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                let remaining = calendarEndDate.map { max($0.timeIntervalSinceNow, 120) } ?? 120
                self.meetingMonitor.suppress(for: remaining)
                self.meetingMonitor.refreshState()
            },
            onClose: { [weak self] in
                self?.isShowingCalendarNotification = false
                self?.showPendingMeetingCompletionNotificationIfPossible()
            }
        )
    }

    private func scheduleMeetingEndNotification(endDate: Date?, title: String) {
        meetingEndTimer?.invalidate()
        meetingEndTimer = nil

        guard let endDate else { return }

        let delay = endDate.timeIntervalSinceNow
        guard delay > 0 else {
            showMeetingEndNotification(title: title)
            return
        }

        meetingEndTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.showMeetingEndNotification(title: title)
            }
        }
    }

    private func showMeetingEndNotification(title: String) {
        guard isMeetingRecording() else { return }
        meetingNotification.show(
            title: "Meeting ended",
            subtitle: "\(title) · scheduled time is over",
            actionLabel: "Stop Transcribing",
            dismissAfter: 45,
            onStartRecording: { [weak self] in
                self?.stopMeetingRecording()
            },
            onDismiss: nil
        )
    }

}

func selectCurrentOrNearbyCachedCalendarEvent(
    from events: [UnifiedCalendarEvent],
    now: Date = Date()
) -> CalendarEventContext? {
    let searchEnd = now.addingTimeInterval(5 * 60)
    let candidates = events
        .filter { event in
            !event.isAllDay && event.endDate > now && event.startDate < searchEnd
        }
        .sorted { $0.startDate < $1.startDate }

    if let active = candidates.first(where: { $0.startDate <= now && $0.endDate > now }) {
        return CalendarEventContext(
            id: active.id,
            title: active.title,
            calendarOccurrence: active.resolvedCalendarOccurrence
        )
    }

    return candidates.first(where: { $0.startDate > now })
        .map {
            CalendarEventContext(
                id: $0.id,
                title: $0.title,
                calendarOccurrence: $0.resolvedCalendarOccurrence
            )
        }
}

/// The controller is the coordinator's view of live permission state: it owns
/// the monitor and the published snapshot.
extension MeetsController: InteractionPermissionSnapshotSource {
    var currentPermissionSnapshot: InteractionPermissionSnapshot? {
        appState.interactionPermissionSnapshot
    }

    func refreshPermissionSnapshot() async {
        await interactionPermissionMonitor.refresh()
    }
}
