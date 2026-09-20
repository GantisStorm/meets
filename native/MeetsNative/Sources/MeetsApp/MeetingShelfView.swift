import SwiftUI
import Foundation
import MeetsCore

/// Actions the browser hands to a shelf. Bundled so shelf and row views stay
/// free of the controller.
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

/// One follow-up family as a single card: the parent row, then its descendants
/// inside the same enclosure below a divider.
///
/// Everything a family owns is drawn between one border, so a thread reads as
/// one object instead of a card followed by a pile of loose rows. Depth inside
/// the enclosure is carried by a single thread rail and modest indentation; a
/// branch deep enough that indentation stops meaning anything names its parent
/// in words instead.
struct MeetingShelfView: View {
    let shelf: MeetingBrowserShelf
    let isSelected: Bool
    let isExpanded: Bool
    let rootHasFollowUps: Bool
    let selectedMeetingID: Int64?
    let folders: [MeetingFolder]
    let folderBreadcrumbs: [Int64: String]
    /// True when the rendered card is too narrow for generous padding and two
    /// preview lines.
    let compact: Bool
    /// True in the list layout, where a family is a compact library row rather
    /// than a spacious grid card.
    let dense: Bool
    /// True when a date range is active, so the overflow control may report
    /// how many hidden follow-ups fall inside it.
    let annotatesHiddenMatches: Bool
    let actions: MeetingShelfActions

    /// Leading inset of the descendant block inside the enclosure: enough that
    /// children read as nested under the parent, without a decorative spine.
    private static let descendantInset: CGFloat = 20

    /// What the collapsed shelf shows and what the overflow control reports.
    /// A filtered thread can otherwise hide its only matching meeting behind
    /// context ancestors.
    private var descendantPlan: MeetingBrowserDescendantPlan {
        MeetingBrowserLogic.descendantPlan(
            matchFlags: shelf.descendants.map(\.matchesFilter),
            isExpanded: isExpanded
        )
    }

    private var visibleDescendants: [MeetingBrowserNode] {
        let visibleCount = descendantPlan.visibleCount
        return visibleCount == shelf.descendants.count
            ? shelf.descendants
            : Array(shelf.descendants.prefix(visibleCount))
    }

    /// A shelf only ever expands past the initial limit, so a shelf with more
    /// descendants than the limit always keeps its footer. That is the control
    /// that used to disappear the moment the thread was expanded, leaving no
    /// way back to the collapsed shelf.
    private var showsThreadFooter: Bool {
        shelf.descendants.count > MeetingBrowserLogic.initialDescendantLimit
    }

    /// True when any member of the family is the open meeting, so the
    /// enclosure can mark itself without filling the row the user is not on.
    private var containsSelection: Bool {
        if shelf.root.id == selectedMeetingID { return true }
        return shelf.descendants.contains { $0.id == selectedMeetingID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MeetingListItemView(
                display: MeetingListItemDisplay(entry: shelf.root.entry, record: shelf.root.record),
                isSelected: isSelected,
                hasFollowUps: rootHasFollowUps,
                followUpCount: shelf.descendants.count,
                folders: folders,
                folderBreadcrumbs: folderBreadcrumbs,
                externalParent: shelf.root.externalParent,
                isOutsideRange: !shelf.root.matchesFilter,
                compact: compact,
                dense: dense,
                canStartFollowUp: actions.canStartFollowUp(shelf.root),
                canDelete: actions.canDelete(shelf.root),
                onSelect: { actions.open(shelf.root.id) },
                onMove: { actions.move(shelf.root.id, $0) },
                onCreateFolderAndMove: { actions.createFolderAndMove($0, shelf.root.id) },
                onDelete: { actions.delete(shelf.root.id) },
                onStartFollowUp: { actions.startFollowUp(shelf.root.id) },
                onOpenParent: { actions.open($0) }
            )

            if !shelf.descendants.isEmpty {
                descendants
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MeetsTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerLarge))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerLarge)
                .strokeBorder(
                    containsSelection ? MeetsTheme.accent.opacity(0.35) : MeetsTheme.surfaceBorder,
                    lineWidth: 1
                )
        )
    }

    private var descendants: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .foregroundStyle(MeetsTheme.surfaceBorder)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(visibleDescendants) { node in
                    MeetingThreadRow(
                        node: node,
                        isSelected: node.id == selectedMeetingID,
                        folders: folders,
                        folderBreadcrumbs: folderBreadcrumbs,
                        dense: dense,
                        actions: actions
                    )
                }

                if showsThreadFooter {
                    MeetingThreadOverflowControl(
                        shelf: shelf,
                        plan: descendantPlan,
                        annotatesHiddenMatches: annotatesHiddenMatches,
                        isExpanded: isExpanded,
                        onToggle: { actions.toggleExpanded(shelf.id) }
                    )
                    .padding(.top, 2)
                }
            }
            .padding(.leading, Self.descendantInset)
            .padding(.trailing, compact ? MeetsTheme.spacing12 : MeetsTheme.spacing16)
            .padding(.bottom, dense ? MeetsTheme.spacing8 : MeetsTheme.spacing12)
        }
    }
}

