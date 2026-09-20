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

/// One follow-up family as a single card: the root meeting, then — while the
/// card is expanded — every descendant in an inset panel below the disclosure.
///
/// Everything a family owns is drawn between one border, so a thread reads as
/// one object instead of a card followed by a pile of loose rows. The card's
/// root is the row itself; depth inside the panel is carried by modest
/// indentation, and a branch deep enough that indentation stops meaning
/// anything names its parent in words instead.
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
    /// True when a date range is active, so the disclosure may report how many
    /// follow-ups it holds back that fall inside it.
    let annotatesHiddenMatches: Bool
    let actions: MeetingShelfActions
    @State private var isHoveringDisclosure = false

    /// One speed for the chevron and the panel it opens, so a disclosure that
    /// turns and a panel that unfolds read as one movement.
    private static let disclosureAnimationDuration: Double = 0.18

    /// Follow-ups this card holds below its root.
    private var descendantCount: Int { shelf.descendants.count }

    /// Descendants that satisfy the active date range. While the card is
    /// collapsed those are exactly the meetings the fold is hiding, which is
    /// what the disclosure has to admit to.
    private var hiddenMatchCount: Int {
        shelf.descendants.reduce(into: 0) { total, node in
            if node.matchesFilter { total += 1 }
        }
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
                followUpCount: descendantCount,
                folders: folders,
                folderBreadcrumbs: folderBreadcrumbs,
                externalParent: shelf.root.externalParent,
                isOutsideRange: !shelf.root.matchesFilter,
                compact: compact,
                canStartFollowUp: actions.canStartFollowUp(shelf.root),
                canDelete: actions.canDelete(shelf.root),
                onSelect: { actions.open(shelf.root.id) },
                onMove: { actions.move(shelf.root.id, $0) },
                onCreateFolderAndMove: { actions.createFolderAndMove($0, shelf.root.id) },
                onDelete: { actions.delete(shelf.root.id) },
                onStartFollowUp: { actions.startFollowUp(shelf.root.id) },
                onOpenParent: { actions.open($0) }
            )

            if descendantCount > 0 {
                disclosure

                if isExpanded {
                    MeetingFollowUpListView(
                        shelf: shelf,
                        selectedMeetingID: selectedMeetingID,
                        folders: folders,
                        folderBreadcrumbs: folderBreadcrumbs,
                        actions: actions
                    )
                }
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

    /// The card's last element: one full-width row that says what the card is
    /// holding back and folds it open or shut in place. The whole row is the hit
    /// target — a disclosure that only answers on its own text is a miss waiting
    /// to happen — and the count capsule keeps the number visible once the label
    /// is the only thing left of the thread.
    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .foregroundStyle(MeetsTheme.surfaceBorder)

            Button {
                withAnimation(.easeInOut(duration: Self.disclosureAnimationDuration)) {
                    actions.toggleExpanded(shelf.id)
                }
            } label: {
                HStack(spacing: MeetsTheme.spacing8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MeetsTheme.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: Self.disclosureAnimationDuration), value: isExpanded)

                    Text(MeetingBrowserLogic.followUpDisclosureLabel(
                        descendantCount: descendantCount,
                        hiddenMatchCount: hiddenMatchCount,
                        isExpanded: isExpanded,
                        annotatesMatches: annotatesHiddenMatches
                    ))
                    .font(MeetsTheme.captionMedium())
                    .foregroundStyle(MeetsTheme.textSecondary)
                    // The label is the whole control, so it wraps rather than
                    // truncating: at the narrowest detail column the in-range
                    // note would otherwise be the first thing ellipsised away.
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                    Text("\(descendantCount)")
                        .font(MeetsTheme.caption())
                        .monospacedDigit()
                        .foregroundStyle(MeetsTheme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(MeetsTheme.surfacePrimary)
                        .clipShape(Capsule())

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, compact ? MeetsTheme.spacing12 : MeetsTheme.spacing16)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isHoveringDisclosure ? MeetsTheme.backgroundHover : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringDisclosure = $0 }
            .help(disclosureHelp)
            .accessibilityLabel("Follow-ups")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows the follow-up meetings for this meeting")
        }
    }

    private var disclosureHelp: String {
        let followUps = "\(descendantCount) follow-up meeting\(descendantCount == 1 ? "" : "s")"
        return isExpanded ? "Collapse this follow-up thread" : "Show the \(followUps) in this thread"
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
        .padding(.vertical, 7)
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

/// Every follow-up of one shelf, in thread order, inside an inset panel under
/// the root card's disclosure.
///
/// The panel is filled with the base background, so the thread reads as a
/// recess in the raised card rather than a second card stacked under it. Rows
/// keep the rest of the browser's rhythm — hairline dividers, the same metadata
/// line, the same one actions menu — so a follow-up looks like the meeting it
/// is, just nested.
struct MeetingFollowUpListView: View {
    let shelf: MeetingBrowserShelf
    let selectedMeetingID: Int64?
    let folders: [MeetingFolder]
    let folderBreadcrumbs: [Int64: String]
    let actions: MeetingShelfActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shelf.descendants.enumerated()), id: \.element.id) { index, node in
                if index > 0 {
                    Divider()
                        .foregroundStyle(MeetsTheme.surfaceBorder)
                }

                MeetingThreadRow(
                    node: node,
                    isSelected: node.id == selectedMeetingID,
                    folders: folders,
                    folderBreadcrumbs: folderBreadcrumbs,
                    actions: actions
                )
            }
        }
        .padding(MeetsTheme.spacing8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MeetsTheme.backgroundBase)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium)
                .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
        )
        .padding(.horizontal, MeetsTheme.spacing12)
        .padding(.bottom, MeetsTheme.spacing12)
        .transition(.opacity.combined(with: .move(edge: .top)))
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
