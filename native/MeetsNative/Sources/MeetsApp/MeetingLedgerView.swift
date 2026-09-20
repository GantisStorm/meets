import SwiftUI
import Foundation
import MeetsCore

/// Actions the browser hands to the ledger. Bundled so the ledger and its rows
/// stay free of the controller.
struct MeetingShelfActions {
    let open: (Int64) -> Void
    let toggleExpanded: (Int64) -> Void
    let move: (Int64, Int64?) -> Void
    let createFolderAndMove: (String, Int64) -> Void
    let delete: (Int64) -> Void
    let startFollowUp: (Int64) -> Void
    let canDelete: (MeetingBrowserNode) -> Bool
    let canStartFollowUp: (MeetingBrowserNode) -> Bool
}

/// One speed for a family's unfold, so the sublist and the pill's chevron move
/// as one thing.
private let ledgerUnfoldDuration: Double = 0.18

/// Geometry shared by the ledger's rows and the sublist they open into.
/// One definition, because the gutter puts the time in a fixed column and the
/// sublist indents against that same column rather than against each row's own
/// contents.
enum MeetingLedgerMetrics {
    /// Padding inside a row's hover box.
    static let rowHorizontalPadding: CGFloat = 8
    static let rowVerticalPadding: CGFloat = 8
    /// Gap between the time column and the row's content.
    static let gutterSpacing: CGFloat = 12
    /// Width of the time column. Collapsed to nothing on a narrow ledger, which
    /// moves the time into the row's metadata line instead.
    ///
    /// Wide enough for the widest label a section can ask for — "Wed 9:30 AM"
    /// and "17 · 9:00 AM" — because a truncated time is worse than a wider
    /// column: the whole point of the gutter is that it can be read down one
    /// edge.
    static func gutterWidth(compact: Bool) -> CGFloat { compact ? 0 : 92 }
    /// How far a follow-up's body sits to the right of its root's, whatever its
    /// depth: the sublist is flat, so one step is all the hierarchy needs — a
    /// follow-up deeper than the first says in words which meeting it follows.
    static let childIndent: CGFloat = 24
}

/// One ledger section: a pinned date heading over the families that belong to
/// it.
///
/// The heading is the spine of the page — "Today", "Yesterday", "Last week",
/// "September" — and says it in sentence case at caption size, with a hairline
/// rule carrying the eye to the trailing count. It fills with the base canvas
/// so rows scroll *under* it rather than through it once it pins.
struct MeetingLedgerSectionHeader: View {
    let title: String
    let meetingCount: Int
    /// The first section sits just under the toolbar; later ones are separated
    /// by their own heading alone.
    let isFirst: Bool

    private var countLabel: String {
        "\(meetingCount) meeting\(meetingCount == 1 ? "" : "s")"
    }

    var body: some View {
        HStack(alignment: .center, spacing: MeetsTheme.spacing8) {
            Text(title)
                .font(MeetsTheme.captionMedium())
                .foregroundStyle(MeetsTheme.textSecondary)
                .lineLimit(1)
                .fixedSize()

            Rectangle()
                .fill(MeetsTheme.surfaceBorder)
                .frame(height: 1)

            Text(countLabel)
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.top, isFirst ? 8 : 20)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MeetsTheme.backgroundBase)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(title), \(countLabel)")
    }
}

