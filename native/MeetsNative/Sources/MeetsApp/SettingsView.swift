/*
 THESIS: Settings reveal the decisions people make often and keep expert depth one deliberate click away, refusing the wall-of-cards layout.
 OWN-WORLD: Native Mac typography, quiet neutral surfaces, Meets accent for selection, and semantic color only for live status.
 STORY: Choose a pane, understand its purpose, set the essentials, then expand a clearly summarized group when deeper control is needed.
 FIRST VIEWPORT: Settings and a right-aligned text switcher lead into a pane introduction, essential controls, and calm disclosure rows at a readable centered width.
 FORM: Essentials + Advanced, sixth of seven grounded structures; surface seed 33ea9e2e.
 FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
*/

import AppKit
import AVFoundation
import SwiftUI
import MeetsCore
import TelemetryDeck

private struct MeetingDetectionAppOption: Identifiable {
    let bundleID: String
    let name: String
    let icon: String
    /// Bundled brand icon resource name (e.g. "appicon-discord"); falls back
    /// to the SF Symbol `icon` when nil or not bundled.
    var brandIcon: String?

    init(bundleID: String, name: String, icon: String, brandIcon: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.icon = icon
        self.brandIcon = brandIcon
    }

    var id: String { bundleID }
}

private struct MicrophoneOption: Identifiable {
    let uid: String?
    let label: String

    var id: String { uid ?? "__automatic__" }
}

enum SettingsPermissionRefreshReason {
    case initialDisplay
    case permissionRequested
    case settingsSelected
    case appActivated

    var refreshesLaunchAtLogin: Bool {
        self == .appActivated
    }

    var refreshesSystemAudio: Bool {
        switch self {
        case .initialDisplay, .settingsSelected, .appActivated:
            true
        case .permissionRequested:
            false
        }
    }
}

struct SettingsView: View {
    private enum PendingDataDestruction {
        case meetings

        var title: String {
            "Clear meeting history?"
        }

        var message: String {
            "This will permanently remove all saved meetings, notes, transcripts, and retained audio recordings. This cannot be undone."
        }

        var confirmLabel: String {
            "Clear Meetings"
        }
    }

    let appState: AppState
    let controller: MeetsController

    @State private var chatGPTSignInError: String?
    @State private var isSigningInChatGPT = false
    @State private var openRouterSignInError: String?
    @State private var isSigningInOpenRouter = false
    @State private var isEnteringOpenRouterAPIKey = false
    @State private var manualOpenRouterAPIKey = ""
    @State private var pendingDataDestruction: PendingDataDestruction?
    @State private var isPreviewingClip = false
    @State private var selectedPane: SettingsPane
    @State private var downloadedBackendOptions: [BackendOption] = []
    @State private var downloadedMeetingLiveCaptionBackends: [MeetingLiveCaptionBackend] = []
    @State private var audioInputDevices: [AudioInputDeviceInfo] = []
    @State private var audioInputDeviceRefreshTask: Task<Void, Never>?
    @State private var permissionMonitoringClientID = UUID()
    @AppStorage("settings.pendingScreenContextEnable") private var pendingScreenContextEnable = false
    @AppStorage("settings.pendingScreenContextRequestedAt") private var pendingScreenContextRequestedAt = 0.0
    @State private var systemAudioGranted = false
    @State private var isCheckingSystemAudioPermission = false
    @State private var calendarGranted = false
    @State private var isCheckingCalendarPermission = false
    @State private var isUsingCustomOpenRouterModel = false
    @State private var hasRefreshedMeetingCalendarSources = false
    @State private var isRefreshingCalendarAccess = false
    @State private var isShowingCalendarSettings = false
    @State private var isShowingCleanupPromptManager = false
    @State private var cleanupDownloads: [String: Double] = [:]
    @State private var isSyncingCloud = false
    @State private var cloudSyncOutcome: String?
    @State private var cloudSyncOutcomeIsError = false
    /// Live ACP agent config options backing the Model/Reasoning menus in the
    /// AI pane's defaults. `nil` = not yet fetched.
    @State private var acpConfigOptions: [ACPConfigOption]?
    /// Command the cached `acpConfigOptions` were fetched for; a changed
    /// command refetches.
    @State private var acpConfigOptionsCommand = ""
    @State private var acpConfigOptionsLoadTask: Task<Void, Never>?
    @State private var acpOptionsUnavailable = false
    /// Providers whose settings are showing in the AI pane's connections list.
    /// Session-scoped: a fresh launch collapses every row again.
    @State private var expandedAIProviders: Set<AIProvider> = []

    init(appState: AppState, controller: MeetsController) {
        self.appState = appState
        self.controller = controller
        _selectedPane = State(initialValue: appState.selectedSettingsPane)
    }

    private var accessibilityGranted: Bool {
        appState.interactionPermissionSnapshot?.accessibility ?? false
    }

    private var screenRecordingGranted: Bool {
        appState.interactionPermissionSnapshot?.screenRecording ?? false
    }

