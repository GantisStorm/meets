import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Availability

/// Live availability of the on-device Apple Intelligence model.
///
/// Mirrors `SystemLanguageModel.Availability` plus the macOS 27 gate, so
/// settings and controller code can read one status without importing
/// FoundationModels. `summary` text ends without a period so callers can
/// compose it into sentences.
enum AppleIntelligenceStatus: Equatable, Sendable {
    case available
    /// The framework is missing, or this Mac runs an OS older than macOS 27.
    /// `LanguageModelSession(model:instructions:)` with a `SystemLanguageModel`
    /// only exists from macOS 27, even though parts of the framework shipped in
    /// macOS 26.
    case requiresNewerOperatingSystem
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    /// An unavailable reason this build does not know yet.
    case unknownUnavailable

    var isAvailable: Bool { self == .available }

    var summary: String {
        switch self {
        case .available:
            return "Available on this Mac"
        case .requiresNewerOperatingSystem:
            return "Requires macOS 27 or later"
        case .deviceNotEligible:
            return "This Mac does not support Apple Intelligence"
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings"
        case .modelNotReady:
            return "Apple Intelligence is still preparing its on-device model"
        case .unknownUnavailable:
            return "Apple Intelligence is unavailable right now"
        }
    }
}

/// Framework-independent mirror of `SystemLanguageModel.Availability.UnavailableReason`.
///
/// `unrecognized` carries any reason a future OS adds, so new reasons degrade to
/// a generic status instead of trapping.
enum AppleIntelligenceUnavailableReason: Equatable, Sendable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unrecognized
}

/// Pure availability mapping. Kept free of FoundationModels so every status is
/// unit-testable.
enum AppleIntelligenceAvailabilityMapper {
    static func status(isAvailable: Bool, reason: AppleIntelligenceUnavailableReason?) -> AppleIntelligenceStatus {
        guard !isAvailable else { return .available }
        switch reason {
        case .deviceNotEligible: return .deviceNotEligible
        case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
        case .modelNotReady: return .modelNotReady
        case .unrecognized, .none: return .unknownUnavailable
        }
    }
}

// MARK: - Errors

/// Failures raised by the on-device adapter. Routing boundaries map these onto
/// `MeetingSummaryError` / `TranscriptCleanupError`.
enum AppleIntelligenceError: LocalizedError, Equatable {
    case unavailable(AppleIntelligenceStatus)
    /// Even the reduced material exceeds the model's context window.
    case contextOverflow(contextSize: Int)
    case emptyResponse
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(status):
            return "Apple Intelligence is unavailable: \(status.summary)."
        case let .contextOverflow(contextSize):
            return "The transcript does not fit the on-device model's \(contextSize)-token context window, even after chunking. Use a shorter transcript or a different backend."
        case .emptyResponse:
            return "Apple Intelligence returned an empty response."
        case let .generationFailed(message):
            return message
        }
    }
}

// MARK: - Context budgeting

/// Token accounting for one on-device request.
struct AppleIntelligenceBudget: Equatable, Sendable {
    /// Conservative characters-per-token ratio. English text is closer to four
    /// characters per token, so character-sized chunks land under the real
    /// token budget.
    static let charactersPerToken = 3
    /// Tokens withheld for the framing text added around each map/reduce prompt.
    static let framingReserveTokens = 256
    /// Share of the response headroom a mirrored-input chunk may occupy.
    static let mirroredAnswerInputShare = 0.75

    let contextSize: Int
    let instructionsTokens: Int
    let outputReserveTokens: Int

    /// Tokens left for the user prompt once instructions, the reserved answer,
    /// and the framing text are accounted for.
    var inputTokens: Int {
        max(0, contextSize - instructionsTokens - outputReserveTokens - Self.framingReserveTokens)
    }

    func fits(tokens: Int) -> Bool { tokens <= inputTokens }

    /// Prompt tokens allowed for one chunk of `mode`. Transcript cleanup
    /// answers are as long as their input, so those chunks stay below the
    /// response headroom: a cleaned answer that runs slightly longer than its
    /// input still fits instead of being cut off.
    func chunkInputTokens(for mode: AppleIntelligenceGenerationMode) -> Int {
        guard mode.answerMirrorsInput else { return inputTokens }
        return min(inputTokens, Int(Double(outputReserveTokens) * Self.mirroredAnswerInputShare))
    }