/// One descendant inside a shelf: its title on the first line with its own
/// actions menu, and its state and timing beneath it.
///
/// The title owns the first line alone — status and range markers moved down to
/// the metadata line — because at the narrowest detail column a title sharing a
/// line with three chips collapses to a few characters. Indentation carries the
/// hierarchy while the shelf still has depth to spare; past the cap the row
/// names the meeting it hangs from instead.
struct MeetingThreadRow: View {
    let node: MeetingBrowserNode
    let isSelected: Bool
    let folders: [MeetingFolder]
    let folderBreadcrumbs: [Int64: String]
    /// True in the list layout, which tightens the row's vertical rhythm.
    let dense: Bool
    let actions: MeetingShelfActions
    @State private var isHovering = false

    private static let indentStep: CGFloat = 12

    private var indentLevels: Int {
        min(max(node.depth - 1, 0), MeetingBrowserLogic.indentationCapDepth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: MeetsTheme.spacing8) {
                openButton
                Spacer(minLength: 0)
                actionsMenu
            }

            detailLine
        }
        .padding(.leading, CGFloat(indentLevels) * Self.indentStep)
        .padding(.trailing, MeetsTheme.spacing8)
        .padding(.vertical, dense ? 5 : 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture { actions.open(node.id) }
        .onHover { isHovering = $0 }
    }

