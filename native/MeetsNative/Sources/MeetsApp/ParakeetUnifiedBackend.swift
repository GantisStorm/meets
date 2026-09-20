import AVFoundation
import FluidAudio
import Foundation
import MeetsCore

/// Native Swift transcription backend for Parakeet Unified 0.6B
/// (FastConformer-RNNT) using FluidAudio's offline batch `UnifiedAsrManager`.
/// English-focused, lower-WER successor to Parakeet TDT v3.
actor ParakeetUnifiedTranscriber {
    /// 16 kHz mono, the format every Parakeet export consumes.
    private static let sampleRate: Double = 16_000
    /// Samples appended to the streaming manager per step, so a long recording
    /// never has to exist twice as a full-length PCM buffer.
    private static let streamingSliceSamples = 30 * 16_000

    private var asrManager: UnifiedAsrManager?
    /// Streaming export of the same model. It shares the decoder, joint, and
    /// vocab bundles with the batch manager but needs its own chunked-attention
    /// encoder, and it is the only path that reports per-token timings.
    private var streamingManager: StreamingUnifiedAsrManager?
    private var loadedPlan: ManagedASRModelPlan?
    private var loadGeneration: UInt64 = 0

    enum TranscriberError: Error, LocalizedError {
        case notLoaded
        case audioConversionFailed

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "Parakeet Unified models not loaded. Call loadModels() first."
            case .audioConversionFailed:
                return "Parakeet Unified could not build a 16 kHz mono buffer for word timings."
            }
        }
    }

    /// Downloads models (if needed) and initializes the unified ASR manager.
    func loadModels(
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        if asrManager != nil { return }
        let generation = loadGeneration

        fputs("[parakeet-unified] downloading/loading models...\n", stderr)
        let plan = ManagedASRModelPlans.parakeetUnified()
        let loaded = try await ManagedASRModelDownloader.loadValidated(
            plan,
            progress: progress,
            progressSnapshot: progressSnapshot
        ) { modelDirectory in
            let preparing = ModelDownloadProgress.preparing(
                modelID: plan.modelID,
                message: "Loading Parakeet Unified into Core ML..."
            )
            progress?(0.95, preparing.message)
            progressSnapshot?(preparing)
            let manager = UnifiedAsrManager()
            try await manager.loadModels(from: modelDirectory)

            // Word timings come from the streaming export. A missing streaming
            // encoder must not fail the load: the batch manager still produces
            // the transcript, just without per-word timings.
            let streaming = StreamingUnifiedAsrManager()
            do {
                try await streaming.loadModels(from: modelDirectory)
                return (batch: manager, streaming: Optional(streaming))
            } catch {
                fputs("[parakeet-unified] word timings unavailable: \(error)\n", stderr)
                return (batch: manager, streaming: Optional<StreamingUnifiedAsrManager>.none)
            }
        }
        // A shutdown() during the load must invalidate the result: discard the
        // freshly loaded manager instead of resurrecting a stale one.
        guard generation == loadGeneration else {
            throw CancellationError()
        }
        self.asrManager = loaded.batch
        self.streamingManager = loaded.streaming
        self.loadedPlan = plan
        let preparing = ModelDownloadProgress.preparing(
            modelID: plan.modelID,
            message: "Loading Parakeet Unified into Core ML..."
        )
        progress?(1, nil)
        progressSnapshot?(preparing.replacing(phase: .ready, message: "Model ready"))
        fputs("[parakeet-unified] models ready\n", stderr)
    }

    /// Transcribe a WAV file URL (16 kHz mono).
    func transcribe(wavURL: URL) async throws -> (text: String, words: [SpeechWord], processingTime: Double) {
        guard let asrManager else { throw TranscriberError.notLoaded }
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(wavURL)
        let start = CFAbsoluteTimeGetCurrent()

        if let streamingManager {
            do {
                let streaming = try await streamingTranscript(samples: samples, manager: streamingManager)
                if !streaming.words.isEmpty {
                    return (streaming.text, streaming.words, CFAbsoluteTimeGetCurrent() - start)
                }
            } catch {
                fputs("[parakeet-unified] word timings unavailable: \(error)\n", stderr)
            }
        }

        let text = try await asrManager.transcribe(samples)
        return (text, [], CFAbsoluteTimeGetCurrent() - start)
    }

    /// Run the streaming export over the whole file and return its transcript
    /// with word timings. The streaming transcript is used whenever timings are
    /// available so the text and the word sequence describe the same decode.
    private func streamingTranscript(
        samples: [Float],
        manager: StreamingUnifiedAsrManager
    ) async throws -> (text: String, words: [SpeechWord]) {
        try await manager.reset()
        try await append(samples, to: manager)
        let text = try await manager.finish()
        let timings = await manager.consumeWordTimings()
        // `consumeWordTimings()` already grouped sub-word tokens on their `▁`
        // and space boundaries, so these only need trimming before the map.
        let words = TranscriptWordTimingBuilder.words(fromWhisper: timings.map { timing in
            (word: timing.word, start: timing.startTime, end: timing.endTime)
        })
        return (text, words)
    }

    /// Feed resampled audio into the streaming manager in bounded slices.
    private func append(_ samples: [Float], to manager: StreamingUnifiedAsrManager) async throws {
        guard !samples.isEmpty else { return }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriberError.audioConversionFailed
        }

        var index = 0
        while index < samples.count {
            let count = min(Self.streamingSliceSamples, samples.count - index)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else {
                throw TranscriberError.audioConversionFailed
            }
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress! + index, count: count)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try await manager.appendAudio(buffer)
            try await manager.processBufferedAudio()
            index += count
        }
    }

    func shutdown() {
        asrManager = nil
        streamingManager = nil
        loadedPlan = nil
        loadGeneration &+= 1
    }
}
