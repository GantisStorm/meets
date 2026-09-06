import FluidAudio
import Foundation
import MeetsCore

struct SpeechSegment: Sendable {
    let start: Double
    let end: Double
    let text: String
}

struct SpeechTranscriptionResult: Sendable {
    let text: String
    let segments: [SpeechSegment]
}

actor AppleSpeechUseLifecycle {
    typealias Cleanup = @Sendable () async -> Void

    struct Snapshot: Equatable, Sendable {
        let activeUseCount: Int
        let hasDeferredCleanup: Bool
        let isCleaningUp: Bool
    }

    private struct CleanupOperation {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var activeUseCount = 0
    private var deferredCleanup: Cleanup?
    private var cleanupOperation: CleanupOperation?

    func beginUse() async {
        deferredCleanup = nil
        activeUseCount += 1

        if let operation = cleanupOperation {
            await operation.task.value
            finishCleanupIfCurrent(operation.id)
        }
    }

    func endUse() async {
        precondition(activeUseCount > 0, "Apple Speech use ended without a matching begin")
        activeUseCount -= 1
        if activeUseCount == 0 {
            await runDeferredCleanupIfNeeded()
        }
    }

    func requestCleanup(_ cleanup: @escaping Cleanup) async {
        deferredCleanup = cleanup

        if let operation = cleanupOperation {
            await operation.task.value
            finishCleanupIfCurrent(operation.id)
            if activeUseCount == 0 {
                await runDeferredCleanupIfNeeded()
            }
            return
        }

        if activeUseCount == 0 {
            await runDeferredCleanupIfNeeded()
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            activeUseCount: activeUseCount,
            hasDeferredCleanup: deferredCleanup != nil,
            isCleaningUp: cleanupOperation != nil
        )
    }

    private func runDeferredCleanupIfNeeded() async {
        guard cleanupOperation == nil, let cleanup = deferredCleanup else { return }
        deferredCleanup = nil

        let id = UUID()
        let task = Task { await cleanup() }
        cleanupOperation = CleanupOperation(id: id, task: task)
        await task.value
        finishCleanupIfCurrent(id)
    }

    private func finishCleanupIfCurrent(_ id: UUID) {
        if cleanupOperation?.id == id {
            cleanupOperation = nil
        }
    }
}

actor TranscriptionCoordinator {
    typealias DiarizerModelLoader = @Sendable (DiarizerRuntimePolicy) async throws -> DiarizerModels
    typealias VADLoader = @Sendable () async throws -> VadManager

    private enum DiarizerLoadWaitOutcome {
        case succeeded
        case failed
        case cancelled
        case timedOut
    }

    private struct DiarizerLoadWaiter {
        let continuation: CheckedContinuation<DiarizerLoadWaitOutcome, Never>
        let timeoutTask: Task<Void, Never>
    }

    // Product flows stop waiting after two minutes and continue without optional
    // diarization. The shared background load gets a longer cooperative deadline.
    private static let defaultDiarizerLoadWaitTimeout: Duration = .seconds(120)
    private static let defaultDiarizerLoadOperationTimeout: Duration = .seconds(300)

    static let explicitlyRoutedBackendIdentifiers: Set<String> = [
        "whisper", "nemotron35", "parakeet-unified", "qwen", "cohere", "indicasr", "sensevoice", "gemma4-litert", "apple-speech",
    ]

    private let fluidTranscriber = FluidAudioTranscriber()
    private let parakeetUnifiedTranscriber = ParakeetUnifiedTranscriber()
    private let whisperTranscriber = WhisperKitTranscriber()
    private var _qwen3Transcriber: Any?
    private var _cohereTranscriber: Any?
    private var _indicASRTranscriber: Any?
    private var _gemma4LiteRTTranscriber: Any?
    private var _appleSpeechTranscriber: Any?
    private let appleSpeechLifecycle = AppleSpeechUseLifecycle()
    private let senseVoiceTranscriber = SenseVoiceTranscriber()
    private var vadManager: VadManager?
    private var diarizerManager: DiarizerManager?
    private var isDiarizerLoadInProgress = false
    private var activeDiarizerLoadID: UUID?
    private var diarizerLoadTask: Task<Void, Never>?
    private var diarizerLoadTimeoutTask: Task<Void, Never>?
    private var didDiarizerLoadTimeOut = false
    private var diarizerLoadWaiters: [UUID: DiarizerLoadWaiter] = [:]
    private let diarizerModelLoader: DiarizerModelLoader
    private let vadLoader: VADLoader
    private let diarizerLoadOperationTimeout: Duration
    private let diarizerDiagnostics: DiarizerPreloadDiagnostics

    init(
        diarizerModelLoader: @escaping DiarizerModelLoader = { policy in
            try await DiarizerModels.download(configuration: policy.modelConfiguration)
        },
        vadLoader: @escaping VADLoader = { try await VadManager() },
        diarizerLoadOperationTimeout: Duration = TranscriptionCoordinator.defaultDiarizerLoadOperationTimeout,
        diarizerDiagnostics: DiarizerPreloadDiagnostics = DiarizerPreloadDiagnostics()
    ) {
        self.diarizerModelLoader = diarizerModelLoader
        self.vadLoader = vadLoader
        self.diarizerLoadOperationTimeout = diarizerLoadOperationTimeout
        self.diarizerDiagnostics = diarizerDiagnostics
    }

    private var _nemotron35Transcriber: Any?
    /// Selected Nemotron 3.5 language prompt id (101 = auto). Stored so it survives
    /// lazy (re)creation of the transcriber and is applied whenever it loads.
    private var nemotron35PromptId: Int32 = 101

    @available(macOS 15, *)
    private var nemotron35Transcriber: Nemotron35StreamingTranscriber {
        if _nemotron35Transcriber == nil {
            _nemotron35Transcriber = Nemotron35StreamingTranscriber()
        }
        return _nemotron35Transcriber as! Nemotron35StreamingTranscriber
    }

    /// Loaded accessor for the live meeting caption path (Nemotron 3.5 unified
    /// live+final backend). Preload normally warms the model, but the live
    /// meeting flow must not reach the actor while its CoreML models are still
    /// unloaded.
    @available(macOS 15, *)
    func getLoadedNemotron35Transcriber(
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws -> Nemotron35StreamingTranscriber {
        let transcriber = nemotron35Transcriber
        await transcriber.setPromptId(nemotron35PromptId)
        try await transcriber.loadModels(progress: progress, progressSnapshot: progressSnapshot)
        return transcriber
    }

    /// Set the Nemotron 3.5 language prompt id (from app config). Applies to the
    /// live transcriber if it already exists.
    func setNemotron35PromptId(_ id: Int32) async {
        nemotron35PromptId = id
        if #available(macOS 15, *), let t = _nemotron35Transcriber as? Nemotron35StreamingTranscriber {
            await t.setPromptId(id)
        }
    }

    func unloadNemotron35Transcriber() async {
        if #available(macOS 15, *), let transcriber = _nemotron35Transcriber as? Nemotron35StreamingTranscriber {
            await transcriber.shutdown()
        }
    }

    func unloadGemma4LiteRTTranscriber() async {
        if #available(macOS 15, *), let transcriber = _gemma4LiteRTTranscriber as? Gemma4LiteRTTranscriber {
            await transcriber.shutdown()
            _gemma4LiteRTTranscriber = nil
        }
    }

    func unloadFluidAudioTranscriber(ifLoadedVersion version: AsrModelVersion) async {
        await fluidTranscriber.shutdown(ifLoadedVersion: version)
    }

    func unloadParakeetUnifiedTranscriber() async {
        await parakeetUnifiedTranscriber.shutdown()
    }

    func unloadQwen3Transcriber() async {
        if #available(macOS 15, *), let transcriber = _qwen3Transcriber as? Qwen3AsrTranscriber {
            await transcriber.shutdown()
            _qwen3Transcriber = nil
        }
    }

    func unloadAppleSpeechTranscriber() async {
        if #available(macOS 26.0, *) {
            await appleSpeechLifecycle.requestCleanup { [weak self] in
                await self?.releaseAppleSpeechTranscriber()
            }
        }
    }

    @available(macOS 26.0, *)
    private func releaseAppleSpeechTranscriber() async {
        guard let transcriber = _appleSpeechTranscriber as? AppleSpeechAnalyzerTranscriber else { return }
        await transcriber.releaseReservations()
        guard let current = _appleSpeechTranscriber as? AppleSpeechAnalyzerTranscriber,
              current === transcriber else { return }
        _appleSpeechTranscriber = nil
    }

    @available(macOS 15, *)
    private var qwen3Transcriber: Qwen3AsrTranscriber {
        if _qwen3Transcriber == nil {
            _qwen3Transcriber = Qwen3AsrTranscriber()
        }
        return _qwen3Transcriber as! Qwen3AsrTranscriber
    }

    @available(macOS 15, *)
    private var cohereTranscriber: CohereTranscribeTranscriber {
        if _cohereTranscriber == nil {
            _cohereTranscriber = CohereTranscribeTranscriber()
        }
        return _cohereTranscriber as! CohereTranscribeTranscriber
    }

    @available(macOS 15, *)
    private var indicASRTranscriber: IndicASRTranscriber {
        if _indicASRTranscriber == nil {
            _indicASRTranscriber = IndicASRTranscriber()
        }
        return _indicASRTranscriber as! IndicASRTranscriber
    }

    @available(macOS 15, *)
    private var gemma4LiteRTTranscriber: Gemma4LiteRTTranscriber {
        if _gemma4LiteRTTranscriber == nil {
            _gemma4LiteRTTranscriber = Gemma4LiteRTTranscriber()
        }
        return _gemma4LiteRTTranscriber as! Gemma4LiteRTTranscriber
    }

    @available(macOS 26.0, *)
    private var appleSpeechTranscriber: AppleSpeechAnalyzerTranscriber {
        if _appleSpeechTranscriber == nil {
            _appleSpeechTranscriber = AppleSpeechAnalyzerTranscriber()
        }
        return _appleSpeechTranscriber as! AppleSpeechAnalyzerTranscriber
    }

    @available(macOS 26.0, *)
    private func prepareAppleSpeech(
        languageIdentifier: String,
        progress: ((Double, String?) -> Void)?,
        progressSnapshot: ModelDownloadProgressHandler?
    ) async throws {
        await appleSpeechLifecycle.beginUse()
        let transcriber = appleSpeechTranscriber
        do {
            try Task.checkCancellation()
            _ = try await transcriber.prepare(
                requestedLocale: AppleSpeechLanguageOption.requestedLocale(for: languageIdentifier),
                progress: progress,
                progressSnapshot: progressSnapshot
            )
            await appleSpeechLifecycle.endUse()
        } catch {
            await appleSpeechLifecycle.endUse()
            throw error
        }
    }

    @available(macOS 26.0, *)
    private func transcribeWithAppleSpeech(
        url: URL,
        languageIdentifier: String
    ) async throws -> SpeechTranscriptionResult {
        await appleSpeechLifecycle.beginUse()
        let transcriber = appleSpeechTranscriber
        do {
            try Task.checkCancellation()
            let result = try await transcriber.transcribe(
                wavURL: url,
                requestedLocale: AppleSpeechLanguageOption.requestedLocale(for: languageIdentifier)
            )
            await appleSpeechLifecycle.endUse()
            return result
        } catch {
            await appleSpeechLifecycle.endUse()
            throw error
        }
    }

    func preload(
        backend: BackendOption,
        includeMeetingHelpers: Bool = true,
        meetingHelperTrigger: DiarizerPreloadTrigger = .unspecified,
        appleSpeechLanguage: String = AppleSpeechLanguageOption.systemIdentifier,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async {
        do {
            try await preloadRequired(
                backend: backend,
                includeMeetingHelpers: includeMeetingHelpers,
                meetingHelperTrigger: meetingHelperTrigger,
                appleSpeechLanguage: appleSpeechLanguage,
                progress: progress,
                progressSnapshot: progressSnapshot
            )
        } catch {
            fputs("[meets] preload failed for \(backend.backend)/\(backend.model): \(error)\n", stderr)
        }
    }

    func preloadRequired(
        backend: BackendOption,
        includeMeetingHelpers: Bool = true,
        meetingHelperTrigger: DiarizerPreloadTrigger = .unspecified,
        appleSpeechLanguage: String = AppleSpeechLanguageOption.systemIdentifier,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        if includeMeetingHelpers {
            await preloadMeetingHelpers(trigger: meetingHelperTrigger)
        }
        try Task.checkCancellation()

        switch backend.backend {
        case "fluidaudio":
            let version: AsrModelVersion = backend.model.contains("v2") ? .v2 : .v3
            try await fluidTranscriber.loadModels(
                version: version,
                progress: progress,
                progressSnapshot: progressSnapshot
            )
        case "parakeet-unified":
            try await parakeetUnifiedTranscriber.loadModels(
                progress: progress,
                progressSnapshot: progressSnapshot
            )
        case "whisper":
            try await whisperTranscriber.loadModel(
                modelName: backend.model,
                progress: progress,
                progressSnapshot: progressSnapshot
            )
            // Warmup ANE/GPU so the first transcription doesn't pay CoreML compilation cost
            fputs("[meets] WhisperKit warmup: running silent audio for CoreML compilation...\n", stderr)
            let warming = ModelDownloadProgress.preparing(
                modelID: backend.model,
                message: "Warming up model..."
            )
            progress?(0.9, warming.message)
            progressSnapshot?(warming)
            try await whisperTranscriber.warmup()
            fputs("[meets] WhisperKit warmup complete\n", stderr)
            progress?(1.0, nil)
            progressSnapshot?(warming.replacing(phase: .ready, message: "Model ready"))
        case "nemotron35":
            if #available(macOS 15, *) {
                let transcriber = try await getLoadedNemotron35Transcriber(progress: progress, progressSnapshot: progressSnapshot)
                // Warmup ANE so the first transcription starts instantly
                fputs("[meets] Nemotron 3.5 warmup: running silent chunk for ANE compilation...\n", stderr)
                var state = try await transcriber.makeStreamState()
                let silence = [Float](repeating: 0, count: transcriber.chunkSamples)
                _ = try await transcriber.transcribeChunk(samples: silence, state: &state)
                fputs("[meets] Nemotron 3.5 warmup complete\n", stderr)
            } else {
                throw NSError(domain: "MeetsTranscriptionRuntime", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Nemotron 3.5 requires macOS 15 or later.",
                ])
            }
        case "qwen":
            if #available(macOS 15, *) {
                try await qwen3Transcriber.loadModels(
                    progress: progress,
                    progressSnapshot: progressSnapshot
                )
            } else {
                throw NSError(domain: "MeetsTranscriptionRuntime", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Qwen3 ASR requires macOS 15 or later.",
                ])
            }
        case "cohere":
            if #available(macOS 15, *) {
                try await cohereTranscriber.prepare(progress: progress, progressSnapshot: progressSnapshot)
            } else {
                throw NSError(domain: "MeetsTranscriptionRuntime", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Cohere Transcribe requires macOS 15 or later.",
                ])
            }
        case "indicasr":
            if #available(macOS 15, *) {
                try await indicASRTranscriber.prepare(progress: progress, progressSnapshot: progressSnapshot)
            } else {
                throw NSError(domain: "MeetsTranscriptionRuntime", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "Indic ASR requires macOS 15 or later.",
                ])
            }
        case "sensevoice":
            try await senseVoiceTranscriber.loadModels(
                progress: progress,
                progressSnapshot: progressSnapshot
            )
        case "gemma4-litert":
            if #available(macOS 15, *) {
                try await gemma4LiteRTTranscriber.prepare(
                    model: Gemma4LiteRTModel.resolved(backend.model),
                    progress: progress,
                    progressSnapshot: progressSnapshot
                )
            } else {
                throw NSError(domain: "MeetsTranscriptionRuntime", code: 7, userInfo: [
                    NSLocalizedDescriptionKey: "\(backend.label) requires macOS 15 or later.",
                ])
            }
        case "apple-speech":
            if #available(macOS 26.0, *) {
                try await prepareAppleSpeech(
                    languageIdentifier: appleSpeechLanguage,
                    progress: progress,
                    progressSnapshot: progressSnapshot
                )
            } else {
                throw AppleSpeechAnalyzerError.unavailable
            }
        default:
            throw NSError(domain: "MeetsTranscriptionRuntime", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Unknown transcription backend: \(backend.backend)",
            ])
        }
    }

    func preloadMeetingHelpers(trigger: DiarizerPreloadTrigger = .unspecified) async {
        if vadManager == nil {
            do {
                vadManager = try await vadLoader()
                fputs("[meets] Silero VAD loaded\n", stderr)
            } catch {
                fputs("[meets] VAD load failed (non-critical): \(error)\n", stderr)
            }
        }

        await preloadDiarizer(trigger: trigger)
    }

    func preloadDiarizer(
        trigger: DiarizerPreloadTrigger = .unspecified,
        waitTimeout: Duration = TranscriptionCoordinator.defaultDiarizerLoadWaitTimeout
    ) async {
        let policy = DiarizerRuntimePolicy.resolve(for: .current())
        let context = DiarizerPreloadContext(
            trigger: trigger,
            policy: policy,
            cacheState: .resolve()
        )

        if diarizerManager != nil {
            diarizerDiagnostics.skipped(context, reason: "already_loaded")
            return
        }

        let startedLoad = !isDiarizerLoadInProgress
        if startedLoad {
            startDiarizerLoad(policy: policy, context: context)
        }

        let outcome = await waitForActiveDiarizerLoad(timeout: waitTimeout)
        let resolvedOutcome: DiarizerLoadWaitOutcome = Task.isCancelled ? .cancelled : outcome
        switch (startedLoad, resolvedOutcome) {
        case (true, .succeeded), (true, .failed):
            // The load lifecycle itself emits the terminal diagnostic.
            break
        case (false, .succeeded):
            diarizerDiagnostics.skipped(context, reason: "joined_load_succeeded")
        case (false, .failed):
            diarizerDiagnostics.skipped(context, reason: "joined_load_failed")
        case (true, .cancelled):
            diarizerDiagnostics.skipped(context, reason: "load_wait_cancelled")
        case (false, .cancelled):
            diarizerDiagnostics.skipped(context, reason: "joined_load_cancelled")
        case (true, .timedOut):
            diarizerDiagnostics.skipped(context, reason: "load_wait_timed_out")
        case (false, .timedOut):
            diarizerDiagnostics.skipped(context, reason: "joined_load_timed_out")
        }
    }

    private func startDiarizerLoad(
        policy: DiarizerRuntimePolicy,
        context: DiarizerPreloadContext
    ) {
        isDiarizerLoadInProgress = true
        didDiarizerLoadTimeOut = false
        let loadID = UUID()
        activeDiarizerLoadID = loadID
        let startedAt = diarizerDiagnostics.begin(context)

        let loader = diarizerModelLoader
        diarizerLoadTask = Task { [weak self] in
            do {
                let models = try await loader(policy)
                try Task.checkCancellation()
                await self?.finishDiarizerLoad(
                    id: loadID,
                    result: .success(models),
                    policy: policy,
                    context: context,
                    startedAt: startedAt
                )
            } catch {
                await self?.finishDiarizerLoad(
                    id: loadID,
                    result: .failure(error),
                    policy: policy,
                    context: context,
                    startedAt: startedAt
                )
            }
        }

        let operationTimeout = diarizerLoadOperationTimeout
        diarizerLoadTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: operationTimeout)
            } catch {
                return
            }
            await self?.timeoutDiarizerLoad(id: loadID)
        }
    }

    private func finishDiarizerLoad(
        id: UUID,
        result: Result<DiarizerModels, Error>,
        policy: DiarizerRuntimePolicy,
        context: DiarizerPreloadContext,
        startedAt: Date
    ) {
        guard activeDiarizerLoadID == id else { return }

        let didTimeOut = didDiarizerLoadTimeOut
        diarizerLoadTimeoutTask?.cancel()
        diarizerLoadTimeoutTask = nil
        diarizerLoadTask = nil
        activeDiarizerLoadID = nil
        isDiarizerLoadInProgress = false
        didDiarizerLoadTimeOut = false

        let outcome: DiarizerLoadWaitOutcome
        switch result {
        case .success(let models):
            let diarizer = DiarizerManager()
            diarizer.initialize(models: models)
            diarizerManager = diarizer
            diarizerDiagnostics.ready(context, startedAt: startedAt)
            fputs(
                "[meets] Speaker diarization loaded (compute: \(policy.computePolicy.rawValue))\n",
                stderr
            )
            outcome = .succeeded
        case .failure(let error):
            let reportedError: Error = didTimeOut ? DiarizerPreloadFailure.operationTimedOut : error
            diarizerDiagnostics.failed(context, startedAt: startedAt, error: reportedError)
            fputs("[meets] Diarization load failed (non-critical): \(reportedError)\n", stderr)
            outcome = .failed
        }

        resumeAllDiarizerLoadWaiters(with: outcome)
    }

    private func timeoutDiarizerLoad(id: UUID) {
        guard activeDiarizerLoadID == id else { return }
        didDiarizerLoadTimeOut = true
        diarizerLoadTask?.cancel()
        // A third-party model load may not observe cancellation while CoreML is
        // compiling. Release product callers immediately while retaining the
        // active-load guard so another expensive load cannot start in parallel.
        resumeAllDiarizerLoadWaiters(with: .timedOut)
    }

    private func waitForActiveDiarizerLoad(timeout: Duration) async -> DiarizerLoadWaitOutcome {
        if didDiarizerLoadTimeOut { return .timedOut }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }

                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.resumeDiarizerLoadWaiter(id: waiterID, with: .timedOut)
                }
                diarizerLoadWaiters[waiterID] = DiarizerLoadWaiter(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
        } onCancel: { [weak self] in
            Task {
                await self?.resumeDiarizerLoadWaiter(id: waiterID, with: .cancelled)
            }
        }
    }

    private func resumeDiarizerLoadWaiter(id: UUID, with outcome: DiarizerLoadWaitOutcome) {
        guard let waiter = diarizerLoadWaiters.removeValue(forKey: id) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: outcome)
    }

    private func resumeAllDiarizerLoadWaiters(with outcome: DiarizerLoadWaitOutcome) {
        let waiters = diarizerLoadWaiters.values
        diarizerLoadWaiters.removeAll()
        for waiter in waiters {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: outcome)
        }
    }

    #if DEBUG
    func diarizerPreloadStateForTesting() -> (isActive: Bool, waiterCount: Int) {
        (isDiarizerLoadInProgress, diarizerLoadWaiters.count)
    }
    #endif

    func transcribeMeeting(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage = CohereTranscribeLanguage.defaultLanguage,
        indicASRLanguage: IndicASRLanguage = IndicASRLanguage.defaultLanguage,
        whisperLanguage: WhisperKitLanguage = WhisperKitLanguage.defaultLanguage,
        qwen3AsrLanguage: Qwen3AsrLanguage = Qwen3AsrLanguage.defaultLanguage,
        parakeetLanguage: ParakeetLanguage = ParakeetLanguage.defaultLanguage,
        appleSpeechLanguage: String = AppleSpeechLanguageOption.systemIdentifier
    ) async throws -> SpeechTranscriptionResult {
        // Meetings intentionally skip Qwen/custom-word post-processing. Keep deterministic artifact/filler cleanup only.
        cleanMeetingTranscript(try await route(
            url: url,
            backend: backend,
            cohereLanguage: cohereLanguage,
            indicASRLanguage: indicASRLanguage,
            whisperLanguage: whisperLanguage,
            qwen3AsrLanguage: qwen3AsrLanguage,
            parakeetLanguage: parakeetLanguage,
            appleSpeechLanguage: appleSpeechLanguage
        ))
    }

    func transcribeMeetingChunk(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage = CohereTranscribeLanguage.defaultLanguage,
        indicASRLanguage: IndicASRLanguage = IndicASRLanguage.defaultLanguage,
        whisperLanguage: WhisperKitLanguage = WhisperKitLanguage.defaultLanguage,
        qwen3AsrLanguage: Qwen3AsrLanguage = Qwen3AsrLanguage.defaultLanguage,
        parakeetLanguage: ParakeetLanguage = ParakeetLanguage.defaultLanguage,
        appleSpeechLanguage: String = AppleSpeechLanguageOption.systemIdentifier
    ) async throws -> SpeechTranscriptionResult {
        // Meeting chunks intentionally skip Qwen/custom-word post-processing for reconciliation.
        // Run VAD to skip silent chunks (prevents hallucinations)
        if let vadManager {
            do {
                let vadResults = try await vadManager.process(url)
                let hasSpeech = vadResults.contains { $0.probability > 0.5 }
                if !hasSpeech {
                    fputs("[meets] VAD: chunk is silent, skipping transcription\n", stderr)
                    return SpeechTranscriptionResult(text: "", segments: [])
                }
            } catch {
                fputs("[meets] VAD check failed, transcribing anyway: \(error)\n", stderr)
            }
        }
        return cleanMeetingTranscript(try await route(
            url: url,
            backend: backend,
            cohereLanguage: cohereLanguage,
            indicASRLanguage: indicASRLanguage,
            whisperLanguage: whisperLanguage,
            qwen3AsrLanguage: qwen3AsrLanguage,
            parakeetLanguage: parakeetLanguage,
            appleSpeechLanguage: appleSpeechLanguage
        ))
    }

    func diarizeSystemAudio(at url: URL) async throws -> DiarizationResult? {
        guard let diarizerManager, diarizerManager.isAvailable else {
            fputs("[meets] diarization not available, skipping\n", stderr)
            return nil
        }
        fputs("[meets] running speaker diarization on system audio...\n", stderr)
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(url)
        let result = try diarizerManager.performCompleteDiarization(samples, sampleRate: 16000)
        let speakerCount = Set(result.segments.map(\.speakerId)).count
        fputs("[meets] diarization complete: \(result.segments.count) segments, \(speakerCount) speakers\n", stderr)
        return result
    }

    func getVadManager() -> VadManager? {
        vadManager
    }

    func getDiarizerManager() -> DiarizerManager? {
        diarizerManager
    }

    func shutdown() async {
        await fluidTranscriber.shutdown()
        await parakeetUnifiedTranscriber.shutdown()
        await whisperTranscriber.shutdown()
        await senseVoiceTranscriber.shutdown()
        if #available(macOS 15, *) {
            if let nemotron35 = _nemotron35Transcriber as? Nemotron35StreamingTranscriber {
                await nemotron35.shutdown()
            }
            await qwen3Transcriber.shutdown()
            await cohereTranscriber.shutdown()
            await indicASRTranscriber.shutdown()
            if let gemma4 = _gemma4LiteRTTranscriber as? Gemma4LiteRTTranscriber {
                await gemma4.shutdown()
            }
        }
    }

    private func removeFillers(_ result: SpeechTranscriptionResult) -> SpeechTranscriptionResult {
        let filtered = FillerWordFilter.apply(result.text)
        return SpeechTranscriptionResult(text: filtered, segments: result.segments)
    }

    private func cleanMeetingTranscript(_ result: SpeechTranscriptionResult) -> SpeechTranscriptionResult {
        removeFillers(removeArtifacts(result))
    }

    private func removeArtifacts(_ result: SpeechTranscriptionResult) -> SpeechTranscriptionResult {
        let filtered = TranscriptionEngineArtifactsFilter.apply(result.text)
        return SpeechTranscriptionResult(text: filtered, segments: filtered.isEmpty ? [] : result.segments)
    }

    private func route(
        url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage,
        indicASRLanguage: IndicASRLanguage,
        whisperLanguage: WhisperKitLanguage,
        qwen3AsrLanguage: Qwen3AsrLanguage,
        parakeetLanguage: ParakeetLanguage,
        appleSpeechLanguage: String
    ) async throws -> SpeechTranscriptionResult {
        switch backend.backend {
        case "whisper":
            let language = backend.supportsWhisperLanguageSelection
                ? whisperLanguage
                : WhisperKitLanguage.defaultLanguage
            return try await transcribeWithWhisperKit(url: url, language: language)
        case "nemotron35":
            return try await transcribeWithNemotron35(url: url)
        case "parakeet-unified":
            return try await transcribeWithParakeetUnified(url: url)
        case "qwen":
            return try await transcribeWithQwen3(url: url, language: qwen3AsrLanguage)
        case "cohere":
            return try await transcribeWithCohere(url: url, language: cohereLanguage)
        case "indicasr":
            return try await transcribeWithIndicASR(url: url, language: indicASRLanguage)
        case "sensevoice":
            return try await transcribeWithSenseVoice(url: url)
        case "gemma4-litert":
            return try await transcribeWithGemma4LiteRT(url: url, model: Gemma4LiteRTModel.resolved(backend.model))
        case "apple-speech":
            if #available(macOS 26.0, *) {
                return try await transcribeWithAppleSpeech(
                    url: url,
                    languageIdentifier: appleSpeechLanguage
                )
            }
            throw AppleSpeechAnalyzerError.unavailable
        default:
            return try await transcribeWithFluidAudio(url: url, language: parakeetLanguage)
        }
    }

    // MARK: - FluidAudio (Parakeet on ANE)

    private func transcribeWithFluidAudio(url: URL, language: ParakeetLanguage) async throws -> SpeechTranscriptionResult {
        fputs("[meets] transcribing with FluidAudio: \(url.lastPathComponent)\n", stderr)
        let result = try await fluidTranscriber.transcribe(wavURL: url, language: language.isoCode)
        fputs("[meets] FluidAudio result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = (result.tokenTimings ?? []).map { timing in
            SpeechSegment(start: timing.startTime, end: timing.endTime, text: timing.token)
        }
        return SpeechTranscriptionResult(
            text: text,
            segments: segments.isEmpty && !text.isEmpty ? [SpeechSegment(start: 0, end: result.duration, text: text)] : segments
        )
    }

    // MARK: - Parakeet Unified (FastConformer-RNNT offline batch)

    private func transcribeWithParakeetUnified(url: URL) async throws -> SpeechTranscriptionResult {
        fputs("[meets] transcribing with Parakeet Unified: \(url.lastPathComponent)\n", stderr)
        let result = try await parakeetUnifiedTranscriber.transcribe(wavURL: url)
        fputs("[meets] Parakeet Unified result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SpeechTranscriptionResult(
            text: text,
            segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
        )
    }

    // MARK: - WhisperKit (Whisper on ANE/GPU via CoreML)

    private func transcribeWithWhisperKit(
        url: URL,
        language: WhisperKitLanguage
    ) async throws -> SpeechTranscriptionResult {
        fputs("[meets] transcribing with WhisperKit: \(url.lastPathComponent)\n", stderr)
        let result = try await whisperTranscriber.transcribe(wavURL: url, language: language)
        fputs("[meets] WhisperKit result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SpeechTranscriptionResult(
            text: text,
            segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
        )
    }

    // MARK: - Qwen3 ASR (Autoregressive CoreML on ANE)

    private func transcribeWithQwen3(url: URL, language: Qwen3AsrLanguage) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            fputs("[meets] transcribing with Qwen3 ASR: \(url.lastPathComponent)\n", stderr)
            let result = try await qwen3Transcriber.transcribe(wavURL: url, language: language.pinnedCode)
            fputs("[meets] Qwen3 ASR result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Qwen3 ASR requires macOS 15 or later.",
            ])
        }
    }

    // MARK: - SenseVoiceSmall (FunASR via FluidAudio/CoreML)

    private func transcribeWithSenseVoice(url: URL) async throws -> SpeechTranscriptionResult {
        fputs("[meets] transcribing with SenseVoice: \(url.lastPathComponent)\n", stderr)
        let result = try await senseVoiceTranscriber.transcribe(wavURL: url)
        fputs("[meets] SenseVoice result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SpeechTranscriptionResult(
            text: text,
            // FluidAudio's SenseVoice API returns plain text only, so timestamped segments are not available here.
            segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
        )
    }

    // MARK: - Gemma 4 (LiteRT-LM multimodal)

    private func transcribeWithGemma4LiteRT(
        url: URL,
        model: Gemma4LiteRTModel
    ) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            Gemma4LiteRTLogging.log("transcribing \(url.lastPathComponent)")
            let result = try await gemma4LiteRTTranscriber.transcribe(wavURL: url, model: model)
            Gemma4LiteRTLogging.log("result chars=\(result.text.count), processingTime=\(String(format: "%.3f", result.processingTime))s")
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "MeetsTranscriptionRuntime", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "\(model.label) requires macOS 15 or later.",
            ])
        }
    }

    // MARK: - Cohere Transcribe (CoreML)

    private func transcribeWithCohere(
        url: URL,
        language: CohereTranscribeLanguage
    ) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            fputs("[meets] transcribing with Cohere Transcribe: \(url.lastPathComponent)\n", stderr)
            let result = try await cohereTranscriber.transcribe(wavURL: url, language: language)
            fputs("[meets] Cohere Transcribe result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Cohere Transcribe requires macOS 15 or later.",
            ])
        }
    }

    // MARK: - Indic ASR (AI4Bharat IndicConformer RNNT CoreML)

    private func transcribeWithIndicASR(
        url: URL,
        language: IndicASRLanguage
    ) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            IndicASRLogging.logVerbose("transcribing with Indic ASR (\(language.rawValue)): \(url.lastPathComponent)")
            let result = try await indicASRTranscriber.transcribe(wavURL: url, language: language)
            IndicASRLogging.logVerbose("Indic ASR result chars=\(result.text.count), processingTime=\(String(format: "%.3f", result.processingTime))s")
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Indic ASR requires macOS 15 or later.",
            ])
        }
    }

    // MARK: - Nemotron 3.5 Streaming (RNNT CoreML on ANE)

    private func transcribeWithNemotron35(url: URL) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            fputs("[meets] transcribing with Nemotron 3.5: \(url.lastPathComponent)\n", stderr)
            let transcriber = try await getLoadedNemotron35Transcriber()
            let result = try await transcriber.transcribe(wavURL: url)
            fputs("[meets] Nemotron 3.5 result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Nemotron 3.5 requires macOS 15 or later.",
            ])
        }
    }

}
