import Foundation
import Testing
@testable import MeetsApp

/// The directory decides which providers the menus and the AI settings page may
/// offer, so these cases pin the rules per request path rather than the shape of
/// the code that implements them.
@Suite("AI provider connections")
struct AIProviderDirectoryTests {

    private func connected(_ provider: AIProvider, _ config: AppConfig, _ state: AIConnectionState) -> Bool {
        AIProviderDirectory.isConnected(provider, config: config, state: state)
    }

    @Test("a fresh config connects only what needs no account")
    func freshConfigConnectsOnlyAccountlessProviders() {
        let config = AppConfig()
        let state = AIConnectionState()

        // Ollama ships with a local URL and a model, so it is usable out of the
        // box; LM Studio ships without a model and is not.
        #expect(connected(.ollama, config, state))
        #expect(!connected(.lmStudio, config, state))

        #expect(!connected(.chatGPT, config, state))
        #expect(!connected(.openAI, config, state))
        #expect(!connected(.openRouter, config, state))
        #expect(!connected(.customLLM, config, state))
        #expect(!connected(.acpAgent, config, state))
        #expect(connected(.appleIntelligence, config, state) == AppleIntelligenceBackend.status.isAvailable)
    }

    @Test("OpenAI connects from the stored key or the environment key")
    func openAIConnectsFromEitherKey() {
        var config = AppConfig()
        var state = AIConnectionState()
        #expect(!connected(.openAI, config, state))

        state.environmentOpenAIAPIKey = "sk-env"
        #expect(connected(.openAI, config, state))

        // The stored key wins, and whitespace alone is not a key.
        state.environmentOpenAIAPIKey = ""
        config.openAIAPIKey = "   "
        #expect(!connected(.openAI, config, state))

        config.openAIAPIKey = "sk-stored"
        #expect(connected(.openAI, config, state))
    }

    @Test("OpenRouter connects from the account or a resolved key")
    func openRouterConnectsFromAccountOrKey() {
        let config = AppConfig()
        var state = AIConnectionState()
        #expect(!connected(.openRouter, config, state))

        state.isOpenRouterAuthenticated = true
        #expect(connected(.openRouter, config, state))

        state.isOpenRouterAuthenticated = false
        state.openRouterAPIKey = "sk-or-v1-resolved"
        #expect(connected(.openRouter, config, state))
    }

    @Test("a custom endpoint needs a model, and a key only when it speaks Anthropic")
    func customEndpointRules() {
        var config = AppConfig()
        let state = AIConnectionState()
        config.customLLMURL = "https://example.test/v1/chat/completions"
        #expect(!connected(.customLLM, config, state))

        config.customLLMModel = "gpt-oss"
        #expect(connected(.customLLM, config, state))

        config.customLLMFormat = CustomLLMFormat.anthropic.rawValue
        #expect(!connected(.customLLM, config, state))

        config.customLLMAPIKey = "sk-ant"
        #expect(connected(.customLLM, config, state))
    }

    @Test("a local server needs both a URL and a model")
    func localServerRules() {
        var config = AppConfig()
        let state = AIConnectionState()

        config.ollamaURL = "  "
        #expect(!connected(.ollama, config, state))

        config.ollamaURL = "http://localhost:11434"
        config.ollamaModel = ""
        #expect(!connected(.ollama, config, state))

        config.ollamaModel = "qwen3.5"
        #expect(connected(.ollama, config, state))

        config.lmStudioModel = "qwen2.5-7b-instruct"
        #expect(connected(.lmStudio, config, state))
    }

    @Test("ACP connects when an agent this Mac can run exists, or a command is set")
    func acpConnectionRules() {
        var config = AppConfig()
        var state = AIConnectionState()
        #expect(!connected(.acpAgent, config, state))

        // Discovery is what makes the provider usable: the agent itself is
        // picked later, beside its model and reasoning.
        state.installedACPAgents = [ACPAgentCommand(label: "Codex", command: "codex-acp")]
        #expect(connected(.acpAgent, config, state))

        // An agent typed by hand counts too, since discovery only knows the
        // launchers it ships with.
        state.installedACPAgents = []
        config.acpAgentCommand = "  my-agent --acp  "
        #expect(connected(.acpAgent, config, state))
    }

