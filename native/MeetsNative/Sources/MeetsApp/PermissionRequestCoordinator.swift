import AppKit
import AVFoundation
import Foundation

/// The privacy permissions Meets requests through the system APIs, plus how
/// each one reads back from a captured `InteractionPermissionSnapshot`.
enum InteractionPermissionKind: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case accessibility
    case inputMonitoring
    case screenRecording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .screenRecording: return "Screen Recording"
        }
    }

    var systemSettingsPane: String {
        switch self {
        case .microphone: return "Privacy_Microphone"
        case .accessibility: return "Privacy_Accessibility"
        case .inputMonitoring: return "Privacy_ListenEvent"
        case .screenRecording: return "Privacy_ScreenCapture"
        }
    }

    func isGranted(in snapshot: InteractionPermissionSnapshot) -> Bool {
        switch self {
        case .microphone: return snapshot.microphone
        case .accessibility: return snapshot.accessibility
        case .inputMonitoring: return snapshot.inputMonitoring
        case .screenRecording: return snapshot.screenRecording
        }
    }
}

/// Set when a request settled without a grant, so the only remaining cure is
/// the System Settings pane itself.
enum PermissionRequestHint: Equatable, Sendable {
    case openedSystemSettings

    var guidance: String {
        "Turn on Meets in System Settings. If it's already on, turn it off and on again, then return here."
    }
}

/// What a permission row shows. Derived from the coordinator so Settings and
/// Onboarding cannot disagree about precedence.
enum PermissionRowPresentation: Equatable, Sendable {
    case granted
    /// A check that lives outside this coordinator (calendar, system audio).
    case checking
    /// A request is in flight; the system may still be showing its prompt.
    case pending
    /// The request settled without a grant and the pane was opened.
    case hint
    case idle
}

/// The raw TCC calls, behind a protocol so the coordinator is testable without
/// touching the privacy database.
@MainActor
protocol SystemPermissionRequesting {
    /// True when the system reported the grant immediately.
    func requestMicrophone() async -> Bool
    func requestAccessibility() -> Bool
    func requestInputMonitoring() -> Bool
    func requestScreenRecording() -> Bool
    /// `requestAccess` returns false without prompting once the user denied the
    /// microphone, so polling cannot help and the pane is the only cure.
    var isMicrophoneDenied: Bool { get }
    func openPane(_ pane: String)
}

/// Where the coordinator reads grants from and how it forces a fresh reading.
@MainActor
protocol InteractionPermissionSnapshotSource: AnyObject {
    var currentPermissionSnapshot: InteractionPermissionSnapshot? { get }
    func refreshPermissionSnapshot() async
}

typealias PermissionSleeper = @Sendable (Duration) async -> Void

/// Owns every permission request Meets makes, because each raw API is
/// one-shot per app identity: a second call silently does nothing, and a
/// pre-existing denial is only fixable in System Settings. The coordinator
/// fires the request, polls for the grant, and falls back to opening the pane
/// with a hint instead of leaving the user staring at an unchanged row.
@MainActor
final class PermissionRequestCoordinator {
    private let appState: AppState
    private let snapshotSource: InteractionPermissionSnapshotSource
    private let requester: SystemPermissionRequesting
    private let sleep: PermissionSleeper
    private let settleTimeout: Duration
    private let pollInterval: Duration

    init(
        appState: AppState,
        snapshotSource: InteractionPermissionSnapshotSource,
        requester: SystemPermissionRequesting? = nil,
        settleTimeout: Duration = .seconds(2.5),
        pollInterval: Duration = .milliseconds(500),
        sleep: @escaping PermissionSleeper = { try? await Task.sleep(for: $0) }
    ) {
        self.appState = appState
        self.snapshotSource = snapshotSource
        self.requester = requester ?? SystemPermissionRequester()
        self.settleTimeout = settleTimeout
        self.pollInterval = pollInterval
        self.sleep = sleep
    }

    func presentation(for kind: InteractionPermissionKind) -> PermissionRowPresentation {
        if isGranted(kind) { return .granted }
        if appState.pendingPermissionRequests.contains(kind) { return .pending }
        if appState.permissionHints[kind] == .openedSystemSettings { return .hint }
        return .idle
    }

    /// Returns the settle task so callers (and tests) can await the outcome;
    /// nil when the request was already granted or already in flight.
    @discardableResult
    func request(_ kind: InteractionPermissionKind) -> Task<Void, Never>? {
        guard !appState.pendingPermissionRequests.contains(kind) else { return nil }
        guard !isGranted(kind) else { return nil }

        appState.pendingPermissionRequests.insert(kind)
        return Task { await settle(kind) }
    }

    /// A grant that arrives later — from System Settings or from another
    /// surface's request — retires the pane hint.
    func handleSnapshot(_ snapshot: InteractionPermissionSnapshot) {
        for kind in InteractionPermissionKind.allCases
        where appState.permissionHints[kind] != nil && kind.isGranted(in: snapshot) {
            appState.permissionHints[kind] = nil
        }
    }

    private func settle(_ kind: InteractionPermissionKind) async {
        let immediateGrant = await fireSystemRequest(kind)

        await snapshotSource.refreshPermissionSnapshot()

        var granted = immediateGrant || isGranted(kind)
        // A denied microphone answers instantly and shows no prompt, so the
        // settle window would only delay the pane.
        let refusedWithoutPrompt = !granted && kind == .microphone && requester.isMicrophoneDenied
        var waited = Duration.zero
        while !granted, !refusedWithoutPrompt, waited < settleTimeout, !Task.isCancelled {
            await sleep(pollInterval)
            waited += pollInterval
            await snapshotSource.refreshPermissionSnapshot()
            granted = isGranted(kind)
        }

        appState.pendingPermissionRequests.remove(kind)
        guard !granted else { return }

        requester.openPane(kind.systemSettingsPane)
        appState.permissionHints[kind] = .openedSystemSettings
    }

    private func fireSystemRequest(_ kind: InteractionPermissionKind) async -> Bool {
        switch kind {
        case .microphone: return await requester.requestMicrophone()
        case .accessibility: return requester.requestAccessibility()
        case .inputMonitoring: return requester.requestInputMonitoring()
        case .screenRecording: return requester.requestScreenRecording()
        }
    }

    private func isGranted(_ kind: InteractionPermissionKind) -> Bool {
        guard let snapshot = snapshotSource.currentPermissionSnapshot else { return false }
        return kind.isGranted(in: snapshot)
    }
}

@MainActor
struct SystemPermissionRequester: SystemPermissionRequesting {
    func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    var isMicrophoneDenied: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .denied
    }

    func openPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
