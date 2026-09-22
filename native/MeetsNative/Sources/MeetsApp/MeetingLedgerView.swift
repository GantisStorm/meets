import SwiftUI
import Foundation
import MeetsCore

/// Actions the browser hands to the ledger. Bundled so the ledger and its rows
/// stay free of the controller.
struct MeetingShelfActions {
    let open: (Int64) -> Void
    /// Opens or folds one family's follow-ups. The browser owns the fold state,
    /// so a row only ever asks for the toggle.
    let toggleExpanded: (Int64) -> Void
    let move: (Int64, Int64?) -> Void
    let createFolderAndMove: (String, Int64) -> Void
    let delete: (Int64) -> Void
    let startFollowUp: (Int64) -> Void
    let canDelete: (MeetingBrowserNode) -> Bool
    let canStartFollowUp: (MeetingBrowserNode) -> Bool
}

/// One speed for a family's unfold, so the rows it reveals and the chevron that
/// revealed them move as one thing.
private let ledgerUnfoldDuration: Double = 0.18

/// Geometry shared by the ledger's rows.
enum MeetingLedgerMetrics {
    /// Padding inside a row's hover box.
    static let rowHorizontalPadding: CGFloat = 8
    static let rowVerticalPadding: CGFloat = 7
    /// Gap between the time column and the row's content, and between the
    /// row's own elements.
    static let gutterSpacing: CGFloat = 12
    /// Width of the time column on a wide ledger. A narrow ledger drops the
    /// column entirely and moves the date next to the title instead.
    ///
    /// Wide enough for the widest label a section can ask for — "Wed 11:20 AM"
    /// measures 80 points at this size — because a truncated time is worse than
    /// a wider column: the whole point of the gutter is that it can be read
    /// down one edge.
    static let gutterWidth: CGFloat = 84
    /// The space a row always keeps between its title and the duration that
    /// trails it.
    static let minimumTitleGap: CGFloat = 8
    /// The slot a root's fold control sits in, left of the time gutter. Every
    /// row reserves its width — a row with nothing to fold leaves it empty — so
    /// the gutter and every title stay aligned down the column. The slot takes
    /// its height from the row's own text, not from the control drawn into it.
    static let disclosureWidth: CGFloat = 20
    /// The fold control's hit area, drawn inside that slot. Taller than the line
    /// it marks, because a 20-point target is easier to hit than a 10-point
    /// chevron, and drawn over the row rather than laid out in it, so a row with
    /// follow-ups is exactly as tall as one without.
    static let disclosureHitSize: CGFloat = 20
    /// How far an open family's follow-ups sit in from their root, measured
    /// past the time gutter: one step for all of them, whatever their depth, so
    /// a long thread stays a list rather than a staircase.
    static let followUpIndent: CGFloat = 20
}

/// One ledger section: a pinned date heading over the families that belong to
/// it.
///
/// The heading is the spine of the page — "Today", "Yesterday", "Last week",
/// "September" — and says it in sentence case at caption size. It fills with
/// the base canvas so rows scroll *under* it rather than through it once it
/// pins. Nothing else is on the line: no rule, no count.
struct MeetingLedgerSectionHeader: View {
    let title: String
    /// The first section sits just under the toolbar; later ones are separated
    /// by their own heading alone.
    let isFirst: Bool

    var body: some View {
        Text(title)
            .font(MeetsTheme.captionMedium())
            .foregroundStyle(MeetsTheme.textSecondary)
            .lineLimit(1)
            .padding(.top, isFirst ? 8 : 24)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MeetsTheme.backgroundBase)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(title)
    }
}

