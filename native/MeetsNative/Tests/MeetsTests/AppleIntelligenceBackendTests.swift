import Testing
import Foundation
@testable import MeetsApp

/// Deterministic stand-in for the on-device system model: records every request
/// and answers with a canned response. No live Apple model is used.
private actor AppleIntelligenceModelStub {
    struct Call: Sendable {
        let instructions: String
        let prompt: String
    }

    private(set) var calls: [Call] = []
    private let response: @Sendable (_ instructions: String, _ prompt: String) -> String

    init(response: @escaping @Sendable (_ instructions: String, _ prompt: String) -> String = { _, prompt in prompt }) {
        self.response = response
    }

    func respond(instructions: String, prompt: String) -> String {
        calls.append(Call(instructions: instructions, prompt: prompt))
        return response(instructions, prompt)
    }
}

@Suite("AppleIntelligenceBackend")
struct AppleIntelligenceBackendTests {
    @Test("backend resolves for meeting summaries and transcript cleanup")
    func registration() {
        #expect(MeetingSummaryBackendOption.appleIntelligence.backend == "apple_intelligence")
        #expect(MeetingSummaryBackendOption.appleIntelligence.label == "Apple Intelligence (On-Device)")
        #expect(MeetingSummaryBackendOption.all.contains(.appleIntelligence))
        #expect(MeetingSummaryBackendOption.resolved("apple_intelligence") == .appleIntelligence)

        let cleanup = TranscriptCleanupBackendOption.resolved("apple_intelligence")
        #expect(cleanup == .appleIntelligence)
        #expect(cleanup.llmBackend == .appleIntelligence)
        #expect(cleanup.isAppleIntelligence)
        #expect(cleanup.isOnDevice)
        #expect(TranscriptCleanupBackendOption.all.contains(.appleIntelligence))
        #expect(TranscriptCleanupBackendOption.available(for: .gemma4E2BLiteRT).contains(.appleIntelligence))
    }

