import SwiftUI
import MeetsCore

/// Folder id → "Grandparent / Parent / Folder". Computed once per render so
/// menus never walk the folder tree per row.
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
                .foregroundStyle(isHovering ? MeetsTheme.textPrimary : MeetsTheme.textTertiary)
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
