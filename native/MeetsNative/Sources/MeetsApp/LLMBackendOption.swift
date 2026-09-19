import Foundation

struct LLMBackendOption: Equatable, Identifiable {
    let backend: String
    let label: String

    var id: String { backend }

    static let chatGPT = LLMBackendOption(backend: "chatgpt", label: "ChatGPT")
    static let openAI = LLMBackendOption(backend: "openai", label: "OpenAI")
    static let openRouter = LLMBackendOption(backend: "openrouter", label: "OpenRouter")
    static let ollama = LLMBackendOption(backend: "ollama", label: "Ollama")
    static let lmStudio = LLMBackendOption(backend: "lmstudio", label: "LM Studio")
    static let customLLM = LLMBackendOption(backend: "custom_llm", label: "Custom LLM")
    static let acpAgent = LLMBackendOption(backend: "acp_agent", label: "Agent (ACP)")
    static let appleIntelligence = LLMBackendOption(
        backend: AppleIntelligenceBackend.backend,
        label: AppleIntelligenceBackend.label
    )

    static let all: [LLMBackendOption] = [.chatGPT, .appleIntelligence, .openAI, .openRouter, .ollama, .lmStudio, .customLLM, .acpAgent]

    static func resolved(_ backend: String?) -> LLMBackendOption? {
        guard let backend else { return nil }
        return all.first { $0.backend == backend }
    }
}

struct TranscriptCleanupBackendOption: Equatable, Identifiable {
    let backend: String
    let label: String
    let llmBackend: LLMBackendOption?

    var id: String { backend }
    var isLocal: Bool { self == .local }
    var isGemma4LiteRT: Bool { self == .gemma4LiteRT }
    var isAppleIntelligence: Bool { self == .appleIntelligence }
    var isOnDevice: Bool { isLocal || isGemma4LiteRT || isAppleIntelligence }

    static let local = TranscriptCleanupBackendOption(
        backend: "local",
        label: "Local Model",
        llmBackend: nil
    )

    static let gemma4LiteRT = TranscriptCleanupBackendOption(
        backend: "gemma4-litert",
        label: "Gemma 4",
        llmBackend: nil
    )

    /// Apple Intelligence shares the LLM routing but needs no account, key, or
    /// model: it always runs the system on-device model.
    static var appleIntelligence: TranscriptCleanupBackendOption { .hosted(.appleIntelligence) }

    static func hosted(_ option: LLMBackendOption) -> TranscriptCleanupBackendOption {
        TranscriptCleanupBackendOption(
            backend: option.backend,
            label: option.label,
            llmBackend: option
        )
    }

    static let all: [TranscriptCleanupBackendOption] = [.local, .gemma4LiteRT] + LLMBackendOption.all.map(hosted)

    func isCompatible(with transcriptionBackend: BackendOption) -> Bool {
        !(isGemma4LiteRT && transcriptionBackend.backend == BackendOption.gemma4E2BLiteRT.backend)
    }

    /// Only the local S1-mini formatter is restricted to non-Bodhan input.
    func isCompatible(with transcriptionBackend: BackendOption, inputFormat: PostProcessorOption.InputFormat) -> Bool {
        isCompatible(with: transcriptionBackend)
            && !(self == .local && inputFormat == .s1Mini && transcriptionBackend.backend == "bodhan")
    }

    static func available(for transcriptionBackend: BackendOption) -> [TranscriptCleanupBackendOption] {
        all.filter { $0.isCompatible(with: transcriptionBackend) }
    }

    static func resolved(_ backend: String?) -> TranscriptCleanupBackendOption {
        guard let backend, let option = all.first(where: { $0.backend == backend }) else {
            return .local
        }
        return option
    }
}
