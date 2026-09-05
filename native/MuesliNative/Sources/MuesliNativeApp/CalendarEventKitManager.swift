import AppKit
import EventKit
import Foundation
import MuesliCore

/// Single owner of the app's `EKEventStore`.
///
/// EventKit docs recommend holding one long-lived store per app: stores cache
/// calendar data, and EventKit requires the store instance that created an
/// object to mutate it. Keeping the store alive as a property also makes
/// `EKEventStoreChangedNotification` observations stable.
@MainActor
final class CalendarEventKitManager {
    static let shared = CalendarEventKitManager()

    /// The one EKEventStore the app reads and writes calendars through.
    /// EventKit calendar/event objects created from other store instances are
    /// not editable; callers must go through this property.
    let store = EKEventStore()

    private init() {}

    // MARK: - Authorization

    var authorizationState: CalendarAuthState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return .fullAccess
        case .writeOnly:
            return .writeOnly
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    /// Whether the app can currently read event contents (not just write).
    var canReadEvents: Bool {
        authorizationState == .fullAccess
    }

    /// Whether an event absence observed within a fetch window can be trusted
    /// as a real absence (only true under full read access).
    var canConfirmMissingEvents: Bool {
        canReadEvents
    }

    /// Requests full calendar access. macOS 14+ uses
    /// `requestFullAccessToEvents()`; older systems fall back to the generic
    /// `requestAccess(to:)` (unreachable at this deployment target, kept for
    /// source compatibility). Returns true when full access was granted.
    func requestFullAccessToEvents() async -> Bool {
        do {
            if #available(macOS 14.0, *) {
                return try await store.requestFullAccessToEvents()
            } else {
                return try await store.requestAccess(to: .event)
            }
        } catch {
            fputs("[calendar] full-access request failed: \(error)\n", stderr)
            return false
        }
    }

    // MARK: - Calendars

    /// Every event calendar EventKit exposes, grouped by its owning account.
    /// Only accounts that own at least one event calendar are listed.
    func calendarsByAccount() -> [(account: EKAccountModel, calendars: [EKCalendarModel])] {
        guard canReadEvents else { return [] }
        let calendars = store.calendars(for: .event)
        let bySourceID = Dictionary(grouping: calendars) { $0.source?.sourceIdentifier ?? "" }
        var result: [(account: EKAccountModel, calendars: [EKCalendarModel])] = []
        for (sourceID, group) in bySourceID {
            guard let source = group.compactMap(\.source).first(where: { $0.sourceIdentifier == sourceID }) else { continue }
            let models = group
                .map { EKCalendarModel.from($0, source: source) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            result.append((account: EKAccountModel.from(source), calendars: models))
        }
        return result.sorted {
            if $0.account.title != $1.account.title {
                return $0.account.title.localizedCaseInsensitiveCompare($1.account.title) == .orderedAscending
            }
            return $0.account.typeLabel < $1.account.typeLabel
        }
    }

    /// All event calendars as flat value snapshots, sorted by account then title.
    func allCalendars() -> [EKCalendarModel] {
        guard canReadEvents else { return [] }
        return store.calendars(for: .event)
            .map { EKCalendarModel.from($0, source: $0.source) }
            .sorted { lhs, rhs in
                if lhs.accountID != rhs.accountID {
                    return lhs.accountID < rhs.accountID
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    // MARK: - Events

    /// Fetches events in `start...end` from the given calendars (nil = all).
    /// Includes all-day events and events the user cancelled or declined, each
    /// flagged so callers can filter or display them distinctly. Detached
    /// recurring instances carry their own occurrence reference.
    func events(
        from start: Date,
        to end: Date,
        calendars: [EKCalendarModel]? = nil
    ) -> [UnifiedCalendarEvent] {
        guard canReadEvents else { return [] }
        let ekCalendars: [EKCalendar]? = calendars?.compactMap { model in
            store.calendar(withIdentifier: model.id)
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: ekCalendars)
        return store.events(matching: predicate).compactMap { event -> UnifiedCalendarEvent? in
            guard let startDate = event.startDate, let endDate = event.endDate else { return nil }
            let eventID = event.eventIdentifier ?? UUID().uuidString
            return UnifiedCalendarEvent(
                id: eventID,
                title: event.title ?? "Meeting",
                startDate: startDate,
                endDate: endDate,
                isAllDay: event.isAllDay,
                source: .eventKit,
                calendarID: event.calendar?.calendarIdentifier,
                calendarOccurrence: CalendarMonitor.occurrenceReference(
                    for: event,
                    eventID: eventID,
                    startDate: startDate
                ),
                meetingURL: CalendarMonitor.extractMeetingURL(from: event),
                attendees: CalendarMonitor.attendees(from: event),
                location: event.location,
                isCancelled: event.status == .canceled,
                isDeclined: Self.isDeclined(event)
            )
        }
    }

    /// True when the current user declined the event. Matches the current
    /// user's attendee entry (EKParticipant.isCurrentUser); events without an
    /// attendee list (e.g. untitled local events) cannot be declined.
    private static func isDeclined(_ event: EKEvent) -> Bool {
        guard let attendees = event.attendees, !attendees.isEmpty else { return false }
        for attendee in attendees where attendee.participantStatus == .declined {
            if attendee.isCurrentUser {
                return true
            }
            if let organizerURL = event.organizer?.url, attendee.url == organizerURL {
                return true
            }
        }
        return false
    }

    // MARK: - Calendar mutations

    /// Deletes a calendar and all its events. Respects EventKit's immutability
    /// and content-modification constraints; returns false (with a log) when
    /// the calendar cannot be deleted or the operation fails.
    @discardableResult
    func deleteCalendar(id: String) -> Bool {
        guard canReadEvents else {
            fputs("[calendar] delete rejected: no calendar access\n", stderr)
            return false
        }
        guard let calendar = store.calendar(withIdentifier: id) else {
            fputs("[calendar] delete rejected: unknown calendar \(id)\n", stderr)
            return false
        }
        guard !calendar.isImmutable, calendar.allowsContentModifications else {
            fputs("[calendar] delete rejected: calendar \(id) is immutable or read-only\n", stderr)
            return false
        }
        do {
            try store.removeCalendar(calendar, commit: true)
            return true
        } catch {
            fputs("[calendar] delete failed for \(id): \(error)\n", stderr)
            return false
        }
    }

    /// Renames a calendar. Respects the same EventKit constraints as deletion;
    /// the new title is trimmed and must be non-empty.
    @discardableResult
    func renameCalendar(id: String, to newTitle: String) -> Bool {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            fputs("[calendar] rename rejected: empty title\n", stderr)
            return false
        }
        guard canReadEvents else {
            fputs("[calendar] rename rejected: no calendar access\n", stderr)
            return false
        }
        guard let calendar = store.calendar(withIdentifier: id) else {
            fputs("[calendar] rename rejected: unknown calendar \(id)\n", stderr)
            return false
        }
        guard !calendar.isImmutable, calendar.allowsContentModifications else {
            fputs("[calendar] rename rejected: calendar \(id) is immutable or read-only\n", stderr)
            return false
        }
        calendar.title = trimmed
        do {
            try store.saveCalendar(calendar, commit: true)
            return true
        } catch {
            fputs("[calendar] rename failed for \(id): \(error)\n", stderr)
            return false
        }
    }
}