/// The browser's meetings as a ledger: date sections, each holding the
/// follow-up families that started inside it, with each family's follow-ups
/// unfolding under its root when the root's pill is opened.
///
/// One column and no cards — the archive is read top to bottom, and the only
/// things that carry structure are the section headings, the fixed time gutter,
/// and the one step of indentation the sublist takes. Root rows and follow-up
/// rows use the same row shape, so a deep thread reads as the same kind of
/// object as the meeting it came from.
struct MeetingLedgerView: View {
    let groups: [MeetingLedgerGroup]
    /// The page's single clock, so a row's gutter label and the section it sits
    /// in can never be computed from two different "now"s. A follow-up from
    /// last month under a "Today" root still reads "17 · 9:00 AM".
    let now: Date
    /// Whether a family's thread is open. Resolution stays with `MeetingsView`,
    /// which owns the user's fold overrides.
    let expandedResolver: (MeetingBrowserShelf) -> Bool
    /// Every meeting with follow-ups in scope, so a root whose thread lives in
    /// another folder can say so instead of showing an empty rail.
    let meetingIDsWithFollowUps: Set<Int64>
    let folders: [MeetingFolder]
    let folderBreadcrumbs: [Int64: String]
    let currentFolderID: Int64?
    /// True on a narrow ledger: the time column collapses and the date moves
    /// into the row's metadata line.
    let compact: Bool
    /// True when a date range is active, so a fold reports the matches it is
    /// holding back.
    let annotatesHiddenMatches: Bool
    let actions: MeetingShelfActions

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.shelves) { shelf in
                        MeetingLedgerFamily(
                            shelf: shelf,
                            isExpanded: expandedResolver(shelf),
                            now: now,
                            hasOutsideScopeFollowUps: shelf.descendants.isEmpty
                                && meetingIDsWithFollowUps.contains(shelf.root.id),
                            folders: folders,
                            folderBreadcrumbs: folderBreadcrumbs,
                            currentFolderID: currentFolderID,
                            compact: compact,
                            annotatesHiddenMatches: annotatesHiddenMatches,
                            actions: actions
                        )
                    }
                } header: {
                    MeetingLedgerSectionHeader(
                        title: group.kind.title(now: now, calendar: .current, locale: .current),
                        meetingCount: group.meetingCount,
                        isFirst: group.id == groups.first?.id
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One follow-up family as a ledger entry: the root meeting, then — while its
/// pill is open — every follow-up in thread order, indented one step beneath it.
struct MeetingLedgerFamily: View {
    let shelf: MeetingBrowserShelf
    let isExpanded: Bool
    let now: Date
    /// True when this root has follow-ups that the current scope does not hold.
    let hasOutsideScopeFollowUps: Bool
    let folders: [MeetingFolder]
    let folderBreadcrumbs: [Int64: String]
    let currentFolderID: Int64?
    let compact: Bool
    let annotatesHiddenMatches: Bool
    let actions: MeetingShelfActions

    /// Every descendant is counted, not just a visible prefix: folded, the pill
    /// hides all of them, so all of them are what the range is looking for.
    private var hiddenMatchCount: Int {
        shelf.descendants.filter(\.matchesFilter).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MeetingLedgerRow(
                node: shelf.root,
                kind: .root,
                rootDate: shelf.root.startDate,
                now: now,
                hasOutsideScopeFollowUps: hasOutsideScopeFollowUps,
                followUpLabel: shelf.descendants.isEmpty
                    ? nil
                    : MeetingBrowserLogic.followUpPillLabel(
                        descendantCount: shelf.descendants.count,
                        hiddenMatchCount: hiddenMatchCount,
                        annotatesMatches: annotatesHiddenMatches,
                        isExpanded: isExpanded
                    ),
                followUpsExpanded: isExpanded,
                onToggleFollowUps: {
                    withAnimation(.easeOut(duration: ledgerUnfoldDuration)) {
                        actions.toggleExpanded(shelf.id)
                    }
                },
                folders: folders,
                folderBreadcrumbs: folderBreadcrumbs,
                currentFolderID: currentFolderID,
                compact: compact,
                actions: actions
            )

            if isExpanded, !shelf.descendants.isEmpty {
                followUpList
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    /// Every descendant, in thread order, as one flat list: rows carry their own
    /// vertical padding, so nothing else has to separate them.
    private var followUpList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shelf.descendants) { node in
                MeetingLedgerRow(
                    node: node,
                    kind: .child,
                    rootDate: shelf.root.startDate,
                    now: now,
                    hasOutsideScopeFollowUps: false,
                    followUpLabel: nil,
                    followUpsExpanded: false,
                    onToggleFollowUps: {},
                    folders: folders,
                    folderBreadcrumbs: folderBreadcrumbs,
                    currentFolderID: currentFolderID,
                    compact: compact,
                    actions: actions
                )
            }
        }
    }
}

/// Which place in a family a row occupies. Roots carry the family's weight;
/// children are the same row, quieter, one step to the right.
enum MeetingLedgerRowKind: Hashable {
    case root
    case child
}

/// One meeting as a ledger row: time in the gutter, title and state in the
/// body, actions on the trailing edge.
///
/// Nothing is drawn around it — no border, no fill at rest — so the row's own
/// weight is the only thing separating it from its neighbours. Hover is the
/// row's single transient state, and it is the same hover a folder tile uses.
struct MeetingLedgerRow: View {
    let node: MeetingBrowserNode
    let kind: MeetingLedgerRowKind
    /// The family's root date. Children read their gutter against it — a time
    /// alone only means something on the root's own day — and roots ignore it.
    let rootDate: Date
    let now: Date
    let hasOutsideScopeFollowUps: Bool
    /// The follow-ups hanging under this meeting, already counted into a pill's
    /// label. Roots with a family carry one; every other row passes `nil`.
    let followUpLabel: String?
    /// Whether that family's follow-ups are on screen under this row.
    let followUpsExpanded: Bool
    let onToggleFollowUps: () -> Void
    let folders: [MeetingFolder]
    let folderBreadcrumbs: [Int64: String]
    let currentFolderID: Int64?
    let compact: Bool
    let actions: MeetingShelfActions
    @State private var isHovering = false

    private var display: MeetingListItemDisplay {
        MeetingListItemDisplay(entry: node.entry, record: node.record)
    }

    /// The row's own time. A root is formatted for the section it falls in; a
    /// follow-up is formatted against its root, so a yesterday follow-up under
    /// a "Today" root shows a date instead of a time that would read as today's.
    private var gutterLabel: String {
        switch kind {
        case .root:
            return MeetingBrowserLogic.ledgerGutterLabel(
                for: node.startDate,
                in: MeetingBrowserLogic.ledgerSectionKind(
                    for: node.startDate,
                    now: now,
                    calendar: .current
                ),
                calendar: .current
            )
        case .child:
            return MeetingBrowserLogic.ledgerChildGutterLabel(
                childDate: node.startDate,
                rootDate: rootDate,
                now: now,
                calendar: .current
            )
        }
    }

    private var contentInset: CGFloat {
        switch kind {
        case .root: return 0
        case .child: return MeetingLedgerMetrics.childIndent
        }
    }

    private var titleFont: Font {
        switch kind {
        case .root: return .system(size: 14, weight: .semibold)
        case .child: return .system(size: 13, weight: .medium)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MeetingLedgerMetrics.gutterSpacing) {
            gutter

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: MeetingLedgerMetrics.gutterSpacing) {
                    openContent
                    actionMenu
                }

                parentCaption
                externalParentLink
            }
            .padding(.leading, contentInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, MeetingLedgerMetrics.rowHorizontalPadding)
        .padding(.vertical, MeetingLedgerMetrics.rowVerticalPadding)
        .background(isHovering ? MeetsTheme.backgroundHover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    /// The fixed time column. It is the only thing in the row that holds a
    /// position across sections, so the ledger can be scanned down one edge.
    /// On a narrow ledger it collapses and the date moves into the meta line.
    @ViewBuilder
    private var gutter: some View {
        Group {
            if !compact {
                Text(gutterLabel)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(MeetsTheme.textSecondary)
                    .lineLimit(1)
                    .help(MeetingBrowserLogic.formatStartTime(node.entry.startTime))
            }
        }
        .frame(width: MeetingLedgerMetrics.gutterWidth(compact: compact), alignment: .trailing)
    }

    /// Title, state and preview. The block opens the meeting on a tap gesture
    /// rather than a wrapping Button: the follow-up pill and the actions menu
    /// are real buttons inside the same row, and a button nested in a button's
    /// label fights it for the tap. Same shape as the calendar's event rows.
    private var openContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            titleText
            metaLine
            previewLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { actions.open(node.id) }
        .help("Open \(node.entry.title)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the meeting")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { actions.open(node.id) }
    }

    /// The row's title. A narrow ledger has room for two lines, so it wraps
    /// instead of ellipsising a title down to its first few words; a wide one
    /// keeps one line, where a second would only add height to every row.
    @ViewBuilder
    private var titleText: some View {
        if compact {
            titleLabel.fixedSize(horizontal: false, vertical: true)
        } else {
            titleLabel
        }
    }

    private var titleLabel: some View {
        Text(node.entry.title)
            .font(titleFont)
            .foregroundStyle(MeetsTheme.textPrimary)
            .lineLimit(compact ? 2 : 1)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
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
        .opacity(isHovering ? 1 : 0)
        .accessibilityHidden(false)
    }

    /// State, duration, folder, and where the meeting came from. The date leads
    /// on a narrow ledger, where the gutter is gone. The arrangements go from
    /// one line to three: the detail column can narrow to the point where a line
    /// of chips would truncate the title's only remaining neighbours, and a
    /// follow-up pill must never wrap inside itself — so it takes a line of its
    /// own before that can happen.
    @ViewBuilder
    private var metaLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MeetsTheme.spacing8) {
                primaryElements
                secondaryElements
                followUpPill
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: MeetsTheme.spacing8) {
                    primaryElements
                    Spacer(minLength: 0)
                }
                HStack(spacing: MeetsTheme.spacing8) {
                    secondaryElements
                    followUpPill
                    Spacer(minLength: 0)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: MeetsTheme.spacing8) {
                    primaryElements
                    Spacer(minLength: 0)
                }
                HStack(spacing: MeetsTheme.spacing8) {
                    secondaryElements
                    Spacer(minLength: 0)
                }
                HStack(spacing: MeetsTheme.spacing8) {
                    followUpPill
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Date, state, range and duration: what the meeting is.
    @ViewBuilder
    private var primaryElements: some View {
        compactDateElement
        statusElement
        rangeElement
        durationElement
    }

    /// Folder and source, plus any follow-ups living outside this scope: where
    /// the meeting sits.
    @ViewBuilder
    private var secondaryElements: some View {
        folderElement
        sourceElement
        followUpsElsewhereElement
    }

    /// This meeting's follow-ups, counted and opened. Its own button, layered
    /// over the row's tap target, so opening a family never opens the meeting.
    @ViewBuilder
    private var followUpPill: some View {
        if let followUpLabel {
            MeetingFollowUpPill(
                label: followUpLabel,
                isExpanded: followUpsExpanded,
                onToggle: onToggleFollowUps
            )
        }
    }

    @ViewBuilder
    private var previewLine: some View {
        if let previewText = display.previewText {
            Text(previewText)
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A follow-up deeper than the first step says in words which meeting it
    /// follows on from: the sublist indents every row one step, so indentation
    /// alone can no longer say what it says for the row whose root is directly
    /// above it. A caption, not a link: that meeting is always somewhere above
    /// in the same sublist.
    @ViewBuilder
    private var parentCaption: some View {
        if case .child = kind, node.depth > 1, let parentTitle = node.entry.predecessorTitle {
            Text("Follow-up to \(parentTitle)")
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Follow-up to \(parentTitle)")
        }
    }

    /// A scoped root whose predecessor lives outside the current folder. The
    /// link is the only way to reach that meeting from here, so it stays an
    /// action rather than a caption.
    @ViewBuilder
    private var externalParentLink: some View {
        if case .root = kind, let externalParent = node.externalParent {
            Button {
                actions.open(externalParent.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.left.up")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Follow-up to \(externalParent.title)")
                        .font(MeetsTheme.caption())
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(MeetsTheme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(externalParent.title)")
            .accessibilityLabel("Open parent meeting \(externalParent.title)")
        }
    }

    @ViewBuilder
    private var compactDateElement: some View {
        if compact {
            Text(gutterLabel)
                .font(MeetsTheme.caption())
                .monospacedDigit()
                .foregroundStyle(MeetsTheme.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .help(MeetingBrowserLogic.formatStartTime(node.entry.startTime))
        }
    }

    @ViewBuilder
    private var statusElement: some View {
        if node.entry.status != .completed {
            MeetingStatusBadge(status: node.entry.status)
        }
    }

    @ViewBuilder
    private var rangeElement: some View {
        if !node.matchesFilter {
            MeetingOutsideRangeChip()
        }
    }

    private var durationElement: some View {
        Text(MeetingListItemFormat.duration(node.entry.durationSeconds))
            .font(MeetsTheme.caption())
            .monospacedDigit()
            .foregroundStyle(MeetsTheme.textSecondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    /// Only when the meeting sits outside the folder being viewed: inside that
    /// folder the chip would repeat the page heading on every row.
    @ViewBuilder
    private var folderElement: some View {
        if let folderID = node.entry.folderID,
           folderID != currentFolderID,
           let path = folderBreadcrumbs[folderID] {
            let name = MeetingFolderBreadcrumbs.leafName(of: path)
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                Text(name)
                    .font(MeetsTheme.caption())
                    .lineLimit(1)
            }
            .foregroundStyle(MeetsTheme.textSecondary)
            .help(path)
            .accessibilityLabel("Folder: \(path)")
        }
    }

    @ViewBuilder
    private var sourceElement: some View {
        if display.isImportedAudio {
            sourceGlyph(icon: "square.and.arrow.down", help: "Imported audio")
        } else if display.hasSavedRecording {
            sourceGlyph(icon: "waveform", help: "Saved recording available")
        }
    }

    @ViewBuilder
    private var followUpsElsewhereElement: some View {
        if hasOutsideScopeFollowUps {
            sourceGlyph(icon: "arrow.triangle.branch", help: "This meeting has follow-ups outside the current folder")
        }
    }

    /// A quiet 10-point glyph: the icon carries the meaning and the help text
    /// carries the words, so no chip has to earn its place in the row.
    private func sourceGlyph(icon: String, help: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(MeetsTheme.textSecondary)
            .help(help)
            .accessibilityLabel(help)
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
        if !node.matchesFilter {
            parts.append("outside the active date range")
        }
        return parts.joined(separator: ", ")
    }
}

/// The root row's follow-up pill: how many follow-ups hang under this meeting,
/// and the way to open or fold the sublist they render into.
///
/// It is a button of its own inside the row's metadata line, layered over the
/// row's tap target: opening a family and opening the meeting it belongs to are
/// two different things, and neither should ever do the other. The chevron
/// turns as the sublist unfolds, at the same speed and in the same moment.
struct MeetingFollowUpPill: View {
    let label: String
    let isExpanded: Bool
    let onToggle: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeOut(duration: ledgerUnfoldDuration), value: isExpanded)
                Text(label)
                    .font(MeetsTheme.captionMedium())
                    .lineLimit(1)
                    // Never compress the count into an ellipsis: the pill moves
                    // to a line of its own before that, and a label that says
                    // "4 follow-ups · 4…" reports nothing.
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(isHovering ? MeetsTheme.textPrimary : MeetsTheme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(MeetsTheme.surfacePrimary)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Shows this meeting's follow-up meetings")
        .accessibilityLabel("Follow-ups")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows this meeting's follow-up meetings")
    }
}

/// Folder navigation tile for the level directly below the current scope: a
/// quiet row of name and count that never competes with the meetings.
struct MeetingFolderCardView: View {
    let folder: MeetingFolder
    let meetingCount: Int
    let hasSubfolders: Bool
    let onOpen: () -> Void
    @State private var isHovering = false

    private var countLabel: String {
        switch meetingCount {
        case 0: return "No meetings"
        case 1: return "1 meeting"
        default: return "\(meetingCount) meetings"
        }
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: MeetsTheme.spacing8) {
                Image(systemName: hasSubfolders ? "folder.fill" : "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(MeetsTheme.textSecondary)
                    .frame(width: 16)

                Text(folder.name)
                    .font(MeetsTheme.captionMedium())
                    .foregroundStyle(MeetsTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: MeetsTheme.spacing4)

                Text("\(meetingCount)")
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textSecondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? MeetsTheme.backgroundHover : MeetsTheme.surfacePrimary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Open \(folder.name) \u{00B7} \(countLabel)")
        .accessibilityLabel("\(folder.name), \(countLabel)")
    }
}