    @Test("the summary list offers only connected providers, in canonical order")
    func summaryListFiltersAndOrders() {
        var config = AppConfig()
        var state = AIConnectionState()
        config.openAIModel = "gpt-5.5"
        config.openAIAPIKey = "sk-stored"
        config.acpAgentCommand = "codex acp"

        // Apple Intelligence is connected wherever the OS can run it, so the
        // expectation is derived rather than hard-coded to this machine.
        var expected: Set<String> = [.openAI, .ollama, .acpAgent].map(\.backend)
        if AppleIntelligenceBackend.status.isAvailable {
            expected.insert(MeetingSummaryBackendOption.appleIntelligence.backend)
        } else {
            expected.remove(MeetingSummaryBackendOption.appleIntelligence.backend)
        }
        let canonical = MeetingSummaryBackendOption.all.map(\.backend)
        #expect(AIProviderDirectory.connectedSummaryProviders(config: config, state: state).map(\.backend)
            == canonical.filter(expected.contains))

        state.isChatGPTAuthenticated = true
        expected.insert(MeetingSummaryBackendOption.chatGPT.backend)
        #expect(AIProviderDirectory.connectedSummaryProviders(config: config, state: state).map(\.backend)
            == canonical.filter(expected.contains))
    }

    @Test("the cleanup list keeps the on-device model and never Gemma 4")
    func cleanupListKeepsLocalAndDropsGemma() {
        var config = AppConfig()
        config.openAIAPIKey = "sk-stored"

        let backends = AIProviderDirectory.connectedCleanupBackends(
            config: config,
            state: AIConnectionState()
        )

        #expect(backends.first == .local)
        #expect(!backends.contains(.gemma4LiteRT))
        #expect(backends.contains(.hosted(.openAI)))
        #expect(!backends.contains(.hosted(.openRouter)))
    }

    @Test("every provider round-trips through its summary and cleanup options")
    func providerMappingRoundTrips() {
        for provider in AIProvider.allCases {
            guard let summaryOption = provider.summaryOption else {
                Issue.record("\(provider.rawValue) has no summary option")
                continue
            }
            #expect(AIProvider(summaryOption: summaryOption) == provider)

            guard let cleanupBackend = provider.cleanupBackend else {
                Issue.record("\(provider.rawValue) has no cleanup backend")
                continue
            }
            #expect(AIProvider(cleanupBackend: cleanupBackend) == provider)
            #expect(cleanupBackend.label == provider.label)
        }
    }
}

/// The fallback policy decides whether a failed attempt is retried, and on
/// what. These cases pin the "unknown or equal means no fallback" rule, which
/// is the one that keeps a typo in the settings from silently rerunning the
/// provider that just failed.
@Suite("AI fallback policy")
struct AIFallbackPolicyTests {

    /// `AppConfig` is not `Equatable`, so "no fallback" is read off the backend
    /// the policy would have switched. The policy always sets that field on a
    /// returned config, so a `nil` backend means no fallback.
    private func summaryFallbackBackend(_ stored: AppConfig, _ attempted: AppConfig) -> String? {
        AIFallbackPolicy.fallbackSummaryConfig(from: stored, attempted: attempted)?.meetingSummaryBackend
    }

    private func cleanupFallbackBackend(_ stored: AppConfig, _ attempted: AppConfig) -> String? {
        AIFallbackPolicy.fallbackCleanupConfig(from: stored, attempted: attempted)?.postProcessorBackend
    }

    @Test("nothing configured, or whitespace, is no fallback")
    func blankFallbackIsNoFallback() {
        let config = AppConfig()
        #expect(summaryFallbackBackend(config, config) == nil)
        #expect(cleanupFallbackBackend(config, config) == nil)

        var spaced = config
        spaced.fallbackSummaryBackend = "   "
        spaced.fallbackPostProcessorBackend = "\n"
        #expect(summaryFallbackBackend(spaced, spaced) == nil)
        #expect(cleanupFallbackBackend(spaced, spaced) == nil)
    }

