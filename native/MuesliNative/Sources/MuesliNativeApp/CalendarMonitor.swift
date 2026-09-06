import AppKit
import EventKit
import Foundation
import MuesliCore

/// A local attendee snapshot sourced exclusively from EventKit.
struct CalendarAttendee: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let emailAddress: String?

    init?(identifier: String?, displayName: String?, emailAddress: String?) {
        let normalizedEmail = Self.normalizedEmail(emailAddress ?? identifier)
        let normalizedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackIdentifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedName = normalizedName.isEmpty ? (normalizedEmail ?? "") : normalizedName
        guard !resolvedName.isEmpty else { return nil }

        let identity = normalizedEmail.map { "email:\($0)" }
            ?? (fallbackIdentifier.isEmpty ? nil : "calendar:\(fallbackIdentifier.lowercased())")
        guard let identity else { return nil }
        self.id = identity
        self.displayName = resolvedName
        self.emailAddress = normalizedEmail
    }

    var participantDraft: MeetingParticipantDraft {
        MeetingParticipantDraft(
            participantIdentifier: id,
            displayName: displayName,
            emailAddress: emailAddress
        )
    }

    static func deduplicated(_ attendees: [CalendarAttendee]) -> [CalendarAttendee] {
        var seen = Set<String>()
        return attendees.filter { seen.insert($0.id).inserted }
    }

    private static func normalizedEmail(_ candidate: String?) -> String? {
        var value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.lowercased().hasPrefix("mailto:") {
            value.removeFirst("mailto:".count)
        }
        guard value.contains("@") else { return nil }
        return value.lowercased()
    }
}

struct UpcomingMeetingEvent {
    let id: String
    let title: String
    let startDate: Date
    var calendarOccurrence: CalendarOccurrenceReference? = nil
    var meetingURL: URL? = nil
}

final class CalendarMonitor {
    private enum State {
        case stopped
        case requesting(Int)
        case running(Int)
    }

    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?
    private var generation = 0
    private var state: State = .stopped

    /// Called when EventKit detects a calendar change (event added, moved, deleted).
    /// Delivered via NotificationCenter — immune to App Nap timer suspension.
    var onCalendarChanged: (() -> Void)?

