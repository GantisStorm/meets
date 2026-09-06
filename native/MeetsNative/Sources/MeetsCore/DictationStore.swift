import Foundation
import SQLite3

public enum DictationStoreError: Error, LocalizedError {
    case meetingNotFound(id: Int64)
    case invalidParticipantIdentifier

    public var errorDescription: String? {
        switch self {
        case .meetingNotFound(let id):
            return "Meeting \(id) no longer exists."
        case .invalidParticipantIdentifier:
            return "That meeting participant could not be identified."
        }
    }
}

public struct MeetingThreadNavigation: Equatable, Sendable {
    public let predecessorID: Int64?
    public let successorIDs: [Int64]
    public let count: Int
}

public final class DictationStore {
    private static let iso8601Formatter = ISO8601DateFormatter()
    private static let iso8601FormatterLock = NSLock()

    public static func countWords(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.split(whereSeparator: \.isWhitespace).count
    }

    private let databaseURL: URL

    /// Thread-confined (MainActor) one-shot overrides of the per-meeting
    /// include-notes-in-summary preference, written by the UI setter while a
    /// meeting stop is in flight. `completeLiveMeeting` consumes and clears
    /// them so a persisted toggle during the stop survives the row update.
    private static let meetingColumns = """
    id, title, start_time, duration_seconds, raw_transcript, formatted_notes, word_count, folder_id, calendar_event_id, mic_audio_path, system_audio_path, saved_recording_path, meeting_status, manual_notes, selected_template_id, selected_template_name, selected_template_kind, selected_template_prompt, source, follow_up_to_id, calendar_occurrence_key, calendar_source, calendar_id, calendar_series_id, calendar_occurrence_start, visual_context, include_notes_in_summary
    """

    public init() {
        self.databaseURL = MeetsPaths.defaultDatabaseURL()
    }

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public var resolvedDatabaseURL: URL {
        databaseURL
    }