    @Test("an unknown value means no fallback rather than a silent default")
    func unknownFallbackIsNoFallback() {
        var config = AppConfig()
        config.meetingSummaryBackend = MeetingSummaryBackendOption.openAI.backend
        config.postProcessorBackend = TranscriptCleanupBackendOption.local.backend
        config.fallbackSummaryBackend = "nope"
        config.fallbackPostProcessorBackend = "nope"

        #expect(summaryFallbackBackend(config, config) == nil)
        #expect(cleanupFallbackBackend(config, config) == nil)

        // Both resolvers answer an unknown value with their default, so the
        // name of that default stays a valid choice when it is written out.
        config.fallbackSummaryBackend = MeetingSummaryBackendOption.chatGPT.backend
        #expect(summaryFallbackBackend(config, config) == MeetingSummaryBackendOption.chatGPT.backend)
        #expect(cleanupFallbackBackend(config, config) == nil)
    }

    @Test("a fallback equal to the backend that just failed is no fallback")
    func equalFallbackIsNoFallback() {
        var config = AppConfig()
        config.meetingSummaryBackend = MeetingSummaryBackendOption.openAI.backend
        config.fallbackSummaryBackend = MeetingSummaryBackendOption.openAI.backend
        config.postProcessorBackend = TranscriptCleanupBackendOption.local.backend
        config.fallbackPostProcessorBackend = TranscriptCleanupBackendOption.local.backend

        #expect(summaryFallbackBackend(config, config) == nil)
        #expect(cleanupFallbackBackend(config, config) == nil)

        config.fallbackPostProcessorBackend = "  \(TranscriptCleanupBackendOption.local.backend)  "
        #expect(cleanupFallbackBackend(config, config) == nil)
    }

    @Test("a configured summary fallback switches only the backend")
    func summaryFallbackSwitchesOnlyTheBackend() {
        var stored = AppConfig()
        stored.meetingSummaryBackend = MeetingSummaryBackendOption.openAI.backend
        stored.openAIModel = "gpt-5.5"
        stored.chatGPTModel = "gpt-5.5-pro"
        stored.defaultMeetingTemplateID = "custom-template"
        stored.fallbackSummaryBackend = "  \(MeetingSummaryBackendOption.chatGPT.backend)  "

        // The attempted snapshot carries the failed provider's per-request
        // model; none of it belongs to the fallback.
        var attempted = stored
        attempted.chatGPTModel = "snapshot-model"

        let fallback = AIFallbackPolicy.fallbackSummaryConfig(from: stored, attempted: attempted)
        #expect(fallback?.meetingSummaryBackend == MeetingSummaryBackendOption.chatGPT.backend)
        #expect(fallback?.chatGPTModel == "gpt-5.5-pro")
        #expect(fallback?.openAIModel == "gpt-5.5")
        #expect(fallback?.defaultMeetingTemplateID == "custom-template")
    }

    @Test("a configured cleanup fallback switches only the backend")
    func cleanupFallbackSwitchesOnlyTheBackend() {
        var stored = AppConfig()
        stored.postProcessorBackend = TranscriptCleanupBackendOption.local.backend
        stored.postProcessorOpenAIModel = "gpt-5.5"
        stored.postProcessorSystemPrompt = "Tidy the transcript."
        stored.activePostProcessorId = "local-s1-mini"
        stored.fallbackPostProcessorBackend = TranscriptCleanupBackendOption.hosted(.openAI).backend

        var attempted = stored
        attempted.postProcessorOpenAIModel = "snapshot-model"

        let fallback = AIFallbackPolicy.fallbackCleanupConfig(from: stored, attempted: attempted)
        #expect(fallback?.postProcessorBackend == TranscriptCleanupBackendOption.hosted(.openAI).backend)
        #expect(fallback?.postProcessorOpenAIModel == "gpt-5.5")
        #expect(fallback?.postProcessorSystemPrompt == "Tidy the transcript.")
        #expect(fallback?.activePostProcessorId == "local-s1-mini")
    }

