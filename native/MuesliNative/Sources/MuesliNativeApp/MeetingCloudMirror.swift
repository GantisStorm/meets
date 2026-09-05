import Foundation
import MuesliCore

/// A meeting mirrored into a cloud-sync folder, as recorded in the folder's
/// `library.json` index. Upserted by meeting id on every mirror so re-runs and
/// "Sync Now" passes converge on one entry per meeting.
struct CloudMirrorIndexEntry: Codable, Equatable {
    var id: Int64
    var title: String
    var startTime: String
    var durationSeconds: Double
    var wordCount: Int
    var status: String
    var noteFile: String?
    var audioFile: String?
    var folderID: Int64?
    var calendarEventID: String?
}

/// Mirrors completed meetings into a folder the user's cloud app already syncs
/// (`<cloud location>/Meets`). Zero-device: no accounts, API keys, or sync
/// engine — the cloud provider's own client moves the files. All writes are
/// incremental and idempotent: note/audio writes skip when the destination
/// already exists with the same deterministic name, and the index upserts by
/// meeting id.
final class MeetingCloudMirror {
    struct MirrorResult {
        var mirrored: [URL] = []
        var skippedNote: Bool = false
        var skippedAudio: Bool = false
        var indexEntryAdded: Bool = false
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// The configured mirror folder path trimmed and validated as an absolute
    /// path; nil when unset or relative (mirroring is then disabled).
    private static func normalizedFolderPath(from config: AppConfig) -> String? {
        let trimmed = config.cloudSyncFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, NSString(string: trimmed).isAbsolutePath else { return nil }
        return trimmed
    }

    /// True when cloud mirroring is switched on and a destination folder path
    /// is configured. The path itself is not probed here — probing happens per
    /// mirror so transient provider state (paused sync, offline) cannot
    /// silently toggle the feature.
    func isCloudSyncConfigured(_ config: AppConfig) -> Bool {
        config.cloudSyncEnabled && Self.normalizedFolderPath(from: config) != nil
    }

    /// Mirrors one meeting into the configured folder. Returns which artifacts
    /// were written and which were skipped as already-present. Note-only
    /// meetings (no saved recording) mirror the note plus an index entry.
    @discardableResult
    func mirror(meeting: MeetingRecord, config: AppConfig) async -> MirrorResult {
        var result = MirrorResult()
        guard config.cloudSyncEnabled,
              let folderPath = Self.normalizedFolderPath(from: config) else { return result }

        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        do {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            return result
        }

        let noteName = Self.noteFilename(for: meeting, config: config)
        let noteURL = folderURL.appendingPathComponent(noteName)

        // Note file — deterministic name, so an existing file with the same
        // name is the same meeting/date and is skipped (never clobbers user
        // edits in the cloud folder).
        if fileManager.fileExists(atPath: noteURL.path) {
            result.skippedNote = true
            result.mirrored.append(noteURL)
        } else {
            do {
                let markdown = MeetingExporter.buildMarkdown(
                    meeting: meeting,
                    content: Self.cloudContent(for: config)
                )
                try markdown.write(to: noteURL, atomically: true, encoding: .utf8)
                result.mirrored.append(noteURL)
            } catch {
                return result
            }
        }

        // Audio copy — optional; skipped silently when the meeting has no
        // recording or the source file is gone (note-only meetings). The
        // destination name is deterministic given the source extension, so a
        // second pass for the same meeting never duplicates the copy.
        var audioName: String?
        if config.cloudSyncIncludesAudio,
           let audioSource = meeting.savedRecordingPath,
           fileManager.fileExists(atPath: audioSource) {
            let sourceURL = URL(fileURLWithPath: audioSource)
            let extensionName = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
            let name = Self.audioFilename(for: meeting, extensionName: extensionName)
            let audioURL = folderURL.appendingPathComponent(name)
            if fileManager.fileExists(atPath: audioURL.path) {
                result.skippedAudio = true
                result.mirrored.append(audioURL)
            } else {
                do {
                    try fileManager.copyItem(at: sourceURL, to: audioURL)
                    result.mirrored.append(audioURL)
                } catch {
                    return result
                }
            }
            audioName = name
        }

        // Index — read-merge-write, atomic; always happens so the index
        // reflects the latest state even when every artifact was skipped.
        let entry = CloudMirrorIndexEntry(
            id: meeting.id,
            title: meeting.title,
            startTime: meeting.startTime,
            durationSeconds: meeting.durationSeconds,
            wordCount: meeting.wordCount,
            status: meeting.status.rawValue,
            noteFile: noteName,
            audioFile: audioName,
            folderID: meeting.folderID,
            calendarEventID: meeting.calendarEventID
        )
        let indexURL = folderURL.appendingPathComponent(Self.indexFilename)
        do {
            result.indexEntryAdded = try updateIndex(at: indexURL, with: entry)
        } catch {
            // Index failure is non-fatal: artifacts are already on disk and the
            // cloud sync client will move them regardless.
            fputs("[meets-cloud-mirror] index update failed: \(error)\n", stderr)
        }
        return result
    }

