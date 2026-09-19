import SwiftUI
import MeetsCore

/// Resolved display data for one meeting card.
///
/// Built either from a full `MeetingRecord` — meetings inside the recently
/// loaded window — or from the lightweight `MeetingBrowserEntry` that covers
/// the whole library. The entry path has no notes or transcript, so
/// `previewText` stays nil rather than showing invented content.
struct MeetingListItemDisplay {
    let id: Int64
    let title: String
    let startTime: String
    let durationSeconds: Double
    let status: MeetingStatus
    let folderID: Int64?
    let source: MeetingSource
    let savedRecordingPath: String?
    let previewText: String?

    init(entry: MeetingBrowserEntry, previewText: String? = nil) {
        self.id = entry.id
        self.title = entry.title
        self.startTime = entry.startTime
        self.durationSeconds = entry.durationSeconds
        self.status = entry.status
        self.folderID = entry.folderID
        self.source = entry.source
        self.savedRecordingPath = entry.savedRecordingPath
        self.previewText = previewText
    }

    init(record: MeetingRecord) {
        self.init(
            entry: MeetingBrowserEntry(record: record),
            previewText: Self.resolvedPreviewText(for: record)
        )
    }

    /// Display for a browser node: full detail when the record is loaded,
    /// otherwise the browse entry alone.
    init(entry: MeetingBrowserEntry, record: MeetingRecord?) {
        if let record {
            self.init(record: record)
        } else {
            self.init(entry: entry)
        }
    }

    var isImportedAudio: Bool {
        source == .audioImport || hasLegacyImportedRecordingPath
    }

    var hasSavedRecording: Bool {
        guard let savedRecordingPath else { return false }
        return !savedRecordingPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasLegacyImportedRecordingPath: Bool {
        guard let savedRecordingPath else { return false }
        let filename = URL(fileURLWithPath: savedRecordingPath).lastPathComponent
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}_.+_[0-9A-Fa-f]{8}\.wav$"#
        return filename.range(of: pattern, options: .regularExpression) != nil
    }

    private static func resolvedPreviewText(for record: MeetingRecord) -> String {
        let source: String
        if !record.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           record.status != .completed {
            source = record.manualNotes
        } else {
            source = record.formattedNotes.isEmpty ? record.rawTranscript : record.formattedNotes
        }
        return MeetingPreviewText.snippet(from: source)
    }
}

/// Folder id → "Grandparent / Parent / Folder". Computed once per render so
/// cards and rows never walk the folder tree per row.
enum MeetingFolderBreadcrumbs {
    static func paths(for folders: [MeetingFolder]) -> [Int64: String] {
        let foldersByID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var paths: [Int64: String] = [:]
        paths.reserveCapacity(folders.count)
        for folder in folders {
            var parts: [String] = [folder.name]
            var seen: Set<Int64> = [folder.id]
            var current = folder.parentID
            while let id = current, let parent = foldersByID[id], seen.insert(id).inserted {
                parts.insert(parent.name, at: 0)
                current = parent.parentID
            }
            paths[folder.id] = parts.joined(separator: " / ")
        }
        return paths
    }
}

/// One meeting rendered as a card: the shelf root, or a standalone meeting.
///
/// Opens through a real button so the card is reachable from the keyboard;
/// move, follow-up, and delete stay sibling controls instead of nesting inside
/// that button.
struct MeetingListItemView: View {
    let display: MeetingListItemDisplay
    let isSelected: Bool
    let hasFollowUps: Bool
    /// Rendered follow-ups in this shelf; shown as a count chip when non-zero.
    let followUpCount: Int
    let folders: [MeetingFolder]
    let folderBreadcrumbs: [Int64: String]
    /// Predecessor outside this shelf; rendered as a link that opens it.
    let externalParent: MeetingBrowserParentLink?
    /// True when the card is shown only to keep a matching descendant's
    /// thread context.
    let isOutsideRange: Bool
    /// True when the card is too narrow to keep the title and the action
    /// cluster on one row: the title takes the full width and the actions move
    /// beneath it, so the title stays legible instead of truncating to a stub.
    let compactHeader: Bool
    let onSelect: () -> Void
    let onMove: (Int64?) -> Void
    let onCreateFolderAndMove: ((String) -> Void)?
    let onDelete: (() -> Void)?
    let onStartFollowUp: (() -> Void)?
    let onOpenParent: ((Int64) -> Void)?
    @State private var isHovering = false

