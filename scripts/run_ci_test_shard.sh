#!/usr/bin/env bash
set -euo pipefail

list_filters=false
if [[ "${1:-}" == "--list-filters" ]]; then
  list_filters=true
  shard="${2:-}"
else
  shard="${1:-}"
fi

if [[ -z "${shard}" ]]; then
  echo "usage: $0 [--list-filters] <core|dictation-transcription|meetings>" >&2
  exit 2
fi

case "${shard}" in
  core)
    filters=(
      ConfigStoreTests
      ACPClientTests
      AppleIntelligenceBackendTests
      DashboardPresentationReadinessTests
      DictationStoreTests
      MeetsCLITests
      ChatGPTAuthTests
      ChatGPTResponsesTransportTests
      ChatGPTTokenStorageTests
      OpenRouterAuthTests
      SettingsPermissionRefreshReasonTests
      InteractionPermissionMonitorTests
      OnboardingFlowTests
      OnboardingProgressTests
      FloatingIndicatorVisibilityTests
      IndicatorFrameSizeTests
      WindowAppearanceTests
      OpenAILogoShapeTests
      StandardMenuShortcutTests
      MeetingChunkCollectorTests
      AppConfigTests
      CGPointCodableTests
      UpdateFailureGuidanceTests
      WordCountTests
      CustomWordDictionaryTests
      ModelDownloadCoordinatorTests
      BodhanBackendTests
      BodhanArtifactValidationTests
      BodhanLifecycleTests
    )
    ;;
  dictation-transcription)
    filters=(
      FluidAudioTranscriberTests
      AppleSpeechAnalyzerBackendTests
      BackendCoverageTests
      JaroWinklerTests
      CustomWordMatcherApplyTests
      SpeechSegmentTests
      SpeechTranscriptionResultTests
      TranscriptionCoordinatorTests
      TranscriptionEngineArtifactsFilterTests
      DiarizerRuntimePolicyTests
      DiarizerPreloadDiagnosticsTests
      DiarizerPreloadCoordinationTests
      BackendOptionTests
      SummaryModelPresetTests
      HotkeyMonitorTests
      HotkeyConfigTests
      Nemotron35ModelStoreTests
    )
    ;;
  meetings)
    filters=(
      AudioAttributionServiceTests
      CameraActivityMonitorTests
      MicrophoneActivityMonitorTests
      MeetingCaptureLifecycleTests
      AudioQueueInputRecorderTests
      MeetingCaptureShutdownTests
      MeetingMonitoringModePolicyTests
      MeetingAudioRecoveryDeadlinesTests
      MeetingSignalRefreshPolicyTests
      MeetingMicRecoveryCoordinatorTests
      MeetingMicHealthTrackerTests
      MeetingSystemAudioWatchdogTests
      AudioGraphExceptionBridgeTests
      DiagnosticIncidentTests
      DictationAudioRouteControllerTests
      MeetingContactIdentityTests
      MeetingContactResolverTests
      MeetingParticipantStoreTests
      MeetingProcessingStageTests
      MeetingRecordingWriterTests
      MeetingResumePolicyTests
      MeetingStreamingPartialSessionTests
      MeetingFollowUpPolicyTests
      MeetingFollowUpThreadTests
      MeetingFollowUpSummaryPromptTests
      MeetingSummaryClientTests
      MeetingsNavigationTests
      MeetingBrowserLogicTests
      MeetingBrowserShelfTests
      MeetingBrowserIndexTests
      MeetingNotesInlineMarkdownTests
      TranscriptFormatterTests
      MeetingSummaryBackendTests
      MeetingResummarizationPolicyTests
      MeetingTemplateResolutionTests
      MeetingTemplatesDefaultFallbackTests
      RouteAwareMeetingMicRecorderTests
      CalendarEventQueryTests
      CalendarMonitorLifecycleTests
      DisabledCalendarFilterTests
    )
    ;;
  *)
    echo "unknown shard: ${shard}" >&2
    exit 2
    ;;
esac

if [[ "${list_filters}" == true ]]; then
  printf '%s\n' "${filters[@]}"
  exit 0
fi

args=(--package-path native/MeetsNative)
if [[ "${shard}" == meetings ]]; then
  # Concurrent suites can starve the utility-priority caption tasks on small
  # runners. Serialize test cases, preserving concurrency exercised inside each
  # test, rather than weakening their deadlines or changing production QoS.
  args+=(--no-parallel)
fi
if [[ -n "${MEETS_SWIFTPM_SCRATCH_PATH:-}" ]]; then
  args+=(--scratch-path "${MEETS_SWIFTPM_SCRATCH_PATH}")
fi
for filter in "${filters[@]}"; do
  args+=(--filter "${filter}")
done

echo "Running ${shard} shard with ${#filters[@]} filters"
swift test "${args[@]}"