    /// Mirrors every stored meeting (most recent first) into the configured
    /// folder. Runs serially so deterministic filenames stay collision-free;
    /// returns the count of meetings whose mirror completed.
    func mirrorAllMeetings(meetings: [MeetingRecord], config: AppConfig) async -> Int {
        guard isCloudSyncConfigured(config), !meetings.isEmpty else { return 0 }
        var mirroredCount = 0
        for meeting in meetings {
            let result = await mirror(meeting: meeting, config: config)
            if !result.mirrored.isEmpty {
                mirroredCount += 1
            }
        }
        return mirroredCount
    }

    // MARK: - Index

    private static let indexFilename = "library.json"

    /// Loads the existing index (missing/corrupt → empty), replaces or appends
    /// the entry for `id`, and writes the result atomically.
    private func updateIndex(
        at indexURL: URL,
        with entry: CloudMirrorIndexEntry
    ) throws -> Bool {
        var entries: [CloudMirrorIndexEntry]
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([CloudMirrorIndexEntry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        entries.sort { $0.id > $1.id }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: indexURL, options: .atomic)
        return true
    }

    // MARK: - Filenames

    /// Deterministic note name following the auto-export convention:
    /// `yyyy-MM-dd-<title slug>-notes.md` (notes content) or
    /// `yyyy-MM-dd-<title slug>.md` (full-meeting content). The date is the
    /// meeting's local start date, so re-mirroring the same meeting always
    /// resolves to the same file.
    private static func noteFilename(for meeting: MeetingRecord, config: AppConfig) -> String {
        let slug = Self.titleSlug(meeting.title)
        let date = Self.localDatePrefix(from: meeting.startTime)
        let suffix: String
        switch Self.cloudContent(for: config) {
        case .notes: suffix = "-notes"
        case .transcript: suffix = "-transcript"
        case .fullMeeting: suffix = ""
        }
        return "\(date)-\(slug)\(suffix).md"
    }

    /// Markdown breadth for mirrored notes. Follows the user's existing
    /// auto-export content choice (notes vs. full meeting) so the two features
    /// never produce inconsistent documents, without adding a parallel toggle.
    private static func cloudContent(for config: AppConfig) -> MeetingExportContent {
        config.resolvedAutoExportMarkdownContent
    }

    /// `yyyy-MM-dd <title>.<ext>` — readable title-first name for an audio file
    /// in a user-facing cloud folder (distinct from the note slug convention so
    /// the artifact kinds never collide and sort naturally).
    private static func audioFilename(for meeting: MeetingRecord, extensionName: String) -> String {
        let cleaned = meeting.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: ":")
        let title = cleaned.isEmpty ? "Meeting" : cleaned
        let date = Self.localDatePrefix(from: meeting.startTime)
        return "\(date) \(title).\(extensionName)"
    }

    private static func titleSlug(_ title: String) -> String {
        let sanitized = String(
            title
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: "-")
                .lowercased()
                .prefix(50)
        )
        return sanitized.isEmpty ? "meeting" : sanitized
    }

    /// The meeting's start date rendered in the local time zone as
    /// `yyyy-MM-dd`, matching MeetingMarkdownAutoExporter's prefix so both
    /// engines date the same meeting identically.
    private static func localDatePrefix(from startTime: String) -> String {
        guard let date = MeetingBrowserLogic.parseDate(startTime) else {
            return "unknown-date"
        }
        return Self.fileDateFormatter.string(from: date)
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