    private var openButton: some View {
        Button {
            actions.open(node.id)
        } label: {
            Text(node.entry.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MeetsTheme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .truncationMode(.tail)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(node.entry.title)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the meeting")
    }

    private var actionsMenu: some View {
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

    /// State first, then when it ran, then — where the rail alone no longer says
    /// it — what it follows on from. The date keeps its full width and the named
    /// parent gives way first; a narrow column stacks the two instead of
    /// clipping either.
    private var detailLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                badgeElements
                metaText
                parentText
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    badgeElements
                    metaText
                    Spacer(minLength: 0)
                }
                parentText
            }

            VStack(alignment: .leading, spacing: 2) {
                badgeElements
                metaText
                parentText
            }
        }
    }

    @ViewBuilder
    private var badgeElements: some View {
        if node.entry.status != .completed {
            MeetingStatusBadge(status: node.entry.status)
        }
        if !node.matchesFilter {
            MeetingOutsideRangeChip()
        }
    }

    private var metaText: some View {
        Text(MeetingListItemFormat.meta(
            startTime: node.entry.startTime,
            durationSeconds: node.entry.durationSeconds
        ))
        .font(.system(size: 11))
        .foregroundStyle(MeetsTheme.textSecondary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .help(MeetingBrowserLogic.formatStartTime(node.entry.startTime))
    }

    @ViewBuilder
    private var parentText: some View {
        if let parentTitle = node.parentLinkTitle {
            Text("Follow-up to \(parentTitle)")
                .font(.system(size: 11))
                .foregroundStyle(MeetsTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help("Follow-up to \(parentTitle)")
        }
    }

    private var rowBackground: Color {
        if isSelected { return MeetsTheme.surfaceSelected }
        return isHovering ? MeetsTheme.backgroundHover : .clear
    }

    private var accessibilityLabel: String {
        var parts: [String] = [node.entry.title]
        parts.append(MeetingBrowserLogic.formatStartTime(node.entry.startTime))
        parts.append(MeetingListItemFormat.duration(node.entry.durationSeconds))
        if node.entry.status != .completed {
            parts.append("status \(node.entry.status.displayLabel)")
        }
        if let folderID = node.entry.folderID, let folderName = folderBreadcrumbs[folderID] {
            parts.append("in folder \(folderName)")
        }
        if let parentTitle = node.parentLinkTitle {
            parts.append("follow-up to \(parentTitle)")
        } else if node.depth > 0 {
            parts.append("follow-up")
        }
        if !node.matchesFilter {
            parts.append("outside the active date range")
        }
        return parts.joined(separator: ", ")
    }
}

/// Collapsed-descendant control. Hovering previews the whole thread in a
/// scrollable popover; activating it — by click or keyboard — expands or
/// collapses the shelf in place.
struct MeetingThreadOverflowControl: View {
    let shelf: MeetingBrowserShelf
    let plan: MeetingBrowserDescendantPlan
    /// True when a date range is active, so hidden matches are worth reporting.
    let annotatesHiddenMatches: Bool
    let isExpanded: Bool
    let onToggle: () -> Void
    @State private var showsPreview = false
    @State private var isHovering = false
    @State private var hideWorkItem: DispatchWorkItem?

    private var label: String {
        isExpanded ? "Show fewer follow-ups" : plan.summary(annotatingMatches: annotatesHiddenMatches)
    }

    var body: some View {
        Button {
            cancelHide()
            showsPreview = false
            onToggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isHovering ? MeetsTheme.textPrimary : MeetsTheme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isHovering ? MeetsTheme.backgroundHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
        .onHover { hovering in
            isHovering = hovering
            guard !isExpanded else { return }
            if hovering { showPreview() } else { scheduleHide() }
        }
        .onChange(of: isExpanded) { _, expanded in
            guard expanded else { return }
            cancelHide()
            showsPreview = false
        }
        .onDisappear { cancelHide() }
        .popover(isPresented: $showsPreview, arrowEdge: .bottom) {
            preview
        }
    }

    private var helpText: String {
        guard !isExpanded else { return "Collapse this follow-up thread" }
        guard plan.hiddenMatchCount > 0 else { return "Show every follow-up in this thread" }
        return "\(plan.hiddenCount) follow-ups are hidden, \(plan.hiddenMatchCount) of them inside the active date range"
    }

    private var accessibilityLabel: String {
        guard !isExpanded else { return "Collapse follow-up thread" }
        let base = "Show all \(shelf.descendants.count) follow-ups"
        guard plan.hiddenMatchCount > 0 else { return base }
        return "\(base), \(plan.hiddenMatchCount) matching the active date range"
    }

    /// The popover outlives the cursor leaving the button so the thread can be
    /// scrolled; it closes shortly after the pointer leaves both.
    private var preview: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
            Text("Follow-up thread \u{00B7} \(shelf.totalCount) meetings")
                .font(MeetsTheme.captionMedium())
                .foregroundStyle(MeetsTheme.textSecondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
                    ForEach(shelf.descendants) { node in
                        previewRow(node)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            }
            .frame(height: previewHeight)
        }
        .padding(MeetsTheme.spacing12)
        .frame(width: 340)
        .onHover { inside in
            if inside { cancelHide() } else { scheduleHide() }
        }
    }

    /// Sized to the thread so a short thread does not open a mostly empty
    /// panel; long threads cap at 300 pt and scroll.
    private var previewHeight: CGFloat {
        let rowHeight: CGFloat = 32
        let rowSpacing: CGFloat = MeetsTheme.spacing8
        let count = CGFloat(max(shelf.descendants.count, 1))
        return min(300, count * rowHeight + (count - 1) * rowSpacing)
    }

    private func previewRow(_ node: MeetingBrowserNode) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(node.entry.title)
                    .font(MeetsTheme.captionMedium())
                    .foregroundStyle(MeetsTheme.textPrimary)
                    .lineLimit(1)
                if node.entry.status != .completed {
                    MeetingStatusBadge(status: node.entry.status)
                }
                Spacer(minLength: 0)
            }
            Text(MeetingListItemFormat.meta(
                startTime: node.entry.startTime,
                durationSeconds: node.entry.durationSeconds
            ))
            .font(.system(size: 11))
            .foregroundStyle(MeetsTheme.textSecondary)
            .lineLimit(1)
        }
        .padding(.leading, CGFloat(min(node.depth, MeetingBrowserLogic.indentationCapDepth + 1)) * 12)
    }

    private func showPreview() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        showsPreview = true
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            showsPreview = false
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func cancelHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }
}

/// Folder navigation tile for the level directly below the current scope: a
/// quiet row of name and count that never competes with the meeting cards.
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