    func fitsChunk(tokens: Int, mode: AppleIntelligenceGenerationMode) -> Bool {
        tokens <= chunkInputTokens(for: mode)
    }

    /// Characters allowed in one chunk of `mode`.
    func chunkCharacters(for mode: AppleIntelligenceGenerationMode) -> Int {
        max(1, chunkInputTokens(for: mode) * Self.charactersPerToken)
    }

    /// Conservative upper-bound token estimate, used only when
    /// `SystemLanguageModel.tokenCount` fails. One token per UTF-8 byte is never
    /// below the real token count for any text, so chunking stays safe on dense
    /// Unicode input at the cost of smaller requests.
    static func estimatedTokens(for text: String) -> Int {
        max(1, text.utf8.count)
    }
}

// MARK: - Chunking

/// Pure, lossless text splitting used by the map/reduce path.
enum AppleIntelligenceChunker {
    /// Splits `text` into ordered chunks of at most `maxCharacters` Characters.
    ///
    /// Guarantees:
    /// - `chunks.joined() == text`: nothing is trimmed, dropped, or reordered.
    /// - No chunk exceeds `maxCharacters` when `maxCharacters >= 1`.
    /// - Chunks never split a `Character` (grapheme cluster).
    /// - Breaks land on whitespace when whitespace exists in the second half of
    ///   the window, so cleanup output keeps its word boundaries.
    static func chunks(of text: String, maxCharacters: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        guard maxCharacters >= 1, text.count > maxCharacters else { return [text] }

        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let hardEnd = text.index(start, offsetBy: maxCharacters, limitedBy: text.endIndex) ?? text.endIndex
            guard hardEnd < text.endIndex else {
                chunks.append(String(text[start...]))
                break
            }
            let end = breakIndex(in: text, from: start, hardEnd: hardEnd, maxCharacters: maxCharacters)
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
    }

    /// Last whitespace boundary inside the second half of the window, or
    /// `hardEnd` when the window holds no whitespace.
    private static func breakIndex(
        in text: String,
        from start: String.Index,
        hardEnd: String.Index,
        maxCharacters: Int
    ) -> String.Index {
        let limit = text.index(start, offsetBy: max(1, maxCharacters / 2), limitedBy: hardEnd) ?? hardEnd
        var index = hardEnd
        while index > limit {
            let previous = text.index(before: index)
            if text[previous].isWhitespace {
                return text.index(after: previous)
            }
            index = previous
        }
        return hardEnd
    }
}

/// Pure planning seam: decides when a prompt must be split and produces the
/// ordered chunks. Token counts are supplied by the caller, so both decisions
/// are unit-testable without a live model.
enum AppleIntelligencePromptPlanner {
    /// True when the prompt must be split across several model requests.
    /// Judged against the mode's chunk budget: transcript cleanup chunks below
    /// the general input budget because its answers mirror their input, while
    /// summaries use the whole input budget.
    static func requiresChunking(
        promptTokens: Int,
        budget: AppleIntelligenceBudget,
        mode: AppleIntelligenceGenerationMode
    ) -> Bool {
        !budget.fitsChunk(tokens: promptTokens, mode: mode)
    }

    /// Ordered, lossless chunks of `prompt` sized to `budget`.
    static func chunks(of prompt: String, budget: AppleIntelligenceBudget, mode: AppleIntelligenceGenerationMode) -> [String] {
        AppleIntelligenceChunker.chunks(of: prompt, maxCharacters: budget.chunkCharacters(for: mode))
    }
}

// MARK: - Generation modes

/// What the on-device model is being asked to do. Summary requests may chunk
/// and reduce; cleanup requests chunk and must not drop content.
enum AppleIntelligenceGenerationMode: Equatable, Sendable {
    case meetingSummary
    case transcriptCleanup

    /// Tokens withheld from the context window for the generated answer, and
    /// the per-request response cap.
    var outputReserveTokens: Int {
        switch self {
        case .meetingSummary: return 1_200
        case .transcriptCleanup: return 1_500
        }
    }