    init(
        display: MeetingListItemDisplay,
        isSelected: Bool,
        hasFollowUps: Bool,
        followUpCount: Int = 0,
        folders: [MeetingFolder],
        folderBreadcrumbs: [Int64: String] = [:],
        externalParent: MeetingBrowserParentLink? = nil,
        isOutsideRange: Bool = false,
        compactHeader: Bool = false,
        onSelect: @escaping () -> Void,
        onMove: @escaping (Int64?) -> Void,
        onCreateFolderAndMove: ((String) -> Void)?,
        onDelete: (() -> Void)?,
        onStartFollowUp: (() -> Void)? = nil,
        onOpenParent: ((Int64) -> Void)? = nil
    ) {
        self.display = display
        self.isSelected = isSelected
        self.hasFollowUps = hasFollowUps
        self.followUpCount = followUpCount
        self.folders = folders
        self.folderBreadcrumbs = folderBreadcrumbs
        self.externalParent = externalParent
        self.isOutsideRange = isOutsideRange
        self.compactHeader = compactHeader
        self.onSelect = onSelect
        self.onMove = onMove
        self.onCreateFolderAndMove = onCreateFolderAndMove
        self.onDelete = onDelete
        self.onStartFollowUp = onStartFollowUp
        self.onOpenParent = onOpenParent
    }

