import AppKit
import EventKit
import Foundation
import MuesliCore

/// Whether the app may read (and write) the user's Apple Calendar data.
enum CalendarAuthState: Equatable {
    case unknown
    case denied
    case writeOnly
    case fullAccess
}

/// A single event calendar exposed by EventKit (iCloud, On-My-Mac, Exchange,
/// CalDAV, a linked Internet Account calendar, a subscription, birthdays).
/// A value-only snapshot so EventKit objects never cross actor boundaries.
struct EKCalendarModel: Identifiable, Equatable, Sendable {
    /// EKCalendar.calendarIdentifier — stable across launches; persisted as the
    /// per-calendar enable/disable key in AppConfig.disabledCalendarIDs.
    let id: String
    let title: String
    /// RGB hex string like "1e2a3f" (no leading "#"), nil when the calendar
    /// has no color.
    let colorHex: String?
    /// EKSource.sourceIdentifier of the account owning this calendar.
    let accountID: String
    /// True when the calendar is fixed by the system (e.g. Birthdays) and
    /// cannot be created/renamed/deleted by callers.
    let isImmutable: Bool
    let allowsContentModifications: Bool
    let isBirthdays: Bool
    let isSubscription: Bool

    init(
        id: String,
        title: String,
        colorHex: String?,
        accountID: String,
        isImmutable: Bool,
        allowsContentModifications: Bool,
        isBirthdays: Bool,
        isSubscription: Bool
    ) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
        self.accountID = accountID
        self.isImmutable = isImmutable
        self.allowsContentModifications = allowsContentModifications
        self.isBirthdays = isBirthdays
        self.isSubscription = isSubscription
    }
}

extension EKCalendarModel {
    /// Map an EKCalendar (plus its source) to the value snapshot. Static and
    /// pure so it can run on background threads.
    static func from(_ calendar: EKCalendar, source: EKSource?) -> EKCalendarModel {
        EKCalendarModel(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            colorHex: hexString(from: calendar.cgColor),
            accountID: source?.sourceIdentifier ?? "",
            isImmutable: calendar.isImmutable,
            allowsContentModifications: calendar.allowsContentModifications,
            isBirthdays: calendar.type == .birthday,
            isSubscription: calendar.type == .subscription
        )
    }

    /// sRGB hex string ("rrggbb", lowercase) for a CGColor, or nil.
    static func hexString(from cgColor: CGColor?) -> String? {
        guard let cgColor, let nsColor = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else { return nil }
        let r = Int(round(nsColor.redComponent * 255))
        let g = Int(round(nsColor.greenComponent * 255))
        let b = Int(round(nsColor.blueComponent * 255))
        return String(format: "%02x%02x%02x", r, g, b)
    }
}

/// A calendar account/source exposed by EventKit (iCloud, Google/Exchange
/// linked through Internet Accounts, CalDAV servers, On-My-Mac, ...).
struct EKAccountModel: Identifiable, Equatable, Sendable {
    /// EKSource.sourceIdentifier.
    let id: String
    let title: String
    /// Human label for the source type ("iCloud", "Google", "Exchange",
    /// "CalDAV", "On My Mac").
    let typeLabel: String
    /// Whether this account is an Exchange or Google-backed account synced
    /// through an Internet Account. Such sources do not allow the app to
    /// rename or delete calendars.
    let isExchangeOrGoogle: Bool
    /// Whether this account is a plain CalDAV source.
    let isCalDAV: Bool

    init(id: String, title: String, typeLabel: String, isExchangeOrGoogle: Bool, isCalDAV: Bool) {
        self.id = id
        self.title = title
        self.typeLabel = typeLabel
        self.isExchangeOrGoogle = isExchangeOrGoogle
        self.isCalDAV = isCalDAV
    }
}

extension EKAccountModel {
    /// Map an EKSource to the value snapshot. Static and pure so it can run
    /// on background threads.
    static func from(_ source: EKSource) -> EKAccountModel {
        let type = source.sourceType
        let typeLabel: String
        let isExchangeOrGoogle: Bool
        let isCalDAV: Bool
        switch type {
        case .exchange:
            typeLabel = "Exchange"
            isExchangeOrGoogle = true
            isCalDAV = false
        case .calDAV:
            typeLabel = "CalDAV"
            isExchangeOrGoogle = false
            isCalDAV = true
        case .mobileMe:
            typeLabel = "iCloud"
            isExchangeOrGoogle = false
            isCalDAV = false
        case .local:
            typeLabel = "On My Mac"
            isExchangeOrGoogle = false
            isCalDAV = false
        case .subscribed:
            typeLabel = "Subscribed Calendars"
            isExchangeOrGoogle = false
            isCalDAV = false
        case .birthdays:
            typeLabel = "Birthdays"
            isExchangeOrGoogle = false
            isCalDAV = false
        @unknown default:
            typeLabel = "Calendar"
            isExchangeOrGoogle = false
            isCalDAV = false
        }
        return EKAccountModel(
            id: source.sourceIdentifier,
            title: source.title,
            typeLabel: typeLabel,
            isExchangeOrGoogle: isExchangeOrGoogle,
            isCalDAV: isCalDAV
        )
    }
}

// MARK: - Unified Calendar Event Model

/// A calendar event normalized across calendar providers. EventKit is the only
/// live provider; `.googleCalendar` remains as a decodable legacy value for
/// occurrence references persisted by older builds.
struct UnifiedCalendarEvent: Identifiable, Equatable {
    let id: String
    /// Occurrence-unique row identity. EventKit returns one EKEvent per
    /// recurrence instance sharing a single eventIdentifier, so keying rows
    /// by bare id collapses a Tue+Thu series into one row. Linkage maps keep
    /// using the bare eventIdentifier.
    var pickerRowID: String { "\(id)|\(startDate.timeIntervalSince1970)" }
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let source: CalendarSource
    /// Identifier of the calendar this event belongs to.
    /// EventKit: `EKCalendar.calendarIdentifier`.
    /// Optional because legacy events deserialized from older state may not have it.
    var calendarID: String? = nil
    var calendarOccurrence: CalendarOccurrenceReference? = nil
    var meetingURL: URL? = nil
    var attendees: [CalendarAttendee] = []
    /// Free-form location text carried by the event, if any.
    var location: String? = nil
    /// True when the event was cancelled on the calendar.
    var isCancelled: Bool = false
    /// True when the current user declined the event.
    var isDeclined: Bool = false

    enum CalendarSource: String {
        case eventKit
        case googleCalendar // legacy decodable only — never produced by new code

        var occurrenceProvider: CalendarOccurrenceReference.Provider {
            switch self {
            case .eventKit:
                return .eventKit
            case .googleCalendar:
                return .googleCalendar
            }
        }
    }

    var resolvedCalendarOccurrence: CalendarOccurrenceReference {
        calendarOccurrence ?? CalendarOccurrenceReference(
            provider: source.occurrenceProvider,
            calendarID: calendarID,
            eventID: id,
            originalStartTime: startDate
        )
    }

    /// Drop events whose `calendarID` is in `disabledCalendarIDs`. Events with `nil`
    /// calendarID always pass through (they predate per-calendar filtering).
    static func filter(
        _ events: [UnifiedCalendarEvent],
        disabledCalendarIDs: Set<String>
    ) -> [UnifiedCalendarEvent] {
        guard !disabledCalendarIDs.isEmpty else { return events }
        return events.filter { event in
            guard let id = event.calendarID else { return true }
            return !disabledCalendarIDs.contains(id)
        }
    }
}
