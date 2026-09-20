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
            paths[folder.id] = parts.joined(separator: MeetingFolderBreadcrumbs.separator)
        }
        return paths
    }

    static let separator = " / "

    /// The last component of a breadcrumb path built by `paths(for:)`.
    static func leafName(of path: String) -> String {
        path.components(separatedBy: separator).last ?? path
    }
}

/// One meeting rendered as a row: the parent of a follow-up family, or a
/// meeting with no follow-ups, which is a family of one.
///
/// The shelf owns the card chrome — fill, corner, border — so this view draws
/// content only and fills its own row box. Hover is the row's only transient
/// state, which is why a standalone meeting and a family parent look like the
/// same kind of object.
struct MeetingListItemView: View {
    let display: MeetingListItemDisplay
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
    /// True when the card is too narrow for generous padding and two preview
    /// lines: the row tightens its inset and shows one.
    let compact: Bool
    let canStartFollowUp: Bool
    let canDelete: Bool
    let onSelect: () -> Void
    let onMove: (Int64?) -> Void
    let onCreateFolderAndMove: (String) -> Void
    let onDelete: () -> Void
    let onStartFollowUp: () -> Void
    let onOpenParent: ((Int64) -> Void)?
    @State private var isHovering = false

    private var currentFolderName: String? {
        guard let folderID = display.folderID else { return nil }
        return folderBreadcrumbs[folderID]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? MeetsTheme.spacing4 : 6) {
            HStack(alignment: .top, spacing: MeetsTheme.spacing8) {
                openButton
                actionMenu
            }

            parentLinkButton

            metaLine

            contextLine

            previewLine
        }
        .padding(.horizontal, compact ? MeetsTheme.spacing12 : MeetsTheme.spacing16)
        .padding(.vertical, compact ? MeetsTheme.spacing12 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    /// A prominent title that keeps the row to itself, with the whole family's
    /// actions folded into one menu beside it.
    private var openButton: some View {
        Button(action: onSelect) {
            Text(display.title)
                .font(MeetsTheme.title3())
                .foregroundStyle(MeetsTheme.textPrimary)
                .lineLimit(compact ? 1 : 2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(display.title)")
        .accessibilityLabel(display.title)
        .accessibilityHint("Opens the meeting")
    }

    private var actionMenu: some View {
        MeetingRowActionMenu(
            meetingTitle: display.title,
            folders: folders,
            breadcrumbs: folderBreadcrumbs,
            currentFolderID: display.folderID,
            isHovering: isHovering,
            canStartFollowUp: canStartFollowUp,
            canDelete: canDelete,
            onStartFollowUp: onStartFollowUp,
            onMove: onMove,
            onCreateFolderAndMove: onCreateFolderAndMove,
            onDelete: onDelete
        )
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

    /// Date, duration, and status. A narrow card stacks the source badge under
    /// the rest instead of squeezing the line into a stub.
    @ViewBuilder
    private var metaLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MeetsTheme.spacing8) {
                statusElement
                rangeChip
                metaText
                sourceElement
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
                HStack(spacing: MeetsTheme.spacing8) {
                    statusElement
                    rangeChip
                    metaText
                    Spacer(minLength: 0)
                }
                sourceElement
            }
        }
    }

    @ViewBuilder
    private var contextLine: some View {
        if followUpCount > 0 || hasFollowUps || currentFolderName != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: MeetsTheme.spacing12) {
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
    }

    @ViewBuilder
    private var previewLine: some View {
        if let previewText = display.previewText {
            Text(previewText)
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textSecondary)
                .lineLimit(compact ? 1 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        Text(MeetingListItemFormat.meta(
            startTime: display.startTime,
            durationSeconds: display.durationSeconds
        ))
        .font(MeetsTheme.caption())
        .foregroundStyle(MeetsTheme.textSecondary)
        .lineLimit(1)
        .help(MeetingBrowserLogic.formatStartTime(display.startTime))
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
            meetingChip(
                icon: "arrow.triangle.branch",
                label: "\(followUpCount) follow-up\(followUpCount == 1 ? "" : "s")"
            )
            .accessibilityLabel("\(followUpCount) follow-up meeting\(followUpCount == 1 ? "" : "s")")
        } else if hasFollowUps {
            meetingChip(icon: "arrow.triangle.branch", label: "Has follow-ups")
                .help("This meeting has follow-ups outside the current folder")
                .accessibilityLabel("This meeting has follow-ups outside the current folder")
        }
    }

    /// Narrow cards show only the leaf folder so a middle-truncated path cannot
    /// read as two folder names fused together; the full path stays in help
    /// and accessibility.
    @ViewBuilder
    private var folderChip: some View {
        if let name = currentFolderName {
            let label = compact ? MeetingFolderBreadcrumbs.leafName(of: name) : name
            meetingChip(icon: "folder", label: label, truncationMode: compact ? .tail : .middle)
                .help(name)
                .accessibilityLabel("Folder: \(name)")
        }
    }

    /// Quiet metadata chip: the icon carries the meaning, the text stays in the
    /// neutral secondary tone so only actions and selection use the accent.
    private func meetingChip(
        icon: String,
        label: String,
        truncationMode: Text.TruncationMode = .tail
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(label)
                .font(MeetsTheme.caption())
                .lineLimit(1)
                .truncationMode(truncationMode)
        }
        .foregroundStyle(MeetsTheme.textSecondary)
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

    private var rowBackground: Color {
        isHovering ? MeetsTheme.backgroundHover : .clear
    }
}

// MARK: - Shared row pieces

enum MeetingListItemFormat {
    /// Compact duration for list rows: "42m", "1h 5m", "2h", "<1m". Seconds are
    /// noise once a meeting is a row in a library.
    static func duration(_ seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        if rounded >= 3600 {
            let hours = rounded / 3600
            let minutes = (rounded % 3600) / 60
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        if rounded >= 60 {
            return "\(rounded / 60)m"
        }
        return "<1m"
    }

    /// The one metadata line every browser row shows: when the meeting ran and
    /// how long. The full timestamp stays in help text and accessibility.
    static func meta(startTime: String, durationSeconds: Double) -> String {
        "\(MeetingBrowserLogic.formatListDate(startTime)) \u{00B7} \(duration(durationSeconds))"
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

/// The one actions control a meeting row carries: follow-up, folder move, and
/// delete, each with the confirmation and create-folder flow the separate icon
/// buttons used to hold. A sibling of the open button, never nested inside it,
/// so both stay reachable from the keyboard.
struct MeetingRowActionMenu: View {
    let meetingTitle: String
    let folders: [MeetingFolder]
    let breadcrumbs: [Int64: String]
    let currentFolderID: Int64?
    let isHovering: Bool
    /// False while a recording is being prepared or is running, or when the
    /// meeting's own status cannot start one: the item stays visible so the
    /// action is discoverable, and reads as disabled.
    let canStartFollowUp: Bool
    let canDelete: Bool
    let onStartFollowUp: () -> Void
    let onMove: (Int64?) -> Void
    let onCreateFolderAndMove: (String) -> Void
    let onDelete: () -> Void
    @State private var showDeleteConfirmation = false
    @State private var showNewFolderPrompt = false
    @State private var newFolderName = ""

    private var folderIDsWithChildren: Set<Int64> {
        Set(folders.compactMap(\.parentID))
    }

    var body: some View {
        HStack(spacing: 0) {
            menu
        }
        .alert("Delete Meeting", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this meeting? Saved notes, transcript, and any retained recording will be removed.")
        }
    }

    private var menu: some View {
        Menu {
            Button {
                onStartFollowUp()
            } label: {
                Label("Start Follow-up", systemImage: "arrow.turn.down.right")
            }
            .disabled(!canStartFollowUp)

            Divider()

            Menu("Move to Folder") {
                Button {
                    onMove(nil)
                } label: {
                    folderItem("Unfiled", systemImage: "tray", isActive: currentFolderID == nil)
                }

                if !folders.isEmpty {
                    Divider()
                }

                ForEach(folders) { folder in
                    Button {
                        onMove(folder.id)
                    } label: {
                        folderItem(
                            breadcrumbs[folder.id] ?? folder.name,
                            systemImage: folderIDsWithChildren.contains(folder.id) ? "folder.fill" : "folder",
                            isActive: currentFolderID == folder.id
                        )
                    }
                }

                Divider()

                Button {
                    newFolderName = ""
                    showNewFolderPrompt = true
                } label: {
                    Label("New Folder\u{2026}", systemImage: "folder.badge.plus")
                }
            }

            Divider()

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete Meeting", systemImage: "trash")
            }
            .disabled(!canDelete)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovering ? MeetsTheme.textPrimary : MeetsTheme.textSecondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Meeting actions")
        .accessibilityLabel("Actions for \(meetingTitle)")
        .alert("New Folder", isPresented: $showNewFolderPrompt) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    onCreateFolderAndMove(trimmed)
                }
            }
            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create a new folder and move this meeting into it.")
        }
    }

    /// Checkmark in place of the folder glyph for the folder the meeting is
    /// already in, matching how macOS marks a menu's current choice.
    private func folderItem(_ label: String, systemImage: String, isActive: Bool) -> some View {
        Label {
            Text(label)
        } icon: {
            Image(systemName: isActive ? "checkmark" : systemImage)
        }
    }
}
