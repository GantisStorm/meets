import Foundation
import SwiftUI
import MeetsCore

/// What a list says about a meeting. Derived once here so the browser, a
/// folder scope, and a calendar event's recordings agree on the words.
struct MeetingFacts: Equatable {
    /// The attached event, already resolved for display: the event's title, or
    /// `"Calendar meeting"` when the meeting carries a calendar event id whose
    /// title the caller could not load. nil when there is no attached event, so
    /// a meeting from a hotkey shows no event at all.
    let eventTitle: String?
    let peopleCount: Int
    let hasWrittenNotes: Bool
    let hasSummary: Bool
    let hasTranscript: Bool

    init(
        eventTitle: String?,
        peopleCount: Int,
        hasWrittenNotes: Bool,
        hasSummary: Bool,
        hasTranscript: Bool
    ) {
        self.eventTitle = eventTitle
        self.peopleCount = peopleCount
        self.hasWrittenNotes = hasWrittenNotes
        self.hasSummary = hasSummary
        self.hasTranscript = hasTranscript
    }

    /// `eventTitle` comes from the caller: the entry carries the event id, and
    /// only the view knows the calendar the event lives in.
    init(entry: MeetingBrowserEntry, eventTitle: String?) {
        self.init(
            eventTitle: Self.resolvedEventTitle(eventTitle, calendarEventID: entry.calendarEventID),
            peopleCount: entry.participantCount,
            hasWrittenNotes: entry.hasWrittenNotes,
            hasSummary: entry.hasSummary,
            hasTranscript: entry.hasTranscript
        )
    }

    /// A record carries no participants, so `peopleCount` comes from the
    /// caller — a store-backed caller reads it from `participantCounts`.
    init(record: MeetingRecord, eventTitle: String?, peopleCount: Int) {
        let entry = MeetingBrowserEntry(record: record)
        self.init(
            eventTitle: Self.resolvedEventTitle(eventTitle, calendarEventID: entry.calendarEventID),
            peopleCount: peopleCount,
            hasWrittenNotes: entry.hasWrittenNotes,
            hasSummary: entry.hasSummary,
            hasTranscript: entry.hasTranscript
        )
    }

    /// The facts line, joined into the one string every list renders. Empty
    /// when there is nothing to say, so a bare meeting keeps a bare row.
    var text: String {
        parts.joined(separator: " · ")
    }

    /// The wording, in one place: the attached event first, then people,
    /// written notes, and whether a summary exists.
    private var parts: [String] {
        var parts: [String] = []
        if let eventTitle {
            parts.append(eventTitle)
        }
        if peopleCount > 0 {
            parts.append(peopleCount == 1 ? "1 person" : "\(peopleCount) people")
        }
        if hasWrittenNotes {
            parts.append("Written notes")
        }
        if hasSummary {
            parts.append("Summary")
        } else if hasTranscript {
            parts.append("Transcript only")
        }
        return parts
    }

    private static func resolvedEventTitle(_ title: String?, calendarEventID: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        return calendarEventID == nil ? nil : "Calendar meeting"
    }
}

/// The facts line those lists render, in one place and one tone: the attached
/// event first, then people, written notes, and whether a summary exists.
/// Renders nothing when there is nothing to say, so a bare meeting keeps a
/// bare row.
struct MeetingFactsRow: View {
    let facts: MeetingFacts

    var body: some View {
        if !facts.text.isEmpty {
            Text(facts.text)
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
