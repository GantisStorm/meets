import AppKit
import AVFoundation
import SwiftUI
import MeetsCore

struct OnboardingView: View {
    let controller: MeetsController
    let appState: AppState

    @State private var currentStep: Int
    @State private var userName: String
    @State private var selectedUseCase: OnboardingUseCase
    @State private var selectedBackend: BackendOption
    @State private var selectedCohereLanguage: CohereTranscribeLanguage
    @State private var summaryBackend: MeetingSummaryBackendOption = .chatGPT
    @State private var apiKey = ""
    @State private var isSigningInChatGPT = false
    @State private var chatGPTSignInDone = false
    @State private var chatGPTSignInError: String?
    @State private var isSigningInOpenRouter = false
    @State private var openRouterSignInDone = false
    @State private var openRouterSignInError: String?
    @State private var isEnteringOpenRouterAPIKey = false

    // ACP agent config options for the Agent (ACP) summary tab, fetched
    // asynchronously from the agent command when the tab shows.
    @State private var acpConfigOptions: [ACPConfigOption]?
    @State private var acpConfigOptionsCommand = ""
    @State private var acpConfigOptionsLoadTask: Task<Void, Never>?
    @State private var acpOptionsUnavailable = false

    // Permission states — polled from OS every second
    @State private var micGranted = false
    @State private var screenRecordingGranted = false
    @State private var systemAudioGranted = false
    /// Optional permissions the user skipped (persisted in OnboardingProgress).
    @State private var skippedPermissions: Set<String> = []
    @State private var permissionPollTimer: Timer?
    @State private var grantingPermissionName: String?

    // The meeting-recording shortcut is carried through onboarding so resuming
    // and completion persist a usable value; there is no hotkey step anymore.
    @State private var selectedHotkey: HotkeyConfig

    // Model selection
    @State private var showMoreModels = false

    // Model download / preparation
    @State private var isModelStillDownloading = false
    @State private var modelReadyBackend: BackendOption?
    @State private var modelDownloadBackend: BackendOption?
    @State private var modelDownloadTask: Task<Void, Never>?
    @State private var modelDownloadGeneration = UUID()
    @State private var modelDownloadProgress: Double?
    @State private var modelDownloadSnapshot: ModelDownloadProgress?
    @State private var isModelPreparingAfterDownload = false
    @State private var modelDownloadStatus: String?
    @State private var modelDownloadError: String?

    @State private var hasFinishedOnboarding = false

    static let permissionsStep = OnboardingFlow.Step.permissions.rawValue

    private var orderedSteps: [Int] {
        OnboardingFlow.orderedSteps(for: OnboardingUseCase.meetings)
    }

    private var currentStepIndex: Int {
        OnboardingFlow.stepIndex(currentStep, for: OnboardingUseCase.meetings)
    }

    private var onboardingAlternativeModels: [BackendOption] {
        var options = BackendOption.onboarding.filter { $0 != BackendOption.onboardingDefault }
        if BackendOption.onboarding.contains(selectedBackend),
           selectedBackend != BackendOption.onboardingDefault,
           !options.contains(selectedBackend) {
            options.insert(selectedBackend, at: 0)
        }
        return options
    }

    private var onboardingModelDescription: String {
        "Start with a fast local model for meeting transcription. Larger models can download while you continue setup."
    }

