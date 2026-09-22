import Foundation
import SwiftUI
import MeetsCore

/// One drawn fact: a symbol with the words it stands for, kept together so a
/// screen reader and a tooltip still say "Written notes".
struct MeetingFactSymbol: Equatable, Identifiable {
    let name: String
    let label: String
    var id: String { name }
}

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
        words.joined(separator: " · ")
    }

    /// Every fact in words, in the line's order: what a text-only surface and
    /// the row's accessibility label read.
    var words: [String] {
        facts.map { fact in
            switch fact {
            case let .words(words):
                return words
            case let .symbol(symbol):
                return symbol.label
            }
        }
    }

    /// The facts that spell themselves out — the attached event and the people
    /// count — in the line's order. A drawn fact is not written out again: the
    /// symbol is the statement, and `words` still carries what it stands for.
    var spelledWords: [String] {
        facts.compactMap { fact in
            switch fact {
            case let .words(words):
                return words
            case .symbol:
                return nil
            }
        }
    }

    /// The facts that draw as a symbol instead of spelling themselves out, in
    /// the line's order. Their words stay in `words` for everything that reads.
    var symbols: [MeetingFactSymbol] {
        facts.compactMap { fact in
            switch fact {
            case .words:
                return nil
            case let .symbol(symbol):
                return symbol
            }
        }
    }

    /// The wording, in one place: the attached event first, then people,
    /// written notes, and whether a summary exists. The event and the people
    /// count are always words; the rest draws as the symbol the meeting page
    /// already uses for the same thing. A summary replaces the transcript
    /// rather than joining it.
    private var facts: [Fact] {
        var facts: [Fact] = []
        if let eventTitle {
            facts.append(.words(eventTitle))
        }
        if peopleCount > 0 {
            facts.append(.words(peopleCount == 1 ? "1 person" : "\(peopleCount) people"))
        }
        if hasWrittenNotes {
            facts.append(.symbol(MeetingFactSymbol(name: "square.and.pencil", label: "Written notes")))
        }
        if hasSummary {
            facts.append(.symbol(MeetingFactSymbol(name: "sparkles", label: "Summary")))
        } else if hasTranscript {
            facts.append(.symbol(MeetingFactSymbol(name: "doc.plaintext", label: "Transcript only")))
        }
        return facts
    }

    /// One fact of the line: words it spells out, or a symbol with the words
    /// it stands for.
    private enum Fact {
        case words(String)
        case symbol(MeetingFactSymbol)
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
/// event first, then people, written notes, and whether a summary exists. The
/// event and the people count spell themselves out; notes, a summary, and a
/// bare transcript draw as the symbol the rest of the app uses for them.
/// Renders nothing when there is nothing to say, so a bare meeting keeps a
/// bare row.
///
/// `drawsSymbols` is `false` for a caller that already draws them: the ledger
/// keeps the symbols next to the row's title, so its facts line carries only
/// the words.
struct MeetingFactsRow: View {
    let facts: MeetingFacts
    var drawsSymbols = true

    var body: some View {
        if !facts.text.isEmpty {
            HStack(spacing: 6) {
                if !facts.spelledWords.isEmpty {
                    Text(facts.spelledWords.joined(separator: " · "))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if drawsSymbols {
                    MeetingFactSymbols(facts: facts)
                }
            }
            .font(MeetsTheme.caption())
            .foregroundStyle(MeetsTheme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The facts that draw as symbols, in the line's order, with the words they
/// stand for kept for a tooltip and for a reader that cannot see them.
struct MeetingFactSymbols: View {
    let facts: MeetingFacts

    var body: some View {
        HStack(spacing: 6) {
            ForEach(facts.symbols) { symbol in
                Image(systemName: symbol.name)
                    .help(symbol.label)
                    .accessibilityLabel(symbol.label)
            }
        }
    }
}
