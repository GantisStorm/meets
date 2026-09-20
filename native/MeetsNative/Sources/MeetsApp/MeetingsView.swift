import SwiftUI
import MeetsCore

// DIRECTION — Meetings browser (seed 0e51c253, Operate, distilled)
// THESIS: A list of meetings by day. Text and spacing only.
// FIRST VIEWPORT: title, a line of folders, a plain toolbar, "Today",
//   rows of time · title · duration. Nothing filled, nothing bordered.
// MATERIAL: base canvas; hover fill is the only surface. Three text tones.
// MOTION: none authored; native hover only.
// REFUSE: cards, chips, pills, badges, counts, rules, previews, icons in rows.

enum MeetingBrowserFilter: Hashable {
    case all, last2Days, lastWeek, last2Weeks, lastMonth, last3Months

    var label: String {
        switch self {
        case .all: return "All time"
        case .last2Days: return "Last 2 days"
        case .lastWeek: return "Last week"
        case .last2Weeks: return "Last 2 weeks"
        case .lastMonth: return "Last month"
        case .last3Months: return "Last 3 months"
        }
    }
}

enum MeetingBrowserSort: Hashable {
    case newestFirst
    case oldestFirst

    var label: String {
        switch self {
        case .newestFirst: return "Newest first"
        case .oldestFirst: return "Oldest first"
        }
    }
}

/// A predecessor that is not part of the shelf it is displayed in, so a scoped
/// shelf root can still navigate up to the meeting it follows on from.
struct MeetingBrowserParentLink: Equatable {
    let id: Int64
    let title: String
}

/// One meeting inside a rendered shelf. `record` is present only for meetings
/// inside the recently loaded window; everything else comes from the
/// lightweight browse index, so a shelf can show members the browser never
/// loaded in full.
struct MeetingBrowserNode: Identifiable {
    let entry: MeetingBrowserEntry
    /// Parsed start time, `.distantPast` when the timestamp does not parse.
    /// Carried on the node so the ledger can place every row in its date
    /// section without parsing a date again on each render.
    let startDate: Date
    let record: MeetingRecord?
    /// Predecessor to link to when it sits outside this shelf.
    let externalParent: MeetingBrowserParentLink?
    /// Predecessor title, set when the row should name the meeting it follows
    /// on from: its parent is outside this shelf, or the row sits past the
    /// indentation cap and indentation alone no longer carries the hierarchy.
    let parentLinkTitle: String?
    /// False when the meeting is shown only to keep a matching descendant's
    /// thread context.
    let matchesFilter: Bool
    /// Nesting depth inside its shelf; the shelf root is 0.
    let depth: Int

    var id: Int64 { entry.id }
}

/// A follow-up family rendered as one unit: the root meeting, then every
/// descendant in thread order. `descendants` is flat and pre-ordered, carrying
/// its own `depth`, so arbitrarily deep branches never recurse.
struct MeetingBrowserShelf: Identifiable {
    let id: Int64
    let root: MeetingBrowserNode
    let descendants: [MeetingBrowserNode]
    /// Meetings in this shelf that satisfy the active date filter.
    let matchCount: Int
    /// Newest (or oldest, following the active sort) meeting time in the shelf.
    let activity: Date

    var nodes: [MeetingBrowserNode] { [root] + descendants }
    var totalCount: Int { descendants.count + 1 }
    var contextCount: Int { totalCount - matchCount }
}

struct MeetingBrowserShelfPresentation {
    let shelves: [MeetingBrowserShelf]
    let meetingIDsWithFollowUps: Set<Int64>
    /// Meetings matching the date filter. Ancestors retained for context are
    /// not counted, so the header never over-reports a range.
    let matchCount: Int
    /// Meetings rendered, including context ancestors.
    let displayedCount: Int
    /// Oldest start date across everything in scope, so the date-range menu can
    /// be derived from the same pass that built the shelves instead of walking
    /// every meeting a second time.
    let oldestStartDate: Date?

    var contextCount: Int { max(0, displayedCount - matchCount) }

    static let empty = MeetingBrowserShelfPresentation(
        shelves: [],
        meetingIDsWithFollowUps: [],
        matchCount: 0,
        displayedCount: 0,
        oldestStartDate: nil
    )
}

/// The date section a ledger group covers. Sections are coarse on purpose:
/// the ledger's spine says where in time a meeting sits, not which day of the
/// calendar it was.
enum MeetingLedgerSectionKind: Hashable {
    case today
    case yesterday
    case earlierThisWeek
    case lastWeek
    case month(year: Int, month: Int)

    /// Heading text. Named days and weeks need no date; a month heading names
    /// its year only when the year is not the current one, so the common case
    /// stays a single word.
    func title(now: Date, calendar: Calendar, locale: Locale) -> String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .earlierThisWeek: return "Earlier this week"
        case .lastWeek: return "Last week"
        case let .month(year, month):
            let name = MeetingBrowserLogic.monthName(month, locale: locale, timeZone: calendar.timeZone)
            return year == calendar.component(.year, from: now) ? name : "\(name) \(year)"
        }
    }
}

/// A run of rows that share one date section: the pinned heading and
/// everything under it.
///
/// Rows arrive already time-sorted, so a section is one consecutive run of
/// them and the section kind is the group's whole identity. Sorting by each
/// row's own start time is what keeps a kind from ever repeating.
struct MeetingLedgerGroup: Identifiable {
    let kind: MeetingLedgerSectionKind
    var rows: [MeetingBrowserNode]

    var id: MeetingLedgerSectionKind { kind }
}

enum MeetingBrowserLogic {
    /// Deepest nesting level that still earns extra indentation. Descendants
    /// below it keep their place in the shelf and instead name the parent they
    /// hang from, so nothing is dropped from view.
    static let indentationCapDepth = 3

