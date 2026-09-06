import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("DiagnosticIncident")
struct DiagnosticIncidentTests {
    private let metadata = DiagnosticAppMetadata(
        appVersion: "1.2.3",
        buildNumber: "456",
        bundleID: "com.muesli.dev",
        displayName: "MuesliDev",
        macOSVersion: "15.5.0",
        architecture: "arm64"
    )

    @Test("signature tokens collapse adjacent separators deterministically")
    func signatureTokensCollapseAdjacentSeparators() {
        #expect(DiagnosticErrorCatalog.signatureToken("Foo...Bar///Baz") == "foo_bar_baz")
    }

    @Test("nil underlying errors use app-state category and allowlisted signature")
    func nilErrorUsesAppStateCategory() {
        let incident = DiagnosticIncident(
            kind: .streamingDictationStartFailed,
            stage: .nemotronStreamingStart,
            backendOption: .nemotron35Multilingual,
            error: nil,
            metadata: metadata
        )

        #expect(incident.telemetryCategory == .appState)
        #expect(incident.errorFingerprint.signature == "streaming_controller_start_failed")
        #expect(incident.telemetryErrorID == "Muesli.Diagnostic.streaming_dictation_start_failed.streaming_controller_start_failed")
        #expect(incident.telemetryParameters["diagnostic.error_known"] == "true")
        #expect(incident.telemetryParameters["diagnostic.error_domain"] == nil)
    }

    @Test("Nemotron cases map directly to stable fingerprints")
    func nemotronCasesUseStableFingerprints() {
        let cases: [(Error, String, String)] = [
            (NemotronRNNTError.notLoaded, "nemotron_models_not_loaded", "0"),
            (NemotronRNNTError.downloadFailed("private download detail"), "nemotron_download_failed", "1"),
            (NemotronRNNTError.preprocessingFailed("private preprocessing detail"), "nemotron_preprocessing_failed", "2"),
            (NemotronRNNTError.decodingFailed("private decoding detail"), "nemotron_decoding_failed", "3"),
        ]

        for (error, signature, code) in cases {
            let fingerprint = DiagnosticErrorCatalog.fingerprint(
                for: error,
                kind: .streamingDictationRuntimeFailed,
                stage: .nemotronStreamingRuntime
            )
            #expect(fingerprint.signature == signature)
            #expect(fingerprint.safeDomain == "NemotronRNNTError")
            #expect(fingerprint.safeCode == code)
            #expect(!fingerprint.summary.contains("private"))
        }
    }

    @Test("recording save failure is classified as degraded output")
    func recordingSaveFailureIsDegraded() {
        let incident = DiagnosticIncident(
            kind: .meetingRecordingSaveFailed,
            stage: .saveMeetingRecording,
            error: NSError(domain: "MeetingRecordingWriter", code: 3),
            metadata: metadata
        )

        #expect(incident.userImpact == .degradedResult)
        #expect(incident.telemetryParameters["diagnostic.user_impact"] == "degraded_result")
    }

    @Test("meeting microphone failure is privacy-safe degraded telemetry")
    func meetingMicrophoneFailureIsDegraded() {
        let incident = DiagnosticIncident(
            kind: .meetingMicrophoneCaptureFailed,
            severity: .warning,
            stage: .meetingMicrophoneCapture,
            error: nil,
            metadata: metadata
        )

        #expect(incident.userImpact == .degradedResult)
        #expect(incident.telemetryCategory == .appState)
        #expect(incident.telemetryParameters["diagnostic.stage"] == "meeting_microphone_capture")
        #expect(incident.telemetryParameters["diagnostic.error_domain"] == nil)
        #expect(incident.telemetryParameters["diagnostic.error_code"] == nil)
    }

    @Test("domain fallback covers Swift enum style diagnostic errors")
    func domainFallbackCoversSwiftEnumErrors() {
        let meaning = DiagnosticErrorCatalog.meaning(
            domain: "MuesliNativeApp.MeetingLifecycleError",
            code: "0"
        )

        #expect(meaning?.summary == "Meeting recording could not be saved")
        #expect(meaning?.area == "meeting_persistence")
    }

    @Test("allowlisted domains reject unrecognized codes")
    func allowlistedDomainRejectsUnknownCode() {
        let incident = DiagnosticIncident(
            kind: .meetingProcessingFailed,
            stage: .meetingStopProcessing,
            error: NSError(domain: "MuesliNativeApp.MeetingLifecycleError", code: 999),
            metadata: metadata
        )

        #expect(incident.errorFingerprint == .unclassified())
        #expect(incident.telemetryParameters["diagnostic.error_domain"] == nil)
        #expect(incident.telemetryParameters["diagnostic.error_code"] == nil)
    }

