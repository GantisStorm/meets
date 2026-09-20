import Foundation
import Testing
@testable import MeetsApp

private let noGrants = InteractionPermissionSnapshot(
    microphone: false,
    accessibility: false,
    inputMonitoring: false,
    screenRecording: false
)

private let accessibilityGrantedOnly = InteractionPermissionSnapshot(
    microphone: false,
    accessibility: true,
    inputMonitoring: false,
    screenRecording: false
)

private let allGranted = InteractionPermissionSnapshot(
    microphone: true,
    accessibility: true,
    inputMonitoring: true,
    screenRecording: true
)

@MainActor
private final class FakePermissionRequester: SystemPermissionRequesting {
    var grantsImmediately = false
    var microphoneDenied = false
    private(set) var requestedKinds: [InteractionPermissionKind] = []
    private(set) var openedPanes: [String] = []

    func requestMicrophone() async -> Bool {
        requestedKinds.append(.microphone)
        return grantsImmediately
    }

    func requestAccessibility() -> Bool {
        requestedKinds.append(.accessibility)
        return grantsImmediately
    }

    func requestInputMonitoring() -> Bool {
        requestedKinds.append(.inputMonitoring)
        return grantsImmediately
    }

    func requestScreenRecording() -> Bool {
        requestedKinds.append(.screenRecording)
        return grantsImmediately
    }

    var isMicrophoneDenied: Bool { microphoneDenied }

    func openPane(_ pane: String) {
        openedPanes.append(pane)
    }
}

/// Stands in for the monitor: each refresh advances one snapshot, and the last
/// snapshot repeats so a never-granted system stays never-granted.
@MainActor
private final class FakePermissionSnapshotSource: InteractionPermissionSnapshotSource {
    private let snapshots: [InteractionPermissionSnapshot]
    private var index = 0
    private var published: InteractionPermissionSnapshot?
    private(set) var refreshCount = 0

    init(snapshots: [InteractionPermissionSnapshot]) {
        self.snapshots = snapshots
        precondition(!snapshots.isEmpty)
    }

    var currentPermissionSnapshot: InteractionPermissionSnapshot? {
        published ?? snapshots[min(index, snapshots.count - 1)]
    }

    /// Models the monitor publishing a snapshot outside a request.
    func publish(_ snapshot: InteractionPermissionSnapshot) {
        published = snapshot
    }

    func refreshPermissionSnapshot() async {
        refreshCount += 1
        index = min(index + 1, snapshots.count - 1)
    }
}

/// Manual clock: records the requested intervals and returns immediately, so
/// the settle loop is exercised without real waiting.
private final class PermissionClockProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []

    var intervals: [Duration] {
        lock.withLock { recorded }
    }

    func record(_ duration: Duration) {
        lock.withLock { recorded.append(duration) }
    }

    var sleep: PermissionSleeper {
        { [self] duration in
            record(duration)
            await Task.yield()
        }
    }
}

@MainActor
@Suite("Permission request coordinator")
struct PermissionRequestCoordinatorTests {
    private func makeCoordinator(
        snapshots: [InteractionPermissionSnapshot],
        settleTimeout: Duration = .seconds(2.5),
        pollInterval: Duration = .milliseconds(500)
    ) -> (
        coordinator: PermissionRequestCoordinator,
        appState: AppState,
        requester: FakePermissionRequester,
        source: FakePermissionSnapshotSource,
        clock: PermissionClockProbe
    ) {
        let appState = AppState()
        let requester = FakePermissionRequester()
        let source = FakePermissionSnapshotSource(snapshots: snapshots)
        let clock = PermissionClockProbe()
        let coordinator = PermissionRequestCoordinator(
            appState: appState,
            snapshotSource: source,
            requester: requester,
            settleTimeout: settleTimeout,
            pollInterval: pollInterval,
            sleep: clock.sleep
        )
        return (coordinator, appState, requester, source, clock)
    }

    @Test("a grant on the first refresh settles without opening the pane")
    func grantOnFirstRefreshSettles() async {
        let (coordinator, appState, requester, source, clock) =
            makeCoordinator(snapshots: [noGrants, accessibilityGrantedOnly])

        await coordinator.request(.accessibility)?.value

        #expect(appState.pendingPermissionRequests.isEmpty)
        #expect(appState.permissionHints.isEmpty)
        #expect(requester.openedPanes.isEmpty)
        #expect(clock.intervals.isEmpty)
        #expect(source.refreshCount == 1)
        #expect(coordinator.presentation(for: .accessibility) == .granted)
    }