    static func availableFilters(
        for meetings: [MeetingRecord],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [MeetingBrowserFilter] {
        availableFilters(forStartTimes: meetings.map(\.startTime), now: now, calendar: calendar)
    }

    static func availableFilters(
        forStartTimes startTimes: [String],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [MeetingBrowserFilter] {
        availableFilters(
            oldestStartDate: startTimes.compactMap(parseDate).min(),
            now: now,
            calendar: calendar
        )
    }

    /// Ranges worth offering, from the oldest start date already computed while
    /// building the shelves.
    static func availableFilters(
        oldestStartDate: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [MeetingBrowserFilter] {
        var filters: [MeetingBrowserFilter] = [.all]
        guard let oldest = oldestStartDate else { return filters }
        let daysSinceOldest = calendar.dateComponents([.day], from: oldest, to: now).day ?? 0

        if daysSinceOldest >= 1 { filters.append(.last2Days) }
        if daysSinceOldest >= 3 { filters.append(.lastWeek) }
        if daysSinceOldest >= 8 { filters.append(.last2Weeks) }
        if daysSinceOldest >= 15 { filters.append(.lastMonth) }
        if daysSinceOldest >= 31 { filters.append(.last3Months) }

        return filters
    }

    /// The label in a row's time gutter. It carries exactly as much date as the
    /// section heading above it does not: nothing but the time for today and
    /// yesterday, the weekday for the named weeks, and the day of the month
    /// once the section is a month. `kind` is the section of the row's *own*
    /// date, which is the section the row is filed under. Seconds are never
    /// shown: a ledger is scanned, not audited.
    static func ledgerGutterLabel(
        for date: Date,
        in kind: MeetingLedgerSectionKind,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let timeZone = calendar.timeZone
        let time = dateFormatters.string(from: date, template: "jm", locale: locale, timeZone: timeZone)
        switch kind {
        case .today, .yesterday:
            return time
        case .earlierThisWeek, .lastWeek:
            let weekday = dateFormatters.string(from: date, template: "EEE", locale: locale, timeZone: timeZone)
            return "\(weekday) \(time)"
        case .month:
            let day = dateFormatters.string(from: date, template: "d", locale: locale, timeZone: timeZone)
            return "\(day) \u{00B7} \(time)"
        }
    }

    /// Which section a meeting belongs to. Weeks follow the calendar's own
    /// first weekday, so "earlier this week" means what the user's calendar
    /// says it means. A future date — a scheduled meeting that has not
    /// happened yet — reads as today, because that is when the user meets it.
    static func ledgerSectionKind(
        for date: Date,
        now: Date,
        calendar: Calendar
    ) -> MeetingLedgerSectionKind {
        if date > now { return .today }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else {
            return monthKind(for: date, calendar: calendar)
        }
        if date >= thisWeek { return .earlierThisWeek }
        if let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek), date >= lastWeek {
            return .lastWeek
        }
        return monthKind(for: date, calendar: calendar)
    }

    /// Every node in the shelves — roots and descendants alike — as one flat,
    /// time-sorted list of rows.
    ///
    /// The ledger is a list of meetings by day, so a follow-up is filed under
    /// its own date rather than under the meeting it follows on from. The sort
    /// follows the active sort, is stable — rows sharing a timestamp keep the
    /// order the shelves gave them, which is thread order — and puts a row
    /// whose timestamp does not parse last either way rather than landing it
    /// among the dated ones.
    ///
    /// `startDate` is already parsed when the node is built, so the ordering
    /// reads that value instead of parsing every timestamp a second time;
    /// `.distantPast` is the sentinel `shelves` writes for an unparseable
    /// timestamp.
    static func flatRows(
        from shelves: [MeetingBrowserShelf],
        sort: MeetingBrowserSort
    ) -> [MeetingBrowserNode] {
        func sortableDate(_ node: MeetingBrowserNode) -> Date? {
            node.startDate == .distantPast ? nil : node.startDate
        }
        return shelves
            .flatMap(\.nodes)
            .enumerated()
            .sorted { left, right in
                switch (sortableDate(left.element), sortableDate(right.element)) {
                case let (leftDate?, rightDate?):
                    guard leftDate != rightDate else { return left.offset < right.offset }
                    return sort == .newestFirst ? leftDate > rightDate : leftDate < rightDate
                case (nil, nil):
                    return left.offset < right.offset
                case (nil, _):
                    return false
                case (_, nil):
                    return true
                }
            }
            .map(\.element)
    }

    /// Date sections for an already time-sorted row list.
    ///
    /// Because the rows arrive in date order, a section is one consecutive run
    /// of them and its kind never repeats. An unparseable timestamp still lands
    /// in a section rather than disappearing: the sentinel date reads as the
    /// oldest month there is.
    static func ledgerGroups(
        from rows: [MeetingBrowserNode],
        now: Date,
        calendar: Calendar
    ) -> [MeetingLedgerGroup] {
        var groups: [MeetingLedgerGroup] = []
        for row in rows {
            let kind = ledgerSectionKind(for: row.startDate, now: now, calendar: calendar)
            if let last = groups.indices.last, groups[last].kind == kind {
                groups[last].rows.append(row)
                continue
            }
            groups.append(MeetingLedgerGroup(kind: kind, rows: [row]))
        }
        return groups
    }

    /// Standalone month name for a month number, from the same bounded
    /// formatter cache every other browser date uses.
    static func monthName(_ month: Int, locale: Locale, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = 2000
        components.month = month
        components.day = 1
        guard let date = calendar.date(from: components) else { return "" }
        return dateFormatters.string(from: date, template: "LLLL", locale: locale, timeZone: timeZone)
    }

    private static func monthKind(
        for date: Date,
        calendar: Calendar
    ) -> MeetingLedgerSectionKind {
        let components = calendar.dateComponents([.year, .month], from: date)
        return .month(year: components.year ?? 0, month: components.month ?? 0)
    }

    /// Flat, shelf-ordered meeting list. Follow-up families stay together and
    /// in thread order, which is the same result as a plain date sort when no
    /// meeting has a follow-up.
    static func filteredMeetings(
        from meetings: [MeetingRecord],
        filter: MeetingBrowserFilter,
        sort: MeetingBrowserSort,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [MeetingRecord] {
        let recordsByID = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return shelves(
            entries: meetings.map(MeetingBrowserEntry.init(record:)),
            records: meetings,
            filter: filter,
            sort: sort,
            now: now,
            calendar: calendar
        ).shelves.flatMap { shelf in
            shelf.nodes.compactMap { recordsByID[$0.id] }
        }
    }

    /// Builds the follow-up shelves for one folder scope.
    ///
    /// - Parameters:
    ///   - entries: the complete, text-free browse index for the scope.
    ///   - records: the recently loaded full records; whichever of these are
    ///     missing from `entries` are added so the browser still works when the
    ///     index read fails.
    ///
    /// A meeting whose predecessor is outside the scope becomes the root of a
    /// scoped shelf and links to that predecessor. Meetings that only exist to
    /// keep a matching descendant's context are retained but excluded from
    /// `matchCount`. Follow-up cycles and self-links are broken at the lowest
    /// id on the cycle so every member renders exactly once.
    static func shelves(
        entries: [MeetingBrowserEntry],
        records: [MeetingRecord] = [],
        filter: MeetingBrowserFilter,
        sort: MeetingBrowserSort,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> MeetingBrowserShelfPresentation {
        var universe: [Int64: MeetingBrowserEntry] = [:]
        universe.reserveCapacity(entries.count + records.count)
        for entry in entries { universe[entry.id] = entry }
        for record in records where universe[record.id] == nil {
            universe[record.id] = MeetingBrowserEntry(record: record)
        }
        guard !universe.isEmpty else { return .empty }

        var recordsByID: [Int64: MeetingRecord] = [:]
        recordsByID.reserveCapacity(records.count)
        for record in records { recordsByID[record.id] = record }

        // Follow-up edges. `parentByID` keeps only links whose predecessor is
        // visible in this scope, so traversal never leaves the scope;
        // `linkByID` keeps every real link so a child whose predecessor sits
        // outside the scope can still name it. The "has follow-ups" indicator
        // is scope-wide, matching indexing the scoped slice before filtering.
        var parentByID: [Int64: Int64] = [:]
        var linkByID: [Int64: Int64] = [:]
        var meetingIDsWithFollowUps = Set<Int64>()
        for entry in universe.values {
            guard let parentID = entry.followUpToID, parentID != entry.id else { continue }
            linkByID[entry.id] = parentID
            meetingIDsWithFollowUps.insert(parentID)
            if universe[parentID] != nil {
                parentByID[entry.id] = parentID
            }
        }

        let threshold = threshold(for: filter, now: now, calendar: calendar)
        var dateByID: [Int64: Date] = [:]
        dateByID.reserveCapacity(universe.count)
        var oldestStartDate: Date?
        var matches: Set<Int64> = []
        for (id, entry) in universe {
            // One parse per meeting for the whole build: the same value feeds
            // ordering, family activity, and the date range check.
            let date = parseDate(entry.startTime)
            dateByID[id] = date ?? .distantPast
            if let date, oldestStartDate.map({ date < $0 }) ?? true {
                oldestStartDate = date
            }
            if isAfterThreshold(date, threshold: threshold) {
                matches.insert(id)
            }
        }
        guard !matches.isEmpty else {
            return MeetingBrowserShelfPresentation(
                shelves: [],
                meetingIDsWithFollowUps: meetingIDsWithFollowUps,
                matchCount: 0,
                displayedCount: 0,
                oldestStartDate: oldestStartDate
            )
        }

        // Keep every match plus the ancestors that explain where it came from.
        var retained = matches
        for id in matches {
            var cursor = parentByID[id]
            while let parentID = cursor, retained.insert(parentID).inserted {
                cursor = parentByID[parentID]
            }
        }

        // Break every follow-up cycle at the lowest id *on the cycle*, so the
        // walk still reaches the whole thread. A meeting has at most one
        // predecessor, so a cycle is always a closed loop of links; a lower-id
        // leaf hanging off that loop must stay a descendant, not become a root.
        var resolved: Set<Int64> = []
        for start in retained.sorted() where !resolved.contains(start) {
            var path: [Int64] = []
            var positionByID: [Int64: Int] = [:]
            var current: Int64? = start
            while let node = current {
                if let position = positionByID[node] {
                    if let breaker = path[position...].min() {
                        parentByID.removeValue(forKey: breaker)
                    }
                    break
                }
                if resolved.contains(node) { break }
                positionByID[node] = path.count
                path.append(node)
                current = parentByID[node].flatMap { retained.contains($0) ? $0 : nil }
            }
            resolved.formUnion(path)
        }

        // Roots: anything whose predecessor is absent from this scope.
        let rootIDs = retained
            .filter { id in
                guard let parentID = parentByID[id] else { return true }
                return !retained.contains(parentID)
            }
            .sorted()

        var childrenByID: [Int64: [Int64]] = [:]
        childrenByID.reserveCapacity(retained.count)
        for id in retained {
            guard let parentID = parentByID[id], retained.contains(parentID) else { continue }
            childrenByID[parentID, default: []].append(id)
        }
        childrenByID = childrenByID.mapValues { childIDs in
            childIDs.sorted { lhs, rhs in
                let lhsDate = dateByID[lhs] ?? .distantPast
                let rhsDate = dateByID[rhs] ?? .distantPast
                return lhsDate == rhsDate ? lhs < rhs : lhsDate < rhsDate
            }
        }

        // Thread order, iteratively: descendants depth first, siblings in
        // chronological order.
        var depthByID: [Int64: Int] = [:]
        var visited: Set<Int64> = []
        var rootOrder: [Int64] = []
        var descendantOrder: [Int64: [Int64]] = [:]
        func walk(from root: Int64) -> [Int64] {
            var stack: [(id: Int64, depth: Int)] = [(root, 0)]
            var preorder: [Int64] = []
            while let top = stack.popLast() {
                guard visited.insert(top.id).inserted else { continue }
                depthByID[top.id] = top.depth
                preorder.append(top.id)
                for child in (childrenByID[top.id] ?? []).reversed() {
                    stack.append((child, top.depth + 1))
                }
            }
            return Array(preorder.dropFirst())
        }
        for root in rootIDs where !visited.contains(root) {
            rootOrder.append(root)
            descendantOrder[root] = walk(from: root)
        }
        // Completeness backstop: a retained meeting the family walk could not
        // reach still renders as its own shelf rather than disappearing.
        for id in retained.sorted() where !visited.contains(id) {
            rootOrder.append(id)
            descendantOrder[id] = walk(from: id)
        }

        func makeNode(_ id: Int64, shelfMembers: Set<Int64>) -> MeetingBrowserNode {
            let record = recordsByID[id]
            // `retained` only ever holds ids present in `universe`; the default
            // keeps the node renderable if that invariant is ever broken.
            let entry = universe[id] ?? MeetingBrowserEntry(
                id: id,
                title: record?.title ?? "Untitled meeting",
                startTime: record?.startTime ?? "",
                durationSeconds: record?.durationSeconds ?? 0,
                folderID: record?.folderID,
                status: record?.status ?? .completed
            )
            let depth = depthByID[id] ?? 0
            let parentID = linkByID[id]
            let parentIsInShelf = parentID.map(shelfMembers.contains) ?? false
            let parentTitle = parentID.flatMap { parent in
                entry.predecessorTitle ?? universe[parent]?.title
            }
            var externalParent: MeetingBrowserParentLink?
            if let parentID, let parentTitle, !parentIsInShelf {
                externalParent = MeetingBrowserParentLink(id: parentID, title: parentTitle)
            }
            let showsParentLink = externalParent != nil
                || (parentID != nil && parentTitle != nil && depth > indentationCapDepth)
            return MeetingBrowserNode(
                entry: entry,
                startDate: dateByID[id] ?? .distantPast,
                record: record,
                externalParent: externalParent,
                parentLinkTitle: showsParentLink ? parentTitle : nil,
                matchesFilter: matches.contains(id),
                depth: depth
            )
        }

        var shelfList: [MeetingBrowserShelf] = []
        shelfList.reserveCapacity(rootOrder.count)
        for root in rootOrder {
            let descendantIDs = descendantOrder[root] ?? []
            let memberIDs = [root] + descendantIDs
            let shelfMembers = Set(memberIDs)
            // Order by the meetings that actually matched, so a retained older
            // ancestor never decides where a filtered shelf sorts.
            let matchingDates = memberIDs.filter { matches.contains($0) }.compactMap { dateByID[$0] }
            let activity = (sort == .newestFirst ? matchingDates.max() : matchingDates.min()) ?? .distantPast
            let matchCount = memberIDs.reduce(into: 0) { total, id in
                if matches.contains(id) { total += 1 }
            }
            shelfList.append(MeetingBrowserShelf(
                id: root,
                root: makeNode(root, shelfMembers: shelfMembers),
                descendants: descendantIDs.map { makeNode($0, shelfMembers: shelfMembers) },
                matchCount: matchCount,
                activity: activity
            ))
        }

        shelfList.sort { lhs, rhs in
            if lhs.activity != rhs.activity {
                return sort == .newestFirst ? lhs.activity > rhs.activity : lhs.activity < rhs.activity
            }
            return lhs.id < rhs.id
        }

        return MeetingBrowserShelfPresentation(
            shelves: shelfList,
            meetingIDsWithFollowUps: meetingIDsWithFollowUps,
            matchCount: matches.count,
            displayedCount: shelfList.reduce(0) { $0 + $1.totalCount },
            oldestStartDate: oldestStartDate
        )
    }

    private static func threshold(
        for filter: MeetingBrowserFilter,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        switch filter {
        case .all:
            return nil
        case .last2Days:
            return calendar.date(byAdding: .day, value: -2, to: now)
        case .lastWeek:
            return calendar.date(byAdding: .day, value: -7, to: now)
        case .last2Weeks:
            return calendar.date(byAdding: .day, value: -14, to: now)
        case .lastMonth:
            return calendar.date(byAdding: .month, value: -1, to: now)
        case .last3Months:
            return calendar.date(byAdding: .month, value: -3, to: now)
        }
    }

    private static func isAfterThreshold(_ date: Date?, threshold: Date?) -> Bool {
        guard let threshold else { return true }
        guard let date else { return false }
        return date >= threshold
    }

    static func parseDate(_ raw: String) -> Date? {
        isoParsers.lazy.compactMap { $0.date(from: raw) }.first
            ?? localParsers.lazy.compactMap { $0.date(from: raw) }.first
    }

    /// Full start timestamp — "Jan 15, 2026 at 3:04:12 PM" in the active
    /// locale. Export, detail, and help text use this one; lists use the
    /// concise `formatListDate` instead.
    static func formatStartTime(
        _ raw: String,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        guard let date = parseDate(raw) else {
            return formatStartTimeFallback(raw)
        }
        return dateFormatters.string(from: date, template: nil, locale: locale, timeZone: timeZone)
    }

    /// Concise list date: "Today · 3:04 PM", "Yesterday · 9:12 AM", or an
    /// abbreviated date and seconds-free time. Library rows format every
    /// visible meeting, so the heavy formatters stay cached and a day name
    /// replaces the date whenever the meeting is recent enough to name.
    static func formatListDate(
        _ raw: String,
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        calendar: Calendar = .current
    ) -> String {
        guard let date = parseDate(raw) else {
            return formatStartTimeFallback(raw)
        }
        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = "Today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(date, inSameDayAs: yesterday) {
            day = "Yesterday"
        } else {
            let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
            day = dateFormatters.string(
                from: date,
                template: sameYear ? "MMMd" : "yMMMd",
                locale: locale,
                timeZone: timeZone
            )
        }
        let time = dateFormatters.string(from: date, template: "jm", locale: locale, timeZone: timeZone)
        return "\(day) \u{00B7} \(time)"
    }

    /// Bounded cache of display formatters. The browser formats a date for
    /// every rendered row, and building a `DateFormatter` per call costs more
    /// than the format itself. Keyed by template, locale, and time zone; capped
    /// so callers that vary them cannot grow it without bound. Formatting
    /// happens under the lock because `DateFormatter` is not safe to share
    /// across threads. A nil template means the full medium date and time.
    private final class DateFormatterCache: @unchecked Sendable {
        private struct Key: Hashable {
            let template: String?
            let locale: String
            let timeZone: String
        }

        private let lock = NSLock()
        private var storage: [Key: DateFormatter] = [:]
        private var order: [Key] = []
        private let limit = 12

        func string(from date: Date, template: String?, locale: Locale, timeZone: TimeZone) -> String {
            lock.lock()
            defer { lock.unlock() }
            return formatter(template: template, locale: locale, timeZone: timeZone).string(from: date)
        }

        private func formatter(template: String?, locale: Locale, timeZone: TimeZone) -> DateFormatter {
            let key = Key(template: template, locale: locale.identifier, timeZone: timeZone.identifier)
            if let cached = storage[key] { return cached }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            if let template {
                formatter.setLocalizedDateFormatFromTemplate(template)
            } else {
                formatter.dateStyle = .medium
                formatter.timeStyle = .medium
            }
            if order.count >= limit, let oldest = order.first {
                order.removeFirst()
                storage.removeValue(forKey: oldest)
            }
            order.append(key)
            storage[key] = formatter
            return formatter
        }
    }

    private static let dateFormatters = DateFormatterCache()

    private static func formatStartTimeFallback(_ raw: String) -> String {
        let clean = raw.replacingOccurrences(of: "T", with: " ")
        if clean.count > 16 {
            return String(clean.prefix(16))
        }
        return clean
    }

    private static let isoParsers: [ISO8601DateFormatter] = {
        let iso1 = ISO8601DateFormatter()
        iso1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        iso2.formatOptions = [.withInternetDateTime]
        return [iso1, iso2]
    }()

    private static let localParsers: [DateFormatter] = {
        let local1: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
            return f
        }()
        let local2: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return f
        }()
        return [local1, local2]
    }()
}

struct MeetingsView: View {
    let appState: AppState
    let controller: MeetsController
    @State private var selectedFilter: MeetingBrowserFilter = .all
    @State private var selectedSort: MeetingBrowserSort = .newestFirst