    @Test("availability reasons map onto user-facing status")
    func availabilityMapping() {
        #expect(AppleIntelligenceAvailabilityMapper.status(isAvailable: true, reason: nil) == .available)
        #expect(AppleIntelligenceAvailabilityMapper.status(isAvailable: false, reason: .deviceNotEligible) == .deviceNotEligible)
        #expect(AppleIntelligenceAvailabilityMapper.status(isAvailable: false, reason: .appleIntelligenceNotEnabled) == .appleIntelligenceNotEnabled)
        #expect(AppleIntelligenceAvailabilityMapper.status(isAvailable: false, reason: .modelNotReady) == .modelNotReady)
        #expect(AppleIntelligenceAvailabilityMapper.status(isAvailable: false, reason: .unrecognized) == .unknownUnavailable)
        #expect(AppleIntelligenceAvailabilityMapper.status(isAvailable: false, reason: nil) == .unknownUnavailable)

        #expect(AppleIntelligenceStatus.available.isAvailable)
        let unavailable: [AppleIntelligenceStatus] = [
            .requiresNewerOperatingSystem,
            .deviceNotEligible,
            .appleIntelligenceNotEnabled,
            .modelNotReady,
            .unknownUnavailable,
        ]
        #expect(unavailable.allSatisfy { !$0.isAvailable })
        #expect(unavailable.allSatisfy { !$0.summary.isEmpty })
        #expect(unavailable.count == Set(unavailable.map(\.summary)).count)
        #expect(AppleIntelligenceStatus.requiresNewerOperatingSystem.summary.contains("macOS 27"))
        #expect(AppleIntelligenceError.unavailable(.requiresNewerOperatingSystem).localizedDescription.contains("macOS 27"))
        if #available(macOS 27.0, *) {
            #expect(AppleIntelligenceBackend.status != .requiresNewerOperatingSystem)
        }
    }

    @Test("generation rejects an unavailable model before any request")
    func generationRequiresAvailability() async {
        guard !AppleIntelligenceBackend.status.isAvailable else { return }
        await #expect(throws: AppleIntelligenceError.unavailable(AppleIntelligenceBackend.status)) {
            _ = try await AppleIntelligenceBackend.generate(
                instructions: "Summarize the meeting.",
                userPrompt: "Transcript body.",
                mode: .meetingSummary,
                logCategory: "test"
            )
        }
    }

    @Test("planner keeps short prompts in one request and chunks long prompts")
    func plannerShortVersusLong() {
        let budget = AppleIntelligenceBudget(contextSize: 4_096, instructionsTokens: 300, outputReserveTokens: 1_200)
        #expect(budget.inputTokens == 4_096 - 300 - 1_200 - AppleIntelligenceBudget.framingReserveTokens)

        #expect(!AppleIntelligencePromptPlanner.requiresChunking(promptTokens: budget.inputTokens, budget: budget, mode: .meetingSummary))
        #expect(AppleIntelligencePromptPlanner.requiresChunking(promptTokens: budget.inputTokens + 1, budget: budget, mode: .meetingSummary))

        // Cleanup answers mirror their input, so cleanup chunks below the
        // general input budget that a summary would still accept.
        let cleanupChunkTokens = budget.chunkInputTokens(for: .transcriptCleanup)
        #expect(cleanupChunkTokens < budget.inputTokens)
        #expect(!AppleIntelligencePromptPlanner.requiresChunking(promptTokens: cleanupChunkTokens, budget: budget, mode: .transcriptCleanup))
        #expect(AppleIntelligencePromptPlanner.requiresChunking(promptTokens: cleanupChunkTokens + 1, budget: budget, mode: .transcriptCleanup))
        #expect(!AppleIntelligencePromptPlanner.requiresChunking(promptTokens: cleanupChunkTokens + 1, budget: budget, mode: .meetingSummary))

        let prompt = String(repeating: "The quarterly plan covers hiring and budget. ", count: 400)
        let chunks = AppleIntelligencePromptPlanner.chunks(of: prompt, budget: budget, mode: .meetingSummary)
        #expect(chunks.count > 1)
        #expect(chunks.joined() == prompt)
        #expect(chunks.allSatisfy { !$0.isEmpty })
    }

    @Test("token fallback is a conservative UTF-8 byte upper bound")
    func tokenEstimateUpperBound() {
        #expect(AppleIntelligenceBudget.estimatedTokens(for: "") == 1)
        #expect(AppleIntelligenceBudget.estimatedTokens(for: "hello world") == 11)

        let dense = "東京👨‍👩‍👧‍👦é"
        #expect(AppleIntelligenceBudget.estimatedTokens(for: dense) == dense.utf8.count)
        #expect(AppleIntelligenceBudget.estimatedTokens(for: dense) > dense.count)
        #expect(AppleIntelligenceBudget.estimatedTokens(for: dense) > dense.count / AppleIntelligenceBudget.charactersPerToken)
    }

    @Test("cleanup planning preserves order, content, and Character boundaries")
    func cleanupPlanningPreservesContent() {
        let budget = AppleIntelligenceBudget(contextSize: 2_048, instructionsTokens: 200, outputReserveTokens: 1_500)
        let prompt = (1...200)
            .map { "Line \($0): café, naïve résumé, 👨‍👩‍👧‍👦 and 東京 discussion." }
            .joined(separator: "\n")

        let chunks = AppleIntelligencePromptPlanner.chunks(of: prompt, budget: budget, mode: .transcriptCleanup)
        let characterLimit = budget.chunkCharacters(for: .transcriptCleanup)

        #expect(chunks.count > 1)
        #expect(chunks.joined() == prompt)
        #expect(chunks.allSatisfy { $0.count <= characterLimit })
        #expect(chunks.allSatisfy { chunk in
            let droppedLeadingMark = chunk.unicodeScalars.first.map { !(0x0300...0x036F).contains($0.value) } ?? false
            let droppedTrailingMark = chunk.unicodeScalars.last.map { !(0x0300...0x036F).contains($0.value) } ?? false
            return droppedLeadingMark && droppedTrailingMark
        })

        #expect(AppleIntelligenceChunker.chunks(of: "👨‍👩‍👧‍👦🎉", maxCharacters: 1) == ["👨‍👩‍👧‍👦", "🎉"])
        #expect(AppleIntelligenceChunker.chunks(of: "", maxCharacters: 4).isEmpty)
        #expect(AppleIntelligenceChunker.chunks(of: "short", maxCharacters: 5) == ["short"])
    }

    @Test("cleanup requests every chunk in order and keeps all of its content")
    func cleanupChunkOrdering() async throws {
        let stub = AppleIntelligenceModelStub()
        let generator = AppleIntelligenceChunkedGenerator(
            mode: .transcriptCleanup,
            budget: AppleIntelligenceBudget(contextSize: 8_192, instructionsTokens: 200, outputReserveTokens: 1_500),
            countTokens: { $0.count },
            generate: { instructions, prompt in await stub.respond(instructions: instructions, prompt: prompt) }
        )

        let chunks = ["first part of the transcript", "second part of the transcript", "third part of the transcript"]
        let output = try await generator.run(chunks: chunks, instructions: "Remove filler words.")

        let calls = await stub.calls
        #expect(calls.map(\.prompt) == chunks)
        #expect(calls.allSatisfy { $0.instructions.contains("Remove filler words.") })
        #expect(calls.enumerated().allSatisfy { entry in
            entry.element.instructions.contains("part \(entry.offset + 1) of \(chunks.count)")
        })
        #expect(output == chunks.joined(separator: "\n"))
    }

    @Test("a chunk the character splitter left whole is split by token count before any request")
    func oversizedChunkSplitsByTokens() async throws {
        let stub = AppleIntelligenceModelStub()
        let budget = AppleIntelligenceBudget(contextSize: 4_096, instructionsTokens: 300, outputReserveTokens: 1_500)
        let chunkTokens = budget.chunkInputTokens(for: .transcriptCleanup)
        let generator = AppleIntelligenceChunkedGenerator(
            mode: .transcriptCleanup,
            budget: budget,
            countTokens: { $0.count / 2 },
            generate: { instructions, prompt in await stub.respond(instructions: instructions, prompt: prompt) }
        )

        // Dense text: under the character budget as one chunk, over the token
        // budget as one request.
        let chunk = String(repeating: "0123456789", count: 300)
        #expect(AppleIntelligenceChunker.chunks(of: chunk, maxCharacters: budget.chunkCharacters(for: .transcriptCleanup)).count == 1)
        #expect(chunk.count / 2 > chunkTokens)

        let output = try await generator.run(chunks: [chunk], instructions: "Remove filler words.")

        let calls = await stub.calls
        #expect(calls.count > 1)
        #expect(calls.allSatisfy { $0.prompt.count / 2 <= chunkTokens })
        #expect(calls.allSatisfy { $0.prompt != chunk })
        #expect(calls.map(\.prompt).joined() == chunk)
        #expect(output == calls.map(\.prompt).joined(separator: "\n"))
    }

    @Test("long summaries map every chunk then reduce under the original instructions")
    func summaryMapReduce() async throws {
        let stub = AppleIntelligenceModelStub(response: { _, prompt in "notes: \(prompt)" })
        let generator = AppleIntelligenceChunkedGenerator(
            mode: .meetingSummary,
            budget: AppleIntelligenceBudget(contextSize: 8_192, instructionsTokens: 200, outputReserveTokens: 1_200),
            countTokens: { $0.count },
            generate: { instructions, prompt in await stub.respond(instructions: instructions, prompt: prompt) }
        )

        let chunks = ["first half of the meeting transcript", "second half of the meeting transcript"]
        let instructions = "Write the monthly report."
        let output = try await generator.run(chunks: chunks, instructions: instructions)

        let calls = await stub.calls
        #expect(calls.count == chunks.count + 1)
        #expect(Array(calls.prefix(chunks.count)).map(\.prompt) == chunks)
        #expect(calls.prefix(chunks.count).allSatisfy { $0.instructions != instructions })
        #expect(calls.last?.instructions == instructions)
        #expect(calls.last?.prompt.contains("notes: first half of the meeting transcript") == true)
        #expect(calls.last?.prompt.contains("notes: second half of the meeting transcript") == true)
        #expect(output == calls.last.map { "notes: " + $0.prompt })
    }

    @Test("summary reduction is capped and reports a clear context error")
    func reductionCapStops() async {
        let stub = AppleIntelligenceModelStub(response: { instructions, prompt in
            // Map steps return long notes; condensation echoes its piece, so the
            // material grows only by separators and each pass splits the same way.
            instructions == AppleIntelligenceGenerationMode.condensationInstructions
                ? prompt
                : String(repeating: "n", count: 600)
        })
        let budget = AppleIntelligenceBudget(contextSize: 1_000, instructionsTokens: 200, outputReserveTokens: 211)
        #expect(budget.inputTokens == 333)
        let generator = AppleIntelligenceChunkedGenerator(
            mode: .meetingSummary,
            budget: budget,
            countTokens: { $0.count },
            generate: { instructions, prompt in await stub.respond(instructions: instructions, prompt: prompt) }
        )

        await #expect(throws: AppleIntelligenceError.contextOverflow(contextSize: 1_000)) {
            _ = try await generator.run(
                chunks: ["first half of the transcript", "second half of the transcript"],
                instructions: "Write the monthly report."
            )
        }

        // Two map calls, then four verified pieces per reduction pass (the
        // 1,202-character material splits into 999 + 203, and 999 splits into
        // 333 + 333 + 333), for exactly `maximumReductionPasses` passes.
        #expect(await stub.calls.count == 2 + AppleIntelligenceChunkedGenerator.maximumReductionPasses * 4)
    }

    @Test("condensation splits material the character splitter left whole")
    func condensationSplitsByTokens() async throws {
        let note = String(repeating: "a", count: 180)
        let stub = AppleIntelligenceModelStub(response: { instructions, _ in
            instructions == AppleIntelligenceGenerationMode.condensationInstructions ? "c" : note
        })
        let budget = AppleIntelligenceBudget(contextSize: 1_000, instructionsTokens: 200, outputReserveTokens: 211)
        #expect(budget.inputTokens == 333)
        let generator = AppleIntelligenceChunkedGenerator(
            mode: .meetingSummary,
            budget: budget,
            countTokens: { $0.count * 2 },
            generate: { instructions, prompt in await stub.respond(instructions: instructions, prompt: prompt) }
        )

        _ = try await generator.run(
            chunks: ["first half of the transcript", "second half of the transcript"],
            instructions: "Write the monthly report."
        )

        let calls = await stub.calls
        let material = [note, note].joined(separator: "\n\n")
        #expect(AppleIntelligenceChunker.chunks(of: material, maxCharacters: budget.chunkCharacters(for: .meetingSummary)).count == 1)

        let condensationCalls = calls.filter { $0.instructions == AppleIntelligenceGenerationMode.condensationInstructions }
        #expect(condensationCalls.count > 1)
        #expect(condensationCalls.allSatisfy { $0.prompt.count * 2 <= budget.inputTokens })
        #expect(condensationCalls.map(\.prompt).joined() == material)
        #expect(calls.last?.instructions == "Write the monthly report.")
    }

    @Test("cleanup readiness follows live availability and needs no account or model")
    func cleanupReadinessNeedsNoProviderSettings() {
        let backend = TranscriptCleanupBackendOption.appleIntelligence
        var keyed = AppConfig()
        keyed.openAIAPIKey = "sk-test"
        keyed.openRouterAPIKey = "sk-or-test"
        keyed.postProcessorOpenRouterModel = "openrouter/free"
        keyed.postProcessorCustomLLMModel = "custom-model"

        let expected = AppleIntelligenceBackend.status.isAvailable
        #expect(TranscriptCleanupClient.hasRequiredSettings(for: backend, config: AppConfig(), isChatGPTAuthenticated: false) == expected)
        #expect(TranscriptCleanupClient.hasRequiredSettings(for: backend, config: keyed, isChatGPTAuthenticated: true) == expected)
        #expect(TranscriptCleanupClient.defaultModel(for: backend).isEmpty)
        #expect(TranscriptCleanupClient.configuredModel(for: backend, config: keyed).isEmpty)
    }

    @Test("adapter failures map onto the existing error surfaces")
    func errorMapping() {
        if case let TranscriptCleanupError.backendFailed(message) = TranscriptCleanupClient.appleIntelligenceCleanupError(
            AppleIntelligenceError.unavailable(.requiresNewerOperatingSystem)
        ) {
            #expect(message == AppleIntelligenceError.unavailable(.requiresNewerOperatingSystem).localizedDescription)
            #expect(message.contains("macOS 27"))
        } else {
            Issue.record("expected a backendFailed cleanup error")
        }

        if case let TranscriptCleanupError.emptyResponse(backend) = TranscriptCleanupClient.appleIntelligenceCleanupError(
            AppleIntelligenceError.emptyResponse
        ) {
            #expect(backend == AppleIntelligenceBackend.label)
        } else {
            Issue.record("expected an emptyResponse cleanup error")
        }

        if case let MeetingSummaryError.backendFailed(backend, statusCode, message) = MeetingSummaryClient.appleIntelligenceSummaryError(
            AppleIntelligenceError.generationFailed("The model declined this request."),
            backend: AppleIntelligenceBackend.label
        ) {
            #expect(backend == AppleIntelligenceBackend.label)
            #expect(statusCode == nil)
            #expect(message == "The model declined this request.")
        } else {
            Issue.record("expected a backendFailed summary error")
        }

        if case let MeetingSummaryError.emptyResponse(backend) = MeetingSummaryClient.appleIntelligenceSummaryError(
            AppleIntelligenceError.emptyResponse,
            backend: AppleIntelligenceBackend.label
        ) {
            #expect(backend == AppleIntelligenceBackend.label)
        } else {
            Issue.record("expected an emptyResponse summary error")
        }
    }
}