    private var currentFolderName: String? {
        guard let folderID = display.folderID else { return nil }
        return folderBreadcrumbs[folderID]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
            headerRow

            parentLinkButton

            detailBlock
        }
        .padding(compactHeader ? MeetsTheme.spacing12 : MeetsTheme.spacing16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? MeetsTheme.surfaceSelected : MeetsTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerLarge))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerLarge)
                .strokeBorder(
                    isSelected ? MeetsTheme.accent.opacity(0.35) : MeetsTheme.surfaceBorder,
                    lineWidth: 1
                )
        )
        .onHover { isHovering = $0 }
    }

    /// Title and actions share a row while the card can hold both; a narrow card
    /// gives the title the full width and moves the actions underneath it.
    @ViewBuilder
    private var headerRow: some View {
        if compactHeader {
            VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
                openButton
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    actionCluster
                }
            }
        } else {
            HStack(alignment: .top, spacing: MeetsTheme.spacing8) {
                openButton
                Spacer(minLength: 0)
                actionCluster
            }
        }
    }

    private var actionCluster: some View {
        HStack(spacing: 6) {
            MeetingFolderMoveControl(
                folders: folders,
                breadcrumbs: folderBreadcrumbs,
                currentFolderID: display.folderID,
                isHovering: isHovering,
                onMove: onMove,
                onCreateFolderAndMove: onCreateFolderAndMove
            )
            if let onStartFollowUp {
                MeetingFollowUpControl(isHovering: isHovering, onStart: onStartFollowUp)
            }
            if let onDelete {
                MeetingDeleteControl(isHovering: isHovering, onDelete: onDelete)
            }
        }
    }

    /// Link to a predecessor that is not part of this shelf — the folder-scope
    /// case, where the parent lives outside the current scope. A sibling of the
    /// open button rather than part of it, so both stay separately focusable.
    @ViewBuilder
    private var parentLinkButton: some View {
        if let externalParent {
            Button {
                onOpenParent?(externalParent.id)
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
            .allowsHitTesting(onOpenParent != nil)
            .help("Open \(externalParent.title)")
            .accessibilityLabel("Open parent meeting \(externalParent.title)")
        }
    }

    private var openButton: some View {
        Button(action: onSelect) {
            Text(display.title)
                .font(MeetsTheme.headline())
                .foregroundStyle(MeetsTheme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(display.title)")
        .accessibilityLabel("Open \(display.title)")
    }

    /// Metadata and preview keep the full card width, so the action icons never
    /// crowd them. Each line falls back to a stacked variant when a narrow grid
    /// column cannot hold it.
    private var detailBlock: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: MeetsTheme.spacing4) {
                    statusElement
                    rangeChip
                    if display.status != .completed && hasSourceBadge {
                        separatorDot
                    }
                    metaText
                    if hasSourceBadge {
                        separatorDot
                        sourceElement
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
                    HStack(spacing: MeetsTheme.spacing4) {
                        statusElement
                        rangeChip
                        metaText
                        Spacer(minLength: 0)
                    }
                    sourceElement
                }
            }

            if followUpCount > 0 || hasFollowUps || currentFolderName != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: MeetsTheme.spacing8) {
                        followUpChip
                        folderChip
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
                        followUpChip
                        folderChip
                    }
                }
            }

            if let previewText = display.previewText {
                Text(previewText)
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var separatorDot: some View {
        Text("\u{2022}")
            .font(MeetsTheme.caption())
            .foregroundStyle(MeetsTheme.textTertiary)
    }

    @ViewBuilder
    private var statusElement: some View {
        if display.status != .completed {
            MeetingStatusBadge(status: display.status)
        }
    }

    /// Marks a card kept only because a matching descendant needs its thread
    /// context.
    @ViewBuilder
    private var rangeChip: some View {
        if isOutsideRange {
            MeetingOutsideRangeChip()
        }
    }

    private var metaText: some View {
        Text(formatMeta())
            .font(MeetsTheme.caption())
            .foregroundStyle(MeetsTheme.textSecondary)
            .lineLimit(1)
    }

    private var hasSourceBadge: Bool {
        display.isImportedAudio || display.hasSavedRecording
    }

    @ViewBuilder
    private var sourceElement: some View {
        if display.isImportedAudio {
            sourceBadge(icon: "square.and.arrow.down", label: "Imported", help: "Imported audio")
        } else if display.hasSavedRecording {
            sourceBadge(icon: "waveform", label: "Recording", help: "Saved recording available")
        }
    }

    @ViewBuilder
    private var followUpChip: some View {
        if followUpCount > 0 {
            HStack(spacing: 2) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                Text("\(followUpCount) follow-up\(followUpCount == 1 ? "" : "s")")
                    .font(MeetsTheme.caption())
            }
            .foregroundStyle(MeetsTheme.accent.opacity(0.8))
            .accessibilityLabel("\(followUpCount) follow-up meeting\(followUpCount == 1 ? "" : "s")")
        } else if hasFollowUps {
            HStack(spacing: 2) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                Text("Has follow-ups")
                    .font(MeetsTheme.caption())
            }
            .foregroundStyle(MeetsTheme.accent.opacity(0.8))
            .help("This meeting has follow-ups outside the current folder")
            .accessibilityLabel("This meeting has follow-ups outside the current folder")
        }
    }

    @ViewBuilder
    private var folderChip: some View {
        if let name = currentFolderName {
            HStack(spacing: 2) {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                Text(name)
                    .font(MeetsTheme.caption())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(MeetsTheme.accent.opacity(0.8))
            .help(name)
            .accessibilityLabel("Folder: \(name)")
        }
    }

    private func sourceBadge(icon: String, label: String, help: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(display.isImportedAudio ? MeetsTheme.accent : MeetsTheme.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background((display.isImportedAudio ? MeetsTheme.accent : MeetsTheme.textSecondary).opacity(0.12))
        .clipShape(Capsule())
        .help(help)
        .accessibilityLabel(help)
    }

    private func formatMeta() -> String {
        let time = MeetingBrowserLogic.formatStartTime(display.startTime)
        let duration = MeetingListItemFormat.duration(display.durationSeconds)
        return "\(time)  \u{2022}  \(duration)"
    }
}

// MARK: - Shared row pieces

enum MeetingListItemFormat {
    static func duration(_ seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        if rounded >= 3600 {
            return "\(rounded / 3600)h \((rounded % 3600) / 60)m"
        }
        if rounded >= 60 {
            let m = rounded / 60
            let s = rounded % 60
            return s == 0 ? "\(m)m" : "\(m)m \(s)s"
        }
        return "\(rounded)s"
    }
}

struct MeetingStatusBadge: View {
    let status: MeetingStatus

    var body: some View {
        Text(status.displayLabel)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(status.displayColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(status.displayColor.opacity(0.12))
            .clipShape(Capsule())
            .accessibilityLabel("Status: \(status.displayLabel)")
    }
}

/// Marks a meeting kept in view only because a matching descendant needs its
/// thread context.
struct MeetingOutsideRangeChip: View {
    var body: some View {
        Text("Outside range")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(MeetsTheme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(MeetsTheme.textSecondary.opacity(0.12))
            .clipShape(Capsule())
            .help("Kept so this follow-up thread stays intact. This meeting is outside the active date range.")
            .accessibilityLabel("Outside the active date range")
    }
}

/// Folder picker shared by every browser row: unfiled, every folder with its
/// breadcrumb, and an inline "New Folder…" that moves this meeting into it.
struct MeetingFolderMoveControl: View {
    let folders: [MeetingFolder]
    let breadcrumbs: [Int64: String]
    let currentFolderID: Int64?
    let isHovering: Bool
    let onMove: (Int64?) -> Void
    let onCreateFolderAndMove: ((String) -> Void)?
    @State private var showFolderPopover = false
    @State private var showNewFolderPrompt = false
    @State private var newFolderName = ""

    private var folderIDsWithChildren: Set<Int64> {
        Set(folders.compactMap(\.parentID))
    }

    var body: some View {
        Button {
            showFolderPopover.toggle()
        } label: {
            Image(systemName: currentFolderID != nil ? "folder.fill" : "folder.badge.plus")
                .font(.system(size: 11))
                .foregroundStyle(
                    currentFolderID != nil
                        ? MeetsTheme.accent
                        : (isHovering ? MeetsTheme.textSecondary : MeetsTheme.textTertiary)
                )
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Move to folder")
        .accessibilityLabel("Move to folder")
        .popover(isPresented: $showFolderPopover, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                folderPopoverRow(icon: "tray", label: "Unfiled", isActive: currentFolderID == nil) {
                    onMove(nil)
                    showFolderPopover = false
                }
                if !folders.isEmpty {
                    Divider().padding(.vertical, 4)
                    folderList
                }
                if onCreateFolderAndMove != nil {
                    Divider().padding(.vertical, 4)
                    folderPopoverRow(icon: "folder.badge.plus", label: "New Folder...") {
                        showFolderPopover = false
                        newFolderName = ""
                        showNewFolderPrompt = true
                    }
                }
            }
            .padding(8)
        }
        .alert("New Folder", isPresented: $showNewFolderPrompt) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    onCreateFolderAndMove?(trimmed)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create a new folder and move this meeting into it.")
        }
    }

    /// Folder rows, height-capped so a deep folder tree scrolls inside the
    /// popover instead of running past the screen edge.
    @ViewBuilder
    private var folderList: some View {
        if folders.count > 8 {
            ScrollView {
                folderRows
            }
            .frame(width: 240, height: 260)
        } else {
            folderRows
        }
    }

    private var folderRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(folders) { folder in
                folderPopoverRow(
                    icon: folderIDsWithChildren.contains(folder.id) ? "folder.fill" : "folder",
                    label: breadcrumbs[folder.id] ?? folder.name,
                    isActive: currentFolderID == folder.id
                ) {
                    onMove(folder.id)
                    showFolderPopover = false
                }
            }
        }
    }

    @ViewBuilder
    private func folderPopoverRow(icon: String, label: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 16)
                Text(label)
                    .font(MeetsTheme.callout())
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MeetsTheme.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Starts a new meeting linked into this meeting's follow-up thread.
struct MeetingFollowUpControl: View {
    let isHovering: Bool
    let onStart: () -> Void

    var body: some View {
        Button(action: onStart) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11))
                .foregroundStyle(isHovering ? MeetsTheme.accent : MeetsTheme.textTertiary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Start a follow-up meeting")
        .accessibilityLabel("Start a follow-up meeting")
    }
}

/// Delete control with its confirmation, shared by cards and shelf rows.
struct MeetingDeleteControl: View {
    let isHovering: Bool
    let onDelete: () -> Void
    @State private var showDeleteConfirmation = false
    /// Keeps the control visible while it holds keyboard focus, so it never
    /// disappears out from under the focus ring.
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            showDeleteConfirmation = true
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundStyle(
                    isHovering || isFocused
                        ? MeetsTheme.recording.opacity(0.85)
                        : MeetsTheme.textTertiary
                )
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .opacity(isHovering || isFocused ? 1 : 0)
        .help("Delete meeting")
        .accessibilityLabel("Delete meeting")
        .alert("Delete Meeting", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this meeting? Saved notes, transcript, and any retained recording will be removed.")
        }
    }
}