    /// Complete browse index for the current scope, so shelves keep every
    /// follow-up member even when it sits outside the recently loaded window.
    private var scopedEntries: [MeetingBrowserEntry] {
        appState.meetingBrowserEntries
    }

    /// Recently loaded full records; the only source of notes, transcripts,
    /// and recording details in the browser.
    private var scopedMeetings: [MeetingRecord] {
        appState.meetingRows
    }

    private func browserPresentation(now: Date) -> MeetingBrowserShelfPresentation {
        MeetingBrowserLogic.shelves(
            entries: scopedEntries,
            records: scopedMeetings,
            filter: selectedFilter,
            sort: selectedSort,
            now: now
        )
    }

    private var currentFolderName: String {
        guard let folderID = appState.selectedFolderID else { return "All Meetings" }
        return appState.folders.first(where: { $0.id == folderID })?.name ?? "All Meetings"
    }

    private var currentDocumentMeeting: MeetingRecord? {
        guard case let .document(id) = appState.meetingsNavigationState else { return nil }
        if appState.selectedMeetingID == id, let selectedMeeting = appState.selectedMeeting {
            return selectedMeeting
        }
        return controller.meeting(id: id)
    }

    private var activeLiveMeeting: MeetingRecord? {
        controller.activeLiveMeetingRecord()
    }

