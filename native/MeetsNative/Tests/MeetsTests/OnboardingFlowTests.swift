import Foundation
import Testing
@testable import MeetsApp

@Suite("OnboardingFlow")
struct OnboardingFlowTests {
    @Test("Restored supported models outside onboarding must be reconfirmed", arguments: [2, 3, 4, 5, 6])
    func replacedModelReturnsToSelection(_ requestedStep: Int) {
        let version = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        let initial = BackendOption.gemma4E2BLiteRT
        #expect(initial.isCompatible(currentOSVersion: version))
        let resolved = BackendOption.resolvedOnboardingBackend(initial, currentOSVersion: version)
        #expect(resolved != initial)
        #expect(OnboardingFlow.modelGatedResumeStep(
            requestedStep: requestedStep, initialBackend: initial,
            resolvedBackend: resolved, currentOSVersion: version
        ) == 1)
    }

    @Test("Unchanged supported onboarding models preserve the permission-gated step", arguments: [0, 1, 2, 3, 4, 5, 6])
    func unchangedModelPreservesResumeStep(_ requestedStep: Int) {
        let version = OperatingSystemVersion(majorVersion: 14, minorVersion: 8, patchVersion: 0)
        let initial = BackendOption.parakeetUnified
        #expect(OnboardingFlow.modelGatedResumeStep(
            requestedStep: requestedStep, initialBackend: initial,
            resolvedBackend: BackendOption.resolvedOnboardingBackend(initial, currentOSVersion: version),
            currentOSVersion: version
        ) == requestedStep)
    }

    @Test("OS-incompatible restored models return to selection without skipping welcome", arguments: [0, 1, 3, 4])
    func incompatibleModelRespectsEarlierSteps(_ requestedStep: Int) {
        let version = OperatingSystemVersion(majorVersion: 14, minorVersion: 8, patchVersion: 0)
        let initial = BackendOption.nemotron35Multilingual
        #expect(OnboardingFlow.modelGatedResumeStep(
            requestedStep: requestedStep, initialBackend: initial,
            resolvedBackend: BackendOption.resolvedOnboardingBackend(initial, currentOSVersion: version),
            currentOSVersion: version
        ) == min(requestedStep, 1))
    }

    @Test("voice notes orders push-to-talk steps without paste permission")
    func voiceNotesOrderedSteps() {
        #expect(OnboardingFlow.orderedSteps(for: .voiceNotes) == [0, 1, 2, 3, 4])
    }

    @Test("dictation orders dictation-only steps")
    func dictationOrderedSteps() {
        #expect(OnboardingFlow.orderedSteps(for: .dictation) == [0, 1, 2, 3, 4])
    }

    @Test("meetings orders meetings-only steps")
    func meetingsOrderedSteps() {
        #expect(OnboardingFlow.orderedSteps(for: .meetings) == [0, 1, 3, 5, 6])
    }

    @Test("dictation and meetings orders combined steps")
    func dictationAndMeetingsOrderedSteps() {
        #expect(OnboardingFlow.orderedSteps(for: .dictationAndMeetings) == [0, 1, 2, 3, 4, 5, 6])
    }

    @Test("multi-select unions include every required workflow step")
    func multiSelectUnionOrderedSteps() {
        #expect(OnboardingFlow.orderedSteps(for: .voiceNotesAndMeetings) == [0, 1, 2, 3, 4, 5, 6])
        #expect(OnboardingFlow.orderedSteps(for: .voiceNotesAndDictation) == [0, 1, 2, 3, 4])
        #expect(OnboardingFlow.orderedSteps(for: .everything) == [0, 1, 2, 3, 4, 5, 6])
    }

    @Test("restored calendar step uses macOS calendar access")
    func restoredRemovedCalendarStep() {
        for useCase: OnboardingUseCase in [.meetings, .dictationAndMeetings, .voiceNotesAndMeetings, .everything] {
            #expect(OnboardingFlow.normalizedStep(6, for: useCase) == OnboardingFlow.Step.calendarAccess.rawValue)
            #expect(OnboardingFlow.orderedSteps(for: useCase).last == OnboardingFlow.Step.calendarAccess.rawValue)
        }
    }

    @Test("normalized step advances over skipped steps")
    func normalizedStepAdvancesOverSkippedSteps() {
        #expect(OnboardingFlow.normalizedStep(2, for: .meetings) == 3)
        #expect(OnboardingFlow.normalizedStep(4, for: .meetings) == 5)
    }

    @Test("normalized step keeps valid steps and clamps after final step")
    func normalizedStepKeepsValidAndClampsAfterFinalStep() {
        #expect(OnboardingFlow.normalizedStep(3, for: .meetings) == 3)
        #expect(OnboardingFlow.normalizedStep(99, for: .dictation) == 4)
        #expect(OnboardingFlow.normalizedStep(4, for: .voiceNotes) == 4)
    }

    @Test("can go back is disabled after successful dictation test")
    func canGoBackAfterSuccessfulDictationTest() {
        #expect(!OnboardingFlow.canGoBack(
            from: OnboardingFlow.Step.dictationTest.rawValue,
            useCase: .dictation,
            dictationTestSucceeded: true
        ))
        #expect(OnboardingFlow.canGoBack(
            from: OnboardingFlow.Step.dictationTest.rawValue,
            useCase: .dictation,
            dictationTestSucceeded: false
        ))
    }

    @Test("can go back is disabled at first step")
    func canGoBackAtFirstStep() {
        #expect(!OnboardingFlow.canGoBack(
            from: OnboardingFlow.Step.welcome.rawValue,
            useCase: .dictationAndMeetings,
            dictationTestSucceeded: false
        ))
    }

    @Test("completed permission steps do not auto-advance again on re-entry")
    func completedPermissionStepDoesNotAutoAdvanceAgain() {
        let resumedAfterPermissions = OnboardingFlow.hasCompletedPermissionsStep(
            resumingAt: OnboardingFlow.Step.dictationTest.rawValue
        )
        let resumedAtPermissions = OnboardingFlow.hasCompletedPermissionsStep(
            resumingAt: OnboardingFlow.Step.permissions.rawValue
        )
        let schedulesAfterCompletion = OnboardingFlow.shouldSchedulePermissionAdvance(
            currentStep: OnboardingFlow.Step.permissions.rawValue,
            requiredPermissionsGranted: true,
            hasCompletedPermissionsStep: true,
            hasScheduledTask: false
        )
        let schedulesInitialCompletion = OnboardingFlow.shouldSchedulePermissionAdvance(
            currentStep: OnboardingFlow.Step.permissions.rawValue,
            requiredPermissionsGranted: true,
            hasCompletedPermissionsStep: false,
            hasScheduledTask: false
        )

        #expect(resumedAfterPermissions)
        #expect(!resumedAtPermissions)
        #expect(!schedulesAfterCompletion)
        #expect(schedulesInitialCompletion)
    }

    @Test("extreme ETA values are omitted instead of overflowing")
    func extremeETAReturnsUnknown() {
        #expect(ModelDownloadDisplayFormatting.eta(Double.greatestFiniteMagnitude) == nil)
        #expect(ModelDownloadDisplayFormatting.eta(.infinity) == nil)
        #expect(ModelDownloadDisplayFormatting.eta(3_600) == "1h 00m")
    }
}
