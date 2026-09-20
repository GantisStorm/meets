import Testing
import CloudKit
import Foundation
import MeetsCore
import SQLite3
@testable import MeetsApp

@Suite("DictationStore", .serialized)
struct DictationStoreTests {

    /// Creates a DictationStore backed by a temporary database file.
    /// Each test gets its own isolated DB — no production data is touched.
    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meets-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    private func makeLegacyStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meets-legacy-test-\(UUID().uuidString).db")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE meetings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            calendar_event_id TEXT,
            start_time TEXT NOT NULL,
            end_time TEXT,
            duration_seconds REAL,
            raw_transcript TEXT,
            formatted_notes TEXT,
            mic_audio_path TEXT,
            system_audio_path TEXT,
            word_count INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL DEFAULT 'meeting',
            created_at TEXT DEFAULT (datetime('now'))
        );
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return DictationStore(databaseURL: url)
    }

    private func sqliteTestError(_ message: String) -> NSError {
        NSError(domain: "DictationStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func setFolderParentRaw(folderID: Int64, parentID: Int64, store: DictationStore) throws {
        var db: OpaquePointer?
        guard sqlite3_open(store.databasePath().path, &db) == SQLITE_OK else {
            throw sqliteTestError("failed to open test database")
        }
        defer { sqlite3_close(db) }

        let sql = "UPDATE meeting_folders SET parent_id = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteTestError("failed to prepare folder parent update")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, parentID)
        sqlite3_bind_int64(statement, 2, folderID)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
            throw sqliteTestError("failed to update folder parent")
        }
    }

    @Test("migration creates tables without error")
    func migration() throws {
        let store = try makeStore()
        try store.migrateIfNeeded() // idempotent
    }

    @Test("migration replaces calendar event uniqueness with occurrence lookup")
    func migrationReplacesCalendarEventUniqueness() throws {
        let store = try makeLegacyStore()
        var db: OpaquePointer?
        #expect(sqlite3_open(store.databasePath().path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(
            db,
            "CREATE UNIQUE INDEX idx_meetings_calendar_event_id ON meetings(calendar_event_id) WHERE calendar_event_id IS NOT NULL",
            nil,
            nil,
            nil
        ) == SQLITE_OK)
        sqlite3_close(db)

        try store.migrateIfNeeded()

        let originalStart = Date(timeIntervalSince1970: 1_775_817_600)
        let occurrence = CalendarOccurrenceReference(
            provider: .eventKit,
            calendarID: "calendar",
            eventID: "reused-event-id",
            seriesID: "reused-event-id",
            originalStartTime: originalStart
        )
        let firstID = try store.createLiveMeeting(
            title: "First recording",
            calendarEventID: occurrence.eventID,
            startTime: originalStart,
            calendarOccurrence: occurrence
        )
        let secondID = try store.createLiveMeeting(
            title: "Second recording",
            calendarEventID: occurrence.eventID,
            startTime: originalStart.addingTimeInterval(5),
            calendarOccurrence: occurrence
        )
        let sameDayOccurrence = CalendarOccurrenceReference(
            provider: .eventKit,
            calendarID: "calendar",
            eventID: "reused-event-id",
            seriesID: "reused-event-id",
            originalStartTime: originalStart.addingTimeInterval(60 * 60)
        )
        let sameDayID = try store.createLiveMeeting(
            title: "Later occurrence",
            calendarEventID: sameDayOccurrence.eventID,
            startTime: originalStart.addingTimeInterval(60 * 60),
            calendarOccurrence: sameDayOccurrence
        )
        let nextDayOccurrence = CalendarOccurrenceReference(
            provider: .eventKit,
            calendarID: "calendar",
            eventID: "reused-event-id",
            seriesID: "reused-event-id",
            originalStartTime: originalStart.addingTimeInterval(24 * 60 * 60)
        )
        let nextDayID = try store.createLiveMeeting(
            title: "Next recurrence",
            calendarEventID: nextDayOccurrence.eventID,
            startTime: originalStart.addingTimeInterval(24 * 60 * 60),
            calendarOccurrence: nextDayOccurrence
        )

        #expect(firstID != secondID)
        #expect(Set([firstID, secondID, sameDayID, nextDayID]).count == 4)
        #expect(try store.recentMeetings(limit: 10).count == 4)
        #expect(try store.meeting(id: firstID)?.calendarOccurrence == occurrence)
        #expect(try store.meetingByCalendarOccurrence(occurrence)?.id == secondID)
        #expect(try store.meetingByCalendarOccurrence(sameDayOccurrence)?.id == sameDayID)
        #expect(try store.meetingByCalendarOccurrence(nextDayOccurrence)?.id == nextDayID)
    }

    @Test("calendar occurrence identity distinguishes recurrences and survives moves")
    func calendarOccurrenceIdentitySemantics() {
        let originalStart = Date(timeIntervalSince1970: 1_775_817_600)
        let movedOccurrence = CalendarOccurrenceReference(
            provider: .googleCalendar,
            calendarID: "primary",
            eventID: "instance-after-move",
            seriesID: "daily-series",
            originalStartTime: originalStart
        )
        let sameOccurrenceBeforeMove = CalendarOccurrenceReference(
            provider: .googleCalendar,
            calendarID: "primary",
            eventID: "instance-before-move",
            seriesID: "daily-series",
            originalStartTime: originalStart
        )
        let nextOccurrence = CalendarOccurrenceReference(
            provider: .googleCalendar,
            calendarID: "primary",
            eventID: "next-instance",
            seriesID: "daily-series",
            originalStartTime: originalStart.addingTimeInterval(24 * 60 * 60)
        )
        let movedSingleEvent = CalendarOccurrenceReference(
            provider: .googleCalendar,
            calendarID: "primary",
            eventID: "single-event",
            originalStartTime: originalStart.addingTimeInterval(60 * 60)
        )
        let originalSingleEvent = CalendarOccurrenceReference(
            provider: .googleCalendar,
            calendarID: "primary",
            eventID: "single-event",
            originalStartTime: originalStart
        )

        #expect(movedOccurrence.identityKey == sameOccurrenceBeforeMove.identityKey)
        #expect(movedOccurrence.identityKey != nextOccurrence.identityKey)
        #expect(movedSingleEvent.identityKey == originalSingleEvent.identityKey)
    }

    @Test("calendar occurrence lookup finds a legacy placeholder")
    func calendarOccurrenceLookupFindsLegacyPlaceholder() throws {
        let store = try makeStore()
        let originalStart = Date(timeIntervalSince1970: 1_775_817_600)
        let occurrence = CalendarOccurrenceReference(
            provider: .eventKit,
            calendarID: "work",
            eventID: "legacy-event",
            seriesID: "legacy-series",
            originalStartTime: originalStart
        )
        try store.insertMeeting(
            title: "Legacy placeholder",
            calendarEventID: occurrence.eventID,
            startTime: originalStart,
            endTime: originalStart.addingTimeInterval(30 * 60),
            rawTranscript: "",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let matched = try #require(try store.meetingByCalendarOccurrence(occurrence))
        #expect(matched.title == "Legacy placeholder")
        #expect(matched.calendarEventID == occurrence.eventID)
        #expect(matched.calendarOccurrence == nil)

        let differentRecurrence = CalendarOccurrenceReference(
            provider: occurrence.provider,
            calendarID: occurrence.calendarID,
            eventID: occurrence.eventID,
            seriesID: occurrence.seriesID,
            originalStartTime: originalStart.addingTimeInterval(24 * 60 * 60)
        )
        #expect(try store.meetingByCalendarOccurrence(differentRecurrence) == nil)
    }

    @Test("calendar occurrence lookup finds a rescheduled legacy one-off event")
    func calendarOccurrenceLookupFindsRescheduledLegacyOneOffEvent() throws {
        let store = try makeStore()
        let originalStart = Date(timeIntervalSince1970: 1_775_817_600)
        try store.insertMeeting(
            title: "Legacy one-off placeholder",
            calendarEventID: "legacy-one-off",
            startTime: originalStart,
            endTime: originalStart.addingTimeInterval(30 * 60),
            rawTranscript: "",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let rescheduledOccurrence = CalendarOccurrenceReference(
            provider: .eventKit,
            calendarID: "work",
            eventID: "legacy-one-off",
            originalStartTime: originalStart.addingTimeInterval(24 * 60 * 60)
        )

        let matched = try #require(try store.meetingByCalendarOccurrence(rescheduledOccurrence))
        #expect(matched.title == "Legacy one-off placeholder")
        #expect(matched.calendarEventID == rescheduledOccurrence.eventID)
        #expect(matched.calendarOccurrence == nil)
    }

    @Test("MeetingRecord decodes legacy JSON without a calendar occurrence")
    func meetingRecordDecodesWithoutCalendarOccurrence() throws {
        let json = """
        {
          "id": 42,
          "title": "Legacy meeting",
          "startTime": "2026-04-10T14:00:00Z",
          "durationSeconds": 1800,
          "rawTranscript": "",
          "formattedNotes": "",
          "wordCount": 0
        }
        """

        let record = try JSONDecoder().decode(
            MeetingRecord.self,
            from: try #require(json.data(using: .utf8))
        )

        #expect(record.calendarOccurrence == nil)
    }

    @Test("MeetingRecord decodes legacy JSON without visual context")
    func meetingRecordDecodesWithoutVisualContext() throws {
        let json = """
        {
          "id": 42,
          "title": "Legacy meeting",
          "startTime": "2026-04-10T14:00:00Z",
          "durationSeconds": 1800,
          "rawTranscript": "",
          "formattedNotes": "",
          "wordCount": 0
        }
        """

        let record = try JSONDecoder().decode(
            MeetingRecord.self,
            from: try #require(json.data(using: .utf8))
        )

        #expect(record.visualContext == nil)
    }

    @Test("MeetingRecord preserves a calendar occurrence through Codable")
    func meetingRecordCalendarOccurrenceCodableRoundTrip() throws {
        let occurrence = CalendarOccurrenceReference(
            provider: .googleCalendar,
            calendarID: "primary",
            eventID: "instance",
            seriesID: "series",
            originalStartTime: Date(timeIntervalSince1970: 1_775_817_600)
        )
        let original = MeetingRecord(
            id: 42,
            title: "Daily sync",
            startTime: "2026-04-10T14:00:00Z",
            durationSeconds: 1800,
            rawTranscript: "",
            formattedNotes: "",
            wordCount: 0,
            folderID: nil,
            calendarEventID: occurrence.eventID,
            calendarOccurrence: occurrence
        )

        let decoded = try JSONDecoder().decode(
            MeetingRecord.self,
            from: JSONEncoder().encode(original)
        )

        #expect(decoded.calendarOccurrence == occurrence)
    }

    @Test("migration adds template columns to legacy meeting schema")
    func migrationAddsTemplateColumns() throws {
        let store = try makeLegacyStore()

        try store.migrateIfNeeded()

        let meeting = try store.meeting(id: 1)
        #expect(meeting == nil)
        try store.insertMeeting(
            title: "Legacy Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(60),
            rawTranscript: "Legacy transcript",
            formattedNotes: "Legacy notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            selectedTemplateID: "one-to-one",
            selectedTemplateName: "1 to 1",
            selectedTemplateKind: .builtin,
            selectedTemplatePrompt: "## Check-In"
        )
        let inserted = try store.recentMeetings(limit: 1).first
        #expect(inserted?.selectedTemplateID == "one-to-one")
        #expect(inserted?.selectedTemplateKind == .builtin)
        #expect(inserted?.savedRecordingPath == nil)
        #expect(inserted?.status == .completed)
        #expect(inserted?.manualNotes == "")
        #expect(inserted?.source == .meeting)
    }

    @Test("migration adds saved recording path column to legacy meeting schema")
    func migrationAddsSavedRecordingColumn() throws {
        let store = try makeLegacyStore()

        try store.migrateIfNeeded()

        let start = Date()
        try store.insertMeeting(
            title: "Saved Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "Notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: "/tmp/meeting.wav"
        )

        let inserted = try store.recentMeetings(limit: 1).first
        #expect(inserted?.savedRecordingPath == "/tmp/meeting.wav")
    }

    @Test("meeting source is persisted")
    func meetingSourcePersists() throws {
        let store = try makeStore()
        let start = Date()

        try store.insertMeeting(
            title: "Imported Audio",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "Notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: "/tmp/import.wav",
            source: .audioImport
        )

        let inserted = try #require(try store.recentMeetings(limit: 1).first)
        #expect(inserted.source == .audioImport)
    }

    @Test("visual context round-trips through insert and fetch")
    func visualContextPersists() throws {
        let store = try makeStore()
        let start = Date()

        let id = try store.insertMeeting(
            title: "Context Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "Notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            visualContext: "[10:00:00] Safari:\nApp context:\nSlide deck"
        )

        let fetched = try #require(try store.meeting(id: id))
        #expect(fetched.visualContext == "[10:00:00] Safari:\nApp context:\nSlide deck")

        let plainID = try store.insertMeeting(
            title: "No Context",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "Notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        #expect(try #require(try store.meeting(id: plainID)).visualContext == nil)
    }

    @Test("completeLiveMeeting stores visual context")
    func completeLiveMeetingStoresVisualContext() throws {
        let store = try makeStore()
        let start = Date()
        let id = try store.createLiveMeeting(
            title: "Live",
            calendarEventID: nil,
            startTime: start
        )

        try store.completeLiveMeeting(
            id: id,
            title: "Live",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(120),
            rawTranscript: "Transcript",
            formattedNotes: "Notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            visualContext: "[10:05:00] Zoom:\nOCR visual text:\nQ3 roadmap"
        )

        let fetched = try #require(try store.meeting(id: id))
        #expect(fetched.visualContext == "[10:05:00] Zoom:\nOCR visual text:\nQ3 roadmap")
    }

    @Test("migrating a legacy database twice tolerates the duplicate columns")
    func legacyMigrationIsIdempotent() throws {
        let store = try makeLegacyStore()

        try store.migrateIfNeeded()
        // The second pass re-runs every ADD COLUMN against columns that now
        // exist; those duplicates must stay tolerated while real failures throw.
        try store.migrateIfNeeded()

        let start = Date()
        let id = try store.insertMeeting(
            title: "Twice Migrated",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "Notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            visualContext: "context survives a second migration"
        )
        #expect(try #require(try store.meeting(id: id)).visualContext == "context survives a second migration")
    }

    @Test("migration adds visual context column to legacy meeting schema")
    func migrationAddsVisualContextColumn() throws {
        let store = try makeLegacyStore()

        try store.migrateIfNeeded()

        let start = Date()
        let id = try store.insertMeeting(
            title: "Migrated Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "Notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            visualContext: "context after migration"
        )

        #expect(try #require(try store.meeting(id: id)).visualContext == "context after migration")
    }

    @Test("meetingRawTranscript returns the stored transcript")
    func meetingRawTranscriptReturnsStoredTranscript() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(
            title: "Standup",
            calendarEventID: nil,
            startTime: Date()
        )
        try store.updateMeetingTranscript(id: id, rawTranscript: "Hello from the meeting")

        #expect(try store.meetingRawTranscript(id: id) == "Hello from the meeting")
    }

    @Test("meetingRawTranscript returns nil for a missing meeting")
    func meetingRawTranscriptReturnsNilForMissingMeeting() throws {
        let store = try makeStore()
        #expect(try store.meetingRawTranscript(id: 999_999) == nil)
    }

    @Test("meetingRawTranscript returns nil for a deleted meeting")
    func meetingRawTranscriptReturnsNilForDeletedMeeting() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(
            title: "Deleted",
            calendarEventID: nil,
            startTime: Date()
        )
        try store.updateMeetingTranscript(id: id, rawTranscript: "Should be hidden")
        try store.deleteMeeting(id: id)

        #expect(try store.meetingRawTranscript(id: id) == nil)
    }

    @Test("completeLiveMeeting can persist explicit recorded duration")
    func completeLiveMeetingPersistsExplicitRecordedDuration() throws {
        let store = try makeStore()
        let originalStart = Date(timeIntervalSince1970: 1_000_000)
        let resumedEnd = originalStart.addingTimeInterval(21 * 24 * 60 * 60)
        let id = try store.createLiveMeeting(
            title: "Long-running artifact",
            calendarEventID: nil,
            startTime: originalStart
        )

        try store.completeLiveMeeting(
            id: id,
            title: "Long-running artifact",
            calendarEventID: nil,
            startTime: originalStart,
            endTime: resumedEnd,
            durationSeconds: 210,
            rawTranscript: "old\nnew",
            formattedNotes: "notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.startTime == ISO8601DateFormatter().string(from: originalStart))
        #expect(meeting.durationSeconds == 210)
    }

    @Test("unknown meeting source falls back to meeting")
    func unknownMeetingSourceFallsBackToMeeting() throws {
        let store = try makeStore()
        var db: OpaquePointer?
        #expect(sqlite3_open(store.databasePath().path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO meetings (
            title, start_time, end_time, duration_seconds, raw_transcript,
            formatted_notes, word_count, source
        )
        VALUES ('Legacy', '2026-06-16T10:00:00Z', '2026-06-16T10:01:00Z', 60, 'Legacy text', '', 2, 'future_source')
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)

        let meeting = try #require(try store.recentMeetings(limit: 1).first)
        #expect(meeting.source == .meeting)
    }

    @Test("live meeting starts as recording with empty manual notes")
    func createLiveMeeting() throws {
        let store = try makeStore()
        let start = Date()

        let id = try store.createLiveMeeting(
            title: "Quick Note",
            calendarEventID: nil,
            startTime: start,
            selectedTemplateID: "auto",
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: "## Summary"
        )

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.title == "Quick Note")
        #expect(meeting.status == .recording)
        #expect(meeting.manualNotes == "")
        #expect(meeting.rawTranscript == "")
        #expect(meeting.formattedNotes == "")
        #expect(meeting.selectedTemplateID == "auto")
        #expect(meeting.source == .meeting)
    }

    @Test("manual notes update independently from final notes")
    func updateManualNotes() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Quick Note", calendarEventID: nil, startTime: Date())

        try store.updateMeetingManualNotes(id: id, manualNotes: "- Decision: ship today")

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.manualNotes == "- Decision: ship today")
        #expect(meeting.formattedNotes == "")
    }

    @Test("manual notes update fails when the meeting row is missing")
    func updateManualNotesFailsWhenMeetingMissing() throws {
        let store = try makeStore()

        #expect(throws: Error.self) {
            try store.updateMeetingManualNotes(id: 9_999, manualNotes: "Lost note")
        }
    }

    @Test("status update fails when the meeting row is missing")
    func updateMeetingStatusFailsWhenMeetingMissing() throws {
        let store = try makeStore()

        #expect(throws: Error.self) {
            try store.updateMeetingStatus(id: 9_999, status: .failed)
        }
    }

    @Test("live meeting completes the same row")
    func completeLiveMeetingUpdatesExistingRow() throws {
        let store = try makeStore()
        let start = Date()
        let id = try store.createLiveMeeting(title: "Draft", calendarEventID: nil, startTime: start)
        try store.updateMeetingManualNotes(id: id, manualNotes: "- Keep this")

        try store.completeLiveMeeting(
            id: id,
            title: "Generated Title",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(120),
            rawTranscript: "hello world",
            formattedNotes: "## Summary\nHello\n\n## Manual Notes\n\n- Keep this",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: nil,
            selectedTemplateID: "auto",
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: "## Summary"
        )

        let meetings = try store.recentMeetings(limit: 10)
        #expect(meetings.count == 1)
        let completed = try #require(meetings.first)
        #expect(completed.id == id)
        #expect(completed.status == .completed)
        #expect(completed.title == "Generated Title")
        #expect(completed.rawTranscript == "hello world")
        #expect(completed.wordCount == 5)
        #expect(completed.manualNotes == "- Keep this")
    }

    @Test("live meeting completion stores the stop-time manual notes snapshot verbatim")
    func completeLiveMeetingStoresExplicitManualNotes() throws {
        let store = try makeStore()
        let start = Date()
        let id = try store.createLiveMeeting(title: "Draft", calendarEventID: nil, startTime: start)

        // The row's debounced live value was lost/empty at stop; the stop-time
        // snapshot must still land in manual_notes (this is the regression the
        // completed meeting must not clear or drop).
        try store.completeLiveMeeting(
            id: id,
            title: "Generated Title",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(120),
            rawTranscript: "hello world",
            formattedNotes: "## Summary\nHello\n\n### Written notes\n\n- Ship today",
            manualNotes: "- Ship today",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: nil,
            selectedTemplateID: "auto",
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: "## Summary"
        )

        let completed = try #require(try store.meeting(id: id))
        #expect(completed.manualNotes == "- Ship today")
        #expect(completed.wordCount == DictationStore.countWords(in: "hello world") + DictationStore.countWords(in: "- Ship today"))
    }

    @Test("live meeting completion keeps stored manual notes when no snapshot is supplied")
    func completeLiveMeetingKeepsStoredManualNotesWithoutSnapshot() throws {
        let store = try makeStore()
        let start = Date()
        let id = try store.createLiveMeeting(title: "Draft", calendarEventID: nil, startTime: start)
        try store.updateMeetingManualNotes(id: id, manualNotes: "- Already persisted live")

        try store.completeLiveMeeting(
            id: id,
            title: "Generated Title",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(120),
            rawTranscript: "hello world",
            formattedNotes: "## Summary\nHello",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: nil,
            selectedTemplateID: "auto",
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: "## Summary"
        )

        let completed = try #require(try store.meeting(id: id))
        #expect(completed.manualNotes == "- Already persisted live")
    }

    @Test("live transcript checkpoints recover stale meetings as raw transcript fallback")
    func liveTranscriptCheckpointsRecoverStaleMeeting() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(
            title: "Crashed Meeting",
            calendarEventID: nil,
            startTime: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try store.updateMeetingManualNotes(id: id, manualNotes: "Remember this decision")

        try store.appendLiveTranscriptCheckpoints(meetingID: id, entries: [
            LiveTranscriptCheckpointEntry(timestampLabel: "10:00:01", speaker: "You", startSeconds: 1, endSeconds: 2, text: "We should ship today."),
            LiveTranscriptCheckpointEntry(timestampLabel: "10:00:03", speaker: "Others", startSeconds: 3, endSeconds: 4, text: "Agreed with the plan.")
        ])

        let recovered = try store.recoverLiveMeetingFromTranscriptCheckpoints(id: id)

        #expect(recovered == true)
        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.status == .completed)
        #expect(meeting.notesState == .rawTranscriptFallback)
        #expect(meeting.rawTranscript.contains("[10:00:01] You: We should ship today."))
        #expect(meeting.rawTranscript.contains("[10:00:03] Others: Agreed with the plan."))
        #expect(meeting.formattedNotes.contains("Recovered from live transcript checkpoints"))
        #expect(meeting.wordCount == DictationStore.countWords(in: meeting.rawTranscript) + 3)
        #expect(meeting.durationSeconds == 4)
        #expect(try store.liveTranscriptCheckpointText(meetingID: id) == nil)
    }

    @Test("resumed meeting crash recovery preserves prior transcript and appends checkpoints")
    func resumedMeetingCrashRecoveryPreservesPriorTranscriptAndAppendsCheckpoints() throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let id = try store.insertMeeting(
            title: "Original Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(120),
            rawTranscript: "Original transcript",
            formattedNotes: "## Summary\nOriginal notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        #expect(try store.prepareMeetingForResume(id: id) == "Original transcript")
        try store.appendLiveTranscriptCheckpoints(meetingID: id, entries: [
            LiveTranscriptCheckpointEntry(timestampLabel: "10:03:01", speaker: "You", startSeconds: 1, endSeconds: 3, text: "Resumed words")
        ])

        let recovered = try store.recoverLiveMeetingFromTranscriptCheckpoints(id: id)

        #expect(recovered == true)
        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.status == .completed)
        #expect(meeting.rawTranscript == "Original transcript\n\n— Resumed —\n\n[10:03:01] You: Resumed words")
        #expect(meeting.formattedNotes.contains("## Summary\nOriginal notes"))
        #expect(meeting.formattedNotes.contains("Recovered from live transcript checkpoints after a resumed meeting"))
        #expect(meeting.durationSeconds == 123)
        #expect(try store.liveTranscriptCheckpointText(meetingID: id) == nil)
        #expect(try store.recoverLiveMeetingFromTranscriptCheckpoints(id: id) == false)
    }

    @Test("resumed meeting crash recovery restores prior completed row without checkpoints")
    func resumedMeetingCrashRecoveryRestoresPriorCompletedRowWithoutCheckpoints() throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let id = try store.insertMeeting(
            title: "Original Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(120),
            rawTranscript: "Original transcript",
            formattedNotes: "## Summary\nOriginal notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        _ = try store.prepareMeetingForResume(id: id)

        let recovered = try store.recoverLiveMeetingFromTranscriptCheckpoints(id: id)

        #expect(recovered == true)
        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.status == .completed)
        #expect(meeting.rawTranscript == "Original transcript")
        #expect(meeting.formattedNotes == "## Summary\nOriginal notes")
        #expect(meeting.durationSeconds == 120)
        #expect(try store.recoverLiveMeetingFromTranscriptCheckpoints(id: id) == false)
    }

    @Test("normal live meeting completion clears transcript checkpoints")
    func completeLiveMeetingClearsTranscriptCheckpoints() throws {
        let store = try makeStore()
        let start = Date()
        let id = try store.createLiveMeeting(title: "Draft", calendarEventID: nil, startTime: start)
        try store.appendLiveTranscriptCheckpoints(meetingID: id, entries: [
            LiveTranscriptCheckpointEntry(timestampLabel: "10:00:01", speaker: "You", startSeconds: 1, endSeconds: 2, text: "Temporary live text")
        ])

        try store.completeLiveMeeting(
            id: id,
            title: "Generated Title",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(120),
            rawTranscript: "final diarized transcript",
            formattedNotes: "## Summary\nFinal notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: nil,
            selectedTemplateID: "auto",
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: "## Summary"
        )

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.status == .completed)
        #expect(meeting.rawTranscript == "final diarized transcript")
        #expect(meeting.notesState == .structuredNotes)
        #expect(try store.liveTranscriptCheckpointText(meetingID: id) == nil)
        #expect(try store.recoverLiveMeetingFromTranscriptCheckpoints(id: id) == false)
    }

    @Test("note-only status updates word count from manual notes")
    func noteOnlyStatusCountsManualNotes() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Manual Draft", calendarEventID: nil, startTime: Date())
        try store.updateMeetingManualNotes(id: id, manualNotes: "Decision ship today")

        try store.updateMeetingStatus(id: id, status: .noteOnly)

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.status == .noteOnly)
        #expect(meeting.wordCount == 3)
    }

    @Test("live meeting completion fails when the row disappeared")
    func completeLiveMeetingFailsWhenRowMissing() throws {
        let store = try makeStore()
        let start = Date()

        #expect(throws: Error.self) {
            try store.completeLiveMeeting(
                id: 9_999,
                title: "Generated Title",
                calendarEventID: nil,
                startTime: start,
                endTime: start.addingTimeInterval(120),
                rawTranscript: "hello world",
                formattedNotes: "## Summary\nHello",
                micAudioPath: nil,
                systemAudioPath: nil,
                savedRecordingPath: nil,
                selectedTemplateID: "auto",
                selectedTemplateName: "Auto",
                selectedTemplateKind: .auto,
                selectedTemplatePrompt: "## Summary"
            )
        }
    }

    @Test("staleLiveMeetings returns only recording and processing rows")
    func staleLiveMeetingsFiltersLiveStatuses() throws {
        let store = try makeStore()
        let start = Date()

        let recordingID = try store.createLiveMeeting(title: "Recording", calendarEventID: nil, startTime: start)
        let processingID = try store.createLiveMeeting(title: "Processing", calendarEventID: nil, startTime: start.addingTimeInterval(1))
        let noteOnlyID = try store.createLiveMeeting(title: "Note Only", calendarEventID: nil, startTime: start.addingTimeInterval(2))
        try store.updateMeetingStatus(id: processingID, status: .processing)
        try store.updateMeetingStatus(id: noteOnlyID, status: .noteOnly)
        try store.insertMeeting(
            title: "Completed",
            calendarEventID: nil,
            startTime: start.addingTimeInterval(3),
            endTime: start.addingTimeInterval(60),
            rawTranscript: "done",
            formattedNotes: "## Summary\nDone",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let stale = try store.staleLiveMeetings()

        #expect(stale.map(\.id) == [processingID, recordingID])
        #expect(stale.allSatisfy { $0.status == .recording || $0.status == .processing })
    }

    @Test("insert and retrieve meeting")
    func insertAndRetrieveMeeting() throws {
        let store = try makeStore()

        let start = Date()
        try store.insertMeeting(
            title: "Test Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(600),
            rawTranscript: "Speaker one said hello. Speaker two replied.",
            formattedNotes: "## Summary\nGood meeting",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let rows = try store.recentMeetings(limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first!.title == "Test Meeting")
        #expect(rows.first!.wordCount == 7)
        #expect(rows.first!.appliedTemplateID == MeetingTemplates.autoID)
    }

    @Test("meeting template snapshot persists on insert")
    func insertAndRetrieveMeetingTemplateSnapshot() throws {
        let store = try makeStore()

        let start = Date()
        try store.insertMeeting(
            title: "Template Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(300),
            rawTranscript: "Transcript body",
            formattedNotes: "## Summary\nStructured",
            micAudioPath: nil,
            systemAudioPath: nil,
            selectedTemplateID: "stand-up",
            selectedTemplateName: "Stand-Up",
            selectedTemplateKind: .builtin,
            selectedTemplatePrompt: "## Yesterday"
        )

        let meeting = try store.recentMeetings(limit: 1).first
        #expect(meeting?.selectedTemplateID == "stand-up")
        #expect(meeting?.selectedTemplateName == "Stand-Up")
        #expect(meeting?.selectedTemplateKind == .builtin)
        #expect(meeting?.selectedTemplatePrompt == "## Yesterday")
    }

    @Test("update meeting notes and title")
    func updateMeeting() throws {
        let store = try makeStore()

        let start = Date()
        try store.insertMeeting(
            title: "Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Some transcript",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let rows = try store.recentMeetings(limit: 1)
        let meetingId = rows.first!.id

        try store.updateMeeting(id: meetingId, title: "Sprint Planning", formattedNotes: "## Summary\nPlanned the sprint")

        let updated = try store.recentMeetings(limit: 1)
        #expect(updated.first!.title == "Sprint Planning")
        #expect(updated.first!.formattedNotes == "## Summary\nPlanned the sprint")
    }

    @Test("update meeting notes only")
    func updateMeetingNotesOnly() throws {
        let store = try makeStore()

        let start = Date()
        try store.insertMeeting(
            title: "Original Title",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "Old notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let rows = try store.recentMeetings(limit: 1)
        try store.updateMeetingNotes(id: rows.first!.id, formattedNotes: "New notes")

        let updated = try store.recentMeetings(limit: 1)
        #expect(updated.first!.title == "Original Title") // title unchanged
        #expect(updated.first!.formattedNotes == "New notes")
    }

    @Test("update meeting summary stores template snapshot")
    func updateMeetingSummaryWithTemplateSnapshot() throws {
        let store = try makeStore()

        let start = Date()
        try store.insertMeeting(
            title: "Original Title",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "Old notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let meetingID = try store.recentMeetings(limit: 1).first!.id
        try store.updateMeetingSummary(
            id: meetingID,
            title: "Standup",
            formattedNotes: "## Yesterday\n- Fixed bugs",
            selectedTemplateID: "stand-up",
            selectedTemplateName: "Stand-Up",
            selectedTemplateKind: .builtin,
            selectedTemplatePrompt: "## Yesterday"
        )

        let updated = try store.recentMeetings(limit: 1).first
        #expect(updated?.title == "Standup")
        #expect(updated?.selectedTemplateID == "stand-up")
        #expect(updated?.selectedTemplateName == "Stand-Up")
        #expect(updated?.selectedTemplateKind == .builtin)
        #expect(updated?.selectedTemplatePrompt == "## Yesterday")
    }

    @Test("update meeting transcript and summary replaces empty transcription")
    func updateMeetingTranscriptAndSummary() throws {
        let store = try makeStore()

        let start = Date()
        let meetingID = try store.insertMeeting(
            title: "Recovered Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: "/tmp/recovered.wav"
        )
        try store.updateMeetingManualNotes(id: meetingID, manualNotes: "Manual note")
        try store.updateMeetingStatus(id: meetingID, status: .failed)

        try store.updateMeetingTranscriptAndSummary(
            id: meetingID,
            rawTranscript: "Recovered transcript words",
            formattedNotes: "## Summary\nRecovered notes",
            selectedTemplateID: "auto",
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: "Auto prompt"
        )

        let updated = try #require(try store.meeting(id: meetingID))
        #expect(updated.rawTranscript == "Recovered transcript words")
        #expect(updated.formattedNotes == "## Summary\nRecovered notes")
        #expect(updated.status == .completed)
        #expect(updated.wordCount == 5)
        #expect(updated.savedRecordingPath == "/tmp/recovered.wav")
        #expect(updated.manualNotes == "Manual note")
    }

    @Test("update meeting transcript preserves notes and refreshes word count")
    func updateMeetingTranscript() throws {
        let store = try makeStore()

        let start = Date()
        let meetingID = try store.insertMeeting(
            title: "Editable Transcript",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Original words",
            formattedNotes: "## Summary\nExisting notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        try store.updateMeetingManualNotes(id: meetingID, manualNotes: "Manual note")

        try store.updateMeetingTranscript(
            id: meetingID,
            rawTranscript: "[10:00:00] You: Edited transcript words"
        )

        let updated = try #require(try store.meeting(id: meetingID))
        #expect(updated.rawTranscript == "[10:00:00] You: Edited transcript words")
        #expect(updated.formattedNotes == "## Summary\nExisting notes")
        #expect(updated.manualNotes == "Manual note")
        #expect(updated.wordCount == 7)
    }

    @Test("fetch meeting by id returns audio paths and notes state")
    func fetchMeetingByID() throws {
        let store = try makeStore()

        let now = Date()
        try store.insertMeeting(
            title: "Recorded Meeting",
            calendarEventID: "evt_123",
            startTime: now,
            endTime: now.addingTimeInterval(90),
            rawTranscript: "Discussed roadmap items",
            formattedNotes: "## Summary\nRoadmap reviewed",
            micAudioPath: "/tmp/mic.wav",
            systemAudioPath: "/tmp/system.wav",
            savedRecordingPath: "/tmp/meeting.wav"
        )

        let inserted = try store.recentMeetings(limit: 1).first!
        let fetched = try store.meeting(id: inserted.id)

        #expect(fetched?.id == inserted.id)
        #expect(fetched?.calendarEventID == "evt_123")
        #expect(fetched?.micAudioPath == "/tmp/mic.wav")
        #expect(fetched?.systemAudioPath == "/tmp/system.wav")
        #expect(fetched?.savedRecordingPath == "/tmp/meeting.wav")
        #expect(fetched?.notesState == .structuredNotes)
        #expect(fetched?.appliedTemplateID == MeetingTemplates.autoID)
    }

    @Test("meeting notes state distinguishes raw transcript fallback from structured notes")
    func meetingNotesState() throws {
        let missing = MeetingRecord(
            id: 1,
            title: "Missing",
            startTime: "2026-03-17T10:00:00Z",
            durationSeconds: 60,
            rawTranscript: "Hello world",
            formattedNotes: "",
            wordCount: 2,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let fallback = MeetingRecord(
            id: 2,
            title: "Fallback",
            startTime: "2026-03-17T10:00:00Z",
            durationSeconds: 60,
            rawTranscript: "Hello world",
            formattedNotes: "## Raw Transcript\n\nHello world",
            wordCount: 2,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let structured = MeetingRecord(
            id: 3,
            title: "Structured",
            startTime: "2026-03-17T10:00:00Z",
            durationSeconds: 60,
            rawTranscript: "Hello world",
            formattedNotes: "## Summary\nNext steps captured",
            wordCount: 2,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let structuredWithTranscriptSection = MeetingRecord(
            id: 4,
            title: "Structured With Transcript Section",
            startTime: "2026-03-17T10:00:00Z",
            durationSeconds: 60,
            rawTranscript: "Hello world",
            formattedNotes: "## Summary\nNext steps captured\n\n## Raw Transcript\n\nQuoted transcript for reference",
            wordCount: 2,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil
        )

        #expect(missing.notesState == .missing)
        #expect(fallback.notesState == .rawTranscriptFallback)
        #expect(structured.notesState == .structuredNotes)
        #expect(structuredWithTranscriptSection.notesState == .structuredNotes)
    }

    @Test("meeting stats aggregate correctly")
    func meetingStats() throws {
        let store = try makeStore()

        let start = Date()
        try store.insertMeeting(
            title: "Stats Meeting", calendarEventID: nil,
            startTime: start, endTime: start.addingTimeInterval(300),
            rawTranscript: "This is a test transcript with several words",
            formattedNotes: "", micAudioPath: nil, systemAudioPath: nil
        )
        let liveID = try store.createLiveMeeting(
            title: "Live Draft",
            calendarEventID: nil,
            startTime: start.addingTimeInterval(60)
        )
        let noteOnlyID = try store.createLiveMeeting(
            title: "Written Notes",
            calendarEventID: nil,
            startTime: start.addingTimeInterval(120)
        )
        try store.updateMeetingManualNotes(id: noteOnlyID, manualNotes: "manual note words")
        try store.updateMeetingStatus(id: noteOnlyID, status: .noteOnly)
        try store.updateMeetingStatus(id: liveID, status: .failed)

        let stats = try store.meetingStats()
        #expect(stats.totalMeetings == 2)
        #expect(stats.totalWords == 11)
    }

    @Test("clear meetings removes all records")
    func clearMeetings() throws {
        let store = try makeStore()
        let now = Date()
        let meetingID = try store.insertMeeting(title: "Del", calendarEventID: nil, startTime: now, endTime: now.addingTimeInterval(60), rawTranscript: "x", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil)
        _ = try store.prepareMeetingForResume(id: meetingID)
        try store.clearMeetings()
        #expect(try store.recentMeetings(limit: 100).isEmpty)
        #expect(try store.recoverLiveMeetingFromTranscriptCheckpoints(id: meetingID) == false)
    }

    @Test("delete meeting removes a single meeting row")
    func deleteMeeting() throws {
        let store = try makeStore()
        let now = Date()

        try store.insertMeeting(
            title: "Delete Me",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "first meeting",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        try store.insertMeeting(
            title: "Keep Me",
            calendarEventID: nil,
            startTime: now.addingTimeInterval(120),
            endTime: now.addingTimeInterval(180),
            rawTranscript: "second meeting",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let meetings = try store.recentMeetings(limit: 10)
        let deleteID = meetings.first(where: { $0.title == "Delete Me" })!.id
        try store.deleteMeeting(id: deleteID)

        let remaining = try store.recentMeetings(limit: 10)
        #expect(remaining.count == 1)
        #expect(remaining.first?.title == "Keep Me")
    }

    @Test("delete meeting scrubs the stored visual context")
    func deleteMeetingScrubsVisualContext() throws {
        let store = try makeStore()
        let now = Date()
        let id = try store.insertMeeting(
            title: "Context Delete",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "Notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            visualContext: "[10:00:00] Safari:\nsensitive on-screen text"
        )

        try store.deleteMeeting(id: id)
        #expect(try rawMeetingVisualContext(id: id, store: store) == nil)

        let clearID = try store.insertMeeting(
            title: "Context Clear",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "Notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            visualContext: "more on-screen text"
        )
        try store.clearMeetings()
        #expect(try rawMeetingVisualContext(id: clearID, store: store) == nil)
    }

    /// Reads visual_context straight from the row. Deletion removes the row
    /// outright in this build (there is no CloudKit tombstone to soft-delete
    /// into), so a missing row means no stored context survives.
    private func rawMeetingVisualContext(id: Int64, store: DictationStore) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open(store.databasePath().path, &db) == SQLITE_OK else {
            throw sqliteTestError("failed to open test database")
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT visual_context FROM meetings WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteTestError("failed to prepare visual context read")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(statement, 0))
    }

    @Test("delete meeting removes live transcript checkpoints")
    func deleteMeetingRemovesLiveTranscriptCheckpoints() throws {
        let store = try makeStore()
        let now = Date()
        try store.insertMeeting(
            title: "Delete Checkpoints",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let meetingID = try #require(try store.recentMeetings(limit: 1).first?.id)
        try store.appendLiveTranscriptCheckpoints(meetingID: meetingID, entries: [
            LiveTranscriptCheckpointEntry(
                timestampLabel: "10:00:01",
                speaker: "You",
                startSeconds: 1,
                endSeconds: 2,
                text: "Temporary checkpoint"
            )
        ])
        #expect(try store.liveTranscriptCheckpointText(meetingID: meetingID) != nil)

        try store.deleteMeeting(id: meetingID)

        #expect(try store.liveTranscriptCheckpointText(meetingID: meetingID) == nil)
    }

    // MARK: - Transcript Line Timings

    @Test("replace transcript lines stores them in ordinal order")
    func replaceTranscriptLinesStoresInOrder() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Lines", calendarEventID: nil, startTime: Date())

        try store.replaceTranscriptLines(meetingID: id, lines: [
            TranscriptLineTiming(ordinal: 0, speaker: "You", startSeconds: 0.25, endSeconds: 0.6, text: "Hello there"),
            TranscriptLineTiming(ordinal: 1, speaker: "You", startSeconds: 0.6, endSeconds: 2.9, text: "How are you"),
            TranscriptLineTiming(ordinal: 2, speaker: "Others", startSeconds: 3.1, endSeconds: 4.5, text: "Hi")
        ])

        let lines = try store.transcriptLines(meetingID: id)
        #expect(lines.map(\.ordinal) == [0, 1, 2])
        #expect(lines.map(\.text) == ["Hello there", "How are you", "Hi"])
        #expect(lines.map(\.speaker) == ["You", "You", "Others"])
        #expect(lines.first?.startSeconds == 0.25)
        #expect(lines.last?.endSeconds == 4.5)
    }

    @Test("replace transcript lines overwrites the previous run")
    func replaceTranscriptLinesOverwrites() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Reworded", calendarEventID: nil, startTime: Date())

        try store.replaceTranscriptLines(meetingID: id, lines: [
            TranscriptLineTiming(ordinal: 0, speaker: "You", startSeconds: 0, endSeconds: 1, text: "Draft line"),
            TranscriptLineTiming(ordinal: 1, speaker: "You", startSeconds: 1, endSeconds: 2, text: "second line")
        ])
        try store.replaceTranscriptLines(meetingID: id, lines: [
            TranscriptLineTiming(ordinal: 0, speaker: "Others", startSeconds: 0, endSeconds: 1, text: "Rewritten line")
        ])

        let lines = try store.transcriptLines(meetingID: id)
        #expect(lines.map(\.text) == ["Rewritten line"])
        #expect(lines.map(\.speaker) == ["Others"])
    }

    @Test("non-contiguous ordinals are renumbered by reading order")
    func replaceTranscriptLinesRenumbersGappedOrdinals() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Gaps", calendarEventID: nil, startTime: Date())

        try store.replaceTranscriptLines(meetingID: id, lines: [
            TranscriptLineTiming(ordinal: 0, speaker: "You", startSeconds: 0, endSeconds: 1, text: "first line"),
            TranscriptLineTiming(ordinal: 4, speaker: "You", startSeconds: 1, endSeconds: 2, text: "second line"),
            TranscriptLineTiming(ordinal: 9, speaker: "You", startSeconds: 2, endSeconds: 3, text: "third line")
        ])

        let lines = try store.transcriptLines(meetingID: id)
        #expect(lines.map(\.ordinal) == [0, 1, 2])
        #expect(lines.map(\.text) == ["first line", "second line", "third line"])
    }

    @Test("delete transcript lines clears only the named meeting")
    func deleteTranscriptLinesScopesToOneMeeting() throws {
        let store = try makeStore()
        let kept = try store.createLiveMeeting(title: "Keep", calendarEventID: nil, startTime: Date())
        let cleared = try store.createLiveMeeting(title: "Clear", calendarEventID: nil, startTime: Date())
        let lines = [TranscriptLineTiming(ordinal: 0, speaker: "You", startSeconds: 0, endSeconds: 0.5, text: "one line")]
        try store.replaceTranscriptLines(meetingID: kept, lines: lines)
        try store.replaceTranscriptLines(meetingID: cleared, lines: lines)

        try store.deleteTranscriptLines(meetingID: cleared)

        #expect(try store.transcriptLines(meetingID: cleared).isEmpty)
        #expect(try store.transcriptLines(meetingID: kept).count == 1)
    }

    @Test("delete meeting removes transcript lines")
    func deleteMeetingRemovesTranscriptLines() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Delete Lines", calendarEventID: nil, startTime: Date())
        try store.replaceTranscriptLines(meetingID: id, lines: [
            TranscriptLineTiming(ordinal: 0, speaker: "You", startSeconds: 0, endSeconds: 0.5, text: "one line")
        ])
        #expect(try store.transcriptLines(meetingID: id).count == 1)

        try store.deleteMeeting(id: id)

        #expect(try store.transcriptLines(meetingID: id).isEmpty)
    }

    @Test("clear meetings removes transcript lines")
    func clearMeetingsRemovesTranscriptLines() throws {
        let store = try makeStore()
        let first = try store.createLiveMeeting(title: "One", calendarEventID: nil, startTime: Date())
        let second = try store.createLiveMeeting(title: "Two", calendarEventID: nil, startTime: Date())
        let lines = [TranscriptLineTiming(ordinal: 0, speaker: "You", startSeconds: 0, endSeconds: 0.5, text: "one line")]
        try store.replaceTranscriptLines(meetingID: first, lines: lines)
        try store.replaceTranscriptLines(meetingID: second, lines: lines)

        try store.clearMeetings()

        #expect(try store.transcriptLines(meetingID: first).isEmpty)
        #expect(try store.transcriptLines(meetingID: second).isEmpty)
    }

    @Test("replacing with no lines clears stored timings")
    func replaceTranscriptLinesWithEmptyArrayClears() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Emptied", calendarEventID: nil, startTime: Date())
        try store.replaceTranscriptLines(meetingID: id, lines: [
            TranscriptLineTiming(ordinal: 0, speaker: "You", startSeconds: 0, endSeconds: 0.5, text: "one line")
        ])

        try store.replaceTranscriptLines(meetingID: id, lines: [])

        #expect(try store.transcriptLines(meetingID: id).isEmpty)
    }

    @Test("a fresh database never carries the abandoned words table")
    func freshDatabaseHasNoWordsTable() throws {
        let store = try makeStore()

        #expect(try tableExists("meeting_transcript_words", at: store.databasePath()) == false)
        #expect(try tableExists("meeting_transcript_lines", at: store.databasePath()))
    }

    @Test("migrating a database that still carries the words table drops it")
    func migrationDropsAbandonedWordsTable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meets-legacy-words-\(UUID().uuidString).db")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let sql = """
        CREATE TABLE meeting_transcript_words (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            meeting_id INTEGER NOT NULL,
            ordinal INTEGER NOT NULL,
            speaker TEXT NOT NULL DEFAULT '',
            start_seconds REAL NOT NULL,
            end_seconds REAL NOT NULL,
            text TEXT NOT NULL
        );
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()

        #expect(try tableExists("meeting_transcript_words", at: url) == false)
        #expect(try tableExists("meeting_transcript_lines", at: url))
    }

    private func tableExists(_ name: String, at url: URL) throws -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw sqliteTestError("failed to open \(url.lastPathComponent)")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE name = ?", -1, &statement, nil) == SQLITE_OK else {
            throw sqliteTestError("failed to prepare sqlite_master lookup")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    // MARK: - Editable Meeting Title

    @Test("update meeting title only preserves notes")
    func updateMeetingTitleOnly() throws {
        let store = try makeStore()

        let now = Date()
        try store.insertMeeting(
            title: "Auto Title",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Some words",
            formattedNotes: "## Notes\nKeep these",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let rows = try store.recentMeetings(limit: 1)
        try store.updateMeetingTitle(id: rows.first!.id, title: "Edited Title")

        let updated = try store.recentMeetings(limit: 1)
        #expect(updated.first!.title == "Edited Title")
        #expect(updated.first!.formattedNotes == "## Notes\nKeep these") // notes unchanged
    }

    @Test("update meeting saved recording path stores the retained file location")
    func updateMeetingSavedRecordingPath() throws {
        let store = try makeStore()

        let now = Date()
        let meetingID = try store.insertMeeting(
            title: "Auto Title",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Some words",
            formattedNotes: "## Notes\nKeep these",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        try store.updateMeetingSavedRecordingPath(id: meetingID, path: "/tmp/retained.wav")

        let updated = try store.meeting(id: meetingID)
        #expect(updated?.savedRecordingPath == "/tmp/retained.wav")
    }

    // MARK: - Folder CRUD

    @Test("create and list folders")
    func createAndListFolders() throws {
        let store = try makeStore()

        let id1 = try store.createFolder(name: "Engineering")
        let id2 = try store.createFolder(name: "Customer Calls")

        let folders = try store.listFolders()
        #expect(folders.count == 2)
        #expect(folders.contains(where: { $0.id == id1 && $0.name == "Engineering" }))
        #expect(folders.contains(where: { $0.id == id2 && $0.name == "Customer Calls" }))
    }

    @Test("rename folder")
    func renameFolder() throws {
        let store = try makeStore()

        let id = try store.createFolder(name: "Old Name")
        try store.renameFolder(id: id, name: "New Name")

        let folders = try store.listFolders()
        let folder = folders.first(where: { $0.id == id })
        #expect(folder?.name == "New Name")
    }

    @Test("delete folder removes it from list")
    func deleteFolderRemovesIt() throws {
        let store = try makeStore()

        let id = try store.createFolder(name: "To Delete")
        #expect(try store.listFolders().contains(where: { $0.id == id }))

        try store.deleteFolder(id: id)
        let remaining = try store.listFolders()
        #expect(!remaining.contains(where: { $0.id == id }))
    }

    // MARK: - Move Meeting to Folder

    @Test("move meeting to folder sets folderID")
    func moveMeetingToFolder() throws {
        let store = try makeStore()

        let now = Date()
        try store.insertMeeting(
            title: "Standup",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Daily standup",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let folderID = try store.createFolder(name: "Team")
        let meeting = try store.recentMeetings(limit: 1).first!
        #expect(meeting.folderID == nil) // starts unfiled

        try store.moveMeeting(id: meeting.id, toFolder: folderID)

        let updated = try store.recentMeetings(limit: 1).first!
        #expect(updated.folderID == folderID)
    }

    @Test("move meeting to nil unfiles it")
    func moveMeetingToUnfiled() throws {
        let store = try makeStore()

        let now = Date()
        try store.insertMeeting(
            title: "Filed Meeting",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "words",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let folderID = try store.createFolder(name: "Temp")
        let meetingID = try store.recentMeetings(limit: 1).first!.id
        try store.moveMeeting(id: meetingID, toFolder: folderID)
        #expect(try store.recentMeetings(limit: 1).first!.folderID == folderID)

        try store.moveMeeting(id: meetingID, toFolder: nil)
        #expect(try store.recentMeetings(limit: 1).first!.folderID == nil)
    }

    // MARK: - Move Meeting Family to Folder

    /// `createLiveMeeting` is the store entry point that carries both the
    /// folder and the follow-up link; `insertMeeting` accepts neither.
    @discardableResult
    private func insertFollowUpMeeting(
        in store: DictationStore,
        title: String,
        folderID: Int64? = nil,
        followUpToID: Int64? = nil
    ) throws -> Int64 {
        try store.createLiveMeeting(
            title: title,
            calendarEventID: nil,
            startTime: Date(),
            folderID: folderID,
            followUpToID: followUpToID
        )
    }

    private func storedFolderID(of meetingID: Int64, in store: DictationStore) throws -> Int64? {
        let meetings = try store.recentMeetings()
        return try #require(meetings.first(where: { $0.id == meetingID })).folderID
    }

    @Test("moving a follow-up chain root moves the whole chain, and unfiles it")
    func moveMeetingFamilyMovesChain() throws {
        let store = try makeStore()
        let folderID = try store.createFolder(name: "Family")

        let rootID = try insertFollowUpMeeting(in: store, title: "Root")
        let childID = try insertFollowUpMeeting(in: store, title: "Child", followUpToID: rootID)
        let grandchildID = try insertFollowUpMeeting(in: store, title: "Grandchild", followUpToID: childID)

        try store.moveMeetingFamily(rootID: rootID, toFolder: folderID)
        #expect(try storedFolderID(of: rootID, in: store) == folderID)
        #expect(try storedFolderID(of: childID, in: store) == folderID)
        #expect(try storedFolderID(of: grandchildID, in: store) == folderID)

        try store.moveMeetingFamily(rootID: rootID, toFolder: nil)
        #expect(try storedFolderID(of: rootID, in: store) == nil)
        #expect(try storedFolderID(of: childID, in: store) == nil)
        #expect(try storedFolderID(of: grandchildID, in: store) == nil)
    }

    @Test("moving a follow-up root moves sibling branches and their children")
    func moveMeetingFamilyMovesSiblingBranches() throws {
        let store = try makeStore()
        let folderID = try store.createFolder(name: "Family")

        let rootID = try insertFollowUpMeeting(in: store, title: "Root")
        let firstChildID = try insertFollowUpMeeting(in: store, title: "First Child", followUpToID: rootID)
        let secondChildID = try insertFollowUpMeeting(in: store, title: "Second Child", followUpToID: rootID)
        let grandchildID = try insertFollowUpMeeting(in: store, title: "Grandchild", followUpToID: firstChildID)

        try store.moveMeetingFamily(rootID: rootID, toFolder: folderID)
        #expect(try storedFolderID(of: rootID, in: store) == folderID)
        #expect(try storedFolderID(of: firstChildID, in: store) == folderID)
        #expect(try storedFolderID(of: secondChildID, in: store) == folderID)
        #expect(try storedFolderID(of: grandchildID, in: store) == folderID)
    }

    @Test("moving a middle follow-up moves only its subtree, not its parent")
    func moveMeetingFamilyLeavesAncestorsPut() throws {
        let store = try makeStore()
        let ancestorFolderID = try store.createFolder(name: "Ancestor Folder")
        let subtreeFolderID = try store.createFolder(name: "Subtree Folder")

        let rootID = try insertFollowUpMeeting(in: store, title: "Root", folderID: ancestorFolderID)
        let childID = try insertFollowUpMeeting(in: store, title: "Child", followUpToID: rootID)
        let grandchildID = try insertFollowUpMeeting(in: store, title: "Grandchild", followUpToID: childID)

        try store.moveMeetingFamily(rootID: childID, toFolder: subtreeFolderID)

        #expect(try storedFolderID(of: rootID, in: store) == ancestorFolderID)
        #expect(try storedFolderID(of: childID, in: store) == subtreeFolderID)
        #expect(try storedFolderID(of: grandchildID, in: store) == subtreeFolderID)
    }

    @Test("moveMeetingFamily returns exactly the moved ids")
    func moveMeetingFamilyReturnsMovedIDs() throws {
        let store = try makeStore()
        let folderID = try store.createFolder(name: "Family")

        let rootID = try insertFollowUpMeeting(in: store, title: "Root")
        let childID = try insertFollowUpMeeting(in: store, title: "Child", followUpToID: rootID)
        let grandchildID = try insertFollowUpMeeting(in: store, title: "Grandchild", followUpToID: childID)
        let unrelatedID = try insertFollowUpMeeting(in: store, title: "Unrelated")

        let moved = try store.moveMeetingFamily(rootID: rootID, toFolder: folderID)
        #expect(moved.sorted() == [rootID, childID, grandchildID].sorted())
        #expect(!moved.contains(unrelatedID))
    }

    @Test("delete folder moves its meetings to unfiled")
    func deleteFolderUnfilesMeetings() throws {
        let store = try makeStore()

        let now = Date()
        let folderID = try store.createFolder(name: "Doomed Folder")

        try store.insertMeeting(
            title: "Meeting A",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "a",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let meetingID = try store.recentMeetings(limit: 1).first!.id
        try store.moveMeeting(id: meetingID, toFolder: folderID)
        #expect(try store.recentMeetings(limit: 1).first!.folderID == folderID)

        try store.deleteFolder(id: folderID)

        let meeting = try store.recentMeetings(limit: 1).first!
        #expect(meeting.folderID == nil) // moved to unfiled
        #expect(meeting.title == "Meeting A") // meeting still exists
    }

    @Test("new meetings have nil folderID by default")
    func newMeetingsUnfiled() throws {
        let store = try makeStore()

        let now = Date()
        try store.insertMeeting(
            title: "Unfiled Meeting",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "test",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let meeting = try store.recentMeetings(limit: 1).first!
        #expect(meeting.folderID == nil)
    }

    // MARK: - Nested Folder Tests

    @Test("create subfolder sets parent_id")
    func createSubfolderSetsParentID() throws {
        let store = try makeStore()

        let parentID = try store.createFolder(name: "Projects")
        let childID = try store.createFolder(name: "Sprint 1", parentID: parentID)

        let folders = try store.listFolders()
        let child = folders.first(where: { $0.id == childID })
        #expect(child?.parentID == parentID)
        #expect(child?.name == "Sprint 1")

        let parent = folders.first(where: { $0.id == parentID })
        #expect(parent?.parentID == nil)
    }

    @Test("deeply nested folders have correct parent chain")
    func deeplyNestedFolders() throws {
        let store = try makeStore()

        let root = try store.createFolder(name: "Root")
        let mid = try store.createFolder(name: "Middle", parentID: root)
        let leaf = try store.createFolder(name: "Leaf", parentID: mid)

        let folders = try store.listFolders()
        #expect(folders.first(where: { $0.id == root })?.parentID == nil)
        #expect(folders.first(where: { $0.id == mid })?.parentID == root)
        #expect(folders.first(where: { $0.id == leaf })?.parentID == mid)
    }

    @Test("descendantFolderIDs returns all nested children")
    func descendantFolderIDsReturnsAll() throws {
        let store = try makeStore()

        let root = try store.createFolder(name: "Root")
        let child1 = try store.createFolder(name: "Child 1", parentID: root)
        let child2 = try store.createFolder(name: "Child 2", parentID: root)
        let grandchild = try store.createFolder(name: "Grandchild", parentID: child1)
        _ = try store.createFolder(name: "Unrelated")

        let descendants = try store.descendantFolderIDs(of: root)
        #expect(descendants == [child1, child2, grandchild])
    }

    @Test("descendantFolderIDs excludes root folder in cyclic data")
    func descendantFolderIDsExcludesRootInCycle() throws {
        let store = try makeStore()

        let folderA = try store.createFolder(name: "A")
        let folderB = try store.createFolder(name: "B", parentID: folderA)
        try setFolderParentRaw(folderID: folderA, parentID: folderB, store: store)

        let descendants = try store.descendantFolderIDs(of: folderA)
        #expect(descendants == [folderB])
    }

    @Test("descendantFolderIDs of leaf folder returns empty set")
    func descendantFolderIDsLeafIsEmpty() throws {
        let store = try makeStore()

        let root = try store.createFolder(name: "Root")
        let leaf = try store.createFolder(name: "Leaf", parentID: root)

        let descendants = try store.descendantFolderIDs(of: leaf)
        #expect(descendants.isEmpty)
    }

    @Test("moveFolder reparents folder")
    func moveFolderReparents() throws {
        let store = try makeStore()

        let a = try store.createFolder(name: "A")
        let b = try store.createFolder(name: "B")

        try store.moveFolder(id: b, toParent: a)

        let folders = try store.listFolders()
        #expect(folders.first(where: { $0.id == b })?.parentID == a)
    }

    @Test("moveFolder to nil makes folder top-level")
    func moveFolderToRoot() throws {
        let store = try makeStore()

        let parent = try store.createFolder(name: "Parent")
        let child = try store.createFolder(name: "Child", parentID: parent)

        try store.moveFolder(id: child, toParent: nil)

        let folders = try store.listFolders()
        #expect(folders.first(where: { $0.id == child })?.parentID == nil)
    }

    @Test("moveFolder into own descendant is a no-op")
    func moveFolderIntoDescendantNoOp() throws {
        let store = try makeStore()

        let parent = try store.createFolder(name: "Parent")
        let child = try store.createFolder(name: "Child", parentID: parent)
        let grandchild = try store.createFolder(name: "Grandchild", parentID: child)

        try store.moveFolder(id: parent, toParent: grandchild)

        let folders = try store.listFolders()
        #expect(folders.first(where: { $0.id == parent })?.parentID == nil)
    }

    @Test("moveFolder into itself is a no-op")
    func moveFolderIntoSelfNoOp() throws {
        let store = try makeStore()

        let folder = try store.createFolder(name: "Self")
        try store.moveFolder(id: folder, toParent: folder)

        let folders = try store.listFolders()
        #expect(folders.first(where: { $0.id == folder })?.parentID == nil)
    }

    @Test("delete folder reparents children to grandparent")
    func deleteFolderReparentsChildren() throws {
        let store = try makeStore()

        let root = try store.createFolder(name: "Root")
        let mid = try store.createFolder(name: "Mid", parentID: root)
        let leaf = try store.createFolder(name: "Leaf", parentID: mid)

        try store.deleteFolder(id: mid)

        let folders = try store.listFolders()
        #expect(!folders.contains(where: { $0.id == mid }))
        #expect(folders.first(where: { $0.id == leaf })?.parentID == root)
    }

    @Test("delete root folder reparents children to top level")
    func deleteRootFolderReparentsToTopLevel() throws {
        let store = try makeStore()

        let root = try store.createFolder(name: "Root")
        let child = try store.createFolder(name: "Child", parentID: root)

        try store.deleteFolder(id: root)

        let folders = try store.listFolders()
        #expect(!folders.contains(where: { $0.id == root }))
        #expect(folders.first(where: { $0.id == child })?.parentID == nil)
    }

    @Test("delete folder in cycle reparents child to top level")
    func deleteFolderInCycleReparentsChildToTopLevel() throws {
        let store = try makeStore()

        let folderA = try store.createFolder(name: "A")
        let folderB = try store.createFolder(name: "B", parentID: folderA)
        try setFolderParentRaw(folderID: folderA, parentID: folderB, store: store)

        try store.deleteFolder(id: folderA)

        let folders = try store.listFolders()
        #expect(!folders.contains(where: { $0.id == folderA }))
        #expect(folders.first(where: { $0.id == folderB })?.parentID == nil)
    }

    @Test("delete orphaned folder reparents child to top level")
    func deleteOrphanedFolderReparentsChildToTopLevel() throws {
        let store = try makeStore()

        let orphan = try store.createFolder(name: "Orphan")
        let child = try store.createFolder(name: "Child", parentID: orphan)
        try setFolderParentRaw(folderID: orphan, parentID: 999, store: store)

        try store.deleteFolder(id: orphan)

        let folders = try store.listFolders()
        #expect(!folders.contains(where: { $0.id == orphan }))
        #expect(folders.first(where: { $0.id == child })?.parentID == nil)
    }

    @Test("recentMeetings with folderID includes descendant folder meetings")
    func recentMeetingsIncludesDescendants() throws {
        let store = try makeStore()
        let now = Date()

        let parent = try store.createFolder(name: "Parent")
        let child = try store.createFolder(name: "Child", parentID: parent)

        try store.insertMeeting(
            title: "Meeting in Parent",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "parent meeting",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let parentMeeting = try store.recentMeetings(limit: 1).first!
        try store.moveMeeting(id: parentMeeting.id, toFolder: parent)

        try store.insertMeeting(
            title: "Meeting in Child",
            calendarEventID: nil,
            startTime: now.addingTimeInterval(1),
            endTime: now.addingTimeInterval(61),
            rawTranscript: "child meeting",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let childMeeting = try store.recentMeetings(limit: 1).first!
        try store.moveMeeting(id: childMeeting.id, toFolder: child)

        // Querying the parent folder should return both meetings.
        let parentResults = try store.recentMeetings(folderID: parent)
        #expect(parentResults.count == 2)
        #expect(parentResults.contains(where: { $0.title == "Meeting in Parent" }))
        #expect(parentResults.contains(where: { $0.title == "Meeting in Child" }))

        // Querying the child folder should return only the child meeting.
        let childResults = try store.recentMeetings(folderID: child)
        #expect(childResults.count == 1)
        #expect(childResults.first?.title == "Meeting in Child")
    }

    @Test("recentMeetings with cyclic folder ancestry returns each matching meeting once")
    func recentMeetingsDeduplicatesCyclicFolderTree() throws {
        let store = try makeStore()
        let now = Date()

        let folderA = try store.createFolder(name: "A")
        let folderB = try store.createFolder(name: "B", parentID: folderA)
        try setFolderParentRaw(folderID: folderA, parentID: folderB, store: store)

        try store.insertMeeting(
            title: "Meeting A",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "a",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        try store.moveMeeting(id: try store.recentMeetings(limit: 1).first!.id, toFolder: folderA)

        try store.insertMeeting(
            title: "Meeting B",
            calendarEventID: nil,
            startTime: now.addingTimeInterval(1),
            endTime: now.addingTimeInterval(61),
            rawTranscript: "b",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        try store.moveMeeting(id: try store.recentMeetings(limit: 1).first!.id, toFolder: folderB)

        let results = try store.recentMeetings(folderID: folderA)
        #expect(results.count == 2)
        #expect(Set(results.map(\.title)) == ["Meeting A", "Meeting B"])
    }

    @Test("meetingCounts includes recursive counts for parent folders")
    func meetingCountsRecursive() throws {
        let store = try makeStore()
        let now = Date()

        let parent = try store.createFolder(name: "Parent")
        let child = try store.createFolder(name: "Child", parentID: parent)

        try store.insertMeeting(
            title: "M1", calendarEventID: nil, startTime: now,
            endTime: now.addingTimeInterval(60), rawTranscript: "t", formattedNotes: "",
            micAudioPath: nil, systemAudioPath: nil
        )
        try store.moveMeeting(id: try store.recentMeetings(limit: 1).first!.id, toFolder: parent)

        try store.insertMeeting(
            title: "M2", calendarEventID: nil, startTime: now.addingTimeInterval(1),
            endTime: now.addingTimeInterval(61), rawTranscript: "t", formattedNotes: "",
            micAudioPath: nil, systemAudioPath: nil
        )
        try store.moveMeeting(id: try store.recentMeetings(limit: 1).first!.id, toFolder: child)

        try store.insertMeeting(
            title: "M3", calendarEventID: nil, startTime: now.addingTimeInterval(2),
            endTime: now.addingTimeInterval(62), rawTranscript: "t", formattedNotes: "",
            micAudioPath: nil, systemAudioPath: nil
        )
        try store.moveMeeting(id: try store.recentMeetings(limit: 1).first!.id, toFolder: child)

        let counts = try store.meetingCounts()
        #expect(counts.total == 3)
        #expect(counts.byFolder[child] == 2)
        #expect(counts.byFolder[parent] == 3) // 1 direct + 2 from child
        #expect(counts.directByFolder[parent] == 1)
        #expect(counts.directByFolder[child] == 2)
    }

    @Test("meetingCounts gives stable totals for cyclic folder data")
    func meetingCountsCyclicFoldersAreStable() throws {
        let store = try makeStore()
        let now = Date()

        let folderA = try store.createFolder(name: "A")
        let folderB = try store.createFolder(name: "B", parentID: folderA)
        try setFolderParentRaw(folderID: folderA, parentID: folderB, store: store)

        try store.insertMeeting(
            title: "A1", calendarEventID: nil, startTime: now,
            endTime: now.addingTimeInterval(60), rawTranscript: "t", formattedNotes: "",
            micAudioPath: nil, systemAudioPath: nil
        )
        try store.moveMeeting(id: try store.recentMeetings(limit: 1).first!.id, toFolder: folderA)

        try store.insertMeeting(
            title: "B1", calendarEventID: nil, startTime: now.addingTimeInterval(1),
            endTime: now.addingTimeInterval(61), rawTranscript: "t", formattedNotes: "",
            micAudioPath: nil, systemAudioPath: nil
        )
        try store.moveMeeting(id: try store.recentMeetings(limit: 1).first!.id, toFolder: folderB)

        let counts = try store.meetingCounts()
        #expect(counts.total == 2)
        #expect(counts.byFolder[folderA] == 2)
        #expect(counts.byFolder[folderB] == 2)
        #expect(counts.directByFolder[folderA] == 1)
        #expect(counts.directByFolder[folderB] == 1)
    }

    @Test("treeOrderedFolders produces depth-first order")
    func treeOrderedFoldersProducesCorrectOrder() {
        let folders = [
            MeetingFolder(id: 1, name: "A", parentID: nil, createdAt: ""),
            MeetingFolder(id: 2, name: "B", parentID: nil, createdAt: ""),
            MeetingFolder(id: 3, name: "A1", parentID: 1, createdAt: ""),
            MeetingFolder(id: 4, name: "A2", parentID: 1, createdAt: ""),
            MeetingFolder(id: 5, name: "A1a", parentID: 3, createdAt: ""),
        ]
        let ordered = MeetsController.treeOrderedFolders(folders, order: [1, 2, 3, 4, 5])
        let ids = ordered.map(\.id)
        #expect(ids == [1, 3, 5, 4, 2])
    }

    @Test("treeOrderedFolders handles orphaned folders and their children")
    func treeOrderedFoldersHandlesOrphans() {
        let folders = [
            MeetingFolder(id: 1, name: "Root", parentID: nil, createdAt: ""),
            MeetingFolder(id: 2, name: "Orphan", parentID: 999, createdAt: ""),
            MeetingFolder(id: 3, name: "OrphanChild", parentID: 2, createdAt: ""),
        ]
        let ordered = MeetsController.treeOrderedFolders(folders, order: [1, 2, 3])
        #expect(ordered.count == 3)
        let ids = ordered.map(\.id)
        #expect(ids.contains(2))
        #expect(ids.contains(3))
        // Orphan child should appear after its parent.
        let orphanIdx = ids.firstIndex(of: 2)!
        let childIdx = ids.firstIndex(of: 3)!
        #expect(childIdx > orphanIdx)
    }

    @Test("treeOrderedFolders includes closed cycles once")
    func treeOrderedFoldersIncludesClosedCyclesOnce() {
        let folders = [
            MeetingFolder(id: 1, name: "A", parentID: 2, createdAt: ""),
            MeetingFolder(id: 2, name: "B", parentID: 1, createdAt: ""),
            MeetingFolder(id: 3, name: "Root", parentID: nil, createdAt: ""),
            MeetingFolder(id: 4, name: "Child", parentID: 3, createdAt: ""),
        ]
        let ordered = MeetsController.treeOrderedFolders(folders, order: [3, 4, 1, 2])
        let ids = ordered.map(\.id)
        #expect(ids == [3, 4, 1, 2])
        #expect(Set(ids).count == folders.count)
    }

    // MARK: - Search Tests

    @Test("searchMeetings matches across title, transcript, and notes")
    func searchMeetingsMultiField() throws {
        let store = try makeStore()
        let start = Date()
        try store.insertMeeting(
            title: "Sprint Planning",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(600),
            rawTranscript: "We discussed the backlog items",
            formattedNotes: "## Notes\nPrioritized features",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        try store.insertMeeting(
            title: "Design Review",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(300),
            rawTranscript: "Reviewed the mockups",
            formattedNotes: "## Notes\nApproved designs",
            micAudioPath: nil,
            systemAudioPath: nil
        )

        let byTitle = try store.searchMeetings(query: "Sprint")
        #expect(byTitle.count == 1)
        #expect(byTitle.first!.title == "Sprint Planning")

        let byTranscript = try store.searchMeetings(query: "backlog")
        #expect(byTranscript.count == 1)

        let byNotes = try store.searchMeetings(query: "Prioritized")
        #expect(byNotes.count == 1)
    }

    @Test("searchMeetings matches manual notes")
    func searchMeetingsManualNotes() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Quick Note", calendarEventID: nil, startTime: Date())
        try store.updateMeetingManualNotes(id: id, manualNotes: "Escalate renewal risk")

        let results = try store.searchMeetings(query: "renewal")

        #expect(results.map(\.id).contains(id))
    }

    @Test("searchMeetings matches participant names and emails")
    func searchMeetingsParticipants() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(
            title: "Weekly Sync",
            calendarEventID: nil,
            startTime: Date()
        )
        try store.attachMeetingParticipant(
            meetingID: id,
            participant: MeetingParticipantDraft(
                participantIdentifier: "calendar:pranav@meets.works",
                displayName: "Pranav Hari",
                emailAddress: "pranav@meets.works"
            )
        )

        #expect(try store.searchMeetings(query: "Pranav Hari").map(\.id) == [id])
        #expect(try store.searchMeetings(query: "pranav@meets.works").map(\.id) == [id])
    }

    // MARK: - Meeting ↔ Event links

    private func makeLinkableMeeting(in store: DictationStore) throws -> Int64 {
        let start = Date(timeIntervalSince1970: 1_775_000_000)
        return try store.insertMeeting(
            title: "Manual Sync",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(1800),
            rawTranscript: "Transcript",
            formattedNotes: "## Notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )
    }

    @Test("meeting event link add, list, reverse lookup, and remove round-trip")
    func meetingEventLinkRoundTrip() throws {
        let store = try makeStore()
        let meetingID = try makeLinkableMeeting(in: store)

        try store.addMeetingEventLink(meetingID: meetingID, eventID: "event-1", calendarID: "cal-a")
        try store.addMeetingEventLink(meetingID: meetingID, eventID: "event-2", occurrenceKey: "occ-2")
        // Duplicate add is an idempotent no-op.
        try store.addMeetingEventLink(meetingID: meetingID, eventID: "event-1", calendarID: "cal-a")

        let links = try store.meetingEventLinks(meetingID: meetingID)
        #expect(links.count == 2)
        #expect(links.contains { $0.eventID == "event-1" && $0.calendarID == "cal-a" && $0.occurrenceKey == nil })
        #expect(links.contains { $0.eventID == "event-2" && $0.occurrenceKey == "occ-2" })

        #expect(Set(try store.meetingsLinked(toEventID: "event-1")) == [meetingID])
        #expect(Set(try store.meetingsLinked(toEventID: "event-2")) == [meetingID])
        #expect(try store.meetingsLinked(toEventID: "event-3").isEmpty)

        let all = try store.allMeetingEventLinks()
        #expect(all.count == 2)

        try store.removeMeetingEventLink(meetingID: meetingID, eventID: "event-1")
        let remaining = try store.meetingEventLinks(meetingID: meetingID)
        #expect(remaining.count == 1)
        #expect(remaining.first?.eventID == "event-2")
    }

    @Test("meeting event links cascade-delete with their meeting")
    func meetingEventLinksCascadeOnMeetingDelete() throws {
        let store = try makeStore()
        let meetingID = try makeLinkableMeeting(in: store)
        try store.addMeetingEventLink(meetingID: meetingID, eventID: "event-1")

        try store.deleteMeeting(id: meetingID)

        #expect(try store.meetingEventLinks(meetingID: meetingID).isEmpty)
        #expect(try store.meetingsLinked(toEventID: "event-1").isEmpty)
        #expect(try store.allMeetingEventLinks().isEmpty)
    }

    @Test("updateMeetingCalendarLink adopts primary event identity")
    func updateMeetingCalendarLinkAdoptsIdentity() throws {
        let store = try makeStore()
        let meetingID = try makeLinkableMeeting(in: store)
        let start = Date(timeIntervalSince1970: 1_775_000_000)
        let occurrence = CalendarOccurrenceReference(
            provider: .eventKit,
            calendarID: "cal-a",
            eventID: "event-1",
            seriesID: "series-1",
            originalStartTime: start
        )

        try store.updateMeetingCalendarLink(id: meetingID, eventID: "event-1", occurrence: occurrence)

        let meeting = try #require(try store.meeting(id: meetingID))
        #expect(meeting.calendarEventID == "event-1")
        #expect(meeting.calendarOccurrence?.identityKey == occurrence.identityKey)
        #expect(meeting.calendarOccurrence?.seriesID == "series-1")
        #expect(try store.meetingByCalendarOccurrence(occurrence)?.id == meetingID)
    }
}
