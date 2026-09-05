import AppKit
import AVFoundation
import SwiftUI
import MuesliCore
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
    case periodicPoll
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
        case .periodicPoll, .permissionRequested:
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
    let controller: MuesliController

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
    @State private var permissionPollTimer: Timer?
    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false
    @State private var screenRecordingGranted = false
    @State private var systemAudioGranted = false
    @State private var isCheckingSystemAudioPermission = false
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
    /// Meeting Summaries section. `nil` = not yet fetched.
    @State private var acpConfigOptions: [ACPConfigOption]?
    /// Command the cached `acpConfigOptions` were fetched for; a changed
    /// command refetches.
    @State private var acpConfigOptionsCommand = ""
    @State private var acpConfigOptionsLoadTask: Task<Void, Never>?
    @State private var acpOptionsUnavailable = false

    init(appState: AppState, controller: MuesliController) {
        self.appState = appState
        self.controller = controller
        _selectedPane = State(initialValue: appState.selectedSettingsPane)
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
            && appState.config.resolvedMeetingLiveCaptionBackend == .nemotron35
            && downloadedMeetingLiveCaptionBackends.contains(.nemotron35)
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

    private var selectedIndicASRLanguage: IndicASRLanguage {
        appState.config.resolvedIndicASRLanguage
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

    private var activeFeatureTourTarget: FeatureTourTarget? {
        appState.activeFeatureTourTarget
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                    Text("Settings")
                        .font(MuesliTheme.title1())
                        .foregroundStyle(MuesliTheme.textPrimary)

                    settingsPanePicker
                    paneContent
                }
                .padding(.horizontal, MuesliTheme.spacing32)
            .padding(.top, MuesliTheme.pageTop)
            .padding(.bottom, MuesliTheme.spacing32)
            }
            .background(MuesliTheme.backgroundBase)
            .onAppear {
                refreshDownloadedModelOptions()
                refreshAudioInputDevices()
                startPermissionPolling()
                if appState.selectedMeetingSummaryBackend == .openRouter {
                    loadOpenRouterFreeModelsIfNeeded()
                }
                if selectedPane == .meetings {
                    loadACPConfigOptionsIfNeeded()
                }
                scrollToFeatureTourTarget(activeFeatureTourTarget, using: scrollProxy)
            }
            .onDisappear {
                SoundController.stopMaraudersMapClip()
                isPreviewingClip = false
                audioInputDeviceRefreshTask?.cancel()
                audioInputDeviceRefreshTask = nil
                stopPermissionPolling()
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
                if pane == .meetings {
                    loadCachedAudioInputDevices()
                    loadACPConfigOptionsIfNeeded()
                }
                scrollToFeatureTourTarget(activeFeatureTourTarget, using: scrollProxy)
            }
            .onChange(of: activeFeatureTourTarget) { _, target in
                scrollToFeatureTourTarget(target, using: scrollProxy)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                guard appState.selectedTab == .settings else { return }
                refreshAudioInputDevices()
                refreshPermissionStatuses(for: .appActivated)
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
                if pane != .meetings {
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
                .frame(minWidth: 560, minHeight: 480)
            }
            .sheet(isPresented: $isShowingCalendarSettings) {
                CalendarSettingsView(
                    appState: appState,
                    controller: controller,
                    onClose: { isShowingCalendarSettings = false }
                )
                .frame(minWidth: 560, minHeight: 520)
            }
        }
    }

    private func scrollToFeatureTourTarget(_ target: FeatureTourTarget?, using proxy: ScrollViewProxy) {
        guard let target, target == .liveCaptionsSetting else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(target.rawValue, anchor: .center)
            }
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

    private func loadCachedAudioInputDevices() {
        refreshAudioInputDevices()
    }

    /// (Re)fetches the ACP agent's advertised config options whenever the
    /// Meeting Summaries ACP branch is visible with a non-empty command.
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
        acpConfigOptions = nil
        acpConfigOptionsCommand = command
        acpOptionsUnavailable = false
        acpConfigOptionsLoadTask = Task { @MainActor in
            do {
                let options = try await ACPClient.availableOptions(command: command, timeout: 20)
                guard !Task.isCancelled else { return }
                acpConfigOptions = options
                acpOptionsUnavailable = options.isEmpty
            } catch {
                guard !Task.isCancelled else { return }
                acpConfigOptions = []
                acpOptionsUnavailable = true
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
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textTertiary)
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
    private var acpModelCaption: String? {
        guard !isACPConfigOptionsLoading else { return nil }
        return acpOptionsUnavailableAfterLoad || acpOptionValues("model").isEmpty
            ? "Start the agent to see available models."
            : nil
    }

    private static let acpThinkingCaption = "Reasoning effort: off / auto / low / medium / high / xhigh / max."

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
        let width = rowControlWidth ?? controlWidth
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(screenContextDescription(includesScreenOCR: includesScreenOCR))
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: 20)

            ZStack(alignment: .trailing) {
                Color.clear.frame(width: width, height: 1)
                screenContextControl(width: width)
            }
        }
        .frame(minHeight: 52)
    }

    private let customIndicatorPositionLabel = "Custom (drag to reposition)"

    private var settingsPanePicker: some View {
        HStack {
            Spacer()
            Picker("", selection: $selectedPane) {
                ForEach(SettingsPane.allCases) { pane in
                    Text(pane.title).tag(pane)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 760)
            Spacer()
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedPane {
        case .general:
            generalSettingsPane
        case .meetings:
            meetingsSettingsPane
        case .appearance:
            appearanceSettingsPane
        }
    }

    private var generalSettingsPane: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            settingsSection("General") {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    settingsRow("Launch at login") {
                        settingsSwitch(isOn: appState.config.launchAtLogin) { newValue in
                            controller.setLaunchAtLogin(newValue)
                        }
                    }
                    if appState.launchAtLoginRegistrationState == .requiresApproval {
                        launchAtLoginApprovalPrompt
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Open dashboard on launch") {
                    settingsSwitch(isOn: appState.config.openDashboardOnLaunch) { newValue in
                        controller.updateConfig { $0.openDashboardOnLaunch = newValue }
                    }
                }
            }

            permissionsSection

            settingsSection("Data") {
                HStack(spacing: MuesliTheme.spacing12) {
                    actionButton("Clear meeting history", role: .destructive) {
                        pendingDataDestruction = .meetings
                    }
                    .disabled(controller.isMeetingRecording())
                    .help("Stop the current meeting recording before clearing meeting history.")
                }
            }
        }
    }

    private var launchAtLoginApprovalPrompt: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.recording)
            Text("Requires approval in System Settings")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
            Spacer(minLength: MuesliTheme.spacing12)
            Button {
                controller.openLaunchAtLoginSettings()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Open")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(MuesliTheme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(MuesliTheme.accentSubtle)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .help("Open Login Items in System Settings")
        }
        .padding(.leading, MuesliTheme.spacing16)
        .padding(.trailing, MuesliTheme.spacing16)
        .padding(.bottom, MuesliTheme.spacing8)
    }

    private var meetingTranscriptionSettingsSection: some View {
        settingsSection("Transcription") {
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
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow(
                "Show transcript on hover",
                description: "Show recent transcript beside the waveform.",
                controlWidth: meetingControlWidth
            ) {
                settingsSwitch(isOn: appState.config.showMeetingTranscriptOnIndicatorHover) { newValue in
                    controller.updateConfig { $0.showMeetingTranscriptOnIndicatorHover = newValue }
                }
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow(
                "Live preview model",
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
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .multilineTextAlignment(.trailing)
                        .frame(width: meetingControlWidth, alignment: .trailing)
                }
            }
            .id(FeatureTourTarget.liveCaptionsSetting.rawValue)
            .featureTourTarget(.liveCaptionsSetting)
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Final transcript", controlWidth: meetingControlWidth) {
                if usesUnifiedMeetingTranscript {
                    Text("\(MeetingLiveCaptionBackend.nemotron35.label) (same model)")
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .frame(width: meetingControlWidth, alignment: .trailing)
                } else if meetingBackendOptions.isEmpty {
                    Text("No downloaded models")
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textTertiary)
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
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Language", controlWidth: meetingControlWidth) {
                    nemotron35LanguageMenu
                }
            } else if appState.selectedMeetingTranscriptionBackend.backend == BackendOption.cohereTranscribe.backend {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Cohere language", controlWidth: meetingControlWidth) {
                    cohereLanguageMenu
                }
            } else if appState.selectedMeetingTranscriptionBackend.backend == BackendOption.indicASR.backend {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Indic language", controlWidth: meetingControlWidth) {
                    indicLanguageMenu
                }
            } else if appState.selectedMeetingTranscriptionBackend.supportsWhisperLanguageSelection {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Whisper language", controlWidth: meetingControlWidth) {
                    whisperLanguageMenu
                }
            }
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

    private var indicLanguageMenu: some View {
        FixedWidthPopUp(
            selection: selectedIndicASRLanguage.label,
            options: IndicASRLanguage.allCases.map(\.label),
            onSelectIndex: { index in
                guard index >= 0, index < IndicASRLanguage.allCases.count else { return }
                controller.selectIndicASRLanguage(IndicASRLanguage.allCases[index])
            }
        )
        .frame(height: 24)
    }

    private var meetingSummarySettingsSection: some View {
        settingsSection("Meeting Summaries") {
            settingsRow("Include written notes") {
                settingsSwitch(isOn: appState.config.includeNotesInSummary) { newValue in
                    controller.updateConfig { $0.includeNotesInSummary = newValue }
                }
            }
            settingsDescription("Feed your written notes into AI summaries alongside the transcript. Notes are always kept verbatim either way.")
            Divider().background(MuesliTheme.surfaceBorder)

            settingsRow("Summary backend", controlWidth: meetingControlWidth) {
                settingsMenu(
                    selection: appState.selectedMeetingSummaryBackend.label,
                    options: MeetingSummaryBackendOption.all.map(\.label)
                ) { label in
                    if let option = MeetingSummaryBackendOption.all.first(where: { $0.label == label }) {
                        controller.selectMeetingSummaryBackend(option)
                    }
                }
            }
            Divider().background(MuesliTheme.surfaceBorder)

            if appState.selectedMeetingSummaryBackend == .chatGPT {
                settingsRow("Account", controlWidth: meetingControlWidth) {
                    chatGPTAccountControl()
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Model", controlWidth: meetingControlWidth) {
                    settingsModelMenu(
                        currentModel: appState.config.chatGPTModel,
                        presets: SummaryModelPreset.chatGPTModels
                    ) { val in controller.updateConfig { $0.chatGPTModel = val } }
                }
            } else if appState.selectedMeetingSummaryBackend == .openAI {
                settingsRow("API Key", controlWidth: meetingControlWidth) {
                    PastableSecureField(
                        text: appState.config.openAIAPIKey,
                        placeholder: "sk-...",
                        onChange: { val in controller.updateConfig { $0.openAIAPIKey = val } }
                    )
                    .frame(height: 22)
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Model", controlWidth: meetingControlWidth) {
                    settingsModelMenu(
                        currentModel: appState.config.openAIModel,
                        presets: SummaryModelPreset.openAIModels
                    ) { val in controller.updateConfig { $0.openAIModel = val } }
                }
                keyStatusRow(key: appState.config.openAIAPIKey)
            } else if appState.selectedMeetingSummaryBackend == .ollama {
                settingsRow("Ollama URL", controlWidth: meetingControlWidth) {
                    PastableTextField(
                        text: appState.config.ollamaURL,
                        placeholder: "http://localhost:11434",
                        onChange: { val in controller.updateConfig { $0.ollamaURL = val } }
                    )
                    .frame(height: 22)
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Model", controlWidth: meetingControlWidth) {
                    settingsModelTextField(
                        currentModel: appState.config.ollamaModel,
                        placeholder: "qwen3.5"
                    ) { val in controller.updateConfig { $0.ollamaModel = val } }
                }
            } else if appState.selectedMeetingSummaryBackend == .lmStudio {
                settingsRow("LM Studio URL", controlWidth: meetingControlWidth) {
                    PastableTextField(
                        text: appState.config.lmStudioURL,
                        placeholder: "http://localhost:1234",
                        onChange: { val in controller.updateConfig { $0.lmStudioURL = val } }
                    )
                    .frame(height: 22)
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Model", controlWidth: meetingControlWidth) {
                    settingsModelTextField(
                        currentModel: appState.config.lmStudioModel,
                        placeholder: "Select a loaded LM Studio model"
                    ) { val in controller.updateConfig { $0.lmStudioModel = val } }
                }
            } else if appState.selectedMeetingSummaryBackend == .customLLM {
                customLLMSettingsRows(model: appState.config.customLLMModel) {
                    val in controller.updateConfig { $0.customLLMModel = val }
                }
            } else if appState.selectedMeetingSummaryBackend == .acpAgent {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Command", description: "Runs your installed agent (omp, Claude Code, Codex…) over Agent Client Protocol. No API key needed.", controlWidth: meetingControlWidth) {
                    PastableTextField(
                        text: appState.config.acpAgentCommand,
                        placeholder: "omp acp",
                        onChange: { val in controller.updateConfig { $0.acpAgentCommand = val } }
                    )
                    .frame(height: 22)
                }
                Divider().background(MuesliTheme.surfaceBorder)
                acpModelMenuRow
                Divider().background(MuesliTheme.surfaceBorder)
                acpThinkingMenuRow
            } else {
                settingsRow("Account", controlWidth: meetingControlWidth) {
                    openRouterAccountControl()
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Model", controlWidth: meetingControlWidth) {
                    openRouterFreeModelMenu
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Custom model ID", controlWidth: meetingControlWidth) {
                    settingsModelTextField(
                        currentModel: appState.config.openRouterModel,
                        placeholder: "provider/model",
                        onBeginEditing: { isUsingCustomOpenRouterModel = true }
                    ) { val in controller.updateConfig { $0.openRouterModel = val } }
                }
            }
        }
    }

    @ViewBuilder
    private func customLLMSettingsRows(model: String, onModelChange: @escaping (String) -> Void) -> some View {
        Divider().background(MuesliTheme.surfaceBorder)
        settingsRow("API Format", controlWidth: meetingControlWidth) {
            settingsMenu(
                selection: CustomLLMFormat(rawValue: appState.config.customLLMFormat)?.label ?? CustomLLMFormat.openAI.label,
                options: CustomLLMFormat.allCases.map(\.label)
            ) { label in
                guard let format = CustomLLMFormat.allCases.first(where: { $0.label == label }) else { return }
                controller.updateConfig { $0.customLLMFormat = format.rawValue }
            }
        }
        Divider().background(MuesliTheme.surfaceBorder)
        settingsRow("Endpoint", controlWidth: meetingControlWidth) {
            PastableTextField(
                text: appState.config.customLLMURL,
                placeholder: appState.config.customLLMFormat == CustomLLMFormat.anthropic.rawValue
                    ? "https://api.anthropic.com"
                    : "http://localhost:8080/v1",
                onChange: { val in controller.updateConfig { $0.customLLMURL = val } }
            )
            .frame(height: 22)
        }
        Divider().background(MuesliTheme.surfaceBorder)
        settingsRow("API Key", controlWidth: meetingControlWidth) {
            PastableSecureField(
                text: appState.config.customLLMAPIKey,
                placeholder: appState.config.customLLMFormat == CustomLLMFormat.anthropic.rawValue
                    ? "Required for Anthropic API"
                    : "Optional for local servers",
                onChange: { val in controller.updateConfig { $0.customLLMAPIKey = val } }
            )
            .frame(height: 22)
        }
        Divider().background(MuesliTheme.surfaceBorder)
        settingsRow("Model", controlWidth: meetingControlWidth) {
            settingsModelTextField(
                currentModel: model,
                placeholder: appState.config.customLLMFormat == CustomLLMFormat.anthropic.rawValue
                    ? "claude-3-5-sonnet-20241022"
                    : "custom-model-id"
            ) { val in onModelChange(val) }
        }
    }

    private var cleanupBackendOptions: [TranscriptCleanupBackendOption] {
        TranscriptCleanupBackendOption.all.filter { !$0.isGemma4LiteRT }
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

    @ViewBuilder
    private var transcriptCleanupSettingsSection: some View {
        settingsSection("Transcript Cleanup") {
            settingsRow("AI transcript cleanup") {
                settingsSwitch(isOn: appState.config.enablePostProcessor) { newValue in
                    controller.setPostProcessorEnabled(newValue)
                }
            }
            if appState.config.enablePostProcessor {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow(
                    "Cleanup source",
                    description: cleanupSourceDescription,
                    controlWidth: meetingControlWidth
                ) {
                    settingsMenu(
                        selection: selectedCleanupBackend.label,
                        options: cleanupBackendOptions.map(\.label)
                    ) { label in
                        if let option = cleanupBackendOptions.first(where: { $0.label == label }) {
                            controller.selectPostProcessorBackend(option)
                        }
                    }
                }
                if selectedCleanupBackend.isLocal {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Local model", controlWidth: meetingControlWidth) {
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
                        Divider().background(MuesliTheme.surfaceBorder)
                        settingsRow("Download", controlWidth: meetingControlWidth) {
                            if let progress = cleanupDownloads[selectedCleanupLocalModel.id] {
                                HStack(spacing: 6) {
                                    ProgressView(value: progress)
                                        .frame(width: 120)
                                    Text("\(Int(progress * 100))%")
                                        .font(.system(size: 11))
                                        .foregroundStyle(MuesliTheme.textTertiary)
                                }
                            } else {
                                compactActionButton("Download \(selectedCleanupLocalModel.sizeLabel)", systemImage: "arrow.down.circle") {
                                    downloadSelectedCleanupModel()
                                }
                            }
                        }
                    } else {
                        Divider().background(MuesliTheme.surfaceBorder)
                        settingsRow("Delete model", controlWidth: meetingControlWidth) {
                            compactActionButton("Delete", systemImage: "trash") {
                                controller.deletePostProcessorModel(selectedCleanupLocalModel)
                            }
                        }
                    }
                } else if selectedCleanupBackend.backend == "acp_agent" {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Command", controlWidth: meetingControlWidth) {
                        PastableTextField(
                            text: appState.config.acpAgentCommand,
                            placeholder: "omp acp",
                            onChange: { val in controller.updateConfig { $0.acpAgentCommand = val } }
                        )
                        .frame(height: 22)
                    }
                    acpModelMenuRow
                    acpThinkingMenuRow
                } else {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Model", controlWidth: meetingControlWidth) {
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
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Cleanup prompt", controlWidth: meetingControlWidth) {
                    actionButton("Manage Prompts…") {
                        isShowingCleanupPromptManager = true
                    }
                }
            }
        }
    }

    private var cleanupSourceDescription: String {
        switch selectedCleanupBackend.backend {
        case "local": return "Runs on-device with a downloaded Qwen3 GGUF model."
        case "acp_agent": return "Runs your installed agent (omp, Claude Code, Codex…) over Agent Client Protocol. No API key needed."
        default: return "Uses the same account configured for meeting summaries."
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

    private var meetingsSettingsPane: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            meetingTranscriptionSettingsSection

            settingsSection("Meeting Context") {
                screenContextRow("Meeting context", includesScreenOCR: true)
            }

            meetingSummarySettingsSection

            transcriptCleanupSettingsSection

            settingsSection("Meeting Notes") {
                settingsRow("Default template", controlWidth: meetingControlWidth) {
                    meetingTemplateMenu(selectionID: appState.config.defaultMeetingTemplateID) { id in
                        controller.updateDefaultMeetingTemplate(id: id)
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
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
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Templates", controlWidth: meetingControlWidth) {
                    actionButton("Manage Templates…") {
                        controller.showMeetingTemplatesManager()
                    }
                }
            }

            settingsSection("Recording") {
                settingsRow("Auto-record calendar meetings") {
                    settingsSwitch(isOn: appState.config.autoRecordMeetings) { newValue in
                        controller.updateConfig { $0.autoRecordMeetings = newValue }
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Save meeting recording") {
                    settingsMenu(
                        selection: recordingSaveLabel(for: appState.config.meetingRecordingSavePolicy),
                        options: MeetingRecordingSavePolicy.allCases.map(recordingSaveLabel(for:))
                    ) { label in
                        guard let policy = recordingSavePolicy(for: label) else { return }
                        controller.updateConfig { $0.meetingRecordingSavePolicy = policy }
                    }
                }
                if appState.config.meetingRecordingSavePolicy != .never {
                    Divider().background(MuesliTheme.surfaceBorder)
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

            settingsSection("Auto Export") {
                settingsRow("Auto-export meetings") {
                    settingsSwitch(isOn: appState.config.autoExportMarkdownEnabled) { newValue in
                        controller.updateConfig { $0.autoExportMarkdownEnabled = newValue }
                    }
                }
                if appState.config.autoExportMarkdownEnabled {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Destination folder") {
                        autoExportFolderPicker
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Content") {
                        settingsMenu(
                            selection: appState.config.resolvedAutoExportMarkdownContent.displayName,
                            options: MeetingExportContent.allCases.map(\.displayName)
                        ) { label in
                            guard let index = MeetingExportContent.allCases.firstIndex(where: { $0.displayName == label }) else { return }
                            let content = MeetingExportContent.allCases[index]
                            controller.updateConfig { $0.autoExportMarkdownContent = content.rawValue }
                        }
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("File format") {
                        settingsMenu(
                            selection: appState.config.resolvedAutoExportFileFormat.displayName,
                            options: MeetingAutoExportFileFormat.allCases.map(\.displayName)
                        ) { label in
                            guard let format = MeetingAutoExportFileFormat.allCases.first(where: { $0.displayName == label }) else { return }
                            controller.updateConfig { $0.autoExportFileFormat = format.rawValue }
                        }
                    }
                }
                Text("Automatically saves each completed meeting to the chosen folder in the selected format.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .padding(.horizontal, MuesliTheme.spacing16)
            }

            cloudSyncSettingsSection

            settingsSection("Meeting Notifications") {
                settingsRow("Scheduled meetings") {
                    settingsSwitch(isOn: appState.config.showScheduledMeetingNotifications) { newValue in
                        controller.updateConfig { $0.showScheduledMeetingNotifications = newValue }
                    }
                }
                settingsDescription("Show notifications for calendar meetings with a join link.")

                if appState.config.showScheduledMeetingNotifications {
                    Divider().background(MuesliTheme.surfaceBorder)

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

                Divider().background(MuesliTheme.surfaceBorder)

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

                Divider().background(MuesliTheme.surfaceBorder)

                settingsRow("Auto-detected meetings") {
                    settingsSwitch(isOn: appState.config.showMeetingDetectionNotification) { newValue in
                        controller.updateConfig { $0.showMeetingDetectionNotification = newValue }
                    }
                }
                settingsDescription("Show notifications when a call is detected from browser, camera, microphone, or app audio activity.")

                if appState.config.showMeetingDetectionNotification {
                    Divider().background(MuesliTheme.surfaceBorder)
                    mutedMeetingDetectionAppsControl
                    Divider().background(MuesliTheme.surfaceBorder)
                    customMeetingDetectionAppsControl
                        .padding(.top, MuesliTheme.spacing8)
                }
            }

            settingsSection("Calendars") {
                calendarSyncRow
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Upcoming meetings", controlWidth: meetingControlWidth) {
                    settingsMenu(
                        selection: selectedUpcomingMeetingsWindow.label,
                        options: UpcomingMeetingsWindow.allCases.map(\.label)
                    ) { label in
                        guard let window = UpcomingMeetingsWindow.allCases.first(where: { $0.label == label }) else { return }
                        controller.updateUpcomingMeetingsWindow(dayCount: window.dayCount)
                    }
                }
                settingsDescription("Controls how many calendar days appear in Coming Up, the menu bar, and scheduled meeting checks.")
            }

            calendarManagementSection

            settingsSection("Advanced") {
                settingsRow("Enable post-meeting hook", controlWidth: meetingControlWidth) {
                    settingsSwitch(isOn: appState.config.meetingHookEnabled) { newValue in
                        controller.updateConfig { $0.meetingHookEnabled = newValue }
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Hook script", controlWidth: meetingControlWidth) {
                    meetingHookPathPicker
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Timeout", controlWidth: meetingControlWidth) {
                    meetingHookTimeoutControl
                }
                settingsDescription("Runs a user-supplied executable after each completed meeting. The executable receives JSON on stdin and must already be runnable on its own.")
            }
            .padding(.top, MuesliTheme.spacing8)
        }
        .onAppear {
            refreshMeetingCalendarSourcesIfNeeded()
        }
    }

    // MARK: - Cloud Sync

    private var cloudSyncSettingsSection: some View {
        settingsSection("Cloud Sync") {
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
                Divider().background(MuesliTheme.surfaceBorder)
                if !cloudSyncLocations.isEmpty {
                    settingsRow("Cloud folder", controlWidth: meetingControlWidth) {
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
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Include audio recordings") {
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
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Sync Now") {
                    compactActionButton(isSyncingCloud ? "Syncing…" : "Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                        syncNowToCloud()
                    }
                    .disabled(isSyncingCloud)
                }
                if let cloudSyncOutcome {
                    Text(cloudSyncOutcome)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(cloudSyncOutcomeIsError ? MuesliTheme.recording : MuesliTheme.textSecondary)
                        .padding(.horizontal, MuesliTheme.spacing16)
                }
            }
            Text("Meetings are saved to \(cloudSyncFolderName) as Markdown notes (+ audio). Open that folder in iCloud Drive / Dropbox / Drive on your iPhone to read them.")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
                .padding(.horizontal, MuesliTheme.spacing16)
        }
    }

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

    private var calendarManagementSection: some View {
        settingsSection("Calendar Management") {
            settingsRow("Apple Calendar", description: "See what’s synced: accounts, calendars, per-calendar toggles, rename and delete.") {
                Button {
                    isShowingCalendarSettings = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.right.circle")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Manage…")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(MuesliTheme.accent)
                }
                .buttonStyle(.plain)
                .help("Manage Apple Calendar accounts and calendars")
            }
        }
    }

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
                    .foregroundStyle(MuesliTheme.success)
                Text("On")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textSecondary)
                Spacer(minLength: 0)
            }
        case .writeOnly:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MuesliTheme.transcribing)
                Text("Limited")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textSecondary)
                Spacer(minLength: 0)
            }
        case .denied:
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MuesliTheme.recording)
                Text("Off")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textSecondary)
                Spacer(minLength: 0)
                Button {
                    refreshMeetingCalendarSources()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Request Access")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(MuesliTheme.accent)
                .disabled(isRefreshingCalendarAccess)
            }
        case .unknown:
            Button(isRefreshingCalendarAccess ? "Checking…" : "Authorize") {
                refreshMeetingCalendarSources()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(MuesliTheme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(MuesliTheme.accentSubtle)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .disabled(isRefreshingCalendarAccess)
        }
    }

    private var appearanceSettingsPane: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            settingsSection("Floating Indicator") {
                settingsRow("Show floating indicator") {
                    settingsSwitch(isOn: appState.config.showFloatingIndicator) { newValue in
                        controller.updateConfig { $0.showFloatingIndicator = newValue }
                        controller.refreshIndicatorVisibility()
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Show hotkey on floating indicator") {
                    settingsSwitch(isOn: appState.config.showHotkeyOnFloatingIndicator) { newValue in
                        controller.updateConfig { $0.showHotkeyOnFloatingIndicator = newValue }
                    }
                    .disabled(!appState.config.showFloatingIndicator)
                }
                settingsRow("Hover style") {
                    settingsMenu(
                        selection: appState.config.indicatorHoverStyle.label,
                        options: IndicatorHoverStyle.allCases.map(\.label)
                    ) { label in
                        guard let style = IndicatorHoverStyle.allCases.first(where: { $0.label == label }) else { return }
                        controller.updateConfig { $0.indicatorHoverStyle = style }
                    }
                    .disabled(!appState.config.showFloatingIndicator)
                }
                settingsDescription("Classic grows the pill to show the hotkey. Shortcut pill keeps a thin grip and pops a separate label on hover.")
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Indicator position") {
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
                        controller.refreshIndicatorVisibility()
                    }
                }
            }

            settingsSection("Appearance") {
                settingsRow("Dark mode") {
                    settingsSwitch(isOn: appState.config.darkMode) { newValue in
                        controller.updateConfig { $0.darkMode = newValue }
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Menu bar icon") {
                    menuBarIconPicker
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Show hotkey in menu bar") {
                    settingsSwitch(isOn: appState.config.showHotkeyInMenuBar) { newValue in
                        controller.updateConfig { $0.showHotkeyInMenuBar = newValue }
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Accent color") {
                    glassTintPicker
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Play sound effects") {
                    settingsSwitch(isOn: appState.config.soundEnabled) { newValue in
                        controller.updateConfig { $0.soundEnabled = newValue }
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Show next meeting in menu bar") {
                    settingsSwitch(isOn: appState.config.showNextMeetingInMenuBar) { newValue in
                        controller.updateConfig { $0.showNextMeetingInMenuBar = newValue }
                    }
                }
            }

            if appState.config.maraudersMapUnlocked {
                settingsSection("Marauder\u{2019}s Map") {
                    settingsRow("Meeting countdown audio") {
                        maraudersMapControl
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("") {
                        Button {
                            SoundController.stopMaraudersMapClip()
                            isPreviewingClip = false
                            controller.resetMaraudersMap()
                        } label: {
                            Text("Mischief Managed")
                                .font(.system(size: 11))
                                .foregroundColor(MuesliTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
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
                            Circle().strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help(preset.name)
            }
        }
    }

    private var menuBarIconPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(MenuBarIconRenderer.options, id: \.id) { option in
                    let isSelected = appState.config.menuBarIcon == option.id
                    Button {
                        controller.updateConfig { $0.menuBarIcon = option.id }
                    } label: {
                        Group {
                            if option.id == "muesli",
                               let img = MenuBarIconRenderer.make(choice: "muesli") {
                                Image(nsImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 14, height: 14)
                            } else {
                                Image(systemName: option.id)
                                    .font(.system(size: 12))
                            }
                        }
                        .foregroundStyle(isSelected ? MuesliTheme.accent : MuesliTheme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isSelected ? MuesliTheme.surfaceSelected : Color.clear)
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
        }
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
                .background(MuesliTheme.success)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .buttonStyle(.plain)
        } else if isSigningInChatGPT {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Signing in...")
                    .font(.system(size: 11))
                    .foregroundStyle(MuesliTheme.textSecondary)
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
                            .fill(MuesliTheme.accentContent)
                            .frame(width: 10, height: 10)
                        Text("Sign in with ChatGPT")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(MuesliTheme.accentContent)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(MuesliTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
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
                            .foregroundStyle(MuesliTheme.success)
                        Text(appState.isOpenRouterEnvironmentManaged ? "Environment key" : "Connected")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(MuesliTheme.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()
                        .background(MuesliTheme.surfaceBorder)
                        .padding(.vertical, 5)

                    Button {
                        controller.manageOpenRouterKey()
                    } label: {
                        Text("Manage key")
                            .font(.system(size: 10))
                            .foregroundStyle(MuesliTheme.textSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .help("Manage this key at OpenRouter")

                    Divider()
                        .background(MuesliTheme.surfaceBorder)
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
                                .foregroundStyle(MuesliTheme.textSecondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .help("Remove Meets's local copy of this OpenRouter key")
                    } else {
                        Text("Managed externally")
                            .font(.system(size: 10))
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .lineLimit(1)
                    }
                }
                .frame(height: 24)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
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
                    .foregroundStyle(MuesliTheme.textSecondary)
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
                            .foregroundStyle(MuesliTheme.accentContent)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(MuesliTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)

                Button(isEnteringOpenRouterAPIKey ? "Cancel manual key" : "Enter API key manually") {
                    isEnteringOpenRouterAPIKey.toggle()
                    manualOpenRouterAPIKey = ""
                    openRouterSignInError = nil
                }
                .buttonStyle(.link)
                .font(.system(size: 10))

                if isEnteringOpenRouterAPIKey {
                    HStack(spacing: 6) {
                        PastableSecureField(
                            text: manualOpenRouterAPIKey,
                            placeholder: "sk-or-...",
                            onChange: { manualOpenRouterAPIKey = $0 }
                        )
                        .frame(height: 22)

                        Button("Save") {
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
        HStack(spacing: MuesliTheme.spacing8) {
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
                    .foregroundColor(MuesliTheme.textSecondary)
                    .frame(width: 24, height: 24)
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
            fputs("[muesli-native] Could not resolve Application Support directory\n", stderr)
            return
        }

        do {
            let supportDir = appSupportBase
                .appendingPathComponent(Bundle.main.infoDictionary?["MuesliSupportDirectoryName"] as? String ?? "Meets")
            let destPath = try SoundController.importCustomClip(from: url, supportDir: supportDir)
            controller.updateConfig {
                $0.maraudersMapAudioClip = SoundController.customClipID
                $0.maraudersMapCustomAudioPath = destPath
            }
            controller.updateMaraudersMapAudioClip()
        } catch {
            fputs("[muesli-native] Failed to import custom audio: \(error)\n", stderr)
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
        settingsSection("Permissions") {
            permissionStatusRow(
                "Microphone",
                granted: micGranted,
                action: { AVCaptureDevice.requestAccess(for: .audio) { _ in } },
                pane: "Privacy_Microphone"
            )
            Divider().background(MuesliTheme.surfaceBorder)
            permissionStatusRow(
                "Accessibility",
                granted: accessibilityGranted,
                action: {
                    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                    AXIsProcessTrustedWithOptions(opts)
                },
                pane: "Privacy_Accessibility"
            )
            Divider().background(MuesliTheme.surfaceBorder)
            permissionStatusRow(
                "Input Monitoring",
                granted: inputMonitoringGranted,
                action: {
                    if !CGRequestListenEventAccess() {
                        openPrivacyPane("Privacy_ListenEvent")
                    }
                },
                pane: "Privacy_ListenEvent"
            )
            Divider().background(MuesliTheme.surfaceBorder)
            permissionStatusRow(
                "Screen Recording",
                granted: screenRecordingGranted,
                action: { CGRequestScreenCaptureAccess() },
                pane: "Privacy_ScreenCapture"
            )
            if appState.config.useCoreAudioTap {
                Divider().background(MuesliTheme.surfaceBorder)
                permissionStatusRow(
                    "System Audio",
                    granted: systemAudioGranted,
                    action: {
                        guard !isCheckingSystemAudioPermission else { return }
                        isCheckingSystemAudioPermission = true
                        Task { @MainActor in
                            defer { isCheckingSystemAudioPermission = false }
                            systemAudioGranted = await CoreAudioSystemRecorder.requestSystemAudioAccess()
                        }
                    },
                    pane: "Privacy_ScreenCapture",
                    isBusy: isCheckingSystemAudioPermission
                )
            }
        }
    }

    @ViewBuilder
    private func permissionStatusRow(
        _ name: String,
        granted: Bool,
        action: @escaping () -> Void,
        pane: String,
        isBusy: Bool = false
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(granted ? MuesliTheme.success : MuesliTheme.recording)
                    .frame(width: 8, height: 8)
                Text(name)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
            }
            Spacer()
            if granted {
                Text("Granted")
                    .font(.system(size: 11))
                    .foregroundStyle(MuesliTheme.success)
            } else {
                Button(isBusy ? "Checking…" : "Grant") {
                    action()
                }
                .disabled(isBusy)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(MuesliTheme.accentSubtle)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            Button {
                openPrivacyPane(pane)
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 11))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Open in System Settings")
        }
        .frame(minHeight: 32)
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private func screenContextControl(width: CGFloat? = nil) -> some View {
        if accessibilityGranted {
            settingsSwitch(isOn: appState.config.enableScreenContext) { newValue in
                handleScreenContextToggle(newValue)
            }
            .frame(width: width, alignment: .trailing)
        } else {
            Button {
                handleScreenContextToggle(true)
            } label: {
                Text("Grant")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: width)
                    .frame(minHeight: 32)
                    .background(MuesliTheme.accentSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .buttonStyle(.plain)
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
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            accessibilityGranted = AXIsProcessTrusted()
            if accessibilityGranted {
                controller.updateConfig { $0.enableScreenContext = true }
            }
            return accessibilityGranted
        }

        controller.updateConfig { $0.enableScreenContext = true }
        return true
    }

    private func startPermissionPolling() {
        // Keep the 1 Hz poll limited to cheap TCC snapshots. SMAppService can block
        // the main thread, while probing system audio creates a CoreAudio process
        // tap and can perturb the HAL. Refresh those only at lifecycle boundaries.
        refreshPermissionStatuses(for: .initialDisplay)
        permissionPollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            refreshPermissionStatuses(for: .periodicPoll)
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    private func refreshPermissionStatuses(for reason: SettingsPermissionRefreshReason) {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = CGPreflightListenEventAccess()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        if reason.refreshesLaunchAtLogin {
            controller.refreshLaunchAtLoginState()
        }
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

    @ViewBuilder
    private func settingsSection(
        _ title: String,
        icon: NSImage? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: 5) {
                if let icon {
                    Image(nsImage: icon)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
            }
            .foregroundStyle(MuesliTheme.textTertiary)
            .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(MuesliTheme.spacing16)
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
    }

    /// Standardized row: label on left, control on right.
    /// Controls share a fixed-width column so they all right-align consistently.
    @ViewBuilder
    private func settingsRow(_ label: String, controlWidth rowControlWidth: CGFloat? = nil, @ViewBuilder control: () -> some View) -> some View {
        let width = rowControlWidth ?? controlWidth
        HStack(alignment: .center) {
            Text(label)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
                .layoutPriority(1)
            Spacer(minLength: 20)
            ZStack(alignment: .trailing) {
                // Invisible spacer forces the ZStack to exactly controlWidth
                Color.clear.frame(width: width, height: 1)
                control()
                    .frame(maxWidth: width)
            }
        }
        .frame(minHeight: 32)
    }

    @ViewBuilder
    private func settingsRow(
        _ label: String,
        description: String,
        controlWidth rowControlWidth: CGFloat? = nil,
        @ViewBuilder control: () -> some View
    ) -> some View {
        let width = rowControlWidth ?? controlWidth
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(description)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            control()
                .frame(width: width, alignment: .trailing)
        }
        .frame(minHeight: 44)
    }

    private func settingsDescription(_ text: String) -> some View {
        Text(text)
            .font(MuesliTheme.caption())
            .foregroundStyle(MuesliTheme.textTertiary)
            .padding(.horizontal, MuesliTheme.spacing16)
            .padding(.top, -4)
            .padding(.bottom, MuesliTheme.spacing8)
    }

    // MARK: - Controls

    @ViewBuilder
    private func settingsSwitch(isOn: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        HStack {
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: { onChange($0) }))
                .toggleStyle(.switch)
                .tint(MuesliTheme.accent)
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

    @ViewBuilder
    private func compactActionButton(
        _ title: String,
        systemImage: String? = nil,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isDestructive = role == .destructive
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isDestructive ? MuesliTheme.recording : MuesliTheme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(isDestructive ? MuesliTheme.recording.opacity(0.1) : MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(isDestructive ? MuesliTheme.recording.opacity(0.25) : MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var mutedMeetingDetectionAppsControl: some View {
        let muted = Set(appState.config.mutedMeetingDetectionAppBundleIDs)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Don't notify me when a call is detected in these apps:")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
            ], alignment: .leading, spacing: 8) {
                ForEach(meetingDetectionAppOptions) { app in
                    mutedDetectionAppButton(app, isMuted: muted.contains(app.bundleID))
                }
            }
        }
        .padding(.leading, MuesliTheme.spacing16)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(MuesliTheme.surfaceBorder)
                .frame(width: 2)
        }
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
                .foregroundStyle(MuesliTheme.textTertiary)
        }
    }

    private func mutedDetectionAppButton(_ app: MeetingDetectionAppOption, isMuted: Bool) -> some View {
        Button {
            updateMutedMeetingDetectionApp(app.bundleID, isMuted: !isMuted)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isMuted ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isMuted ? MuesliTheme.accent : MuesliTheme.textTertiary)
                    .frame(width: 16)
                detectionAppIcon(app)
                    .frame(width: 14)
                Text(app.name)
                    .font(.system(size: 12))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(isMuted ? MuesliTheme.accentSubtle : MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(isMuted ? MuesliTheme.accent.opacity(0.35) : MuesliTheme.surfaceBorder, lineWidth: 1)
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

    /// Editor for user-configured call apps (bundle ID + display name) that
    /// the meeting detector treats like built-in dedicated apps. Lets users
    /// add call-capable apps that aren't in the built-in list (Discord is
    /// built in; Telegram, Signal, Session, ... can be added here).
    private var customMeetingDetectionAppsControl: some View {
        let customApps = controller.customMeetingDetectionAppTable()
        return VStack(alignment: .leading, spacing: 10) {
            Text("Custom meeting apps — detect calls in other apps:")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)

            if customApps.isEmpty {
                Text("No custom apps yet. Add one below — e.g. Telegram, Signal, or any app you take calls in.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            } else {
                ForEach(customApps.sorted(by: { $0.value < $1.value }), id: \.key) { bundleID, name in
                    HStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .frame(width: 14)
                        Text(name)
                            .font(.system(size: 12))
                            .foregroundStyle(MuesliTheme.textSecondary)
                            .lineLimit(1)
                        Text(bundleID)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button {
                            controller.setCustomMeetingApp(bundleID: bundleID, name: "")
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(MuesliTheme.recording.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(name)")
                        .accessibilityLabel("Remove \(name)")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                            .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                    )
                }
            }

            HStack(spacing: 8) {
                TextField("Bundle ID (com.example.app)", text: $customAppBundleID)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                            .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                    )
                TextField("Name", text: $customAppName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: 90)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                            .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
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
                        .foregroundStyle(MuesliTheme.accentContent)
                        .frame(width: 22, height: 22)
                        .background(MuesliTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)
                .disabled(customAppBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Add custom meeting app")
            }
        }
        .padding(.leading, MuesliTheme.spacing16)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(MuesliTheme.surfaceBorder)
                .frame(width: 2)
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
                    .foregroundStyle(MuesliTheme.textTertiary)

                if appState.config.autoExportMarkdownFolderPath.isEmpty {
                    Text("Choose a folder…")
                        .font(.system(size: 12))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .lineLimit(1)
                } else {
                    Text(appState.config.autoExportMarkdownFolderPath)
                        .font(.system(size: 12))
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
            .help(appState.config.autoExportMarkdownFolderPath.isEmpty ? "No destination folder selected" : appState.config.autoExportMarkdownFolderPath)

            if !appState.config.autoExportMarkdownFolderPath.isEmpty {
                Button {
                    controller.updateConfig { $0.autoExportMarkdownFolderPath = "" }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        .overlay(
                            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
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
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                            .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
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
                    .foregroundStyle(MuesliTheme.textTertiary)

                if appState.config.meetingHookPath.isEmpty {
                    Text("Choose a script…")
                        .font(.system(size: 12))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .lineLimit(1)
                } else {
                    Text(appState.config.meetingHookPath)
                        .font(.system(size: 12))
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
            .frame(maxWidth: .infinity)
            .help(appState.config.meetingHookPath.isEmpty ? "No hook script selected" : appState.config.meetingHookPath)

            if !appState.config.meetingHookPath.isEmpty {
                Button {
                    controller.updateConfig { $0.meetingHookPath = "" }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        .overlay(
                            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
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
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                            .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
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

        return HStack(spacing: MuesliTheme.spacing8) {
            TextField(label, value: clampedBinding, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 72)
                .accessibilityLabel(label)

            Text(unit(clampedValue))
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
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
                    .foregroundStyle(MuesliTheme.textTertiary)
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
                    Button("Retry") {
                        controller.loadOpenRouterModels(.text, force: true)
                    }
                    .font(.system(size: 11, weight: .medium))
                }
            }
        } else {
            HStack(spacing: 8) {
                if case .failed(let message) = appState.openRouterSummaryCatalogState {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .lineLimit(1)
                }
                Button(appState.openRouterSummaryCatalogState == .idle ? "Load" : "Retry") {
                    controller.loadOpenRouterModels(.text, force: true)
                }
                .font(.system(size: 12, weight: .medium))
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
                .fill(key.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.success)
                .frame(width: 6, height: 6)
            Text(key.isEmpty ? "No API key configured" : "Key configured")
                .font(.system(size: 11))
                .foregroundStyle(key.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.success)
        }
        .frame(minHeight: 20)
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        systemImage: String? = nil,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isDestructive = role == .destructive
        Button(action: action) {
            HStack(spacing: MuesliTheme.spacing8) {
                Text(title)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                }
            }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isDestructive ? MuesliTheme.recording : MuesliTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, MuesliTheme.spacing16)
                .padding(.vertical, MuesliTheme.spacing8)
                .background(isDestructive ? MuesliTheme.recording.opacity(0.1) : MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(
                            isDestructive ? MuesliTheme.recording.opacity(0.2) : MuesliTheme.surfaceBorder,
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
