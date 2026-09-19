import FluidAudio
import MeetsCore
import SwiftUI

struct ModelDownloadGenerationState: Equatable {
    private(set) var current: UUID?

    mutating func begin() -> UUID {
        let generation = UUID()
        current = generation
        return generation
    }

    func contains(_ generation: UUID) -> Bool {
        current == generation
    }

    @discardableResult
    mutating func clear(_ generation: UUID) -> Bool {
        guard current == generation else { return false }
        current = nil
        return true
    }
}

struct ModelsView: View {
    let appState: AppState
    let controller: MeetsController

    @State private var nemotron35UpdateAvailable = false
    @State private var downloadingModels: Set<String> = []
    @State private var downloadProgress: [String: Double] = [:]
    @State private var downloadMessages: [String: String] = [:]
    @State private var downloadSnapshots: [String: ModelDownloadProgress] = [:]
    @State private var downloadGenerations: [String: UUID] = [:]
    @State private var downloadedModels: Set<String> = []
    @State private var downloadTasks: [String: Task<Void, Never>] = [:]
    @State private var modelToDelete: BackendOption?
    @State private var selectedParakeetModel: String
    @State private var selectedWhisperModel: String
    @State private var selectedBodhanCoreModel: String
    @State private var selectedBodhanFlexModel: String
    @State private var showExperimental: Bool
    @State private var appleSpeechLanguageOptions: [AppleSpeechLanguageOption] = [.system]
    @State private var isLiveCaptionModelDownloaded = false
    @State private var isDownloadingLiveCaptionModel = false
    @State private var isCancellingLiveCaptionModelDownload = false
    @State private var liveCaptionDownloadProgress = 0.0
    @State private var liveCaptionDownloadTask: Task<Void, Never>?
    @State private var liveCaptionDownloadGeneration = ModelDownloadGenerationState()
    @State private var showDeleteLiveCaptionModelConfirmation = false