/// The browser's meetings as a ledger: one column of date sections, each
/// holding the follow-up families that started inside it.
///
/// One column and no cards — the archive is read top to bottom. A family is its
/// root row plus, once that root's fold is open, every follow-up in thread
/// order directly beneath it, indented one step past the time gutter. Folded,
/// the family is the root alone, and its count says what is behind the fold.
struct MeetingLedgerView: View {
    let groups: [MeetingLedgerGroup]
    /// The page's single clock, so a row's gutter label and the section it sits
    /// in can never be computed from two different "now"s. A follow-up from
    /// last month under a "Today" root reads "17 · 9:00 AM" rather than a time
    /// that would read as this morning's.
    let now: Date
    /// Whether a family's follow-ups are on screen. Resolution stays with
    /// `MeetingsView`, which owns the user's fold overrides.
    let expandedResolver: (MeetingBrowserShelf) -> Bool
    let folders: [MeetingFolder]
    let folderBreadcrumbs: [Int64: String]
    let currentFolderID: Int64?
    /// True on a narrow ledger: the time column collapses and the date moves
    /// next to the title.
    let compact: Bool
    /// True when a date range is active, so a folded family can report the
    /// matches it is holding back.
    let annotatesRange: Bool
    /// What every row says about its meeting, keyed by meeting id and built
    /// once by the page from the same shelves the groups below are cut from.
    /// Explicit, with no default: a page that forgets to build it must fail to
    /// compile rather than render rows that quietly say nothing.
    let facts: [Int64: MeetingFacts]
    let actions: MeetingShelfActions

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.shelves) { shelf in
                        MeetingLedgerFamily(
                            shelf: shelf,
                            kind: group.kind,
                            isExpanded: expandedResolver(shelf),
                            now: now,
                            folders: folders,
                            folderBreadcrumbs: folderBreadcrumbs,
                            currentFolderID: currentFolderID,
                            compact: compact,
                            annotatesRange: annotatesRange,
                            facts: facts,
                            actions: actions
                        )
                    }
                } header: {
                    MeetingLedgerSectionHeader(
                        title: group.kind.title(now: now, calendar: .current, locale: .current),
                        isFirst: group.id == groups.first?.id
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One follow-up family: the root meeting, then — while its fold is open —
/// every follow-up in thread order, indented one step beneath it.
struct MeetingLedgerFamily: View {
    let shelf: MeetingBrowserShelf
    /// The section the family is filed under — its root's, since `ledgerGroups`
    /// orders families by the meeting each one started from. The gutter label a
    /// root reads is the one this heading does not already carry.
    let kind: MeetingLedgerSectionKind
    let isExpanded: Bool
    let now: Date
    let folders: [MeetingFolder]
    let folderBreadcrumbs: [Int64: String]
    let currentFolderID: Int64?
    let compact: Bool
    let annotatesRange: Bool
    let facts: [Int64: MeetingFacts]
    let actions: MeetingShelfActions

    /// Every descendant is counted, not a visible prefix: folded, the count
    /// hides all of them, so all of them are what the range is looking for
    /// behind it.
    private var hiddenMatchCount: Int {
        shelf.descendants.filter(\.matchesFilter).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MeetingLedgerRow(
                node: shelf.root,
                kind: .root,
                gutterLabel: MeetingBrowserLogic.ledgerGutterLabel(for: shelf.root.startDate, in: kind),
                followUpCount: shelf.descendants.isEmpty
                    ? nil
                    : MeetingBrowserLogic.followUpCountLabel(
                        descendantCount: shelf.descendants.count,
                        hiddenMatchCount: hiddenMatchCount,
                        annotatesMatches: annotatesRange,
                        isExpanded: isExpanded
                    ),
                isExpanded: isExpanded,
                onToggle: {
                    withAnimation(.easeOut(duration: ledgerUnfoldDuration)) {
                        actions.toggleExpanded(shelf.id)
                    }
                },
                folders: folders,
                folderBreadcrumbs: folderBreadcrumbs,
                currentFolderID: currentFolderID,
                compact: compact,
                annotatesRange: annotatesRange,
                facts: facts,
                actions: actions
            )

            if isExpanded, !shelf.descendants.isEmpty {
                followUpList
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Every descendant, in thread order, as one flat list.
    private var followUpList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shelf.descendants) { node in
                MeetingLedgerRow(
                    node: node,
                    kind: .child,
                    // A follow-up's time only means something beside its root, so
                    // it is read against that root rather than the section: the
                    // time alone on the root's own day, its date otherwise.
                    gutterLabel: MeetingBrowserLogic.ledgerChildGutterLabel(
                        childDate: node.startDate,
                        rootDate: shelf.root.startDate,
                        now: now
                    ),
                    followUpCount: nil,
                    isExpanded: false,
                    onToggle: {},
                    folders: folders,
                    folderBreadcrumbs: folderBreadcrumbs,
                    currentFolderID: currentFolderID,
                    compact: compact,
                    annotatesRange: annotatesRange,
                    facts: facts,
                    actions: actions
                )
            }
        }
    }
}

/// Which place in a family a row occupies. Roots carry the fold and the count
/// of what is under them; follow-ups are the same row, indented one step.
enum MeetingLedgerRowKind: Hashable {
    case root
    case child
}

/// One meeting as a row: the fold slot, time in the gutter, title and state in
/// the body, the actions control on the trailing edge.
///
/// Nothing is drawn around it — no border, no fill at rest — so the row's own
/// text is the only thing separating it from its neighbours. Hover is the row's
/// single transient state.
struct MeetingLedgerRow: View {
    let node: MeetingBrowserNode
    let kind: MeetingLedgerRowKind
    /// The row's time-gutter text, which the family derives: a root reads the
    /// section its heading names, and a follow-up reads its own date against
    /// the root above it.
    let gutterLabel: String
    /// How many follow-ups hang under this meeting, already counted into a
    /// label. Roots with a family carry one; every other row passes `nil`.
    let followUpCount: String?
    /// Whether those follow-ups are on screen under this row.
    let isExpanded: Bool
    let onToggle: () -> Void
    let folders: [MeetingFolder]
    let folderBreadcrumbs: [Int64: String]
    let currentFolderID: Int64?
    let compact: Bool
    /// True when a date range is active: a row the range excluded is dimmed and
    /// says why it is still on screen.
    let annotatesRange: Bool
    /// What this row's meeting has to say, looked up by id. A meeting the page
    /// built no facts for renders bare rather than borrowing another's.
    let facts: [Int64: MeetingFacts]
    let actions: MeetingShelfActions
    @State private var isHovering = false
    @State private var isHoveringDisclosure = false

    /// The meeting this one follows on from, when the shelves could name it: the
    /// browse entry carries it, and the node carries the copy the shelves
    /// resolved for a parent that sits outside the row's own family.
    private var predecessorTitle: String? {
        node.entry.predecessorTitle ?? node.parentLinkTitle
    }

    /// The row's tooltip, when it has something to say that the text does not:
    /// which meeting a follow-up hangs from, and why a row the active range
    /// excluded is still on screen.
    private var helpText: String? {
        let followUpNote = node.entry.followUpToID != nil
            ? predecessorTitle.map { "Follow-up to \($0)" }
            : nil
        guard annotatesRange, !node.matchesFilter else { return followUpNote }
        let rangeNote = "Outside the selected range; shown for thread context"
        guard let followUpNote else { return rangeNote }
        return "\(followUpNote). \(rangeNote)"
    }

    /// The status word's colour: the recording red while a meeting is live, the
    /// transcribing amber while its notes are still being written, and the
    /// status's own display colour for everything else.
    private var statusColor: Color {
        switch node.entry.status {
        case .recording: return MeetsTheme.recording
        case .processing: return MeetsTheme.transcribing
        case .completed, .noteOnly, .failed: return node.entry.status.displayColor
        }
    }

    var body: some View {
        row
    }

    private var row: some View {
        HStack(spacing: 0) {
            disclosure
            HStack(alignment: .firstTextBaseline, spacing: MeetingLedgerMetrics.gutterSpacing) {
                openButton
                actionMenu
            }
        }
        .padding(.horizontal, MeetingLedgerMetrics.rowHorizontalPadding)
        .padding(.vertical, MeetingLedgerMetrics.rowVerticalPadding)
        .background(isHovering ? MeetsTheme.backgroundHover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .opacity(node.matchesFilter ? 1 : 0.55)
    }

    /// The fold control, left of the time gutter and outside the row's open
    /// button, so unfolding a family never opens the meeting. A row with no
    /// follow-ups leaves the slot empty rather than absent, which is what keeps
    /// every gutter and title on the same vertical line.
    private var disclosure: some View {
        Color.clear
            .frame(width: MeetingLedgerMetrics.disclosureWidth)
            .overlay {
                if followUpCount != nil {
                    Button(action: onToggle) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isHoveringDisclosure ? MeetsTheme.textPrimary : MeetsTheme.textTertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeOut(duration: ledgerUnfoldDuration), value: isExpanded)
                            .frame(
                                width: MeetingLedgerMetrics.disclosureHitSize,
                                height: MeetingLedgerMetrics.disclosureHitSize
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringDisclosure = $0 }
                    .help(isExpanded ? "Hide follow-ups" : "Show follow-ups")
                    .accessibilityLabel("Follow-ups")
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                }
            }
    }

    /// The row is one plain button, so the whole line opens the meeting and
    /// stays reachable from the keyboard. The actions menu is its sibling,
    /// never its child, so both keep their own clicks.
    @ViewBuilder
    private var openButton: some View {
        let button = Button {
            actions.open(node.id)
        } label: {
            openButtonLabel
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the meeting")

        // The tooltip sits on the button rather than on the whole row, so it
        // never covers the fold control's own.
        if let helpText {
            button.help(helpText)
        } else {
            button
        }
    }

    /// The row's whole content: the label line, and — when the page has
    /// something to say about this meeting — the facts line beneath it.
    ///
    /// A narrow row tries the date beside the title first, sheds the date when
    /// the title would otherwise be squeezed to nothing, and sheds the trailing
    /// duration after that. The title is what never goes: a row with no room
    /// left for its title says nothing at all, and the section heading above
    /// still carries the date the label was naming.
    private var openButtonLabel: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
            Group {
                if compact {
                    ViewThatFits(in: .horizontal) {
                        labelLine(showsDate: true, showsDuration: true)
                        labelLine(showsDate: false, showsDuration: true)
                        labelLine(showsDate: false, showsDuration: false)
                    }
                } else {
                    labelLine(showsDate: false, showsDuration: true)
                }
            }
            factsLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The facts line, directly under the label line and starting where the
    /// title starts: it is a second line of the same row, not a column of its
    /// own, so it never moves the time gutter the ledger is scanned down.
    ///
    /// It carries only what spells itself out — an attached event's title, a
    /// people count. Notes and a summary are icons beside the title, so a
    /// meeting that has only those keeps a one-line row.
    @ViewBuilder
    private var factsLine: some View {
        if let facts = facts[node.entry.id], !facts.spelledWords.isEmpty {
            MeetingFactsRow(facts: facts, drawsSymbols: false)
                .padding(.leading, titleLeadingInset)
        }
    }

    /// Written notes and a summary, drawn where the eye already is: beside the
    /// title, in the size the rest of the row's quiet text uses. The words they
    /// stand for stay in the row's accessibility label.
    @ViewBuilder
    private var factSymbols: some View {
        if let facts = facts[node.entry.id], !facts.symbols.isEmpty {
            MeetingFactSymbols(facts: facts)
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textTertiary)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
        }
    }

    /// How far the row's title sits from its leading edge, which is also where
    /// the facts line starts: past the time gutter on a wide row, past nothing
    /// on a narrow one where the column is gone, and one further step in for a
    /// follow-up on either.
    private var titleLeadingInset: CGFloat {
        let gutter = compact
            ? 0
            : MeetingLedgerMetrics.gutterWidth + MeetingLedgerMetrics.gutterSpacing
        return gutter + (kind == .child ? MeetingLedgerMetrics.followUpIndent : 0)
    }

    private func labelLine(showsDate: Bool, showsDuration: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MeetingLedgerMetrics.gutterSpacing) {
            gutter

            // A follow-up indents past the gutter, never the gutter itself:
            // the time column is what the whole ledger is read down, so it has
            // to hold one position for roots and children alike.
            HStack(alignment: .firstTextBaseline, spacing: MeetingLedgerMetrics.gutterSpacing) {
                followUpArrow
                title
                factSymbols
                countLabel
                statusWord
                if showsDate {
                    compactDate
                }
                Spacer(minLength: MeetingLedgerMetrics.minimumTitleGap)
                if showsDuration {
                    duration
                }
            }
            .padding(.leading, kind == .child ? MeetingLedgerMetrics.followUpIndent : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The fixed time column. It is the only thing in the row that holds a
    /// position across sections, so the list can be scanned down one edge.
    @ViewBuilder
    private var gutter: some View {
        if !compact {
            Text(gutterLabel)
                .font(MeetsTheme.caption())
                .monospacedDigit()
                .foregroundStyle(MeetsTheme.textTertiary)
                .lineLimit(1)
                .frame(width: MeetingLedgerMetrics.gutterWidth, alignment: .trailing)
        }
    }

    /// A follow-up is marked, not weighed: the row names the meeting it hangs
    /// from in its tooltip, and the arrow says there is one.
    @ViewBuilder
    private var followUpArrow: some View {
        if node.entry.followUpToID != nil {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10))
                .foregroundStyle(MeetsTheme.textTertiary)
        }
    }

    /// A narrow ledger has room for two lines, so a long title wraps instead of
    /// ellipsising down to its first few words; a wide one keeps one line, where
    /// a second would only add height to every row.
    private var title: some View {
        Text(node.entry.title)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(MeetsTheme.textPrimary)
            .lineLimit(compact ? 2 : 1)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
    }

    /// What the fold is holding: the follow-up count, and — while a range is
    /// active and the fold is closed over some of its matches — how many the
    /// range is looking for. A count, not a badge: same size as the duration,
    /// in the quietest tone, and it wraps rather than truncating when a narrow
    /// column leaves it no room.
    @ViewBuilder
    private var countLabel: some View {
        if let followUpCount {
            Text(followUpCount)
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Status as a word in the status colour, not a badge: the row keeps one
    /// text line, and the label comes from `MeetingStatusDisplay` so the browser
    /// and the rest of the app name a state the same way.
    @ViewBuilder
    private var statusWord: some View {
        if node.entry.status != .completed {
            Text(node.entry.status.displayLabel)
                .font(MeetsTheme.caption())
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// Where the date goes on a narrow ledger, once the gutter is gone.
    @ViewBuilder
    private var compactDate: some View {
        if compact {
            Text(gutterLabel)
                .font(MeetsTheme.caption())
                .monospacedDigit()
                .foregroundStyle(MeetsTheme.textTertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var duration: some View {
        Text(MeetingListItemFormat.duration(node.entry.durationSeconds))
            .font(MeetsTheme.caption())
            .monospacedDigit()
            .foregroundStyle(MeetsTheme.textTertiary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var actionMenu: some View {
        MeetingRowActionMenu(
            meetingTitle: node.entry.title,
            folders: folders,
            breadcrumbs: folderBreadcrumbs,
            currentFolderID: node.entry.folderID,
            isHovering: isHovering,
            canStartFollowUp: actions.canStartFollowUp(node),
            canDelete: actions.canDelete(node),
            onStartFollowUp: { actions.startFollowUp(node.id) },
            onMove: { actions.move(node.id, $0) },
            onCreateFolderAndMove: { actions.createFolderAndMove($0, node.id) },
            onDelete: { actions.delete(node.id) }
        )
    }

    private var accessibilityLabel: String {
        var parts = [
            node.entry.title
        ]
        if let followUpCount {
            parts.append(followUpCount)
        }
        parts.append(gutterLabel)
        parts.append(MeetingListItemFormat.duration(node.entry.durationSeconds))
        if node.entry.status != .completed {
            parts.append("status \(node.entry.status.displayLabel)")
        }
        // The label replaces the text the row draws, so the facts line has to
        // be named here too or a screen reader never hears it.
        if let facts = facts[node.entry.id], !facts.text.isEmpty {
            parts.append(facts.text)
        }
        if node.entry.followUpToID != nil, let predecessorTitle {
            parts.append("follow-up to \(predecessorTitle)")
        }
        if annotatesRange, !node.matchesFilter {
            parts.append("outside the active date range")
        }
        return parts.joined(separator: ", ")
    }
}
