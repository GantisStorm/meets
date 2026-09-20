import Testing
@testable import MeetsApp

/// One cleanup request can run through a provider other than the stored
/// default, so these cases pin which model field each backend fills, that the
/// on-device backends fill none, and that the stored config is left alone.
@Suite("Transcript cleanup configuration")
struct TranscriptCleanupConfigurationTests {

    /// Every model field a cleanup override could write. Gemma 4 and Apple
    /// Intelligence keep no cleanup model of their own, and Gemma 4's field
    /// belongs to the dictation picker, so an override must not touch it.
    private static let modelFields: [WritableKeyPath<AppConfig, String>] = [
        \.postProcessorGemmaModel,
        \.postProcessorChatGPTModel,
        \.postProcessorOpenAIModel,
        \.postProcessorOpenRouterModel,
        \.postProcessorOllamaModel,
        \.postProcessorLMStudioModel,
        \.postProcessorCustomLLMModel,
    ]

    /// Each hosted backend and the single field it owns.
    private static let hostedSlots: [(option: TranscriptCleanupBackendOption,
                                      field: WritableKeyPath<AppConfig, String>)] = [
        (.hosted(.chatGPT), \.postProcessorChatGPTModel),
        (.hosted(.openAI), \.postProcessorOpenAIModel),
        (.hosted(.openRouter), \.postProcessorOpenRouterModel),
        (.hosted(.ollama), \.postProcessorOllamaModel),
        (.hosted(.lmStudio), \.postProcessorLMStudioModel),
        (.hosted(.customLLM), \.postProcessorCustomLLMModel),
    ]

    /// Backends that run no user-selectable model.
    private static let onDeviceOptions: [TranscriptCleanupBackendOption] = [
        .local, .gemma4LiteRT, .appleIntelligence,
    ]

    private static let storedPrompt = "Keep the speaker's wording."
    private static let storedProcessorId = "cleanup-meeting-notes"

    /// Stored config that routes cleanup through Local Model, with a distinct
    /// saved model in every field and a prompt of its own, so a field the
    /// override fills or drops is visible in the comparison.
    private static func storedConfig() -> AppConfig {
        var config = AppConfig()
        config.postProcessorBackend = TranscriptCleanupBackendOption.local.backend
        config.postProcessorSystemPrompt = storedPrompt
        config.activePostProcessorId = storedProcessorId
        for (index, field) in modelFields.enumerated() {
            config[keyPath: field] = "stored-model-\(index)"
        }
        return config
    }

    private static func models(_ config: AppConfig) -> [String] {
        modelFields.map { config[keyPath: $0] }
    }

    private static func models(
        _ config: AppConfig,
        except field: WritableKeyPath<AppConfig, String>
    ) -> [String] {
        modelFields.filter { $0 != field }.map { config[keyPath: $0] }
    }

    @Test("a hosted backend writes the model into its own field and switches the backend")
    func hostedBackendWritesItsOwnModelField() {
        for slot in Self.hostedSlots {
            let source = Self.storedConfig()
            let copy = slot.option.cleanupConfiguration(from: source, model: "override-model")

            #expect(copy.postProcessorBackend == slot.option.backend)
            #expect(copy[keyPath: slot.field] == "override-model")
            // Every other slot keeps the value the stored config held.
            #expect(Self.models(copy, except: slot.field) == Self.models(source, except: slot.field))
        }
    }

    @Test("an on-device backend switches the backend and writes no model field")
    func onDeviceBackendWritesNoModelField() {
        for option in Self.onDeviceOptions {
            let source = Self.storedConfig()
            let copy = option.cleanupConfiguration(from: source, model: "override-model")

            #expect(copy.postProcessorBackend == option.backend)
            #expect(Self.models(copy) == Self.models(source))
        }
    }

    @Test("the stored config keeps its backend and models after the override")
    func storedConfigIsNotMutated() {
        for option in Self.hostedSlots.map(\.option) + Self.onDeviceOptions {
            var source = Self.storedConfig()
            let storedModels = Self.models(source)

            _ = option.cleanupConfiguration(from: source, model: "override-model")

            #expect(source.postProcessorBackend == TranscriptCleanupBackendOption.local.backend)
            #expect(Self.models(source) == storedModels)
        }
    }

    @Test("the copy carries over the prompt and processor the override does not set")
    func copyCarriesOverTheRest() {
        for option in Self.hostedSlots.map(\.option) + Self.onDeviceOptions {
            let source = Self.storedConfig()
            let copy = option.cleanupConfiguration(from: source, model: "override-model")

            #expect(copy.postProcessorSystemPrompt == Self.storedPrompt)
            #expect(copy.postProcessorSystemPrompt == source.postProcessorSystemPrompt)
            #expect(copy.activePostProcessorId == Self.storedProcessorId)
            #expect(copy.activePostProcessorId == source.activePostProcessorId)
        }
    }
}
