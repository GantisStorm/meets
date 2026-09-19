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

/// One follow-up shelf: the root meeting as a card, then its descendants as
/// compact nested rows. The shelf carries no chrome of its own, so a card
/// never ends up inside another card.
struct MeetingShelfView: View {
    let shelf: MeetingBrowserShelf
    let isSelected: Bool
    let isExpanded: Bool
    let rootHasFollowUps: Bool
    let selectedMeetingID: Int64?
    let folders: [MeetingFolder]
    let folderBreadcrumbs: [Int64: String]
    /// True when the rendered card is too narrow for a title and its action
    /// cluster to share a row.
    let compact: Bool
    /// True when a date range is active, so the overflow control may report
    /// how many hidden follow-ups fall inside it.
    let annotatesHiddenMatches: Bool
    let actions: MeetingShelfActions

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

    var body: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
            MeetingListItemView(
                display: MeetingListItemDisplay(entry: shelf.root.entry, record: shelf.root.record),
                isSelected: isSelected,
                hasFollowUps: rootHasFollowUps,
                followUpCount: shelf.descendants.count,
                folders: folders,
                folderBreadcrumbs: folderBreadcrumbs,
                externalParent: shelf.root.externalParent,
                isOutsideRange: !shelf.root.matchesFilter,
                compactHeader: compact,
                onSelect: { actions.open(shelf.root.id) },
                onMove: { actions.move(shelf.root.id, $0) },
                onCreateFolderAndMove: { actions.createFolderAndMove($0, shelf.root.id) },
                onDelete: actions.canDelete(shelf.root) ? { actions.delete(shelf.root.id) } : nil,
                onStartFollowUp: actions.canStartFollowUp(shelf.root)
                    ? { actions.startFollowUp(shelf.root.id) }
                    : nil,
                onOpenParent: { actions.open($0) }
            )

            if !shelf.descendants.isEmpty {
                descendants
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var descendants: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(visibleDescendants) { node in
                MeetingThreadRow(
                    node: node,
                    isSelected: node.id == selectedMeetingID,
                    folders: folders,
                    folderBreadcrumbs: folderBreadcrumbs,
                    compact: compact,
                    actions: actions
                )
            }

            if descendantPlan.hiddenCount > 0 {
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
        .padding(.leading, MeetsTheme.spacing8)
    }
}

/// One descendant inside a shelf: a compact row, indented while indentation
/// still conveys the hierarchy and naming its parent once it does not.
struct MeetingThreadRow: View {
    let node: MeetingBrowserNode
    let isSelected: Bool
    let folders: [MeetingFolder]
    let folderBreadcrumbs: [Int64: String]
    /// True when the column is too narrow to keep the row text and its action
    /// cluster side by side: the actions move below so indentation does not
    /// consume the title.
    let compact: Bool
    let actions: MeetingShelfActions
    @State private var isHovering = false

    private static let indentStep: CGFloat = 10

    private var indentLevels: Int {
        min(max(node.depth - 1, 0), MeetingBrowserLogic.indentationCapDepth)
    }

