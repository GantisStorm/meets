import Foundation
import MuesliCore

// MARK: - Meeting ↔ Calendar Event linkage core
//
// Single source of truth for how a calendar event relates to recorded
// meetings. CalendarPageView/CalendarSettingsView/MeetingsView render through
// `MeetingEventLinkage`; MuesliController performs the mutations
// (`recordCalendarEvent`, `syncMeetingTitleWithCalendarEvent`,
// `handleCalendarEventChange`). Keep derivation pure and deterministic so the
// Calendar UI and the sync services never disagree.

// MARK: - State

/// Display-level state of one calendar event relative to the meetings store.
enum MeetingEventState: Equatable {
    case upcoming
    case now
    case recording
    case processing
    case completed
    case missed
    case cancelledEvent
    case noEvent

    var title: String {
        switch self {
        case .upcoming: return "Upcoming"
        case .now: return "Now"
        case .recording: return "Recording"
        case .processing: return "Processing"
        case .completed: return "Recorded"
        case .missed: return "Missed"
        case .cancelledEvent: return "Cancelled"
        case .noEvent: return "No meeting"
        }
    }

    var symbol: String {
        switch self {
        case .upcoming: return "clock"
        case .now: return "calendar.badge.clock"
        case .recording: return "record.circle"
        case .processing: return "waveform"
        case .completed: return "checkmark.circle.fill"
        case .missed: return "calendar.badge.minus"
        case .cancelledEvent: return "calendar.badge.exclamationmark"
        case .noEvent: return "calendar"
        }
    }

    /// Stable semantic token; consumers map it to their own palette.
    /// Values: "upcoming" | "now" | "recording" | "processing" | "completed"
    /// | "missed" | "cancelled" | "noEvent"
    var tintName: String {
        switch self {
        case .upcoming: return "upcoming"
        case .now: return "now"
        case .recording: return "recording"
        case .processing: return "processing"
        case .completed: return "completed"
        case .missed: return "missed"
        case .cancelledEvent: return "cancelled"
        case .noEvent: return "noEvent"
        }
    }
}

// MARK: - Linkage

/// Pure derivation of how one calendar event relates to recorded meetings.
/// Prefer `derive(event:meetings:now:isCurrentlyRecording:)` over building
/// this struct by hand so every consumer shares the same precedence rules.
struct MeetingEventLinkage {
    let event: UnifiedCalendarEvent?
    let state: MeetingEventState
    /// Meeting matched to this event (exact keys first, then title+window).
    let linkedMeeting: MeetingRecord?
    /// True when an active recording session belongs to this event (a linked
    /// meeting in `.recording` status). The app allows only one live session,
    /// so this is per-event, not global.
    let recordingInProgress: Bool
    /// True when the event is upcoming/now, not cancelled, and no recording is
    /// in flight — i.e. the Record affordance should be offered.
    let canRecord: Bool
    /// Join URL carried by the calendar event, if any.
    let joinURL: URL?
    /// True when the linked meeting's stored title is a stale calendar copy
    /// (see `MeetingCalendarLinkage.titleSyncDecision`). UI may surface this
    /// as an explicit "sync title" affordance.
    let needsTitleSync: Bool

    static func derive(
        event: UnifiedCalendarEvent?,
        meetings: [MeetingRecord],
        now: Date = Date(),
        isCurrentlyRecording: Bool = false
    ) -> MeetingEventLinkage {
        guard let event else {
            return MeetingEventLinkage(
                event: nil,
                state: .noEvent,
                linkedMeeting: nil,
                recordingInProgress: false,
                canRecord: false,
                joinURL: nil,
                needsTitleSync: false
            )
        }

        let isCancelled = event.isCancelled || event.isDeclined
        let linked = MeetingCalendarLinkage.linkedMeeting(event: event, meetings: meetings)
        let recordingInProgress = linked?.status == .recording

        let state: MeetingEventState
        if let linked {
            switch linked.status {
            case .recording:
                state = .recording
            case .processing:
                state = .processing
            default:
                // Past vs present decided below; `completed` also covers
                // `.noteOnly` and `.failed` (a failed recording still means
                // "an attempt exists for this event"; its needs-attention
                // detail is surfaced from the meeting row itself).
                if event.endDate <= now {
                    state = .completed
                } else if isCancelled {
                    state = .cancelledEvent
                } else if event.startDate > now {
                    state = .upcoming
                } else {
                    state = .now
                }
            }
        } else {
            if isCancelled {
                state = .cancelledEvent
            } else if event.startDate > now {
                state = .upcoming
            } else if event.endDate > now {
                state = .now
            } else {
                state = .missed
            }
        }

        let canRecord: Bool
        switch state {
        case .upcoming, .now:
            // "not already recording" = no live session anywhere in the app
            // (global guard) and none linked to this event.
            canRecord = !isCurrentlyRecording && !recordingInProgress && !isCancelled
        case .recording, .processing, .completed, .missed, .cancelledEvent, .noEvent:
            canRecord = false
        }

        let needsTitleSync = linked.map {
            MeetingCalendarLinkage.titleSyncDecision(
                event: event,
                meeting: $0,
                oldTitle: nil
            )
        } ?? false

        return MeetingEventLinkage(
            event: event,
            state: state,
            linkedMeeting: linked,
            recordingInProgress: recordingInProgress,
            canRecord: canRecord,
            joinURL: event.meetingURL,
            needsTitleSync: needsTitleSync
        )
    }
}