    init(appState: AppState, controller: MeetsController) {
        self.appState = appState
        self.controller = controller

        let active = appState.selectedBackend
        _selectedParakeetModel = State(initialValue: BackendOption.parakeetFamily.contains(active) ? active.model : BackendOption.parakeetUnified.model)
        _selectedWhisperModel = State(initialValue: BackendOption.whisperFamily.contains(active) ? active.model : BackendOption.whisperSmall.model)
        let bodhan = BodhanModel(rawValue: active.model)
        _selectedBodhanCoreModel = State(initialValue: bodhan?.isCore == true ? active.model : BodhanModel.coreInt8.rawValue)
        _selectedBodhanFlexModel = State(initialValue: bodhan?.isCore == false ? active.model : BodhanModel.flexInt8.rawValue)
        _showExperimental = State(initialValue: false)
    }

    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: MeetsTheme.spacing24) {
                    Text("Models")
                        .font(MeetsTheme.title1())
                        .foregroundStyle(MeetsTheme.textPrimary)

                    Text("Choose the transcription models that best match how your meetings sound.")
                        .font(MeetsTheme.body())
                        .foregroundStyle(MeetsTheme.textSecondary)

                    Picker("Model category", selection: modelsCategorySelection) {
                        ForEach(ModelsCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity, alignment: .center)

                    selectedCategoryContent
                }
                .padding(.horizontal, MeetsTheme.spacing32)
            .padding(.top, MeetsTheme.pageTop)
            .padding(.bottom, MeetsTheme.spacing32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        .background(MeetsTheme.backgroundBase)
        .onAppear {
            checkDownloadedModels()
            isLiveCaptionModelDownloaded = MeetingLiveCaptionModelStore.isDownloaded()
            syncSelectionsFromActiveBackend()
            checkNemotron35Update()
            loadAppleSpeechLanguageOptions()
        }
        .onChange(of: appState.selectedBackend.model) { _, _ in
            syncSelectionsFromActiveBackend()
        }
        .alert(
            "Delete \"\(modelToDelete?.label ?? "")\"?",
            isPresented: Binding(
                get: { modelToDelete != nil },
                set: { if !$0 { modelToDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                modelToDelete = nil
            }
            Button("Delete", role: .destructive) {
                guard let option = modelToDelete else { return }
                deleteModel(option)
                modelToDelete = nil
            }
        } message: {
            Text("The downloaded model files will be removed from this Mac. You can download the model again later.")
        }
        .alert(
            "Delete \"\(MeetingLiveCaptionModelStore.label)\"?",
            isPresented: $showDeleteLiveCaptionModelConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteLiveCaptionModel()
            }
        } message: {
            Text("Live meetings will fall back to standard chunk-by-chunk captions until this model is downloaded again.")
        }
    }

    private var modelsCategorySelection: Binding<ModelsCategory> {
        Binding(
            get: { appState.selectedModelsCategory },
            set: { appState.selectedModelsCategory = $0 }
        )
    }

    @ViewBuilder
    private var selectedCategoryContent: some View {
        switch appState.selectedModelsCategory {
        case .transcription:
            ForEach(BackendOption.systemManaged, id: \.model) { option in
                modelCard(
                    option: option,
                    logo: logoForBackend(option),
                    downloadedLabel: "Available"
                )
                .id(option.model)
            }

            familyCard(
                title: "Parakeet Family",
                subtitle: "The most responsive choices for meeting transcription, with multilingual and English-only options.",
                defaultBadge: "Recommended: Unified",
                logo: "nvidia-logo",
                selection: $selectedParakeetModel,
                options: BackendOption.parakeetFamily
            )


            familyCard(
                title: "Whisper",
                subtitle: "Dependable alternatives when you prefer Whisper's transcription style or need broader multilingual coverage.",
                defaultBadge: "Default: Small",
                logo: "openai-logo",
                selection: $selectedWhisperModel,
                options: BackendOption.whisperFamily
            )

            modelCard(option: .cohereTranscribe, logo: "cohere-logo")
            bodhanCard(selection: $selectedBodhanCoreModel, isCore: true)
            bodhanCard(selection: $selectedBodhanFlexModel, isCore: false)
            experimentalSection
            comingSoonSection
        case .streaming:
            streamingSection
        }
    }

    @ViewBuilder
    private var comingSoonSection: some View {
        if !BackendOption.comingSoon.isEmpty {
            VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
                Text("COMING SOON")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MeetsTheme.textTertiary)
                    .textCase(.uppercase)
                    .padding(.leading, 2)
                    .padding(.top, MeetsTheme.spacing8)

                VStack(spacing: MeetsTheme.spacing12) {
                    ForEach(BackendOption.comingSoon, id: \.model) { option in
                        comingSoonCard(option: option)
                    }
                }
            }
        }
    }


    private var streamingSection: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing12) {
            VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
                Text("LIVE MEETINGS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MeetsTheme.textTertiary)

                Text("Choose how words appear while a meeting is in progress. Apple Speech and Nemotron also create the saved transcript; Parakeet provides a provisional preview.")
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textSecondary)
            }
            .padding(.leading, 2)
            .padding(.top, MeetsTheme.spacing8)


            if BackendOption.systemManaged.contains(.appleSpeechAnalyzer) {
                let option = BackendOption.appleSpeechAnalyzer
                modelCard(
                    option: option,
                    logo: logoForBackend(option),
                    isActive: appState.config.enableLiveStreamingPartials
                        && appState.config.resolvedMeetingLiveCaptionBackend == .appleSpeech,
                    onSetActive: {
                        controller.updateConfig {
                            $0.meetingLiveCaptionBackend = MeetingLiveCaptionBackend.appleSpeech.rawValue
                            $0.enableLiveStreamingPartials = true
                        }
                    },
                    description: "Apple's private, on-device streaming transcription on macOS 26. Finalized speech becomes your saved transcript; your regular meeting model recovers any audio the live stream could not finish.",
                    downloadedLabel: "Available"
                )
            }

            ForEach(BackendOption.streaming, id: \.model) { option in
                if let liveCaptionBackend = MeetingLiveCaptionBackend(rawValue: option.backend) {
                    modelCard(
                        option: option,
                        logo: logoForBackend(option),
                        isActive: appState.config.enableLiveStreamingPartials
                            && appState.config.resolvedMeetingLiveCaptionBackend == liveCaptionBackend,
                        onSetActive: {
                            controller.updateConfig {
                                $0.meetingLiveCaptionBackend = liveCaptionBackend.rawValue
                                $0.enableLiveStreamingPartials = true
                            }
                        }
                    )
                }
            }

            liveCaptionModelCard
        }
    }

    private var liveCaptionModelCard: some View {
        let isActive = isLiveCaptionModelDownloaded
            && appState.config.enableLiveStreamingPartials
            && appState.config.resolvedMeetingLiveCaptionBackend == .parakeetRealtimeEOU

        return VStack(alignment: .leading, spacing: MeetsTheme.spacing12) {
            HStack(alignment: .top, spacing: MeetsTheme.spacing12) {
                brandLogo("nvidia-logo")
                VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
                    HStack(spacing: MeetsTheme.spacing8) {
                        Text(MeetingLiveCaptionModelStore.label)
                            .font(MeetsTheme.headline())
                            .foregroundStyle(MeetsTheme.textPrimary)

                        Text(MeetingLiveCaptionModelStore.sizeLabel)
                            .font(MeetsTheme.caption())
                            .foregroundStyle(MeetsTheme.textTertiary)
                    }

                    Text("Fast English captions while a meeting is in progress. They are a provisional preview; your regular meeting model creates the transcript you keep.")
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.textSecondary)
                }

                Spacer()

                if isActive {
                    Text("Active")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MeetsTheme.success)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MeetsTheme.success.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if isLiveCaptionModelDownloaded {
                    Text("Ready")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MeetsTheme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MeetsTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            if isDownloadingLiveCaptionModel {
                downloadProgressView(
                    for: MeetingLiveCaptionModelStore.modelID,
                    fallbackProgress: liveCaptionDownloadProgress
                )
            }

            HStack(spacing: MeetsTheme.spacing8) {
                if isDownloadingLiveCaptionModel {
                    Button(isCancellingLiveCaptionModelDownload ? "Pausing…" : "Cancel") {
                        guard !isCancellingLiveCaptionModelDownload else { return }
                        let task = liveCaptionDownloadTask
                        task?.cancel()
                        let cancellationGeneration = liveCaptionDownloadGeneration.begin()
                        isCancellingLiveCaptionModelDownload = true
                        Task {
                            let shouldCancel = await MainActor.run {
                                liveCaptionDownloadGeneration.contains(cancellationGeneration)
                            }
                            guard shouldCancel else { return }
                            await ManagedASRModelDownloader.cancelAndWait(
                                modelID: MeetingLiveCaptionModelStore.modelID
                            )
                            _ = await task?.value
                            await MainActor.run {
                                guard liveCaptionDownloadGeneration.clear(cancellationGeneration) else { return }
                                liveCaptionDownloadTask = nil
                                isDownloadingLiveCaptionModel = false
                                isCancellingLiveCaptionModelDownload = false
                                liveCaptionDownloadProgress = 0
                            }
                        }
                        liveCaptionDownloadProgress = 0
                        if let snapshot = downloadSnapshots[MeetingLiveCaptionModelStore.modelID] {
                            downloadSnapshots[MeetingLiveCaptionModelStore.modelID] = snapshot.replacing(
                                phase: .paused,
                                message: "Paused — select Download to resume"
                            )
                        }
                    }
                    .disabled(isCancellingLiveCaptionModelDownload)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MeetsTheme.textSecondary)
                } else if isLiveCaptionModelDownloaded {
                    if !isActive {
                        Button("Set Active") {
                            controller.updateConfig {
                                $0.meetingLiveCaptionBackend = MeetingLiveCaptionBackend.parakeetRealtimeEOU.rawValue
                                $0.enableLiveStreamingPartials = true
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MeetsTheme.accent)
                        .padding(.horizontal, MeetsTheme.spacing12)
                        .padding(.vertical, 4)
                        .background(MeetsTheme.accentSubtle)
                        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                    }

                    Button {
                        showDeleteLiveCaptionModelConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.red.opacity(0.6))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Delete live caption model")
                } else {
                    Button("Download") {
                        startLiveCaptionModelDownload()
                    }
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
        .padding(MeetsTheme.spacing16)
        .background(MeetsTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium)
                .strokeBorder(isActive ? MeetsTheme.accent.opacity(0.6) : MeetsTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func startLiveCaptionModelDownload() {
        guard !isDownloadingLiveCaptionModel else { return }
        isCancellingLiveCaptionModelDownload = false
        isDownloadingLiveCaptionModel = true
        liveCaptionDownloadProgress = 0
        downloadSnapshots.removeValue(forKey: MeetingLiveCaptionModelStore.modelID)
        let generation = liveCaptionDownloadGeneration.begin()
        liveCaptionDownloadTask = Task {
            do {
                try await MeetingLiveCaptionModelStore.download { progress in
                    Task { @MainActor in
                        guard liveCaptionDownloadGeneration.contains(generation) else { return }
                        liveCaptionDownloadProgress = progress
                    }
                } progressSnapshot: { snapshot in
                    Task { @MainActor in
                        guard liveCaptionDownloadGeneration.contains(generation) else { return }
                        downloadSnapshots[MeetingLiveCaptionModelStore.modelID] = snapshot
                        if let fraction = snapshot.fractionCompleted {
                            liveCaptionDownloadProgress = fraction
                        }
                    }
                }
                guard !Task.isCancelled,
                      liveCaptionDownloadGeneration.contains(generation)
                else { return }
                isLiveCaptionModelDownloaded = true
            } catch is CancellationError {
                // Cancellation is an expected user action.
            } catch {
                fputs("[meets] live caption model download failed: \(error)\n", stderr)
            }
            guard liveCaptionDownloadGeneration.clear(generation) else { return }
            isDownloadingLiveCaptionModel = false
            isCancellingLiveCaptionModelDownload = false
            liveCaptionDownloadProgress = 0
            liveCaptionDownloadTask = nil
            if isLiveCaptionModelDownloaded {
                downloadSnapshots.removeValue(forKey: MeetingLiveCaptionModelStore.modelID)
            }
        }
    }

    private func deleteLiveCaptionModel() {
        do {
            try MeetingLiveCaptionModelStore.delete()
            isLiveCaptionModelDownloaded = false
            if appState.config.resolvedMeetingLiveCaptionBackend == .parakeetRealtimeEOU {
                controller.updateConfig { $0.enableLiveStreamingPartials = false }
            }
        } catch {
            fputs("[meets] live caption model delete failed: \(error)\n", stderr)
        }
    }

    private var experimentalSection: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing12) {
            Button {
                showExperimental.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: MeetsTheme.spacing12) {
                    VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
                        HStack(spacing: 6) {
                            Image(systemName: showExperimental ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(MeetsTheme.textTertiary)

                            Text("Experimental")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(MeetsTheme.textSecondary)
                        }

                        Text("Early models for specific languages and evaluation. Expect less consistent transcripts, and try them with your own voice before relying on them.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MeetsTheme.textPrimary)
                            .opacity(0.8)
                    }

                    Spacer()

                    Text("Early access")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MeetsTheme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(MeetsTheme.surfacePrimary)
                        .clipShape(Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showExperimental {
                VStack(spacing: MeetsTheme.spacing12) {
                    ForEach(BackendOption.experimental, id: \.model) { option in
                        modelCard(option: option, logo: logoForBackend(option))
                    }
                }
            }
        }
        .padding(MeetsTheme.spacing16)
        .background(MeetsTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium)
                .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private var cohereLanguageSelection: Binding<CohereTranscribeLanguage> {
        Binding(
            get: { appState.config.resolvedCohereLanguage },
            set: { controller.selectCohereLanguage($0) }
        )
    }

    @ViewBuilder
    private func bodhanCard(selection: Binding<String>, isCore: Bool) -> some View {
        let variants = BackendOption.bodhanFamily.filter { BodhanModel(rawValue: $0.model)?.isCore == isCore }
        if let selected = variants.first(where: { $0.model == selection.wrappedValue }) ?? variants.first {
            modelCard(option: selected, logo: "bodhan-logo",
                         title: isCore ? "Bodhan Core" : "Bodhan Flex",
                         precisionSelection: selection)
        }
    }

    private func bodhanLanguageSelection(for model: String) -> Binding<BodhanLanguage> {
        Binding(
            get: { appState.config.resolvedBodhanLanguage.supported(for: model) },
            set: { controller.selectBodhanLanguage($0) }
        )
    }

    private var nemotron35LanguageSelection: Binding<Nemotron35Language> {
        Binding(
            get: { appState.config.resolvedNemotron35Language },
            set: { language in
                Task { await controller.setNemotron35Language(language) }
            }
        )
    }

    private var whisperLanguageSelection: Binding<WhisperKitLanguage> {
        Binding(
            get: { appState.config.resolvedWhisperLanguage },
            set: { controller.selectWhisperLanguage($0) }
        )
    }

    private var parakeetLanguageSelection: Binding<ParakeetLanguage> {
        Binding(
            get: { appState.config.resolvedParakeetLanguage },
            set: { controller.selectParakeetLanguage($0) }
        )
    }

    private var qwen3AsrLanguageSelection: Binding<Qwen3AsrLanguage> {
        Binding(
            get: { appState.config.resolvedQwen3AsrLanguage },
            set: { controller.selectQwen3AsrLanguage($0) }
        )
    }

    private var appleSpeechLanguageSelection: Binding<String> {
        Binding(
            get: { appState.config.resolvedAppleSpeechLanguage },
            set: { controller.selectAppleSpeechLanguage($0) }
        )
    }


    private func familyCard(
        title: String,
        subtitle: String,
        defaultBadge: String,
        logo: String? = nil,
        selection: Binding<String>,
        options: [BackendOption]
    ) -> some View {
        let selectedOption = options.first(where: { $0.model == selection.wrappedValue }) ?? options[0]
        let isActive = appState.selectedBackend == selectedOption
        let isDownloaded = downloadedModels.contains(selectedOption.model)
        let isDownloading = downloadingModels.contains(selectedOption.model)
        let progress = downloadProgress[selectedOption.model] ?? 0
        let showsDownloadStatus = shouldShowDownloadStatus(for: selectedOption.model, isDownloading: isDownloading)
        let incompatibilityReason = selectedOption.incompatibilityReason()

        return VStack(alignment: .leading, spacing: MeetsTheme.spacing12) {
            HStack(alignment: .top, spacing: MeetsTheme.spacing12) {
                brandLogo(logo)
                VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
                    HStack(spacing: MeetsTheme.spacing8) {
                        Text(title)
                            .font(MeetsTheme.headline())
                            .foregroundStyle(MeetsTheme.textPrimary)

                        Text(defaultBadge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MeetsTheme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(MeetsTheme.accentSubtle)
                            .clipShape(Capsule())
                    }

                    Text(subtitle)
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.textSecondary)
                }

                Spacer()

                familyStatusBadge(isActive: isActive, isDownloaded: isDownloaded)
            }

            HStack(alignment: .center, spacing: MeetsTheme.spacing12) {
                Text("Variant")
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textTertiary)
                    .frame(width: 52, alignment: .leading)

                Picker("", selection: selection) {
                    ForEach(options, id: \.model) { option in
                        Text(option.label).tag(option.model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220, alignment: .leading)
                .disabled(incompatibilityReason != nil)

                Text(selectedOption.sizeLabel)
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textTertiary)
            }

            Text(selectedOption.description)
                .font(MeetsTheme.caption())
                .foregroundStyle(incompatibilityReason == nil ? MeetsTheme.textSecondary : MeetsTheme.textTertiary)

            if selectedOption.supportsWhisperLanguageSelection {
                HStack(alignment: .center, spacing: MeetsTheme.spacing12) {
                    Text("Language")
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.textTertiary)
                        .frame(width: 64, alignment: .leading)

                    Picker("", selection: whisperLanguageSelection) {
                        ForEach(WhisperKitLanguage.allCases, id: \.self) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                    .disabled(incompatibilityReason != nil)
                }
            }

            if selectedOption.backend == BackendOption.parakeetMultilingual.backend {
                HStack(alignment: .center, spacing: MeetsTheme.spacing12) {
                    Text("Language")
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.textTertiary)
                        .frame(width: 64, alignment: .leading)

                    Picker("", selection: parakeetLanguageSelection) {
                        ForEach(ParakeetLanguage.allCases, id: \.self) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                    .disabled(incompatibilityReason != nil)
                }

                Text("Script filter: keeps the chosen language's writing script in the transcript. Parakeet v3 only — v2 ignores this setting.")
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textTertiary)
            }

            if showsDownloadStatus, incompatibilityReason == nil {
                downloadProgressView(
                    for: selectedOption.model,
                    fallbackProgress: progress,
                    fallbackMessage: downloadMessages[selectedOption.model],
                    isDownloading: isDownloading
                )
            }

            if let incompatibilityReason {
                Label(incompatibilityReason, systemImage: "exclamationmark.triangle")
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textTertiary)
            }

            actionButtons(
                for: selectedOption,
                isActive: isActive,
                isDownloaded: isDownloaded,
                isDownloading: isDownloading,
                incompatibilityReason: incompatibilityReason
            )
        }
        .padding(MeetsTheme.spacing16)
        .background(MeetsTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium)
                .strokeBorder(isActive ? MeetsTheme.accent.opacity(0.5) : MeetsTheme.surfaceBorder, lineWidth: isActive ? 1.5 : 1)
        )
    }

    @ViewBuilder
    private func familyStatusBadge(isActive: Bool, isDownloaded: Bool) -> some View {
        if isActive {
            Text("Active")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MeetsTheme.success)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(MeetsTheme.success.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if isDownloaded {
            Text("Downloaded")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MeetsTheme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(MeetsTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    @ViewBuilder
    private func downloadProgressView(
        for modelID: String,
        fallbackProgress: Double,
        fallbackMessage: String? = nil,
        isDownloading: Bool = true
    ) -> some View {
        if let snapshot = downloadSnapshots[modelID] {
            VStack(alignment: .leading, spacing: 4) {
                if snapshot.phase != .preparing {
                    ProgressView(value: snapshot.fractionCompleted ?? fallbackProgress)
                        .tint(MeetsTheme.accent)
                }

                if let currentFile = snapshot.currentFile?.split(separator: "/").last.map(String.init), !currentFile.isEmpty {
                    Text("\(downloadPhaseLabel(snapshot.phase)): \(currentFile)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MeetsTheme.textSecondary)
                } else {
                    Text(snapshot.message ?? downloadPhaseLabel(snapshot.phase))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MeetsTheme.textSecondary)
                }

                if let detail = downloadDetailText(snapshot), !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(MeetsTheme.textTertiary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                // Only show a moving bar while a download is actually in flight — a failure with
                // no snapshot (e.g. an instant OS-compatibility rejection) can leave a stale
                // message behind with nothing in progress to animate.
                if isDownloading {
                    ProgressView(value: fallbackProgress)
                        .tint(MeetsTheme.accent)
                }
                Text(fallbackMessage ?? "\(Int(fallbackProgress * 100))% downloading...")
                    .font(.system(size: 11))
                    .foregroundStyle(MeetsTheme.textTertiary)
            }
        }
    }

    private func downloadPhaseLabel(_ phase: ModelDownloadPhase) -> String {
        switch phase {
        case .downloading: return "Downloading"
        case .preparing: return "Preparing"
        case .ready: return "Ready"
        case .paused: return "Download paused"
        case .failed: return "Failed"
        }
    }

    private func downloadDetailText(_ snapshot: ModelDownloadProgress) -> String? {
        var details: [String] = []
        if snapshot.totalFileCount > 0 {
            let completed = min(max(snapshot.completedFileCount, 0), snapshot.totalFileCount)
            let remaining = snapshot.totalFileCount - completed
            details.append("\(completed) of \(snapshot.totalFileCount) \(downloadFileNoun(snapshot.totalFileCount))")
            if remaining > 0 {
                details.append("\(remaining) \(downloadFileNoun(remaining)) left")
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
                details.append("\(ModelDownloadDisplayFormatting.bytes(currentTotal - snapshot.currentFileCompletedBytes)) left in file")
            }
        }
        if snapshot.phase == .downloading {
            if snapshot.bytesPerSecond > 0 {
                details.append("\(ModelDownloadDisplayFormatting.rate(snapshot.bytesPerSecond))")
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
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    private func downloadFileNoun(_ count: Int) -> String {
        count == 1 ? "file" : "files"
    }

    private func shouldShowDownloadStatus(for modelID: String, isDownloading: Bool) -> Bool {
        guard let phase = downloadSnapshots[modelID]?.phase else {
            return isDownloading || downloadMessages[modelID] != nil
        }
        return isDownloading || phase == .paused || phase == .failed
    }

    @ViewBuilder
    private func brandLogo(_ name: String?) -> some View {
        if name == "apple-system-logo" {
            Image(systemName: "apple.logo")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(MeetsTheme.textPrimary)
                .frame(width: 24, height: 24)
                .padding(.top, 2)
        } else if let name,
           let url = Bundle.main.url(forResource: name, withExtension: "png")
                ?? Bundle.main.url(forResource: name, withExtension: "svg"),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(.top, 2)
        }
    }

    private func logoForBackend(_ option: BackendOption) -> String? {
        switch option.backend {
        case "fluidaudio": return "nvidia-logo"
        case "parakeet-unified": return "nvidia-logo"
        case "whisper": return "openai-logo"
        case "cohere": return "cohere-logo"
        case "qwen": return "qwen-logo"
        case "nemotron35": return "nvidia-logo"
        case "bodhan": return "bodhan-logo"
        case "sensevoice": return "qwen-logo"
        case "gemma4-litert": return "google-logo"
        case "apple-speech": return "apple-system-logo"
        default: return nil
        }
    }

    @ViewBuilder
    private func actionButtons(
        for option: BackendOption,
        isActive: Bool,
        isDownloaded: Bool,
        isDownloading: Bool,
        actionTitle: String = "Set Active",
        activationDisabledReason: String? = nil,
        incompatibilityReason: String? = nil,
        onSetActive: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: MeetsTheme.spacing8) {
            if isDownloading {
                Button("Pause") {
                    cancelDownload(option)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MeetsTheme.textSecondary)
                .padding(.horizontal, MeetsTheme.spacing12)
                .padding(.vertical, 4)
                .background(MeetsTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
            } else if isDownloaded {
                if !isActive {
                    let disabledReason = incompatibilityReason ?? activationDisabledReason
                    Button(actionTitle) {
                        if let onSetActive {
                            onSetActive()
                        } else {
                            controller.selectBackend(option)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(disabledReason == nil ? MeetsTheme.accent : MeetsTheme.textTertiary)
                    .padding(.horizontal, MeetsTheme.spacing12)
                    .padding(.vertical, 4)
                    .background(disabledReason == nil ? MeetsTheme.accentSubtle : MeetsTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                    .disabled(disabledReason != nil)
                    .help(disabledReason ?? actionTitle)
                }

                if !option.isSystemManaged {
                    Button {
                        modelToDelete = option
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.red.opacity(0.6))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button("Download") {
                    startDownload(option)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(incompatibilityReason == nil ? MeetsTheme.accent : MeetsTheme.textTertiary)
                .padding(.horizontal, MeetsTheme.spacing12)
                .padding(.vertical, 4)
                .background(incompatibilityReason == nil ? MeetsTheme.accentSubtle : MeetsTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                .disabled(incompatibilityReason != nil)
                .help(incompatibilityReason ?? "Download")
            }
        }
    }

    private func modelCard(
        option: BackendOption,
        logo: String? = nil,
        title: String? = nil,
        precisionSelection: Binding<String>? = nil,
        isActive activeOverride: Bool? = nil,
        onSetActive: (() -> Void)? = nil,
        description: String? = nil,
        activeLabel: String = "Active",
        downloadedLabel: String = "Downloaded",
        actionTitle: String = "Set Active",
        activationDisabledReason: String? = nil
    ) -> some View {
        let isActive = activeOverride ?? (appState.selectedBackend == option)
        let isDownloaded = downloadedModels.contains(option.model)
        let isDownloading = downloadingModels.contains(option.model)
        let progress = downloadProgress[option.model] ?? 0
        let showsDownloadStatus = shouldShowDownloadStatus(for: option.model, isDownloading: isDownloading)
        let incompatibilityReason = option.incompatibilityReason()

        return VStack(alignment: .leading, spacing: MeetsTheme.spacing12) {
            HStack(alignment: .top, spacing: MeetsTheme.spacing12) {
                brandLogo(logo)
                VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
                    HStack(spacing: MeetsTheme.spacing8) {
                        Text(title ?? option.label)
                            .font(MeetsTheme.headline())
                            .foregroundStyle(incompatibilityReason == nil ? MeetsTheme.textPrimary : MeetsTheme.textTertiary)

                        if option.recommended {
                            Text("Recommended")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(MeetsTheme.accentContent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(MeetsTheme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        Text(option.sizeLabel)
                            .font(MeetsTheme.caption())
                            .foregroundStyle(MeetsTheme.textTertiary)
                    }

                    Text(description ?? option.description)
                        .font(MeetsTheme.caption())
                        .foregroundStyle(incompatibilityReason == nil ? MeetsTheme.textSecondary : MeetsTheme.textTertiary)
                }

                Spacer()

                // Status badge — Incompatible takes priority over Active/Downloaded.
                if let incompatibilityReason {
                    Text("Incompatible")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MeetsTheme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MeetsTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .help(incompatibilityReason)
                } else if isActive {
                    Text(activeLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MeetsTheme.success)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MeetsTheme.success.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if isDownloaded {
                    Text(downloadedLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MeetsTheme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MeetsTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            if option.backend == BackendOption.cohereTranscribe.backend {
                HStack(alignment: .center, spacing: MeetsTheme.spacing12) {
                    Text("Language")
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.textTertiary)
                        .frame(width: 64, alignment: .leading)

                    Picker("", selection: cohereLanguageSelection) {
                        ForEach(CohereTranscribeLanguage.allCases, id: \.self) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                    .disabled(incompatibilityReason != nil)
                }
            }

            if option.backend == BackendOption.bodhanFlex.backend {
                HStack(alignment: .center, spacing: MeetsTheme.spacing12) {
                    Text("Language")
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.textTertiary)
                        .frame(width: 64, alignment: .leading)

                    Picker("", selection: bodhanLanguageSelection(for: option.model)) {
                        ForEach(BodhanLanguage.choices(for: option.model), id: \.self) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                    .disabled(incompatibilityReason != nil)

                    if let precisionSelection {
                        Text("Precision")
                            .font(MeetsTheme.caption())
                            .foregroundStyle(MeetsTheme.textTertiary)
                        Picker("Precision", selection: precisionSelection) {
                            ForEach(BackendOption.bodhanFamily.filter {
                                BodhanModel(rawValue: $0.model)?.isCore == BodhanModel(rawValue: option.model)?.isCore
                            }, id: \.model) { variant in
                                Text(BodhanModel(rawValue: variant.model)?.isInt8 == true ? "INT8" : "FP16")
                                    .tag(variant.model)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 100)
                        .disabled(isDownloading || incompatibilityReason != nil)
                    }
                }
            }

            if option.backend == BackendOption.qwen3Asr.backend {
                HStack(alignment: .center, spacing: MeetsTheme.spacing12) {
                    Text("Language")
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.textTertiary)
                        .frame(width: 64, alignment: .leading)

                    Picker("", selection: qwen3AsrLanguageSelection) {
                        ForEach(Qwen3AsrLanguage.allCases, id: \.self) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                    .disabled(incompatibilityReason != nil)
                }
            }

            if option.backend == BackendOption.appleSpeechAnalyzer.backend {
                HStack(alignment: .center, spacing: MeetsTheme.spacing12) {
                    Text("Language")
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.textTertiary)
                        .frame(width: 64, alignment: .leading)

                    Picker("", selection: appleSpeechLanguageSelection) {
                        ForEach(appleSpeechLanguageOptions) { language in
                            Text(language.label).tag(language.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                    .disabled(incompatibilityReason != nil)
                }
            }

            if option.supportsWhisperLanguageSelection {
                HStack(alignment: .center, spacing: MeetsTheme.spacing12) {
                    Text("Language")
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.textTertiary)
                        .frame(width: 64, alignment: .leading)

                    Picker("", selection: whisperLanguageSelection) {
                        ForEach(WhisperKitLanguage.allCases, id: \.self) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                }
            }

            if option.backend == BackendOption.nemotron35Multilingual.backend {
                HStack(alignment: .center, spacing: MeetsTheme.spacing12) {
                    Text("Language")
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.textTertiary)
                        .frame(width: 64, alignment: .leading)

                    Picker("", selection: nemotron35LanguageSelection) {
                        ForEach(Nemotron35Language.allCases, id: \.self) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                    .disabled(incompatibilityReason != nil)
                }

                if isDownloaded && nemotron35UpdateAvailable && !isDownloading {
                    HStack(spacing: MeetsTheme.spacing8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                            .foregroundStyle(MeetsTheme.accent)
                        Text("A newer model build is available.")
                            .font(MeetsTheme.caption())
                            .foregroundStyle(MeetsTheme.textSecondary)
                        Button("Update") { updateNemotron35(option) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(incompatibilityReason == nil ? MeetsTheme.accent : MeetsTheme.textTertiary)
                            .disabled(incompatibilityReason != nil)
                            .help(incompatibilityReason ?? "Update")
                    }
                }
            }

            // Progress bar when downloading.
            if showsDownloadStatus, incompatibilityReason == nil {
                downloadProgressView(
                    for: option.model,
                    fallbackProgress: progress,
                    fallbackMessage: downloadMessages[option.model],
                    isDownloading: isDownloading
                )
            }

            if let incompatibilityReason {
                Label(incompatibilityReason, systemImage: "exclamationmark.triangle")
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textTertiary)
            } else if let activationDisabledReason, isDownloaded, !isActive {
                Label(activationDisabledReason, systemImage: "exclamationmark.lock")
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textTertiary)
            }

            actionButtons(
                for: option,
                isActive: isActive,
                isDownloaded: isDownloaded,
                isDownloading: isDownloading,
                actionTitle: actionTitle,
                activationDisabledReason: activationDisabledReason,
                incompatibilityReason: incompatibilityReason,
                onSetActive: onSetActive
            )
        }
        .padding(MeetsTheme.spacing16)
        .background(MeetsTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium)
                .strokeBorder(isActive ? MeetsTheme.accent.opacity(0.5) : MeetsTheme.surfaceBorder, lineWidth: isActive ? 1.5 : 1)
        )
    }

    private func comingSoonCard(option: BackendOption) -> some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
                    HStack(spacing: MeetsTheme.spacing8) {
                        Text(option.label)
                            .font(MeetsTheme.headline())
                            .foregroundStyle(MeetsTheme.textTertiary)

                        Text("Coming soon")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MeetsTheme.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(MeetsTheme.surfacePrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        Text(option.sizeLabel)
                            .font(MeetsTheme.caption())
                            .foregroundStyle(MeetsTheme.textTertiary.opacity(0.6))
                    }

                    Text(option.description)
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.textTertiary.opacity(0.7))
                }
                Spacer()
            }
        }
        .padding(MeetsTheme.spacing16)
        .background(MeetsTheme.backgroundRaised.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium)
                .strokeBorder(MeetsTheme.surfaceBorder.opacity(0.5), lineWidth: 1)
        )
        .opacity(0.6)
    }


    // MARK: - Actions

    private func startDownload(_ option: BackendOption) {
        guard option.isCompatible() else { return }
        withAnimation { _ = downloadingModels.insert(option.model) }
        downloadProgress[option.model] = 0.05  // Show initial progress immediately
        downloadMessages.removeValue(forKey: option.model)
        downloadSnapshots.removeValue(forKey: option.model)
        let generation = UUID()
        downloadGenerations[option.model] = generation

        let startTime = Date()
        let task = Task {
            do {
                try await controller.transcriptionCoordinator.preloadRequired(
                    backend: option,
                    includeMeetingHelpers: false,
                    meetingHelperTrigger: .modelLibrary,
                    appleSpeechLanguage: appState.config.resolvedAppleSpeechLanguage
                ) { progress, message in
                    DispatchQueue.main.async {
                        guard downloadGenerations[option.model] == generation else { return }
                        downloadProgress[option.model] = max(progress, 0.05)
                        if let message { downloadMessages[option.model] = message }
                    }
                } progressSnapshot: { snapshot in
                    DispatchQueue.main.async {
                        guard downloadGenerations[option.model] == generation else { return }
                        downloadSnapshots[option.model] = snapshot
                        if let fraction = snapshot.fractionCompleted {
                            downloadProgress[option.model] = max(fraction, 0.05)
                        }
                    }
                }
                guard !Task.isCancelled else {
                    await MainActor.run {
                        guard downloadGenerations[option.model] == generation else { return }
                        withAnimation {
                            downloadingModels.remove(option.model)
                            downloadProgress.removeValue(forKey: option.model)
                            downloadMessages[option.model] = "Paused — select Download to resume"
                            if let snapshot = downloadSnapshots[option.model] {
                                downloadSnapshots[option.model] = snapshot.replacing(
                                    phase: .paused,
                                    message: "Paused — select Download to resume"
                                )
                            }
                            downloadGenerations.removeValue(forKey: option.model)
                            downloadTasks.removeValue(forKey: option.model)
                        }
                    }
                    return
                }
                guard isModelDownloaded(option, fm: FileManager.default) else {
                    throw NSError(
                        domain: "MeetsModelDownload",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "\(option.label) was not downloaded successfully."]
                    )
                }
                guard !Task.isCancelled else {
                    await MainActor.run {
                        guard downloadGenerations[option.model] == generation else { return }
                        withAnimation {
                            downloadingModels.remove(option.model)
                            downloadProgress.removeValue(forKey: option.model)
                            downloadMessages[option.model] = "Paused — select Download to resume"
                            if let snapshot = downloadSnapshots[option.model] {
                                downloadSnapshots[option.model] = snapshot.replacing(
                                    phase: .paused,
                                    message: "Paused — select Download to resume"
                                )
                            }
                            downloadGenerations.removeValue(forKey: option.model)
                            downloadTasks.removeValue(forKey: option.model)
                        }
                    }
                    return
                }
                // Ensure the downloading state is visible for at least 1.5s
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed < 1.5 {
                    try? await Task.sleep(nanoseconds: UInt64((1.5 - elapsed) * 1_000_000_000))
                }
                await MainActor.run {
                    guard downloadGenerations[option.model] == generation, !Task.isCancelled else { return }
                    withAnimation {
                        downloadingModels.remove(option.model)
                        downloadedModels.insert(option.model)
                        downloadProgress.removeValue(forKey: option.model)
                        downloadMessages.removeValue(forKey: option.model)
                        downloadSnapshots.removeValue(forKey: option.model)
                        downloadGenerations.removeValue(forKey: option.model)
                        downloadTasks.removeValue(forKey: option.model)
                    }
                }
            } catch {
                let isCancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                await MainActor.run {
                    withAnimation {
                        guard downloadGenerations[option.model] == generation else { return }
                        downloadingModels.remove(option.model)
                        downloadProgress.removeValue(forKey: option.model)
                        if isCancelled {
                            if let snapshot = downloadSnapshots[option.model] {
                                downloadSnapshots[option.model] = snapshot.replacing(
                                    phase: .paused,
                                    message: "Paused — select Download to resume"
                                )
                            }
                        } else {
                            downloadMessages[option.model] = error.localizedDescription
                            if let snapshot = downloadSnapshots[option.model] {
                                downloadSnapshots[option.model] = snapshot.replacing(
                                    phase: .failed,
                                    message: error.localizedDescription
                                )
                            }
                        }
                        downloadGenerations.removeValue(forKey: option.model)
                        downloadTasks.removeValue(forKey: option.model)
                    }
                }
                if !isCancelled {
                    fputs("[meets] model download failed for \(option.backend)/\(option.model): \(error)\n", stderr)
                }
            }
        }
        downloadTasks[option.model] = task
    }

    private func loadAppleSpeechLanguageOptions() {
        guard #available(macOS 26.0, *), AppleSpeechAnalyzerTranscriber.isSupportedOnCurrentSystem else {
            appleSpeechLanguageOptions = [.system]
            return
        }

        Task {
            var options = await AppleSpeechLanguageOption.supportedOptions()
            let selectedIdentifier = appState.config.resolvedAppleSpeechLanguage
            if selectedIdentifier != AppleSpeechLanguageOption.systemIdentifier,
               !options.contains(where: { $0.id == selectedIdentifier }) {
                options.append(.locale(Locale(identifier: selectedIdentifier)))
            }
            appleSpeechLanguageOptions = options
        }
    }

    private func cancelDownload(_ option: BackendOption) {
        let modelID = option.model
        let task = downloadTasks[modelID]
        let cancellationGeneration = UUID()
        task?.cancel()
        withAnimation {
            downloadingModels.remove(modelID)
            downloadProgress.removeValue(forKey: modelID)
            downloadMessages[modelID] = "Paused — select Download to resume"
            // Keep a cancellation generation until the caller task has fully
            // unwound. If a replacement starts first, this generation changes
            // and the old cancellation must not stop the replacement transfer.
            downloadGenerations[modelID] = cancellationGeneration
            downloadTasks.removeValue(forKey: modelID)
            if let snapshot = downloadSnapshots[modelID] {
                downloadSnapshots[modelID] = snapshot.replacing(
                    phase: .paused,
                    message: "Paused — select Download to resume"
                )
            }
        }
        Task {
            let shouldCancel = await MainActor.run {
                downloadGenerations[modelID] == cancellationGeneration
            }
            guard shouldCancel else { return }

            await ManagedASRModelDownloader.cancel(modelID: modelID)
            _ = await task?.value

            await MainActor.run {
                guard downloadGenerations[modelID] == cancellationGeneration else { return }
                downloadGenerations.removeValue(forKey: modelID)
            }
        }
    }

    /// Re-download Nemotron 3.5 to pick up a newer upstream build: delete the cached
    /// files (so the download isn't skipped), then start a fresh download.
    private func updateNemotron35(_ option: BackendOption) {
        // Check before unloading or deleting the installed model: startDownload also
        // rejects incompatible backends, so otherwise no replacement would be started.
        guard option.isCompatible() else { return }
        Task {
            do {
                await controller.transcriptionCoordinator.unloadNemotron35Transcriber()
                try await deleteModelFiles(option)
                await MainActor.run {
                    downloadedModels.remove(option.model)
                    nemotron35UpdateAvailable = false
                    startDownload(option)
                }
            } catch {
                fputs("[meets] model update cleanup failed for \(option.backend)/\(option.model): \(error)\n", stderr)
            }
        }
    }

    private func deleteModel(_ option: BackendOption) {
        if option == .nemotron35Multilingual,
           appState.config.resolvedMeetingLiveCaptionBackend == .nemotron35 {
            controller.updateConfig { $0.enableLiveStreamingPartials = false }
        }
        if appState.selectedBackend == option {
            let fallback = downloadedModels
                .compactMap { model in BackendOption.all.first(where: { $0.model == model && $0 != option }) }
                .first ?? (option == .parakeetUnified ? .parakeetMultilingual : .parakeetUnified)
            controller.selectBackend(fallback)
        }
        let task = downloadTasks[option.model]
        task?.cancel()
        let deletionGeneration = UUID()
        downloadGenerations[option.model] = deletionGeneration
        downloadTasks.removeValue(forKey: option.model)

        // Stop any transfer before removing files so a late write cannot recreate
        // part of the model after the deletion has completed.
        Task {
            let deletionToken = await ManagedASRModelDownloader.beginDeletion(
                modelID: option.model
            )
            do {
                _ = await task?.value
                let shouldDelete = await MainActor.run {
                    downloadGenerations[option.model] == deletionGeneration
                }
                guard shouldDelete else {
                    await ManagedASRModelDownloader.endDeletion(deletionToken)
                    return
                }
                try await deleteModelFiles(option)
                await MainActor.run {
                    _ = downloadedModels.remove(option.model)
                    if appState.selectedMeetingTranscriptionBackend == option {
                        controller.refreshMeetingTranscriptionSelectionForAvailability()
                    }
                    downloadSnapshots.removeValue(forKey: option.model)
                    downloadMessages.removeValue(forKey: option.model)
                    downloadGenerations.removeValue(forKey: option.model)
                }
            } catch {
                fputs("[meets] model delete failed for \(option.backend)/\(option.model): \(error)\n", stderr)
            }
            await ManagedASRModelDownloader.endDeletion(deletionToken)
        }
    }

    private func deleteModelFiles(_ option: BackendOption) async throws {
        let fm = FileManager.default
        switch option.backend {
        case "whisper":
            WhisperKitTranscriber.deleteModel(option.model)
        case "nemotron35":
            try removeItemIfPresent(at: Nemotron35ModelStore.cacheDirectory(fileManager: fm), fileManager: fm)
        case "cohere":
            try removeItemIfPresent(at: CohereTranscribeModelStore.cacheDirectory(), fileManager: fm)
        case "bodhan":
            if let model = BodhanModel(rawValue: option.model) {
                if model.localOverride == nil {
                    await controller.transcriptionCoordinator.unloadBodhanTranscriber(ifLoadedModelID: model.rawValue)
                    try removeItemIfPresent(at: model.cacheDirectory, fileManager: fm)
                }
            }
        case "sensevoice":
            SenseVoiceTranscriber.deleteModelFiles(fileManager: fm)
        case "gemma4-litert":
            await controller.transcriptionCoordinator.unloadGemma4LiteRTTranscriber()
            try Gemma4LiteRTModelStore.deleteModelFiles(
                model: Gemma4LiteRTModel.resolved(option.model),
                fileManager: fm
            )
        case "fluidaudio":
            let version: AsrModelVersion = option.model.contains("v2") ? .v2 : .v3
            await controller.transcriptionCoordinator.unloadFluidAudioTranscriber(
                ifLoadedVersion: version
            )
            let plan = version == .v2
                ? ManagedASRModelPlans.parakeetV2()
                : ManagedASRModelPlans.parakeetV3()
            try plan.delete(fileManager: fm)
        case "parakeet-unified":
            await controller.transcriptionCoordinator.unloadParakeetUnifiedTranscriber()
            try ManagedASRModelPlans.parakeetUnified().delete(fileManager: fm)
        case "qwen":
            await controller.transcriptionCoordinator.unloadQwen3Transcriber()
            try Qwen3AsrModelStore.deleteModelFiles(fileManager: fm)
        default:
            break
        }
    }

    private func removeItemIfPresent(at url: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    // MARK: - Check Downloaded Status

    private func checkDownloadedModels() {
        let fm = FileManager.default
        for option in BackendOption.all {
            if isModelDownloaded(option, fm: fm) {
                downloadedModels.insert(option.model)
            }
        }
    }

    /// Background check: does FluidInference's repo have a newer commit than what's
    /// installed for Nemotron 3.5? Never auto-downloads — just surfaces a badge.
    private func checkNemotron35Update() {
        guard #available(macOS 15, *),
              isModelDownloaded(.nemotron35Multilingual, fm: FileManager.default) else { return }
        Task {
            let available = await Nemotron35StreamingTranscriber.updateAvailable()
            await MainActor.run { nemotron35UpdateAvailable = available }
        }
    }

    private func syncSelectionsFromActiveBackend() {
        let active = appState.selectedBackend
        if BackendOption.parakeetFamily.contains(active) {
            selectedParakeetModel = active.model
        }
        if BackendOption.whisperFamily.contains(active) {
            selectedWhisperModel = active.model
        }
        if let model = BodhanModel(rawValue: active.model) {
            if model.isCore { selectedBodhanCoreModel = active.model }
            else { selectedBodhanFlexModel = active.model }
        }
        if BackendOption.experimental.contains(active) {
            showExperimental = true
        }
    }

    private func isModelDownloaded(_ option: BackendOption, fm: FileManager) -> Bool {
        switch option.backend {
        case "whisper":
            return WhisperKitTranscriber.isModelDownloaded(option.model)
        case "nemotron35":
            return Nemotron35ModelStore.isModelDownloaded(fileManager: fm)
        case "fluidaudio":
            let plan = option.model.contains("v2")
                ? ManagedASRModelPlans.parakeetV2()
                : ManagedASRModelPlans.parakeetV3()
            return plan.isAvailableLocally(fileManager: fm)
        case "parakeet-unified":
            return ManagedASRModelPlans.parakeetUnified().isAvailableLocally(fileManager: fm)
        case "qwen":
            return Qwen3AsrModelStore.isModelDownloaded(fileManager: fm)
        case "cohere":
            return CohereTranscribeModelStore.isAvailableLocally()
        case "bodhan":
            return BodhanModel(rawValue: option.model)?.isDownloaded ?? false
        case "sensevoice":
            return SenseVoiceTranscriber.isModelDownloaded(fileManager: fm)
        case "gemma4-litert":
            return Gemma4LiteRTModelStore.isAvailableLocally(
                model: Gemma4LiteRTModel.resolved(option.model),
                fileManager: fm
            )
        case "apple-speech":
            if #available(macOS 26.0, *) {
                return AppleSpeechAnalyzerTranscriber.isSupportedOnCurrentSystem
            }
            return false
        default:
            return false
        }
    }
}