    func start() {
        guard case .stopped = state else { return }

        // Never prompt from a monitor start (startup, background refresh).
        // The permissions step and Settings grant buttons own the dialog;
        // the next syncCalendarMonitor after a grant starts us for real.
        guard EKEventStore.authorizationStatus(for: .event) != .notDetermined else {
            state = .stopped
            return
        }

        generation += 1
        let token = generation
        state = .requesting(token)

        store.requestFullAccessToEvents { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard case .requesting(let activeToken) = self.state, activeToken == token else { return }

                if !granted {
                    self.state = .stopped
                    fputs("[calendar] calendar access denied: \(error?.localizedDescription ?? "none")\n", stderr)
                    return
                }

                self.registerForChanges(token: token)
                self.state = .running(token)
            }
        }
    }

    func stop() {
        generation += 1
        state = .stopped
        removeObserver()
    }

    var canConfirmMissingEvents: Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            return true
        case .notDetermined, .restricted, .denied, .writeOnly:
            return false
        @unknown default:
            return false
        }
    }

    private func registerForChanges(token: Int) {
        guard changeObserver == nil else { return }
        guard case .requesting(let activeToken) = state, activeToken == token else { return }

        // EKEventStoreChangedNotification fires whenever any calendar event
        // is added, modified, or deleted — including synced changes from
        // iCloud, Exchange, linked Internet Accounts, etc. This is push-based
        // and works regardless of App Nap or LSUIElement status.
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            self?.onCalendarChanged?()
        }
    }

    private func removeObserver() {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
            self.changeObserver = nil
        }
    }

    /// Returns the current calendar event if one is happening right now.
    func currentEvent() -> UpcomingMeetingEvent? {
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(60), calendars: nil)
        let events = store.events(matching: predicate)
        for event in events {
            guard !event.isAllDay else { continue }
            guard let startDate = event.startDate, let endDate = event.endDate else { continue }
            if startDate <= now && endDate > now {
                let eventID = event.eventIdentifier ?? ""
                return UpcomingMeetingEvent(
                    id: eventID,
                    title: event.title ?? "Meeting",
                    startDate: startDate,
                    calendarOccurrence: Self.occurrenceReference(
                        for: event,
                        eventID: eventID,
                        startDate: startDate
                    ),
                    meetingURL: Self.extractMeetingURL(from: event)
                )
            }
        }
        return nil
    }

    /// Returns the current or recently started event (within 15 minutes)
    /// for meeting detection. Prefers currently active events over nearby ones.
    func currentOrNearbyEvent() -> CalendarEventContext? {
        let now = Date()
        let searchStart = now.addingTimeInterval(-15 * 60)
        let searchEnd = now.addingTimeInterval(5 * 60)
        let predicate = store.predicateForEvents(withStart: searchStart, end: searchEnd, calendars: nil)
        let events = store.events(matching: predicate)

        var nearby: CalendarEventContext?
        for event in events {
            guard !event.isAllDay else { continue }
            guard let startDate = event.startDate, let endDate = event.endDate else { continue }
            let ctx = CalendarEventContext(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "Meeting",
                calendarOccurrence: Self.occurrenceReference(
                    for: event,
                    eventID: event.eventIdentifier ?? "",
                    startDate: startDate
                )
            )
            // Currently active — return immediately
            if startDate <= now && endDate > now {
                return ctx
            }
            // Recently started (within 15 min) or about to start (within 5 min)
            if nearby == nil {
                nearby = ctx
            }
        }
        return nearby
    }

    /// Returns timed events from the local macOS calendar (EventKit) within
    /// `start...end`. All-day events are excluded — they're not useful for
    /// meeting recording. Events from calendars listed in `disabledCalendarIDs`
    /// are filtered out. A fresh store is used per call so externally synced
    /// changes (made in another calendar app) are always reflected.
    func events(
        from start: Date,
        to end: Date,
        disabledCalendarIDs: Set<String> = []
    ) -> [UnifiedCalendarEvent] {
        let freshStore = EKEventStore()
        let predicate = freshStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = freshStore.events(matching: predicate)
        let unified: [UnifiedCalendarEvent] = events.compactMap { event in
            guard let startDate = event.startDate, let endDate = event.endDate else { return nil }
            guard !event.isAllDay else { return nil }
            let eventID = event.eventIdentifier ?? UUID().uuidString
            return UnifiedCalendarEvent(
                id: eventID,
                title: event.title ?? "Meeting",
                startDate: startDate,
                endDate: endDate,
                isAllDay: false,
                source: .eventKit,
                calendarID: event.calendar?.calendarIdentifier,
                calendarOccurrence: Self.occurrenceReference(
                    for: event,
                    eventID: eventID,
                    startDate: startDate
                ),
                meetingURL: Self.extractMeetingURL(from: event),
                attendees: Self.attendees(from: event),
                location: event.location
            )
        }
        return UnifiedCalendarEvent
            .filter(unified, disabledCalendarIDs: disabledCalendarIDs)
            .filter { $0.startDate < end && $0.endDate > start }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Returns events in the `daysPast...now` window (no all-day events).
    func pastEvents(
        daysPast: Int,
        disabledCalendarIDs: Set<String> = [],
        now: Date = Date()
    ) -> [UnifiedCalendarEvent] {
        guard daysPast > 0,
              let pastStart = Calendar.current.date(byAdding: .day, value: -daysPast, to: now) else { return [] }
        return events(from: pastStart, to: now, disabledCalendarIDs: disabledCalendarIDs)
    }

    /// Returns upcoming timed events from the local macOS calendar (EventKit)
    /// for the selected calendar-day window. All-day events are excluded —
    /// they're not useful for meeting recording. Events from calendars listed
    /// in `disabledCalendarIDs` are filtered out.
    func upcomingEvents(
        daysAhead: Int = UpcomingMeetingsWindow.defaultDayCount,
        disabledCalendarIDs: Set<String> = [],
        now: Date = Date()
    ) -> [UnifiedCalendarEvent] {
        guard let future = UpcomingMeetingsWindow.endDate(from: now, dayCount: daysAhead) else { return [] }
        return events(from: now, to: future, disabledCalendarIDs: disabledCalendarIDs)
    }

    static func occurrenceReference(
        for event: EKEvent,
        eventID: String,
        startDate: Date
    ) -> CalendarOccurrenceReference {
        let isRecurring = event.hasRecurrenceRules || event.isDetached
        return CalendarOccurrenceReference(
            provider: .eventKit,
            calendarID: event.calendar?.calendarIdentifier,
            eventID: eventID,
            seriesID: isRecurring
                ? (event.calendarItemExternalIdentifier ?? eventID)
                : nil,
            originalStartTime: isRecurring
                ? (event.occurrenceDate ?? startDate)
                : startDate
        )
    }

    /// Maps an EKEvent's organizer + attendees into a deduplicated attendee
    /// snapshot. Internal so CalendarEventKitManager and MuesliController can
    /// reuse the same mapping.
    static func attendees(from event: EKEvent) -> [CalendarAttendee] {
        let participants = [event.organizer].compactMap { $0 } + (event.attendees ?? [])
        let attendees = participants.compactMap { participant -> CalendarAttendee? in
            guard participant.participantType != .resource,
                  participant.participantType != .room else { return nil }
            return CalendarAttendee(
                identifier: participant.url.absoluteString,
                displayName: participant.name,
                emailAddress: participant.url.absoluteString
            )
        }
        return CalendarAttendee.deduplicated(attendees)
    }

    /// Resolves participants at the persistence boundary so recording entry
    /// points only need to carry the existing occurrence identity.
    static func attendees(for occurrence: CalendarOccurrenceReference) -> [CalendarAttendee] {
        guard occurrence.provider == .eventKit else { return [] }

        let freshStore = EKEventStore()
        if let event = freshStore.event(withIdentifier: occurrence.eventID) {
            return Self.attendees(from: event)
        }

        let start = occurrence.originalStartTime.addingTimeInterval(-60)
        let end = occurrence.originalStartTime.addingTimeInterval(60)
        let predicate = freshStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        guard let event = freshStore.events(matching: predicate).first(where: {
            Self.occurrenceReference(
                for: $0,
                eventID: $0.eventIdentifier ?? "",
                startDate: $0.startDate
            ).identityKey == occurrence.identityKey
        }) else {
            return []
        }
        return Self.attendees(from: event)
    }

    // MARK: - Meeting URL Extraction

    /// Extract a meeting join URL from an EventKit event.
    /// Checks the event URL, location, and notes for known meeting link patterns.
    private static let meetingURLPattern: NSRegularExpression? = {
        let patterns = [
            "https://[a-z0-9.-]*zoom\\.us/j/[^\\s\"<>]+",
            "https://meet\\.google\\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}[^\\s\"<>]*",
            "https://teams\\.microsoft\\.com/l/meetup-join/[^\\s\"<>]+",
            "https://[a-z0-9.-]*webex\\.com/[^\\s\"<>]+/j\\.php[^\\s\"<>]*",
            "https://[a-z0-9.-]*chime\\.aws/[^\\s\"<>]+",
            "https://facetime\\.apple\\.com/join[^\\s\"<>]*",
            "https://app\\.slack\\.com/huddle/[A-Z0-9]+/[A-Z0-9]+[^\\s\"<>]*",
        ]
        return try? NSRegularExpression(pattern: "(\(patterns.joined(separator: "|")))", options: .caseInsensitive)
    }()

    static func extractMeetingURL(from event: EKEvent) -> URL? {
        // 1. Explicit event URL (set by calendar provider)
        if let url = event.url, isMeetingURL(url) {
            return url
        }

        // 2. Search location field
        if let location = event.location, let url = findMeetingURL(in: location) {
            return url
        }

        // 3. Search notes/description
        if let notes = event.notes, let url = findMeetingURL(in: notes) {
            return url
        }

        return nil
    }

    private static func isMeetingURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        // Slack: only huddle URLs are meetings; app.slack.com/client/... etc. are not.
        if host == "app.slack.com" {
            return url.path.hasPrefix("/huddle/")
        }
        let meetingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "webex.com", "chime.aws", "facetime.apple.com"]
        return meetingHosts.contains(where: { host.hasSuffix($0) })
    }

    static func findMeetingURL(in text: String) -> URL? {
        guard let regex = meetingURLPattern else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        guard let matchRange = Range(match.range, in: text) else { return nil }
        return URL(string: String(text[matchRange]))
    }

}