    var body: some View {
        Group {
            if let meeting = currentDocumentMeeting {
                MeetingDetailView(
                    meeting: meeting,
                    controller: controller,
                    appState: appState,
                    onBack: { controller.showMeetingsHome(folderID: appState.selectedFolderID) },
                    backLabel: "Back to Meetings"
                )
                .id(meeting.id)
            } else {
                browserView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MeetsTheme.backgroundBase)
    }

    @ViewBuilder
    private var browserView: some View {
        // The window's detail column can be as narrow as ~280 points once the
        // sidebar is subtracted, so page padding and the folder line follow the
        // space actually available instead of assuming a wide canvas.
        GeometryReader { proxy in
            let contentWidth = proxy.size.width
            ScrollView {
                // One clock for the whole page: the shelves, the date sections
                // they group into, and the range menu all read the same "now",
                // so a row cannot land in a section built from a different
                // minute than the one that placed it.
                let now = Date()
                let presentation = browserPresentation(now: now)
                VStack(alignment: .leading, spacing: MeetsTheme.spacing24) {
                    PageTitle(currentFolderName)

                    if !appState.upcomingCalendarEvents.isEmpty {
                        comingUpSection
                    }

                    if appState.isMeetingStarting {
                        MeetingPreparationBanner(
                            status: appState.meetingStartStatus,
                            onCancel: { controller.cancelMeetingPreparation() }
                        )
                    }

                    if let activeLiveMeeting {
                        activeMeetingBanner(activeLiveMeeting)
                    }

                    folderNavigation()

                    // 24 under the folder line, then 16 between the toolbar and
                    // the first section heading, which carries 8 of its own top
                    // padding.
                    VStack(alignment: .leading, spacing: MeetsTheme.spacing16) {
                        browserHeader(presentation: presentation)

                        if presentation.shelves.isEmpty {
                            emptyState
                        } else {
                            ledger(presentation: presentation, now: now, width: contentWidth)
                        }
                    }
                }
                .frame(maxWidth: 960, alignment: .leading)
                .padding(.horizontal, Self.horizontalPadding(for: contentWidth))
                .padding(.top, MeetsTheme.pageTop)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    guard let data = item as? Data,
                          let urlString = String(data: data, encoding: .utf8),
                          let url = URL(string: urlString) else { return }
                    guard AudioFileImportController.isSupportedFileURL(url) else { return }
                    DispatchQueue.main.async {
                        controller.importAudioFileFromURL(url)
                    }
                }
                return true
            }
        }
    }