    init(
        controller: MeetsController,
        appState: AppState,
        initialStep: Int = 0,
        initialUserName: String = "",
        initialBackend: BackendOption = BackendOption.onboardingDefault,
        initialCohereLanguage: CohereTranscribeLanguage = CohereTranscribeLanguage.defaultLanguage,
        initialHotkey: HotkeyConfig = .default,
        initialSystemAudioRequested: Bool = false,
        initialUseCase: OnboardingUseCase = .dictation,
        initialSummaryBackend: MeetingSummaryBackendOption = .chatGPT,
        initialModelDownloadProgress: Double? = nil,
        initialModelDownloadStatus: String? = nil
    ) {
        self.controller = controller
        self.appState = appState
        // Meets is meetings-only. Older profiles may carry dictation,
        // voice-note, or combined use cases; onboarding always proceeds with
        // the meetings capability so the step list and completion are stable.
        let resolvedUseCase = OnboardingUseCase.meetings
        // Pre-populate permission states so resumed onboarding reflects grants
        // that happened before the deliberate restart.
        let initialMicGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let initialSystemAudioGranted = initialSystemAudioRequested
        let initialPermissions = OnboardingPermissionSnapshot(
            microphone: initialMicGranted,
            accessibility: false,
            inputMonitoring: false,
            systemAudio: initialSystemAudioGranted,
            screenRecording: false
        )
        // normalizedStep maps stored hotkey/dictation-test steps (2/4) onto the
        // meetings ordering, and resumeStep re-validates permissions.
        let permissionGatedInitialStep = OnboardingPermissionGate.resumeStep(
            requestedStep: initialStep,
            permissions: initialPermissions,
            useCase: resolvedUseCase,
            permissionsStep: Self.permissionsStep,
            useCoreAudioTap: appState.config.useCoreAudioTap
        )
        let sanitizedInitialBackend = BackendOption.resolvedOnboardingBackend(initialBackend)
        let modelGatedInitialStep = OnboardingFlow.modelGatedResumeStep(
            requestedStep: permissionGatedInitialStep,
            initialBackend: initialBackend,
            resolvedBackend: sanitizedInitialBackend
        )
        let effectiveInitialStep = OnboardingFlow.normalizedStep(modelGatedInitialStep, for: resolvedUseCase)

        _currentStep = State(initialValue: effectiveInitialStep)
        _userName = State(initialValue: initialUserName)
        _selectedUseCase = State(initialValue: resolvedUseCase)
        _selectedBackend = State(initialValue: sanitizedInitialBackend)
        _selectedCohereLanguage = State(initialValue: initialCohereLanguage)
        _selectedHotkey = State(initialValue: initialHotkey)
        _summaryBackend = State(initialValue: initialSummaryBackend)
        _modelDownloadProgress = State(initialValue: sanitizedInitialBackend == initialBackend ? initialModelDownloadProgress : nil)
        _modelDownloadStatus = State(initialValue: sanitizedInitialBackend == initialBackend ? initialModelDownloadStatus : nil)
        _micGranted = State(initialValue: initialMicGranted)
        _systemAudioGranted = State(initialValue: initialSystemAudioGranted)
        _skippedPermissions = State(initialValue: OnboardingProgress.load()?.skippedPermissions ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            // Download status lives in normal flow (centered banner), never
            // floating over step content. It disappears as soon as the model is ready.
            if shouldShowModelDownloadIndicator {
                HStack {
                    Spacer(minLength: 0)
                    modelDownloadIndicator
                    Spacer(minLength: 0)
                }
                .padding(.top, MeetsTheme.spacing16)
                .padding(.horizontal, MeetsTheme.spacing32)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Group {
                switch currentStep {
                case OnboardingFlow.Step.welcome.rawValue: welcomeStep
                case OnboardingFlow.Step.model.rawValue: modelStep
                case OnboardingFlow.Step.permissions.rawValue: permissionsStep
                case OnboardingFlow.Step.meetingSummary.rawValue: meetingSummaryStep
                case OnboardingFlow.Step.calendarAccess.rawValue: calendarAccessStep
                case OnboardingFlow.Step.transcriptCleanup.rawValue: transcriptCleanupStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().background(MeetsTheme.surfaceBorder)

            // Bottom bar
            HStack {
                HStack(spacing: 6) {
                    ForEach(Array(orderedSteps.enumerated()), id: \.offset) { _, step in
                        Circle()
                            .fill(step == currentStep ? MeetsTheme.accent : MeetsTheme.textTertiary)
                            .frame(width: 7, height: 7)
                    }
                }

                Spacer()

                HStack(spacing: MeetsTheme.spacing12) {
                    if canGoBack {
                        Button("Back") {
                            goToPreviousStep()
                        }
                        .buttonStyle(.plain)
                        .font(MeetsTheme.body())
                        .foregroundStyle(MeetsTheme.textSecondary)
                        .padding(.horizontal, MeetsTheme.spacing16)
                        .padding(.vertical, MeetsTheme.spacing8)
                        .background(MeetsTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                        .overlay(
                            RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                                .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
                        )
                    }

                    primaryButton
                }
            }
            .padding(.horizontal, MeetsTheme.spacing32)
            .padding(.vertical, MeetsTheme.spacing16)
        }
        .background(MeetsTheme.backgroundBase)
        .preferredColorScheme(.dark)
        .onAppear {
            saveProgress(atStep: currentStep)
        }
        .onChange(of: currentStep) { _, step in
            saveProgress(atStep: step)
        }
        .onChange(of: userName) { _, _ in
            saveProgress(atStep: currentStep)
        }
        .onChange(of: selectedBackend) { _, _ in
            resetModelDownloadForBackendChange()
            saveProgress(atStep: currentStep)
        }
        .onChange(of: selectedCohereLanguage) { _, _ in
            saveProgress(atStep: currentStep)
        }
    }

    // MARK: - Primary Button

    @ViewBuilder
    private var primaryButton: some View {
        switch currentStep {
        case OnboardingFlow.Step.welcome.rawValue:
            onboardingButton("Continue", enabled: !userName.trimmingCharacters(in: .whitespaces).isEmpty) {
                goToNextStep()
            }
        case OnboardingFlow.Step.model.rawValue:
            onboardingButton(selectedBackend.isDownloaded ? "Continue" : "Download & Continue", enabled: selectedBackend.isCompatible()) {
                startDownload()
            }
        case OnboardingFlow.Step.permissions.rawValue:
            onboardingButton(currentStepIndex == orderedSteps.count - 1 ? "Finish" : "Continue", enabled: requiredPermissionsGranted) {
                advancePastPermissions()
            }
        case OnboardingFlow.Step.meetingSummary.rawValue:
            onboardingButton("Continue", enabled: true) {
                goToNextStep()
            }
        case OnboardingFlow.Step.calendarAccess.rawValue:
            HStack(spacing: MeetsTheme.spacing12) {
                skipButton("Not now") { finishOnboarding(withKey: true) }
                onboardingButton("Finish", enabled: true) {
                    finishOnboarding(withKey: true)
                }
            }
        case OnboardingFlow.Step.transcriptCleanup.rawValue:
            HStack(spacing: MeetsTheme.spacing16) {
                Button("Skip for now") {
                    finishOnboarding(withKey: true)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MeetsTheme.textSecondary)
                onboardingButton("Finish Setup", enabled: true) {
                    finishOnboarding(withKey: true)
                }
            }
        default:
            EmptyView()
        }
    }

    private func goToNextStep() {
        guard currentStepIndex < orderedSteps.count - 1 else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            currentStep = orderedSteps[currentStepIndex + 1]
        }
    }

    private func goToPreviousStep() {
        guard currentStepIndex > 0 else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            currentStep = orderedSteps[currentStepIndex - 1]
        }
    }

    @ViewBuilder
    private func onboardingButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MeetsTheme.accentContent)
                .padding(.horizontal, MeetsTheme.spacing20)
                .padding(.vertical, MeetsTheme.spacing8)
                .background(enabled ? MeetsTheme.accent : MeetsTheme.accent.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    @ViewBuilder
    private func skipButton(_ title: String = "Skip", action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(MeetsTheme.body())
            .foregroundStyle(MeetsTheme.textSecondary)
            .padding(.horizontal, MeetsTheme.spacing16)
            .padding(.vertical, MeetsTheme.spacing8)
            .background(MeetsTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                    .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
            )
    }

    private var shouldShowModelDownloadIndicator: Bool {
        isModelStillDownloading || modelDownloadError != nil
    }

    private var canGoBack: Bool {
        OnboardingFlow.canGoBack(from: currentStep, useCase: OnboardingUseCase.meetings, dictationTestSucceeded: false)
    }

    private var modelDownloadIndicator: some View {
        let progress = modelDownloadProgress.map { min(max($0, 0), 1) }
        return HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(MeetsTheme.surfaceBorder)
                    .frame(width: 24, height: 24)

                if isModelPreparingAfterDownload {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 24, height: 24)
                } else if let progress {
                    ModelDownloadProgressShape(progress: progress)
                        .fill(MeetsTheme.accent)
                        .frame(width: 24, height: 24)

                    Circle()
                        .stroke(MeetsTheme.accent.opacity(0.7), lineWidth: 1)
                        .frame(width: 24, height: 24)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 24, height: 24)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(modelDownloadIndicatorTitle)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(modelDownloadError == nil ? MeetsTheme.textSecondary : MeetsTheme.recording)
                    .lineLimit(1)
                Text(modelDownloadIndicatorDetail(progress: progress))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(MeetsTheme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(MeetsTheme.backgroundRaised.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 6)
        .frame(width: 260, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .animation(.easeInOut(duration: 0.2), value: shouldShowModelDownloadIndicator)
    }

    private var modelDownloadIndicatorTitle: String {
        if let snapshot = modelDownloadSnapshot {
            switch snapshot.phase {
            case .downloading: return "Downloading \(selectedBackend.label)"
            case .preparing: return "Preparing \(selectedBackend.label)"
            case .ready: return "\(selectedBackend.label) ready"
            case .paused: return "Download paused"
            case .failed: return "Download failed"
            }
        }
        if modelDownloadError != nil {
            return "Download failed"
        }
        return "Preparing \(selectedBackend.label)"
    }

    private func modelDownloadIndicatorDetail(progress: Double?) -> String {
        if let modelDownloadError {
            return modelDownloadError
        }
        if let snapshot = modelDownloadSnapshot {
            return modelDownloadSnapshotDetail(snapshot)
        }
        if let modelDownloadStatus {
            return modelDownloadStatus
        }
        if let progress {
            return "\(Int((progress * 100).rounded()))% complete"
        }
        return "Downloading..."
    }

    private func modelDownloadSnapshotDetail(_ snapshot: ModelDownloadProgress) -> String {
        var details: [String] = []
        if let currentFile = snapshot.currentFile?.split(separator: "/").last.map(String.init), !currentFile.isEmpty {
            details.append(currentFile)
        }
        if snapshot.totalFileCount > 0 {
            let completed = min(max(snapshot.completedFileCount, 0), snapshot.totalFileCount)
            let remaining = snapshot.totalFileCount - completed
            details.append("\(completed) of \(snapshot.totalFileCount) files")
            if remaining > 0 {
                details.append("\(remaining) left")
            }
        }
        if let total = snapshot.totalBytes, total > 0 {
            details.append("\(ModelDownloadDisplayFormatting.bytes(snapshot.completedBytes)) / \(ModelDownloadDisplayFormatting.bytes(total))")
            if snapshot.completedBytes < total {
                details.append("\(ModelDownloadDisplayFormatting.bytes(total - snapshot.completedBytes)) left")
            }
        } else if let currentTotal = snapshot.currentFileTotalBytes, currentTotal > 0 {
            details.append("\(ModelDownloadDisplayFormatting.bytes(snapshot.currentFileCompletedBytes)) / \(ModelDownloadDisplayFormatting.bytes(currentTotal))")
            if snapshot.currentFileCompletedBytes < currentTotal {
                details.append("\(ModelDownloadDisplayFormatting.bytes(currentTotal - snapshot.currentFileCompletedBytes)) left")
            }
        }
        if snapshot.phase == .downloading {
            if snapshot.bytesPerSecond > 0 {
                details.append(ModelDownloadDisplayFormatting.rate(snapshot.bytesPerSecond))
            }
            if let eta = snapshot.estimatedSecondsRemaining,
               let formattedETA = ModelDownloadDisplayFormatting.eta(eta) {
                details.append("\(formattedETA) left")
            }
            if snapshot.retryCount > 0 {
                details.append("retry \(snapshot.retryCount)/3")
            }
        } else if let message = snapshot.message, !message.isEmpty {
            details.append(message)
        }
        return details.isEmpty ? (snapshot.message ?? "Downloading...") : details.joined(separator: " · ")
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: MeetsTheme.spacing24) {
            Spacer()

            MeetsWordmark(size: 56, color: MeetsTheme.textPrimary)

            VStack(spacing: MeetsTheme.spacing8) {
                Text("Record your meetings. Get notes.")
                    .font(MeetsTheme.title2())
                    .foregroundStyle(MeetsTheme.textPrimary)

                Text("Local-first transcription, summaries, and calendar sync — all on this Mac.")
                    .font(MeetsTheme.body())
                    .foregroundStyle(MeetsTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
                Text("Your name")
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textTertiary)

                OnboardingTextField(text: $userName, placeholder: "Enter your name", onSubmit: {
                    if !userName.trimmingCharacters(in: .whitespaces).isEmpty {
                        goToNextStep()
                    }
                })
                    .frame(width: 280, height: 32)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Step 2: Model Selection

    private var modelStep: some View {
        VStack(spacing: MeetsTheme.spacing16) {
            VStack(spacing: MeetsTheme.spacing8) {
                Text("Choose your transcription model")
                    .font(MeetsTheme.title1())
                    .foregroundStyle(MeetsTheme.textPrimary)

                Text(onboardingModelDescription)
                    .font(MeetsTheme.body())
                    .foregroundStyle(MeetsTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, MeetsTheme.spacing24)

            ScrollView {
                VStack(spacing: MeetsTheme.spacing8) {
                    modelCard(option: BackendOption.onboardingDefault)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showMoreModels.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Other models")
                                .font(MeetsTheme.caption())
                            Image(systemName: showMoreModels ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(MeetsTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, MeetsTheme.spacing4)

                    if showMoreModels {
                        ForEach(onboardingAlternativeModels, id: \.model) { option in
                            modelCard(option: option)
                        }

                        Text("More models are available after onboarding.")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(MeetsTheme.textTertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, MeetsTheme.spacing4)
                    }

                    if selectedBackend.backend == BackendOption.cohereTranscribe.backend {
                        cohereLanguageCard
                    }
                }
                .padding(.horizontal, MeetsTheme.spacing32)
            }

        }
        .frame(maxWidth: .infinity)
    }

    private var cohereLanguageCard: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
            Text("Cohere language")
                .font(MeetsTheme.headline())
                .foregroundStyle(MeetsTheme.textPrimary)

            Text("Cohere does not auto-detect language, so pick the language you want it to transcribe.")
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textSecondary)

            FixedWidthPopUp(
                selection: selectedCohereLanguage.label,
                options: CohereTranscribeLanguage.allCases.map(\.label)
            ) { label in
                guard let language = CohereTranscribeLanguage.allCases.first(where: { $0.label == label }) else { return }
                selectedCohereLanguage = language
            }
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(MeetsTheme.spacing12)
        .background(MeetsTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium)
                .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
        )
        .padding(.top, MeetsTheme.spacing8)
    }

    private func modelCard(option: BackendOption) -> some View {
        let isSelected = selectedBackend == option
        let incompatibilityReason = option.incompatibilityReason()
        return Button {
            guard option.isCompatible() else { return }
            selectedBackend = option
        } label: {
            HStack(spacing: MeetsTheme.spacing12) {
                Circle()
                    .fill(isSelected ? MeetsTheme.accent : Color.clear)
                    .frame(width: 16, height: 16)
                    .overlay(
                        Circle()
                            .strokeBorder(isSelected ? MeetsTheme.accent : MeetsTheme.textTertiary, lineWidth: 1.5)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(MeetsTheme.headline())
                            .foregroundStyle(incompatibilityReason == nil ? MeetsTheme.textPrimary : MeetsTheme.textTertiary)
                        if option == BackendOption.onboardingDefault {
                            Text("Recommended")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(MeetsTheme.accentContent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(MeetsTheme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        Text(option.sizeLabel)
                            .font(MeetsTheme.caption())
                            .foregroundStyle(MeetsTheme.textTertiary)
                    }
                    Text(option.description)
                        .font(MeetsTheme.caption())
                        .foregroundStyle(incompatibilityReason == nil ? MeetsTheme.textSecondary : MeetsTheme.textTertiary)
                    if let incompatibilityReason {
                        Label(incompatibilityReason, systemImage: "exclamationmark.triangle")
                            .font(MeetsTheme.caption())
                            .foregroundStyle(MeetsTheme.textTertiary)
                    }
                }

                Spacer()
            }
            .padding(MeetsTheme.spacing12)
            .background(MeetsTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium))
            .overlay(
                RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium)
                    .strokeBorder(isSelected ? MeetsTheme.accent : MeetsTheme.surfaceBorder, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(incompatibilityReason != nil)
        .help(incompatibilityReason ?? option.label)
    }

    // MARK: - Step 3: Permissions

    /// Meetings need the Microphone to record the spoken meeting and one
    /// system-audio path to capture the other participants: the CoreAudio tap
    /// when it is enabled, otherwise Screen Recording. Microphone is required
    /// to continue; the system-audio row can also be enabled later from
    /// Settings.
    private struct PermissionRow {
        let icon: String
        let name: String
        let description: String
        let state: PermissionRowPresentation
        /// Microphone alone blocks Continue; everything else is skippable.
        let skippable: Bool
        let action: () -> Void
    }

    private var permissionRows: [PermissionRow] {
        var rows: [PermissionRow] = [
            PermissionRow(
                icon: "mic.fill", name: "Microphone",
                description: "Required to record meeting audio",
                state: micGranted ? .granted : .idle, skippable: false,
                action: { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
            ),
        ]
        if appState.config.useCoreAudioTap {
            rows.append(PermissionRow(
                icon: "speaker.wave.2.fill", name: "System Audio",
                description: "Captures the other participants' audio in recorded meetings.",
                state: systemAudioGranted ? .granted : .idle, skippable: true,
                action: { requestSystemAudioPermission() }
            ))
        } else {
            rows.append(PermissionRow(
                icon: "record.circle", name: "Screen Recording",
                description: "Captures the other participants' audio (legacy path).",
                state: screenRecordingRowState, skippable: true,
                action: { requestScreenRecordingPermission() }
            ))
        }
        return rows
    }

    /// Onboarding polls the OS directly every second, so a grant that lands
    /// without a request still flips the row; the coordinator supplies the
    /// in-flight and System Settings fallback states.
    private var screenRecordingRowState: PermissionRowPresentation {
        if screenRecordingGranted { return .granted }
        return controller.permissionRequests.presentation(for: .screenRecording)
    }

    private func requestScreenRecordingPermission() {
        controller.permissionRequests.request(.screenRecording)
    }

    private func togglePermissionSkipped(_ name: String) {
        if skippedPermissions.contains(name) {
            skippedPermissions.remove(name)
        } else {
            skippedPermissions.insert(name)
        }
        saveProgress(atStep: currentStep)
    }

    /// True when the coordinator handed a permission off to System Settings
    /// and the OS still reports it ungranted (TCC often needs a relaunch before
    /// new grants read back). Only Screen Recording can reach this state, and
    /// only while its row is shown. Surfaces the relaunch row.
    private var needsRelaunchHint: Bool {
        guard !appState.config.useCoreAudioTap else { return false }
        return appState.permissionHints[.screenRecording] == .openedSystemSettings
            && !screenRecordingGranted
    }

    private func relaunchApp() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func requestSystemAudioPermission() {
        guard !systemAudioGranted, grantingPermissionName == nil else { return }
        grantingPermissionName = "System Audio"
        Task { @MainActor in
            let granted = await CoreAudioSystemRecorder.requestSystemAudioAccess()
            grantingPermissionName = nil
            systemAudioGranted = granted
            if granted {
                saveProgress(atStep: currentStep)
            } else {
                openSystemSettings("Privacy_ScreenCapture", yieldBehavior: .orderedBehind)
            }
        }
    }

    private var permissionsStep: some View {
        VStack(spacing: MeetsTheme.spacing24) {
            Spacer()

            VStack(spacing: MeetsTheme.spacing8) {
                Text("Permissions")
                    .font(MeetsTheme.title1())
                    .foregroundStyle(MeetsTheme.textPrimary)

                Text("Meets records your microphone and the meeting's system audio. Grant Microphone to continue; System Audio can be added now or later in Settings.")
                    .font(MeetsTheme.body())
                    .foregroundStyle(MeetsTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: MeetsTheme.spacing12) {
                ForEach(Array(permissionRows.enumerated()), id: \.offset) { _, row in
                    permissionRow(
                        icon: row.icon,
                        name: row.name,
                        description: row.description,
                        state: row.state,
                        skippable: row.skippable,
                        skipped: skippedPermissions.contains(row.name),
                        action: row.action,
                        onSkip: { togglePermissionSkipped(row.name) }
                    )
                }
                if needsRelaunchHint {
                    HStack(spacing: MeetsTheme.spacing8) {
                        Image(systemName: "arrow.trianglehead.2.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(MeetsTheme.textTertiary)
                        Text("Granted access but still unverified? Relaunch the app to finish.")
                            .font(MeetsTheme.caption())
                            .foregroundStyle(MeetsTheme.textSecondary)
                        Spacer(minLength: 8)
                        Button("Relaunch") { relaunchApp() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MeetsTheme.accent)
                    }
                    .padding(.horizontal, MeetsTheme.spacing4)
                }

                Text("Only Microphone is required. Skipped permissions can be granted later in Settings.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(MeetsTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, MeetsTheme.spacing4)
            }
            .padding(.horizontal, MeetsTheme.spacing24)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            startPermissionPolling()
        }
        .onDisappear {
            stopPermissionPolling()
        }
    }

    private func permissionRow(
        icon: String,
        name: String,
        description: String,
        state: PermissionRowPresentation,
        skippable: Bool,
        skipped: Bool,
        action: @escaping () -> Void,
        onSkip: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
            HStack(spacing: MeetsTheme.spacing12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(MeetsTheme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(MeetsTheme.headline())
                        .foregroundStyle(MeetsTheme.textPrimary)
                    Text(description)
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.textSecondary)
                }

                Spacer()

                if state == .granted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(MeetsTheme.success)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    HStack(spacing: MeetsTheme.spacing8) {
                        if skippable {
                            Button(skipped ? "Skipped" : "Skip") {
                                onSkip()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(skipped ? MeetsTheme.textTertiary : MeetsTheme.textSecondary)
                        }
                        if state == .pending {
                            ProgressView()
                                .controlSize(.small)
                            Text("Waiting for System Settings…")
                                .font(.system(size: 11))
                                .foregroundStyle(MeetsTheme.textSecondary)
                        }
                        Button("Grant") {
                            action()
                        }
                        .disabled(state == .pending)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MeetsTheme.accent)
                        .padding(.horizontal, MeetsTheme.spacing12)
                        .padding(.vertical, 4)
                        .background(MeetsTheme.accentSubtle)
                        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                    }
                }
            }
            .padding(.horizontal, MeetsTheme.spacing16)
            .padding(.vertical, MeetsTheme.spacing12)

            if state == .hint {
                Text(PermissionRequestHint.openedSystemSettings.guidance)
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, MeetsTheme.spacing16)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state)
    }

    /// Microphone is the only permission required to continue; System Audio
    /// is optional and can be granted from Settings later.
    private var requiredPermissionsGranted: Bool {
        micGranted
    }

    private func startPermissionPolling() {
        refreshPermissions(refreshSystemAudio: true)
        permissionPollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            withAnimation { refreshPermissions(refreshSystemAudio: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    private func advancePastPermissions() {
        controller.dismissSystemPermissionGuide()
        goToNextStep()
    }

    /// Probing System Audio creates a short CoreAudio process tap, which can
    /// perturb the HAL, so it only runs at lifecycle boundaries (step appear,
    /// after an explicit request). Microphone is cheap and polls every second.
    private func refreshPermissions(refreshSystemAudio: Bool) {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        if refreshSystemAudio, appState.config.useCoreAudioTap || systemAudioGranted {
            systemAudioGranted = CoreAudioSystemRecorder.checkSystemAudioPermission()
        }
    }

    private func saveProgress(atStep step: Int? = nil) {
        guard !hasFinishedOnboarding else { return }
        let progress = OnboardingProgress(
            currentStep: step ?? currentStep,
            userName: userName,
            selectedBackendKey: selectedBackend.backend,
            selectedModelKey: selectedBackend.model,
            selectedCohereLanguageCode: selectedCohereLanguage.rawValue,
            hotkeyKeyCode: selectedHotkey.keyCode,
            hotkeyLabel: selectedHotkey.label,
            systemAudioRequested: systemAudioGranted,
            onboardingUseCaseRawValue: selectedUseCase.rawValue,
            modelDownloadProgress: modelDownloadProgress,
            modelDownloadStatus: modelDownloadStatus,
            skippedPermissions: skippedPermissions
        )
        OnboardingProgress.save(progress)
    }

    private func openSystemSettings(
        _ pane: String,
        yieldBehavior: OnboardingSystemSettingsYieldBehavior
    ) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            if NSWorkspace.shared.open(url) {
                controller.yieldOnboardingFocusToSystemSettings(using: yieldBehavior)
            }
        }
    }

    // MARK: - Meeting Summaries + Transcript Cleanup

    private var meetingSummaryStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: MeetsTheme.spacing16) {
                    VStack(spacing: MeetsTheme.spacing8) {
                        Text("Meeting Summaries")
                            .font(MeetsTheme.title1())
                            .foregroundStyle(MeetsTheme.textPrimary)

                        Text("Connect an LLM provider to get AI-powered meeting notes.\nYou can set this up later in Settings.")
                            .font(MeetsTheme.body())
                            .foregroundStyle(MeetsTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, MeetsTheme.spacing24)

                    summaryProviderTabs
                    summaryProviderConfig
                }
                .padding(.horizontal, MeetsTheme.spacing32)
                .padding(.bottom, MeetsTheme.spacing16)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            loadACPConfigOptionsIfNeeded()
        }
        .onDisappear {
            acpConfigOptionsLoadTask?.cancel()
            acpConfigOptionsLoadTask = nil
        }
        .onChange(of: summaryBackend) { _, _ in
            apiKey = ""
            saveProgress(atStep: currentStep)
        }
        .onChange(of: appState.config.acpAgentCommand) { _, _ in
            loadACPConfigOptionsIfNeeded()
        }
        .onChange(of: appState.config.postProcessorBackend) { _, _ in
            loadACPConfigOptionsIfNeeded()
        }
        .onChange(of: currentStep) { _, newStep in
            if newStep == OnboardingFlow.Step.meetingSummary.rawValue {
                loadACPConfigOptionsIfNeeded()
            }
        }
    }

    /// Step 6: AI Transcript Cleanup — same component language as Meeting
    /// Summaries: provider tab strip + per-backend config rows below.
    private var transcriptCleanupStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: MeetsTheme.spacing16) {
                    VStack(spacing: MeetsTheme.spacing8) {
                        Text("AI Transcript Cleanup")
                            .font(MeetsTheme.title1())
                            .foregroundStyle(MeetsTheme.textPrimary)

                        Text("Automatically clean finished transcripts — remove filler words and disfluencies.\nYou can set this up later in Settings.")
                            .font(MeetsTheme.body())
                            .foregroundStyle(MeetsTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, MeetsTheme.spacing24)

                    cleanupEnabledRow

                    if appState.config.enablePostProcessor {
                        cleanupBackendTabs
                        cleanupBackendConfig
                    }
                }
                .padding(.horizontal, MeetsTheme.spacing32)
                .padding(.bottom, MeetsTheme.spacing16)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            loadACPConfigOptionsIfNeeded()
        }
        .onDisappear {
            acpConfigOptionsLoadTask?.cancel()
            acpConfigOptionsLoadTask = nil
        }
        .onChange(of: appState.config.acpAgentCommand) { _, _ in
            loadACPConfigOptionsIfNeeded()
        }
        .onChange(of: appState.config.postProcessorBackend) { _, _ in
            loadACPConfigOptionsIfNeeded()
        }
        .onChange(of: currentStep) { _, newStep in
            if newStep == OnboardingFlow.Step.transcriptCleanup.rawValue {
                loadACPConfigOptionsIfNeeded()
            }
        }
    }

    /// On/off row for cleanup, matching the summary step's section rhythm.
    private var cleanupEnabledRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clean finished transcripts")
                    .font(MeetsTheme.headline())
                    .foregroundStyle(MeetsTheme.textPrimary)
                Text("Removes filler words and disfluencies from finished transcripts.")
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textSecondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { appState.config.enablePostProcessor },
                set: { controller.setPostProcessorEnabled($0) }
            ))
            .toggleStyle(.switch)
            .tint(MeetsTheme.accent)
            .labelsHidden()
        }
        .padding(MeetsTheme.spacing16)
        .background(MeetsTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium)
                .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
        )
    }