    /// True when a chunk's answer can be as long as its input, so chunk inputs
    /// must themselves fit the response headroom.
    var answerMirrorsInput: Bool { self == .transcriptCleanup }

    /// Extraction instructions for the map step of a long summary request.
    /// The final pass uses the caller's summary instructions instead.
    static let extractionInstructions = """
    You are extracting notes from one part of a meeting transcript. Capture concrete facts: names, numbers, dates, decisions, owners, open questions, and action items. Keep specifics instead of generalizing into themes, and never invent facts. Return only concise markdown bullets.
    """

    /// Instructions used when extracted notes must be shrunk further before the
    /// final summary pass.
    static let condensationInstructions = """
    Condense these extracted meeting notes without losing concrete detail: keep every name, number, date, decision, owner, and action item, and drop only repetition. Return only the condensed notes as markdown bullets.
    """

    /// Instructions for one chunk in the map step.
    func mapInstructions(callerInstructions: String, part: Int, total: Int) -> String {
        let base: String
        switch self {
        case .meetingSummary:
            base = Self.extractionInstructions
        case .transcriptCleanup:
            base = callerInstructions + "\n\nClean only the text you are given. Keep every statement in the original order: do not summarize, shorten, merge, reorder, or drop content, and do not add commentary. Return only the cleaned text."
        }
        guard total > 1 else { return base }
        return base + "\n\nThis is part \(part) of \(total) of the input. Process only this part."
    }

    /// Material handed to the final summary pass.
    static func reducePrompt(_ notes: String) -> String {
        "Notes extracted from every part of the meeting transcript, in order:\n\n\(notes)\n\nWrite the final meeting notes from these extracts."
    }
}

// MARK: - Map / reduce driver

/// Drives chunked generation through an injected model call, so chunk order,
/// content preservation, and the reduction cap are testable without a live
/// system model.
struct AppleIntelligenceChunkedGenerator: Sendable {
    /// Maximum number of extra reduction passes before the request fails.
    static let maximumReductionPasses = 3

    typealias CountTokens = @Sendable (_ text: String) async throws -> Int
    typealias Generate = @Sendable (_ instructions: String, _ prompt: String) async throws -> String

    let mode: AppleIntelligenceGenerationMode
    let budget: AppleIntelligenceBudget
    let countTokens: CountTokens
    let generate: Generate

    /// Returns the final text for `chunks`, which must be ordered, lossless
    /// slices of the original prompt.
    func run(chunks: [String], instructions: String) async throws -> String {
        switch mode {
        case .meetingSummary:
            return try await summarize(chunks: chunks, instructions: instructions)
        case .transcriptCleanup:
            return try await clean(chunks: chunks, instructions: instructions)
        }
    }

    /// Cleans every chunk in order and concatenates the results. Nothing is
    /// summarized away: a chunk the model cannot clean fails the request.
    private func clean(chunks: [String], instructions: String) async throws -> String {
        let orderedChunks = try await verified(chunks)
        var cleaned: [String] = []
        cleaned.reserveCapacity(orderedChunks.count)
        for (index, chunk) in orderedChunks.enumerated() {
            let output = try await generate(
                mode.mapInstructions(callerInstructions: instructions, part: index + 1, total: orderedChunks.count),
                chunk
            )
            cleaned.append(try trimmedOutput(output))
        }
        return cleaned.joined(separator: "\n")
    }

    /// Maps each chunk to factual notes, then reduces those notes under the
    /// caller's original summary instructions.
    private func summarize(chunks: [String], instructions: String) async throws -> String {
        let orderedChunks = try await verified(chunks)
        var notes: [String] = []
        notes.reserveCapacity(orderedChunks.count)
        for (index, chunk) in orderedChunks.enumerated() {
            let output = try await generate(
                mode.mapInstructions(callerInstructions: instructions, part: index + 1, total: orderedChunks.count),
                chunk
            )
            notes.append(try trimmedOutput(output))
        }

        var material = notes.joined(separator: "\n\n")
        var passes = 0
        while passes < Self.maximumReductionPasses, try await fits(material) == false {
            material = try await condense(material)
            passes += 1
        }
        guard try await fits(material) else {
            throw AppleIntelligenceError.contextOverflow(contextSize: budget.contextSize)
        }
        return try trimmedOutput(try await generate(instructions, AppleIntelligenceGenerationMode.reducePrompt(material)))
    }