    /// Page gutters: 40 points when there is room, 16 once the detail column is
    /// narrow enough that 40 would eat the content.
    static func horizontalPadding(for width: CGFloat) -> CGFloat {
        width < 640 ? 16 : 40
    }

    /// Row width below which a ledger row drops its time gutter and moves the
    /// date next to the title.
    static let compactLedgerWidth: CGFloat = 300

    /// True when a ledger row must drop its time gutter and put the date after
    /// the title. The ledger is one full-width column, so the rendered row
    /// width is the page width less both gutters.
    static func usesCompactLedger(for width: CGFloat) -> Bool {
        width - horizontalPadding(for: width) * 2 < compactLedgerWidth
    }

    // MARK: - Coming Up

    private struct UpcomingEventGroup: Identifiable {
        let id: String
        let date: Date
        let dayLabel: String
        let dayNumber: String
        let dayOfWeek: String
        let isToday: Bool
        let events: [UnifiedCalendarEvent]
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d"; return f
    }()
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM"; return f
    }()
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()

    private static let maxUpcomingEvents = 5

    private var groupedUpcomingEvents: [UpcomingEventGroup] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let timedEvents = appState.upcomingCalendarEvents.filter { !$0.isAllDay && !appState.hiddenCalendarEventIDs.contains($0.id) }
        let grouped = Dictionary(grouping: timedEvents) { event in
            calendar.startOfDay(for: event.startDate)
        }
        let dayFormatter = Self.dayFormatter
        let monthFormatter = Self.monthFormatter
        let weekdayFormatter = Self.weekdayFormatter