    @Test("broad system classifications omit domain and code")
    func broadSystemClassificationOmitsRawCode() {
        let incident = DiagnosticIncident(
            kind: .meetingProcessingFailed,
            stage: .meetingStopProcessing,
            error: NSError(domain: "NSCocoaErrorDomain", code: 123_456),
            metadata: metadata
        )

        #expect(incident.errorFingerprint.signature == "system_foundation")
        #expect(incident.telemetryParameters["diagnostic.error_domain"] == nil)
        #expect(incident.telemetryParameters["diagnostic.error_code"] == nil)
    }

    @Test("GitHub issue URL is prefilled")
    func githubIssueURLIsPrefilled() throws {
        let incident = DiagnosticIncident(
            kind: .manualReport,
            severity: .info,
            stage: .manualReport,
            backendOption: nil,
            error: nil,
            metadata: metadata
        )

        let url = try #require(incident.githubIssueURL)
        #expect(url.absoluteString.hasPrefix("https://github.com/Muesli-HQ/muesli/issues/new?"))
        #expect(url.absoluteString.contains("title="))
        #expect(url.absoluteString.contains("body="))
        #expect(DiagnosticIncident.githubIssueFallbackURL.absoluteString == "https://github.com/Muesli-HQ/muesli/issues/new")
    }
}

@Suite("DiagnosticIncidentReporter")
@MainActor
struct DiagnosticIncidentReporterTests {
    @Test("records telemetry and prompts once per kind per day")
    func recordsTelemetryAndThrottlesPrompt() throws {
        let appState = AppState()
        let suiteName = "DiagnosticIncidentReporterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var sent: [DiagnosticIncident] = []
        var prompted: [DiagnosticIncident] = []
        let reporter = DiagnosticIncidentReporter(
            appState: appState,
            defaults: defaults,
            telemetrySink: { sent.append($0) },
            automaticPromptEnabled: { true },
            onPrompt: { prompted.append($0) }
        )

        let first = reporter.record(
            kind: .meetingMicrophoneCaptureFailed,
            stage: .meetingMicrophoneCapture,
            backend: nil,
            error: NSError(domain: "MicrophoneRecorder", code: 1)
        )
        #expect(sent.map(\.id) == [first.id])
        #expect(prompted.map(\.id) == [first.id])
        #expect(appState.pendingDiagnosticIncident?.id == first.id)

        appState.pendingDiagnosticIncident = nil
        let second = reporter.record(
            kind: .meetingMicrophoneCaptureFailed,
            stage: .meetingMicrophoneCapture,
            backend: nil,
            error: NSError(domain: "MicrophoneRecorder", code: 2)
        )
        #expect(sent.map(\.id) == [first.id, second.id])
        #expect(prompted.map(\.id) == [first.id])
        #expect(appState.pendingDiagnosticIncident == nil)

        var restartedPrompted: [DiagnosticIncident] = []
        let restartedReporter = DiagnosticIncidentReporter(
            appState: appState,
            defaults: defaults,
            telemetrySink: { sent.append($0) },
            automaticPromptEnabled: { true },
            onPrompt: { restartedPrompted.append($0) }
        )
        let third = restartedReporter.record(
            kind: .meetingMicrophoneCaptureFailed,
            stage: .meetingMicrophoneCapture,
            backend: nil,
            error: NSError(domain: "MicrophoneRecorder", code: 3)
        )
        #expect(sent.map(\.id) == [first.id, second.id, third.id])
        #expect(restartedPrompted.isEmpty)
        #expect(appState.pendingDiagnosticIncident == nil)
    }

    @Test("default-off automatic reporting still records telemetry")
    func defaultOffStillRecordsTelemetry() {
        let appState = AppState()
        var sent: [DiagnosticIncident] = []
        var prompted: [DiagnosticIncident] = []
        let reporter = DiagnosticIncidentReporter(
            appState: appState,
            telemetrySink: { sent.append($0) },
            onPrompt: { prompted.append($0) }
        )

        let incident = reporter.record(
            kind: .meetingProcessingFailed,
            stage: .meetingStopProcessing
        )

        #expect(sent.map(\.id) == [incident.id])
        #expect(prompted.isEmpty)
        #expect(appState.pendingDiagnosticIncident == nil)

        reporter.recordManualReport()
        #expect(appState.pendingDiagnosticIncident?.kind == .manualReport)
    }
}
