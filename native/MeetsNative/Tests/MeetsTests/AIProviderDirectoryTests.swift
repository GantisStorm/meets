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