        let sortedDates = grouped.keys.sorted()
        var result: [UpcomingEventGroup] = []
        var remaining = Self.maxUpcomingEvents

        for date in sortedDates {
            guard remaining > 0 else { break }
            let sortedEvents = grouped[date]!.sorted { $0.startDate < $1.startDate }
            let limitedEvents = Array(sortedEvents.prefix(remaining))
            remaining -= limitedEvents.count

            let isToday = calendar.isDate(date, inSameDayAs: today)
            let isTomorrow = calendar.date(byAdding: .day, value: 1, to: today).map { calendar.isDate(date, inSameDayAs: $0) } ?? false
            let dayLabel: String
            if isToday {
                dayLabel = "Today"
            } else if isTomorrow {
                dayLabel = "Tomorrow"
            } else {
                dayLabel = monthFormatter.string(from: date)
            }
            result.append(UpcomingEventGroup(
                id: date.description,
                date: date,
                dayLabel: dayLabel,
                dayNumber: dayFormatter.string(from: date),
                dayOfWeek: weekdayFormatter.string(from: date),
                isToday: isToday,
                events: limitedEvents
            ))
        }

        return result
    }

    @ViewBuilder
    private var comingUpSection: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Coming Up")
                    .font(.custom("Cormorant Garamond", size: 22).weight(.medium))
                    .foregroundStyle(MeetsTheme.textPrimary)

                if appState.calendarAuthorization != .fullAccess {
                    Button {
                        controller.openSystemCalendarAccountSettings()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 9))
                            Text("Open System Settings to grant Calendar access")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(MeetsTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 4)

            let groups = groupedUpcomingEvents
            let lastGroupId = groups.last?.id
            ForEach(groups) { group in
                HStack(alignment: .top, spacing: 20) {
                    // Date column
                    VStack(alignment: .center, spacing: 2) {
                        Text(group.dayNumber)
                            .font(.system(size: 24, weight: .light, design: .default))
                            .foregroundStyle(group.isToday ? MeetsTheme.accent : MeetsTheme.textPrimary)
                        Text(group.dayLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(group.isToday ? MeetsTheme.accent : MeetsTheme.textSecondary)
                        Text(group.dayOfWeek)
                            .font(.system(size: 10))
                            .foregroundStyle(MeetsTheme.textSecondary)
                    }
                    .frame(width: 60)

                    // Events column
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(group.events) { event in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(group.isToday ? MeetsTheme.accent : MeetsTheme.textSecondary.opacity(0.4))
                                    .frame(width: 3, height: 36)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(MeetsTheme.textPrimary)
                                        .lineLimit(1)

                                    Text(formatTimeRange(event))
                                        .font(.system(size: 11))
                                        .foregroundStyle(MeetsTheme.textSecondary)
                                }

                                Spacer()

                                if let meetingURL = event.meetingURL,
                                   !appState.isMeetingRecording,
                                   !appState.isMeetingStarting {
                                    joinActionControl(for: event, meetingURL: meetingURL)
                                }

                                Menu {
                                    Button("All Meetings") {
                                        controller.createMeetingFromCalendarEvent(event, folderID: nil)
                                    }
                                    Divider()
                                    ForEach(appState.folders) { folder in
                                        Button(folder.name) {
                                            controller.createMeetingFromCalendarEvent(event, folderID: folder.id)
                                        }
                                    }
                                } label: {
                                    Text("Add to folder")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(MeetsTheme.textSecondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(MeetsTheme.surfacePrimary)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 0.5)
                                        )
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()

                                hideEventButton(event)
                            }
                        }
                    }
                }

                if group.id != lastGroupId {
                    Divider()
                        .foregroundStyle(MeetsTheme.surfaceBorder)
                }
            }
        }
        .padding(20)
        .background(MeetsTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    private func formatTimeRange(_ event: UnifiedCalendarEvent) -> String {
        let f = Self.timeFormatter
        return "\(f.string(from: event.startDate)) – \(f.string(from: event.endDate))"
    }

    private static let joinActionGreen = Color(nsColor: NSColor(red: 0.20, green: 0.72, blue: 0.53, alpha: 1.0))
    private static let joinActionGreenDarker = Color(nsColor: NSColor(red: 0.15, green: 0.58, blue: 0.42, alpha: 1.0))

    /// Split control mirroring the meeting notification panel: the primary segment runs
    /// the default action from Settings, the chevron offers the other two.
    /// (Not `Menu(primaryAction:)` — with a plain custom label on macOS the chevron
    /// segment doesn't render, leaving the menu unreachable.)
    @ViewBuilder
    private func joinActionControl(for event: UnifiedCalendarEvent, meetingURL: URL) -> some View {
        let configured = appState.config.meetingJoinDefaultAction
        let armed = configured.resolved(hasJoinAndRecord: true, hasJoinOnly: true)
        let alternatives = configured.availableAlternatives(hasJoinAndRecord: true, hasJoinOnly: true)

        HStack(spacing: 1) {
            Button {
                performJoinAction(armed, for: event, meetingURL: meetingURL)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: armed.symbolName)
                        .font(.system(size: 9))
                    Text(armed.buttonLabel)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Self.joinActionGreen)
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(alternatives, id: \.self) { action in
                    Button {
                        performJoinAction(action, for: event, meetingURL: meetingURL)
                    } label: {
                        Label(action.buttonLabel, systemImage: action.symbolName)
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 5)
                    .frame(maxHeight: .infinity)
                    .background(Self.joinActionGreenDarker)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: true, vertical: false)
            .help(alternatives.map(\.buttonLabel).joined(separator: " · "))
        }
        .fixedSize()
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func performJoinAction(
        _ action: MeetingJoinDefaultAction,
        for event: UnifiedCalendarEvent,
        meetingURL: URL
    ) {
        // Both transcribe actions must carry calendar occurrence identity: it is
        // what keeps the calendar title (MeetingSession.calendarTitleCandidate)
        // and what createMeetingFromCalendarEvent dedupes against. Without it
        // the same event can end up as two meetings.
        switch action {
        case .joinAndRecord:
            controller.joinAndRecord(
                title: event.title,
                meetingURL: meetingURL,
                endDate: event.endDate,
                calendarOccurrence: event.resolvedCalendarOccurrence
            )
        case .joinOnly:
            controller.joinOnly(meetingURL: meetingURL, endDate: event.endDate)
        case .recordOnly:
            controller.recordOnly(
                title: event.title,
                meetingURL: meetingURL,
                endDate: event.endDate,
                calendarOccurrence: event.resolvedCalendarOccurrence
            )
        }
    }

    private func hideEventButton(_ event: UnifiedCalendarEvent) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                controller.hideCalendarEvent(event)
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(MeetsTheme.textSecondary.opacity(0.6))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help("Hide from Coming Up")
    }

    /// The scope's toolbar: meeting actions and display controls, in plain text.
    @ViewBuilder
    private func browserHeader(presentation: MeetingBrowserShelfPresentation) -> some View {
        MeetingBrowserHeader(
            filter: $selectedFilter,
            sort: $selectedSort,
            availableFilters: MeetingBrowserLogic.availableFilters(
                oldestStartDate: presentation.oldestStartDate
            ),
            isStartDisabled: appState.isMeetingRecording || appState.isMeetingStarting,
            onQuickNote: { controller.startQuickNoteMeeting() },
            onImportAudio: { controller.importAudioFile() }
        )
    }

    @ViewBuilder
    private func activeMeetingBanner(_ meeting: MeetingRecord) -> some View {
        HStack(spacing: MeetsTheme.spacing12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(activeMeetingStatusColor(for: meeting))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MeetsTheme.textPrimary)
                        .lineLimit(1)
                    Text(activeMeetingStatusText(for: meeting))
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.textSecondary)
                }
            }

            Spacer(minLength: MeetsTheme.spacing12)

            Button {
                controller.showMeetingDocument(id: meeting.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Open Notes")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(MeetsTheme.textPrimary)
                .padding(.horizontal, MeetsTheme.spacing12)
                .padding(.vertical, 8)
                .background(MeetsTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
            }
            .buttonStyle(.plain)

            if meeting.status == .recording {
                Button {
                    controller.toggleMeetingRecordingPause()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: appState.isMeetingRecordingPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(appState.isMeetingRecordingPaused ? "Resume" : "Pause")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(appState.isMeetingRecordingPaused ? MeetsTheme.accentContent : MeetsTheme.textPrimary)
                    .padding(.horizontal, MeetsTheme.spacing12)
                    .padding(.vertical, 8)
                    .background(appState.isMeetingRecordingPaused ? MeetsTheme.accent : MeetsTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                            .strokeBorder(appState.isMeetingRecordingPaused ? MeetsTheme.accent.opacity(0.35) : MeetsTheme.surfaceBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!appState.isMeetingRecording)

                Button {
                    controller.stopMeetingRecording()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Stop")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, MeetsTheme.spacing12)
                    .padding(.vertical, 8)
                    .background(MeetsTheme.recording)
                    .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                }
                .buttonStyle(.plain)
                .disabled(!appState.isMeetingRecording)
            }
        }
        .padding(MeetsTheme.spacing12)
        .background(MeetsTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerLarge))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerLarge)
                .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func activeMeetingStatusText(for meeting: MeetingRecord) -> String {
        guard meeting.status == .recording else { return "Finalizing notes" }
        return appState.isMeetingRecordingPaused ? "Recording paused" : "Recording now"
    }

    private func activeMeetingStatusColor(for meeting: MeetingRecord) -> Color {
        guard meeting.status == .recording else { return MeetsTheme.accent }
        return appState.isMeetingRecordingPaused ? MeetsTheme.transcribing : MeetsTheme.recording
    }

    /// One line, no card: what the scope holds, or why it holds nothing.
    private var emptyState: some View {
        Text(emptyStateMessage)
            .font(MeetsTheme.callout())
            .foregroundStyle(MeetsTheme.textSecondary)
    }

    private var emptyStateMessage: String {
        if selectedFilter != .all { return "No meetings in this range." }
        return appState.selectedFolderID == nil ? "No meetings yet." : "No meetings in this folder."
    }

    // MARK: - Folders

    /// Breadcrumb for the current scope plus one line of child folders, so
    /// nested folders stay reachable without leaving the meetings browser.
    @ViewBuilder
    private func folderNavigation() -> some View {
        let path = folderPath(to: appState.selectedFolderID)
        let childFolders = childFolders(of: appState.selectedFolderID)
        if !path.isEmpty || !childFolders.isEmpty {
            VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
                if !path.isEmpty {
                    folderBreadcrumb(path)
                }
                if !childFolders.isEmpty {
                    childFolderLine(childFolders)
                }
            }
        }
    }

    private func folderPath(to folderID: Int64?) -> [MeetingFolder] {
        guard let folderID else { return [] }
        let foldersByID = Dictionary(appState.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var path: [MeetingFolder] = []
        var seen: Set<Int64> = []
        var current: Int64? = folderID
        while let id = current, let folder = foldersByID[id], seen.insert(id).inserted {
            path.insert(folder, at: 0)
            current = folder.parentID
        }
        return path
    }

    private func childFolders(of parentID: Int64?) -> [MeetingFolder] {
        appState.folders.filter { $0.parentID == parentID }
    }

    /// The scope's ancestry, "All Meetings › Clients": plain caption text in
    /// the secondary tone, one separator per step.
    @ViewBuilder
    private func folderBreadcrumb(_ path: [MeetingFolder]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                breadcrumbItem("All Meetings", folderID: nil, isCurrent: false)
                ForEach(path) { folder in
                    Text("›")
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.textTertiary)
                    breadcrumbItem(
                        folder.name,
                        folderID: folder.id,
                        isCurrent: folder.id == appState.selectedFolderID
                    )
                }
            }
        }
        .accessibilityLabel("Folder path")
    }

    @ViewBuilder
    private func breadcrumbItem(_ name: String, folderID: Int64?, isCurrent: Bool) -> some View {
        if isCurrent {
            Text(name)
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textSecondary)
                .lineLimit(1)
        } else {
            Button {
                controller.showMeetingsHome(folderID: folderID)
            } label: {
                MeetingBrowserTextLabel(title: name, font: MeetsTheme.caption())
            }
            .buttonStyle(.plain)
            .help("Show \(name)")
        }
    }

    /// The folder level directly below the scope, as one wrapping line of plain
    /// text: "Clients 24". No icon, no fill, no border.
    @ViewBuilder
    private func childFolderLine(_ folders: [MeetingFolder]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MeetsTheme.spacing20) {
                childFolderButtons(folders)
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
                childFolderButtons(folders)
            }
        }
    }

    @ViewBuilder
    private func childFolderButtons(_ folders: [MeetingFolder]) -> some View {
        ForEach(folders) { folder in
            Button {
                controller.showMeetingsHome(folderID: folder.id)
            } label: {
                MeetingBrowserTextLabel(
                    title: folder.name,
                    count: appState.meetingCountsByFolder[folder.id] ?? 0
                )
            }
            .buttonStyle(.plain)
            .help("Show \(folder.name)")
        }
    }

    // MARK: - Ledger

    /// The ledger: one column of date sections, each a pinned heading over the
    /// meetings whose own start time falls inside it.
    @ViewBuilder
    private func ledger(
        presentation: MeetingBrowserShelfPresentation,
        now: Date,
        width: CGFloat
    ) -> some View {
        MeetingLedgerView(
            groups: MeetingBrowserLogic.ledgerGroups(
                from: MeetingBrowserLogic.flatRows(from: presentation.shelves, sort: selectedSort),
                now: now,
                calendar: .current
            ),
            now: now,
            folders: appState.folders,
            folderBreadcrumbs: folderBreadcrumbsByID,
            currentFolderID: appState.selectedFolderID,
            compact: Self.usesCompactLedger(for: width),
            annotatesRange: selectedFilter != .all,
            actions: shelfActions
        )
    }

    private var folderBreadcrumbsByID: [Int64: String] {
        MeetingFolderBreadcrumbs.paths(for: appState.folders)
    }

    private var shelfActions: MeetingShelfActions {
        MeetingShelfActions(
            open: { controller.showMeetingDocument(id: $0) },
            move: { meetingID, folderID in
                controller.moveMeeting(id: meetingID, toFolder: folderID)
            },
            createFolderAndMove: { name, meetingID in
                controller.createFolderAndMoveMeeting(name: name, meetingID: meetingID)
            },
            delete: { controller.deleteMeeting(id: $0) },
            startFollowUp: { controller.startFollowUpMeeting(fromMeetingID: $0) },
            canDelete: { controller.canDeleteMeeting(id: $0.id, status: $0.entry.status) },
            canStartFollowUp: { node in
                canStartFollowUps
                    && controller.canStartFollowUpMeeting(status: node.entry.status)
            }
        )
    }

    /// Starting a follow-up is refused while a recording is being prepared or
    /// is running, so the control is hidden for the same window.
    private var canStartFollowUps: Bool {
        !appState.isMeetingRecording && !appState.isMeetingStarting
    }
}
