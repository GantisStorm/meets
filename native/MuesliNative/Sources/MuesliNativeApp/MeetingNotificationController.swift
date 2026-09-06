import Foundation
import MuesliCore
import os
import UserNotifications

/// Meeting prompts delivered as Apple notifications (Notification Center),
/// not custom floating panels: they respect Focus modes, persist in the
/// notification list, and play the standard alert treatment.
///
/// Public surface mirrors the old panel controller one-to-one: `show` takes
/// the same prompt parts and callbacks, `close` tears down, and
/// `isVisible`/`currentPromptID`/`shownAt` keep their meaning (a delivered,
/// not-yet-removed notification). Only one prompt is ever live: showing a
/// new one removes the previous, exactly like the panel did.
@MainActor
final class MeetingNotificationController: NSObject, UNUserNotificationCenterDelegate {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MeetingNotification")

    private var deliveredID: String?
    private var removalTask: Task<Void, Never>?
    private var onStartRecording: (() -> Void)?
    private var onJoinAndRecord: (() -> Void)?
    private var onJoinOnly: (() -> Void)?
    private var onDismiss: (() -> Void)?
    private var onAutoDismiss: (() -> Void)?
    private var actionHandlers: [String: () -> Void] = [:]
    private var primaryActionID: String?
    private static var didRequestAuthorization = false
    private(set) var isVisible = false
    private(set) var currentPromptID: String?
    private(set) var shownAt: Date?

    private static let dismissDuration: TimeInterval = 15

    static func suppressesCloseCallbackDuringAutoDismiss(hasAutoDismissHandler: Bool) -> Bool {
        hasAutoDismissHandler
    }