    // MARK: Cleanup backend tabs

    /// Tab strip over cleanup backends (Gemma excluded), same visual as the
    /// Meeting Summaries provider tabs.
    private var cleanupBackendTabs: some View {
        HStack(spacing: 0) {
            ForEach(cleanupBackendOptions, id: \.backend) { option in
                providerTab(option.label, selected: cleanupBackend == option) {
                    controller.selectPostProcessorBackend(option)
                }
            }
        }
        .background(MeetsTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
        )
        .frame(width: CGFloat(cleanupBackendOptions.count) * Self.providerTabWidth)
    }

    /// Per-backend config below the tabs — renders the same component views
    /// and styles as the Meeting Summaries per-backend configs. ChatGPT /
    /// OpenAI / OpenRouter / Ollama / Agent (ACP) reuse the summary config
    /// verbatim (same account, key, agent settings). LM Studio and Custom LLM
    /// mirror the summary rows but write the cleanup model fields, matching
    /// Settings' separate per-feature model.
    @ViewBuilder
    private var cleanupBackendConfig: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
            if cleanupBackend.isLocal {
                Text("Uses the local Qwen3 model downloaded in Models. Model management stays in Settings.")
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, MeetsTheme.spacing4)
            } else {
                switch cleanupBackend.backend {
                case "chatgpt":
                    summaryChatGPTConfig
                case "openai":
                    summaryOpenAIConfig
                case "openrouter":
                    summaryOpenRouterConfig
                case "ollama":
                    summaryOllamaConfig
                case "lmstudio":
                    cleanupLMStudioConfig
                case "custom_llm":
                    cleanupCustomLLMConfig
                case "acp_agent":
                    summaryACPAgentConfig
                case AppleIntelligenceBackend.backend:
                    appleIntelligenceConfig
                default:
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// LM Studio config mirroring summaryLMStudioConfig but persisting the
    /// transcript-cleanup model field.
    private var cleanupLMStudioConfig: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
            Text("Run models from LM Studio on this Mac. Add the server URL and model.")
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textSecondary)

            configFieldRow("Server URL", controlWidth: 320) {
                PastableTextField(
                    text: appState.config.lmStudioURL,
                    placeholder: "http://localhost:1234",
                    onChange: { val in controller.updateConfig { $0.lmStudioURL = val } }
                )
                .frame(height: 26)
            }

            configFieldRow("Model", controlWidth: 320) {
                PastableTextField(
                    text: cleanupConfiguredModel,
                    placeholder: TranscriptCleanupClient.defaultModel(for: cleanupBackend),
                    onChange: { newModel in
                        controller.updateConfig { $0.postProcessorLMStudioModel = newModel }
                    }
                )
                .frame(height: 26)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Custom LLM config mirroring summaryCustomLLMConfig but persisting the
    /// transcript-cleanup model field.
    private var cleanupCustomLLMConfig: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
            Text("Connect any OpenAI-compatible or Anthropic endpoint.")
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textSecondary)

            configFieldRow("API Format", controlWidth: 320) {
                wizardMenu(
                    selection: CustomLLMFormat(rawValue: appState.config.customLLMFormat)?.label ?? CustomLLMFormat.openAI.label,
                    options: CustomLLMFormat.allCases.map(\.label)
                ) { label in
                    guard let format = CustomLLMFormat.allCases.first(where: { $0.label == label }) else { return }
                    controller.updateConfig { $0.customLLMFormat = format.rawValue }
                }
            }

            configFieldRow("URL", controlWidth: 320) {
                PastableTextField(
                    text: appState.config.customLLMURL,
                    placeholder: CustomLLMFormat(rawValue: appState.config.customLLMFormat) == .anthropic
                        ? "https://api.anthropic.com"
                        : "http://localhost:8080/v1",
                    onChange: { val in controller.updateConfig { $0.customLLMURL = val } }
                )
                .frame(height: 26)
            }

            configFieldRow("API Key", controlWidth: 320) {
                PastableSecureField(
                    text: appState.config.customLLMAPIKey,
                    placeholder: CustomLLMFormat(rawValue: appState.config.customLLMFormat) == .anthropic
                        ? "Required for Anthropic API"
                        : "Optional for local servers",
                    onChange: { val in controller.updateConfig { $0.customLLMAPIKey = val } }
                )
                .frame(height: 26)
            }

            configFieldRow("Model", controlWidth: 320) {
                PastableTextField(
                    text: cleanupConfiguredModel,
                    placeholder: TranscriptCleanupClient.defaultModel(for: cleanupBackend),
                    onChange: { newModel in
                        controller.updateConfig { $0.postProcessorCustomLLMModel = newModel }
                    }
                )
                .frame(height: 26)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Summary Provider Tabs

    private var summaryProviderTabs: some View {
        HStack(spacing: 0) {
            ForEach(MeetingSummaryBackendOption.all, id: \.backend) { option in
                providerTab(option.label, selected: summaryBackend == option) {
                    summaryBackend = option
                }
            }
        }
        .background(MeetsTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
        )
        .frame(width: CGFloat(MeetingSummaryBackendOption.all.count) * Self.providerTabWidth)
    }

    @ViewBuilder
    private var summaryProviderConfig: some View {
        if summaryBackend == .chatGPT {
            summaryChatGPTConfig
        } else if summaryBackend == .openAI {
            summaryOpenAIConfig
        } else if summaryBackend == .ollama {
            summaryOllamaConfig
        } else if summaryBackend == .openRouter {
            summaryOpenRouterConfig
        } else if summaryBackend == .lmStudio {
            summaryLMStudioConfig
        } else if summaryBackend == .customLLM {
            summaryCustomLLMConfig
        } else if summaryBackend == .appleIntelligence {
            appleIntelligenceConfig
        } else {
            summaryACPAgentConfig
        }
    }

    /// Apple Intelligence needs no provider setup: live availability plus the
    /// on-device privacy note instead of account, key, or model rows.
    private var appleIntelligenceConfig: some View {
        let status = AppleIntelligenceBackend.status
        return VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.isAvailable ? MeetsTheme.success : MeetsTheme.textTertiary)
                    .frame(width: 6, height: 6)
                Text(status.summary)
                    .font(MeetsTheme.body())
                    .foregroundStyle(status.isAvailable ? MeetsTheme.textPrimary : MeetsTheme.textSecondary)
            }
            Text(AppleIntelligenceBackend.privacyDescription)
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }

    // MARK: Per-backend config

    private var summaryChatGPTConfig: some View {
        VStack(spacing: MeetsTheme.spacing8) {
            Text("Use your ChatGPT Plus or Pro subscription.")
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textSecondary)

            if appState.isChatGPTAuthenticated || chatGPTSignInDone {
                HStack(spacing: 6) {
                    OpenAILogoShape()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                    Text("Signed in with ChatGPT")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(MeetsTheme.success)
                .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
            } else if isSigningInChatGPT {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Signing in...")
                        .font(.system(size: 12))
                        .foregroundStyle(MeetsTheme.textSecondary)
                }
            } else {
                Button {
                    isSigningInChatGPT = true
                    chatGPTSignInError = nil
                    Task {
                        let error = await controller.signInWithChatGPT()
                        isSigningInChatGPT = false
                        chatGPTSignInDone = ChatGPTAuthManager.shared.isAuthenticated
                        chatGPTSignInError = error
                    }
                } label: {
                    HStack(spacing: 6) {
                        OpenAILogoShape()
                            .fill(MeetsTheme.accentContent)
                            .frame(width: 14, height: 14)
                        Text("Sign in with ChatGPT")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(MeetsTheme.accentContent)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(MeetsTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                }
                .buttonStyle(.plain)

                if let chatGPTSignInError {
                    Text(chatGPTSignInError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var summaryOpenAIConfig: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
            Text("Use your OpenAI API key.")
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textSecondary)

            VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
                Text("API Key")
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textTertiary)

                PastableSecureField(
                    text: apiKey,
                    placeholder: "sk-...",
                    onChange: { apiKey = $0 }
                )
                .frame(width: 320, height: 28)

                HStack(spacing: 4) {
                    Circle()
                        .fill(apiKey.isEmpty ? MeetsTheme.textTertiary : MeetsTheme.success)
                        .frame(width: 6, height: 6)
                    Text(apiKey.isEmpty ? "No API key" : "Key entered")
                        .font(.system(size: 11))
                        .foregroundStyle(apiKey.isEmpty ? MeetsTheme.textTertiary : MeetsTheme.success)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private var summaryOllamaConfig: some View {
        VStack(spacing: MeetsTheme.spacing8) {
            Text("Run AI models locally on your device with Ollama.\nNo API key needed — just install Ollama and pull a model.")
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textSecondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
                Text("Ollama is served by default at http://localhost:11434")
                    .font(.system(size: 11))
                    .foregroundStyle(MeetsTheme.textTertiary)

                HStack(spacing: 4) {
                    Circle()
                        .fill(MeetsTheme.success)
                        .frame(width: 6, height: 6)
                    Text("No authentication required")
                        .font(.system(size: 11))
                        .foregroundStyle(MeetsTheme.success)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var summaryOpenRouterConfig: some View {
        VStack(spacing: MeetsTheme.spacing8) {
            Text("Connect OpenRouter in your browser. Meets receives a dedicated API key after you approve access.")
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textSecondary)
                .multilineTextAlignment(.center)

            if appState.isOpenRouterAuthenticated || openRouterSignInDone {
                HStack(spacing: 6) {
                    Image(systemName: "network")
                        .font(.system(size: 13, weight: .semibold))
                    Text("OpenRouter connected")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(MeetsTheme.success)
                .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
            } else if isSigningInOpenRouter {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting...")
                        .font(.system(size: 12))
                        .foregroundStyle(MeetsTheme.textSecondary)
                }
            } else {
                VStack(spacing: MeetsTheme.spacing8) {
                    Button {
                        isSigningInOpenRouter = true
                        openRouterSignInError = nil
                        apiKey = ""
                        isEnteringOpenRouterAPIKey = false
                        Task {
                            let error = await controller.signInWithOpenRouter()
                            isSigningInOpenRouter = false
                            openRouterSignInDone = OpenRouterAuthManager.shared.isAuthenticated
                            openRouterSignInError = error
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "network")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Connect OpenRouter")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(MeetsTheme.accentContent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(MeetsTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                    }
                    .buttonStyle(.plain)

                    Button(isEnteringOpenRouterAPIKey ? "Cancel manual key" : "Enter API key manually") {
                        isEnteringOpenRouterAPIKey.toggle()
                        apiKey = ""
                        openRouterSignInError = nil
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))

                    if isEnteringOpenRouterAPIKey {
                        PastableSecureField(
                            text: apiKey,
                            placeholder: "sk-or-...",
                            onChange: { apiKey = $0 }
                        )
                        .frame(width: 320, height: 28)
                    }

                    if let openRouterSignInError {
                        Text(openRouterSignInError)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var summaryLMStudioConfig: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
            Text("Run models from LM Studio on this Mac. Add the server URL and model.")
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textSecondary)

            configFieldRow("Server URL", controlWidth: 320) {
                PastableTextField(
                    text: appState.config.lmStudioURL,
                    placeholder: "http://localhost:1234",
                    onChange: { val in controller.updateConfig { $0.lmStudioURL = val } }
                )
                .frame(height: 26)
            }

            configFieldRow("Model", controlWidth: 320) {
                PastableTextField(
                    text: appState.config.lmStudioModel,
                    placeholder: "Select a loaded LM Studio model",
                    onChange: { val in controller.updateConfig { $0.lmStudioModel = val } }
                )
                .frame(height: 26)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var summaryCustomLLMConfig: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
            Text("Connect any OpenAI-compatible or Anthropic endpoint.")
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textSecondary)

            configFieldRow("API Format", controlWidth: 320) {
                wizardMenu(
                    selection: CustomLLMFormat(rawValue: appState.config.customLLMFormat)?.label ?? CustomLLMFormat.openAI.label,
                    options: CustomLLMFormat.allCases.map(\.label)
                ) { label in
                    guard let format = CustomLLMFormat.allCases.first(where: { $0.label == label }) else { return }
                    controller.updateConfig { $0.customLLMFormat = format.rawValue }
                }
            }

            configFieldRow("URL", controlWidth: 320) {
                PastableTextField(
                    text: appState.config.customLLMURL,
                    placeholder: CustomLLMFormat(rawValue: appState.config.customLLMFormat) == .anthropic
                        ? "https://api.anthropic.com"
                        : "http://localhost:8080/v1",
                    onChange: { val in controller.updateConfig { $0.customLLMURL = val } }
                )
                .frame(height: 26)
            }

            configFieldRow("API Key", controlWidth: 320) {
                PastableSecureField(
                    text: appState.config.customLLMAPIKey,
                    placeholder: CustomLLMFormat(rawValue: appState.config.customLLMFormat) == .anthropic
                        ? "Required for Anthropic API"
                        : "Optional for local servers",
                    onChange: { val in controller.updateConfig { $0.customLLMAPIKey = val } }
                )
                .frame(height: 26)
            }

            configFieldRow("Model", controlWidth: 320) {
                PastableTextField(
                    text: appState.config.customLLMModel,
                    placeholder: CustomLLMFormat(rawValue: appState.config.customLLMFormat) == .anthropic
                        ? "claude-3-5-sonnet-20241022"
                        : "custom-model-id",
                    onChange: { val in controller.updateConfig { $0.customLLMModel = val } }
                )
                .frame(height: 26)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var summaryACPAgentConfig: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
            Text("Runs your installed agent (omp, Claude Code, Codex…) over ACP. No API key.")
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textSecondary)

            configFieldRow("Command", controlWidth: 320) {
                ACPCommandPicker(
                    appState: appState,
                    controller: controller,
                    popupHeight: 26,
                    fieldHeight: 26
                )
            }

            acpWizardMenuRow(
                label: "Model",
                caption: acpWizardModelCaption,
                optionID: "model",
                storedValue: appState.config.acpAgentModel
            ) { value in
                controller.updateConfig { $0.acpAgentModel = value }
            }

            acpWizardMenuRow(
                label: "Reasoning",
                caption: Self.acpWizardThinkingCaption,
                optionID: "thinking",
                storedValue: appState.config.acpAgentThinking
            ) { value in
                controller.updateConfig { $0.acpAgentThinking = value }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private static let acpWizardThinkingCaption = "Reasoning effort: off / auto / low / medium / high / xhigh / max."

    private var acpWizardModelCaption: String? {
        guard !isACPConfigOptionsLoading else { return nil }
        return acpOptionsUnavailable || (acpConfigOptions?.first(where: { $0.id == "model" })?.options.isEmpty ?? true)
            ? "Start the agent to see available models."
            : nil
    }

    private var isACPConfigOptionsLoading: Bool {
        !appState.config.acpAgentCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && acpConfigOptions == nil
            && acpConfigOptionsLoadTask != nil
            && !acpOptionsUnavailable
    }

    private var isShowingACPConfigOptions: Bool {
        let summaryIsACP = summaryBackend == .acpAgent
        let cleanupIsACP = cleanupBackend.backend == "acp_agent"
        return summaryIsACP || cleanupIsACP
    }

    /// (Re)fetches the ACP agent's advertised config options whenever an ACP
    /// branch is visible with a non-empty command. Failures degrade to "use
    /// agent default": a single "Default" entry in each menu.
    private func loadACPConfigOptionsIfNeeded() {
        guard isShowingACPConfigOptions else {
            acpConfigOptionsLoadTask?.cancel()
            acpConfigOptionsLoadTask = nil
            acpConfigOptions = nil
            acpConfigOptionsCommand = ""
            acpOptionsUnavailable = false
            return
        }
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

    private func acpOptionValues(_ id: String) -> [ACPConfigValue] {
        acpConfigOptions?.first(where: { $0.id == id })?.options ?? []
    }

    @ViewBuilder
    private func acpWizardMenuRow(
        label: String,
        caption: String?,
        optionID: String,
        storedValue: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        if isACPConfigOptionsLoading {
            configFieldRow(label, controlWidth: 320) {
                Text("Loading…")
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textTertiary)
                    .frame(maxWidth: 320, alignment: .trailing)
            }
        } else {
            let entries = [("", "Default")] + acpOptionValues(optionID).map { ($0.value, $0.name) }
            let selectedLabel = {
                if storedValue.isEmpty {
                    return "Default"
                }
                return entries.first(where: { $0.0 == storedValue })?.1 ?? "Default"
            }()
            configFieldRow(label, controlWidth: 320) {
                wizardMenu(
                    selection: selectedLabel,
                    options: entries.map(\.1)
                ) { pickedLabel in
                    guard let entry = entries.first(where: { $0.1 == pickedLabel }) else { return }
                    onSelect(entry.0)
                }
            }
            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(MeetsTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Transcript Cleanup

    private var cleanupBackendOptions: [TranscriptCleanupBackendOption] {
        TranscriptCleanupBackendOption.all.filter { !$0.isGemma4LiteRT }
    }

    private var cleanupBackend: TranscriptCleanupBackendOption {
        TranscriptCleanupBackendOption.resolved(appState.config.postProcessorBackend)
    }

    private var cleanupConfiguredModel: String {
        TranscriptCleanupClient.configuredModel(for: cleanupBackend, config: appState.config)
    }

    // MARK: Shared wizard controls

    private func configFieldRow(_ label: String, controlWidth: CGFloat, @ViewBuilder control: () -> some View) -> some View {
        HStack(alignment: .center) {
            Text(label)
                .font(MeetsTheme.body())
                .foregroundStyle(MeetsTheme.textPrimary)
                .layoutPriority(1)
            Spacer(minLength: 16)
            control()
                .frame(maxWidth: controlWidth)
        }
    }

    private func wizardMenu(selection: String, options: [String], onChange: @escaping (String) -> Void) -> some View {
        FixedWidthPopUp(
            selection: selection,
            options: options,
            onChange: onChange
        )
        .frame(height: 24)
    }

    private func providerTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? MeetsTheme.textPrimary : MeetsTheme.textSecondary)
                .frame(width: Self.providerTabWidth)
                .padding(.vertical, MeetsTheme.spacing8)
                .background(selected ? MeetsTheme.surfacePrimary : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
        }
        .buttonStyle(.plain)
    }

    /// Width of one provider tab. Tab strips size themselves from the number of
    /// backends they list.
    private static let providerTabWidth: CGFloat = 80

    // MARK: - Actions

    private func startDownload() {
        guard selectedBackend.isCompatible() else { return }
        ensureModelDownloadStarted()
        goToNextStep()
    }

    private func ensureModelDownloadStarted() {
        if let reason = selectedBackend.incompatibilityReason() {
            modelDownloadError = reason
            return
        }
        if modelReadyBackend == selectedBackend {
            isModelStillDownloading = false
            modelDownloadProgress = 1.0
            isModelPreparingAfterDownload = false
            modelDownloadStatus = "\(selectedBackend.label) ready"
            modelDownloadError = nil
            clearModelPreparationStatus()
            return
        }

        if modelDownloadTask != nil {
            guard modelDownloadBackend != selectedBackend else {
                isModelStillDownloading = true
                return
            }
            cancelModelDownload(for: modelDownloadBackend)
            modelDownloadGeneration = UUID()
            modelDownloadTask?.cancel()
            modelDownloadTask = nil
            modelDownloadBackend = nil
        }

        let backend = selectedBackend
        let useCase = selectedUseCase
        let generation = UUID()
        let alreadyDownloaded = backend.isDownloaded
        modelDownloadGeneration = generation
        modelDownloadBackend = backend
        isModelStillDownloading = true
        modelDownloadProgress = alreadyDownloaded ? nil : (modelDownloadProgress ?? 0.02)
        isModelPreparingAfterDownload = alreadyDownloaded
        modelDownloadStatus = alreadyDownloaded
            ? "Warming up \(backend.label)..."
            : (modelDownloadStatus ?? initialDownloadStatus(for: backend))
        modelDownloadError = nil
        modelDownloadSnapshot = nil
        publishModelPreparationStatus(
            title: "Preparing \(backend.label)",
            detail: modelDownloadStatus,
            progress: modelDownloadProgress,
            isPreparing: isModelPreparingAfterDownload
        )

        modelDownloadTask = Task {
            defer {
                Task { @MainActor in
                    if modelDownloadGeneration == generation, modelDownloadBackend == backend {
                        modelDownloadTask = nil
                        modelDownloadBackend = nil
                    }
                }
            }
            do {
                try await controller.downloadModelForOnboarding(backend, onboardingUseCase: useCase) { progress, status in
                    Task { @MainActor in
                        guard modelDownloadGeneration == generation,
                              modelDownloadBackend == backend,
                              selectedBackend == backend else { return }
                        applyModelPreparationProgress(progress, status: status, backend: backend, generation: generation)
                    }
                } progressSnapshot: { snapshot in
                    Task { @MainActor in
                        guard modelDownloadGeneration == generation,
                              modelDownloadBackend == backend,
                              selectedBackend == backend else { return }
                        applyModelDownloadSnapshot(snapshot, backend: backend, generation: generation)
                    }
                }
                await MainActor.run {
                    guard modelDownloadGeneration == generation,
                          modelDownloadBackend == backend,
                          selectedBackend == backend else { return }
                    modelReadyBackend = backend
                    modelDownloadProgress = 1.0
                    modelDownloadSnapshot = nil
                    isModelPreparingAfterDownload = false
                    modelDownloadStatus = "\(backend.label) ready"
                    modelDownloadError = nil
                    withAnimation { isModelStillDownloading = false }
                    clearModelPreparationStatus()
                    saveProgress(atStep: currentStep)
                }
            } catch is CancellationError {
                // Backend changes cancel the old task; the new selection owns the download UI.
            } catch {
                await MainActor.run {
                    guard modelDownloadGeneration == generation,
                          modelDownloadBackend == backend,
                          selectedBackend == backend else { return }
                    modelDownloadError = modelPreparationFailureMessage(for: backend)
                    modelDownloadStatus = backend.isDownloaded ? "Model setup paused" : "Download paused"
                    modelDownloadProgress = nil
                    if let snapshot = modelDownloadSnapshot {
                        modelDownloadSnapshot = snapshot.replacing(
                            phase: .failed,
                            message: modelDownloadError
                        )
                    }
                    isModelPreparingAfterDownload = false
                    isModelStillDownloading = false
                    publishModelPreparationStatus(
                        title: backend.isDownloaded ? "Model setup paused" : "Download paused",
                        detail: modelDownloadError,
                        progress: nil,
                        isPreparing: false
                    )
                }
                fputs("[meets] onboarding model download failed: \(error)\n", stderr)
            }
        }
    }

    private func applyModelDownloadSnapshot(
        _ snapshot: ModelDownloadProgress,
        backend: BackendOption,
        generation: UUID
    ) {
        guard modelDownloadGeneration == generation,
              modelDownloadBackend == backend,
              selectedBackend == backend else { return }
        modelDownloadSnapshot = snapshot
        modelDownloadError = nil

        switch snapshot.phase {
        case .downloading:
            isModelStillDownloading = true
            isModelPreparingAfterDownload = false
            if let fraction = snapshot.fractionCompleted {
                modelDownloadProgress = max(modelDownloadProgress ?? 0.02, fraction)
            }
            modelDownloadStatus = modelDownloadSnapshotDetail(snapshot)
        case .preparing:
            isModelStillDownloading = true
            isModelPreparingAfterDownload = true
            modelDownloadProgress = nil
            modelDownloadStatus = snapshot.message ?? "Preparing \(backend.label)..."
        case .ready:
            modelDownloadStatus = snapshot.message ?? "\(backend.label) ready"
        case .paused:
            isModelStillDownloading = false
            isModelPreparingAfterDownload = false
            modelDownloadStatus = snapshot.message ?? "Download paused"
        case .failed:
            isModelStillDownloading = false
            isModelPreparingAfterDownload = false
            modelDownloadError = snapshot.message
            modelDownloadStatus = snapshot.message ?? "Download failed"
        }

        if snapshot.phase == .ready {
            clearModelPreparationStatus()
        } else {
            publishModelPreparationStatus(
                title: modelDownloadIndicatorTitle,
                detail: modelDownloadStatus,
                progress: modelDownloadProgress,
                isPreparing: isModelPreparingAfterDownload
            )
        }
    }

    private func applyModelPreparationProgress(
        _ progress: Double,
        status: String?,
        backend: BackendOption,
        generation: UUID
    ) {
        guard modelDownloadGeneration == generation,
              modelDownloadBackend == backend,
              selectedBackend == backend else { return }
        let detail = status ?? "Preparing \(backend.label)..."
        let lowercasedDetail = detail.lowercased()
        let isPreparing = lowercasedDetail.contains("compiling")
            || lowercasedDetail.contains("warming")
            || lowercasedDetail.contains("readying")

        modelDownloadError = nil
        isModelStillDownloading = true

        if isPreparing {
            isModelPreparingAfterDownload = true
            modelDownloadStatus = "Optimizing \(backend.label) for this Mac..."
            publishModelPreparationStatus(
                title: "Preparing \(backend.label)",
                detail: modelDownloadStatus,
                progress: nil,
                isPreparing: true
            )
            saveProgress(atStep: currentStep)
            return
        }

        isModelPreparingAfterDownload = false
        let clampedProgress = min(max(progress, 0), 1)
        let currentProgress = modelDownloadProgress ?? 0
        let isZeroReset = clampedProgress <= 0.001 && currentProgress > 0.03

        guard !isZeroReset else { return }
        modelDownloadProgress = max(currentProgress, max(clampedProgress, 0.02))
        modelDownloadStatus = detail
        publishModelPreparationStatus(
            title: "Preparing \(backend.label)",
            detail: detail,
            progress: modelDownloadProgress,
            isPreparing: false
        )
        saveProgress(atStep: currentStep)
    }

    private func resetModelDownloadForBackendChange() {
        cancelModelDownload(for: modelDownloadBackend)
        modelDownloadGeneration = UUID()
        modelDownloadTask?.cancel()
        modelDownloadTask = nil
        modelReadyBackend = nil
        modelDownloadBackend = nil
        modelDownloadProgress = nil
        modelDownloadSnapshot = nil
        isModelPreparingAfterDownload = false
        modelDownloadStatus = nil
        modelDownloadError = nil
        isModelStillDownloading = false
    }

    private func cancelModelDownload(for backend: BackendOption?) {
        guard let backend else { return }
        Task {
            await ManagedASRModelDownloader.cancel(modelID: backend.model)
        }
    }

    private func initialDownloadStatus(for backend: BackendOption) -> String {
        let size = backend.sizeLabel
            .replacingOccurrences(of: "~", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !size.isEmpty {
            return "0 MB of \(size)"
        }
        return "Starting \(backend.label) download..."
    }

    private func modelPreparationFailureMessage(for backend: BackendOption) -> String {
        backend.isDownloaded
            ? "Model setup failed. Restart Meets or retry from Models."
            : "Download failed. Check your connection and retry."
    }

    private func publishModelPreparationStatus(
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

    private var calendarAccessStep: some View {
        VStack(spacing: MeetsTheme.spacing24) {
            Spacer()
            Image(nsImage: CalendarIntegration.calendarIcon)
                .resizable()
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
            Text("Bring your meetings into Meets")
                .font(MeetsTheme.title1())
                .foregroundStyle(MeetsTheme.textPrimary)
            Text("Allow access to macOS Calendar to see upcoming meetings and get reminders.")
                .font(MeetsTheme.body())
                .foregroundStyle(MeetsTheme.textSecondary)
            CalendarAccessControl {
                await controller.calendarAccessDidChange()
            }
            Button("Set up calendar accounts…", action: CalendarIntegration.openAccounts)
                .buttonStyle(.link)
            Divider().background(MeetsTheme.surfaceBorder)
            Text("Already use Google or Exchange? Add the account in macOS Internet Accounts and turn on Calendars.")
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textSecondary)
            Spacer()
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, MeetsTheme.spacing32)
    }

    private func finishOnboarding(withKey: Bool) {
        hasFinishedOnboarding = true
        OnboardingProgress.clear()
        let shouldContinueModelPreparation = modelDownloadTask != nil && modelReadyBackend != selectedBackend
        if shouldContinueModelPreparation {
            modelDownloadGeneration = UUID()
            modelDownloadTask?.cancel()
            modelDownloadTask = nil
            modelDownloadBackend = nil
            controller.continueModelPreparationAfterOnboarding(
                selectedBackend,
                onboardingUseCase: selectedUseCase,
                initialProgress: modelDownloadProgress,
                initialStatus: modelDownloadStatus,
                isPreparing: isModelPreparingAfterDownload
            )
        } else if modelReadyBackend == selectedBackend {
            clearModelPreparationStatus()
        } else if isModelStillDownloading {
            publishModelPreparationStatus(
                title: "Preparing \(selectedBackend.label)",
                detail: modelDownloadStatus,
                progress: modelDownloadProgress,
                isPreparing: isModelPreparingAfterDownload
            )
        }
        controller.completeOnboarding(
            userName: userName.trimmingCharacters(in: .whitespaces),
            backend: selectedBackend,
            cohereLanguage: selectedCohereLanguage,
            hotkey: selectedHotkey,
            onboardingUseCase: selectedUseCase,
            summaryBackend: summaryBackend,
            apiKey: withKey ? apiKey : nil
        )
    }
}

private struct ModelDownloadProgressShape: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clampedProgress = min(max(progress, 0), 1)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()

        guard clampedProgress > 0 else { return path }
        path.move(to: center)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + (360 * clampedProgress)),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Text Field

/// NSTextField subclass that handles Cmd+V/C/X/A without needing a standard Edit menu.
class EditableNSTextField: NSTextField {
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

struct OnboardingTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var onSubmit: (() -> Void)?

    func makeNSView(context: Context) -> EditableNSTextField {
        let field = EditableNSTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 14)
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
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        let onSubmit: (() -> Void)?

        init(text: Binding<String>, onSubmit: (() -> Void)?) {
            _text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit?()
                return true
            }
            return false
        }
    }
}

// MARK: - OpenAI Logo

struct OpenAILogoShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 24
        var p = Path()
        p.move(to: CGPoint(x: 22.2819 * sx, y: 9.8211 * sy))
        p.addCurve(to: CGPoint(x: 21.7662 * sx, y: 4.9103 * sy), control1: CGPoint(x: 22.8248 * sx, y: 8.1862 * sy), control2: CGPoint(x: 22.6369 * sx, y: 6.3967 * sy))
        p.addCurve(to: CGPoint(x: 15.2564 * sx, y: 2.0103 * sy), control1: CGPoint(x: 20.4571 * sx, y: 2.6316 * sy), control2: CGPoint(x: 17.8260 * sx, y: 1.4595 * sy))
        p.addCurve(to: CGPoint(x: 4.9807 * sx, y: 4.1818 * sy), control1: CGPoint(x: 12.1364 * sx, y: -1.4602 * sy), control2: CGPoint(x: 6.4298 * sx, y: -0.2543 * sy))
        p.addCurve(to: CGPoint(x: 0.9830 * sx, y: 7.0818 * sy), control1: CGPoint(x: 3.2928 * sx, y: 4.5279 * sy), control2: CGPoint(x: 1.8360 * sx, y: 5.5847 * sy))
        p.addCurve(to: CGPoint(x: 1.7257 * sx, y: 14.1784 * sy), control1: CGPoint(x: -0.3404 * sx, y: 9.3568 * sy), control2: CGPoint(x: -0.0401 * sx, y: 12.2267 * sy))
        p.addCurve(to: CGPoint(x: 2.2367 * sx, y: 19.0891 * sy), control1: CGPoint(x: 1.1808 * sx, y: 15.8125 * sy), control2: CGPoint(x: 1.3670 * sx, y: 17.6022 * sy))
        p.addCurve(to: CGPoint(x: 8.7513 * sx, y: 21.9892 * sy), control1: CGPoint(x: 3.5475 * sx, y: 21.3686 * sy), control2: CGPoint(x: 6.1803 * sx, y: 22.5406 * sy))
        p.addCurve(to: CGPoint(x: 13.2599 * sx, y: 24.0000 * sy), control1: CGPoint(x: 9.8948 * sx, y: 23.2770 * sy), control2: CGPoint(x: 11.5377 * sx, y: 24.0097 * sy))
        p.addCurve(to: CGPoint(x: 19.0317 * sx, y: 19.7942 * sy), control1: CGPoint(x: 15.8937 * sx, y: 24.0024 * sy), control2: CGPoint(x: 18.2271 * sx, y: 22.3021 * sy))
        p.addCurve(to: CGPoint(x: 23.0294 * sx, y: 16.8941 * sy), control1: CGPoint(x: 20.7194 * sx, y: 19.4475 * sy), control2: CGPoint(x: 22.1760 * sx, y: 18.3908 * sy))
        p.addCurve(to: CGPoint(x: 22.2819 * sx, y: 9.8212 * sy), control1: CGPoint(x: 24.3368 * sx, y: 14.6231 * sy), control2: CGPoint(x: 24.0351 * sx, y: 11.7688 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 13.2599 * sx, y: 22.4292 * sy))
        p.addCurve(to: CGPoint(x: 10.3835 * sx, y: 21.3884 * sy), control1: CGPoint(x: 12.2086 * sx, y: 22.4309 * sy), control2: CGPoint(x: 11.1903 * sx, y: 22.0624 * sy))
        p.addLine(to: CGPoint(x: 10.5254 * sx, y: 21.3080 * sy))
        p.addLine(to: CGPoint(x: 15.3037 * sx, y: 18.5498 * sy))
        p.addCurve(to: CGPoint(x: 15.6964 * sx, y: 17.8685 * sy), control1: CGPoint(x: 15.5456 * sx, y: 18.4079 * sy), control2: CGPoint(x: 15.6949 * sx, y: 18.1490 * sy))
        p.addLine(to: CGPoint(x: 15.6964 * sx, y: 11.1316 * sy))
        p.addLine(to: CGPoint(x: 17.7164 * sx, y: 12.3002 * sy))
        p.addCurve(to: CGPoint(x: 17.7544 * sx, y: 12.3522 * sy), control1: CGPoint(x: 17.7367 * sx, y: 12.3105 * sy), control2: CGPoint(x: 17.7508 * sx, y: 12.3298 * sy))
        p.addLine(to: CGPoint(x: 17.7544 * sx, y: 17.9348 * sy))
        p.addCurve(to: CGPoint(x: 13.2599 * sx, y: 22.4292 * sy), control1: CGPoint(x: 17.7491 * sx, y: 20.4148 * sy), control2: CGPoint(x: 15.7399 * sx, y: 22.4240 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 3.5992 * sx, y: 18.3038 * sy))
        p.addCurve(to: CGPoint(x: 3.0646 * sx, y: 15.2901 * sy), control1: CGPoint(x: 3.0720 * sx, y: 17.3934 * sy), control2: CGPoint(x: 2.8827 * sx, y: 16.3263 * sy))
        p.addLine(to: CGPoint(x: 3.2066 * sx, y: 15.3753 * sy))
        p.addLine(to: CGPoint(x: 7.9896 * sx, y: 18.1335 * sy))
        p.addCurve(to: CGPoint(x: 8.7702 * sx, y: 18.1335 * sy), control1: CGPoint(x: 8.2306 * sx, y: 18.2749 * sy), control2: CGPoint(x: 8.5292 * sx, y: 18.2749 * sy))
        p.addLine(to: CGPoint(x: 14.6130 * sx, y: 14.7650 * sy))
        p.addLine(to: CGPoint(x: 14.6130 * sx, y: 17.0974 * sy))
        p.addCurve(to: CGPoint(x: 14.5798 * sx, y: 17.1589 * sy), control1: CGPoint(x: 14.6119 * sx, y: 17.1219 * sy), control2: CGPoint(x: 14.5997 * sx, y: 17.1445 * sy))
        p.addLine(to: CGPoint(x: 9.7400 * sx, y: 19.9502 * sy))
        p.addCurve(to: CGPoint(x: 3.5992 * sx, y: 18.3038 * sy), control1: CGPoint(x: 7.5893 * sx, y: 21.1891 * sy), control2: CGPoint(x: 4.8416 * sx, y: 20.4525 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 2.3408 * sx, y: 7.8956 * sy))
        p.addCurve(to: CGPoint(x: 4.7063 * sx, y: 5.9228 * sy), control1: CGPoint(x: 2.8717 * sx, y: 6.9794 * sy), control2: CGPoint(x: 3.7096 * sx, y: 6.2805 * sy))
        p.addLine(to: CGPoint(x: 4.7063 * sx, y: 11.6000 * sy))
        p.addCurve(to: CGPoint(x: 5.0942 * sx, y: 12.2765 * sy), control1: CGPoint(x: 4.7026 * sx, y: 11.8793 * sy), control2: CGPoint(x: 4.8513 * sx, y: 12.1386 * sy))
        p.addLine(to: CGPoint(x: 10.9086 * sx, y: 15.6308 * sy))
        p.addLine(to: CGPoint(x: 8.8885 * sx, y: 16.7993 * sy))
        p.addCurve(to: CGPoint(x: 8.8175 * sx, y: 16.7993 * sy), control1: CGPoint(x: 8.8663 * sx, y: 16.8111 * sy), control2: CGPoint(x: 8.8397 * sx, y: 16.8111 * sy))
        p.addLine(to: CGPoint(x: 3.9872 * sx, y: 14.0128 * sy))
        p.addCurve(to: CGPoint(x: 2.3408 * sx, y: 7.8720 * sy), control1: CGPoint(x: 1.8408 * sx, y: 12.7686 * sy), control2: CGPoint(x: 1.1047 * sx, y: 10.0230 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 18.9371 * sx, y: 11.7514 * sy))
        p.addLine(to: CGPoint(x: 13.1038 * sx, y: 8.3640 * sy))
        p.addLine(to: CGPoint(x: 15.1192 * sx, y: 7.2000 * sy))
        p.addCurve(to: CGPoint(x: 15.1902 * sx, y: 7.2000 * sy), control1: CGPoint(x: 15.1414 * sx, y: 7.1882 * sy), control2: CGPoint(x: 15.1680 * sx, y: 7.1882 * sy))
        p.addLine(to: CGPoint(x: 20.0205 * sx, y: 9.9913 * sy))
        p.addCurve(to: CGPoint(x: 19.3440 * sx, y: 18.0955 * sy), control1: CGPoint(x: 23.3136 * sx, y: 11.8915 * sy), control2: CGPoint(x: 22.9065 * sx, y: 16.7676 * sy))
        p.addLine(to: CGPoint(x: 19.3440 * sx, y: 12.4183 * sy))
        p.addCurve(to: CGPoint(x: 18.9370 * sx, y: 11.7513 * sy), control1: CGPoint(x: 19.3355 * sx, y: 12.1397 * sy), control2: CGPoint(x: 19.1808 * sx, y: 11.8863 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 20.9478 * sx, y: 8.7283 * sy))
        p.addLine(to: CGPoint(x: 20.8058 * sx, y: 8.6431 * sy))
        p.addLine(to: CGPoint(x: 16.0323 * sx, y: 5.8613 * sy))
        p.addCurve(to: CGPoint(x: 15.2469 * sx, y: 5.8613 * sy), control1: CGPoint(x: 15.7898 * sx, y: 5.7190 * sy), control2: CGPoint(x: 15.4894 * sx, y: 5.7190 * sy))
        p.addLine(to: CGPoint(x: 9.4090 * sx, y: 9.2297 * sy))
        p.addLine(to: CGPoint(x: 9.4090 * sx, y: 6.8974 * sy))
        p.addCurve(to: CGPoint(x: 9.4374 * sx, y: 6.8359 * sy), control1: CGPoint(x: 9.4065 * sx, y: 6.8732 * sy), control2: CGPoint(x: 9.4174 * sx, y: 6.8496 * sy))
        p.addLine(to: CGPoint(x: 14.2677 * sx, y: 4.0493 * sy))
        p.addCurve(to: CGPoint(x: 20.9479 * sx, y: 8.7093 * sy), control1: CGPoint(x: 17.5693 * sx, y: 2.1473 * sy), control2: CGPoint(x: 21.5928 * sx, y: 4.9539 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 8.3065 * sx, y: 12.8630 * sy))
        p.addLine(to: CGPoint(x: 6.2865 * sx, y: 11.6992 * sy))
        p.addCurve(to: CGPoint(x: 6.2485 * sx, y: 11.6425 * sy), control1: CGPoint(x: 6.2660 * sx, y: 11.6869 * sy), control2: CGPoint(x: 6.2521 * sx, y: 11.6661 * sy))
        p.addLine(to: CGPoint(x: 6.2485 * sx, y: 6.0742 * sy))
        p.addCurve(to: CGPoint(x: 13.6242 * sx, y: 2.6205 * sy), control1: CGPoint(x: 6.2535 * sx, y: 2.2647 * sy), control2: CGPoint(x: 10.6950 * sx, y: 0.1849 * sy))
        p.addLine(to: CGPoint(x: 13.4822 * sx, y: 2.7010 * sy))
        p.addLine(to: CGPoint(x: 8.7040 * sx, y: 5.4590 * sy))
        p.addCurve(to: CGPoint(x: 8.3113 * sx, y: 6.1403 * sy), control1: CGPoint(x: 8.4621 * sx, y: 5.6009 * sy), control2: CGPoint(x: 8.3128 * sx, y: 5.8598 * sy))
        p.closeSubpath()
        // Inner hexagon
        p.move(to: CGPoint(x: 9.4041 * sx, y: 10.4976 * sy))
        p.addLine(to: CGPoint(x: 12.0061 * sx, y: 8.9978 * sy))
        p.addLine(to: CGPoint(x: 14.6130 * sx, y: 10.4976 * sy))
        p.addLine(to: CGPoint(x: 14.6130 * sx, y: 13.4970 * sy))
        p.addLine(to: CGPoint(x: 12.0156 * sx, y: 14.9967 * sy))
        p.addLine(to: CGPoint(x: 9.4089 * sx, y: 13.4970 * sy))
        p.closeSubpath()
        return p
    }
}