    // Uniform width for standard right-side controls.
    private let controlWidth: CGFloat = 220
    // Wider controls keep model/provider selections visually consistent in Settings.
    private let meetingControlWidth: CGFloat = 275
    private let meetingDetectionAppOptions: [MeetingDetectionAppOption] = [
        MeetingDetectionAppOption(bundleID: "com.google.Chrome", name: "Chrome", icon: "globe"),
        MeetingDetectionAppOption(bundleID: "company.thebrowser.Browser", name: "Arc", icon: "globe"),
        MeetingDetectionAppOption(bundleID: "com.apple.Safari", name: "Safari", icon: "globe"),
        MeetingDetectionAppOption(bundleID: "com.microsoft.edgemac", name: "Edge", icon: "globe"),
        MeetingDetectionAppOption(bundleID: "com.brave.Browser", name: "Brave", icon: "globe"),
        MeetingDetectionAppOption(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", icon: "message.fill", brandIcon: "slack"),
        MeetingDetectionAppOption(bundleID: "us.zoom.xos", name: "Zoom", icon: "video.fill", brandIcon: "zoom-app"),
        MeetingDetectionAppOption(bundleID: "com.microsoft.teams2", name: "Teams", icon: "person.2.fill", brandIcon: "teams"),
        MeetingDetectionAppOption(bundleID: "com.apple.FaceTime", name: "FaceTime", icon: "video.fill"),
        MeetingDetectionAppOption(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", icon: "phone.fill", brandIcon: "appicon-whatsapp"),
        MeetingDetectionAppOption(bundleID: "com.hnc.discord", name: "Discord", icon: "bubble.left.fill", brandIcon: "appicon-discord"),
        MeetingDetectionAppOption(bundleID: "ru.keepcoder.Telegram", name: "Telegram", icon: "paperplane.fill", brandIcon: "appicon-telegram"),
        MeetingDetectionAppOption(bundleID: "org.whispersystems.signal-mac", name: "Signal", icon: "lock.fill", brandIcon: "appicon-signal"),
        MeetingDetectionAppOption(bundleID: "com.webex.meetingmanager", name: "Webex", icon: "video.fill", brandIcon: "appicon-webex"),
    ]

    private var meetingBackendOptions: [BackendOption] {
        downloadedBackendOptions.filter(\.supportsMeetingTranscription)
    }

    private var selectedMeetingLiveCaptionLabel: String {
        let selected = appState.config.resolvedMeetingLiveCaptionBackend
        guard appState.config.enableLiveStreamingPartials,
              downloadedMeetingLiveCaptionBackends.contains(selected) else {
            return "Off"
        }
        return selected.settingsLabel
    }

    private var usesUnifiedMeetingTranscript: Bool {
        appState.config.enableLiveStreamingPartials
            && appState.config.resolvedMeetingLiveCaptionBackend.producesFinalTranscript
            && downloadedMeetingLiveCaptionBackends.contains(appState.config.resolvedMeetingLiveCaptionBackend)
    }

    private var meetingLiveTranscriptDescription: String {
        let selected = appState.config.resolvedMeetingLiveCaptionBackend
        guard appState.config.enableLiveStreamingPartials,
              downloadedMeetingLiveCaptionBackends.contains(selected) else {
            return "Shows completed transcript segments only."
        }
        if usesUnifiedMeetingTranscript {
            return "Creates the live and final transcript."
        }
        return "Adds a low-latency preview."
    }

    private var selectedMeetingBackendLabel: String {
        if meetingBackendOptions.contains(appState.selectedMeetingTranscriptionBackend) {
            return appState.selectedMeetingTranscriptionBackend.label
        }
        return meetingBackendOptions.first?.label ?? "No downloaded models"
    }

    private var selectedCohereLanguage: CohereTranscribeLanguage {
        appState.config.resolvedCohereLanguage
    }

    private var selectedUpcomingMeetingsWindow: UpcomingMeetingsWindow {
        UpcomingMeetingsWindow.resolve(dayCount: appState.config.upcomingMeetingsDayCount)
    }

    private var selectedBodhanLanguage: BodhanLanguage {
        appState.config.resolvedBodhanLanguage
    }

    private var selectedNemotron35Language: Nemotron35Language {
        appState.config.resolvedNemotron35Language
    }
    private var selectedWhisperLanguage: WhisperKitLanguage {
        appState.config.resolvedWhisperLanguage
    }

    private var meetingMicrophoneOptions: [MicrophoneOption] {
        microphoneOptions(selectedUID: appState.config.meetingInputDeviceUID)
    }

    private var selectedMeetingMicrophoneLabel: String {
        let selectedUID = appState.config.meetingInputDeviceUID
        return meetingMicrophoneOptions.first(where: { $0.uid == selectedUID })?.label ?? "Automatic"
    }

    private func microphoneOptions(selectedUID: String?) -> [MicrophoneOption] {
        var options = [MicrophoneOption(uid: nil, label: "Automatic")]
        options += audioInputDevices.map { MicrophoneOption(uid: $0.uid, label: $0.name) }
        if let selectedUID, !options.contains(where: { $0.uid == selectedUID }) {
            options.append(MicrophoneOption(uid: selectedUID, label: "Selected microphone unavailable"))
        }
        return options
    }

    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: MeetsTheme.spacing24) {
                    settingsHeader
                    paneIntroduction
                    paneContent
                }
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.horizontal, MeetsTheme.spacing32)
                .padding(.top, MeetsTheme.spacing24)
                .padding(.bottom, MeetsTheme.spacing32)
            }
            .background(MeetsTheme.backgroundBase)
            .onAppear {
                refreshDownloadedModelOptions()
                refreshAudioInputDevices()
                startPermissionMonitoring()
                if appState.selectedMeetingSummaryBackend == .openRouter {
                    loadOpenRouterFreeModelsIfNeeded()
                }
                if selectedPane == .ai {
                    loadACPConfigOptionsIfNeeded()
                }
            }
            .onDisappear {
                SoundController.stopMaraudersMapClip()
                isPreviewingClip = false
                audioInputDeviceRefreshTask?.cancel()
                audioInputDeviceRefreshTask = nil
                stopPermissionMonitoring()
                hasRefreshedMeetingCalendarSources = false
            }
            .onChange(of: appState.selectedTab) { _, tab in
                if tab == .settings {
                    selectedPane = appState.selectedSettingsPane
                    refreshDownloadedModelOptions()
                    refreshAudioInputDevices()
                    refreshPermissionStatuses(for: .settingsSelected)
                }
            }
            .onChange(of: appState.selectedSettingsPane) { _, pane in
                selectedPane = pane
            }
            .onChange(of: selectedPane) { _, pane in
                appState.selectedSettingsPane = pane
                handlePaneSelection(pane)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                guard appState.selectedTab == .settings else { return }
                refreshAudioInputDevices()
                refreshPermissionStatuses(for: .appActivated)
                if selectedPane == .calendar {
                    Task {
                        await controller.calendarAccessDidChange()
                    }
                }
            }
            .onChange(of: appState.selectedBackend) { _, _ in
                refreshDownloadedModelOptions()
            }
            .onChange(of: appState.selectedMeetingTranscriptionBackend) { _, _ in
                refreshDownloadedModelOptions()
            }
            .onChange(of: appState.selectedMeetingSummaryBackend) { _, backend in
                if backend == .openRouter {
                    loadOpenRouterFreeModelsIfNeeded()
                }
                if backend == .acpAgent {
                    loadACPConfigOptionsIfNeeded()
                }
            }
            .onChange(of: appState.config.acpAgentCommand) { _, _ in
                loadACPConfigOptionsIfNeeded()
            }
            .onChange(of: appState.config.postProcessorBackend) { _, _ in
                if selectedCleanupBackend.backend == "acp_agent" {
                    loadACPConfigOptionsIfNeeded()
                }
            }
            .onChange(of: selectedPane) { _, pane in
                if pane != .ai {
                    acpConfigOptionsLoadTask?.cancel()
                    acpConfigOptionsLoadTask = nil
                    acpConfigOptions = nil
                    acpConfigOptionsCommand = ""
                    acpOptionsUnavailable = false
                }
            }
            .alert(
                pendingDataDestruction?.title ?? "Confirm Destructive Action",
                isPresented: Binding(
                    get: { pendingDataDestruction != nil },
                    set: { if !$0 { pendingDataDestruction = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    pendingDataDestruction = nil
                }
                Button(pendingDataDestruction?.confirmLabel ?? "Delete", role: .destructive) {
                    controller.clearMeetingHistory()
                    pendingDataDestruction = nil
                }
            } message: {
                Text(pendingDataDestruction?.message ?? "")
            }
            .sheet(isPresented: $isShowingCleanupPromptManager) {
                TranscriptCleanupPromptsManagerView(
                    appState: appState,
                    controller: controller,
                    onClose: { isShowingCleanupPromptManager = false }
                )
            }
            .sheet(isPresented: $isShowingCalendarSettings) {
                CalendarSettingsView(
                    appState: appState,
                    controller: controller,
                    onClose: { isShowingCalendarSettings = false }
                )
                .frame(width: 720, height: 600)
            }
    }

    private func refreshDownloadedModelOptions() {
        controller.refreshMeetingTranscriptionSelectionForAvailability()
        downloadedBackendOptions = BackendOption.downloaded
        downloadedMeetingLiveCaptionBackends = MeetingLiveCaptionBackend.allCases.filter(\.isDownloaded)
    }

    private func refreshAudioInputDevices() {
        audioInputDeviceRefreshTask?.cancel()
        audioInputDeviceRefreshTask = Task { @MainActor in
            // Live CoreAudio reads can block while the HAL is unhealthy, so
            // never run them on the main thread.
            let devices = await Task.detached(priority: .userInitiated) {
                CoreAudioDeviceInspector().availableInputDevices()
            }.value
            guard !Task.isCancelled else { return }
            audioInputDevices = devices
        }
    }

    private func handlePaneSelection(_ pane: SettingsPane) {
        if pane == .recording {
            loadCachedAudioInputDevices()
        }
        // ACP agent rows live in the AI pane, next to the defaults that use
        // them.
        loadACPConfigOptionsIfNeeded()
    }

    private func loadCachedAudioInputDevices() {
        refreshAudioInputDevices()
    }

    /// (Re)fetches the ACP agent's advertised config options whenever the AI
    /// pane shows an ACP Model or Reasoning menu with a non-empty command.
    /// Failures degrade to "use agent default": a single "Default" entry in
    /// each menu and a hint that starting the agent surfaces the options.
    private func loadACPConfigOptionsIfNeeded() {
        let summaryIsACP = appState.selectedMeetingSummaryBackend == .acpAgent
        let cleanupIsACP = selectedCleanupBackend.backend == "acp_agent"
        guard summaryIsACP || cleanupIsACP else { return }
        let command = appState.config.acpAgentCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            acpConfigOptionsLoadTask?.cancel()
            acpConfigOptionsLoadTask = nil
            acpConfigOptions = nil
            acpConfigOptionsCommand = ""
            acpOptionsUnavailable = false
            return
        }
        guard acpConfigOptionsCommand != command else { return }
        acpConfigOptionsLoadTask?.cancel()
        // Stale-while-revalidate: show the last-known options for this
        // command instantly (nil on first sight), then refresh quietly.
        acpConfigOptions = appState.config.acpCachedOptionsByCommand[command]
        acpConfigOptionsCommand = command
        acpOptionsUnavailable = false
        acpConfigOptionsLoadTask = Task { @MainActor in
            do {
                // Debounce: collapse keystroke/command bursts into one spawn.
                try await Task.sleep(nanoseconds: 600_000_000)
                let options = try await ACPClient.availableOptions(command: command, timeout: 20)
                guard !Task.isCancelled else { return }
                acpConfigOptions = options
                acpOptionsUnavailable = options.isEmpty
                controller.updateConfig {
                    $0.acpCachedOptionsByCommand[command] = options
                    while $0.acpCachedOptionsByCommand.count > 8 {
                        $0.acpCachedOptionsByCommand.removeValue(forKey: $0.acpCachedOptionsByCommand.keys.first!)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                // Keep showing cached options on transient failure; only a
                // command with nothing cached degrades to agent default.
                if acpConfigOptions == nil {
                    acpConfigOptions = []
                    acpOptionsUnavailable = true
                }
            }
        }
    }

    private var isACPConfigOptionsLoading: Bool {
        (appState.selectedMeetingSummaryBackend == .acpAgent || selectedCleanupBackend.backend == "acp_agent")
            && !appState.config.acpAgentCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && acpConfigOptions == nil
            && acpConfigOptionsLoadTask != nil
            && !acpOptionsUnavailable
    }

    /// Live option values for an ACP config option id, in the agent's order.
    private func acpOptionValues(_ id: String) -> [ACPConfigValue] {
        acpConfigOptions?.first(where: { $0.id == id })?.options ?? []
    }

    @ViewBuilder
    private func acpConfigMenuRow(
        label: String,
        description: String?,
        optionID: String,
        storedValue: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        if let description {
            settingsRow(label, description: description, controlWidth: meetingControlWidth) {
                acpConfigMenuControl(optionID: optionID, storedValue: storedValue, onSelect: onSelect)
            }
        } else {
            settingsRow(label, controlWidth: meetingControlWidth) {
                acpConfigMenuControl(optionID: optionID, storedValue: storedValue, onSelect: onSelect)
            }
        }
    }

    @ViewBuilder
    private func acpConfigMenuControl(
        optionID: String,
        storedValue: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        if isACPConfigOptionsLoading {
            Text("Loading…")
                .font(MeetsTheme.body())
                .foregroundStyle(MeetsTheme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            acpConfigMenu(options: acpOptionValues(optionID), storedValue: storedValue, onSelect: onSelect)
        }
    }

    @ViewBuilder
    private func acpConfigMenu(
        options: [ACPConfigValue],
        storedValue: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        let entries = [("", "Default")] + options.map { ($0.value, $0.name) }
        let selection = {
            if storedValue.isEmpty {
                return "Default"
            }
            return entries.first(where: { $0.0 == storedValue })?.1 ?? "Default"
        }()
        settingsMenu(
            selection: selection,
            options: entries.map(\.1)
        ) { pickedLabel in
            guard let entry = entries.first(where: { $0.1 == pickedLabel }) else { return }
            onSelect(entry.0)
        }
    }

    /// True once the fetch finished and the agent offered no config options
    /// (or the fetch failed); the menus then offer only "Default".
    private var acpOptionsUnavailableAfterLoad: Bool {
        acpOptionsUnavailable
            || (acpConfigOptionsLoadTask == nil && acpConfigOptions?.isEmpty == true)
    }

    /// Shown under the Model row only while the agent is offline or offers no
    /// options; live menus speak for themselves.
    private var acpModelCaption: String {
        let base = "Agent model override. Empty means the agent default."
        guard !isACPConfigOptionsLoading else { return base }
        return acpOptionsUnavailableAfterLoad || acpOptionValues("model").isEmpty
            ? base + " Start the agent to see available models."
            : base
    }

    private static let acpThinkingCaption = "Reasoning effort: off / auto / low / medium / high / xhigh / max."

    /// Which ACP agent runs this work. The connection row lists what this Mac
    /// has; the choice belongs next to the model and reasoning it reports, so
    /// the three read as one decision.
    private func acpAgentRow(description: String) -> some View {
        settingsRow("Agent", description: description, controlWidth: meetingControlWidth) {
            ACPCommandPicker(appState: appState, controller: controller)
        }
    }

    @ViewBuilder
    private var acpModelMenuRow: some View {
        acpConfigMenuRow(
            label: "Model",
            description: acpModelCaption,
            optionID: "model",
            storedValue: appState.config.acpAgentModel
        ) { value in
            controller.updateConfig { $0.acpAgentModel = value }
        }
    }

    @ViewBuilder
    private var acpThinkingMenuRow: some View {
        acpConfigMenuRow(
            label: "Reasoning",
            description: Self.acpThinkingCaption,
            optionID: "thinking",
            storedValue: appState.config.acpAgentThinking
        ) { value in
            controller.updateConfig { $0.acpAgentThinking = value }
        }
    }

    private static let accentPresets: [(hex: String, name: String)] = [
        ("2563eb", "Blue"),
        ("ef4444", "Red"),
        ("f59e0b", "Amber"),
        ("10b981", "Green"),
        ("8b5cf6", "Purple"),
        ("ec4899", "Pink"),
        ("1e1e2e", "Dark"),
    ]

    private func screenContextDescription(includesScreenOCR: Bool) -> String {
        if !accessibilityGranted {
            return "Grant Accessibility, then toggle again if needed."
        }
        if includesScreenOCR, !screenRecordingGranted {
            return "Adds nearby app text for meeting context. Screen Recording enables OCR context."
        }
        if includesScreenOCR {
            return "Adds nearby app text and OCR context."
        }
        return "Adds nearby app text for meeting context."
    }

    @ViewBuilder
    private func screenContextRow(
        _ title: String,
        includesScreenOCR: Bool = false,
        controlWidth rowControlWidth: CGFloat? = nil
    ) -> some View {
        settingsRow(
            title,
            description: screenContextDescription(includesScreenOCR: includesScreenOCR),
            controlWidth: rowControlWidth
        ) {
            screenContextControl()
        }
    }

    private let customIndicatorPositionLabel = "Custom (drag to reposition)"

    private var settingsHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: MeetsTheme.spacing24) {
            // One line, whatever the window does: the pane row beside it is a
            // single line too, and a wrapped page title would push the pane
            // introduction down for no reader.
            PageTitle("Settings")
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: MeetsTheme.spacing24)

            // The pane row is measured before the page title: a title that
            // gives up a few points is invisible, a pane row that gives up its
            // labels is not.
            settingsPanePicker
                .layoutPriority(1)
        }
    }

    /// Every pane on one line, never two: the titles when they fit beside the
    /// page title, the same panes as their icons when they do not, so the
    /// header keeps its height at every window width.
    private var settingsPanePicker: some View {
        ViewThatFits(in: .horizontal) {
            settingsPanePickerRow(SettingsPane.allCases)
            settingsPaneIconPickerRow(SettingsPane.allCases)
        }
    }

    private func settingsPanePickerRow(_ panes: [SettingsPane]) -> some View {
        HStack(spacing: MeetsTheme.spacing16) {
            ForEach(panes) { pane in
                settingsPaneButton(pane) {
                    Text(pane.title)
                        .font(.system(size: 13, weight: selectedPane == pane ? .semibold : .medium))
                }
            }
        }
    }

    /// The narrow form of the same row: the pane's own icon, named in a tooltip
    /// and to a reader, because a header that wrapped would push the page down.
    /// The icons sit closer than the words do, so the page title beside them
    /// keeps its own line intact as long as the window holds both.
    private func settingsPaneIconPickerRow(_ panes: [SettingsPane]) -> some View {
        HStack(spacing: MeetsTheme.spacing12) {
            ForEach(panes) { pane in
                settingsPaneButton(pane) {
                    Image(systemName: pane.iconName)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 20, height: 18)
                }
                .help(pane.title)
            }
        }
    }

    /// One pane in the switcher: the caller supplies the face, the switcher
    /// owns the selection colour, the underline, and what a reader hears.
    private func settingsPaneButton<Face: View>(
        _ pane: SettingsPane,
        @ViewBuilder face: () -> Face
    ) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                selectedPane = pane
            }
        } label: {
            face()
                .foregroundStyle(selectedPane == pane ? MeetsTheme.textPrimary : MeetsTheme.textTertiary)
                .padding(.vertical, 5)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(selectedPane == pane ? MeetsTheme.accent : Color.clear)
                        .frame(height: 2)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pane.title)
        .accessibilityAddTraits(selectedPane == pane ? .isSelected : [])
    }

    private var paneIntroduction: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
            HStack(spacing: MeetsTheme.spacing8) {
                Image(systemName: selectedPaneIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MeetsTheme.textSecondary)
                    .frame(width: 20)
                Text(selectedPane.title)
                    .font(MeetsTheme.title2())
                    .foregroundStyle(MeetsTheme.textPrimary)
            }

            Text(selectedPaneDescription)
                .font(MeetsTheme.callout())
                .foregroundStyle(MeetsTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, MeetsTheme.spacing4)
    }

    private var selectedPaneIcon: String {
        selectedPane.iconName
    }

    private var selectedPaneDescription: String {
        switch selectedPane {
        case .general:
            "Startup behavior, permissions, and the meeting data stored on this Mac."
        case .permissions:
            "Grant the macOS permissions Meets uses to capture and read your meetings."
        case .recording:
            "Choose how meetings are captured and transcribed."
        case .calendar:
            "Connect your calendars and choose which meetings Meets records."
        case .notes:
            "Pick the templates that shape the notes Meets generates."
        case .ai:
            "Connect the AI services Meets can use, then pick the defaults for summaries and transcript cleanup."
        case .advanced:
            "Run a script of your own after each meeting."
        case .appearance:
            "Tune the menu bar and recording controls to fit your workspace."
        }
    }

    private var notificationSettingsSummary: String {
        let scheduled = appState.config.showScheduledMeetingNotifications
        let detected = appState.config.showMeetingDetectionNotification
        return switch (scheduled, detected) {
        case (true, true): "Scheduled and detected meeting alerts are on"
        case (true, false): "Scheduled meeting alerts are on"
        case (false, true): "Detected meeting alerts are on"
        case (false, false): "Meeting alerts are off"
        }
    }

    private var calendarSettingsSummary: String {
        switch appState.calendarAuthorization {
        case .fullAccess: "Connected · showing \(selectedUpcomingMeetingsWindow.label.lowercased())"
        case .writeOnly: "Limited calendar access"
        case .denied: "Calendar access is off"
        case .unknown: "Calendar access has not been configured"
        }
    }

    private var syncAndExportSettingsSummary: String {
        let export = appState.config.autoExportMarkdownEnabled
        let sync = appState.config.cloudSyncEnabled
        return switch (export, sync) {
        case (true, true): "Automatic export and cloud-folder sync are on"
        case (true, false): "Automatic export is on"
        case (false, true): "Cloud-folder sync is on"
        case (false, false): "Export and cloud-folder sync are off"
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedPane {
        case .general:
            generalSettingsPane
        case .permissions:
            permissionsSettingsPane
        case .recording:
            recordingSettingsPane
        case .calendar:
            calendarSettingsPane
        case .notes:
            notesSettingsPane
        case .ai:
            aiSettingsPane
        case .advanced:
            advancedSettingsPane
        case .appearance:
            appearanceSettingsPane
        }
    }

    private var generalSettingsPane: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing20) {
            settingsSection("Startup", iconName: "power") {
                VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
                    settingsRow(
                        "Launch at login",
                        description: "Start Meets automatically when you sign in."
                    ) {
                        settingsSwitch(isOn: appState.config.launchAtLogin) { newValue in
                            controller.setLaunchAtLogin(newValue)
                        }
                    }
                    if appState.launchAtLoginRegistrationState == .requiresApproval {
                        launchAtLoginApprovalPrompt
                    }
                }
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow(
                    "Open dashboard on launch",
                    description: "Show the dashboard window on launch."
                ) {
                    settingsSwitch(isOn: appState.config.openDashboardOnLaunch) { newValue in
                        controller.updateConfig { $0.openDashboardOnLaunch = newValue }
                    }
                }
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow(
                    "Setup guide",
                    description: "Review meeting setup, permissions, transcription, and summaries."
                ) {
                    actionButton("Open Setup Guide", systemImage: "arrow.up.right.square") {
                        controller.showOnboarding()
                    }
                }
            }

            settingsDisclosureSection(
                "Data Management",
                summary: "Clear meetings and their stored transcripts, notes, and audio.",
                icon: "externaldrive",
            ) {
                HStack(spacing: MeetsTheme.spacing12) {
                    actionButton("Clear meeting history", role: .destructive, fillsWidth: true) {
                        pendingDataDestruction = .meetings
                    }
                    .disabled(controller.isMeetingRecording())
                    .help("Stop the current meeting recording before clearing meeting history.")
                }
                // Plain caption (not settingsDescription): that helper lifts
                // text up under tall rows, which overlaps a short button row.
                Text("Permanently delete all saved meetings, notes, transcripts, and audio.")
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textTertiary)
                    .padding(.top, MeetsTheme.spacing8)
            }
        }
    }

    private var permissionsSettingsPane: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing20) {
            permissionsSection
        }
    }

    private var launchAtLoginApprovalPrompt: some View {
        HStack(spacing: MeetsTheme.spacing8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MeetsTheme.recording)
            Text("Requires approval in System Settings")
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textTertiary)
            Spacer(minLength: MeetsTheme.spacing12)
            inlineLinkButton("Open", systemImage: "arrow.up.forward.square") {
                controller.openLaunchAtLoginSettings()
            }
            .help("Open Login Items in System Settings")
        }
        .padding(.bottom, MeetsTheme.spacing8)
    }

    private var meetingTranscriptionSettingsSection: some View {
        settingsSection("Capture & Transcription", iconName: "waveform") {
            settingsRow(
                "Microphone",
                description: "Only affects Meets. Changes apply immediately.",
                controlWidth: meetingControlWidth
            ) {
                let options = meetingMicrophoneOptions
                FixedWidthPopUp(
                    selection: selectedMeetingMicrophoneLabel,
                    options: options.map(\.label),
                    onSelectIndex: { index in
                        guard options.indices.contains(index) else { return }
                        controller.selectMeetingInputDeviceUID(options[index].uid)
                        loadCachedAudioInputDevices()
                    }
                )
                .frame(height: 24)
            }
            Divider().background(MeetsTheme.surfaceBorder)
            settingsRow(
                "Show transcript on hover",
                description: "Show recent transcript beside the waveform.",
                controlWidth: meetingControlWidth
            ) {
                settingsSwitch(isOn: appState.config.showMeetingTranscriptOnIndicatorHover) { newValue in
                    controller.updateConfig { $0.showMeetingTranscriptOnIndicatorHover = newValue }
                }
            }
            Divider().background(MeetsTheme.surfaceBorder)
            settingsRow(
                "Live transcript model",
                description: meetingLiveTranscriptDescription,
                controlWidth: meetingControlWidth
            ) {
                if !downloadedMeetingLiveCaptionBackends.isEmpty {
                    settingsMenu(
                        selection: selectedMeetingLiveCaptionLabel,
                        options: downloadedMeetingLiveCaptionBackends.map(\.settingsLabel) + ["Off"]
                    ) { label in
                        guard label != "Off" else {
                            controller.updateConfig { $0.enableLiveStreamingPartials = false }
                            return
                        }
                        guard let backend = downloadedMeetingLiveCaptionBackends.first(where: { $0.settingsLabel == label }) else {
                            return
                        }
                        controller.updateConfig {
                            $0.meetingLiveCaptionBackend = backend.rawValue
                            $0.enableLiveStreamingPartials = true
                        }
                    }
                } else {
                    Text("Download from Models")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MeetsTheme.textTertiary)
                        .multilineTextAlignment(.trailing)
                        .frame(width: meetingControlWidth, alignment: .trailing)
                }
            }

            Divider().background(MeetsTheme.surfaceBorder)
            settingsRow(
                "Final transcript",
                description: "Model used for the saved meeting transcript.",
                controlWidth: meetingControlWidth
            ) {
                if usesUnifiedMeetingTranscript {
                    Text("\(appState.config.resolvedMeetingLiveCaptionBackend.label) (same model)")
                        .font(MeetsTheme.body())
                        .foregroundStyle(MeetsTheme.textSecondary)
                        .frame(width: meetingControlWidth, alignment: .trailing)
                } else if meetingBackendOptions.isEmpty {
                    Text("No downloaded models")
                        .font(MeetsTheme.body())
                        .foregroundStyle(MeetsTheme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    settingsMenu(
                        selection: selectedMeetingBackendLabel,
                        options: meetingBackendOptions.map(\.label)
                    ) { label in
                        if let option = meetingBackendOptions.first(where: { $0.label == label }) {
                            controller.selectMeetingTranscriptionBackend(option)
                        }
                    }
                }
            }
            if usesUnifiedMeetingTranscript {
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow(
                    "Language",
                    description: "Language for live and final transcription.",
                    controlWidth: meetingControlWidth
                ) {
                    if appState.config.resolvedMeetingLiveCaptionBackend == .nemotron35 {
                        nemotron35LanguageMenu
                    } else {
                        Text("Set in Models → Apple Speech")
                            .font(MeetsTheme.body())
                            .foregroundStyle(MeetsTheme.textSecondary)
                    }
                }
            } else if appState.selectedMeetingTranscriptionBackend.backend == BackendOption.cohereTranscribe.backend {
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow(
                    "Cohere language",
                    description: "Transcription language for the Cohere backend.",
                    controlWidth: meetingControlWidth
                ) {
                    cohereLanguageMenu
                }
            } else if appState.selectedMeetingTranscriptionBackend.backend == BackendOption.bodhanFlex.backend {
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow("Bodhan language", controlWidth: meetingControlWidth) {
                    indicLanguageMenu(model: appState.selectedMeetingTranscriptionBackend.model)
                }
            } else if appState.selectedMeetingTranscriptionBackend.supportsWhisperLanguageSelection {
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow(
                    "Whisper language",
                    description: "Transcription language, or automatic detection.",
                    controlWidth: meetingControlWidth
                ) {
                    whisperLanguageMenu
                }
            }

            Divider().background(MeetsTheme.surfaceBorder)
            screenContextRow("Meeting context", includesScreenOCR: true)
        }
    }

    private var cohereLanguageMenu: some View {
        settingsMenu(
            selection: selectedCohereLanguage.label,
            options: CohereTranscribeLanguage.allCases.map(\.label)
        ) { label in
            guard let language = CohereTranscribeLanguage.allCases.first(where: { $0.label == label }) else { return }
            controller.selectCohereLanguage(language)
        }
    }

    private var nemotron35LanguageMenu: some View {
        settingsMenu(
            selection: selectedNemotron35Language.label,
            options: Nemotron35Language.allCases.map(\.label)
        ) { label in
            guard let language = Nemotron35Language.allCases.first(where: { $0.label == label }) else { return }
            Task { await controller.setNemotron35Language(language) }
        }
    }

    private var whisperLanguageMenu: some View {
        settingsMenu(
            selection: selectedWhisperLanguage.label,
            options: WhisperKitLanguage.allCases.map(\.label)
        ) { label in
            guard let language = WhisperKitLanguage.allCases.first(where: { $0.label == label }) else { return }
            controller.selectWhisperLanguage(language)
        }
    }

    private func indicLanguageMenu(model: String) -> some View {
        let languages = BodhanLanguage.choices(for: model)
        return FixedWidthPopUp(
            selection: selectedBodhanLanguage.supported(for: model).label,
            options: languages.map(\.label),
            onSelectIndex: { index in
                guard index >= 0, index < languages.count else { return }
                controller.selectBodhanLanguage(languages[index])
            }
        )
        .frame(height: 24)
    }

    private var meetingSummarySettingsSection: some View {
        settingsDisclosureSection(
            "Meeting Summaries",
            summary: "\(appState.selectedMeetingSummaryBackend.label) writes notes after each meeting.",
            icon: "sparkles",
        ) {
            settingsRow("Include written notes") {
                settingsSwitch(isOn: appState.config.includeNotesInSummary) { newValue in
                    controller.updateConfig { $0.includeNotesInSummary = newValue }
                }
            }
            settingsDescription("Feed your written notes into AI summaries alongside the transcript. Notes are always kept verbatim either way.")

            Divider().background(MeetsTheme.surfaceBorder)
            settingsRow("Summary retries", controlWidth: meetingControlWidth) {
                integerInput(
                    label: "Summary retries",
                    value: Binding(
                        get: {
                            MeetingSummaryRetryPolicy.clampedRetryCount(appState.config.meetingSummaryRetryCount)
                        },
                        set: { newValue in
                            controller.updateConfig {
                                $0.meetingSummaryRetryCount = MeetingSummaryRetryPolicy.clampedRetryCount(newValue)
                            }
                        }
                    ),
                    range: 0...MeetingSummaryRetryPolicy.maximumRetryCount,
                    unit: { $0 == 1 ? "retry" : "retries" }
                )
            }
            settingsDescription("Retry transient AI summary failures before saving failed notes.")
        }
    }

    @ViewBuilder
    private func customLLMSettingsRows() -> some View {
        settingsRow(
            "API Format",
            description: "Request format for your endpoint.",
            controlWidth: meetingControlWidth
        ) {
            settingsMenu(
                selection: CustomLLMFormat(rawValue: appState.config.customLLMFormat)?.label ?? CustomLLMFormat.openAI.label,
                options: CustomLLMFormat.allCases.map(\.label)
            ) { label in
                guard let format = CustomLLMFormat.allCases.first(where: { $0.label == label }) else { return }
                controller.updateConfig { $0.customLLMFormat = format.rawValue }
            }
        }
        Divider().background(MeetsTheme.surfaceBorder)
        settingsRow(
            "API Key",
            description: "API key for your server. Stored locally.",
            controlWidth: meetingControlWidth
        ) {
            PastableSecureField(
                text: appState.config.customLLMAPIKey,
                placeholder: appState.config.customLLMFormat == CustomLLMFormat.anthropic.rawValue
                    ? "Required for Anthropic API"
                    : "Optional for local servers",
                onChange: { val in controller.updateConfig { $0.customLLMAPIKey = val } }
            )
            .frame(height: 22)
        }
        Divider().background(MeetsTheme.surfaceBorder)
        settingsRow(
            "Model",
            description: "Model your endpoint serves for this work.",
            controlWidth: meetingControlWidth
        ) {
            settingsModelTextField(
                currentModel: appState.config.customLLMModel,
                placeholder: appState.config.customLLMFormat == CustomLLMFormat.anthropic.rawValue
                    ? "claude-3-5-sonnet-20241022"
                    : "custom-model-id"
            ) { val in controller.updateConfig { $0.customLLMModel = val } }
        }
    }

    private var selectedCleanupBackend: TranscriptCleanupBackendOption {
        TranscriptCleanupBackendOption.resolved(appState.config.postProcessorBackend)
    }

    private var cleanupLocalModels: [PostProcessorOption] {
        PostProcessorOption.all
    }

    private var selectedCleanupLocalModel: PostProcessorOption {
        PostProcessorOption.resolve(id: appState.config.activePostProcessorId)
    }

    private var cleanupSourceDescription: String {
        switch selectedCleanupBackend.backend {
        case "local": return "Runs on-device with a downloaded Qwen3 GGUF model."
        case "acp_agent": return "Runs your installed agent (omp, Claude Code, Codex…) over Agent Client Protocol. No API key needed."
        case AppleIntelligenceBackend.backend: return "Runs on this Mac with Apple's on-device model. No account or API key needed."
        default: return "Uses the same account configured for meeting summaries."
        }
    }

    /// Apple Intelligence has no provider settings to enter, so its row is the
    /// live status itself — including the reason it cannot be used — next to
    /// the on-device privacy note.
    private var appleIntelligenceStatusRow: some View {
        let status = AppleIntelligenceBackend.status
        return settingsRow(
            AIProvider.appleIntelligence.label,
            description: AppleIntelligenceBackend.privacyDescription,
            controlWidth: meetingControlWidth
        ) {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.isAvailable ? MeetsTheme.success : MeetsTheme.textTertiary)
                    .frame(width: 6, height: 6)
                Text(status.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(status.isAvailable ? MeetsTheme.success : MeetsTheme.textTertiary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var cleanupConfiguredModel: String {
        TranscriptCleanupClient.configuredModel(for: selectedCleanupBackend, config: appState.config)
    }

    private func downloadSelectedCleanupModel() {
        let option = selectedCleanupLocalModel
        cleanupDownloads[option.id] = 0
        Task {
            do {
                try await controller.downloadPostProcessorModel(option) { progress in
                    cleanupDownloads[option.id] = progress
                }
                await MainActor.run { cleanupDownloads[option.id] = nil }
            } catch {
                await MainActor.run { cleanupDownloads[option.id] = nil }
            }
        }
    }

    private var recordingSettingsPane: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing20) {
            VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
                sectionHeading("Recording Shortcut", icon: "command")
                ShortcutsView(appState: appState, controller: controller).meetingRecordingShortcutSection
            }
            meetingTranscriptionSettingsSection

            settingsSection("Saved Audio", iconName: "record.circle") {
                settingsRow(
                    "Save meeting recording",
                    description: "Keep the recorded audio after transcription."
                ) {
                    settingsMenu(
                        selection: recordingSaveLabel(for: appState.config.meetingRecordingSavePolicy),
                        options: MeetingRecordingSavePolicy.allCases.map(recordingSaveLabel(for:))
                    ) { label in
                        guard let policy = recordingSavePolicy(for: label) else { return }
                        controller.updateConfig { $0.meetingRecordingSavePolicy = policy }
                    }
                }
                if appState.config.meetingRecordingSavePolicy != .never {
                    Divider().background(MeetsTheme.surfaceBorder)
                    settingsRow("Recording format") {
                        settingsMenu(
                            selection: appState.config.resolvedMeetingRecordingFileFormat.displayName,
                            options: MeetingRecordingFileFormat.allCases.map(recordingFileFormatLabel(for:))
                        ) { label in
                            guard let format = recordingFileFormat(for: label) else { return }
                            controller.updateConfig { $0.meetingRecordingFileFormat = format.rawValue }
                        }
                    }
                    settingsDescription("M4A is recommended for smaller files. WAV is lossless and uses more storage.")
                }
            }


            settingsDisclosureSection(
                "Sync & Export",
                summary: syncAndExportSettingsSummary,
                icon: "arrow.triangle.2.circlepath",
            ) {
                settingsRow(
                    "Auto-export meetings",
                    description: "Save each completed meeting to the chosen folder in the selected format."
                ) {
                    settingsSwitch(isOn: appState.config.autoExportMarkdownEnabled) { newValue in
                        controller.updateConfig { $0.autoExportMarkdownEnabled = newValue }
                    }
                }
                if appState.config.autoExportMarkdownEnabled {
                    Divider().background(MeetsTheme.surfaceBorder)
                    settingsRow(
                        "Destination folder",
                        description: "Folder where exported meetings are saved."
                    ) {
                        autoExportFolderPicker
                    }
                    Divider().background(MeetsTheme.surfaceBorder)
                    settingsRow(
                        "Content",
                        description: "What each export contains."
                    ) {
                        settingsMenu(
                            selection: appState.config.resolvedAutoExportMarkdownContent.displayName,
                            options: MeetingExportContent.allCases.map(\.displayName)
                        ) { label in
                            guard let index = MeetingExportContent.allCases.firstIndex(where: { $0.displayName == label }) else { return }
                            let content = MeetingExportContent.allCases[index]
                            controller.updateConfig { $0.autoExportMarkdownContent = content.rawValue }
                        }
                    }
                    Divider().background(MeetsTheme.surfaceBorder)
                    settingsRow(
                        "File format",
                        description: "Export file type."
                    ) {
                        settingsMenu(
                            selection: appState.config.resolvedAutoExportFileFormat.displayName,
                            options: MeetingAutoExportFileFormat.allCases.map(\.displayName)
                        ) { label in
                            guard let format = MeetingAutoExportFileFormat.allCases.first(where: { $0.displayName == label }) else { return }
                            controller.updateConfig { $0.autoExportFileFormat = format.rawValue }
                        }
                    }
                }
    
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow(
                    "Sync library to a cloud folder",
                    description: "Mirrors your meetings into a folder your cloud app already syncs — no accounts or keys needed. Notes, audio, and an index appear on your other devices automatically."
                ) {
                    settingsSwitch(
                        isOn: appState.config.cloudSyncEnabled,
                        onChange: { newValue in
                            if newValue {
                                cloudSyncEnable()
                            } else {
                                controller.setCloudSync(
                                    enabled: false,
                                    folderPath: appState.config.cloudSyncFolderPath,
                                    includesAudio: appState.config.cloudSyncIncludesAudio
                                )
                                cloudSyncOutcome = nil
                                cloudSyncOutcomeIsError = false
                            }
                        }
                    )
                }
                if appState.config.cloudSyncEnabled {
                    Divider().background(MeetsTheme.surfaceBorder)
                    if !cloudSyncLocations.isEmpty {
                        settingsRow(
                            "Cloud folder",
                            description: "Synced folder that holds your meeting library.",
                            controlWidth: meetingControlWidth
                        ) {
                            settingsMenu(
                                selection: selectedCloudSyncLocationName,
                                options: cloudSyncLocations.map(\.name),
                                onChange: { label in
                                    guard let location = cloudSyncLocations.first(where: { $0.name == label }) else { return }
                                    controller.setCloudSync(
                                        enabled: true,
                                        folderPath: location.path + "/" + CloudSyncDetector.mirrorFolderName,
                                        includesAudio: appState.config.cloudSyncIncludesAudio
                                    )
                                    cloudSyncOutcome = nil
                                    cloudSyncOutcomeIsError = false
                                }
                            )
                        }
                    } else {
                        settingsRow("Cloud folder") {
                            Text("No synced folders found — sign in to iCloud Drive, Dropbox, Google Drive, or OneDrive on this Mac.")
                                .font(.system(size: 12))
                                .foregroundStyle(MeetsTheme.textTertiary)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    Divider().background(MeetsTheme.surfaceBorder)
                    settingsRow(
                        "Include audio recordings",
                        description: "Also copy recording audio into the cloud folder."
                    ) {
                        settingsSwitch(
                            isOn: appState.config.cloudSyncIncludesAudio,
                            onChange: { newValue in
                                controller.setCloudSync(
                                    enabled: true,
                                    folderPath: appState.config.cloudSyncFolderPath,
                                    includesAudio: newValue
                                )
                            }
                        )
                    }
                    Divider().background(MeetsTheme.surfaceBorder)
                    settingsRow(
                        "Sync Now",
                        description: "Mirror all meetings to the cloud folder now."
                    ) {
                        actionButton(isSyncingCloud ? "Syncing…" : "Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                            syncNowToCloud()
                        }
                        .disabled(isSyncingCloud)
                    }
                    if let cloudSyncOutcome {
                        settingsOutcome(cloudSyncOutcome, isError: cloudSyncOutcomeIsError)
                    }
                }
                if appState.config.cloudSyncEnabled && !appState.config.cloudSyncFolderPath.isEmpty {
                    settingsDescription("Meetings are saved to \(cloudSyncFolderName) as Markdown notes (+ audio). Open that folder in iCloud Drive / Dropbox / Drive on your iPhone to read them.")
                }
            }
        }
    }

    private var calendarSettingsPane: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing20) {
            settingsDisclosureSection(
                "Calendars",
                summary: calendarSettingsSummary,
                icon: "calendar",
            ) {
                calendarSyncRow
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow(
                    "Use calendars already connected to your Mac",
                    description: "Add or remove accounts in macOS System Settings."
                ) {
                    actionButton("Manage accounts…", action: CalendarIntegration.openAccounts)
                }
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow(
                    "Upcoming meetings",
                    description: "Controls how many calendar days appear in Coming Up, the menu bar, and scheduled meeting checks.",
                    controlWidth: meetingControlWidth
                ) {
                    settingsMenu(
                        selection: selectedUpcomingMeetingsWindow.label,
                        options: UpcomingMeetingsWindow.allCases.map(\.label)
                    ) { label in
                        guard let window = UpcomingMeetingsWindow.allCases.first(where: { $0.label == label }) else { return }
                        controller.updateUpcomingMeetingsWindow(dayCount: window.dayCount)
                    }
                }
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow("Apple Calendar", description: "See what’s synced: accounts, calendars, per-calendar toggles, rename and delete.") {
                    inlineLinkButton("Manage…", systemImage: "arrow.right.circle") {
                        isShowingCalendarSettings = true
                    }
                    .help("Manage Apple Calendar accounts and calendars")
                }
            }

            settingsDisclosureSection(
                "Meeting Notifications",
                summary: notificationSettingsSummary,
                icon: "bell",
            ) {
                settingsRow("Scheduled meetings") {
                    settingsSwitch(isOn: appState.config.showScheduledMeetingNotifications) { newValue in
                        controller.updateConfig { $0.showScheduledMeetingNotifications = newValue }
                        if newValue { controller.ensureMeetingNotificationAuth() }
                    }
                }
                settingsDescription("Show notifications for calendar meetings with a join link.")

                if appState.config.showScheduledMeetingNotifications {
                    Divider().background(MeetsTheme.surfaceBorder)

                    settingsRow("Reminder timing") {
                        settingsMenu(
                            selection: scheduledMeetingLeadTimeLabel(for: appState.config.scheduledMeetingNotificationLeadTime),
                            options: ScheduledMeetingNotificationLeadTime.allCases.map(scheduledMeetingLeadTimeLabel(for:))
                        ) { label in
                            guard let leadTime = scheduledMeetingLeadTime(for: label) else { return }
                            controller.updateConfig { $0.scheduledMeetingNotificationLeadTime = leadTime }
                        }
                    }
                    settingsDescription("At start time avoids early calendar-only prompts before you join.")
                }

                Divider().background(MeetsTheme.surfaceBorder)

                settingsRow(
                    "Auto-record calendar meetings",
                    description: "Start recording automatically when a calendar meeting begins."
                ) {
                    settingsSwitch(isOn: appState.config.autoRecordMeetings) { newValue in
                        controller.updateConfig { $0.autoRecordMeetings = newValue }
                    }
                }

                Divider().background(MeetsTheme.surfaceBorder)

                settingsRow("Default action") {
                    settingsMenu(
                        selection: appState.config.meetingJoinDefaultAction.buttonLabel,
                        options: MeetingJoinDefaultAction.allCases.map(\.buttonLabel)
                    ) { label in
                        guard let action = meetingJoinDefaultAction(for: label) else { return }
                        controller.updateConfig { $0.meetingJoinDefaultAction = action }
                    }
                }
                settingsDescription("Primary button for notifications and Coming Up. Pick “Transcribe Only” if you join in another browser.")

                Divider().background(MeetsTheme.surfaceBorder)

                settingsRow("Auto-detected meetings") {
                    settingsSwitch(isOn: appState.config.showMeetingDetectionNotification) { newValue in
                        controller.updateConfig { $0.showMeetingDetectionNotification = newValue }
                        if newValue { controller.ensureMeetingNotificationAuth() }
                    }
                }
                settingsDescription("Show notifications when a call is detected from browser, camera, microphone, or app audio activity.")

                if appState.config.showMeetingDetectionNotification {
                    Divider().background(MeetsTheme.surfaceBorder)
                    customMeetingDetectionAppsControl
                        .padding(.top, MeetsTheme.spacing8)
                    mutedMeetingDetectionAppsControl
                }
            }
        }
        .onAppear {
            refreshMeetingCalendarSourcesIfNeeded()
        }
    }

    private var notesSettingsPane: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing20) {
            settingsDisclosureSection(
                "Meeting Notes",
                summary: "Templates applied to generated notes.",
                icon: "doc.text",
            ) {
                settingsRow(
                    "Default template",
                    description: "Template applied to new meeting summaries.",
                    controlWidth: meetingControlWidth
                ) {
                    meetingTemplateMenu(selectionID: appState.config.defaultMeetingTemplateID) { id in
                        controller.updateDefaultMeetingTemplate(id: id)
                    }
                }
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow(
                    "Templates",
                    description: "Create and edit summary templates.",
                    controlWidth: meetingControlWidth
                ) {
                    actionButton("Manage Templates…") {
                        controller.showMeetingTemplatesManager()
                    }
                }
            }
        }
    }

    private var advancedSettingsPane: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing20) {
            settingsDisclosureSection(
                "Automation",
                summary: appState.config.meetingHookEnabled ? "Runs after every completed meeting" : "Nothing runs after a meeting",
                icon: "terminal",
            ) {
                settingsRow(
                    "Enable post-meeting hook",
                    description: "Run a script after each completed meeting.",
                    controlWidth: meetingControlWidth
                ) {
                    settingsSwitch(isOn: appState.config.meetingHookEnabled) { newValue in
                        controller.updateConfig { $0.meetingHookEnabled = newValue }
                    }
                }
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow(
                    "Hook script",
                    description: "Executable run with meeting data (JSON) on stdin. Must already be runnable on its own.",
                    controlWidth: meetingControlWidth
                ) {
                    meetingHookPathPicker
                }
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow(
                    "Timeout",
                    description: "How long the hook may run before Meets stops waiting.",
                    controlWidth: meetingControlWidth
                ) {
                    meetingHookTimeoutControl
                }
            }
        }
    }

    // MARK: - Cloud Sync



    private var cloudSyncLocations: [CloudSyncLocation] {
        controller.cloudSyncLocations().filter(\.isAvailable)
    }

    private var selectedCloudSyncLocationName: String {
        guard !appState.config.cloudSyncFolderPath.isEmpty else { return cloudSyncLocations.first?.name ?? "Choose…" }
        for location in cloudSyncLocations where appState.config.cloudSyncFolderPath.hasPrefix(location.path + "/") {
            return location.name
        }
        return cloudSyncLocations.first?.name ?? "Choose…"
    }

    private var cloudSyncFolderName: String {
        let folderPath = appState.config.cloudSyncFolderPath
        guard !folderPath.isEmpty else { return "the chosen folder" }
        return folderPath.hasSuffix("/" + CloudSyncDetector.mirrorFolderName)
            ? CloudSyncDetector.mirrorFolderName
            : (folderPath as NSString).lastPathComponent
    }

    private func cloudSyncEnable() {
        let locations = cloudSyncLocations
        if locations.contains(where: {
            appState.config.cloudSyncFolderPath.hasPrefix($0.path + "/")
        }) {
            // The configured folder is still available — keep its path.
            controller.setCloudSync(
                enabled: true,
                folderPath: appState.config.cloudSyncFolderPath,
                includesAudio: appState.config.cloudSyncIncludesAudio
            )
        } else if let first = locations.first {
            controller.setCloudSync(
                enabled: true,
                folderPath: first.path + "/" + CloudSyncDetector.mirrorFolderName,
                includesAudio: appState.config.cloudSyncIncludesAudio
            )
        } else {
            controller.setCloudSync(
                enabled: true,
                folderPath: "",
                includesAudio: appState.config.cloudSyncIncludesAudio
            )
        }
        cloudSyncOutcome = nil
        cloudSyncOutcomeIsError = false
    }

    private func syncNowToCloud() {
        guard !isSyncingCloud else { return }
        isSyncingCloud = true
        cloudSyncOutcome = nil
        cloudSyncOutcomeIsError = false
        Task {
            let outcome: String?
            let isError: Bool
            if appState.config.cloudSyncEnabled,
               !appState.config.cloudSyncFolderPath.isEmpty {
                if let text = await controller.syncAllToCloud() {
                    outcome = text
                    isError = false
                } else {
                    outcome = "Nothing to mirror — meetings will sync automatically as they complete."
                    isError = false
                }
            } else {
                outcome = "Turn on cloud sync and choose a folder first."
                isError = true
            }
            guard !Task.isCancelled else { return }
            isSyncingCloud = false
            cloudSyncOutcome = outcome
            cloudSyncOutcomeIsError = isError
        }
    }

    // MARK: - Calendar management

    private var calendarSyncRow: some View {
        settingsRow("Sync with Apple Calendar", description: calendarSyncDescription) {
            calendarSyncControl
        }
    }

    private var calendarSyncDescription: String {
        switch appState.calendarAuthorization {
        case .unknown, .denied, .writeOnly:
            return "Meets reads your calendars for upcoming meetings. Full access is required."
        case .fullAccess:
            return "Meets reads your calendars for upcoming meetings."
        }
    }

    @ViewBuilder
    private var calendarSyncControl: some View {
        switch appState.calendarAuthorization {
        case .fullAccess:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MeetsTheme.success)
                Text("On")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MeetsTheme.textSecondary)
                Spacer(minLength: 0)
            }
        case .writeOnly:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MeetsTheme.transcribing)
                Text("Limited")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MeetsTheme.textSecondary)
                Spacer(minLength: 0)
            }
        case .denied:
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MeetsTheme.recording)
                Text("Off")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MeetsTheme.textSecondary)
                Spacer(minLength: 0)
                inlineLinkButton("Request Access", systemImage: "arrow.clockwise") {
                    refreshMeetingCalendarSources()
                }
                .disabled(isRefreshingCalendarAccess)
            }
        case .unknown:
            inlineLinkButton(isRefreshingCalendarAccess ? "Checking…" : "Authorize") {
                refreshMeetingCalendarSources()
            }
            .disabled(isRefreshingCalendarAccess)
        }
    }

    private var aiSettingsPane: some View {
        // One snapshot per body evaluation, shared by the connection lines and
        // the default menus so they cannot disagree — and identical to the one
        // the meeting detail menu and status bar read.
        let state = controller.aiConnectionState
        return VStack(alignment: .leading, spacing: MeetsTheme.spacing20) {
            aiConnectionsSection(state: state)
            aiDefaultsSection(state: state)
            meetingSummarySettingsSection
        }
    }

    /// The list is the shape of the page: one collapsed row per service showing
    /// its name and connection state, with that service's settings behind the
    /// row. Connecting here deliberately leaves the defaults below alone, so
    /// signing in never redirects work the user already routed.
    private func aiConnectionsSection(state: AIConnectionState) -> some View {
        settingsSection("Connections", iconName: "link") {
            ForEach(AIProvider.allCases) { provider in
                if provider != AIProvider.allCases.first {
                    Divider().background(MeetsTheme.surfaceBorder)
                }

                let isExpanded = expandedAIProviders.contains(provider)
                VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if isExpanded {
                                expandedAIProviders.remove(provider)
                            } else {
                                expandedAIProviders.insert(provider)
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(MeetsTheme.textTertiary)
                                .frame(width: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.label)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(MeetsTheme.textPrimary)
                                Text(aiConnectionLine(provider, state: state))
                                    .font(.system(size: 11))
                                    .foregroundStyle(MeetsTheme.textTertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(provider.label)
                    .accessibilityValue(aiConnectionLine(provider, state: state))
                    .accessibilityHint(isExpanded ? "Hide settings" : "Show settings")

                    if isExpanded {
                        aiConnectionRows(provider, state: state)
                            .padding(.top, MeetsTheme.spacing8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
    }

    /// Local servers say where they run: for them "Not connected" means a
    /// missing URL or model, not a missing account.
    private func aiConnectionLine(_ provider: AIProvider, state: AIConnectionState) -> String {
        let connected = AIProviderDirectory.isConnected(provider, config: appState.config, state: state)
        let status = connected ? "Connected" : "Not connected"
        return provider.isLocalServer ? "\(status) · Runs on a server on this Mac" : status
    }

    /// Plain-text list of the agents this Mac can run. Choosing the agent
    /// happens under Defaults; this is only the inventory discovery found.
    /// The free-text field survives as the empty-state fallback because
    /// discovery only knows the launchers it ships with, so a bespoke agent
    /// would otherwise be unreachable here.
    @ViewBuilder
    private func acpInstalledAgentList(state: AIConnectionState) -> some View {
        if state.installedACPAgents.isEmpty {
            settingsRow(
                "Command",
                description: "Launcher for a custom ACP agent.",
                controlWidth: meetingControlWidth
            ) {
                PastableTextField(
                    text: appState.config.acpAgentCommand,
                    placeholder: "omp acp",
                    onChange: { val in controller.updateConfig { $0.acpAgentCommand = val } }
                )
                .frame(height: 22)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(state.installedACPAgents, id: \.command) { agent in
                    HStack(spacing: 6) {
                        Text(agent.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(MeetsTheme.textSecondary)
                        Text(agent.command)
                            .font(.system(size: 10))
                            .foregroundStyle(MeetsTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func aiConnectionRows(_ provider: AIProvider, state: AIConnectionState) -> some View {
        switch provider {
        case .chatGPT:
            settingsRow(
                provider.label,
                description: aiConnectionLine(provider, state: state),
                controlWidth: meetingControlWidth
            ) {
                chatGPTAccountControl(selectMeetingSummaryBackend: false)
            }
        case .openAI:
            settingsRow(
                provider.label,
                description: aiConnectionLine(provider, state: state),
                controlWidth: meetingControlWidth
            ) {
                PastableSecureField(
                    text: appState.config.openAIAPIKey,
                    placeholder: "sk-...",
                    onChange: { val in controller.updateConfig { $0.openAIAPIKey = val } }
                )
                .frame(height: 22)
            }
            // OPENAI_API_KEY can connect this provider with the field above
            // still empty, so report the key the request path would use.
            keyStatusRow(key: AIProviderDirectory.resolvedOpenAIAPIKey(config: appState.config, state: state))
        case .openRouter:
            settingsRow(
                provider.label,
                description: aiConnectionLine(provider, state: state),
                controlWidth: meetingControlWidth
            ) {
                openRouterAccountControl(selectMeetingSummaryBackend: false)
            }
        case .customLLM:
            settingsRow(
                provider.label,
                description: aiConnectionLine(provider, state: state),
                controlWidth: meetingControlWidth
            ) {
                PastableTextField(
                    text: appState.config.customLLMURL,
                    placeholder: appState.config.customLLMFormat == CustomLLMFormat.anthropic.rawValue
                        ? "https://api.anthropic.com"
                        : "http://localhost:8080/v1",
                    onChange: { val in controller.updateConfig { $0.customLLMURL = val } }
                )
                .frame(height: 22)
            }
            Divider().background(MeetsTheme.surfaceBorder)
            customLLMSettingsRows()
        case .acpAgent:
            acpInstalledAgentList(state: state)
        case .appleIntelligence:
            appleIntelligenceStatusRow
        case .ollama:
            settingsRow(
                provider.label,
                description: aiConnectionLine(provider, state: state),
                controlWidth: meetingControlWidth
            ) {
                PastableTextField(
                    text: appState.config.ollamaURL,
                    placeholder: "http://localhost:11434",
                    onChange: { val in controller.updateConfig { $0.ollamaURL = val } }
                )
                .frame(height: 22)
            }
        case .lmStudio:
            settingsRow(
                provider.label,
                description: aiConnectionLine(provider, state: state),
                controlWidth: meetingControlWidth
            ) {
                PastableTextField(
                    text: appState.config.lmStudioURL,
                    placeholder: "http://localhost:1234",
                    onChange: { val in controller.updateConfig { $0.lmStudioURL = val } }
                )
                .frame(height: 22)
            }
            Divider().background(MeetsTheme.surfaceBorder)
            settingsRow(
                "Model",
                description: "Model LM Studio serves for this work.",
                controlWidth: meetingControlWidth
            ) {
                settingsModelTextField(
                    currentModel: appState.config.lmStudioModel,
                    placeholder: "Select a loaded LM Studio model"
                ) { val in controller.updateConfig { $0.lmStudioModel = val } }
            }
        }
    }

    /// The two choices the rest of the app falls back to. Only connected
    /// providers are offered, and a provider that has since gone away keeps
    /// its entry — marked — so a picker never silently reassigns the choice.
    private func aiDefaultsSection(state: AIConnectionState) -> some View {
        settingsDisclosureSection(
            "Defaults",
            summary: aiDefaultsSummary,
            icon: "slider.horizontal.3",
        ) {
            settingsRow(
                "Default summary backend",
                description: "Provider that writes AI meeting summaries.",
                controlWidth: meetingControlWidth
            ) {
                settingsMenu(
                    selection: aiSummarySelectionLabel(state: state),
                    options: aiSummaryPickerLabels(state: state)
                ) { label in
                    guard let option = aiSummaryOption(matchingPickerLabel: label) else { return }
                    controller.selectMeetingSummaryBackend(option)
                }
            }
            aiSummaryModelRows
            Divider().background(MeetsTheme.surfaceBorder)
            settingsRow(
                "Fallback summary backend",
                description: "Provider used when the default summary backend fails.",
                controlWidth: meetingControlWidth
            ) {
                settingsMenu(
                    selection: aiFallbackSummarySelectionLabel(state: state),
                    options: aiFallbackSummaryPickerLabels(state: state)
                ) { label in
                    guard let option = aiSummaryOption(matchingPickerLabel: label) else {
                        controller.updateConfig { $0.fallbackSummaryBackend = "" }
                        return
                    }
                    controller.updateConfig { $0.fallbackSummaryBackend = option.backend }
                }
            }
            Divider().background(MeetsTheme.surfaceBorder)
            settingsRow(
                "AI transcript cleanup",
                description: "Automatically clean filler words and false starts from transcripts."
            ) {
                settingsSwitch(isOn: appState.config.enablePostProcessor) { newValue in
                    controller.setPostProcessorEnabled(newValue)
                }
            }
            if appState.config.enablePostProcessor {
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow(
                    "Default cleanup source",
                    description: cleanupSourceDescription,
                    controlWidth: meetingControlWidth
                ) {
                    settingsMenu(
                        selection: aiCleanupSelectionLabel(state: state),
                        options: aiCleanupPickerLabels(state: state)
                    ) { label in
                        guard let option = aiCleanupOption(matchingPickerLabel: label) else { return }
                        controller.selectPostProcessorBackend(option)
                    }
                }
                aiCleanupModelRows
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow(
                    "Fallback cleanup source",
                    description: "Source used when the default cleanup source fails.",
                    controlWidth: meetingControlWidth
                ) {
                    settingsMenu(
                        selection: aiFallbackCleanupSelectionLabel(state: state),
                        options: aiFallbackCleanupPickerLabels(state: state)
                    ) { label in
                        guard let option = aiCleanupOption(matchingPickerLabel: label) else {
                            controller.updateConfig { $0.fallbackPostProcessorBackend = "" }
                            return
                        }
                        controller.updateConfig { $0.fallbackPostProcessorBackend = option.backend }
                    }
                }
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow(
                    "Cleanup prompt",
                    description: "Edit the instructions used for cleanup.",
                    controlWidth: meetingControlWidth
                ) {
                    actionButton("Manage Prompts…") {
                        isShowingCleanupPromptManager = true
                    }
                }
            }
        }
    }

    private var aiDefaultsSummary: String {
        let summaries = "\(appState.selectedMeetingSummaryBackend.label) writes summaries"
        return appState.config.enablePostProcessor
            ? summaries + " · \(selectedCleanupBackend.label) cleans transcripts."
            : summaries + " · transcript cleanup is off."
    }

    /// The model rows for whichever provider is the summary default. They sit
    /// with the default rather than the connection because that is the choice
    /// they configure.
    @ViewBuilder
    private var aiSummaryModelRows: some View {
        let backend = appState.selectedMeetingSummaryBackend
        if backend == .chatGPT {
            Divider().background(MeetsTheme.surfaceBorder)
            settingsRow(
                "Model",
                description: "Model used for meeting summaries.",
                controlWidth: meetingControlWidth
            ) {
                settingsModelMenu(
                    currentModel: appState.config.chatGPTModel,
                    presets: SummaryModelPreset.chatGPTModels
                ) { val in controller.updateConfig { $0.chatGPTModel = val } }
            }
            summaryThinkingRow(model: appState.config.chatGPTModel, presets: SummaryModelPreset.chatGPTModels)
        } else if backend == .openAI {
            Divider().background(MeetsTheme.surfaceBorder)
            settingsRow(
                "Model",
                description: "Model used for meeting summaries.",
                controlWidth: meetingControlWidth
            ) {
                settingsModelMenu(
                    currentModel: appState.config.openAIModel,
                    presets: SummaryModelPreset.openAIModels
                ) { val in controller.updateConfig { $0.openAIModel = val } }
            }
            summaryThinkingRow(model: appState.config.openAIModel, presets: SummaryModelPreset.openAIModels)
        } else if backend == .ollama {
            Divider().background(MeetsTheme.surfaceBorder)
            settingsRow(
                "Model",
                description: "Model used for meeting summaries.",
                controlWidth: meetingControlWidth
            ) {
                settingsModelTextField(
                    currentModel: appState.config.ollamaModel,
                    placeholder: "qwen3.5"
                ) { val in controller.updateConfig { $0.ollamaModel = val } }
            }
        } else if backend == .lmStudio {
            Divider().background(MeetsTheme.surfaceBorder)
            settingsRow(
                "Model",
                description: "Model used for meeting summaries.",
                controlWidth: meetingControlWidth
            ) {
                settingsModelTextField(
                    currentModel: appState.config.lmStudioModel,
                    placeholder: "Select a loaded LM Studio model"
                ) { val in controller.updateConfig { $0.lmStudioModel = val } }
            }
        } else if backend == .customLLM {
            Divider().background(MeetsTheme.surfaceBorder)
            settingsRow(
                "Model",
                description: "Model used for meeting summaries.",
                controlWidth: meetingControlWidth
            ) {
                settingsModelTextField(
                    currentModel: appState.config.customLLMModel,
                    placeholder: appState.config.customLLMFormat == CustomLLMFormat.anthropic.rawValue
                        ? "claude-3-5-sonnet-20241022"
                        : "custom-model-id"
                ) { val in controller.updateConfig { $0.customLLMModel = val } }
            }
        } else if backend == .acpAgent {
            Divider().background(MeetsTheme.surfaceBorder)
            acpAgentRow(description: "Agent that writes meeting summaries.")
            Divider().background(MeetsTheme.surfaceBorder)
            acpModelMenuRow
            Divider().background(MeetsTheme.surfaceBorder)
            acpThinkingMenuRow
        } else if backend == .appleIntelligence {
            // The system on-device model exposes no model or effort to pick.
            settingsDescription("Apple Intelligence writes summaries with the system model; there is nothing to choose.")
        } else {
            Divider().background(MeetsTheme.surfaceBorder)
            settingsRow(
                "Model",
                description: "Model used for meeting summaries.",
                controlWidth: meetingControlWidth
            ) {
                openRouterFreeModelMenu
            }
            Divider().background(MeetsTheme.surfaceBorder)
            settingsRow(
                "Custom model ID",
                description: "Use any OpenRouter model by its ID.",
                controlWidth: meetingControlWidth
            ) {
                settingsModelTextField(
                    currentModel: appState.config.openRouterModel,
                    placeholder: "provider/model",
                    onBeginEditing: { isUsingCustomOpenRouterModel = true }
                ) { val in controller.updateConfig { $0.openRouterModel = val } }
            }
        }
    }

    /// Thinking effort for the summary model, on the models that expose one.
    @ViewBuilder
    private func summaryThinkingRow(model: String, presets: [SummaryModelPreset]) -> some View {
        let resolvedModel = model.isEmpty ? (presets.first?.id ?? "") : model
        if !ReasoningEffortPolicy.selectableEfforts(for: resolvedModel).isEmpty {
            Divider().background(MeetsTheme.surfaceBorder)
            settingsRow("Thinking", controlWidth: meetingControlWidth) {
                settingsReasoningSlider(
                    model: resolvedModel,
                    preferred: appState.config.meetingSummaryReasoningEffort,
                    accessibilityLabel: "Meeting summary thinking"
                ) { effort in
                    controller.updateConfig { $0.meetingSummaryReasoningEffort = effort }
                }
            }
        }
    }

    /// Model rows for whichever cleanup source is the default: the on-device
    /// model keeps its download controls, hosted providers keep their model
    /// field, and Apple Intelligence has nothing to configure.
    @ViewBuilder
    private var aiCleanupModelRows: some View {
        if selectedCleanupBackend.isLocal {
            Divider().background(MeetsTheme.surfaceBorder)
            settingsRow(
                "Local model",
                description: "Downloaded model used for on-device cleanup.",
                controlWidth: meetingControlWidth
            ) {
                settingsMenu(
                    selection: selectedCleanupLocalModel.label,
                    options: cleanupLocalModels.map(\.label)
                ) { label in
                    if let option = cleanupLocalModels.first(where: { $0.label == label }) {
                        controller.selectPostProcessor(option)
                    }
                }
            }
            if !selectedCleanupLocalModel.isDownloaded {
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow(
                    "Download",
                    description: "Download the on-device cleanup model.",
                    controlWidth: meetingControlWidth
                ) {
                    if let progress = cleanupDownloads[selectedCleanupLocalModel.id] {
                        HStack(spacing: 6) {
                            ProgressView(value: progress)
                                .frame(width: 120)
                            Text("\(Int(progress * 100))%")
                                .font(.system(size: 11))
                                .foregroundStyle(MeetsTheme.textTertiary)
                        }
                    } else {
                        actionButton("Download \(selectedCleanupLocalModel.sizeLabel)", systemImage: "arrow.down.circle") {
                            downloadSelectedCleanupModel()
                        }
                    }
                }
            } else {
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow(
                    "Delete model",
                    description: "Remove the downloaded cleanup model to free space.",
                    controlWidth: meetingControlWidth
                ) {
                    actionButton("Delete", systemImage: "trash") {
                        controller.deletePostProcessorModel(selectedCleanupLocalModel)
                    }
                }
            }
        } else if selectedCleanupBackend == .hosted(.acpAgent) {
            Divider().background(MeetsTheme.surfaceBorder)
            acpAgentRow(description: "Agent that cleans up transcripts.")
            Divider().background(MeetsTheme.surfaceBorder)
            acpModelMenuRow
            Divider().background(MeetsTheme.surfaceBorder)
            acpThinkingMenuRow
        } else if selectedCleanupBackend != .appleIntelligence {
            Divider().background(MeetsTheme.surfaceBorder)
            settingsRow(
                "Model",
                description: "Model used for AI transcript cleanup.",
                controlWidth: meetingControlWidth
            ) {
                settingsModelTextField(
                    currentModel: cleanupConfiguredModel,
                    placeholder: TranscriptCleanupClient.defaultModel(for: selectedCleanupBackend)
                ) { newModel in
                    controller.updateConfig { config in
                        switch selectedCleanupBackend.backend {
                        case "chatgpt": config.postProcessorChatGPTModel = newModel
                        case "openai": config.postProcessorOpenAIModel = newModel
                        case "openrouter": config.postProcessorOpenRouterModel = newModel
                        case "ollama": config.postProcessorOllamaModel = newModel
                        case "lmstudio": config.postProcessorLMStudioModel = newModel
                        default: config.postProcessorCustomLLMModel = newModel
                        }
                    }
                }
            }
        }
    }

    /// A default's menu entry keeps its provider even when that provider is no
    /// longer connected, marked so the loss is visible.
    private static let aiNotConnectedSuffix = " · Not connected"

    private func aiSummaryPickerLabels(state: AIConnectionState) -> [String] {
        var labels = AIProviderDirectory.connectedSummaryProviders(config: appState.config, state: state).map(\.label)
        let selected = appState.selectedMeetingSummaryBackend
        if !aiIsConnected(selected, state: state) {
            labels.append(selected.label + Self.aiNotConnectedSuffix)
        }
        return labels
    }

    private func aiSummarySelectionLabel(state: AIConnectionState) -> String {
        let selected = appState.selectedMeetingSummaryBackend
        return aiIsConnected(selected, state: state)
            ? selected.label
            : selected.label + Self.aiNotConnectedSuffix
    }

    private func aiSummaryOption(matchingPickerLabel label: String) -> MeetingSummaryBackendOption? {
        let name = aiBaseLabel(label)
        return MeetingSummaryBackendOption.all.first(where: { $0.label == name })
    }

    private func aiIsConnected(_ option: MeetingSummaryBackendOption, state: AIConnectionState) -> Bool {
        guard let provider = AIProvider(summaryOption: option) else { return false }
        return AIProviderDirectory.isConnected(provider, config: appState.config, state: state)
    }

    private func aiCleanupPickerLabels(state: AIConnectionState) -> [String] {
        var labels = AIProviderDirectory.connectedCleanupBackends(config: appState.config, state: state).map(\.label)
        let selected = selectedCleanupBackend
        if !aiIsConnected(selected, state: state) {
            labels.append(selected.label + Self.aiNotConnectedSuffix)
        }
        return labels
    }

    private func aiCleanupSelectionLabel(state: AIConnectionState) -> String {
        let selected = selectedCleanupBackend
        return aiIsConnected(selected, state: state)
            ? selected.label
            : selected.label + Self.aiNotConnectedSuffix
    }

    private func aiCleanupOption(matchingPickerLabel label: String) -> TranscriptCleanupBackendOption? {
        let name = aiBaseLabel(label)
        return TranscriptCleanupBackendOption.all.first(where: { $0.label == name })
    }

    /// The on-device cleanup model belongs to no provider and needs no account.
    private func aiIsConnected(_ option: TranscriptCleanupBackendOption, state: AIConnectionState) -> Bool {
        if option.isLocal { return true }
        guard let provider = AIProvider(cleanupBackend: option) else { return false }
        return AIProviderDirectory.isConnected(provider, config: appState.config, state: state)
    }

    /// Strips the not-connected marker so a menu pick maps back to its option.
    private func aiBaseLabel(_ label: String) -> String {
        label.hasSuffix(Self.aiNotConnectedSuffix)
            ? String(label.dropLast(Self.aiNotConnectedSuffix.count))
            : label
    }

    /// "None" stands for the empty fallback value: nothing runs, the failure
    /// surfaces.
    private static let aiNoFallbackLabel = "None"

    /// A fallback equal to the default never runs, so the default is left out
    /// of the list. A stored pick that has since gone away stays listed, marked.
    private func aiFallbackSummaryPickerLabels(state: AIConnectionState) -> [String] {
        let defaultOption = appState.selectedMeetingSummaryBackend
        let connected = AIProviderDirectory.connectedSummaryProviders(config: appState.config, state: state)
            .map(\.label)
            .filter { $0 != defaultOption.label }
        var labels = [Self.aiNoFallbackLabel] + connected
        let stored = appState.config.fallbackSummaryBackend
        if !stored.isEmpty,
           stored != defaultOption.backend,
           let option = MeetingSummaryBackendOption.all.first(where: { $0.backend == stored }),
           !labels.contains(option.label) {
            labels.append(option.label + Self.aiNotConnectedSuffix)
        }
        return labels
    }

    private func aiFallbackSummarySelectionLabel(state: AIConnectionState) -> String {
        let defaultOption = appState.selectedMeetingSummaryBackend
        let stored = appState.config.fallbackSummaryBackend
        guard !stored.isEmpty,
              stored != defaultOption.backend,
              let option = MeetingSummaryBackendOption.all.first(where: { $0.backend == stored })
        else { return Self.aiNoFallbackLabel }
        return aiFallbackSummaryPickerLabels(state: state).contains(option.label)
            ? option.label
            : option.label + Self.aiNotConnectedSuffix
    }

    private func aiFallbackCleanupPickerLabels(state: AIConnectionState) -> [String] {
        let defaultOption = selectedCleanupBackend
        let connected = AIProviderDirectory.connectedCleanupBackends(config: appState.config, state: state)
            .map(\.label)
            .filter { $0 != defaultOption.label }
        var labels = [Self.aiNoFallbackLabel] + connected
        let stored = appState.config.fallbackPostProcessorBackend
        if !stored.isEmpty,
           stored != defaultOption.backend,
           let option = TranscriptCleanupBackendOption.all.first(where: { $0.backend == stored }),
           !labels.contains(option.label) {
            labels.append(option.label + Self.aiNotConnectedSuffix)
        }
        return labels
    }

    private func aiFallbackCleanupSelectionLabel(state: AIConnectionState) -> String {
        let defaultOption = selectedCleanupBackend
        let stored = appState.config.fallbackPostProcessorBackend
        guard !stored.isEmpty,
              stored != defaultOption.backend,
              let option = TranscriptCleanupBackendOption.all.first(where: { $0.backend == stored })
        else { return Self.aiNoFallbackLabel }
        return aiFallbackCleanupPickerLabels(state: state).contains(option.label)
            ? option.label
            : option.label + Self.aiNotConnectedSuffix
    }

    private var appearanceSettingsPane: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing20) {
            settingsSection("Recording Indicator", iconName: "capsule") {
                settingsRow(
                    "Position",
                    description: "Shown automatically while a meeting is preparing, recording, or transcribing."
                ) {
                    let isCustom = appState.config.indicatorAnchor == .custom
                    let selection = isCustom ? customIndicatorPositionLabel : appState.config.indicatorAnchor.label
                    let options = (isCustom ? [customIndicatorPositionLabel] : [])
                        + IndicatorAnchor.allCases.filter { $0 != .custom }.map(\.label)
                    settingsMenu(
                        selection: selection,
                        options: options
                    ) { label in
                        if label == customIndicatorPositionLabel { return }
                        guard let anchor = IndicatorAnchor.allCases.first(where: { $0.label == label }) else { return }
                        controller.updateConfig { $0.indicatorAnchor = anchor }
                        controller.refreshIndicatorPresentation()
                    }
                }
            }

            settingsSection("Menu Bar", iconName: "menubar.rectangle") {
                settingsRow("Menu bar icon") {
                    menuBarIconPicker
                }
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow("Show hotkey in menu bar") {
                    settingsSwitch(isOn: appState.config.showHotkeyInMenuBar) { newValue in
                        controller.updateConfig { $0.showHotkeyInMenuBar = newValue }
                    }
                }
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow("Show next meeting in menu bar") {
                    settingsSwitch(isOn: appState.config.showNextMeetingInMenuBar) { newValue in
                        controller.updateConfig { $0.showNextMeetingInMenuBar = newValue }
                    }
                }
            }

            settingsSection("Theme & Sound", iconName: "paintpalette") {
                settingsRow("Dark mode") {
                    settingsSwitch(isOn: appState.config.darkMode) { newValue in
                        controller.updateConfig { $0.darkMode = newValue }
                    }
                }
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow("Accent color") {
                    glassTintPicker
                }
                Divider().background(MeetsTheme.surfaceBorder)
                settingsRow("Play sound effects") {
                    settingsSwitch(isOn: appState.config.soundEnabled) { newValue in
                        controller.updateConfig { $0.soundEnabled = newValue }
                    }
                }
            }

            if appState.config.maraudersMapUnlocked {
                settingsDisclosureSection(
                    "Marauder\u{2019}s Map",
                    summary: "Meeting countdown audio and reset controls.",
                    icon: "map",
                ) {
                    settingsRow("Meeting countdown audio") {
                        maraudersMapControl
                    }
                    Divider().background(MeetsTheme.surfaceBorder)
                    settingsRow("") {
                        actionButton("Mischief Managed") {
                            SoundController.stopMaraudersMapClip()
                            isPreviewingClip = false
                            controller.resetMaraudersMap()
                        }
                    }
                }
            }
        }
    }

    private var glassTintPicker: some View {
        HStack(spacing: 6) {
            ForEach(Self.accentPresets, id: \.hex) { preset in
                let isSelected = appState.config.recordingColorHex.lowercased() == preset.hex
                Button {
                    controller.updateConfig { $0.recordingColorHex = preset.hex }
                } label: {
                    Circle()
                        .fill(Color(hex: preset.hex))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle().strokeBorder(Color.white.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
                        )
                        .overlay(
                            Circle().strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help(preset.name)
            }
        }
    }

    /// Twelve choices, wrapped to as many rows as the control column needs: a
    /// row that runs off the right edge with no scroll indicator reads as a
    /// truncated list of icons, not as a list you can scroll, and this row is
    /// the only place the whole set is ever visible.
    private var menuBarIconPicker: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 26, maximum: 26), spacing: 4)],
            spacing: 4
        ) {
            ForEach(MenuBarIconRenderer.options, id: \.id) { option in
                let isSelected = appState.config.menuBarIcon == option.id
                Button {
                    controller.updateConfig { $0.menuBarIcon = option.id }
                } label: {
                    Group {
                        if option.id == "meets",
                           let img = MenuBarIconRenderer.make(choice: "meets") {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: option.id)
                                .font(.system(size: 12))
                        }
                    }
                    .foregroundStyle(isSelected ? MeetsTheme.accent : MeetsTheme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isSelected ? MeetsTheme.surfaceSelected : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.white.opacity(isSelected ? 0.3 : 0.08), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help(option.label)
            }
        }
        .frame(width: controlWidth, alignment: .trailing)
    }

    @ViewBuilder
    private func chatGPTAccountControl(selectMeetingSummaryBackend: Bool = true) -> some View {
        if appState.isChatGPTAuthenticated {
            Button {
                controller.signOutChatGPT()
            } label: {
                HStack(spacing: 5) {
                    OpenAILogoShape()
                        .fill(.white)
                        .frame(width: 10, height: 10)
                    Text("Signed in · Sign Out")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(MeetsTheme.success)
                .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
            }
            .buttonStyle(.plain)
        } else if isSigningInChatGPT {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Signing in...")
                    .font(.system(size: 11))
                    .foregroundStyle(MeetsTheme.textSecondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    isSigningInChatGPT = true
                    chatGPTSignInError = nil
                    Task {
                        let error = await controller.signInWithChatGPT(selectMeetingSummaryBackend: selectMeetingSummaryBackend)
                        isSigningInChatGPT = false
                        chatGPTSignInError = error
                    }
                } label: {
                    HStack(spacing: 5) {
                        OpenAILogoShape()
                            .fill(MeetsTheme.accentContent)
                            .frame(width: 10, height: 10)
                        Text("Sign in with ChatGPT")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(MeetsTheme.accentContent)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(MeetsTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                }
                .buttonStyle(.plain)

                if let chatGPTSignInError {
                    Text(chatGPTSignInError)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private func openRouterAccountControl(
        selectMeetingSummaryBackend: Bool = true
    ) -> some View {
        if appState.isOpenRouterAuthenticated {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MeetsTheme.success)
                        Text(appState.isOpenRouterEnvironmentManaged ? "Environment key" : "Connected")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(MeetsTheme.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()
                        .background(MeetsTheme.surfaceBorder)
                        .padding(.vertical, 5)

                    Button {
                        controller.manageOpenRouterKey()
                    } label: {
                        Text("Manage key")
                            .font(.system(size: 10))
                            .foregroundStyle(MeetsTheme.textSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .help("Manage this key at OpenRouter")

                    Divider()
                        .background(MeetsTheme.surfaceBorder)
                        .padding(.vertical, 5)

                    if appState.hasStoredOpenRouterCredential {
                        Button {
                            openRouterSignInError = controller.signOutOpenRouter()
                            if openRouterSignInError == nil && !appState.isOpenRouterAuthenticated {
                                isUsingCustomOpenRouterModel = false
                            }
                        } label: {
                            Text(appState.isOpenRouterEnvironmentManaged ? "Forget local" : "Disconnect")
                                .font(.system(size: 10))
                                .foregroundStyle(MeetsTheme.textSecondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .help("Remove Meets's local copy of this OpenRouter key")
                    } else {
                        Text("Managed externally")
                            .font(.system(size: 10))
                            .foregroundStyle(MeetsTheme.textTertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .lineLimit(1)
                    }
                }
                .frame(height: 24)
                .background(MeetsTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                        .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
                )

                if let openRouterSignInError {
                    Text(openRouterSignInError)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        } else if isSigningInOpenRouter {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting...")
                    .font(.system(size: 11))
                    .foregroundStyle(MeetsTheme.textSecondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    isSigningInOpenRouter = true
                    openRouterSignInError = nil
                    Task {
                        let error = await controller.signInWithOpenRouter(
                            selectMeetingSummaryBackend: selectMeetingSummaryBackend
                        )
                        isSigningInOpenRouter = false
                        openRouterSignInError = error
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "network")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Connect OpenRouter")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(MeetsTheme.accentContent)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(MeetsTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                }
                .buttonStyle(.plain)

                inlineLinkButton(isEnteringOpenRouterAPIKey ? "Cancel manual key" : "Enter API key manually") {
                    isEnteringOpenRouterAPIKey.toggle()
                    manualOpenRouterAPIKey = ""
                    openRouterSignInError = nil
                }

                if isEnteringOpenRouterAPIKey {
                    HStack(spacing: 6) {
                        PastableSecureField(
                            text: manualOpenRouterAPIKey,
                            placeholder: "sk-or-...",
                            onChange: { manualOpenRouterAPIKey = $0 }
                        )
                        .frame(height: 22)

                        actionButton("Save") {
                            openRouterSignInError = controller.storeManualOpenRouterAPIKey(
                                manualOpenRouterAPIKey,
                                selectMeetingSummaryBackend: selectMeetingSummaryBackend
                            )
                            if openRouterSignInError == nil {
                                manualOpenRouterAPIKey = ""
                                isEnteringOpenRouterAPIKey = false
                            }
                        }
                        .disabled(manualOpenRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if let openRouterSignInError {
                    Text(openRouterSignInError)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
    }

    private var maraudersMapControl: some View {
        HStack(spacing: MeetsTheme.spacing8) {
            settingsMenu(
                selection: SoundController.labelForClip(
                    id: appState.config.maraudersMapAudioClip,
                    customPath: appState.config.maraudersMapCustomAudioPath
                ),
                options: SoundController.maraudersMapClipLabels
            ) { label in
                if label == "Custom\u{2026}" {
                    pickCustomAudioFile()
                } else if let preset = SoundController.maraudersMapPresets
                    .first(where: { $0.label == label }) {
                    SoundController.stopMaraudersMapClip()
                    isPreviewingClip = false
                    controller.updateConfig {
                        $0.maraudersMapAudioClip = preset.id
                        $0.maraudersMapCustomAudioPath = nil
                    }
                    controller.updateMaraudersMapAudioClip()
                }
            }
            Button {
                if isPreviewingClip {
                    SoundController.stopMaraudersMapClip()
                    isPreviewingClip = false
                } else {
                    SoundController.playMaraudersMapClip(
                        id: appState.config.maraudersMapAudioClip,
                        customPath: appState.config.maraudersMapCustomAudioPath
                    ) {
                        isPreviewingClip = false
                    }
                    isPreviewingClip = true
                }
            } label: {
                Image(systemName: isPreviewingClip ? "stop.fill" : "play.fill")
                    .font(.system(size: 11))
                    .foregroundColor(MeetsTheme.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
    }

    // MARK: - Marauder's Map

    private func pickCustomAudioFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose an audio clip"
        panel.allowedContentTypes = [.mp3, .mpeg4Audio, .wav, .aiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let appSupportBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fputs("[meets] Could not resolve Application Support directory\n", stderr)
            return
        }

        do {
            let supportDir = appSupportBase
                .appendingPathComponent(Bundle.main.infoDictionary?["MeetsSupportDirectoryName"] as? String ?? "Meets")
            let destPath = try SoundController.importCustomClip(from: url, supportDir: supportDir)
            controller.updateConfig {
                $0.maraudersMapAudioClip = SoundController.customClipID
                $0.maraudersMapCustomAudioPath = destPath
            }
            controller.updateMaraudersMapAudioClip()
        } catch {
            fputs("[meets] Failed to import custom audio: \(error)\n", stderr)
        }
    }

    private func pickMeetingHookFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a hook script"
        panel.prompt = "Choose Script"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = preferredMeetingHookDirectoryURL()

        presentOpenPanel(panel) { url in
            controller.updateConfig { $0.meetingHookPath = url.standardizedFileURL.path }
        }
    }

    private func pickAutoExportFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for exported notes"
        panel.prompt = "Choose Folder"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = preferredAutoExportDirectoryURL()

        presentOpenPanel(panel) { url in
            controller.updateConfig { $0.autoExportMarkdownFolderPath = url.standardizedFileURL.path }
        }
    }

    private func preferredAutoExportDirectoryURL() -> URL {
        let configuredPath = appState.config.autoExportMarkdownFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredPath.isEmpty {
            let configuredURL = URL(fileURLWithPath: configuredPath).standardizedFileURL
            if FileManager.default.fileExists(atPath: configuredURL.path) {
                return configuredURL
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
    }

    private func preferredMeetingHookDirectoryURL() -> URL {
        let configuredPath = appState.config.meetingHookPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredPath.isEmpty {
            let configuredURL = URL(fileURLWithPath: configuredPath).standardizedFileURL
            let parentDirectory = configuredURL.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parentDirectory.path) {
                return parentDirectory
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    private func presentOpenPanel(_ panel: NSOpenPanel, onPick: @escaping (URL) -> Void) {
        NSApp.activate()
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                onPick(url)
            }
        } else {
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                onPick(url)
            }
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        settingsSection("System Access", iconName: "hand.raised") {
            interactionPermissionRow(.microphone)
            Divider().background(MeetsTheme.surfaceBorder)
            interactionPermissionRow(.accessibility)
            Divider().background(MeetsTheme.surfaceBorder)
            interactionPermissionRow(.inputMonitoring)
            Divider().background(MeetsTheme.surfaceBorder)
            interactionPermissionRow(.screenRecording)
            if appState.config.useCoreAudioTap {
                Divider().background(MeetsTheme.surfaceBorder)
                permissionStatusRow(
                    "System Audio",
                    state: isCheckingSystemAudioPermission
                        ? .checking
                        : (systemAudioGranted ? .granted : .idle),
                    action: {
                        guard !isCheckingSystemAudioPermission else { return }
                        isCheckingSystemAudioPermission = true
                        Task { @MainActor in
                            defer { isCheckingSystemAudioPermission = false }
                            systemAudioGranted = await CoreAudioSystemRecorder.requestSystemAudioAccess()
                        }
                    },
                    pane: "Privacy_ScreenCapture"
                )
            }
            Divider().background(MeetsTheme.surfaceBorder)
            permissionStatusRow(
                "Calendar",
                state: isCheckingCalendarPermission
                    ? .checking
                    : (calendarGranted ? .granted : .idle),
                action: {
                    guard !isCheckingCalendarPermission else { return }
                    isCheckingCalendarPermission = true
                    Task { @MainActor in
                        defer { isCheckingCalendarPermission = false }
                        await controller.refreshCalendarAccess(requestIfUndetermined: true)
                        calendarGranted = appState.calendarAuthorization == .fullAccess
                    }
                },
                pane: "Privacy_Calendars"
            )
        }
    }

    /// Rows backed by the permission coordinator: Grant, the in-flight wait,
    /// and the System Settings fallback all come from one state machine.
    private func interactionPermissionRow(_ kind: InteractionPermissionKind) -> some View {
        permissionStatusRow(
            kind.title,
            state: controller.permissionRequests.presentation(for: kind),
            action: { controller.permissionRequests.request(kind) },
            pane: kind.systemSettingsPane
        )
    }

    private func permissionStatusRow(
        _ name: String,
        state: PermissionRowPresentation,
        action: @escaping () -> Void,
        pane: String
    ) -> some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(state == .granted ? MeetsTheme.success : MeetsTheme.recording)
                        .frame(width: 8, height: 8)
                    Text(name)
                        .font(MeetsTheme.body())
                        .foregroundStyle(MeetsTheme.textPrimary)
                }
                Spacer()
                permissionStatusControl(state: state, action: action)
                Button {
                    openPrivacyPane(pane)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11))
                        .foregroundStyle(MeetsTheme.textTertiary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Open in System Settings")
            }
            .frame(minHeight: 32)

            if state == .hint {
                Text(PermissionRequestHint.openedSystemSettings.guidance)
                    .font(.system(size: 11))
                    .foregroundStyle(MeetsTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func permissionStatusControl(
        state: PermissionRowPresentation,
        action: @escaping () -> Void
    ) -> some View {
        switch state {
        case .granted:
            Text("Granted")
                .font(.system(size: 11))
                .foregroundStyle(MeetsTheme.success)
        case .checking:
            actionButton("Checking…", action: action)
                .disabled(true)
        case .pending:
            HStack(spacing: MeetsTheme.spacing8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for System Settings…")
                    .font(.system(size: 11))
                    .foregroundStyle(MeetsTheme.textSecondary)
                actionButton("Grant", action: action)
                    .disabled(true)
            }
        case .hint, .idle:
            actionButton("Grant", action: action)
        }
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private func screenContextControl() -> some View {
        if accessibilityGranted {
            settingsSwitch(isOn: appState.config.enableScreenContext) { newValue in
                handleScreenContextToggle(newValue)
            }
        } else {
            actionButton("Grant") {
                handleScreenContextToggle(true)
            }
        }
    }

    @discardableResult
    private func handleScreenContextToggle(_ enabled: Bool) -> Bool {
        guard enabled else {
            controller.updateConfig {
                $0.enableScreenContext = false
            }
            return false
        }

        guard accessibilityGranted else {
            pendingScreenContextEnable = true
            pendingScreenContextRequestedAt = Date().timeIntervalSince1970
            let granted = controller.requestScreenContextEnable()
            controller.refreshInteractionPermissionSnapshot()
            if granted {
                clearPendingScreenContextEnable()
            }
            return granted
        }

        controller.updateConfig { $0.enableScreenContext = true }
        return true
    }

    private func startPermissionMonitoring() {
        controller.beginInteractionPermissionMonitoring(clientID: permissionMonitoringClientID)
        refreshPermissionStatuses(for: .initialDisplay)
    }

    private func stopPermissionMonitoring() {
        controller.endInteractionPermissionMonitoring(clientID: permissionMonitoringClientID)
    }

    private func refreshPermissionStatuses(for reason: SettingsPermissionRefreshReason) {
        controller.syncCalendarAuthorizationState()
        calendarGranted = appState.calendarAuthorization == .fullAccess
        if reason.refreshesLaunchAtLogin {
            controller.refreshLaunchAtLoginState()
        }
        controller.refreshInteractionPermissionSnapshot()
        if !accessibilityGranted && appState.config.enableScreenContext {
            // The app lost Accessibility access since the toggle was enabled;
            // meeting context capture cannot run without it.
            controller.updateConfig {
                $0.enableScreenContext = false
            }
        }
        if reason.refreshesSystemAudio {
            refreshSystemAudioPermissionIfNeeded()
        }
    }

    private func clearPendingScreenContextEnable() {
        pendingScreenContextEnable = false
        pendingScreenContextRequestedAt = 0
    }

    private func refreshSystemAudioPermissionIfNeeded() {
        guard appState.config.useCoreAudioTap, !isCheckingSystemAudioPermission else { return }
        isCheckingSystemAudioPermission = true

        Task {
            let granted = await Task.detached(priority: .utility) {
                CoreAudioSystemRecorder.checkSystemAudioPermission()
            }.value
            await MainActor.run {
                self.systemAudioGranted = granted
                self.isCheckingSystemAudioPermission = false
            }
        }
    }

    // MARK: - Layout Primitives

    private func defaultSectionIcon(for title: String) -> String {
        switch title {
        case "Startup": "power"
        case "Permissions": "hand.raised"
        case "Recording": "record.circle"
        case "Appearance": "paintbrush"
        default: "slider.horizontal.3"
        }
    }

    private func sectionHeading(_ title: String, icon: String) -> some View {
        HStack(spacing: MeetsTheme.spacing8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MeetsTheme.textSecondary)
                .frame(width: 18)
            Text(title)
                .font(MeetsTheme.headline())
                .foregroundStyle(MeetsTheme.textPrimary)
        }
    }

    @ViewBuilder
    private func settingsSection(
        _ title: String,
        iconName: String? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading(title, icon: iconName ?? defaultSectionIcon(for: title))
                .padding(.horizontal, MeetsTheme.spacing20)
                .padding(.vertical, MeetsTheme.spacing16)

            Divider().background(MeetsTheme.surfaceBorder)

            VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
                content()
            }
            .padding(.horizontal, MeetsTheme.spacing20)
            .padding(.vertical, MeetsTheme.spacing16)
        }
        .background(MeetsTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerLarge))
    }

    /// Section card with a title, descriptive summary, and always-visible content.
    @ViewBuilder
    private func settingsDisclosureSection(
        _ title: String,
        summary: String,
        icon: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: MeetsTheme.spacing12) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MeetsTheme.textSecondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
                    Text(title)
                        .font(MeetsTheme.headline())
                        .foregroundStyle(MeetsTheme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(summary)
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: MeetsTheme.spacing16)
            }
            .padding(.horizontal, MeetsTheme.spacing20)
            .padding(.vertical, MeetsTheme.spacing16)

            Divider().background(MeetsTheme.surfaceBorder)

            VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
                content()
            }
            .padding(.horizontal, MeetsTheme.spacing20)
            .padding(.vertical, MeetsTheme.spacing16)
        }
        .background(MeetsTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerLarge))
    }

    /// Standardized row: label on left, control on right.
    /// Controls share a fixed-width column so they all right-align consistently.
    @ViewBuilder
    private func settingsRow(_ label: String, controlWidth rowControlWidth: CGFloat? = nil, @ViewBuilder control: () -> some View) -> some View {
        let width = rowControlWidth ?? controlWidth
        HStack(alignment: .center, spacing: MeetsTheme.spacing20) {
            Text(label)
                .font(MeetsTheme.body())
                .foregroundStyle(MeetsTheme.textPrimary)
                .layoutPriority(1)
            Spacer(minLength: MeetsTheme.spacing12)
            ZStack(alignment: .trailing) {
                Color.clear.frame(width: width, height: 1)
                control()
                    .frame(maxWidth: width)
            }
        }
        .padding(.vertical, MeetsTheme.spacing12)
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private func settingsRow(
        _ label: String,
        description: String,
        controlWidth rowControlWidth: CGFloat? = nil,
        @ViewBuilder control: () -> some View
    ) -> some View {
        let width = rowControlWidth ?? controlWidth
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: MeetsTheme.spacing20) {
                settingsRowLabel(label, description: description)
                    .layoutPriority(1)

                Spacer(minLength: MeetsTheme.spacing12)

                control()
                    .frame(width: width, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: MeetsTheme.spacing12) {
                settingsRowLabel(label, description: description)
                control()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.vertical, MeetsTheme.spacing12)
        .frame(minHeight: 52)
    }

    private func settingsRowLabel(_ label: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
            Text(label)
                .font(MeetsTheme.body())
                .foregroundStyle(MeetsTheme.textPrimary)
            Text(description)
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func settingsDescription(_ text: String) -> some View {
        Text(text)
            .font(MeetsTheme.caption())
            .foregroundStyle(MeetsTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, MeetsTheme.spacing4)
            .padding(.bottom, MeetsTheme.spacing12)
    }

    private func settingsOutcome(_ text: String, isError: Bool) -> some View {
        Text(text)
            .font(MeetsTheme.caption())
            .foregroundStyle(isError ? MeetsTheme.recording : MeetsTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, MeetsTheme.spacing8)
    }

    // MARK: - Controls

    @ViewBuilder
    private func settingsSwitch(isOn: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        HStack {
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: { onChange($0) }))
                .toggleStyle(.switch)
                .tint(MeetsTheme.accent)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private func settingsMenu(
        selection: String,
        options: [String],
        disabledOptions: Set<String> = [],
        onChange: @escaping (String) -> Void
    ) -> some View {
        FixedWidthPopUp(
            selection: selection,
            options: options,
            disabledOptions: disabledOptions,
            onChange: onChange
        )
            .frame(height: 24)
    }

    /// Accent text affordance for rows whose action is a link rather than a
    /// commit: "Manage…", "Open in System Settings", "Request Access". No fill;
    /// the 28pt frame matches the height of `actionButton` in the control column.
    @ViewBuilder
    private func inlineLinkButton(
        _ title: String,
        systemImage: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(MeetsTheme.accent)
            .frame(height: 28)
        }
        .buttonStyle(.plain)
    }

    private var mutedMeetingDetectionAppsControl: some View {
        let muted = Set(appState.config.mutedMeetingDetectionAppBundleIDs)
        return DisclosureGroup(isExpanded: $showMutedDetectionApps) {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
            ], alignment: .leading, spacing: 8) {
                ForEach(meetingDetectionAppOptions) { app in
                    mutedDetectionAppButton(app, isMuted: muted.contains(app.bundleID))
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Text("Don't notify me when a call is detected in these apps")
                    .font(MeetsTheme.body())
                    .foregroundStyle(MeetsTheme.textPrimary)
                Spacer(minLength: 8)
                if !muted.isEmpty {
                    Text(muted.count == 1 ? "1 muted" : "\(muted.count) muted")
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.textTertiary)
                }
            }
        }
        .padding(.top, MeetsTheme.spacing8)
    }

    /// Renders the app's bundled brand icon when available (colored PNG), else
    /// falls back to its SF Symbol.
    @ViewBuilder
    private func detectionAppIcon(_ app: MeetingDetectionAppOption) -> some View {
        if let brandIcon = app.brandIcon,
           let url = Bundle.main.url(forResource: brandIcon, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: app.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MeetsTheme.textTertiary)
        }
    }

    private func mutedDetectionAppButton(_ app: MeetingDetectionAppOption, isMuted: Bool) -> some View {
        Button {
            updateMutedMeetingDetectionApp(app.bundleID, isMuted: !isMuted)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isMuted ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isMuted ? MeetsTheme.accent : MeetsTheme.textTertiary)
                    .frame(width: 16)
                detectionAppIcon(app)
                    .frame(width: 14)
                Text(app.name)
                    .font(.system(size: 12))
                    .foregroundStyle(MeetsTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(isMuted ? MeetsTheme.accentSubtle : MeetsTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                    .strokeBorder(isMuted ? MeetsTheme.accent.opacity(0.35) : MeetsTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func updateMutedMeetingDetectionApp(_ bundleID: String, isMuted: Bool) {
        controller.updateConfig { config in
            var muted = Set(config.mutedMeetingDetectionAppBundleIDs)
            if isMuted {
                muted.insert(bundleID)
            } else {
                muted.remove(bundleID)
            }
            config.mutedMeetingDetectionAppBundleIDs = muted.sorted()
        }
    }

    // MARK: - Custom meeting apps

    @State private var customAppBundleID = ""
    @State private var customAppName = ""
    @State private var showMutedDetectionApps = false

    /// Editor for user-configured call apps (bundle ID + display name) that
    /// the meeting detector treats like built-in dedicated apps. Lets users
    /// add call-capable apps that aren't in the built-in list (Discord is
    /// built in; Telegram, Signal, Session, ... can be added here).
    private var customMeetingDetectionAppsControl: some View {
        let customApps = controller.customMeetingDetectionAppTable()
        return VStack(alignment: .leading, spacing: 10) {
            Text("Custom meeting apps — detect calls in other apps:")
                .font(MeetsTheme.body())
                .foregroundStyle(MeetsTheme.textPrimary)

            if customApps.isEmpty {
                Text("No custom apps yet. Add one below — e.g. Telegram, Signal, or any app you take calls in.")
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textTertiary)
            } else {
                ForEach(customApps.sorted(by: { $0.value < $1.value }), id: \.key) { bundleID, name in
                    HStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(MeetsTheme.textTertiary)
                            .frame(width: 14)
                        Text(name)
                            .font(.system(size: 12))
                            .foregroundStyle(MeetsTheme.textSecondary)
                            .lineLimit(1)
                        Text(bundleID)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(MeetsTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button {
                            controller.setCustomMeetingApp(bundleID: bundleID, name: "")
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(MeetsTheme.recording.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(name)")
                        .accessibilityLabel("Remove \(name)")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(MeetsTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                            .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
                    )
                }
            }

            HStack(spacing: 8) {
                TextField("Bundle ID (com.example.app)", text: $customAppBundleID)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(MeetsTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                            .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
                    )
                TextField("Name", text: $customAppName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: 90)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(MeetsTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                            .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
                    )
                Button {
                    let id = customAppBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !id.isEmpty else { return }
                    controller.setCustomMeetingApp(bundleID: id, name: customAppName)
                    customAppBundleID = ""
                    customAppName = ""
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MeetsTheme.accentContent)
                        .frame(width: 22, height: 22)
                        .background(MeetsTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                }
                .buttonStyle(.plain)
                .disabled(customAppBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Add custom meeting app")
            }
        }
    }

    // MARK: - Calendar management

    private func refreshMeetingCalendarSourcesIfNeeded() {
        guard !hasRefreshedMeetingCalendarSources else { return }
        hasRefreshedMeetingCalendarSources = true
        refreshMeetingCalendarSources()
    }

    private func refreshMeetingCalendarSources() {
        isRefreshingCalendarAccess = true
        Task {
            await controller.refreshCalendarAccess()
            isRefreshingCalendarAccess = false
        }
    }

    @ViewBuilder
    private var autoExportFolderPicker: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MeetsTheme.textTertiary)

                if appState.config.autoExportMarkdownFolderPath.isEmpty {
                    Text("Choose a folder…")
                        .font(.system(size: 12))
                        .foregroundStyle(MeetsTheme.textTertiary)
                        .lineLimit(1)
                } else {
                    Text(appState.config.autoExportMarkdownFolderPath)
                        .font(.system(size: 12))
                        .foregroundStyle(MeetsTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(MeetsTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                    .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
            )
            .help(appState.config.autoExportMarkdownFolderPath.isEmpty ? "No destination folder selected" : appState.config.autoExportMarkdownFolderPath)

            if !appState.config.autoExportMarkdownFolderPath.isEmpty {
                Button {
                    controller.updateConfig { $0.autoExportMarkdownFolderPath = "" }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MeetsTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(MeetsTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                        .overlay(
                            RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                                .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear destination folder")
                .help("Clear destination folder")
            }

            Button {
                pickAutoExportFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MeetsTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(MeetsTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                            .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose destination folder")
            .help("Choose destination folder")
        }
    }

    @ViewBuilder
    private var meetingHookPathPicker: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "doc.badge.gearshape")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MeetsTheme.textTertiary)

                if appState.config.meetingHookPath.isEmpty {
                    Text("Choose a script…")
                        .font(.system(size: 12))
                        .foregroundStyle(MeetsTheme.textTertiary)
                        .lineLimit(1)
                } else {
                    Text(appState.config.meetingHookPath)
                        .font(.system(size: 12))
                        .foregroundStyle(MeetsTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(MeetsTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                    .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
            )
            .frame(maxWidth: .infinity)
            .help(appState.config.meetingHookPath.isEmpty ? "No hook script selected" : appState.config.meetingHookPath)

            if !appState.config.meetingHookPath.isEmpty {
                Button {
                    controller.updateConfig { $0.meetingHookPath = "" }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MeetsTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(MeetsTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                        .overlay(
                            RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                                .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Clear hook script")
            }

            Button {
                pickMeetingHookFile()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MeetsTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(MeetsTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                            .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Choose hook script")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var meetingHookTimeoutControl: some View {
        integerInput(
            label: "Meeting hook timeout",
            value: Binding(
                get: { max(appState.config.meetingHookTimeoutSeconds, 1) },
                set: { newValue in
                    controller.updateConfig { $0.meetingHookTimeoutSeconds = max(newValue, 1) }
                }
            ),
            range: 1...600,
            unit: { $0 == 1 ? "second" : "seconds" }
        )
    }

    private func integerInput(
        label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int = 1,
        unit: @escaping (Int) -> String
    ) -> some View {
        let clampedValue = min(max(value.wrappedValue, range.lowerBound), range.upperBound)
        let clampedBinding = Binding(
            get: { min(max(value.wrappedValue, range.lowerBound), range.upperBound) },
            set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
        )

        return HStack(spacing: MeetsTheme.spacing8) {
            TextField(label, value: clampedBinding, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 72)
                .accessibilityLabel(label)

            Text(unit(clampedValue))
                .font(MeetsTheme.body())
                .foregroundStyle(MeetsTheme.textSecondary)
                .frame(width: 58, alignment: .leading)

            Stepper(label, value: clampedBinding, in: range, step: step)
                .labelsHidden()
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func meetingTemplateMenu(selectionID: String, onChange: @escaping (String) -> Void) -> some View {
        let allItems: [(id: String, label: String)] = {
            var items: [(String, String)] = [(MeetingTemplates.autoID, MeetingTemplates.auto.title)]
            items += controller.builtInMeetingTemplates().map { ($0.id, $0.title) }
            items += controller.customMeetingTemplates().map { ($0.id, $0.name) }
            return items
        }()
        let selectedLabel = allItems.first(where: { $0.id == selectionID })?.label ?? "Auto"
        FixedWidthPopUp(
            selection: selectedLabel,
            options: allItems.map(\.label),
            onSelectIndex: { index in
                guard index >= 0 && index < allItems.count else { return }
                onChange(allItems[index].id)
            }
        )
        .frame(height: 24)
    }

    @ViewBuilder
    private func settingsModelMenu(currentModel: String, presets: [SummaryModelPreset], onChange: @escaping (String) -> Void) -> some View {
        let menuPresets = SummaryModelPreset.menuPresets(presets, currentModel: currentModel)
        let effectiveModel = currentModel.isEmpty ? (presets.first?.id ?? "") : currentModel
        let selectedLabel = menuPresets.first(where: { $0.id == effectiveModel })?.label ?? menuPresets.first?.label ?? ""
        FixedWidthPopUp(
            selection: selectedLabel,
            options: menuPresets.map(\.label),
            onSelectIndex: { index in
                guard index >= 0 && index < menuPresets.count else { return }
                let selectedId = menuPresets[index].id
                onChange(selectedId == presets.first?.id ? "" : selectedId)
            }
        )
        .frame(height: 24)
    }

    @ViewBuilder
    private func settingsReasoningSlider(
        model: String,
        preferred: ReasoningEffort?,
        accessibilityLabel: String,
        onChange: @escaping (ReasoningEffort) -> Void
    ) -> some View {
        let efforts = ReasoningEffortPolicy.selectableEfforts(for: model)
        if let effectiveEffort = ReasoningEffortPolicy.resolvedEffort(
            for: model,
            preferred: preferred
        ) {
            HStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: {
                            Double(efforts.firstIndex(of: effectiveEffort) ?? 0)
                        },
                        set: { value in
                            let index = min(max(Int(value.rounded()), 0), efforts.count - 1)
                            onChange(efforts[index])
                        }
                    ),
                    in: 0 ... Double(efforts.count - 1),
                    step: 1
                )
                .tint(MeetsTheme.accent)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(effectiveEffort.label)

                Text(effectiveEffort.label)
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textSecondary)
                    .frame(width: 80, alignment: .trailing)
            }
            .frame(height: 24)
        }
    }

    @ViewBuilder
    private func settingsModelTextField(
        currentModel: String,
        placeholder: String,
        onBeginEditing: (() -> Void)? = nil,
        onChange: @escaping (String) -> Void
    ) -> some View {
        PastableTextField(
            text: currentModel,
            placeholder: placeholder,
            onBeginEditing: onBeginEditing,
            onChange: { value in
                onChange(value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        )
        .frame(height: 22)
    }

    @ViewBuilder
    private var openRouterFreeModelMenu: some View {
        if appState.openRouterSummaryCatalogState == .loading,
           appState.openRouterSummaryModels.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading models")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MeetsTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else if !appState.openRouterSummaryModels.isEmpty {
            let openRouterFreeModels = appState.openRouterSummaryModels
            let configuredModel = appState.config.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let configuredPreset = openRouterFreeModels.first { $0.id == configuredModel }
            let showsCustomSelection = isUsingCustomOpenRouterModel
                || (!configuredModel.isEmpty && configuredPreset == nil)
            let customLabel = configuredModel.isEmpty
                ? "Custom model ID"
                : "Custom: \(configuredModel)"
            let menuPresets = showsCustomSelection
                ? openRouterFreeModels + [SummaryModelPreset(id: configuredModel, label: customLabel)]
                : openRouterFreeModels
            let selectedLabel = showsCustomSelection
                ? customLabel
                : (configuredPreset?.label ?? openRouterFreeModels[0].label)

            HStack(spacing: 8) {
                FixedWidthPopUp(
                    selection: selectedLabel,
                    options: menuPresets.map(\.label),
                    onSelectIndex: { index in
                        guard index >= 0 && index < menuPresets.count else { return }
                        if showsCustomSelection && index == openRouterFreeModels.count {
                            isUsingCustomOpenRouterModel = true
                            return
                        }
                        isUsingCustomOpenRouterModel = false
                        let selectedID = openRouterFreeModels[index].id
                        controller.updateConfig {
                            $0.openRouterModel = OpenRouterModelSelection.persistedModelID(for: selectedID)
                        }
                    }
                )
                .frame(height: 24)
                if case .failed = appState.openRouterSummaryCatalogState {
                    actionButton("Retry") {
                        controller.loadOpenRouterModels(.text, force: true)
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                if case .failed(let message) = appState.openRouterSummaryCatalogState {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(MeetsTheme.textTertiary)
                        .lineLimit(1)
                }
                actionButton(appState.openRouterSummaryCatalogState == .idle ? "Load" : "Retry") {
                    controller.loadOpenRouterModels(.text, force: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func loadOpenRouterFreeModelsIfNeeded() {
        controller.loadOpenRouterModels(.text)
    }

    @ViewBuilder
    private func keyStatusRow(key: String) -> some View {
        HStack(spacing: 6) {
            Spacer()
            Circle()
                .fill(key.isEmpty ? MeetsTheme.textTertiary : MeetsTheme.success)
                .frame(width: 6, height: 6)
            Text(key.isEmpty ? "No API key configured" : "Key configured")
                .font(.system(size: 11))
                .foregroundStyle(key.isEmpty ? MeetsTheme.textTertiary : MeetsTheme.success)
        }
        .frame(minHeight: 20)
    }

    /// The standard compact action in a settings row: sized to its content and
    /// 28pt tall so it centres in the row's trailing control column. Pass
    /// `fillsWidth` only when the action is intentionally the card's full width.
    @ViewBuilder
    private func actionButton(
        _ title: String,
        systemImage: String? = nil,
        role: ButtonRole? = nil,
        fillsWidth: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let isDestructive = role == .destructive
        Button(action: action) {
            HStack(spacing: MeetsTheme.spacing8) {
                Text(title)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                }
            }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isDestructive ? MeetsTheme.recording : MeetsTheme.textPrimary)
                .padding(.horizontal, MeetsTheme.spacing12)
                .frame(height: 28)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .background(isDestructive ? MeetsTheme.recording.opacity(0.1) : MeetsTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                        .strokeBorder(
                            isDestructive ? MeetsTheme.recording.opacity(0.2) : MeetsTheme.surfaceBorder,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func recordingSaveLabel(for policy: MeetingRecordingSavePolicy) -> String {
        switch policy {
        case .never:
            return "Never"
        case .prompt:
            return "Ask every time"
        case .always:
            return "Always"
        }
    }

    private func recordingSavePolicy(for label: String) -> MeetingRecordingSavePolicy? {
        let policy = MeetingRecordingSavePolicy.allCases.first { recordingSaveLabel(for: $0) == label }
        if policy == nil {
            assertionFailure("Unexpected recording save label: \(label)")
        }
        return policy
    }

    private func recordingFileFormatLabel(for format: MeetingRecordingFileFormat) -> String {
        format.displayName
    }

    private func recordingFileFormat(for label: String) -> MeetingRecordingFileFormat? {
        let format = MeetingRecordingFileFormat.allCases.first { recordingFileFormatLabel(for: $0) == label }
        if format == nil {
            assertionFailure("Unexpected recording file format label: \(label)")
        }
        return format
    }

    private func scheduledMeetingLeadTimeLabel(for leadTime: ScheduledMeetingNotificationLeadTime) -> String {
        switch leadTime {
        case .atStart:
            return "At start time"
        case .oneMinute:
            return "1 min before"
        case .threeMinutes:
            return "3 min before"
        case .fiveMinutes:
            return "5 min before"
        }
    }

    private func scheduledMeetingLeadTime(for label: String) -> ScheduledMeetingNotificationLeadTime? {
        let leadTime = ScheduledMeetingNotificationLeadTime.allCases.first {
            scheduledMeetingLeadTimeLabel(for: $0) == label
        }
        if leadTime == nil {
            assertionFailure("Unexpected scheduled meeting notification lead time label: \(label)")
        }
        return leadTime
    }

    private func meetingJoinDefaultAction(for label: String) -> MeetingJoinDefaultAction? {
        let action = MeetingJoinDefaultAction.allCases.first { $0.buttonLabel == label }
        if action == nil {
            assertionFailure("Unexpected meeting join default action label: \(label)")
        }
        return action
    }
}

// MARK: - Pastable Secure Field (NSViewRepresentable)

/// NSSecureTextField subclass that handles Cmd+V/C/X/A without needing a standard Edit menu.
/// Required because the app runs as .accessory (no menu bar), so key equivalents
/// don't route to text fields by default.
class EditableNSSecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "a":
                if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) { return true }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// NSPopUpButton wrapper that respects width constraints (SwiftUI Picker with .menu style ignores them).
struct FixedWidthPopUp: NSViewRepresentable {
    let selection: String
    let options: [String]
    let disabledOptions: Set<String>
    /// Reports the selected index, avoiding label collision issues.
    let onSelectionIndex: (Int) -> Void

    init(
        selection: String,
        options: [String],
        disabledOptions: Set<String> = [],
        onChange: @escaping (String) -> Void
    ) {
        self.selection = selection
        self.options = options
        self.disabledOptions = disabledOptions
        self.onSelectionIndex = { index in
            guard index >= 0 && index < options.count else { return }
            guard !disabledOptions.contains(options[index]) else { return }
            onChange(options[index])
        }
    }

    init(
        selection: String,
        options: [String],
        disabledOptions: Set<String> = [],
        onSelectIndex: @escaping (Int) -> Void
    ) {
        self.selection = selection
        self.options = options
        self.disabledOptions = disabledOptions
        self.onSelectionIndex = { index in
            guard index >= 0 && index < options.count else { return }
            guard !disabledOptions.contains(options[index]) else { return }
            onSelectIndex(index)
        }
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.removeAllItems()
        button.addItems(withTitles: options)
        button.menu?.autoenablesItems = false
        updateEnabledItems(in: button)
        button.selectItem(withTitle: selection)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let currentTitles = button.itemTitles
        if currentTitles != options {
            button.removeAllItems()
            button.addItems(withTitles: options)
        }
        updateEnabledItems(in: button)
        if button.titleOfSelectedItem != selection {
            button.selectItem(withTitle: selection)
        }
        context.coordinator.onSelectionIndex = onSelectionIndex
    }

    private func updateEnabledItems(in button: NSPopUpButton) {
        for item in button.itemArray {
            item.isEnabled = !disabledOptions.contains(item.title)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelectionIndex: onSelectionIndex) }

    class Coordinator: NSObject {
        var onSelectionIndex: (Int) -> Void
        init(onSelectionIndex: @escaping (Int) -> Void) { self.onSelectionIndex = onSelectionIndex }
        @objc func selectionChanged(_ sender: NSPopUpButton) {
            onSelectionIndex(sender.indexOfSelectedItem)
        }
    }
}

/// A text field that supports Cmd+V paste and masks the value when not focused.
struct PastableSecureField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let onChange: (String) -> Void

    func makeNSView(context: Context) -> EditableNSSecureTextField {
        let field = EditableNSSecureTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ nsView: EditableNSSecureTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        let onChange: (String) -> Void

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            onChange(field.stringValue)
        }
    }
}

/// Plain text field with the same accessory-app edit shortcuts as secure fields.
struct PastableTextField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let onBeginEditing: (() -> Void)?
    let onChange: (String) -> Void

    init(
        text: String,
        placeholder: String,
        onBeginEditing: (() -> Void)? = nil,
        onChange: @escaping (String) -> Void
    ) {
        self.text = text
        self.placeholder = placeholder
        self.onBeginEditing = onBeginEditing
        self.onChange = onChange
    }

    func makeNSView(context: Context) -> EditableNSTextField {
        let field = EditableNSTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ nsView: EditableNSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.onBeginEditing = onBeginEditing
        context.coordinator.onChange = onChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onBeginEditing: onBeginEditing, onChange: onChange)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var onBeginEditing: (() -> Void)?
        var onChange: (String) -> Void

        init(onBeginEditing: (() -> Void)?, onChange: @escaping (String) -> Void) {
            self.onBeginEditing = onBeginEditing
            self.onChange = onChange
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            onBeginEditing?()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            onChange(field.stringValue)
        }
    }
}

private extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        h = h.hasPrefix("#") ? String(h.dropFirst()) : h
        guard h.count == 6, let value = UInt64(h, radix: 16) else {
            self = .black; return
        }
        self = Color(
            red:   Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8)  & 0xFF) / 255,
            blue:  Double( value        & 0xFF) / 255
        )
    }
}

private extension NSColor {
    func toHexString() -> String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        let r = Int((rgb.redComponent   * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent  * 255).rounded())
        return String(format: "%02x%02x%02x", r, g, b)
    }
}