    /// Shrinks extracted notes one pass further, splitting them when a single
    /// request no longer fits. Pieces are verified by real token count, so dense
    /// notes the character splitter left whole are still broken up before any
    /// condensation request is sent.
    private func condense(_ material: String) async throws -> String {
        let planned = AppleIntelligenceChunker.chunks(
            of: material,
            maxCharacters: budget.chunkCharacters(for: mode)
        )
        let pieces = try await verified(planned)
        guard pieces.count > 1 else {
            throw AppleIntelligenceError.contextOverflow(contextSize: budget.contextSize)
        }
        var condensed: [String] = []
        condensed.reserveCapacity(pieces.count)
        for piece in pieces {
            let output = try await generate(AppleIntelligenceGenerationMode.condensationInstructions, piece)
            condensed.append(try trimmedOutput(output))
        }
        return condensed.joined(separator: "\n")
    }

    /// Splits chunks that the character budget could not keep inside the
    /// context window, measuring the real token count so a chunk the
    /// conservative splitter left whole is still broken up before it reaches
    /// the model. Order and content are preserved; a chunk that cannot be split
    /// small enough fails the request instead of being sent oversized.
    private func verified(_ chunks: [String]) async throws -> [String] {
        var verified: [String] = []
        verified.reserveCapacity(chunks.count)
        for chunk in chunks {
            if try await fitsChunk(chunk) {
                verified.append(chunk)
                continue
            }
            verified.append(contentsOf: try await splitByTokenBudget(chunk))
        }
        return verified
    }

    /// Largest fitting pieces of an oversized chunk, by binary search on the
    /// real token count. Token counts grow with prefix length, so the search
    /// only ever accepts a piece it measured as fitting.
    private func splitByTokenBudget(_ text: String) async throws -> [String] {
        var pieces: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let remaining = String(text[start...])
            if try await fitsChunk(remaining) {
                pieces.append(remaining)
                break
            }
            guard let end = try await largestFittingPrefixEnd(in: text, from: start) else {
                throw AppleIntelligenceError.contextOverflow(contextSize: budget.contextSize)
            }
            pieces.append(String(text[start..<end]))
            start = end
        }
        return pieces
    }

    /// Largest Character boundary past `start` whose prefix fits the chunk
    /// budget, or `nil` when even one Character is too large.
    private func largestFittingPrefixEnd(in text: String, from start: String.Index) async throws -> String.Index? {
        var low = 1
        var high = text.distance(from: start, to: text.endIndex)
        var best: String.Index?
        while low <= high {
            let middle = low + (high - low) / 2
            guard let end = text.index(start, offsetBy: middle, limitedBy: text.endIndex) else { break }
            if try await fitsChunk(String(text[start..<end])) {
                best = end
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return best
    }

    private func fits(_ text: String) async throws -> Bool {
        budget.fits(tokens: try await countTokens(text))
    }

    private func fitsChunk(_ text: String) async throws -> Bool {
        budget.fitsChunk(tokens: try await countTokens(text), mode: mode)
    }

    private func trimmedOutput(_ output: String) throws -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppleIntelligenceError.emptyResponse }
        return trimmed
    }
}

// MARK: - Backend

/// On-device Apple Intelligence backend shared by meeting summaries and
/// transcript cleanup. Every FoundationModels import and call lives in this
/// file, behind `#if canImport` plus a runtime macOS 27 gate.
enum AppleIntelligenceBackend {
    /// Stable persisted identifier. It is written to `AppConfig`, so it must
    /// never change.
    static let backend = "apple_intelligence"
    static let label = "Apple Intelligence (On-Device)"

    static let privacyDescription = "Runs on this Mac with Apple's on-device model. No account or API key is needed, and text never leaves the device."

