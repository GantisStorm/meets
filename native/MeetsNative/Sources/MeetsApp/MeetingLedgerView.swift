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

/// Geometry shared by the rows, the thread and the rail drawn through them.
/// One definition, because the rail has to land exactly on the rows it marks:
/// the gutter puts the time in a fixed column, and everything else is measured
/// from that column rather than from each row's own contents.
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
    /// Vertical rail the follow-ups hang from, in the thread's coordinates.
    static func railX(compact: Bool) -> CGFloat {
        rowHorizontalPadding + gutterWidth(compact: compact) + gutterSpacing
    }
    /// How far the rail reaches towards each follow-up. A follow-up's content
    /// starts exactly this far right of the rail, so every tick lands on the
    /// row it belongs to no matter how deep the thread runs.
    static let railTickLength: CGFloat = 10
    /// Extra indent per nesting level.
    static let indentStep: CGFloat = 16
    /// Nesting carried by indentation alone; deeper rows name their parent.
    static let indentCap = MeetingBrowserLogic.indentationCapDepth

    static func indent(forDepth depth: Int) -> CGFloat {
        CGFloat(min(max(depth - 1, 0), indentCap - 1)) * indentStep
    }

    /// Where a follow-up's own content begins, relative to the thread.
    static func childContentInset(forDepth depth: Int) -> CGFloat {
        railTickLength + indent(forDepth: depth)
    }

    /// Where a row's title sits on the vertical axis: the row's own padding
    /// plus the font's own baseline below the top of its line box. The rail's
    /// ticks land on the title they mark, and the offset comes from the font
    /// rather than from a hand-written constant, so changing the type size
    /// moves both together. Rounded, because a hairlines that lands between two
    /// pixel rows loses half its contrast to antialiasing.
    static func titleBaselineY(inRowStartingAt minY: CGFloat, kind: MeetingLedgerRowKind) -> CGFloat {
        (minY + rowVerticalPadding + titleBaselineOffset(for: kind)).rounded()
    }

    private static func titleBaselineOffset(for kind: MeetingLedgerRowKind) -> CGFloat {
        let font: NSFont
        switch kind {
        case .root: font = .systemFont(ofSize: 14, weight: .semibold)
        case .child: font = .systemFont(ofSize: 13, weight: .medium)
        }
        return font.ascender + font.leading / 2
    }

    /// The rail and its ticks. `textTertiary` rather than the hairline border
    /// tone: a 10-point tick at border opacity disappears against the canvas,
    /// and a rail nobody can see is a rail that isn't drawn.
    static let rail = MeetsTheme.textTertiary

    /// Height of the thread's fold control.
    static let moreRowHeight: CGFloat = 28
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
/// follow-up families that started inside it, with the family's thread hanging
/// from a rail under its root.
///
/// One column and no cards — the archive is read top to bottom, and the only
/// things that carry structure are the section headings, the fixed time gutter,
/// and the rail. Root rows and follow-up rows use the same row shape, so a deep
/// thread reads as the same kind of object as the meeting it came from.
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

/// One follow-up family as a ledger entry: the root meeting, then — while the
/// thread is open — its follow-ups hanging from a rail beneath it.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MeetingLedgerRow(
                node: shelf.root,
                kind: .root,
                rootDate: shelf.root.startDate,
                now: now,
                hasOutsideScopeFollowUps: hasOutsideScopeFollowUps,
                folders: folders,
                folderBreadcrumbs: folderBreadcrumbs,
                currentFolderID: currentFolderID,
                compact: compact,
                actions: actions
            )

            if !shelf.descendants.isEmpty {
                MeetingLedgerThread(
                    shelf: shelf,
                    isExpanded: isExpanded,
                    now: now,
                    folders: folders,
                    folderBreadcrumbs: folderBreadcrumbs,
                    currentFolderID: currentFolderID,
                    compact: compact,
                    annotatesHiddenMatches: annotatesHiddenMatches,
                    actions: actions
                )
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }
}