    @Test("a grant on the third poll settles without opening the pane")
    func grantOnThirdPollSettles() async {
        let (coordinator, appState, requester, _, clock) = makeCoordinator(
            snapshots: [noGrants, noGrants, noGrants, noGrants, accessibilityGrantedOnly]
        )

        await coordinator.request(.accessibility)?.value

        #expect(clock.intervals.count == 3)
        #expect(appState.pendingPermissionRequests.isEmpty)
        #expect(appState.permissionHints.isEmpty)
        #expect(requester.openedPanes.isEmpty)
        #expect(coordinator.presentation(for: .accessibility) == .granted)
    }

    @Test("a request that never lands opens the pane once and leaves a hint")
    func unansweredRequestOpensPane() async {
        let (coordinator, appState, requester, source, clock) =
            makeCoordinator(snapshots: [noGrants])

        await coordinator.request(.accessibility)?.value

        #expect(clock.intervals == Array(repeating: Duration.milliseconds(500), count: 5))
        #expect(source.refreshCount == 6)
        #expect(requester.openedPanes == [InteractionPermissionKind.accessibility.systemSettingsPane])
        #expect(appState.permissionHints[.accessibility] == .openedSystemSettings)
        #expect(appState.pendingPermissionRequests.isEmpty)
        #expect(coordinator.presentation(for: .accessibility) == .hint)
    }

    @Test("a second request while one is pending is ignored")
    func secondRequestWhilePendingIsIgnored() async {
        let (coordinator, appState, requester, _, _) = makeCoordinator(snapshots: [noGrants])

        let first = coordinator.request(.accessibility)
        #expect(first != nil)
        #expect(appState.pendingPermissionRequests == [.accessibility])
        #expect(coordinator.presentation(for: .accessibility) == .pending)

        let second = coordinator.request(.accessibility)
        #expect(second == nil)

        await first?.value

        #expect(requester.requestedKinds == [.accessibility])
    }

    @Test("a later grant clears the hint")
    func laterGrantClearsHint() async {
        let (coordinator, appState, _, source, _) = makeCoordinator(snapshots: [noGrants])

        await coordinator.request(.accessibility)?.value
        #expect(appState.permissionHints[.accessibility] == .openedSystemSettings)

        source.publish(allGranted)
        coordinator.handleSnapshot(allGranted)

        #expect(appState.permissionHints.isEmpty)
        #expect(coordinator.presentation(for: .accessibility) == .granted)
    }

    @Test("an already-granted request does nothing")
    func alreadyGrantedRequestDoesNothing() async {
        let (coordinator, appState, requester, source, _) =
            makeCoordinator(snapshots: [allGranted])

        let task = coordinator.request(.screenRecording)

        #expect(task == nil)
        #expect(requester.requestedKinds.isEmpty)
        #expect(requester.openedPanes.isEmpty)
        #expect(appState.pendingPermissionRequests.isEmpty)
        #expect(source.refreshCount == 0)
        #expect(coordinator.presentation(for: .screenRecording) == .granted)
    }

    @Test("a denied microphone settles without polling and opens its pane")
    func deniedMicrophoneOpensPaneWithoutPolling() async {
        let (coordinator, appState, requester, _, clock) = makeCoordinator(snapshots: [noGrants])
        requester.microphoneDenied = true

        await coordinator.request(.microphone)?.value

        #expect(clock.intervals.isEmpty)
        #expect(requester.openedPanes == [InteractionPermissionKind.microphone.systemSettingsPane])
        #expect(appState.permissionHints[.microphone] == .openedSystemSettings)
    }

    @Test("an immediate grant skips the settle window")
    func immediateGrantSkipsSettleWindow() async {
        let (coordinator, appState, requester, _, clock) = makeCoordinator(snapshots: [noGrants])
        requester.grantsImmediately = true

        await coordinator.request(.inputMonitoring)?.value

        #expect(clock.intervals.isEmpty)
        #expect(requester.openedPanes.isEmpty)
        #expect(appState.pendingPermissionRequests.isEmpty)
        #expect(appState.permissionHints.isEmpty)
    }
}