// MARK: - Matching & sync decisions

enum MeetingCalendarLinkage {
    /// ISO8601 parse of a meeting's stored `startTime` string. DictationStore
    /// persists with `ISO8601DateFormatter`, so this mirrors that format.
    static func meetingStartDate(_ meeting: MeetingRecord) -> Date? {
        ISO8601DateFormatter().date(from: meeting.startTime)
    }

    /// Case/whitespace-insensitive title comparison used by the fallback
    /// matcher. Diacritics are folded so "Café sync" ≈ "cafe sync".
    static func titlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let fold: (String) -> String = {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
        }
        return !lhs.isEmpty && fold(lhs) == fold(rhs)
    }

    /// Link keys a meeting exposes for calendar matching.
    private static func lookupKeys(for meeting: MeetingRecord) -> [String] {
        var keys: [String] = []
        if let id = meeting.calendarEventID { keys.append(id) }
        if let eventID = meeting.calendarOccurrence?.eventID { keys.append(eventID) }
        return keys
    }

    /// The recorded meeting for a calendar event, newest meeting first on
    /// ties. Matching precedence (deterministic, documented):
    ///
    /// 1. Occurrence identity key equality — per-instance identity that
    ///    survives EventKit identifier regeneration (recurring series use
    ///    the stable external identifier + original start). This is the only
    ///    match that can tell two instances of one recurring series apart.
    /// 2. Stored event identifier equality (`calendarEventID` or the
    ///    occurrence `eventID`). For recurring series these equal the series
    ///    master identifier, so an instance match is only returned when the
    ///    meeting's recorded occurrence start falls on this event's instance
    ///    start; otherwise no cross-instance link is made.
    /// 3. Title + time-window fallback: an entirely unlinked meeting (no
    ///    calendar keys) whose title matches the event and that started
    ///    within the event's span (±5 min grace) is treated as the recording
    ///    for this event. Manual recordings started mid-meeting with the
    ///    same title therefore still surface as recorded.
    static func linkedMeeting(
        event: UnifiedCalendarEvent,
        meetings: [MeetingRecord],
        now: Date = Date()
    ) -> MeetingRecord? {
        let occurrence = event.resolvedCalendarOccurrence
        let idMatches = meetings.filter {
            lookupKeys(for: $0).contains(event.id)
        }

        if let instanceMatch = idMatches.first(where: {
            $0.calendarOccurrence?.identityKey == occurrence.identityKey
        }) {
            return instanceMatch
        }

        if !idMatches.isEmpty {
            if occurrence.seriesID != nil {
                // Series-level identifier collision (recurring): only link the
                // instance whose recorded occurrence start is this instance.
                return idMatches.first { meeting in
                    guard let recordedStart = meeting.calendarOccurrence?.originalStartTime else {
                        return false
                    }
                    return abs(recordedStart.timeIntervalSince(event.startDate)) < 60
                }
            }
            return idMatches.first
        }

        if let byOccurrence = meetings.first(where: {
            $0.calendarOccurrence?.identityKey == occurrence.identityKey
        }) {
            return byOccurrence
        }

        // Fallback: unlinked meetings matched by title + event window.
        let start = event.startDate.addingTimeInterval(-5 * 60)
        let end = event.endDate.addingTimeInterval(5 * 60)
        return meetings.first { meeting in
            guard meeting.calendarEventID == nil,
                  meeting.calendarOccurrence == nil,
                  titlesMatch(meeting.title, event.title),
                  let meetingStart = meetingStartDate(meeting) else {
                return false
            }
            return meetingStart >= start && meetingStart <= end
        }
    }

    /// Whether a meeting's stored title should follow a calendar event's
    /// title. Auto-sync only ever overwrites a *calendar copy* of the title —
    /// never a user-authored one. Two admissible signals, deterministic:
    ///
    /// 1. `oldTitle` anchor (preferred, used by `handleCalendarEventChange`
    ///    which diffs pre/post-change event snapshots): the meeting's stored
    ///    title still equals the calendar's previous title, proving it was
    ///    copied from the calendar at record time and never renamed. An event
    ///    rename then propagates; a user rename (title != oldTitle) does not.
    /// 2. Fresh-copy heuristic (used when no old title is available, e.g.
    ///    explicit `syncMeetingTitleWithCalendarEvent` from the UI): the
    ///    meeting began within 2 minutes of the event's start, i.e. it was
    ///    created from this event. Manual edits are not persisted, so the
    ///    heuristic cannot observe them; a user rename made in the first two
    ///    minutes of a recording that is then followed by a calendar rename
    ///    is the one documented case where an explicit sync could overwrite
    ///    user text. The automatic change hook never relies on this path.
    static func titleSyncDecision(
        event: UnifiedCalendarEvent,
        meeting: MeetingRecord,
        oldTitle: String?
    ) -> Bool {
        guard meeting.title != event.title else { return false }
        guard linkedMeeting(event: event, meetings: [meeting]) != nil else { return false }

        if let oldTitle, !oldTitle.isEmpty {
            return meeting.title == oldTitle
        }

        guard let meetingStart = meetingStartDate(meeting) else { return false }
        return abs(meetingStart.timeIntervalSince(event.startDate)) <= 2 * 60
    }
}