    public var databaseExists: Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
    }

    public func migrateIfNeeded() throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let createSQL = """
        CREATE TABLE IF NOT EXISTS meetings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            calendar_event_id TEXT,
            calendar_occurrence_key TEXT,
            calendar_source TEXT,
            calendar_id TEXT,
            calendar_series_id TEXT,
            calendar_occurrence_start REAL,
            start_time TEXT NOT NULL,
            end_time TEXT,
            duration_seconds REAL,
            raw_transcript TEXT,
            formatted_notes TEXT,
            mic_audio_path TEXT,
            system_audio_path TEXT,
            saved_recording_path TEXT,
            meeting_status TEXT NOT NULL DEFAULT 'completed',
            manual_notes TEXT NOT NULL DEFAULT '',
            word_count INTEGER NOT NULL DEFAULT 0,
            selected_template_id TEXT,
            selected_template_name TEXT,
            selected_template_kind TEXT,
            selected_template_prompt TEXT,
            source TEXT NOT NULL DEFAULT 'meeting',
            updated_at REAL NOT NULL DEFAULT 0,
            follow_up_to_id INTEGER REFERENCES meetings(id) ON DELETE SET NULL,
            visual_context TEXT,
            include_notes_in_summary INTEGER NOT NULL DEFAULT 0,
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_meetings_start_time ON meetings(start_time DESC);
        CREATE INDEX IF NOT EXISTS idx_meetings_calendar_event_lookup ON meetings(calendar_event_id) WHERE calendar_event_id IS NOT NULL;

        -- Calendar attendee snapshots and manually selected people are device-local.
        CREATE TABLE IF NOT EXISTS meeting_participants (
            meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            participant_identifier TEXT NOT NULL,
            display_name TEXT NOT NULL,
            email_address TEXT,
            insertion_order INTEGER NOT NULL,
            source TEXT NOT NULL DEFAULT 'manual',
            is_suppressed INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (meeting_id, participant_identifier)
        );
        CREATE INDEX IF NOT EXISTS idx_meeting_participants_order
            ON meeting_participants(meeting_id, insertion_order);

        -- Explicit "Add to Event" attachments: a meeting can be tied to one
        -- or more calendar events, in addition to its primary
        -- calendar_event_id column. Cascade-deleted with the meeting.
        -- The primary key includes occurrence_key so one meeting can attach
        -- to several instances of a recurring series (each instance is a
        -- separate schedulable item with its own occurrence identity).
        CREATE TABLE IF NOT EXISTS meeting_event_links (
            meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            event_id TEXT NOT NULL,
            calendar_id TEXT,
            occurrence_key TEXT,
            added_at REAL NOT NULL DEFAULT 0,
            PRIMARY KEY (meeting_id, event_id, occurrence_key)
        );
        CREATE INDEX IF NOT EXISTS idx_meeting_event_links_event
            ON meeting_event_links(event_id);

        CREATE TABLE IF NOT EXISTS meeting_transcript_checkpoints (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            timestamp_label TEXT NOT NULL,
            speaker TEXT NOT NULL,
            start_seconds REAL NOT NULL,
            end_seconds REAL NOT NULL,
            text TEXT NOT NULL,
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_meeting_transcript_checkpoints_meeting
            ON meeting_transcript_checkpoints(meeting_id, start_seconds, id);

        CREATE TABLE IF NOT EXISTS meeting_resume_snapshots (
            meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
            raw_transcript TEXT NOT NULL DEFAULT '',
            formatted_notes TEXT,
            duration_seconds REAL NOT NULL DEFAULT 0,
            start_time TEXT NOT NULL,
            end_time TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        );
        """
        try exec(createSQL, db: db)

        let foldersSQL = """
        CREATE TABLE IF NOT EXISTS meeting_folders (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            parent_id INTEGER REFERENCES meeting_folders(id),
            created_at TEXT DEFAULT (datetime('now'))
        );
        """
        try exec(foldersSQL, db: db)

        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN folder_id INTEGER REFERENCES meeting_folders(id)", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        // These template columns are also present in CREATE TABLE for fresh databases.
        // The ALTER TABLE path upgrades pre-existing databases where meetings already exists.
        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN selected_template_id TEXT", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN selected_template_name TEXT", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN selected_template_kind TEXT", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN selected_template_prompt TEXT", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN saved_recording_path TEXT", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN meeting_status TEXT NOT NULL DEFAULT 'completed'", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN manual_notes TEXT NOT NULL DEFAULT ''", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN source TEXT NOT NULL DEFAULT 'meeting'", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN visual_context TEXT", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN include_notes_in_summary INTEGER NOT NULL DEFAULT 0", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        // Clean up legacy pre-meeting tables and sync columns from databases
        // created by earlier Muesli versions.
        for table in ["dictations", "computer_use_traces", "cloud_sync_state", "local_migrations"] {
            _ = sqlite3_exec(db, "DROP TABLE IF EXISTS \(table)", nil, nil, nil)
        }
        for column in ["deleted_at", "cloud_record_name", "cloud_change_tag", "cloud_system_fields",
                       "cloud_transcript_record_name", "last_synced_at", "sync_dirty", "follow_up_to_record_name"] {
            let sql = "ALTER TABLE meetings DROP COLUMN \(column)"
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                // SQLite versions before 3.35 do not support DROP COLUMN; the
                // column simply remains unused in the meeting-only schema.
            }
        }
        // Insights aggregation tables (daily cache, tokens, record cache,
        // llm_usage_log). Previously this helper was never invoked, so fresh
        // databases lacked the insights tables and the Insights page failed
        // with "no such table: insights_cache_meta".
        try migrateInsightsCache(db: db)
        try migrateMeetingEventLinks(db: db)
    }

    /// Widens meeting_event_links to PRIMARY KEY (meeting_id, event_id,
    /// occurrence_key). Pre-existing rows keep working: they copy over
    /// unchanged (legacy rows simply carry a NULL occurrence key).
    private func migrateMeetingEventLinks(db: OpaquePointer?) throws {
        var needsMigration = false
        do {
            let sql = "SELECT sql FROM sqlite_master WHERE name = 'meeting_event_links'"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            if sqlite3_step(statement) == SQLITE_ROW,
               let text = sqlite3_column_text(statement, 0) {
                let ddl = String(cString: text)
                needsMigration = !ddl.contains("PRIMARY KEY (meeting_id, event_id, occurrence_key)")
            }
        }
        guard needsMigration else { return }
        try exec("""
        ALTER TABLE meeting_event_links RENAME TO meeting_event_links_legacy;
        CREATE TABLE meeting_event_links (
            meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            event_id TEXT NOT NULL,
            calendar_id TEXT,
            occurrence_key TEXT,
            added_at REAL NOT NULL DEFAULT 0,
            PRIMARY KEY (meeting_id, event_id, occurrence_key)
        );
        INSERT INTO meeting_event_links
            (meeting_id, event_id, calendar_id, occurrence_key, added_at)
            SELECT meeting_id, event_id, calendar_id, occurrence_key, added_at
            FROM meeting_event_links_legacy
            GROUP BY meeting_id, event_id, occurrence_key;
        DROP TABLE meeting_event_links_legacy;
        CREATE INDEX IF NOT EXISTS idx_meeting_event_links_event
            ON meeting_event_links(event_id);
        """, db: db)
    }

    private func migrateInsightsCache(db: OpaquePointer?) throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS insights_cache_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS insights_tokens (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            token TEXT NOT NULL UNIQUE
        );
        CREATE TABLE IF NOT EXISTS insights_record_cache (
            record_id INTEGER PRIMARY KEY,
            source_updated_at REAL NOT NULL,
            activity_day TEXT NOT NULL,
            word_count INTEGER NOT NULL,
            duration_seconds REAL NOT NULL,
            meeting_words INTEGER NOT NULL,
            meetings INTEGER NOT NULL,
            token_blob BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_insights_record_updated
            ON insights_record_cache(source_updated_at);
        CREATE TABLE IF NOT EXISTS insights_daily_cache (
            day TEXT PRIMARY KEY,
            meeting_words INTEGER NOT NULL DEFAULT 0,
            meetings INTEGER NOT NULL DEFAULT 0,
            duration_seconds REAL NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS insights_token_totals (
            token_id INTEGER PRIMARY KEY REFERENCES insights_tokens(id) ON DELETE CASCADE,
            meeting_count INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS insights_daily_tokens (
            day TEXT NOT NULL,
            token_id INTEGER NOT NULL REFERENCES insights_tokens(id) ON DELETE CASCADE,
            meeting_count INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(day, token_id)
        );
        CREATE INDEX IF NOT EXISTS idx_insights_daily_tokens_token
            ON insights_daily_tokens(token_id, day);

        -- Append-only log of LLM pillar runs (summaries, transcript cleanup,
        -- title generation). Written at call sites; read by Insights.
        CREATE TABLE IF NOT EXISTS llm_usage_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL,
            backend TEXT NOT NULL,
            model TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL,
            retry_count INTEGER NOT NULL DEFAULT 0,
            characters INTEGER NOT NULL DEFAULT 0,
            meeting_id INTEGER,
            created_at REAL NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_llm_usage_created ON llm_usage_log(created_at);
        """, db: db)

        try rebuildLegacyInsightsTablesIfNeeded(db: db)
    }

    /// Reshape pre-existing dictation-era insights tables (which carried
    /// `kind`/`dictation_*` columns and composite keys) into the
    /// meetings-only schema. `CREATE TABLE IF NOT EXISTS` cannot alter an
    /// existing table, so legacy databases keep the old shape and every
    /// insert fails (NOT NULL constraint on the missing-column default).
    /// Meeting data is preserved; dictation columns are dropped (dead in the
    /// meetings-only app).
    private func rebuildLegacyInsightsTablesIfNeeded(db: OpaquePointer?) throws {
        // Detect legacy shape: insights_record_cache has a `kind` column.
        var legacy = false
        var s: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM pragma_table_info('insights_record_cache') WHERE name='kind'", -1, &s, nil) == SQLITE_OK {
            if sqlite3_step(s) == SQLITE_ROW { legacy = sqlite3_column_int(s, 0) > 0 }
            sqlite3_finalize(s)
        }
        guard legacy else { return }
        try withInsightsWriteTransaction(db: db) {
            // 1. insights_record_cache: old PK(kind, record_id) -> new PK(record_id).
            try exec("ALTER TABLE insights_record_cache RENAME TO insights_record_cache_legacy", db: db)
            try exec("""
            CREATE TABLE insights_record_cache (
                record_id INTEGER PRIMARY KEY,
                source_updated_at REAL NOT NULL,
                activity_day TEXT NOT NULL,
                word_count INTEGER NOT NULL,
                duration_seconds REAL NOT NULL,
                meeting_words INTEGER NOT NULL,
                meetings INTEGER NOT NULL,
                token_blob BLOB NOT NULL
            )
            """, db: db)
            try exec("""
            INSERT INTO insights_record_cache
              (record_id, source_updated_at, activity_day, word_count, duration_seconds,
               meeting_words, meetings, token_blob)
            SELECT record_id, source_updated_at, activity_day, word_count, duration_seconds,
                   meeting_words, meetings, token_blob
            FROM insights_record_cache_legacy
            """, db: db)
            try exec("DROP TABLE insights_record_cache_legacy", db: db)
            try exec("CREATE INDEX IF NOT EXISTS idx_insights_record_updated ON insights_record_cache(source_updated_at)", db: db)

            // 2. insights_daily_cache: drop dictation_words/dictation_sessions.
            try exec("ALTER TABLE insights_daily_cache RENAME TO insights_daily_cache_legacy", db: db)
            try exec("""
            CREATE TABLE insights_daily_cache (
                day TEXT PRIMARY KEY,
                meeting_words INTEGER NOT NULL DEFAULT 0,
                meetings INTEGER NOT NULL DEFAULT 0,
                duration_seconds REAL NOT NULL DEFAULT 0
            )
            """, db: db)
            try exec("""
            INSERT INTO insights_daily_cache (day, meeting_words, meetings, duration_seconds)
            SELECT day, meeting_words, meetings, duration_seconds
            FROM insights_daily_cache_legacy
            """, db: db)
            try exec("DROP TABLE insights_daily_cache_legacy", db: db)

            // 3. insights_token_totals + insights_daily_tokens: drop dictation_count.
            try exec("ALTER TABLE insights_token_totals RENAME TO insights_token_totals_legacy", db: db)
            try exec("""
            CREATE TABLE insights_token_totals (
                token_id INTEGER PRIMARY KEY REFERENCES insights_tokens(id) ON DELETE CASCADE,
                meeting_count INTEGER NOT NULL DEFAULT 0
            )
            """, db: db)
            try exec("""
            INSERT INTO insights_token_totals (token_id, meeting_count)
            SELECT token_id, meeting_count FROM insights_token_totals_legacy
            """, db: db)
            try exec("DROP TABLE insights_token_totals_legacy", db: db)

            try exec("ALTER TABLE insights_daily_tokens RENAME TO insights_daily_tokens_legacy", db: db)
            try exec("""
            CREATE TABLE insights_daily_tokens (
                day TEXT NOT NULL,
                token_id INTEGER NOT NULL REFERENCES insights_tokens(id) ON DELETE CASCADE,
                meeting_count INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(day, token_id)
            )
            """, db: db)
            try exec("""
            INSERT INTO insights_daily_tokens (day, token_id, meeting_count)
            SELECT day, token_id, meeting_count FROM insights_daily_tokens_legacy
            """, db: db)
            try exec("DROP TABLE insights_daily_tokens_legacy", db: db)
            try exec("CREATE INDEX IF NOT EXISTS idx_insights_daily_tokens_token ON insights_daily_tokens(token_id, day)", db: db)
        }
        fputs("[meets-store] rebuilt legacy dictation-era insights tables to meetings-only schema\n", stderr)
    }

    public func meetingCounts() throws -> (total: Int, byFolder: [Int64: Int], directByFolder: [Int64: Int]) {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        var total = 0
        var stmt: OpaquePointer?
        let totalSQL = "SELECT COUNT(*) FROM meetings"
        if sqlite3_prepare_v2(db, totalSQL, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { total = Int(sqlite3_column_int(stmt, 0)) }
            sqlite3_finalize(stmt)
        } else {
            fputs("[meets-store] meetingCounts: failed to prepare total count query\n", stderr)
        }

        // Direct counts per folder.
        var directByFolder: [Int64: Int] = [:]
        var stmt2: OpaquePointer?
        let folderSQL = "SELECT folder_id, COUNT(*) FROM meetings WHERE folder_id IS NOT NULL GROUP BY folder_id"
        if sqlite3_prepare_v2(db, folderSQL, -1, &stmt2, nil) == SQLITE_OK {
            while sqlite3_step(stmt2) == SQLITE_ROW {
                directByFolder[sqlite3_column_int64(stmt2, 0)] = Int(sqlite3_column_int(stmt2, 1))
            }
            sqlite3_finalize(stmt2)
        } else {
            fputs("[meets-store] meetingCounts: failed to prepare folder count query\n", stderr)
        }

        // Load the folder tree to compute recursive counts.
        let allFolders = (try? listFoldersInternal(db: db)) ?? []
        var childrenMap: [Int64: [Int64]] = [:]
        for folder in allFolders {
            if let pid = folder.parentID {
                childrenMap[pid, default: []].append(folder.id)
            }
        }

        // Count each folder plus every reachable descendant exactly once.
        var byFolder: [Int64: Int] = [:]
        func recursiveCount(for id: Int64) -> Int {
            var reachable: Set<Int64> = [id]
            var queue: [Int64] = [id]
            while !queue.isEmpty {
                let current = queue.removeFirst()
                for childID in childrenMap[current] ?? [] {
                    if reachable.insert(childID).inserted {
                        queue.append(childID)
                    }
                }
            }
            let count = reachable.reduce(0) { $0 + (directByFolder[$1] ?? 0) }
            byFolder[id] = count
            return count
        }
        for folder in allFolders {
            _ = recursiveCount(for: folder.id)
        }

        return (total, byFolder, directByFolder)
    }

    private func listFoldersInternal(db: OpaquePointer?) throws -> [MeetingFolder] {
        let sql = "SELECT id, name, parent_id, created_at FROM meeting_folders ORDER BY id ASC"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        var rows: [MeetingFolder] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let parentID: Int64? = sqlite3_column_type(statement, 2) != SQLITE_NULL
                ? sqlite3_column_int64(statement, 2) : nil
            rows.append(MeetingFolder(
                id: sqlite3_column_int64(statement, 0),
                name: stringColumn(statement, index: 1),
                parentID: parentID,
                createdAt: stringColumn(statement, index: 3)
            ))
        }
        return rows
    }

    public func recentMeetings(
        limit: Int? = nil,
        folderID: Int64? = nil
    ) throws -> [MeetingRecord] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        var sql: String
        if folderID != nil {
            // Recursive CTE collects the selected folder and all descendants
            // without needing one placeholder per folder.
            sql = """
                WITH RECURSIVE folder_tree(id) AS (
                    SELECT id FROM meeting_folders WHERE id = ?
                    UNION
                    SELECT mf.id FROM meeting_folders mf
                    JOIN folder_tree ft ON mf.parent_id = ft.id
                )
                SELECT \(Self.meetingColumns) FROM meetings
                WHERE folder_id IN (SELECT id FROM folder_tree)
                ORDER BY id DESC
                """
        } else {
            sql = "SELECT \(Self.meetingColumns) FROM meetings ORDER BY id DESC"
        }
        if limit != nil { sql += " LIMIT ?" }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        var bindIndex: Int32 = 1
        if let folderID {
            sqlite3_bind_int64(statement, bindIndex, folderID)
            bindIndex += 1
        }
        if let limit {
            sqlite3_bind_int(statement, bindIndex, Int32(limit))
        }

        var rows: [MeetingRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(makeMeetingRecord(statement))
        }
        return rows
    }

    public func staleLiveMeetings() throws -> [MeetingRecord] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let sql = """
        SELECT \(Self.meetingColumns)
        FROM meetings
        WHERE meeting_status IN (?, ?)
        ORDER BY id DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (MeetingStatus.recording.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (MeetingStatus.processing.rawValue as NSString).utf8String, -1, nil)

        var rows: [MeetingRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(makeMeetingRecord(statement))
        }
        return rows
    }

    public func meeting(id: Int64) throws -> MeetingRecord? {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        return try meeting(id: id, db: db)
    }

    private func meeting(id: Int64, db: OpaquePointer?) throws -> MeetingRecord? {

        let sql = """
        SELECT \(Self.meetingColumns)
        FROM meetings
        WHERE id = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return makeMeetingRecord(statement)
    }

    private static func escapeLikePattern(_ query: String) -> String {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    public func searchMeetings(query: String, limit: Int = 50) throws -> [MeetingRecord] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let sql = """
        SELECT \(Self.meetingColumns)
        FROM meetings
        WHERE (
            title LIKE ? ESCAPE '\\'
            OR raw_transcript LIKE ? ESCAPE '\\'
            OR formatted_notes LIKE ? ESCAPE '\\'
            OR manual_notes LIKE ? ESCAPE '\\'
            OR EXISTS (
                SELECT 1
                FROM meeting_participants
                WHERE meeting_participants.meeting_id = meetings.id
                    AND meeting_participants.is_suppressed = 0
                    AND (
                        meeting_participants.display_name LIKE ? ESCAPE '\\'
                        OR meeting_participants.email_address LIKE ? ESCAPE '\\'
                    )
            )
        )
        ORDER BY id DESC
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        let pattern = Self.escapeLikePattern(query) as NSString
        sqlite3_bind_text(statement, 1, pattern.utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, pattern.utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, pattern.utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, pattern.utf8String, -1, nil)
        sqlite3_bind_text(statement, 5, pattern.utf8String, -1, nil)
        sqlite3_bind_text(statement, 6, pattern.utf8String, -1, nil)
        sqlite3_bind_int(statement, 7, Int32(limit))

        var rows: [MeetingRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(makeMeetingRecord(statement))
        }
        return rows
    }

    public func meetingByCalendarOccurrence(_ occurrence: CalendarOccurrenceReference) throws -> MeetingRecord? {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let legacyStartPredicate = occurrence.seriesID == nil
            ? ""
            : "AND ABS(strftime('%s', start_time) - ?) < 1"
        let sql = """
        SELECT \(Self.meetingColumns)
        FROM meetings
        WHERE (
            calendar_occurrence_key = ?
            OR (
              calendar_occurrence_key IS NULL
              AND calendar_event_id = ?
              \(legacyStartPredicate)
            )
          )
        ORDER BY id DESC
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (occurrence.identityKey as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (occurrence.eventID as NSString).utf8String, -1, nil)
        if occurrence.seriesID != nil {
            sqlite3_bind_double(statement, 3, occurrence.originalStartTime.timeIntervalSince1970)
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return makeMeetingRecord(statement)
    }

    @discardableResult
    public func insertMeeting(
        title: String,
        calendarEventID: String?,
        startTime: Date,
        endTime: Date,
        rawTranscript: String,
        formattedNotes: String,
        micAudioPath: String?,
        systemAudioPath: String?,
        savedRecordingPath: String? = nil,
        selectedTemplateID: String? = nil,
        selectedTemplateName: String? = nil,
        selectedTemplateKind: MeetingTemplateKind? = nil,
        selectedTemplatePrompt: String? = nil,
        source: MeetingSource = .meeting,
        calendarOccurrence: CalendarOccurrenceReference? = nil,
        visualContext: String? = nil
    ) throws -> Int64 {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO meetings
        (title, calendar_event_id, start_time, end_time, duration_seconds, raw_transcript, formatted_notes, mic_audio_path, system_audio_path, saved_recording_path, word_count, selected_template_id, selected_template_name, selected_template_kind, selected_template_prompt, source, updated_at, calendar_occurrence_key, calendar_source, calendar_id, calendar_series_id, calendar_occurrence_start, visual_context, include_notes_in_summary)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }

        let startString = formatISODate(startTime)
        let endString = formatISODate(endTime)
        let durationSeconds = max(endTime.timeIntervalSince(startTime), 0)
        let wordCount = Self.countWords(in: rawTranscript)

        sqlite3_bind_text(statement, 1, (title as NSString).utf8String, -1, nil)
        bindOptionalText(calendarOccurrence?.eventID ?? calendarEventID, at: 2, statement: statement)
        sqlite3_bind_text(statement, 3, (startString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (endString as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 5, durationSeconds)
        sqlite3_bind_text(statement, 6, (rawTranscript as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 7, (formattedNotes as NSString).utf8String, -1, nil)
        bindOptionalText(micAudioPath, at: 8, statement: statement)
        bindOptionalText(systemAudioPath, at: 9, statement: statement)
        bindOptionalText(savedRecordingPath, at: 10, statement: statement)
        sqlite3_bind_int(statement, 11, Int32(wordCount))
        bindOptionalText(selectedTemplateID, at: 12, statement: statement)
        bindOptionalText(selectedTemplateName, at: 13, statement: statement)
        bindOptionalText(selectedTemplateKind?.rawValue, at: 14, statement: statement)
        bindOptionalText(selectedTemplatePrompt, at: 15, statement: statement)
        sqlite3_bind_text(statement, 16, (source.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 17, Date().timeIntervalSince1970)
        bindOptionalText(calendarOccurrence?.identityKey, at: 18, statement: statement)
        bindOptionalText(calendarOccurrence?.provider.rawValue, at: 19, statement: statement)
        bindOptionalText(calendarOccurrence?.calendarID, at: 20, statement: statement)
        bindOptionalText(calendarOccurrence?.seriesID, at: 21, statement: statement)
        if let calendarOccurrence {
            sqlite3_bind_double(statement, 22, calendarOccurrence.originalStartTime.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 22)
        }
        bindOptionalText(visualContext, at: 23, statement: statement)
        // include-notes-in-summary is a global AppConfig setting; new meetings
        // start at the transcript-only default (0).
        sqlite3_bind_int(statement, 24, 0)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        return sqlite3_last_insert_rowid(db)
    }

    public func listMeetingParticipants(meetingID: Int64) throws -> [MeetingParticipant] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let sql = """
        SELECT meeting_id, participant_identifier, display_name, email_address, insertion_order
        FROM meeting_participants
        WHERE meeting_id = ? AND is_suppressed = 0
        ORDER BY insertion_order, participant_identifier
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)

        var participants: [MeetingParticipant] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                participants.append(MeetingParticipant(
                    meetingID: sqlite3_column_int64(statement, 0),
                    participantIdentifier: stringColumn(statement, index: 1),
                    displayName: stringColumn(statement, index: 2),
                    emailAddress: sqlite3_column_type(statement, 3) == SQLITE_NULL
                        ? nil
                        : stringColumn(statement, index: 3),
                    insertionOrder: Int(sqlite3_column_int64(statement, 4))
                ))
            case SQLITE_DONE:
                return participants
            default:
                throw lastError(db)
            }
        }
    }

    public func attachMeetingParticipant(
        meetingID: Int64,
        participant: MeetingParticipantDraft
    ) throws {
        try attachMeetingParticipants(
            meetingID: meetingID,
            participants: [participant],
            source: .manual
        )
    }

    /// Upserts an EventKit attendee snapshot batch through one connection and transaction.
    public func attachCalendarMeetingParticipants(
        meetingID: Int64,
        participants: [MeetingParticipantDraft]
    ) throws {
        try attachMeetingParticipants(
            meetingID: meetingID,
            participants: participants,
            source: .calendar
        )
    }

    private enum MeetingParticipantSource: String {
        case calendar
        case manual
    }

    private func attachMeetingParticipants(
        meetingID: Int64,
        participants: [MeetingParticipantDraft],
        source: MeetingParticipantSource
    ) throws {
        guard !participants.isEmpty else { return }
        let normalizedParticipants = try Self.normalizedMeetingParticipants(participants)

        let db = try openDatabase()
        defer { sqlite3_close(db) }

        try exec("BEGIN IMMEDIATE TRANSACTION", db: db)
        do {
            try upsertMeetingParticipants(
                meetingID: meetingID,
                participants: normalizedParticipants,
                source: source,
                db: db
            )
            try exec("COMMIT", db: db)
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Replaces only the calendar-owned portion of a meeting's local People
    /// snapshot. Manual Contacts remain untouched, and calendar identities the
    /// user explicitly removed remain suppressed.
    public func reconcileCalendarMeetingParticipants(
        meetingID: Int64,
        participants: [MeetingParticipantDraft]
    ) throws {
        let normalizedParticipants = try Self.normalizedMeetingParticipants(participants)
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        try exec("BEGIN IMMEDIATE TRANSACTION", db: db)
        do {
            let incomingIdentifiers = Set(normalizedParticipants.map(\.participantIdentifier))
            let storedIdentifiers = try calendarMeetingParticipantIdentifiers(
                meetingID: meetingID,
                db: db
            )
            for identifier in storedIdentifiers.subtracting(incomingIdentifiers) {
                try deleteMeetingParticipant(
                    meetingID: meetingID,
                    participantIdentifier: identifier,
                    db: db
                )
            }
            try upsertMeetingParticipants(
                meetingID: meetingID,
                participants: normalizedParticipants,
                source: .calendar,
                db: db
            )
            try exec("COMMIT", db: db)
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    public func removeMeetingParticipant(
        meetingID: Int64,
        participantIdentifier: String
    ) throws {
        let normalizedIdentifier = participantIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedIdentifier.isEmpty else {
            throw DictationStoreError.invalidParticipantIdentifier
        }

        let db = try openDatabase()
        defer { sqlite3_close(db) }

        try exec("BEGIN IMMEDIATE TRANSACTION", db: db)
        do {
            if try meetingParticipantSource(
                meetingID: meetingID,
                participantIdentifier: normalizedIdentifier,
                db: db
            ) == .calendar {
                try suppressMeetingParticipant(
                    meetingID: meetingID,
                    participantIdentifier: normalizedIdentifier,
                    db: db
                )
            } else {
                try deleteMeetingParticipant(
                    meetingID: meetingID,
                    participantIdentifier: normalizedIdentifier,
                    db: db
                )
            }
            try exec("COMMIT", db: db)
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private static func normalizedMeetingParticipants(
        _ participants: [MeetingParticipantDraft]
    ) throws -> [MeetingParticipantDraft] {
        try participants.map { participant in
            let participantIdentifier = participant.participantIdentifier
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = participant.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !participantIdentifier.isEmpty, !displayName.isEmpty else {
                throw DictationStoreError.invalidParticipantIdentifier
            }
            return MeetingParticipantDraft(
                participantIdentifier: participantIdentifier,
                displayName: displayName,
                emailAddress: participant.emailAddress
            )
        }
    }

    private func upsertMeetingParticipants(
        meetingID: Int64,
        participants: [MeetingParticipantDraft],
        source: MeetingParticipantSource,
        db: OpaquePointer?
    ) throws {
        guard !participants.isEmpty else { return }

        let sql = """
        INSERT INTO meeting_participants
            (meeting_id, participant_identifier, display_name, email_address, insertion_order, source)
        VALUES (
            ?,
            ?,
            ?,
            ?,
            COALESCE(
                (SELECT MAX(insertion_order) + 1
                 FROM meeting_participants
                 WHERE meeting_id = ?),
                0
            ),
            ?
        )
        ON CONFLICT(meeting_id, participant_identifier)
        DO UPDATE SET
            display_name = CASE
                WHEN meeting_participants.source = 'manual' AND excluded.source = 'calendar'
                    THEN meeting_participants.display_name
                ELSE excluded.display_name
            END,
            email_address = CASE
                WHEN meeting_participants.source = 'manual' AND excluded.source = 'calendar'
                    THEN meeting_participants.email_address
                ELSE COALESCE(excluded.email_address, meeting_participants.email_address)
            END,
            source = CASE
                WHEN excluded.source = 'manual' THEN 'manual'
                ELSE meeting_participants.source
            END,
            is_suppressed = CASE
                WHEN excluded.source = 'manual' THEN 0
                ELSE meeting_participants.is_suppressed
            END
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }

        for participant in participants {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int64(statement, 1, meetingID)
            sqlite3_bind_text(
                statement,
                2,
                (participant.participantIdentifier as NSString).utf8String,
                -1,
                nil
            )
            sqlite3_bind_text(
                statement,
                3,
                (participant.displayName as NSString).utf8String,
                -1,
                nil
            )
            bindOptionalText(participant.emailAddress, at: 4, statement: statement)
            sqlite3_bind_int64(statement, 5, meetingID)
            sqlite3_bind_text(statement, 6, (source.rawValue as NSString).utf8String, -1, nil)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw lastError(db)
            }
        }
    }

    private func calendarMeetingParticipantIdentifiers(
        meetingID: Int64,
        db: OpaquePointer?
    ) throws -> Set<String> {
        let sql = """
        SELECT participant_identifier
        FROM meeting_participants
        WHERE meeting_id = ?
            AND source = 'calendar'
            AND is_suppressed = 0
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)

        var identifiers = Set<String>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                identifiers.insert(stringColumn(statement, index: 0))
            case SQLITE_DONE:
                return identifiers
            default:
                throw lastError(db)
            }
        }
    }

    private func meetingParticipantSource(
        meetingID: Int64,
        participantIdentifier: String,
        db: OpaquePointer?
    ) throws -> MeetingParticipantSource? {
        let sql = """
        SELECT source
        FROM meeting_participants
        WHERE meeting_id = ? AND participant_identifier = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        sqlite3_bind_text(statement, 2, (participantIdentifier as NSString).utf8String, -1, nil)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return MeetingParticipantSource(rawValue: stringColumn(statement, index: 0))
        case SQLITE_DONE:
            return nil
        default:
            throw lastError(db)
        }
    }

    private func suppressMeetingParticipant(
        meetingID: Int64,
        participantIdentifier: String,
        db: OpaquePointer?
    ) throws {
        let sql = """
        UPDATE meeting_participants
        SET is_suppressed = 1
        WHERE meeting_id = ? AND participant_identifier = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        sqlite3_bind_text(statement, 2, (participantIdentifier as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    private func deleteMeetingParticipant(
        meetingID: Int64,
        participantIdentifier: String,
        db: OpaquePointer?
    ) throws {
        let sql = """
        DELETE FROM meeting_participants
        WHERE meeting_id = ? AND participant_identifier = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        sqlite3_bind_text(statement, 2, (participantIdentifier as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    // MARK: - Meeting ↔ Event links (multi "Add to Event" attachments)

    /// Attaches a meeting to an additional calendar event. Idempotent: a
    /// link already present for the pair is left untouched.
    public func addMeetingEventLink(
        meetingID: Int64,
        eventID: String,
        calendarID: String? = nil,
        occurrenceKey: String? = nil
    ) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = """
        INSERT OR IGNORE INTO meeting_event_links
            (meeting_id, event_id, calendar_id, occurrence_key, added_at)
        VALUES (?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        sqlite3_bind_text(statement, 2, (eventID as NSString).utf8String, -1, nil)
        bindOptionalText(calendarID, at: 3, statement: statement)
        bindOptionalText(occurrenceKey, at: 4, statement: statement)
        sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    /// Removes an explicit "Add to Event" attachment. Safe to call when no
    /// such link exists. Pass the occurrence key to remove exactly one
    /// recurring instance; nil removes every row for the meeting+event pair
    /// (legacy behavior, kept for callers without occurrence context).
    public func removeMeetingEventLink(
        meetingID: Int64,
        eventID: String,
        occurrenceKey: String? = nil
    ) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql: String
        if occurrenceKey != nil {
            sql = """
            DELETE FROM meeting_event_links
            WHERE meeting_id = ? AND event_id = ? AND occurrence_key = ?
            """
        } else {
            sql = """
            DELETE FROM meeting_event_links
            WHERE meeting_id = ? AND event_id = ?
            """
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        sqlite3_bind_text(statement, 2, (eventID as NSString).utf8String, -1, nil)
        if let occurrenceKey {
            bindOptionalText(occurrenceKey, at: 3, statement: statement)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    /// The extra events a meeting is explicitly attached to (does not
    /// include the primary `calendar_event_id`).
    public func meetingEventLinks(meetingID: Int64) throws -> [MeetingEventLink] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        return try meetingEventLinks(meetingID: meetingID, db: db)
    }

    private func meetingEventLinks(
        meetingID: Int64,
        db: OpaquePointer?
    ) throws -> [MeetingEventLink] {
        let sql = """
        SELECT meeting_id, event_id, calendar_id, occurrence_key, added_at
        FROM meeting_event_links
        WHERE meeting_id = ?
        ORDER BY added_at ASC, event_id ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)

        var links: [MeetingEventLink] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                links.append(MeetingEventLink(
                    meetingID: sqlite3_column_int64(statement, 0),
                    eventID: stringColumn(statement, index: 1),
                    calendarID: optionalStringColumn(statement, index: 2),
                    occurrenceKey: optionalStringColumn(statement, index: 3),
                    addedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                ))
            case SQLITE_DONE:
                return links
            default:
                throw lastError(db)
            }
        }
    }

    /// Meetings explicitly attached to the given event (by stored event id or
    /// by a recorded occurrence whose identity key matches).
    public func meetingsLinked(toEventID eventID: String) throws -> [Int64] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        return try meetingsLinked(toEventID: eventID, db: db)
    }

    private func meetingsLinked(
        toEventID eventID: String,
        db: OpaquePointer?
    ) throws -> [Int64] {
        let sql = """
        SELECT DISTINCT mel.meeting_id
        FROM meeting_event_links mel
        LEFT JOIN meetings m ON m.id = mel.meeting_id
        WHERE mel.event_id = ?
            OR (mel.occurrence_key IS NOT NULL AND m.calendar_occurrence_key = mel.occurrence_key)
        ORDER BY mel.meeting_id ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (eventID as NSString).utf8String, -1, nil)

        var meetingIDs: [Int64] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                meetingIDs.append(sqlite3_column_int64(statement, 0))
            case SQLITE_DONE:
                return meetingIDs
            default:
                throw lastError(db)
            }
        }
    }

    /// Every explicit meeting-event attachment in the store, most recently
    /// attached first. Read once into `AppState` so views can index links
    /// without per-meeting queries.
    public func allMeetingEventLinks() throws -> [MeetingEventLink] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = """
        SELECT meeting_id, event_id, calendar_id, occurrence_key, added_at
        FROM meeting_event_links
        ORDER BY added_at DESC, meeting_id ASC, event_id ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }

        var links: [MeetingEventLink] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                links.append(MeetingEventLink(
                    meetingID: sqlite3_column_int64(statement, 0),
                    eventID: stringColumn(statement, index: 1),
                    calendarID: optionalStringColumn(statement, index: 2),
                    occurrenceKey: optionalStringColumn(statement, index: 3),
                    addedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                ))
            case SQLITE_DONE:
                return links
            default:
                throw lastError(db)
            }
        }
    }

    @discardableResult
    public func createLiveMeeting(
        title: String,
        calendarEventID: String?,
        startTime: Date,
        selectedTemplateID: String? = nil,
        selectedTemplateName: String? = nil,
        selectedTemplateKind: MeetingTemplateKind? = nil,
        selectedTemplatePrompt: String? = nil,
        folderID: Int64? = nil,
        followUpToID: Int64? = nil,
        calendarOccurrence: CalendarOccurrenceReference? = nil
    ) throws -> Int64 {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = """
        INSERT INTO meetings
        (title, calendar_event_id, start_time, end_time, duration_seconds, raw_transcript, formatted_notes, mic_audio_path, system_audio_path, saved_recording_path, meeting_status, manual_notes, word_count, selected_template_id, selected_template_name, selected_template_kind, selected_template_prompt, source, updated_at, folder_id, follow_up_to_id, calendar_occurrence_key, calendar_source, calendar_id, calendar_series_id, calendar_occurrence_start)
        VALUES (?, ?, ?, NULL, 0, '', '', NULL, NULL, NULL, ?, '', 0, ?, ?, ?, ?, 'meeting', ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }

        let startString = ISO8601DateFormatter().string(from: startTime)
        sqlite3_bind_text(statement, 1, (title as NSString).utf8String, -1, nil)
        bindOptionalText(calendarOccurrence?.eventID ?? calendarEventID, at: 2, statement: statement)
        sqlite3_bind_text(statement, 3, (startString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (MeetingStatus.recording.rawValue as NSString).utf8String, -1, nil)
        bindOptionalText(selectedTemplateID, at: 5, statement: statement)
        bindOptionalText(selectedTemplateName, at: 6, statement: statement)
        bindOptionalText(selectedTemplateKind?.rawValue, at: 7, statement: statement)
        bindOptionalText(selectedTemplatePrompt, at: 8, statement: statement)
        sqlite3_bind_double(statement, 9, Date().timeIntervalSince1970)
        if let folderID {
            sqlite3_bind_int64(statement, 10, folderID)
        } else {
            sqlite3_bind_null(statement, 10)
        }
        if let followUpToID {
            sqlite3_bind_int64(statement, 11, followUpToID)
        } else {
            sqlite3_bind_null(statement, 11)
        }
        bindOptionalText(calendarOccurrence?.identityKey, at: 12, statement: statement)
        bindOptionalText(calendarOccurrence?.provider.rawValue, at: 13, statement: statement)
        bindOptionalText(calendarOccurrence?.calendarID, at: 14, statement: statement)
        bindOptionalText(calendarOccurrence?.seriesID, at: 15, statement: statement)
        if let calendarOccurrence {
            sqlite3_bind_double(statement, 16, calendarOccurrence.originalStartTime.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 16)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// The meeting that `id` points to as its follow-up predecessor, if any.
    public func meetingPredecessorID(of id: Int64) throws -> Int64? {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        return try meetingPredecessorID(of: id, db: db)
    }

    private func meetingPredecessorID(of id: Int64, db: OpaquePointer?) throws -> Int64? {
        var statement: OpaquePointer?
        let sql = """
        SELECT predecessor.id
        FROM meetings AS child
        JOIN meetings AS predecessor
          ON predecessor.id = child.follow_up_to_id
        WHERE child.id = ?
        LIMIT 1
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    /// The earliest meeting recorded as a follow-up to `id`, if any.
    /// A predecessor may have multiple follow-ups; callers that need the whole
    /// set should use `meetingThreadIDs(containing:)`.
    public func meetingSuccessorID(of id: Int64) throws -> Int64? {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        return try meetingSuccessorID(of: id, db: db)
    }

    private func meetingSuccessorID(of id: Int64, db: OpaquePointer?) throws -> Int64? {
        try meetingSuccessorIDs(of: id, db: db).first
    }

    private func meetingSuccessorIDs(of id: Int64, db: OpaquePointer?) throws -> [Int64] {
        var statement: OpaquePointer?
        let sql = """
        SELECT child.id
        FROM meetings AS predecessor
        JOIN meetings AS child
          ON child.follow_up_to_id = predecessor.id
        WHERE predecessor.id = ?
        ORDER BY child.start_time ASC, child.id ASC
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)

        var ids: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(statement, 0))
        }
        return ids
    }

    /// Returns the latest chronological meeting in the follow-up tree that
    /// contains `id`. A predecessor can have multiple follow-ups.
    public func latestMeetingIDInThread(of id: Int64) throws -> Int64 {
        try meetingThreadIDs(containing: id).last ?? id
    }

    /// Parent, direct child follow-ups, and chronological position for `id`.
    /// Returns nil for meetings that are not part of a follow-up thread.
    public func meetingThreadNavigation(containing id: Int64) throws -> MeetingThreadNavigation? {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let thread = try meetingThreadIDs(containing: id, db: db)
        guard thread.count > 1, thread.contains(id) else { return nil }
        return MeetingThreadNavigation(
            predecessorID: try meetingPredecessorID(of: id, db: db),
            successorIDs: try meetingSuccessorIDs(of: id, db: db),
            count: thread.count
        )
    }

    /// The follow-up tree containing `id`, ordered chronologically. A meeting
    /// with no links returns just itself.
    public func meetingThreadIDs(containing id: Int64) throws -> [Int64] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        return try meetingThreadIDs(containing: id, db: db)
    }

    private func meetingThreadIDs(containing id: Int64, db: OpaquePointer?) throws -> [Int64] {
        // Walk back to the root.
        var root = id
        var visited: Set<Int64> = [id]
        while let predecessor = try meetingPredecessorID(of: root, db: db) {
            guard visited.insert(predecessor).inserted else { break }
            root = predecessor
        }

        let sql = """
        WITH RECURSIVE thread(id, start_time, path) AS (
            SELECT id, start_time, ',' || id || ','
            FROM meetings
            WHERE id = ?
            UNION ALL
            SELECT child.id, child.start_time, thread.path || child.id || ','
            FROM meetings AS child
            JOIN thread ON child.follow_up_to_id = thread.id
            WHERE instr(thread.path, ',' || child.id || ',') = 0
        )
        SELECT id
        FROM thread
        ORDER BY start_time ASC, id ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, root)

        var thread: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            thread.append(sqlite3_column_int64(statement, 0))
        }
        return thread
    }

    public func meetingStats() throws -> MeetingStats {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let sql = """
        SELECT
            COUNT(*) AS total_meetings,
            COALESCE(SUM(word_count), 0) AS total_words,
            COALESCE(SUM(CASE WHEN duration_seconds > 0 THEN word_count ELSE 0 END), 0)
                AS timed_words,
            COALESCE(SUM(CASE WHEN duration_seconds > 0 THEN duration_seconds ELSE 0 END), 0)
                AS timed_duration_seconds
        FROM meetings
        WHERE meeting_status IN (?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (MeetingStatus.completed.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (MeetingStatus.noteOnly.rawValue as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return MeetingStats(totalWords: 0, totalMeetings: 0, averageWPM: 0)
        }

        let totalMeetings = Int(sqlite3_column_int(statement, 0))
        let totalWords = Int(sqlite3_column_int(statement, 1))
        let timedWords = Int(sqlite3_column_int(statement, 2))
        let timedDuration = sqlite3_column_double(statement, 3)
        return MeetingStats(
            totalWords: totalWords,
            totalMeetings: totalMeetings,
            averageWPM: timedDuration > 0 ? Double(timedWords) / (timedDuration / 60.0) : 0
        )
    }

    public func insightsSnapshot(
        range: InsightsRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> InsightsSnapshot {
        try insightsSnapshot(
            range: range,
            now: now,
            calendar: calendar,
            afterLifetimeRead: {}
        )
    }

    func insightsSnapshot(
        range: InsightsRange,
        now: Date,
        calendar: Calendar,
        afterLifetimeRead: () throws -> Void
    ) throws -> InsightsSnapshot {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try reconcileInsightsCache(db: db, calendar: calendar)

        let startDate = range.startDate(now: now, calendar: calendar)
        let startDay = startDate.map { cacheDay($0, calendar: calendar) }
        try exec("BEGIN TRANSACTION", db: db)
        do {
            let lifetime = try cachedInsightsTotals(db: db, sinceDay: nil)
            try afterLifetimeRead()
            let selected = try cachedInsightsTotals(db: db, sinceDay: startDay)
            let cachedDays = try cachedDailyActivity(db: db, sinceDay: startDay, calendar: calendar)
            let today = calendar.startOfDay(for: now)
            let firstDay = startDate.map { calendar.startOfDay(for: $0) }
                ?? cachedDays.keys.min()
                ?? today
            var activity: [InsightsDailyActivity] = []
            var cursor = min(firstDay, today)
            while cursor <= today {
                let value = cachedDays[cursor, default: (0, 0)]
                activity.append(InsightsDailyActivity(date: cursor, words: value.words, meetings: value.meetings))
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }

            let streaks = try meetingStreakDays(db: db, calendar: calendar)
            // v2 trinity aggregates.
            let meetingStats = try meetingActivityStats(db: db, sinceDay: startDay, calendar: calendar)
            let lifetimeMeetingStats = try meetingActivityStats(db: db, sinceDay: nil, calendar: calendar)
            // For a bounded range, buckets start at the range start; for
            // "All time" (nil start) they must start at the earliest day
            // that has activity — otherwise the chart window collapses to
            // today and past meetings vanish from the bars.
            let bucketStart = startDate.map { calendar.startOfDay(for: $0) } ?? firstDay
            let meetingBuckets = try meetingActivityBuckets(
                db: db,
                sinceDay: startDay,
                calendar: calendar,
                startDate: bucketStart,
                endDate: today
            )
            let folderStats = try meetingFolderStats(db: db, sinceDay: startDay)
            let recurringMeetings = try recurringMeetingStats(db: db, sinceDay: startDay)
            let llm = try llmUsageStats(db: db, sinceDay: startDay, calendar: calendar)
            let snapshot = InsightsSnapshot(
                range: range,
                generatedAt: now,
                lifetime: lifetime,
                selected: selected,
                dailyActivity: activity,
                currentStreakDays: streaks.current,
                longestStreakDays: streaks.longest,
                activeDaysInRange: activity.filter { $0.meetings > 0 }.count,
                meetingWords: try cachedTopMeetingWords(db: db, sinceDay: startDay),
                meetingStats: meetingStats,
                lifetimeMeetingStats: lifetimeMeetingStats,
                meetingBuckets: meetingBuckets,
                folderStats: folderStats,
                recurringMeetings: recurringMeetings,
                calendarStats: MeetingCalendarLinkageStats(),
                llmStats: llm.stats,
                llmUsageByDay: llm.byDay
            )
            try exec("COMMIT", db: db)
            return snapshot
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private struct InsightsCacheSource {
        let id: Int64
        let updatedAt: Double
        let date: Date
        let wordCount: Int
        let duration: Double
        let deleted: Bool
        let eligible: Bool
    }

    private static let insightsCacheBatchSize = 64

    private func reconcileInsightsCache(db: OpaquePointer?, calendar: Calendar) throws {
        let signature = "4|\(calendar.timeZone.identifier)"
        if try insightsCacheMeta("signature", db: db) != signature {
            try resetInsightsCache(signature: signature, db: db)
        }

        while true {
            let stale = try staleInsightsCacheKeys(db: db, limit: Self.insightsCacheBatchSize)
            guard !stale.isEmpty else { break }
            for id in stale {
                if Task.isCancelled { throw CancellationError() }
                try withInsightsWriteTransaction(db: db) {
                    try removeCachedInsightsRecord(id: id, db: db)
                }
            }
        }

        while true {
            let changed = try changedInsightsSources(db: db, limit: Self.insightsCacheBatchSize)
            guard !changed.isEmpty else { break }
            for source in changed {
                if Task.isCancelled { throw CancellationError() }
                var counts: [String: Int] = [:]
                if !source.deleted, source.eligible {
                    guard let text = try insightsSourceText(source, db: db) else { continue }
                    InsightsWordAnalyzer.accumulateMeetingTranscript(text, into: &counts)
                }
                try applyInsightsSource(source, counts: counts, calendar: calendar, db: db)
            }
        }

        try withInsightsWriteTransaction(db: db) {
            try exec("""
            DELETE FROM insights_daily_cache
              WHERE meeting_words = 0 AND meetings = 0;
            DELETE FROM insights_daily_tokens WHERE meeting_count = 0;
            DELETE FROM insights_token_totals WHERE meeting_count = 0;
            """, db: db)
        }
    }

    private func resetInsightsCache(signature: String, db: OpaquePointer?) throws {
        try withInsightsWriteTransaction(db: db) {
            try exec("""
            DELETE FROM insights_record_cache;
            DELETE FROM insights_daily_cache;
            DELETE FROM insights_daily_tokens;
            DELETE FROM insights_token_totals;
            DELETE FROM insights_tokens;
            """, db: db)
            let sql = """
            INSERT INTO insights_cache_meta(key, value) VALUES('signature', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, (signature as NSString).utf8String, -1, nil)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError(db) }
        }
    }

    private func changedInsightsSources(db: OpaquePointer?, limit: Int) throws -> [InsightsCacheSource] {
        let sql = """
        SELECT m.id, m.updated_at, m.start_time, m.word_count,
               COALESCE(m.duration_seconds, 0), m.meeting_status IN ('completed', 'note_only')
        FROM meetings m
        LEFT JOIN insights_record_cache c ON c.record_id = m.id
        WHERE c.record_id IS NULL OR c.source_updated_at != m.updated_at
        ORDER BY m.id
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var rows: [InsightsCacheSource] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let parsedDate = parseISODate(stringColumn(statement, index: 2))
            rows.append(InsightsCacheSource(
                id: sqlite3_column_int64(statement, 0),
                updatedAt: sqlite3_column_double(statement, 1),
                date: parsedDate ?? Date(timeIntervalSince1970: 0),
                wordCount: Int(sqlite3_column_int64(statement, 3)),
                duration: sqlite3_column_double(statement, 4),
                deleted: false,
                eligible: parsedDate != nil && sqlite3_column_int(statement, 5) != 0
            ))
        }
        return rows
    }

    private func insightsSourceText(_ source: InsightsCacheSource, db: OpaquePointer?) throws -> String? {
        let sql = """
        SELECT CASE WHEN meeting_status = 'note_only' THEN COALESCE(manual_notes, '') ELSE COALESCE(raw_transcript, '') END
        FROM meetings WHERE id = ? AND updated_at = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, source.id)
        sqlite3_bind_double(statement, 2, source.updatedAt)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return stringColumn(statement, index: 0)
    }

    @discardableResult
    private func applyInsightsSource(
        _ source: InsightsCacheSource,
        counts: [String: Int],
        calendar: Calendar,
        db: OpaquePointer?
    ) throws -> Bool {
        try withInsightsWriteTransaction(db: db) {
            guard try insightsSourceIsCurrent(source, db: db) else { return false }
            try removeCachedInsightsRecord(id: source.id, db: db)
            let day = cacheDay(source.date, calendar: calendar)
            guard !source.deleted, source.eligible else {
                try markInsightsSourceProcessed(source, day: day, db: db)
                return true
            }
            var pairs: [InsightsContributionCodec.Pair] = []
            pairs.reserveCapacity(counts.count)
            for (token, count) in counts {
                pairs.append(.init(tokenID: try internInsightsToken(token, db: db), count: count))
            }
            try addCachedInsightsRecord(source, day: day, pairs: pairs, db: db)
            return true
        }
    }

    private func insightsSourceIsCurrent(_ source: InsightsCacheSource, db: OpaquePointer?) throws -> Bool {
        let sql = "SELECT 1 FROM meetings WHERE id = ? AND updated_at = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, source.id)
        sqlite3_bind_double(statement, 2, source.updatedAt)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func staleInsightsCacheKeys(db: OpaquePointer?, limit: Int) throws -> [Int64] {
        let sql = """
        SELECT record_id FROM insights_record_cache c
        WHERE NOT EXISTS (SELECT 1 FROM meetings m WHERE m.id = c.record_id)
        ORDER BY record_id
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var keys: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW { keys.append(sqlite3_column_int64(statement, 0)) }
        return keys
    }

    private func withInsightsWriteTransaction<T>(db: OpaquePointer?, _ work: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE", db: db)
        do {
            let result = try work()
            try exec("COMMIT", db: db)
            return result
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func addCachedInsightsRecord(_ source: InsightsCacheSource, day: String, pairs: [InsightsContributionCodec.Pair], db: OpaquePointer?) throws {
        try adjustInsightsDaily(day: day, meetingWords: source.wordCount, meetings: 1, duration: source.duration, db: db)
        for pair in pairs { try adjustInsightsToken(day: day, pair: pair, multiplier: 1, db: db) }
        let sql = """
        INSERT INTO insights_record_cache
          (record_id, source_updated_at, activity_day, word_count, duration_seconds,
           meeting_words, meetings, token_blob)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, source.id)
        sqlite3_bind_double(statement, 2, source.updatedAt)
        sqlite3_bind_text(statement, 3, (day as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(statement, 4, Int64(source.wordCount))
        sqlite3_bind_double(statement, 5, source.duration)
        sqlite3_bind_int64(statement, 6, Int64(source.wordCount))
        sqlite3_bind_int(statement, 7, 1)
        let blob = InsightsContributionCodec.encode(pairs)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 8, $0.baseAddress, Int32(blob.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError(db) }
    }

    /// Records the source revision even when it contributes no analytics. This keeps
    /// deleted and unfinished rows out of subsequent delta scans until they change.
    private func markInsightsSourceProcessed(_ source: InsightsCacheSource, day: String, db: OpaquePointer?) throws {
        let sql = """
        INSERT INTO insights_record_cache
          (record_id, source_updated_at, activity_day, word_count, duration_seconds,
           meeting_words, meetings, token_blob)
        VALUES (?, ?, ?, 0, 0, 0, 0, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, source.id)
        sqlite3_bind_double(statement, 2, source.updatedAt)
        sqlite3_bind_text(statement, 3, (day as NSString).utf8String, -1, nil)
        let blob = InsightsContributionCodec.encode([])
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(blob.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError(db) }
    }

    private func removeCachedInsightsRecord(id: Int64, db: OpaquePointer?) throws {
        let sql = "SELECT activity_day, word_count, duration_seconds, meeting_words, meetings, token_blob FROM insights_record_cache WHERE record_id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { sqlite3_finalize(statement); return }
        let day = stringColumn(statement, index: 0), words = Int(sqlite3_column_int64(statement, 1))
        let duration = sqlite3_column_double(statement, 2)
        let meetingWords = Int(sqlite3_column_int64(statement, 3)), meetings = Int(sqlite3_column_int(statement, 4))
        let bytes = sqlite3_column_blob(statement, 5), count = Int(sqlite3_column_bytes(statement, 5))
        let blob = bytes.map { Data(bytes: $0, count: count) } ?? Data()
        sqlite3_finalize(statement)
        do {
            try adjustInsightsDaily(day: day, meetingWords: -meetingWords, meetings: -meetings, duration: -duration, db: db)
        } catch {
            throw NSError(domain: "MeetsInsightsCache", code: 3, userInfo: [NSLocalizedDescriptionKey: "Subtracting daily contribution: \(error.localizedDescription)"])
        }
        for pair in InsightsContributionCodec.decode(blob) {
            do {
                try adjustInsightsToken(day: day, pair: pair, multiplier: -1, db: db)
            } catch {
                throw NSError(domain: "MeetsInsightsCache", code: 4, userInfo: [NSLocalizedDescriptionKey: "Subtracting token \(pair.tokenID): \(error.localizedDescription)"])
            }
        }
        var delete: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM insights_record_cache WHERE record_id = ?", -1, &delete, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(delete) }
        sqlite3_bind_int64(delete, 1, id)
        guard sqlite3_step(delete) == SQLITE_DONE else { throw lastError(db) }
    }

    private func adjustInsightsDaily(day: String, meetingWords: Int, meetings: Int, duration: Double, db: OpaquePointer?) throws {
        let sql = """
        INSERT INTO insights_daily_cache(day, meeting_words, meetings, duration_seconds)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(day) DO UPDATE SET meeting_words=meeting_words+excluded.meeting_words,
          meetings=meetings+excluded.meetings, duration_seconds=duration_seconds+excluded.duration_seconds
        """
        var s: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw lastError(db) }; defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, (day as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(s, 2, Int64(meetingWords))
        sqlite3_bind_int(s, 3, Int32(meetings))
        sqlite3_bind_double(s, 4, duration)
        guard sqlite3_step(s) == SQLITE_DONE else { throw lastError(db) }
    }

    private func adjustInsightsToken(day: String, pair: InsightsContributionCodec.Pair, multiplier: Int, db: OpaquePointer?) throws {
        let meetingCount = pair.count * multiplier
        for sql in [
            "INSERT INTO insights_token_totals(token_id,meeting_count) VALUES(?,?) ON CONFLICT(token_id) DO UPDATE SET meeting_count=meeting_count+excluded.meeting_count",
            "INSERT INTO insights_daily_tokens(day,token_id,meeting_count) VALUES(?,?,?) ON CONFLICT(day,token_id) DO UPDATE SET meeting_count=meeting_count+excluded.meeting_count"
        ] {
            var s: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw lastError(db) }; defer { sqlite3_finalize(s) }
            var index: Int32 = 1
            if sql.contains("daily_tokens") { sqlite3_bind_text(s, index, (day as NSString).utf8String, -1, nil); index += 1 }
            sqlite3_bind_int64(s, index, pair.tokenID)
            sqlite3_bind_int(s, index + 1, Int32(meetingCount))
            guard sqlite3_step(s) == SQLITE_DONE else { throw lastError(db) }
        }
    }

    private func internInsightsToken(_ token: String, db: OpaquePointer?) throws -> Int64 {
        var insert: OpaquePointer?; guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO insights_tokens(token) VALUES(?)", -1, &insert, nil) == SQLITE_OK else { throw lastError(db) }
        sqlite3_bind_text(insert, 1, (token as NSString).utf8String, -1, nil); guard sqlite3_step(insert) == SQLITE_DONE else { sqlite3_finalize(insert); throw lastError(db) }; sqlite3_finalize(insert)
        var select: OpaquePointer?; guard sqlite3_prepare_v2(db, "SELECT id FROM insights_tokens WHERE token=?", -1, &select, nil) == SQLITE_OK else { throw lastError(db) }; defer { sqlite3_finalize(select) }
        sqlite3_bind_text(select, 1, (token as NSString).utf8String, -1, nil); guard sqlite3_step(select) == SQLITE_ROW else { throw lastError(db) }
        return sqlite3_column_int64(select, 0)
    }

    private func insightsCacheMeta(_ key: String, db: OpaquePointer?) throws -> String? {
        var s: OpaquePointer?; guard sqlite3_prepare_v2(db, "SELECT value FROM insights_cache_meta WHERE key=?", -1, &s, nil) == SQLITE_OK else { throw lastError(db) }; defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, (key as NSString).utf8String, -1, nil); return sqlite3_step(s) == SQLITE_ROW ? stringColumn(s, index: 0) : nil
    }

    private func cacheDay(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func cachedInsightsTotals(db: OpaquePointer?, sinceDay: String?) throws -> InsightsTotals {
        let sql = """
        WITH selected_day(value) AS (VALUES (?)),
        daily AS (
            SELECT meeting_words, meetings
            FROM insights_daily_cache
            WHERE (SELECT value FROM selected_day) IS NULL
               OR day >= (SELECT value FROM selected_day)
        ),
        timed AS (
            SELECT meeting_words AS words, duration_seconds
            FROM insights_record_cache
            WHERE duration_seconds > 0
              AND ((SELECT value FROM selected_day) IS NULL
                   OR activity_day >= (SELECT value FROM selected_day))
        )
        SELECT
          (SELECT COALESCE(SUM(meeting_words), 0) FROM daily),
          (SELECT COALESCE(SUM(meetings), 0) FROM daily),
          (SELECT COALESCE(SUM(words), 0) FROM timed),
          (SELECT COALESCE(SUM(duration_seconds), 0) FROM timed)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        bindOptionalText(sinceDay, at: 1, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return InsightsTotals(meetingWords: 0, meetings: 0, averageWPM: 0)
        }
        let meetingWords = Int(sqlite3_column_int64(statement, 0))
        let meetings = Int(sqlite3_column_int64(statement, 1))
        let timedWords = Int(sqlite3_column_int64(statement, 2))
        let timedDuration = sqlite3_column_double(statement, 3)
        return InsightsTotals(
            meetingWords: meetingWords,
            meetings: meetings,
            averageWPM: timedDuration > 0 ? Double(timedWords) / (timedDuration / 60) : 0
        )
    }

    private func cachedDailyActivity(db: OpaquePointer?, sinceDay: String?, calendar: Calendar) throws -> [Date: (words: Int, meetings: Int)] {
        var s: OpaquePointer?; guard sqlite3_prepare_v2(db, "SELECT day,meeting_words,meetings FROM insights_daily_cache WHERE (? IS NULL OR day>=?) ORDER BY day", -1, &s, nil) == SQLITE_OK else { throw lastError(db) }; defer { sqlite3_finalize(s) }
        bindOptionalText(sinceDay, at: 1, statement: s); bindOptionalText(sinceDay, at: 2, statement: s)
        var result: [Date: (Int, Int)] = [:]
        while sqlite3_step(s) == SQLITE_ROW {
            let parts = stringColumn(s, index: 0).split(separator: "-").compactMap { Int($0) }
            if parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) {
                result[calendar.startOfDay(for: date)] = (Int(sqlite3_column_int64(s, 1)), Int(sqlite3_column_int64(s, 2)))
            }
        }
        return result
    }

    private func cachedTopMeetingWords(db: OpaquePointer?, sinceDay: String?) throws -> [InsightsWordFrequency] {
        let sql = "SELECT t.token,SUM(d.meeting_count) total FROM insights_daily_tokens d JOIN insights_tokens t ON t.id=d.token_id WHERE (? IS NULL OR d.day>=?) GROUP BY d.token_id HAVING total>0 ORDER BY total DESC,t.token ASC LIMIT 48"
        var s: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw lastError(db) }; defer { sqlite3_finalize(s) }
        bindOptionalText(sinceDay, at: 1, statement: s); bindOptionalText(sinceDay, at: 2, statement: s)
        var words: [InsightsWordFrequency] = []
        while sqlite3_step(s) == SQLITE_ROW { words.append(.init(word: stringColumn(s, index: 0), count: Int(sqlite3_column_int64(s, 1)))) }
        return words
    }

    // MARK: - Trinity aggregates (v2)

    /// Epoch-double bound for a "since day" (YYYY-MM-DD, cache-day form) so
    /// `created_at` (unix epoch) comparisons work. nil when unbounded.
    private static func sinceEpoch(sinceDay: String?, calendar: Calendar) -> Double? {
        guard let sinceDay else { return nil }
        let parts = sinceDay.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return date.timeIntervalSince1970
    }

    /// Finished-meeting aggregate (excludes transient `.recording` live rows,
    /// which are counted separately as `recordingMeetings`).
    func meetingActivityStats(db: OpaquePointer?, sinceDay: String?, calendar: Calendar) throws -> MeetingActivityStats {
        let since = sinceDay.map { "AND start_time >= '\($0)'" } ?? ""
        let finishedSQL = """
        SELECT
          COUNT(*),
          SUM(CASE WHEN meeting_status IN ('completed','note_only') THEN 1 ELSE 0 END),
          SUM(CASE WHEN meeting_status = 'failed' THEN 1 ELSE 0 END),
          COALESCE(SUM(duration_seconds), 0),
          COALESCE(SUM(word_count), 0),
          SUM(CASE WHEN saved_recording_path IS NOT NULL THEN 1 ELSE 0 END),
          SUM(CASE WHEN calendar_event_id IS NOT NULL OR calendar_occurrence_key IS NOT NULL THEN 1 ELSE 0 END),
          SUM(CASE WHEN follow_up_to_id IS NOT NULL THEN 1 ELSE 0 END),
          SUM(CASE WHEN source = 'audio_import' THEN 1 ELSE 0 END)
        FROM meetings
        WHERE (meeting_status IS NULL OR meeting_status != 'recording') \(since)
        """
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, finishedSQL, -1, &s, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { return MeetingActivityStats() }
        let total = Int(sqlite3_column_int64(s, 0))
        let completed = Int(sqlite3_column_int64(s, 1))
        let failed = Int(sqlite3_column_int64(s, 2))
        let duration = sqlite3_column_double(s, 3)
        let words = Int(sqlite3_column_int64(s, 4))
        let withRecording = Int(sqlite3_column_int64(s, 5))
        let linked = Int(sqlite3_column_int64(s, 6))
        let followUps = Int(sqlite3_column_int64(s, 7))
        let imported = Int(sqlite3_column_int64(s, 8))

        var recordingCount = 0
        let recordingSQL = "SELECT COUNT(*) FROM meetings WHERE meeting_status = 'recording' \(since)"
        var rs: OpaquePointer?
        if sqlite3_prepare_v2(db, recordingSQL, -1, &rs, nil) == SQLITE_OK {
            if sqlite3_step(rs) == SQLITE_ROW { recordingCount = Int(sqlite3_column_int64(rs, 0)) }
            sqlite3_finalize(rs)
        }

        return MeetingActivityStats(
            totalMeetings: total,
            completedMeetings: completed,
            failedMeetings: failed,
            recordingMeetings: recordingCount,
            totalDurationSeconds: duration,
            averageDurationSeconds: total > 0 ? duration / Double(total) : 0,
            totalWords: words,
            meetingsWithRecording: withRecording,
            meetingsLinkedToCalendar: linked,
            followUpMeetings: followUps,
            importedMeetings: imported
        )
    }

    /// Per-day finished-meeting activity across `startDate...endDate`,
    /// zero-filled so charts can draw contiguous bars.
    func meetingActivityBuckets(db: OpaquePointer?, sinceDay: String?, calendar: Calendar, startDate: Date, endDate: Date) throws -> [MeetingActivityBucket] {
        let since = sinceDay.map { "AND start_time >= '\($0)'" } ?? ""
        let sql = """
        SELECT start_time, COUNT(*), COALESCE(SUM(duration_seconds),0), COALESCE(SUM(word_count),0)
        FROM meetings
        WHERE (meeting_status IS NULL OR meeting_status != 'recording') \(since)
        GROUP BY start_time
        """
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(s) }
        var byDay: [Date: (meetings: Int, duration: Double, words: Int)] = [:]
        while sqlite3_step(s) == SQLITE_ROW {
            guard let d = parseISODate(stringColumn(s, index: 0)) else { continue }
            let day = calendar.startOfDay(for: d)
            let old = byDay[day] ?? (0, 0, 0)
            byDay[day] = (
                old.meetings + Int(sqlite3_column_int64(s, 1)),
                old.duration + sqlite3_column_double(s, 2),
                old.words + Int(sqlite3_column_int64(s, 3))
            )
        }
        var result: [MeetingActivityBucket] = []
        var cursor = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        while cursor <= end {
            let v = byDay[cursor] ?? (0, 0, 0)
            result.append(MeetingActivityBucket(bucketStart: cursor, meetings: v.meetings, durationSeconds: v.duration, words: v.words))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    /// Finished-meeting counts grouped by folder name.
    func meetingFolderStats(db: OpaquePointer?, sinceDay: String?) throws -> [MeetingFolderStat] {
        let since = sinceDay.map { "AND m.start_time >= '\($0)'" } ?? ""
        let sql = """
        SELECT COALESCE(mf.name, 'No folder'), COUNT(*)
        FROM meetings m LEFT JOIN meeting_folders mf ON mf.id = m.folder_id
        WHERE (m.meeting_status IS NULL OR m.meeting_status != 'recording') \(since)
        GROUP BY COALESCE(mf.name, 'No folder')
        ORDER BY COUNT(*) DESC
        """
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(s) }
        var out: [MeetingFolderStat] = []
        while sqlite3_step(s) == SQLITE_ROW {
            out.append(MeetingFolderStat(folderID: 0, folderName: stringColumn(s, index: 0), meetings: Int(sqlite3_column_int64(s, 1))))
        }
        return out
    }

    /// Most-recorded recurring meeting titles (excludes the generic default
    /// title "Meeting").
    func recurringMeetingStats(db: OpaquePointer?, sinceDay: String?, limit: Int = 10) throws -> [RecurringMeetingStat] {
        let since = sinceDay.map { "AND start_time >= '\($0)'" } ?? ""
        let sql = """
        SELECT title, COUNT(*) c FROM meetings
        WHERE (meeting_status IS NULL OR meeting_status != 'recording') AND title != 'Meeting' \(since)
        GROUP BY title HAVING c > 1 ORDER BY c DESC LIMIT ?
        """
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int(s, 1, Int32(limit))
        var out: [RecurringMeetingStat] = []
        while sqlite3_step(s) == SQLITE_ROW { out.append(.init(title: stringColumn(s, index: 0), count: Int(sqlite3_column_int64(s, 1)))) }
        return out
    }

    /// Appends one LLM usage event (summary / cleanup / title generation).
    public func recordLLMUsage(kind: String, backend: String, model: String, status: String, retryCount: Int = 0, characters: Int = 0, meetingID: Int64? = nil) {
        guard let db = try? openDatabase() else { return }
        defer { sqlite3_close(db) }
        let sql = "INSERT INTO llm_usage_log(kind,backend,model,status,retry_count,characters,meeting_id,created_at) VALUES (?,?,?,?,?,?,?,?)"
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, (kind as NSString).utf8String, -1, nil)
        sqlite3_bind_text(s, 2, (backend as NSString).utf8String, -1, nil)
        sqlite3_bind_text(s, 3, (model as NSString).utf8String, -1, nil)
        sqlite3_bind_text(s, 4, (status as NSString).utf8String, -1, nil)
        sqlite3_bind_int(s, 5, Int32(retryCount))
        sqlite3_bind_int(s, 6, Int32(characters))
        if let meetingID { sqlite3_bind_int64(s, 7, meetingID) } else { sqlite3_bind_null(s, 7) }
        sqlite3_bind_double(s, 8, Date().timeIntervalSince1970)
        sqlite3_step(s)
    }

    /// LLM usage aggregates + per-day runs. `sinceDay` is a cache-day string
    /// ("YYYY-MM-DD"); nil = lifetime.
    func llmUsageStats(db: OpaquePointer?, sinceDay: String?, calendar: Calendar) throws -> (stats: LLMUsageStats, byDay: [LLMUsageDay]) {
        let sinceEpoch = Self.sinceEpoch(sinceDay: sinceDay, calendar: calendar)
        let since = sinceEpoch.map { "AND created_at >= \($0)" } ?? ""

        let aggSQL = """
        SELECT COUNT(*),
               SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END),
               SUM(CASE WHEN status != 'success' THEN 1 ELSE 0 END),
               COALESCE(SUM(characters), 0)
        FROM llm_usage_log WHERE 1=1 \(since)
        """
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, aggSQL, -1, &s, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(s) }
        var stats = LLMUsageStats()
        if sqlite3_step(s) == SQLITE_ROW {
            stats = LLMUsageStats(
                totalRuns: Int(sqlite3_column_int64(s, 0)),
                successfulRuns: Int(sqlite3_column_int64(s, 1)),
                failedRuns: Int(sqlite3_column_int64(s, 2)),
                totalCharacters: Int(sqlite3_column_int64(s, 3))
            )
        }

        let kindSQL = "SELECT kind, COUNT(*) FROM llm_usage_log WHERE 1=1 \(since) GROUP BY kind"
        var ks: OpaquePointer?
        guard sqlite3_prepare_v2(db, kindSQL, -1, &ks, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(ks) }
        var kinds: [String: Int] = [:]
        while sqlite3_step(ks) == SQLITE_ROW { kinds[stringColumn(ks, index: 0)] = Int(sqlite3_column_int64(ks, 1)) }

        let backendSQL = "SELECT backend, COUNT(*) FROM llm_usage_log WHERE 1=1 \(since) GROUP BY backend"
        var bs: OpaquePointer?
        guard sqlite3_prepare_v2(db, backendSQL, -1, &bs, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(bs) }
        var backends: [String: Int] = [:]
        while sqlite3_step(bs) == SQLITE_ROW { backends[stringColumn(bs, index: 0)] = Int(sqlite3_column_int64(bs, 1)) }

        stats = LLMUsageStats(
            totalRuns: stats.totalRuns,
            successfulRuns: stats.successfulRuns,
            failedRuns: stats.failedRuns,
            totalCharacters: stats.totalCharacters,
            byKind: kinds,
            byBackend: backends
        )

        let daySQL = "SELECT created_at, COUNT(*) FROM llm_usage_log WHERE 1=1 \(since) GROUP BY CAST(created_at / 86400 AS INT) ORDER BY 1"
        var ds: OpaquePointer?
        guard sqlite3_prepare_v2(db, daySQL, -1, &ds, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(ds) }
        var days: [LLMUsageDay] = []
        while sqlite3_step(ds) == SQLITE_ROW {
            let epochDay = floor(sqlite3_column_double(ds, 0) / 86400) * 86400
            days.append(LLMUsageDay(day: Date(timeIntervalSince1970: epochDay), runs: Int(sqlite3_column_int64(ds, 1))))
        }
        return (stats, days)
    }

    private func meetingStreakDays(db: OpaquePointer?, calendar: Calendar) throws -> (current: Int, longest: Int) {
        var s: OpaquePointer?; guard sqlite3_prepare_v2(db, "SELECT DISTINCT day FROM insights_daily_cache WHERE meetings > 0 ORDER BY day", -1, &s, nil) == SQLITE_OK else { throw lastError(db) }; defer { sqlite3_finalize(s) }
        var days: [Date] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let parts = stringColumn(s, index: 0).split(separator: "-").compactMap { Int($0) }
            if parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) {
                days.append(calendar.startOfDay(for: date))
            }
        }
        return Self.computeStreak(days: days, calendar: calendar)
    }

    public func deleteMeeting(id: Int64) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try exec("BEGIN IMMEDIATE", db: db)

        do {
            try deleteResumeSnapshot(meetingID: id, db: db)
            try deleteLiveTranscriptCheckpoints(meetingID: id, db: db)
            try deleteMeetingParticipants(meetingID: id, db: db)
            var statement: OpaquePointer?
            let sql = "DELETE FROM meetings WHERE id = ?"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw lastError(db)
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, id)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw lastError(db)
            }
            guard sqlite3_changes(db) > 0 else {
                throw DictationStoreError.meetingNotFound(id: id)
            }
            try detachFollowUpSuccessors(of: id, db: db)
            try exec("COMMIT", db: db)
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    public func clearMeetings() throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try exec("DELETE FROM meeting_resume_snapshots", db: db)
        try exec("DELETE FROM meeting_transcript_checkpoints", db: db)
        try exec("DELETE FROM meeting_participants", db: db)
        try exec("DELETE FROM meeting_event_links", db: db)
        try exec("DELETE FROM meetings", db: db)
    }

    public func updateMeeting(id: Int64, title: String, formattedNotes: String) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "UPDATE meetings SET title = ?, formatted_notes = ?, updated_at = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (title as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (formattedNotes as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 4, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    public func updateMeetingNotes(id: Int64, formattedNotes: String) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "UPDATE meetings SET formatted_notes = ?, updated_at = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (formattedNotes as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    public func updateMeetingTranscript(id: Int64, rawTranscript: String) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let manualNotes = try manualNotesForMeeting(id: id, db: db)
        let wordCount = Self.countWords(in: rawTranscript) + Self.countWords(in: manualNotes)
        let sql = "UPDATE meetings SET raw_transcript = ?, word_count = ?, updated_at = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (rawTranscript as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 2, Int32(wordCount))
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 4, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        guard sqlite3_changes(db) > 0 else {
            throw DictationStoreError.meetingNotFound(id: id)
        }
        try deleteLiveTranscriptCheckpoints(meetingID: id, db: db)
        try deleteResumeSnapshot(meetingID: id, db: db)
    }

    /// Returns the stored raw transcript for a meeting, or `nil` if the meeting does not exist.
    /// Used by the resume-recording flow to append new transcript onto the prior one.
    public func meetingRawTranscript(id: Int64) throws -> String? {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = """
        SELECT raw_transcript
        FROM meetings
        WHERE id = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return stringColumn(statement, index: 0)
    }

    /// Atomically records the prior completed state and reopens the same row for resume recording.
    /// Returns the transcript snapshot to use for in-memory merge on a normal stop.
    public func prepareMeetingForResume(id: Int64) throws -> String {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        do {
            let snapshot = try resumeSnapshotSource(meetingID: id, db: db)
            try upsertResumeSnapshot(meetingID: id, snapshot: snapshot, db: db)
            try deleteLiveTranscriptCheckpoints(meetingID: id, db: db)
            try updateMeetingStatus(id: id, status: .recording, db: db)
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw lastError(db)
            }
            return snapshot.rawTranscript
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    public func appendLiveTranscriptCheckpoints(meetingID: Int64, entries: [LiveTranscriptCheckpointEntry]) throws {
        let trimmedEntries = entries.compactMap { entry -> LiveTranscriptCheckpointEntry? in
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return LiveTranscriptCheckpointEntry(
                timestampLabel: entry.timestampLabel,
                speaker: entry.speaker,
                startSeconds: entry.startSeconds,
                endSeconds: entry.endSeconds,
                text: text
            )
        }
        guard !trimmedEntries.isEmpty else { return }

        let db = try openDatabase()
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw lastError(db)
        }

        do {
            let sql = """
            INSERT INTO meeting_transcript_checkpoints
            (meeting_id, timestamp_label, speaker, start_seconds, end_seconds, text)
            VALUES (?, ?, ?, ?, ?, ?)
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw lastError(db)
            }
            defer { sqlite3_finalize(statement) }

            for entry in trimmedEntries {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_int64(statement, 1, meetingID)
                sqlite3_bind_text(statement, 2, (entry.timestampLabel as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 3, (entry.speaker as NSString).utf8String, -1, nil)
                sqlite3_bind_double(statement, 4, entry.startSeconds)
                sqlite3_bind_double(statement, 5, entry.endSeconds)
                sqlite3_bind_text(statement, 6, (entry.text as NSString).utf8String, -1, nil)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw lastError(db)
                }
            }

            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw lastError(db)
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    public func liveTranscriptCheckpointText(meetingID: Int64) throws -> String? {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        return try liveTranscriptCheckpointText(meetingID: meetingID, db: db)
    }

    @discardableResult
    public func recoverLiveMeetingFromTranscriptCheckpoints(id: Int64) throws -> Bool {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        if let snapshot = try resumeSnapshot(meetingID: id, db: db) {
            return try recoverResumedMeeting(id: id, snapshot: snapshot, db: db)
        }
        guard let transcript = try liveTranscriptCheckpointText(meetingID: id, db: db) else {
            return false
        }

        let manualNotes = try manualNotesForMeeting(id: id, db: db)
        let formattedNotes = """
        ## Raw Transcript

        Recovered from live transcript checkpoints after the meeting did not finalize normally. This fallback may be incomplete and may not include final diarization or reconciliation.

        \(transcript)
        """
        let wordCount = Self.countWords(in: transcript) + Self.countWords(in: manualNotes)
        let durationSeconds = try liveTranscriptCheckpointDuration(meetingID: id, db: db)
        let endTime = try liveMeetingFallbackEndTime(meetingID: id, durationSeconds: durationSeconds, db: db)
        let sql = """
        UPDATE meetings
        SET end_time = ?, duration_seconds = ?, raw_transcript = ?, formatted_notes = ?, meeting_status = ?, word_count = ?, updated_at = ?
        WHERE id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        bindOptionalText(endTime, at: 1, statement: statement)
        sqlite3_bind_double(statement, 2, durationSeconds)
        sqlite3_bind_text(statement, 3, (transcript as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (formattedNotes as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 5, (MeetingStatus.completed.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 6, Int32(wordCount))
        sqlite3_bind_double(statement, 7, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 8, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        guard sqlite3_changes(db) > 0 else {
            throw DictationStoreError.meetingNotFound(id: id)
        }
        try deleteLiveTranscriptCheckpoints(meetingID: id, db: db)
        return true
    }

    public func updateMeetingManualNotes(id: Int64, manualNotes: String) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "UPDATE meetings SET manual_notes = ?, updated_at = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (manualNotes as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        guard sqlite3_changes(db) > 0 else {
            throw DictationStoreError.meetingNotFound(id: id)
        }
    }

    public func updateMeetingStatus(id: Int64, status: MeetingStatus) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try updateMeetingStatus(id: id, status: status, db: db)
    }

    @discardableResult
    public func restoreResumedMeetingIfNeeded(id: Int64) throws -> Bool {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        guard let snapshot = try resumeSnapshot(meetingID: id, db: db) else { return false }
        try restoreResumedMeeting(id: id, snapshot: snapshot, db: db)
        return true
    }

    private func updateMeetingStatus(id: Int64, status: MeetingStatus, db: OpaquePointer?) throws {
        let wordCount = try manualNoteWordCountIfNeeded(for: status, id: id, db: db)
        let sql = wordCount == nil
            ? "UPDATE meetings SET meeting_status = ?, updated_at = ? WHERE id = ?"
            : "UPDATE meetings SET meeting_status = ?, word_count = ?, updated_at = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (status.rawValue as NSString).utf8String, -1, nil)
        if let wordCount {
            sqlite3_bind_int(statement, 2, Int32(wordCount))
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
            sqlite3_bind_int64(statement, 4, id)
        } else {
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            sqlite3_bind_int64(statement, 3, id)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        guard sqlite3_changes(db) > 0 else {
            throw DictationStoreError.meetingNotFound(id: id)
        }
    }

    public func completeLiveMeeting(
        id: Int64,
        title: String,
        calendarEventID: String?,
        startTime: Date,
        endTime: Date,
        durationSeconds explicitDurationSeconds: Double? = nil,
        rawTranscript: String,
        formattedNotes: String,
        manualNotes: String? = nil,
        micAudioPath: String?,
        systemAudioPath: String?,
        savedRecordingPath: String? = nil,
        selectedTemplateID: String? = nil,
        selectedTemplateName: String? = nil,
        selectedTemplateKind: MeetingTemplateKind? = nil,
        selectedTemplatePrompt: String? = nil,
        visualContext: String? = nil
    ) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        // A nil manualNotes keeps the currently stored value (the row already
        // holds debounced live writes); an explicit value (the stop-time
        // snapshot) is authoritative and replaces whatever was last written.
        let resolvedManualNotes: String
        if let manualNotes {
            resolvedManualNotes = manualNotes
        } else {
            resolvedManualNotes = try manualNotesForMeeting(id: id, db: db)
        }
        // include_notes_in_summary is a global setting now (AppConfig); the
        // column stays at its default 0 on this write path.
        let sql = """
        UPDATE meetings
        SET title = ?, calendar_event_id = ?, start_time = ?, end_time = ?, duration_seconds = ?, raw_transcript = ?, formatted_notes = ?, manual_notes = ?, mic_audio_path = ?, system_audio_path = ?, saved_recording_path = ?, meeting_status = ?, word_count = ?, selected_template_id = ?, selected_template_name = ?, selected_template_kind = ?, selected_template_prompt = ?, visual_context = ?, include_notes_in_summary = ?, updated_at = ?
        WHERE id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }

        let formatter = ISO8601DateFormatter()
        let startString = formatter.string(from: startTime)
        let endString = formatter.string(from: endTime)
        let durationSeconds = max(explicitDurationSeconds ?? endTime.timeIntervalSince(startTime), 0)
        let wordCount = Self.countWords(in: rawTranscript) + Self.countWords(in: resolvedManualNotes)

        sqlite3_bind_text(statement, 1, (title as NSString).utf8String, -1, nil)
        bindOptionalText(calendarEventID, at: 2, statement: statement)
        sqlite3_bind_text(statement, 3, (startString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (endString as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 5, durationSeconds)
        sqlite3_bind_text(statement, 6, (rawTranscript as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 7, (formattedNotes as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 8, (resolvedManualNotes as NSString).utf8String, -1, nil)
        bindOptionalText(micAudioPath, at: 9, statement: statement)
        bindOptionalText(systemAudioPath, at: 10, statement: statement)
        bindOptionalText(savedRecordingPath, at: 11, statement: statement)
        sqlite3_bind_text(statement, 12, (MeetingStatus.completed.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 13, Int32(wordCount))
        bindOptionalText(selectedTemplateID, at: 14, statement: statement)
        bindOptionalText(selectedTemplateName, at: 15, statement: statement)
        bindOptionalText(selectedTemplateKind?.rawValue, at: 16, statement: statement)
        bindOptionalText(selectedTemplatePrompt, at: 17, statement: statement)
        bindOptionalText(visualContext, at: 18, statement: statement)
        sqlite3_bind_int(statement, 19, 0)
        sqlite3_bind_double(statement, 20, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 21, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        guard sqlite3_changes(db) > 0 else {
            throw DictationStoreError.meetingNotFound(id: id)
        }
        try deleteLiveTranscriptCheckpoints(meetingID: id, db: db)
        try deleteResumeSnapshot(meetingID: id, db: db)
    }

    private func manualNoteWordCountIfNeeded(for status: MeetingStatus, id: Int64, db: OpaquePointer?) throws -> Int? {
        switch status {
        case .noteOnly, .failed:
            return Self.countWords(in: try manualNotesForMeeting(id: id, db: db))
        case .recording, .processing, .completed:
            return nil
        }
    }

    private func manualNotesForMeeting(id: Int64, db: OpaquePointer?) throws -> String {
        let sql = "SELECT manual_notes FROM meetings WHERE id = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DictationStoreError.meetingNotFound(id: id)
        }
        return stringColumn(statement, index: 0)
    }

    private func liveTranscriptCheckpointText(meetingID: Int64, db: OpaquePointer?) throws -> String? {
        let sql = """
        SELECT timestamp_label, speaker, text
        FROM meeting_transcript_checkpoints
        WHERE meeting_id = ?
        ORDER BY start_seconds ASC, id ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)

        var lines: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = stringColumn(statement, index: 0)
            let speaker = stringColumn(statement, index: 1)
            let text = stringColumn(statement, index: 2).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append("[\(timestamp)] \(speaker): \(text)")
        }

        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    private func liveTranscriptCheckpointDuration(meetingID: Int64, db: OpaquePointer?) throws -> Double {
        let sql = """
        SELECT COALESCE(MAX(end_seconds), 0)
        FROM meeting_transcript_checkpoints
        WHERE meeting_id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw lastError(db)
        }
        return max(sqlite3_column_double(statement, 0), 0)
    }

    private func liveMeetingFallbackEndTime(meetingID: Int64, durationSeconds: Double, db: OpaquePointer?) throws -> String? {
        guard durationSeconds > 0 else { return nil }
        let sql = "SELECT start_time FROM meetings WHERE id = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DictationStoreError.meetingNotFound(id: meetingID)
        }
        let startTimeString = stringColumn(statement, index: 0)
        guard let startTime = ISO8601DateFormatter().date(from: startTimeString) else {
            return nil
        }
        return ISO8601DateFormatter().string(from: startTime.addingTimeInterval(durationSeconds))
    }

    private struct ResumeSnapshot {
        var rawTranscript: String
        var formattedNotes: String
        var durationSeconds: Double
        var startTime: String
        var endTime: String?
    }

    private func resumeSnapshotSource(meetingID: Int64, db: OpaquePointer?) throws -> ResumeSnapshot {
        let sql = """
        SELECT raw_transcript, formatted_notes, COALESCE(duration_seconds, 0), start_time, end_time
        FROM meetings
        WHERE id = ? AND meeting_status = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        sqlite3_bind_text(statement, 2, (MeetingStatus.completed.rawValue as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DictationStoreError.meetingNotFound(id: meetingID)
        }
        return ResumeSnapshot(
            rawTranscript: stringColumn(statement, index: 0),
            formattedNotes: stringColumn(statement, index: 1),
            durationSeconds: max(sqlite3_column_double(statement, 2), 0),
            startTime: stringColumn(statement, index: 3),
            endTime: optionalStringColumn(statement, index: 4)
        )
    }

    private func upsertResumeSnapshot(meetingID: Int64, snapshot: ResumeSnapshot, db: OpaquePointer?) throws {
        let sql = """
        INSERT INTO meeting_resume_snapshots
            (meeting_id, raw_transcript, formatted_notes, duration_seconds, start_time, end_time, created_at)
        VALUES (?, ?, ?, ?, ?, ?, datetime('now'))
        ON CONFLICT(meeting_id) DO UPDATE SET
            raw_transcript = excluded.raw_transcript,
            formatted_notes = excluded.formatted_notes,
            duration_seconds = excluded.duration_seconds,
            start_time = excluded.start_time,
            end_time = excluded.end_time,
            created_at = excluded.created_at
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        sqlite3_bind_text(statement, 2, (snapshot.rawTranscript as NSString).utf8String, -1, nil)
        bindOptionalText(snapshot.formattedNotes, at: 3, statement: statement)
        sqlite3_bind_double(statement, 4, snapshot.durationSeconds)
        sqlite3_bind_text(statement, 5, (snapshot.startTime as NSString).utf8String, -1, nil)
        bindOptionalText(snapshot.endTime, at: 6, statement: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    private func resumeSnapshot(meetingID: Int64, db: OpaquePointer?) throws -> ResumeSnapshot? {
        let sql = """
        SELECT raw_transcript, formatted_notes, duration_seconds, start_time, end_time
        FROM meeting_resume_snapshots
        WHERE meeting_id = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return ResumeSnapshot(
            rawTranscript: stringColumn(statement, index: 0),
            formattedNotes: stringColumn(statement, index: 1),
            durationSeconds: max(sqlite3_column_double(statement, 2), 0),
            startTime: stringColumn(statement, index: 3),
            endTime: optionalStringColumn(statement, index: 4)
        )
    }

    @discardableResult
    private func recoverResumedMeeting(id: Int64, snapshot: ResumeSnapshot, db: OpaquePointer?) throws -> Bool {
        guard let checkpointTranscript = try liveTranscriptCheckpointText(meetingID: id, db: db) else {
            try restoreResumedMeeting(id: id, snapshot: snapshot, db: db)
            return true
        }

        let combined = combinedResumeRecoveryTranscript(prior: snapshot.rawTranscript, new: checkpointTranscript)
        let manualNotes = try manualNotesForMeeting(id: id, db: db)
        let resumedDurationSeconds = try liveTranscriptCheckpointDuration(meetingID: id, db: db)
        let durationSeconds = snapshot.durationSeconds + resumedDurationSeconds
        let endTime = snapshotEndTime(
            startTimeString: snapshot.startTime,
            fallbackEndTime: snapshot.endTime,
            durationSeconds: durationSeconds
        )
        let formattedNotes = resumedRecoveryNotes(priorNotes: snapshot.formattedNotes, combinedTranscript: combined)
        let wordCount = Self.countWords(in: combined) + Self.countWords(in: manualNotes)
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        do {
            try completeResumedRecovery(
                id: id,
                snapshot: snapshot,
                rawTranscript: combined,
                formattedNotes: formattedNotes,
                endTime: endTime,
                durationSeconds: durationSeconds,
                wordCount: wordCount,
                db: db
            )
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw lastError(db)
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
        return true
    }

    private func restoreResumedMeeting(id: Int64, snapshot: ResumeSnapshot, db: OpaquePointer?) throws {
        let manualNotes = try manualNotesForMeeting(id: id, db: db)
        let wordCount = Self.countWords(in: snapshot.rawTranscript) + Self.countWords(in: manualNotes)
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        do {
            try completeResumedRecovery(
                id: id,
                snapshot: snapshot,
                rawTranscript: snapshot.rawTranscript,
                formattedNotes: snapshot.formattedNotes,
                endTime: snapshot.endTime,
                durationSeconds: snapshot.durationSeconds,
                wordCount: wordCount,
                db: db
            )
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw lastError(db)
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func completeResumedRecovery(
        id: Int64,
        snapshot: ResumeSnapshot,
        rawTranscript: String,
        formattedNotes: String,
        endTime: String?,
        durationSeconds: Double,
        wordCount: Int,
        db: OpaquePointer?
    ) throws {
        let sql = """
        UPDATE meetings
        SET start_time = ?, end_time = ?, duration_seconds = ?, raw_transcript = ?, formatted_notes = ?, meeting_status = ?, word_count = ?, updated_at = ?
        WHERE id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (snapshot.startTime as NSString).utf8String, -1, nil)
        bindOptionalText(endTime, at: 2, statement: statement)
        sqlite3_bind_double(statement, 3, durationSeconds)
        sqlite3_bind_text(statement, 4, (rawTranscript as NSString).utf8String, -1, nil)
        bindOptionalText(formattedNotes, at: 5, statement: statement)
        sqlite3_bind_text(statement, 6, (MeetingStatus.completed.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 7, Int32(wordCount))
        sqlite3_bind_double(statement, 8, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 9, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        guard sqlite3_changes(db) > 0 else {
            throw DictationStoreError.meetingNotFound(id: id)
        }
        try deleteLiveTranscriptCheckpoints(meetingID: id, db: db)
        try deleteResumeSnapshot(meetingID: id, db: db)
    }

    private func combinedResumeRecoveryTranscript(prior: String, new: String) -> String {
        let trimmedPrior = prior.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNew = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNew.isEmpty else { return prior }
        guard !trimmedPrior.isEmpty else { return new }
        return prior + "\n\n— Resumed —\n\n" + new
    }

    private func resumedRecoveryNotes(priorNotes: String, combinedTranscript: String) -> String {
        let recoveryNotes = """
        ## Raw Transcript

        Recovered from live transcript checkpoints after a resumed meeting did not finalize normally. This fallback may be incomplete and may not include final diarization or reconciliation.

        \(combinedTranscript)
        """
        let trimmedPriorNotes = priorNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPriorNotes.isEmpty else { return recoveryNotes }
        return trimmedPriorNotes + "\n\n" + recoveryNotes
    }

    private func snapshotEndTime(startTimeString: String, fallbackEndTime: String?, durationSeconds: Double) -> String? {
        guard durationSeconds > 0,
              let startTime = ISO8601DateFormatter().date(from: startTimeString) else {
            return fallbackEndTime
        }
        return ISO8601DateFormatter().string(from: startTime.addingTimeInterval(durationSeconds))
    }

    private func deleteResumeSnapshot(meetingID: Int64, db: OpaquePointer?) throws {
        let sql = "DELETE FROM meeting_resume_snapshots WHERE meeting_id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    private func deleteLiveTranscriptCheckpoints(meetingID: Int64, db: OpaquePointer?) throws {
        let sql = "DELETE FROM meeting_transcript_checkpoints WHERE meeting_id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    private func deleteMeetingParticipants(meetingID: Int64, db: OpaquePointer?) throws {
        let sql = "DELETE FROM meeting_participants WHERE meeting_id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    public func updateMeetingSummary(
        id: Int64,
        title: String,
        formattedNotes: String,
        selectedTemplateID: String,
        selectedTemplateName: String,
        selectedTemplateKind: MeetingTemplateKind,
        selectedTemplatePrompt: String
    ) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = """
        UPDATE meetings
        SET title = ?, formatted_notes = ?, selected_template_id = ?, selected_template_name = ?, selected_template_kind = ?, selected_template_prompt = ?, updated_at = ?
        WHERE id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (title as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (formattedNotes as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (selectedTemplateID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (selectedTemplateName as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 5, (selectedTemplateKind.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 6, (selectedTemplatePrompt as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 7, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 8, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    public func updateMeetingTranscriptAndSummary(
        id: Int64,
        rawTranscript: String,
        formattedNotes: String,
        selectedTemplateID: String,
        selectedTemplateName: String,
        selectedTemplateKind: MeetingTemplateKind,
        selectedTemplatePrompt: String
    ) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let manualNotes = try manualNotesForMeeting(id: id, db: db)
        let wordCount = Self.countWords(in: rawTranscript) + Self.countWords(in: manualNotes)
        let sql = """
        UPDATE meetings
        SET raw_transcript = ?, formatted_notes = ?, meeting_status = ?, word_count = ?, selected_template_id = ?, selected_template_name = ?, selected_template_kind = ?, selected_template_prompt = ?, updated_at = ?
        WHERE id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (rawTranscript as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (formattedNotes as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (MeetingStatus.completed.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 4, Int32(wordCount))
        sqlite3_bind_text(statement, 5, (selectedTemplateID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 6, (selectedTemplateName as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 7, (selectedTemplateKind.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 8, (selectedTemplatePrompt as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 9, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 10, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        guard sqlite3_changes(db) > 0 else {
            throw DictationStoreError.meetingNotFound(id: id)
        }
    }

    public func updateMeetingTitle(id: Int64, title: String) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "UPDATE meetings SET title = ?, updated_at = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (title as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    /// Adopts a calendar event as a meeting's *primary* calendar identity.
    /// Used when a meeting that was never recorded from a calendar row (a
    /// quick/manual meeting) is first attached to an event via "Add to
    /// Event": writing the same calendar columns a recording would have
    /// written keeps every linkage consumer (calendar rows, occurrence
    /// matching, title sync) working for the attached meeting.
    /// Clears a meeting's inline primary calendar identity (all six
    /// calendar columns to NULL), detaching it from the event it was
    /// recorded from or first attached to. Explicit link rows are untouched
    /// (remove those separately); callers clear only when no attachment of
    /// any kind should remain.
    public func clearMeetingCalendarLink(id: Int64) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = """
        UPDATE meetings
        SET calendar_event_id = NULL,
            calendar_occurrence_key = NULL,
            calendar_source = NULL,
            calendar_id = NULL,
            calendar_series_id = NULL,
            calendar_occurrence_start = NULL,
            updated_at = ?
        WHERE id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 2, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    public func updateMeetingCalendarLink(
        id: Int64,
        eventID: String,
        occurrence: CalendarOccurrenceReference?
    ) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = """
        UPDATE meetings
        SET calendar_event_id = ?,
            calendar_occurrence_key = ?,
            calendar_source = ?,
            calendar_id = ?,
            calendar_series_id = ?,
            calendar_occurrence_start = ?,
            updated_at = ?
        WHERE id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (eventID as NSString).utf8String, -1, nil)
        bindOptionalText(occurrence?.identityKey, at: 2, statement: statement)
        if let occurrence {
            sqlite3_bind_text(
                statement,
                3,
                (occurrence.provider.rawValue as NSString).utf8String,
                -1,
                nil
            )
        } else {
            sqlite3_bind_null(statement, 3)
        }
        bindOptionalText(occurrence?.calendarID, at: 4, statement: statement)
        bindOptionalText(occurrence?.seriesID, at: 5, statement: statement)
        if let occurrence {
            sqlite3_bind_double(statement, 6, occurrence.originalStartTime.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        sqlite3_bind_double(statement, 7, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 8, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        guard sqlite3_changes(db) > 0 else {
            throw DictationStoreError.meetingNotFound(id: id)
        }
    }

    public func updateMeetingSavedRecordingPath(id: Int64, path: String?) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "UPDATE meetings SET saved_recording_path = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        bindOptionalText(path, at: 1, statement: statement)
        sqlite3_bind_int64(statement, 2, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    @discardableResult
    public func createFolder(name: String, parentID: Int64? = nil) throws -> Int64 {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "INSERT INTO meeting_folders (name, parent_id) VALUES (?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
        if let parentID {
            sqlite3_bind_int64(statement, 2, parentID)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        return sqlite3_last_insert_rowid(db)
    }

    public func renameFolder(id: Int64, name: String) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "UPDATE meeting_folders SET name = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(statement, 2, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    public func deleteFolder(id: Int64) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw lastError(db)
        }

        do {
            // Look up the deleted folder's parent so children can be reparented.
            var parentID: Int64?
            var pStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT parent_id FROM meeting_folders WHERE id = ?", -1, &pStmt, nil) == SQLITE_OK else {
                throw lastError(db)
            }
            defer { sqlite3_finalize(pStmt) }
            sqlite3_bind_int64(pStmt, 1, id)
            if sqlite3_step(pStmt) == SQLITE_ROW, sqlite3_column_type(pStmt, 0) != SQLITE_NULL {
                parentID = sqlite3_column_int64(pStmt, 0)
            }

            var childIDs: [Int64] = []
            var childStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT id FROM meeting_folders WHERE parent_id = ?", -1, &childStmt, nil) == SQLITE_OK else {
                throw lastError(db)
            }
            sqlite3_bind_int64(childStmt, 1, id)
            while sqlite3_step(childStmt) == SQLITE_ROW {
                childIDs.append(sqlite3_column_int64(childStmt, 0))
            }
            sqlite3_finalize(childStmt)

            func folderExists(_ folderID: Int64) throws -> Bool {
                var existsStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT 1 FROM meeting_folders WHERE id = ? LIMIT 1", -1, &existsStmt, nil) == SQLITE_OK else {
                    throw lastError(db)
                }
                defer { sqlite3_finalize(existsStmt) }
                sqlite3_bind_int64(existsStmt, 1, folderID)
                return sqlite3_step(existsStmt) == SQLITE_ROW
            }

            func safeReplacementParent(for childID: Int64) throws -> Int64? {
                guard let parentID,
                      parentID != id,
                      parentID != childID,
                      try folderExists(parentID)
                else {
                    return nil
                }
                let descendants = try descendantFolderIDs(of: childID, db: db)
                return descendants.contains(parentID) ? nil : parentID
            }

            var reparentStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE meeting_folders SET parent_id = ? WHERE id = ?", -1, &reparentStmt, nil) == SQLITE_OK else {
                throw lastError(db)
            }
            defer { sqlite3_finalize(reparentStmt) }
            for childID in childIDs where childID != id {
                sqlite3_reset(reparentStmt)
                sqlite3_clear_bindings(reparentStmt)
                if let replacementParent = try safeReplacementParent(for: childID) {
                    sqlite3_bind_int64(reparentStmt, 1, replacementParent)
                } else {
                    sqlite3_bind_null(reparentStmt, 1)
                }
                sqlite3_bind_int64(reparentStmt, 2, childID)
                guard sqlite3_step(reparentStmt) == SQLITE_DONE else {
                    throw lastError(db)
                }
            }

            // Move meetings in deleted folder to unfiled.
            var s1: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE meetings SET folder_id = NULL WHERE folder_id = ?", -1, &s1, nil) == SQLITE_OK else {
                throw lastError(db)
            }
            defer { sqlite3_finalize(s1) }
            sqlite3_bind_int64(s1, 1, id)
            guard sqlite3_step(s1) == SQLITE_DONE else {
                throw lastError(db)
            }

            var s2: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM meeting_folders WHERE id = ?", -1, &s2, nil) == SQLITE_OK else {
                throw lastError(db)
            }
            defer { sqlite3_finalize(s2) }
            sqlite3_bind_int64(s2, 1, id)
            guard sqlite3_step(s2) == SQLITE_DONE else {
                throw lastError(db)
            }

            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw lastError(db)
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    public func listFolders() throws -> [MeetingFolder] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        return try listFoldersInternal(db: db)
    }

    public func moveMeeting(id: Int64, toFolder folderID: Int64?) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "UPDATE meetings SET folder_id = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        if let folderID {
            sqlite3_bind_int64(statement, 1, folderID)
        } else {
            sqlite3_bind_null(statement, 1)
        }
        sqlite3_bind_int64(statement, 2, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    public func moveFolder(id: Int64, toParent newParentID: Int64?) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        // Prevent moving a folder into itself or one of its own descendants.
        if let newParentID {
            let descendants = try descendantFolderIDs(of: id, db: db)
            guard newParentID != id, !descendants.contains(newParentID) else { return }
        }
        let sql = "UPDATE meeting_folders SET parent_id = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        if let newParentID {
            sqlite3_bind_int64(statement, 1, newParentID)
        } else {
            sqlite3_bind_null(statement, 1)
        }
        sqlite3_bind_int64(statement, 2, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    public func descendantFolderIDs(of folderID: Int64) throws -> Set<Int64> {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        return try descendantFolderIDs(of: folderID, db: db)
    }

    func descendantFolderIDs(of folderID: Int64, db: OpaquePointer?) throws -> Set<Int64> {
        // BFS traversal to collect all descendant folder IDs.
        var result: Set<Int64> = []
        var queue: [Int64] = [folderID]
        let sql = "SELECT id FROM meeting_folders WHERE parent_id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        while !queue.isEmpty {
            let current = queue.removeFirst()
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int64(statement, 1, current)
            while sqlite3_step(statement) == SQLITE_ROW {
                let childID = sqlite3_column_int64(statement, 0)
                if childID != folderID, result.insert(childID).inserted {
                    queue.append(childID)
                }
            }
        }
        return result
    }

    public func databasePath() -> URL {
        databaseURL
    }

    private func detachFollowUpSuccessors(of predecessorID: Int64, db: OpaquePointer?) throws {
        let sql = """
        UPDATE meetings
        SET follow_up_to_id = NULL,
            updated_at = ?
        WHERE follow_up_to_id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 2, predecessorID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    private func makeMeetingRecord(_ statement: OpaquePointer?) -> MeetingRecord {
        let folderID: Int64? = sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 7)
        let calendarEventID: String? = sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : stringColumn(statement, index: 8)
        let micAudioPath: String? = sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil : stringColumn(statement, index: 9)
        let systemAudioPath: String? = sqlite3_column_type(statement, 10) == SQLITE_NULL ? nil : stringColumn(statement, index: 10)
        let savedRecordingPath: String? = sqlite3_column_type(statement, 11) == SQLITE_NULL ? nil : stringColumn(statement, index: 11)
        let status = MeetingStatus(rawValue: stringColumn(statement, index: 12)) ?? .completed
        let manualNotes = stringColumn(statement, index: 13)
        let selectedTemplateID: String? = sqlite3_column_type(statement, 14) == SQLITE_NULL ? nil : stringColumn(statement, index: 14)
        let selectedTemplateName: String? = sqlite3_column_type(statement, 15) == SQLITE_NULL ? nil : stringColumn(statement, index: 15)
        let selectedTemplateKind: MeetingTemplateKind? = sqlite3_column_type(statement, 16) == SQLITE_NULL
            ? nil
            : MeetingTemplateKind(rawValue: stringColumn(statement, index: 16))
        let selectedTemplatePrompt: String? = sqlite3_column_type(statement, 17) == SQLITE_NULL ? nil : stringColumn(statement, index: 17)
        let source = MeetingSource(rawValue: stringColumn(statement, index: 18)) ?? .meeting
        let followUpToID: Int64? = sqlite3_column_type(statement, 19) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 19)
        let calendarSource = optionalStringColumn(statement, index: 21)
            .flatMap(CalendarOccurrenceReference.Provider.init(rawValue:))
        let calendarOccurrenceStart: Date? = sqlite3_column_type(statement, 24) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, 24))
        let calendarOccurrence: CalendarOccurrenceReference?
        if let calendarSource, let calendarEventID, let calendarOccurrenceStart {
            calendarOccurrence = CalendarOccurrenceReference(
                provider: calendarSource,
                calendarID: optionalStringColumn(statement, index: 22),
                eventID: calendarEventID,
                seriesID: optionalStringColumn(statement, index: 23),
                originalStartTime: calendarOccurrenceStart
            )
        } else {
            calendarOccurrence = nil
        }
        return MeetingRecord(
            id: sqlite3_column_int64(statement, 0),
            title: stringColumn(statement, index: 1),
            startTime: stringColumn(statement, index: 2),
            durationSeconds: sqlite3_column_double(statement, 3),
            rawTranscript: stringColumn(statement, index: 4),
            formattedNotes: stringColumn(statement, index: 5),
            wordCount: Int(sqlite3_column_int(statement, 6)),
            folderID: folderID,
            calendarEventID: calendarEventID,
            calendarOccurrence: calendarOccurrence,
            micAudioPath: micAudioPath,
            systemAudioPath: systemAudioPath,
            savedRecordingPath: savedRecordingPath,
            status: status,
            manualNotes: manualNotes,
            selectedTemplateID: selectedTemplateID,
            selectedTemplateName: selectedTemplateName,
            selectedTemplateKind: selectedTemplateKind,
            selectedTemplatePrompt: selectedTemplatePrompt,
            source: source,
            followUpToID: followUpToID,
            visualContext: optionalStringColumn(statement, index: 25)
        )
    }

    private func openDatabase() throws -> OpaquePointer? {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var db: OpaquePointer?
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            throw lastError(db)
        }
        if sqlite3_busy_timeout(db, 5_000) != SQLITE_OK {
            throw lastError(db)
        }
        if sqlite3_exec(db, "PRAGMA foreign_keys=ON", nil, nil, nil) != SQLITE_OK {
            throw lastError(db)
        }
        if sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil) != SQLITE_OK {
            throw lastError(db)
        }
        return db
    }

    private func exec(_ sql: String, db: OpaquePointer?) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw lastError(db)
        }
    }

    private func lastError(_ db: OpaquePointer?) -> NSError {
        NSError(
            domain: "MeetsDB",
            code: Int(sqlite3_errcode(db)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
        )
    }

    private func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private func optionalStringColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
    }

    private func bindOptionalText(_ value: String?, at index: Int32, statement: OpaquePointer?) {
        if let value {
            sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func parseISODate(_ value: String) -> Date? {
        Self.iso8601FormatterLock.lock()
        defer { Self.iso8601FormatterLock.unlock() }
        return Self.iso8601Formatter.date(from: value)
    }

    private func formatISODate(_ date: Date) -> String {
        Self.iso8601FormatterLock.lock()
        defer { Self.iso8601FormatterLock.unlock() }
        return Self.iso8601Formatter.string(from: date)
    }

    private static func computeStreak(days: [Date], calendar: Calendar) -> (current: Int, longest: Int) {
        let normalized = days
            .map { calendar.startOfDay(for: $0) }
            .sorted()
        guard !normalized.isEmpty else { return (0, 0) }

        var longest = 1
        var run = 1
        for index in 1..<normalized.count {
            let previous = normalized[index - 1]
            let current = normalized[index]
            if let next = calendar.date(byAdding: .day, value: 1, to: previous), calendar.isDate(next, inSameDayAs: current) {
                run += 1
            } else if !calendar.isDate(previous, inSameDayAs: current) {
                longest = max(longest, run)
                run = 1
            }
        }
        longest = max(longest, run)

        let today = calendar.startOfDay(for: Date())
        let anchor: Date
        if calendar.isDate(normalized.last!, inSameDayAs: today) {
            anchor = today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  calendar.isDate(normalized.last!, inSameDayAs: yesterday) {
            anchor = yesterday
        } else {
            return (0, longest)
        }

        var current = 0
        var cursor = anchor
        let set = Set(normalized)
        while set.contains(cursor) {
            current += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return (current, longest)
    }
}