    private var folderName: String? {
        guard let folderID = node.entry.folderID else { return nil }
        return folderBreadcrumbs[folderID]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            indentationGuide

            if compact {
                VStack(alignment: .leading, spacing: 4) {
                    openButton
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        actionCluster
                    }
                }
            } else {
                openButton
                actionCluster
            }
        }
        .padding(.vertical, 5)
        .padding(.trailing, MeetsTheme.spacing8)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
        .onHover { isHovering = $0 }
    }

    private var openButton: some View {
        Button {
            actions.open(node.id)
        } label: {
            rowContent
        }
        .buttonStyle(.plain)
        .help("Open \(node.entry.title)")
        .accessibilityLabel(accessibilityLabel)
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.left.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(MeetsTheme.accent.opacity(0.75))
                Text(node.entry.title)
                    .font(MeetsTheme.captionMedium())
                    .foregroundStyle(MeetsTheme.textPrimary)
                    .lineLimit(1)
                if node.entry.status != .completed {
                    MeetingStatusBadge(status: node.entry.status)
                }
                if !node.matchesFilter {
                    MeetingOutsideRangeChip()
                }
                Spacer(minLength: 0)
            }

            metaRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var metaRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                metaText
                folderChip
                parentLink
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    metaText
                    folderChip
                    Spacer(minLength: 0)
                }
                parentLink
            }
        }
    }

    private var metaText: some View {
        Text("\(MeetingBrowserLogic.formatStartTime(node.entry.startTime))  \u{2022}  \(MeetingListItemFormat.duration(node.entry.durationSeconds))")
            .font(MeetsTheme.caption())
            .foregroundStyle(MeetsTheme.textSecondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var folderChip: some View {
        if let folderName {
            HStack(spacing: 2) {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                Text(folderName)
                    .font(MeetsTheme.caption())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(MeetsTheme.accent.opacity(0.8))
            .help(folderName)
            .accessibilityLabel("Folder: \(folderName)")
        }
    }

    /// Names the predecessor whenever the rail alone no longer says where this
    /// row hangs from: the parent is outside the shelf, or the row sits past
    /// the indentation cap.
    @ViewBuilder
    private var parentLink: some View {
        if let parentTitle = node.parentLinkTitle {
            Text("Follow-up to \(parentTitle)")
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help("Follow-up to \(parentTitle)")
                .accessibilityLabel("Follow-up to \(parentTitle)")
        }
    }

    @ViewBuilder
    private var indentationGuide: some View {
        if indentLevels > 0 {
            HStack(spacing: 0) {
                ForEach(0..<indentLevels, id: \.self) { _ in
                    Rectangle()
                        .fill(MeetsTheme.surfaceBorder)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .padding(.leading, Self.indentStep - 1)
                }
            }
            .padding(.trailing, 2)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var actionCluster: some View {
        HStack(spacing: 2) {
            MeetingFolderMoveControl(
                folders: folders,
                breadcrumbs: folderBreadcrumbs,
                currentFolderID: node.entry.folderID,
                isHovering: isHovering,
                onMove: { actions.move(node.id, $0) },
                onCreateFolderAndMove: { actions.createFolderAndMove($0, node.id) }
            )
            if actions.canStartFollowUp(node) {
                MeetingFollowUpControl(isHovering: isHovering) {
                    actions.startFollowUp(node.id)
                }
            }
            if actions.canDelete(node) {
                MeetingDeleteControl(isHovering: isHovering) {
                    actions.delete(node.id)
                }
            }
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
        if let folderName {
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
/// scrollable popover; activating it — by click or keyboard — expands the
/// shelf in place.
struct MeetingThreadOverflowControl: View {
    let shelf: MeetingBrowserShelf
    let plan: MeetingBrowserDescendantPlan
    /// True when a date range is active, so hidden matches are worth reporting.
    let annotatesHiddenMatches: Bool
    let isExpanded: Bool
    let onToggle: () -> Void
    @State private var showsPreview = false
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
            .foregroundStyle(MeetsTheme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(MeetsTheme.accent.opacity(0.10))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
        .onHover { hovering in
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
            .frame(height: 300)
        }
        .padding(MeetsTheme.spacing12)
        .frame(width: 340)
        .onHover { inside in
            if inside { cancelHide() } else { scheduleHide() }
        }
    }

    private func previewRow(_ node: MeetingBrowserNode) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.turn.left.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(MeetsTheme.accent.opacity(0.75))
                Text(node.entry.title)
                    .font(MeetsTheme.captionMedium())
                    .foregroundStyle(MeetsTheme.textPrimary)
                    .lineLimit(1)
                if node.entry.status != .completed {
                    MeetingStatusBadge(status: node.entry.status)
                }
                Spacer(minLength: 0)
            }
            Text(MeetingBrowserLogic.formatStartTime(node.entry.startTime))
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textSecondary)
                .lineLimit(1)
        }
        .padding(.leading, CGFloat(min(node.depth, MeetingBrowserLogic.indentationCapDepth + 1)) * 10)
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

/// Folder navigation card for the level directly below the current scope.
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
            HStack(spacing: MeetsTheme.spacing12) {
                Image(systemName: hasSubfolders ? "folder.fill" : "folder")
                    .font(.system(size: 14))
                    .foregroundStyle(MeetsTheme.textSecondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(MeetsTheme.captionMedium())
                        .foregroundStyle(MeetsTheme.textPrimary)
                        .lineLimit(1)
                    Text(countLabel)
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(MeetsTheme.textTertiary)
            }
            .padding(.horizontal, MeetsTheme.spacing12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? MeetsTheme.backgroundHover : MeetsTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerLarge))
            .overlay(
                RoundedRectangle(cornerRadius: MeetsTheme.cornerLarge)
                    .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Open \(folder.name)")
        .accessibilityLabel("\(folder.name), \(countLabel)")
    }
}