    static func firesAutoDismissCallbackAfterFade(wasDismissPaused: Bool) -> Bool {
        !wasDismissPaused
    }

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Requests notification authorization if never asked. Called when the
    /// user enables either notification toggle and as a backstop on show.
    func ensureNotificationAuthorization() {
        guard !Self.didRequestAuthorization else { return }
        Self.didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Self.logger.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else {
                Self.logger.notice("notification authorization granted=\(granted)")
            }
        }
    }

    @discardableResult
    func show(
        promptID: String? = nil,
        title: String,
        subtitle: String,
        actionLabel: String = "Start Transcribing",
        meetingURL: URL? = nil,
        dismissAfter: TimeInterval? = nil,
        defaultAction: MeetingJoinDefaultAction = .fallback,
        onStartRecording: @escaping () -> Void,
        onJoinAndRecord: (() -> Void)? = nil,
        onJoinOnly: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        onAutoDismiss: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) -> Bool {
        // Nil out onClose before close() so the old prompt's teardown
        // doesn't fire its callback (e.g. resetting isShowingCalendarNotification).
        self.onClose = nil
        close()

        let duration = dismissAfter ?? Self.dismissDuration
        self.onStartRecording = onStartRecording
        self.onJoinAndRecord = onJoinAndRecord
        self.onJoinOnly = onJoinOnly
        self.onDismiss = onDismiss
        self.onAutoDismiss = onAutoDismiss

        let hasJoinAndRecord = meetingURL != nil && onJoinAndRecord != nil
        let hasJoinOnly = meetingURL != nil && onJoinOnly != nil
        let armedAction = defaultAction.resolved(hasJoinAndRecord: hasJoinAndRecord, hasJoinOnly: hasJoinOnly)
        let alternatives = defaultAction.availableAlternatives(
            hasJoinAndRecord: hasJoinAndRecord,
            hasJoinOnly: hasJoinOnly
        )

        // One category per prompt: action titles differ per prompt
        // ("Start Transcribing" vs "View Notes"), so static categories can't
        // cover them. Registration is additive and cheap.
        let deliveredID = promptID ?? UUID().uuidString
        let categoryID = "meeting." + deliveredID
        var handlers: [String: () -> Void] = [:]
        var actions: [UNNotificationAction] = []
        func addAction(id: String, title: String, handler: @escaping () -> Void) {
            handlers[id] = handler
            actions.append(UNNotificationAction(identifier: id, title: title, options: []))
        }
        // Primary first: body tap invokes it.
        let primaryID = "primary"
        primaryActionID = primaryID
        switch armedAction {
        case .joinAndRecord:
            addAction(id: primaryID, title: MeetingJoinDefaultAction.joinAndRecord.buttonLabel) { [weak self] in self?.onJoinAndRecord?() }
        case .joinOnly:
            addAction(id: primaryID, title: MeetingJoinDefaultAction.joinOnly.buttonLabel) { [weak self] in self?.onJoinOnly?() }
        case .recordOnly:
            addAction(id: primaryID, title: actionLabel) { [weak self] in self?.onStartRecording?() }
        }
        for alternative in alternatives {
            switch alternative {
            case .joinAndRecord:
                addAction(id: "joinRecord", title: MeetingJoinDefaultAction.joinAndRecord.buttonLabel) { [weak self] in self?.onJoinAndRecord?() }
            case .joinOnly:
                addAction(id: "joinOnly", title: MeetingJoinDefaultAction.joinOnly.buttonLabel) { [weak self] in self?.onJoinOnly?() }
            case .recordOnly:
                addAction(id: "transcribe", title: actionLabel) { [weak self] in self?.onStartRecording?() }
            }
        }
        addAction(id: "dismiss", title: "Dismiss") { [weak self] in self?.handleDismissAction() }
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: categoryID, actions: actions, intentIdentifiers: [], options: [])
        ])
        self.actionHandlers = handlers

        ensureNotificationAuthorization()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = subtitle
        content.categoryIdentifier = categoryID
        content.sound = .default
        let request = UNNotificationRequest(identifier: deliveredID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let self else { return }
            if let error {
                Task { @MainActor [weak self] in
                    Self.logger.error("notification deliver failed: \(error.localizedDescription, privacy: .public)")
                    self?.close()
                }
            }
        }

        self.deliveredID = deliveredID
        isVisible = true
        currentPromptID = promptID
        shownAt = Date()
        Self.logger.notice("notification_delivered promptID=\(promptID ?? "nil", privacy: .public) id=\(deliveredID, privacy: .public)")
        removalTask?.cancel()
        removalTask = Task { [weak self, duration] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run { [weak self] in self?.autoRemoveNow() }
        }
        return true
    }

    var onClose: (() -> Void)?

    func close() {
        removalTask?.cancel()
        removalTask = nil
        if let deliveredID {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [deliveredID])
        }
        deliveredID = nil
        actionHandlers = [:]
        primaryActionID = nil
        onStartRecording = nil
        onJoinAndRecord = nil
        onJoinOnly = nil
        onDismiss = nil
        onAutoDismiss = nil
        isVisible = false
        currentPromptID = nil
        shownAt = nil
        onClose?()
        onClose = nil
    }

    /// Removal after the display window: keeps the notification in the
    /// Center's history cleared and fires the auto-dismiss callback with the
    /// same suppression rule the panel fade used.
    private func autoRemoveNow() {
        let autoDismiss = self.onAutoDismiss
        if Self.suppressesCloseCallbackDuringAutoDismiss(hasAutoDismissHandler: autoDismiss != nil) {
            self.onClose = nil
        }
        close()
        if Self.firesAutoDismissCallbackAfterFade(wasDismissPaused: false) {
            autoDismiss?()
        }
    }

    private func handleDismissAction() {
        let action = onDismiss
        close()
        action?()
    }

    private func handleNotificationResponse(id: String, actionID: String) {
        guard id == deliveredID else { return }
        if actionID == UNNotificationDefaultActionIdentifier,
           let primaryActionID,
           let handler = actionHandlers[primaryActionID] {
            close()
            handler()
            return
        }
        guard let handler = actionHandlers[actionID] else {
            close()
            return
        }
        close()
        handler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier
        let actionID = response.actionIdentifier
        Task { @MainActor [weak self] in self?.handleNotificationResponse(id: id, actionID: actionID) }
        completionHandler()
    }
}