/// Which place in a family a row occupies. Roots carry the family's weight;
/// children are the same row, quieter, hanging one step to the right.
enum MeetingLedgerRowKind: Hashable {
    case root
    case child(depth: Int)
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
        case let .child(depth): return MeetingLedgerMetrics.childContentInset(forDepth: depth)
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
                    openButton
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

    /// Title, state and preview. The whole block opens the meeting; the actions
    /// menu is its sibling, never nested, so both stay reachable from the
    /// keyboard.
    private var openButton: some View {
        Button {
            actions.open(node.id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                titleText
                metaLine
                previewLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(node.entry.title)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the meeting")
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
    /// on a narrow ledger, where the gutter is gone. Two arrangements, because
    /// the detail column can narrow to the point where one line of chips would
    /// truncate the title's only remaining neighbours.
    @ViewBuilder
    private var metaLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MeetsTheme.spacing8) {
                compactDateElement
                statusElement
                rangeElement
                durationElement
                folderElement
                sourceElement
                followUpsElsewhereElement
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: MeetsTheme.spacing8) {
                    compactDateElement
                    statusElement
                    rangeElement
                    durationElement
                    Spacer(minLength: 0)
                }
                HStack(spacing: MeetsTheme.spacing8) {
                    folderElement
                    sourceElement
                    followUpsElsewhereElement
                    Spacer(minLength: 0)
                }
            }
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

    /// Past the indentation cap a thread's depth stops meaning anything, so the
    /// row says in words what the rail can no longer show. A caption, not a
    /// link: the parent is always somewhere above in the same thread.
    @ViewBuilder
    private var parentCaption: some View {
        if case .child = kind, let parentTitle = node.parentLinkTitle {
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

/// Every follow-up of one family, in thread order, hanging from a rail under
/// the root.
///
/// The rail is the thread: one hairline from the root down to the last visible
/// follow-up, with a tick landing on each row it reaches. Collapsed, it shows
/// the first follow-ups and offers the rest; expanded, it shows all of them and
/// offers to close again.
struct MeetingLedgerThread: View {
    let shelf: MeetingBrowserShelf
    let isExpanded: Bool
    let now: Date
    let folders: [MeetingFolder]
    let folderBreadcrumbs: [Int64: String]
    let currentFolderID: Int64?
    let compact: Bool
    let annotatesHiddenMatches: Bool
    let actions: MeetingShelfActions
    @State private var isHoveringMore = false

    /// Key for the fold control's own anchor, so the rail ends at the control
    /// that stands for the rows it is hiding.
    private static let moreRowAnchorID = Int64.min

    /// One speed for the fold, so the rows and the control they hang from move
    /// as one thing.
    private static let foldAnimationDuration: Double = 0.18

    private var visibleNodes: [MeetingBrowserNode] {
        isExpanded
            ? shelf.descendants
            : Array(shelf.descendants.prefix(MeetingBrowserLogic.ledgerCollapsedDescendantLimit))
    }

    private var hidesFollowUps: Bool {
        shelf.descendants.count > MeetingBrowserLogic.ledgerCollapsedDescendantLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(visibleNodes) { node in
                MeetingLedgerRow(
                    node: node,
                    kind: .child(depth: node.depth),
                    rootDate: shelf.root.startDate,
                    now: now,
                    hasOutsideScopeFollowUps: false,
                    folders: folders,
                    folderBreadcrumbs: folderBreadcrumbs,
                    currentFolderID: currentFolderID,
                    compact: compact,
                    actions: actions
                )
                .anchorPreference(key: LedgerThreadAnchorKey.self, value: .bounds) { [node.id: $0] }
            }

            if hidesFollowUps {
                moreRow
                    .anchorPreference(key: LedgerThreadAnchorKey.self, value: .bounds) {
                        [Self.moreRowAnchorID: $0]
                    }
            }
        }
        .overlayPreferenceValue(LedgerThreadAnchorKey.self) { anchors in
            GeometryReader { proxy in
                let frames = anchors.compactMapValues { proxy[$0] }
                Path { path in
                    let railX = MeetingLedgerMetrics.railX(compact: compact)
                    guard let lastRow = frames[lastVisibleAnchorID] else { return }
                    path.move(to: CGPoint(x: railX, y: 0))
                    path.addLine(to: CGPoint(x: railX, y: lastRow.midY))

                    for node in visibleNodes {
                        guard let row = frames[node.id] else { continue }
                        let y = MeetingLedgerMetrics.titleBaselineY(
                            inRowStartingAt: row.minY,
                            kind: .child(depth: node.depth)
                        )
                        path.move(to: CGPoint(x: railX, y: y))
                        path.addLine(
                            to: CGPoint(
                                x: railX + MeetingLedgerMetrics.childContentInset(forDepth: node.depth),
                                y: y
                            )
                        )
                    }

                    if hidesFollowUps, let foldRow = frames[Self.moreRowAnchorID] {
                        let y = foldRow.midY.rounded()
                        path.move(to: CGPoint(x: railX, y: y))
                        path.addLine(to: CGPoint(x: railX + MeetingLedgerMetrics.railTickLength, y: y))
                    }
                }
                .stroke(MeetingLedgerMetrics.rail, lineWidth: 1)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var lastVisibleAnchorID: Int64 {
        hidesFollowUps ? Self.moreRowAnchorID : (visibleNodes.last?.id ?? Self.moreRowAnchorID)
    }

    /// The thread's last element: the count of what is folded away, and the
    /// control that folds it. Expanding brings every follow-up in along the
    /// rail rather than jumping the page.
    private var moreRow: some View {
        MeetingLedgerMoreRow(
            label: MeetingBrowserLogic.ledgerMoreLabel(
                hiddenCount: shelf.descendants.count - MeetingBrowserLogic.ledgerCollapsedDescendantLimit,
                hiddenMatchCount: shelf.descendants
                    .dropFirst(MeetingBrowserLogic.ledgerCollapsedDescendantLimit)
                    .filter(\.matchesFilter)
                    .count,
                annotatesMatches: annotatesHiddenMatches,
                isExpanded: isExpanded
            ),
            isExpanded: isExpanded,
            compact: compact,
            isHovering: isHoveringMore,
            onToggle: {
                withAnimation(.easeOut(duration: Self.foldAnimationDuration)) {
                    actions.toggleExpanded(shelf.id)
                }
            }
        )
        .onHover { isHoveringMore = $0 }
    }
}

/// The frame of each rendered row, keyed by meeting id, so the rail is drawn
/// through the rows that actually exist — their real heights, their real
/// positions — instead of through assumed row metrics.
private struct LedgerThreadAnchorKey: PreferenceKey {
    static var defaultValue: [Int64: Anchor<CGRect>] { [:] }

    static func reduce(
        value: inout [Int64: Anchor<CGRect>],
        nextValue: () -> [Int64: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The fold control at the end of a thread: how many follow-ups are still
/// folded away, and the way in or out. It sits in the rail's column, so the
/// thread's text stays one column wide whatever the control says.
struct MeetingLedgerMoreRow: View {
    let label: String
    let isExpanded: Bool
    let compact: Bool
    let isHovering: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(MeetsTheme.captionMedium())
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isHovering ? MeetsTheme.textPrimary : MeetsTheme.textSecondary)
            .padding(
                .leading,
                MeetingLedgerMetrics.railX(compact: compact) + MeetingLedgerMetrics.railTickLength
            )
            .padding(.trailing, MeetingLedgerMetrics.rowHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: MeetingLedgerMetrics.moreRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Fold this follow-up thread" : "Show every follow-up in this thread")
        .accessibilityLabel("Follow-ups")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
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
