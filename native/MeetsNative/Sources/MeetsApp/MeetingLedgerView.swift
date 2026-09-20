import SwiftUI
import Foundation
import MeetsCore

/// Actions the browser hands to the ledger. Bundled so the ledger and its rows
/// stay free of the controller.
struct MeetingShelfActions {
    let open: (Int64) -> Void
    let move: (Int64, Int64?) -> Void
    let createFolderAndMove: (String, Int64) -> Void
    let delete: (Int64) -> Void
    let startFollowUp: (Int64) -> Void
    let canDelete: (MeetingBrowserNode) -> Bool
    let canStartFollowUp: (MeetingBrowserNode) -> Bool
}

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
}

/// One ledger section: a pinned date heading over the meetings that belong to
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

/// The browser's meetings as a list by day: pinned date sections over one flat,
/// time-sorted column of rows.
///
/// One column and no cards — the archive is read top to bottom, and the only
/// things that carry structure are the section headings and the fixed time
/// gutter. A follow-up keeps its own place in the date order and is marked with
/// an arrow rather than indented under the meeting it follows on from, so
/// nothing is ever nested and no row ever grows past one line.
struct MeetingLedgerView: View {
    let groups: [MeetingLedgerGroup]
    /// The page's single clock, so the section headings and the rows they hold
    /// can never be computed from two different "now"s.
    let now: Date
    let folders: [MeetingFolder]
    let folderBreadcrumbs: [Int64: String]
    let currentFolderID: Int64?
    /// True on a narrow ledger: the time column collapses and the date moves
    /// next to the title.
    let compact: Bool
    /// True when a date range is active, so a row the range excluded says so.
    let annotatesRange: Bool
    let actions: MeetingShelfActions

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.rows) { node in
                        MeetingLedgerRow(
                            node: node,
                            sectionKind: group.kind,
                            folders: folders,
                            folderBreadcrumbs: folderBreadcrumbs,
                            currentFolderID: currentFolderID,
                            compact: compact,
                            annotatesRange: annotatesRange,
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

/// One meeting as a row: time in the gutter, title and state in the body, the
/// duration and the actions control on the trailing edge.
///
/// Nothing is drawn around it — no border, no fill at rest — so the row's own
/// text is the only thing separating it from its neighbours. Hover is the row's
/// single transient state.
struct MeetingLedgerRow: View {
    let node: MeetingBrowserNode
    /// The date section this row is filed under. `ledgerGroups` derives it from
    /// the row's own start time, so the gutter never has to guess which section
    /// it is rendering inside.
    let sectionKind: MeetingLedgerSectionKind
    let folders: [MeetingFolder]
    let folderBreadcrumbs: [Int64: String]
    let currentFolderID: Int64?
    let compact: Bool
    /// True when a date range is active: a row the range excluded is dimmed and
    /// says why it is still on screen.
    let annotatesRange: Bool
    let actions: MeetingShelfActions
    @State private var isHovering = false

    private var gutterLabel: String {
        MeetingBrowserLogic.ledgerGutterLabel(for: node.startDate, in: sectionKind)
    }

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
        if let helpText {
            row.help(helpText)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: MeetingLedgerMetrics.gutterSpacing) {
            openButton
            actionMenu
        }
        .padding(.horizontal, MeetingLedgerMetrics.rowHorizontalPadding)
        .padding(.vertical, MeetingLedgerMetrics.rowVerticalPadding)
        .background(isHovering ? MeetsTheme.backgroundHover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .opacity(node.matchesFilter ? 1 : 0.55)
    }

    /// The row is one plain button, so the whole line opens the meeting and
    /// stays reachable from the keyboard. The actions menu is its sibling,
    /// never its child, so both keep their own clicks.
    private var openButton: some View {
        Button {
            actions.open(node.id)
        } label: {
            openButtonLabel
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the meeting")
    }

    /// The row's whole content, on one line.
    ///
    /// A narrow row tries the date beside the title first, sheds the date when
    /// the title would otherwise be squeezed to nothing, and sheds the trailing
    /// duration after that. The title is what never goes: a row with no room
    /// left for its title says nothing at all, and the section heading above
    /// still carries the date the label was naming.
    private var openButtonLabel: some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func labelLine(showsDate: Bool, showsDuration: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MeetingLedgerMetrics.gutterSpacing) {
            gutter
            followUpArrow
            title
            statusWord
            if showsDate {
                compactDate
            }
            Spacer(minLength: MeetingLedgerMetrics.minimumTitleGap)
            if showsDuration {
                duration
            }
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

    /// A follow-up is marked, not indented: the row keeps its own place in the
    /// date order, and the arrow says the meeting belongs to a thread.
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
            node.entry.title,
            gutterLabel,
            MeetingListItemFormat.duration(node.entry.durationSeconds)
        ]
        if node.entry.status != .completed {
            parts.append("status \(node.entry.status.displayLabel)")
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
