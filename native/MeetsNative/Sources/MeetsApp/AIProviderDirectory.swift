import Foundation
import MeetsCore

/// Every AI service Meets can send a meeting summary or a transcript cleanup to.
///
/// The app already stored each provider's settings, but "is this provider
/// usable right now" had three separate answers — the meeting detail menu, the
/// settings rows, and the `hasApiKey` copy. They drifted: Ollama reported
/// usable with no URL, and the summary menu and the cleanup menu disagreed
/// about what a configured endpoint means. This type is the single answer.
enum AIProvider: String, CaseIterable, Identifiable {
    /// Ordered the way the AI settings page lists them: the accounts first,
    /// then the endpoints the user points at a server.
    case chatGPT
    case openAI
    case openRouter
    case customLLM
    case acpAgent
    case appleIntelligence
    case ollama
    case lmStudio

    var id: String { rawValue }

    /// Reuses the labels the rest of the app already prints, so a settings row
    /// and the menu entry that picks the same provider can never disagree.
    var label: String {
        summaryOption?.label ?? cleanupBackend?.label ?? rawValue
    }

    /// Providers that talk to a server the user runs on this Mac: no account,
    /// no key, just a URL.
    var isLocalServer: Bool {
        self == .ollama || self == .lmStudio
    }

    /// The summary option this provider answers to, when it can write summaries.
    var summaryOption: MeetingSummaryBackendOption? {
        switch self {
        case .chatGPT: return .chatGPT
        case .openAI: return .openAI
        case .openRouter: return .openRouter
        case .customLLM: return .customLLM
        case .acpAgent: return .acpAgent
        case .appleIntelligence: return .appleIntelligence
        case .ollama: return .ollama
        case .lmStudio: return .lmStudio
        }
    }

    /// The cleanup backend this provider answers to. Cleanup also has an
    /// on-device model, which belongs to no provider and is not represented here.
    var cleanupBackend: TranscriptCleanupBackendOption? {
        guard let llmBackend = LLMBackendOption.resolved(summaryOption?.backend) else { return nil }
        return .hosted(llmBackend)
    }

    init?(summaryOption: MeetingSummaryBackendOption) {
        guard let match = AIProvider.allCases.first(where: { $0.summaryOption == summaryOption }) else {
            return nil
        }
        self = match
    }

    init?(cleanupBackend: TranscriptCleanupBackendOption) {
        // Match on the option itself rather than round-tripping through a
        // backend string: `resolved(_:)` answers an unknown string with ChatGPT,
        // which would silently mislabel a backend this list does not know.
        guard let match = AIProvider.allCases.first(where: { $0.cleanupBackend == cleanupBackend }) else {
            return nil
        }
        self = match
    }
}

/// The credentials the directory cannot read from `AppConfig` alone.
///
/// Resolved once by the controller and passed in, so `isConnected` stays a pure
/// function of settings — a test can decide every input instead of depending on
/// the machine's environment or credential files.
struct AIConnectionState: Equatable {
    var isChatGPTAuthenticated = false
    var isOpenRouterAuthenticated = false
    /// The OpenRouter key the request path would use: environment, credential
    /// file, or the legacy config field, in that order.
    var openRouterAPIKey = ""
    /// `OPENAI_API_KEY` when the environment supplies one.
    var environmentOpenAIAPIKey = ""
    /// ACP agents whose launcher resolves on this Mac, refreshed with every
    /// snapshot — discovery is a handful of stat calls. For ACP this is what
    /// "connected" means: the agent is chosen later, next to its model and
    /// reasoning, rather than being the thing that makes the provider appear.
    var installedACPAgents: [ACPAgentCommand] = []
}

enum AIProviderDirectory {
    /// What each request path actually requires. Ollama and LM Studio used to
    /// be exempt from this check; they are not, because a provider with no URL
    /// or no model fails the moment the user picks it.
    static func isConnected(
        _ provider: AIProvider,
        config: AppConfig,
        state: AIConnectionState
    ) -> Bool {
        switch provider {
        case .chatGPT:
            return state.isChatGPTAuthenticated
        case .openAI:
            return !resolvedOpenAIAPIKey(config: config, state: state).isEmpty
        case .openRouter:
            return state.isOpenRouterAuthenticated || !trimmed(state.openRouterAPIKey).isEmpty
        case .customLLM:
            let format = CustomLLMFormat(rawValue: config.customLLMFormat) ?? .openAI
            return !trimmed(config.customLLMModel).isEmpty
                && MeetingSummaryClient.resolveCustomLLMURL(config: config, format: format) != nil
                && (!MeetingSummaryClient.customLLMRequiresAPIKey(config: config)
                    || !trimmed(config.customLLMAPIKey).isEmpty)
        case .acpAgent:
            // An agent installed on this Mac makes the provider usable; a
            // command typed by hand counts too, because discovery only knows
            // the launchers it ships with.
            return !trimmed(config.acpAgentCommand).isEmpty || !state.installedACPAgents.isEmpty
        case .appleIntelligence:
            return AppleIntelligenceBackend.status.isAvailable
        case .ollama:
            return !trimmed(config.ollamaURL).isEmpty && !trimmed(config.ollamaModel).isEmpty
        case .lmStudio:
            return !trimmed(config.lmStudioURL).isEmpty && !trimmed(config.lmStudioModel).isEmpty
        }
    }

    /// The summary providers a picker may offer, in the app's canonical order.
    static func connectedSummaryProviders(
        config: AppConfig,
        state: AIConnectionState
    ) -> [MeetingSummaryBackendOption] {
        MeetingSummaryBackendOption.all.filter { option in
            guard let provider = AIProvider(summaryOption: option) else { return false }
            return isConnected(provider, config: config, state: state)
        }
    }

    /// The cleanup backends a picker may offer. The on-device model is always
    /// there — it needs no account — and Gemma 4 is left out because this build
    /// cannot run it.
    static func connectedCleanupBackends(
        config: AppConfig,
        state: AIConnectionState
    ) -> [TranscriptCleanupBackendOption] {
        TranscriptCleanupBackendOption.all.filter { option in
            guard !option.isGemma4LiteRT else { return false }
            if option.isLocal { return true }
            guard let provider = AIProvider(cleanupBackend: option) else { return false }
            return isConnected(provider, config: config, state: state)
        }
    }

    /// `OPENAI_API_KEY` wins over the stored key, matching the summary and
    /// cleanup request paths.
    static func resolvedOpenAIAPIKey(config: AppConfig, state: AIConnectionState) -> String {
        let configured = trimmed(config.openAIAPIKey)
        return configured.isEmpty ? trimmed(state.environmentOpenAIAPIKey) : configured
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension MeetsController {
    /// Snapshot of everything `AIProviderDirectory` needs that does not live in
    /// `AppConfig`.
    var aiConnectionState: AIConnectionState {
        AIConnectionState(
            isChatGPTAuthenticated: appState.isChatGPTAuthenticated,
            isOpenRouterAuthenticated: appState.isOpenRouterAuthenticated,
            openRouterAPIKey: OpenRouterCredentialResolver.resolvedAPIKey(
                legacyAPIKey: config.openRouterAPIKey
            ),
            environmentOpenAIAPIKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "",
            installedACPAgents: ACPAgentDiscovery.discoveredCommands()
        )
    }
}