    /// Live availability. Synchronous and safe to call from settings and
    /// controller code.
    static var status: AppleIntelligenceStatus {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            return foundationModelsStatus()
        }
        #endif
        return .requiresNewerOperatingSystem
    }

    /// Generates trimmed, non-empty text for `instructions` + `userPrompt`.
    ///
    /// Short prompts use one request. Long prompts are chunked: summaries map
    /// to factual notes and reduce under `instructions`; cleanup cleans ordered
    /// chunks and concatenates them without dropping content.
    static func generate(
        instructions: String,
        userPrompt: String,
        mode: AppleIntelligenceGenerationMode,
        logCategory: String
    ) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            return try await generateWithFoundationModels(
                instructions: instructions,
                userPrompt: userPrompt,
                mode: mode,
                logCategory: logCategory
            )
        }
        #endif
        throw AppleIntelligenceError.unavailable(.requiresNewerOperatingSystem)
    }
}

#if canImport(FoundationModels)
@available(macOS 27.0, *)
extension AppleIntelligenceBackend {
    private static func foundationModelsStatus() -> AppleIntelligenceStatus {
        switch SystemLanguageModel.default.availability {
        case .available:
            return AppleIntelligenceAvailabilityMapper.status(isAvailable: true, reason: nil)
        case let .unavailable(reason):
            return AppleIntelligenceAvailabilityMapper.status(isAvailable: false, reason: unavailableReason(reason))
        }
    }

    private static func unavailableReason(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> AppleIntelligenceUnavailableReason {
        switch reason {
        case .deviceNotEligible: return .deviceNotEligible
        case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
        case .modelNotReady: return .modelNotReady
        default: return .unrecognized
        }
    }

    private static func generateWithFoundationModels(
        instructions: String,
        userPrompt: String,
        mode: AppleIntelligenceGenerationMode,
        logCategory: String
    ) async throws -> String {
        let availability = AppleIntelligenceBackend.status
        guard availability.isAvailable else {
            throw AppleIntelligenceError.unavailable(availability)
        }

        let model = SystemLanguageModel.default
        let budget = AppleIntelligenceBudget(
            contextSize: model.contextSize,
            instructionsTokens: await measuredTokens(of: instructions, model: model),
            outputReserveTokens: mode.outputReserveTokens
        )
        let promptTokens = await measuredTokens(of: userPrompt, model: model)
        let chunks = AppleIntelligencePromptPlanner.chunks(of: userPrompt, budget: budget, mode: mode)

        let text: String
        if AppleIntelligencePromptPlanner.requiresChunking(promptTokens: promptTokens, budget: budget, mode: mode) {
            fputs("[\(logCategory)] Apple Intelligence chunked request: \(chunks.count) parts of \(userPrompt.count) characters\n", stderr)
            let generator = AppleIntelligenceChunkedGenerator(
                mode: mode,
                budget: budget,
                countTokens: { await measuredTokens(of: $0, model: model) },
                generate: { instructions, prompt in
                    try await respond(instructions: instructions, prompt: prompt, mode: mode)
                }
            )
            text = try await generator.run(chunks: chunks, instructions: instructions)
        } else {
            fputs("[\(logCategory)] Apple Intelligence request: \(promptTokens) prompt tokens, \(budget.inputTokens) token budget\n", stderr)
            text = try await respond(instructions: instructions, prompt: userPrompt, mode: mode)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppleIntelligenceError.emptyResponse
        }
        return trimmed
    }

    /// One `LanguageModelSession` request. Sessions are per request, so no
    /// transcript is carried between chunks.
    private static func respond(
        instructions: String,
        prompt: String,
        mode: AppleIntelligenceGenerationMode
    ) async throws -> String {
        do {
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(maximumResponseTokens: mode.outputReserveTokens)
            )
            return response.content
        } catch {
            // `LanguageModelError` ships in the macOS 27 SDK only, and this
            // adapter must also build against the macOS 26.5 SDK, so framework
            // failures map generically here. Proactive token budgeting keeps
            // each request inside the context window.
            throw AppleIntelligenceError.generationFailed(error.localizedDescription)
        }
    }

    /// Real token counts when the tokenizer answers, a conservative character
    /// estimate when it does not.
    private static func measuredTokens(of text: String, model: SystemLanguageModel) async -> Int {
        if let tokens = try? await model.tokenCount(for: text) {
            return tokens
        }
        return AppleIntelligenceBudget.estimatedTokens(for: text)
    }
}
#endif