    /// Two distinct failures, so a rethrown first error cannot be mistaken for
    /// the fallback's own failure.
    private enum SummaryAttemptFailure: Error, Equatable {
        case primary
        case fallback
    }

    @Test("a configured fallback is attempted once and its value wins")
    func summaryFallbackReturnsTheFallbackValue() async throws {
        var stored = AppConfig()
        stored.meetingSummaryBackend = MeetingSummaryBackendOption.openAI.backend
        stored.fallbackSummaryBackend = MeetingSummaryBackendOption.chatGPT.backend

        var backends: [String] = []
        let notes = try await AIFallbackPolicy.withSummaryFallback(config: stored) { attemptConfig in
            backends.append(attemptConfig.meetingSummaryBackend)
            guard attemptConfig.meetingSummaryBackend == MeetingSummaryBackendOption.chatGPT.backend else {
                throw SummaryAttemptFailure.primary
            }
            return "fallback notes"
        }

        #expect(notes == "fallback notes")
        #expect(backends == [
            MeetingSummaryBackendOption.openAI.backend,
            MeetingSummaryBackendOption.chatGPT.backend
        ])
    }

    @Test("no configured fallback rethrows the first error without a second attempt")
    func summaryWithoutFallbackRethrowsTheFirstError() async {
        var stored = AppConfig()
        stored.meetingSummaryBackend = MeetingSummaryBackendOption.openAI.backend

        var attempts = 0
        var observed: (any Error)?
        do {
            _ = try await AIFallbackPolicy.withSummaryFallback(config: stored) { (_: AppConfig) -> String in
                attempts += 1
                throw SummaryAttemptFailure.primary
            }
        } catch {
            observed = error
        }

        #expect(observed as? SummaryAttemptFailure == .primary)
        #expect(attempts == 1)
    }

    @Test("a fallback that fails too rethrows the first error, not the fallback's")
    func summaryFallbackFailureRethrowsTheFirstError() async {
        var stored = AppConfig()
        stored.meetingSummaryBackend = MeetingSummaryBackendOption.openAI.backend
        stored.fallbackSummaryBackend = MeetingSummaryBackendOption.chatGPT.backend

        var backends: [String] = []
        var observed: (any Error)?
        do {
            _ = try await AIFallbackPolicy.withSummaryFallback(config: stored) { attemptConfig -> String in
                backends.append(attemptConfig.meetingSummaryBackend)
                throw attemptConfig.meetingSummaryBackend == MeetingSummaryBackendOption.chatGPT.backend
                    ? SummaryAttemptFailure.fallback
                    : SummaryAttemptFailure.primary
            }
        } catch {
            observed = error
        }

        #expect(observed as? SummaryAttemptFailure == .primary)
        #expect(backends == [
            MeetingSummaryBackendOption.openAI.backend,
            MeetingSummaryBackendOption.chatGPT.backend
        ])
    }

    @Test("the first attempt runs on the stored config, not the fallback's")
    func firstSummaryAttemptUsesTheStoredConfig() async throws {
        var stored = AppConfig()
        stored.meetingSummaryBackend = MeetingSummaryBackendOption.chatGPT.backend
        stored.chatGPTModel = "stored-chatgpt-model"
        stored.fallbackSummaryBackend = MeetingSummaryBackendOption.openAI.backend

        var handed: AppConfig?
        let notes = try await AIFallbackPolicy.withSummaryFallback(config: stored) { attemptConfig in
            handed = attemptConfig
            return "notes"
        }

        #expect(notes == "notes")
        #expect(handed?.meetingSummaryBackend == MeetingSummaryBackendOption.chatGPT.backend)
        #expect(handed?.chatGPTModel == "stored-chatgpt-model")
        #expect(handed?.fallbackSummaryBackend == MeetingSummaryBackendOption.openAI.backend)
    }
}
