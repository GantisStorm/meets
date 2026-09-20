import Testing
import AppKit
import Foundation
import MeetsCore
@testable import MeetsApp

private enum OpenRouterDisconnectTestError: Error {
    case expected
}

@MainActor
@Suite("Meetings navigation")
struct MeetingsNavigationTests {

    private func makeController(
        dictationStore: DictationStore? = nil,
        configStore: ConfigStore? = nil
    ) -> MeetsController {
        MeetsController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: dictationStore,
            configStore: configStore ?? ConfigStore(supportDirectory: makeSupportDirectory())
        )
    }

    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meets-nav-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    private func makeSupportDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("meets-nav-support-\(UUID().uuidString)", isDirectory: true)
    }

    @discardableResult
    private func insertMeeting(
        in store: DictationStore,
        title: String,
        savedRecordingPath: String?
    ) throws -> Int64 {
        let now = Date()
        return try store.insertMeeting(
            title: title,
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "## Notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: savedRecordingPath
        )
    }

    @Test("app state defaults meetings to browser mode")
    func meetingsDefaultToBrowser() {
        let appState = AppState()

        #expect(appState.selectedTab == .meetings)
        #expect(appState.meetingsNavigationState == .browser)
        #expect(appState.selectedMeeting == nil)
    }

    @Test("foreground meeting starts open and present notes")
    func foregroundMeetingStartPresentation() {
        let presentation = MeetingStartPresentation.foregroundNotes

        #expect(presentation.opensMeetingDocument)
        #expect(presentation.presentsHistoryWindow)
    }

    @Test("background meeting starts only transition the recording pill")
    func backgroundMeetingStartPresentation() {
        let presentation = MeetingStartPresentation.backgroundPill

        #expect(!presentation.opensMeetingDocument)
        #expect(!presentation.presentsHistoryWindow)
    }

    @Test("each dashboard statistic opens insights with its originating section")
    func dashboardStatisticsOpenInsights() {
        let controller = makeController()

        for section in InsightsSection.allCases {
            controller.openInsights(section: section)
            #expect(controller.appState.selectedTab == .insights)
            #expect(controller.appState.insightsInitialSection == section)
        }
    }

    @Test("closing insights returns to meetings")
    func closingInsightsReturnsToMeetings() {
        let controller = makeController()
        controller.appState.selectedTab = .calendar
        controller.openInsights(section: .words)
        #expect(controller.appState.selectedTab == .insights)
        #expect(controller.appState.insightsInitialSection == .words)
        #expect(controller.appState.insightsBackLabel == "Back to Meetings")

        controller.closeInsights()

        #expect(controller.appState.selectedTab == .meetings)
        #expect(controller.appState.insightsInitialSection == .words)
    }

    @Test("discard confirmation maps checkbox selections to meeting discard resolutions")
    func discardConfirmationResolutionMapping() {
        #expect(
            MeetsController.discardResolution(
                for: .alertFirstButtonReturn,
                deleteManualNotes: nil
            ) == .discardRecording
        )
        #expect(
            MeetsController.discardResolution(
                for: .alertFirstButtonReturn,
                deleteManualNotes: false
            ) == .keepManualNotes
        )
        #expect(
            MeetsController.discardResolution(
                for: .alertFirstButtonReturn,
                deleteManualNotes: true
            ) == .deleteDraft
        )
        #expect(
            MeetsController.discardResolution(
                for: .alertSecondButtonReturn,
                deleteManualNotes: false
            ) == nil
        )
    }

    @Test("selectedMeeting resolves the selected row only")
    func selectedMeetingUsesExplicitSelection() {
        let appState = AppState()
        let first = makeMeeting(id: 101, title: "First")
        let second = makeMeeting(id: 202, title: "Second")
        appState.meetingRows = [first, second]

        #expect(appState.selectedMeeting == nil)

        appState.selectedMeetingID = 202
        #expect(appState.selectedMeeting?.id == 202)
        #expect(appState.selectedMeeting?.title == "Second")
    }

    @Test("selectedMeeting falls back to the stored document record outside the browser slice")
    func selectedMeetingUsesStoredRecordWhenNotInRows() {
        let appState = AppState()
        let visible = makeMeeting(id: 101, title: "Visible")
        let selected = makeMeeting(id: 202, title: "Selected Outside Slice")
        appState.meetingRows = [visible]
        appState.selectedMeetingID = 202
        appState.selectedMeetingRecord = selected

        #expect(appState.selectedMeeting?.id == 202)
        #expect(appState.selectedMeeting?.title == "Selected Outside Slice")
    }

    @Test("showMeetingDocument enters meetings document route and records selection")
    func showMeetingDocumentRoutesToDocument() {
        let controller = makeController()

        controller.appState.selectedTab = .calendar
        controller.appState.selectedFolderID = 55
        controller.appState.meetingRows = [makeMeeting(id: 202, title: "Selected Meeting")]

        controller.showMeetingDocument(id: 202)

        #expect(controller.appState.selectedTab == .meetings)
        #expect(controller.appState.selectedMeetingID == 202)
        #expect(controller.appState.meetingsNavigationState == .document(202))
        #expect(controller.appState.selectedFolderID == 55)
    }

    @Test("showMeetingsHome returns to browser and preserves prior meeting selection")
    func showMeetingsHomeReturnsToBrowser() {
        let controller = makeController()

        controller.appState.selectedMeetingID = 303
        controller.appState.meetingsNavigationState = .document(303)

        controller.showMeetingsHome(folderID: 99)

        #expect(controller.appState.selectedTab == .meetings)
        #expect(controller.appState.selectedFolderID == 99)
        #expect(controller.appState.meetingsNavigationState == .browser)
        #expect(controller.appState.selectedMeetingID == 303)
    }

    @Test("showMeetingsHome with nil folder resets browser to all meetings")
    func showMeetingsHomeResetsFolderFilter() {
        let controller = makeController()

        controller.appState.selectedFolderID = 11
        controller.appState.meetingsNavigationState = .document(404)

        controller.showMeetingsHome(folderID: nil)

        #expect(controller.appState.selectedFolderID == nil)
        #expect(controller.appState.meetingsNavigationState == .browser)
    }

    @Test("deleteMeeting clears selected detail state and removes saved recording")
    func deleteMeetingClearsSelection() throws {
        let store = try makeStore()
        let savedRecordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recording-\(UUID().uuidString).wav")
        try Data("test".utf8).write(to: savedRecordingURL)

        let now = Date()
        try store.insertMeeting(
            title: "Delete Target",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "## Notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: savedRecordingURL.path
        )

        let controller = makeController(dictationStore: store)
        let meetingID = try store.recentMeetings(limit: 1).first!.id
        controller.appState.selectedMeetingID = meetingID
        controller.appState.selectedMeetingRecord = try store.meeting(id: meetingID)
        controller.appState.meetingsNavigationState = .document(meetingID)

        controller.deleteMeeting(id: meetingID)

        #expect(try store.meeting(id: meetingID) == nil)
        #expect(controller.appState.selectedMeetingID == nil)
        #expect(controller.appState.selectedMeetingRecord == nil)
        #expect(controller.appState.meetingsNavigationState == .browser)
        #expect(FileManager.default.fileExists(atPath: savedRecordingURL.path) == false)
    }

    @Test("deleteMeeting removes saved recording waveform cache")
    func deleteMeetingRemovesSavedRecordingWaveformCache() throws {
        let store = try makeStore()
        let supportDirectory = makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let configStore = ConfigStore(supportDirectory: supportDirectory)
        let recordingsDirectory = supportDirectory.appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let savedRecordingURL = recordingsDirectory.appendingPathComponent("meeting.m4a")
        try Data("recording".utf8).write(to: savedRecordingURL)
        let cacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: savedRecordingURL,
            supportDirectory: supportDirectory
        )
        try Data("cache".utf8).write(to: cacheURL)
        let meetingID = try insertMeeting(
            in: store,
            title: "Delete Cache Target",
            savedRecordingPath: savedRecordingURL.path
        )
        let controller = makeController(dictationStore: store, configStore: configStore)

        controller.deleteMeeting(id: meetingID)

        #expect(try store.meeting(id: meetingID) == nil)
        #expect(FileManager.default.fileExists(atPath: savedRecordingURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path) == false)
    }

    @Test("deleteMeeting removes saved recording when waveform cache removal fails")
    func deleteMeetingRemovesSavedRecordingWhenWaveformCacheRemovalFails() throws {
        let store = try makeStore()
        let supportDirectory = makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let configStore = ConfigStore(supportDirectory: supportDirectory)
        let recordingsDirectory = supportDirectory.appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let savedRecordingURL = recordingsDirectory.appendingPathComponent("meeting.wav")
        try Data("recording".utf8).write(to: savedRecordingURL)
        let cacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: savedRecordingURL,
            supportDirectory: supportDirectory
        )
        try Data("cache".utf8).write(to: cacheURL)
        let cacheDirectory = cacheURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: cacheDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheDirectory.path) }
        let meetingID = try insertMeeting(
            in: store,
            title: "Delete Cache Failure Target",
            savedRecordingPath: savedRecordingURL.path
        )
        let controller = makeController(dictationStore: store, configStore: configStore)

        controller.deleteMeeting(id: meetingID)

        #expect(try store.meeting(id: meetingID) == nil)
        #expect(FileManager.default.fileExists(atPath: savedRecordingURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test("clearMeetingHistory removes saved recordings and waveform cache")
    func clearMeetingHistoryRemovesSavedRecordingsAndWaveformCache() throws {
        let store = try makeStore()
        let supportDirectory = makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let configStore = ConfigStore(supportDirectory: supportDirectory)
        let recordingsDirectory = supportDirectory.appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let savedRecordingURL = recordingsDirectory.appendingPathComponent("meeting.m4a")
        try Data("recording".utf8).write(to: savedRecordingURL)
        let cacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: savedRecordingURL,
            supportDirectory: supportDirectory
        )
        try Data("cache".utf8).write(to: cacheURL)
        let strandedCacheURL = RecordingWaveformCacheFiles
            .cacheDirectory(supportDirectory: supportDirectory)
            .appendingPathComponent("stranded.mwf")
        try Data("old-cache".utf8).write(to: strandedCacheURL)
        try insertMeeting(in: store, title: "Clear Target", savedRecordingPath: savedRecordingURL.path)
        let controller = makeController(dictationStore: store, configStore: configStore)

        controller.clearMeetingHistory()

        #expect(try store.recentMeetings(limit: 10).isEmpty)
        #expect(FileManager.default.fileExists(atPath: recordingsDirectory.path) == false)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: strandedCacheURL.path) == false)
    }

    @Test("clearMeetingHistory proceeds when waveform cache removal fails")
    func clearMeetingHistoryProceedsWhenWaveformCacheRemovalFails() throws {
        let store = try makeStore()
        let supportDirectory = makeSupportDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
            let cacheDirectory = RecordingWaveformCacheFiles.cacheDirectory(supportDirectory: supportDirectory)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheDirectory.path)
            try? FileManager.default.removeItem(at: supportDirectory)
        }
        let configStore = ConfigStore(supportDirectory: supportDirectory)
        let recordingsDirectory = supportDirectory.appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let savedRecordingURL = recordingsDirectory.appendingPathComponent("meeting.m4a")
        try Data("recording".utf8).write(to: savedRecordingURL)
        let cacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: savedRecordingURL,
            supportDirectory: supportDirectory
        )
        try Data("cache".utf8).write(to: cacheURL)
        let cacheDirectory = cacheURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: cacheDirectory.path)
        try insertMeeting(in: store, title: "Clear Cache Failure Target", savedRecordingPath: savedRecordingURL.path)
        let controller = makeController(dictationStore: store, configStore: configStore)

        controller.clearMeetingHistory()

        #expect(try store.recentMeetings(limit: 10).isEmpty)
        #expect(FileManager.default.fileExists(atPath: recordingsDirectory.path) == false)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test("deleteMeeting keeps shared saved recording and waveform cache")
    func deleteMeetingKeepsSharedSavedRecordingAndWaveformCache() throws {
        let store = try makeStore()
        let supportDirectory = makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let configStore = ConfigStore(supportDirectory: supportDirectory)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let savedRecordingURL = supportDirectory.appendingPathComponent("shared.m4a")
        try Data("recording".utf8).write(to: savedRecordingURL)
        let cacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: savedRecordingURL,
            supportDirectory: supportDirectory
        )
        try Data("cache".utf8).write(to: cacheURL)
        let firstID = try insertMeeting(in: store, title: "Shared A", savedRecordingPath: savedRecordingURL.path)
        let secondID = try insertMeeting(in: store, title: "Shared B", savedRecordingPath: savedRecordingURL.path)
        let controller = makeController(dictationStore: store, configStore: configStore)

        controller.deleteMeeting(id: firstID)

        #expect(try store.meeting(id: firstID) == nil)
        #expect(try store.meeting(id: secondID) != nil)
        #expect(FileManager.default.fileExists(atPath: savedRecordingURL.path))
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test("orphan sweep removes waveform cache when source recording is gone")
    func orphanSweepRemovesCacheWhenSourceRecordingIsGone() throws {
        let supportDirectory = makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let liveRecordingURL = supportDirectory.appendingPathComponent("live.m4a")
        let missingRecordingURL = supportDirectory.appendingPathComponent("missing.m4a")
        try Data("live".utf8).write(to: liveRecordingURL)
        try Data("missing".utf8).write(to: missingRecordingURL)
        let liveCacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: liveRecordingURL,
            supportDirectory: supportDirectory
        )
        let missingCacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: missingRecordingURL,
            supportDirectory: supportDirectory
        )
        try Data("live-cache".utf8).write(to: liveCacheURL)
        try Data("missing-cache".utf8).write(to: missingCacheURL)
        try FileManager.default.removeItem(at: missingRecordingURL)

        let result = RecordingWaveformCacheFiles.sweepOrphanedCachedWaveforms(
            retainedRecordingURLs: [liveRecordingURL, missingRecordingURL],
            supportDirectory: supportDirectory,
            logger: nil
        )

        #expect(result == .completed(removed: 1))
        #expect(FileManager.default.fileExists(atPath: liveCacheURL.path))
        #expect(FileManager.default.fileExists(atPath: missingCacheURL.path) == false)
    }

    @Test("historical waveform cache cleanup runs only once")
    func historicalWaveformCacheCleanupRunsOnlyOnce() throws {
        let store = try makeStore()
        let supportDirectory = makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let configStore = ConfigStore(supportDirectory: supportDirectory)
        let firstMissingRecordingURL = supportDirectory.appendingPathComponent("first-missing.m4a")
        try Data("first".utf8).write(to: firstMissingRecordingURL)
        let firstCacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: firstMissingRecordingURL,
            supportDirectory: supportDirectory
        )
        try Data("first-cache".utf8).write(to: firstCacheURL)
        let firstLegacyJSONURL = firstCacheURL.deletingPathExtension().appendingPathExtension("json")
        try Data(#"{"peaks":[0.1],"duration":1.0}"#.utf8).write(to: firstLegacyJSONURL)
        try FileManager.default.removeItem(at: firstMissingRecordingURL)
        let controller = makeController(dictationStore: store, configStore: configStore)

        controller.cleanupHistoricalMeetingWaveformCacheFilesIfNeeded()

        #expect(FileManager.default.fileExists(atPath: firstCacheURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: firstLegacyJSONURL.path) == false)
        #expect(configStore.load().waveformCacheOrphanCleanupMigrationApplied)

        let secondMissingRecordingURL = supportDirectory.appendingPathComponent("second-missing.m4a")
        try Data("second".utf8).write(to: secondMissingRecordingURL)
        let secondCacheURL = try RecordingWaveformCacheFiles.cacheURL(
            for: secondMissingRecordingURL,
            supportDirectory: supportDirectory
        )
        try Data("second-cache".utf8).write(to: secondCacheURL)
        let secondLegacyJSONURL = secondCacheURL.deletingPathExtension().appendingPathExtension("json")
        try Data(#"{"peaks":[0.2],"duration":2.0}"#.utf8).write(to: secondLegacyJSONURL)
        try FileManager.default.removeItem(at: secondMissingRecordingURL)
        let nextLaunchController = makeController(dictationStore: store, configStore: configStore)

        nextLaunchController.cleanupHistoricalMeetingWaveformCacheFilesIfNeeded()

        #expect(FileManager.default.fileExists(atPath: secondCacheURL.path))
        #expect(FileManager.default.fileExists(atPath: secondLegacyJSONURL.path))
    }

    @Test("deleteMeeting refuses live meeting rows")
    func deleteMeetingRefusesLiveRows() throws {
        let store = try makeStore()
        let meetingID = try store.createLiveMeeting(
            title: "Live Quick Note",
            calendarEventID: nil,
            startTime: Date()
        )
        let controller = MeetsController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )

        let liveMeeting = try #require(try store.meeting(id: meetingID))
        #expect(controller.canDeleteMeeting(liveMeeting) == false)

        controller.deleteMeeting(id: meetingID)

        #expect(try store.meeting(id: meetingID) != nil)
    }

    @Test("retranscribe missing recording preserves completed meeting status")
    func retranscribeMissingRecordingPreservesCompletedStatus() async throws {
        let store = try makeStore()
        let missingRecordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-meeting-recording-\(UUID().uuidString).wav")
        let now = Date()
        let meetingID = try store.insertMeeting(
            title: "Recovered Meeting",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Existing transcript",
            formattedNotes: "## Existing notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: missingRecordingURL.path
        )
        let controller = MeetsController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        let meeting = try #require(try store.meeting(id: meetingID))

        let result = await withCheckedContinuation { continuation in
            controller.retranscribe(meeting: meeting) { result in
                continuation.resume(returning: result)
            }
        }

        switch result {
        case .success:
            Issue.record("Expected re-transcription to fail when the retained recording is missing")
        case .failure(let error):
            #expect(error is MeetingRetranscriptionError)
        }

        let updated = try #require(try store.meeting(id: meetingID))
        #expect(updated.status == .completed)
        #expect(updated.rawTranscript == "Existing transcript")
        #expect(updated.formattedNotes == "## Existing notes")
    }

    @Test("retranscribe empty transcript restores original meeting status")
    func retranscribeEmptyTranscriptRestoresOriginalMeetingStatus() {
        #expect(MeetsController.retranscriptionFailureStatus(
            originalStatus: .completed,
            didSetProcessing: true,
            error: MeetingRetranscriptionError.emptyTranscript
        ) == .completed)
        #expect(MeetsController.retranscriptionFailureStatus(
            originalStatus: .failed,
            didSetProcessing: true,
            error: MeetingRetranscriptionError.emptyTranscript
        ) == .failed)
    }

    @Test("retranscribe status is unchanged before processing starts")
    func retranscribeStatusIsUnchangedBeforeProcessingStarts() {
        #expect(MeetsController.retranscriptionFailureStatus(
            originalStatus: .completed,
            didSetProcessing: false,
            error: MeetingRetranscriptionError.recordingUnavailable
        ) == nil)
    }

    @Test("retranscribe save failures restore original meeting status")
    func retranscribeSaveFailuresRestoreOriginalMeetingStatus() {
        #expect(MeetsController.retranscriptionFailureStatus(
            originalStatus: .completed,
            didSetProcessing: true,
            error: MeetingRetranscriptionError.failedToSave(underlying: CocoaError(.fileWriteUnknown))
        ) == .completed)
    }

    @Test("retranscribe processing failures mark meeting failed")
    func retranscribeProcessingFailuresMarkMeetingFailed() {
        #expect(MeetsController.retranscriptionFailureStatus(
            originalStatus: .completed,
            didSetProcessing: true,
            error: CocoaError(.fileReadUnknown)
        ) == .failed)
    }

    @Test("cached manual notes are persisted before debounce")
    func cachedManualNotesPersistImmediately() throws {
        let store = try makeStore()
        let meetingID = try store.createLiveMeeting(
            title: "Live Quick Note",
            calendarEventID: nil,
            startTime: Date()
        )
        let controller = MeetsController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )

        controller.cacheMeetingManualNotes(id: meetingID, notes: "Decision before crash")

        let persisted = try #require(try store.meeting(id: meetingID))
        #expect(persisted.manualNotes == "Decision before crash")
    }

    @Test("failed manual note persistence retries on later flush")
    func failedManualNotePersistenceRetriesOnFlush() throws {
        let store = try makeStore()
        let controller = MeetsController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )

        controller.cacheMeetingManualNotes(id: 1, notes: "Draft survives retry")
        let meetingID = try store.createLiveMeeting(
            title: "Live Quick Note",
            calendarEventID: nil,
            startTime: Date()
        )
        #expect(meetingID == 1)

        controller.flushCachedMeetingManualNotes(id: meetingID, sync: false)

        let stored = try #require(try store.meeting(id: meetingID))
        #expect(stored.manualNotes == "Draft survives retry")
    }

    @Test("manual note cache coalesces repeated writes until flush")
    func cachedManualNotesCoalesceRepeatedWrites() throws {
        let store = try makeStore()
        let meetingID = try store.createLiveMeeting(
            title: "Live Quick Note",
            calendarEventID: nil,
            startTime: Date()
        )
        let controller = MeetsController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )

        controller.cacheMeetingManualNotes(id: meetingID, notes: "First durable note")
        #expect(controller.hasPersistedMeetingManualNotes(id: meetingID, notes: "First durable note"))
        controller.cacheMeetingManualNotes(id: meetingID, notes: "Second cached note")
        #expect(!controller.hasPersistedMeetingManualNotes(id: meetingID, notes: "Second cached note"))

        let beforeFlush = try #require(try store.meeting(id: meetingID))
        #expect(beforeFlush.manualNotes == "First durable note")

        controller.flushCachedMeetingManualNotes(id: meetingID, sync: false)
        #expect(controller.hasPersistedMeetingManualNotes(id: meetingID, notes: "Second cached note"))

        let afterFlush = try #require(try store.meeting(id: meetingID))
        #expect(afterFlush.manualNotes == "Second cached note")
    }

    @Test("persistCompletedMeetingResult keeps transcript when recording save fails")
    func persistCompletedMeetingResultPreservesMeetingOnRecordingFailure() async throws {
        let store = try makeStore()
        let controller = MeetsController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        controller.updateConfig { $0.meetingRecordingSavePolicy = .always }

        let invalidRecordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let result = MeetingSessionResult(
            title: "Customer Review",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(90),
            durationSeconds: 90,
            rawTranscript: "Discussed roadmap and blockers.",
            formattedNotes: "## Summary\nRoadmap reviewed.",
            retainedRecordingURL: invalidRecordingURL,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        let preparedRecordingSave = await controller.prepareMeetingRecordingSave(for: result)
        let persistenceResult = try controller.persistCompletedMeetingResult(
            result,
            preparedRecordingSave: preparedRecordingSave
        )

        #expect(persistenceResult.recordingSaveError != nil)
        let storedMeeting = try store.meeting(id: persistenceResult.meetingID)
        #expect(storedMeeting?.title == "Customer Review")
        #expect(storedMeeting?.rawTranscript == "Discussed roadmap and blockers.")
        #expect(storedMeeting?.savedRecordingPath == nil)
    }

    @Test("persistCompletedMeetingResult honors prompt recording save decision")
    func persistCompletedMeetingResultHonorsPromptRecordingSaveDecision() async throws {
        let store = try makeStore()
        let controller = MeetsController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        controller.updateConfig { $0.meetingRecordingSavePolicy = .prompt }

        let retainedRecordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("retained-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try Data("recording".utf8).write(to: retainedRecordingURL)

        let result = MeetingSessionResult(
            title: "Prompt Decision",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(30),
            durationSeconds: 30,
            rawTranscript: "Prompt decision transcript.",
            formattedNotes: "## Summary\nPrompt decision notes.",
            retainedRecordingURL: retainedRecordingURL,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        let preparedRecordingSave = await controller.prepareMeetingRecordingSave(
            for: result,
            saveDecision: false
        )
        let persistenceResult = try controller.persistCompletedMeetingResult(
            result,
            preparedRecordingSave: preparedRecordingSave
        )

        let storedMeeting = try store.meeting(id: persistenceResult.meetingID)
        #expect(storedMeeting?.rawTranscript == "Prompt decision transcript.")
        #expect(storedMeeting?.savedRecordingPath == nil)
        #expect(FileManager.default.fileExists(atPath: retainedRecordingURL.path) == false)
    }

    @Test("persistCompletedMeetingResult honors explicit recording save decision after policy drift")
    func persistCompletedMeetingResultHonorsExplicitRecordingSaveDecisionAfterPolicyDrift() async throws {
        let store = try makeStore()
        let supportDirectory = makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let controller = makeController(
            dictationStore: store,
            configStore: ConfigStore(supportDirectory: supportDirectory)
        )
        controller.updateConfig {
            $0.meetingRecordingSavePolicy = .never
            $0.meetingRecordingFileFormat = MeetingRecordingFileFormat.wav.rawValue
        }

        let retainedRecordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("retained-policy-drift-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try Data("recording".utf8).write(to: retainedRecordingURL)

        let result = MeetingSessionResult(
            title: "Policy Drift",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(30),
            durationSeconds: 30,
            rawTranscript: "Policy drift transcript.",
            formattedNotes: "## Summary\nPolicy drift notes.",
            retainedRecordingURL: retainedRecordingURL,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        let preparedRecordingSave = await controller.prepareMeetingRecordingSave(
            for: result,
            saveDecision: true
        )
        let persistenceResult = try controller.persistCompletedMeetingResult(
            result,
            preparedRecordingSave: preparedRecordingSave
        )

        let storedMeeting = try #require(try store.meeting(id: persistenceResult.meetingID))
        let savedRecordingPath = try #require(storedMeeting.savedRecordingPath)
        #expect(FileManager.default.fileExists(atPath: savedRecordingPath))
        #expect(savedRecordingPath.hasPrefix(supportDirectory.path + "/"))
        #expect(FileManager.default.fileExists(atPath: retainedRecordingURL.path) == false)
    }

    @Test("persistCompletedMeetingResult surfaces prompt policy retained recording failures without decision")
    func persistCompletedMeetingResultSurfacesPromptPolicyRetainedRecordingFailuresWithoutDecision() async throws {
        let store = try makeStore()
        let controller = MeetsController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        controller.updateConfig { $0.meetingRecordingSavePolicy = .prompt }

        let result = MeetingSessionResult(
            title: "Failed Retention",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(30),
            durationSeconds: 30,
            rawTranscript: "Retention failure transcript.",
            formattedNotes: "## Summary\nRetention failure notes.",
            retainedRecordingURL: nil,
            retainedRecordingError: CocoaError(.fileWriteUnknown),
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        let preparedRecordingSave = await controller.prepareMeetingRecordingSave(for: result)
        let persistenceResult = try controller.persistCompletedMeetingResult(
            result,
            preparedRecordingSave: preparedRecordingSave
        )

        let storedMeeting = try #require(try store.meeting(id: persistenceResult.meetingID))
        #expect(storedMeeting.savedRecordingPath == nil)
        #expect(persistenceResult.recordingSaveError != nil)
    }

    @Test("persistCompletedMeetingResult surfaces retained recording failures after explicit save decision")
    func persistCompletedMeetingResultSurfacesRetainedRecordingFailuresAfterExplicitSaveDecision() async throws {
        let store = try makeStore()
        let controller = MeetsController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        controller.updateConfig { $0.meetingRecordingSavePolicy = .prompt }

        let result = MeetingSessionResult(
            title: "Explicit Save Failed Retention",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(30),
            durationSeconds: 30,
            rawTranscript: "Explicit save retention failure transcript.",
            formattedNotes: "## Summary\nExplicit save retention failure notes.",
            retainedRecordingURL: nil,
            retainedRecordingError: CocoaError(.fileWriteUnknown),
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        let preparedRecordingSave = await controller.prepareMeetingRecordingSave(
            for: result,
            saveDecision: true
        )
        let persistenceResult = try controller.persistCompletedMeetingResult(
            result,
            preparedRecordingSave: preparedRecordingSave
        )

        let storedMeeting = try #require(try store.meeting(id: persistenceResult.meetingID))
        #expect(storedMeeting.savedRecordingPath == nil)
        #expect(persistenceResult.recordingSaveError != nil)
    }

    @Test("persistCompletedMeetingResult preserves user-edited live meeting title")
    func persistCompletedMeetingResultPreservesEditedLiveTitle() async throws {
        let store = try makeStore()
        let controller = MeetsController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        let start = Date()
        let liveID = try store.createLiveMeeting(title: "Meeting", calendarEventID: nil, startTime: start)
        try store.updateMeetingTitle(id: liveID, title: "Investor Follow-up")

        let result = MeetingSessionResult(
            title: "Generated Summary Title",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(120),
            durationSeconds: 120,
            rawTranscript: "Discussed fundraising updates.",
            formattedNotes: "## Summary\nFundraising updates discussed.",
            retainedRecordingURL: nil,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        _ = try controller.persistCompletedMeetingResult(
            result,
            existingMeetingID: liveID,
            preparedRecordingSave: .none
        )

        let storedMeeting = try #require(try store.meeting(id: liveID))
        #expect(storedMeeting.title == "Investor Follow-up")
        #expect(storedMeeting.formattedNotes == "## Summary\nFundraising updates discussed.")
    }

    @Test("persistCompletedMeetingResult uses wall-clock duration for normal existing meetings")
    func persistCompletedMeetingResultUsesWallClockDurationForNormalExistingMeetings() async throws {
        let store = try makeStore()
        let controller = MeetsController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        let start = Date()
        let liveID = try store.createLiveMeeting(title: "Meeting", calendarEventID: nil, startTime: start)
        let result = MeetingSessionResult(
            title: "Generated Summary Title",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(120),
            durationSeconds: 30,
            rawTranscript: "Discussed regular completion.",
            formattedNotes: "## Summary\nRegular completion.",
            retainedRecordingURL: nil,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        _ = try controller.persistCompletedMeetingResult(
            result,
            existingMeetingID: liveID,
            preparedRecordingSave: .none
        )

        let storedMeeting = try #require(try store.meeting(id: liveID))
        #expect(storedMeeting.durationSeconds == 120)
    }

    @Test("persistCompletedMeetingResult preserves cached live title before debounce")
    func persistCompletedMeetingResultPreservesCachedLiveTitle() async throws {
        let store = try makeStore()
        let controller = MeetsController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        let start = Date()
        let liveID = try store.createLiveMeeting(title: "Meeting", calendarEventID: nil, startTime: start)
        controller.cacheMeetingTitle(id: liveID, title: "Status Bar Stop Title")

        let result = MeetingSessionResult(
            title: "Generated Summary Title",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(120),
            durationSeconds: 120,
            rawTranscript: "Discussed follow-up items.",
            formattedNotes: "## Summary\nFollow-up items discussed.",
            retainedRecordingURL: nil,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        _ = try controller.persistCompletedMeetingResult(
            result,
            existingMeetingID: liveID,
            preparedRecordingSave: .none
        )

        let storedMeeting = try #require(try store.meeting(id: liveID))
        #expect(storedMeeting.title == "Status Bar Stop Title")
        #expect(storedMeeting.formattedNotes == "## Summary\nFollow-up items discussed.")
    }

    @Test("persistCompletedMeetingResult writes the stop-time manual notes snapshot")
    func persistCompletedMeetingResultCarriesStopTimeManualNotes() async throws {
        let store = try makeStore()
        let controller = MeetsController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )
        let start = Date()
        let liveID = try store.createLiveMeeting(title: "Meeting", calendarEventID: nil, startTime: start)

        // Simulates the user typing during the recording and the controller
        // freezing the notes at stop: the completed row must keep the raw
        // notes even though the row never received a debounced write.
        let result = MeetingSessionResult(
            title: "Generated Summary Title",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(120),
            durationSeconds: 120,
            rawTranscript: "Discussed the roadmap.",
            formattedNotes: "## Summary\nRoadmap reviewed.\n\n### Written notes\n\n- Ship today",
            manualNotes: "- Ship today",
            retainedRecordingURL: nil,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )

        _ = try controller.persistCompletedMeetingResult(
            result,
            existingMeetingID: liveID,
            preparedRecordingSave: .none
        )

        let storedMeeting = try #require(try store.meeting(id: liveID))
        #expect(storedMeeting.status == .completed)
        #expect(storedMeeting.manualNotes == "- Ship today")
    }

    @Test("resummary context strips appended written notes section")
    func resummaryContextStripsWrittenNotesSection() {
        let meeting = makeMeeting(
            id: 909,
            title: "Resummarize",
            formattedNotes: "## Summary\n- Decision captured\n\n### Written notes\n\n- User typed this",
            status: .completed,
            manualNotes: "- User typed this"
        )

        let context = MeetsController.notesContextForResummary(meeting)

        #expect(context == "## Summary\n- Decision captured")
    }

    @Test("startup recovery preserves stale live meetings with notes")
    func startupRecoveryPreservesStaleLiveMeetingWithNotes() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Crashed Draft", calendarEventID: nil, startTime: Date())
        try store.updateMeetingManualNotes(id: id, manualNotes: "Important draft")
        let controller = MeetsController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )

        controller.recoverStaleLiveMeetings()

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.status == .failed)
        #expect(meeting.manualNotes == "Important draft")
    }

    @Test("startup recovery marks empty stale live drafts as failed")
    func startupRecoveryMarksEmptyStaleLiveDraftsFailed() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Empty Draft", calendarEventID: nil, startTime: Date())
        let controller = MeetsController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )

        controller.recoverStaleLiveMeetings()

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.status == .failed)
    }

    @Test("startup recovery uses live transcript checkpoints before failing stale meetings")
    func startupRecoveryUsesLiveTranscriptCheckpoints() throws {
        let store = try makeStore()
        let id = try store.createLiveMeeting(title: "Checkpoint Draft", calendarEventID: nil, startTime: Date())
        try store.appendLiveTranscriptCheckpoints(meetingID: id, entries: [
            LiveTranscriptCheckpointEntry(timestampLabel: "11:45:02", speaker: "Others", startSeconds: 2, endSeconds: 3, text: "The fallback transcript survived.")
        ])
        let controller = MeetsController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store
        )

        controller.recoverStaleLiveMeetings()

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.status == .completed)
        #expect(meeting.notesState == .rawTranscriptFallback)
        #expect(meeting.rawTranscript == "[11:45:02] Others: The fallback transcript survived.")
        #expect(try store.liveTranscriptCheckpointText(meetingID: id) == nil)
    }

    @Test("showMeetingTemplatesManager preserves current meetings context and presents manager")
    func showMeetingTemplatesManagerPresentsManager() {
        let controller = makeController()

        controller.appState.selectedTab = .settings
        controller.appState.meetingsNavigationState = .document(404)
        controller.appState.isMeetingTemplatesManagerPresented = false

        controller.showMeetingTemplatesManager()

        // The manager sheet is hosted at the dashboard root, so presenting it
        // never detours through the Meetings tab.
        #expect(controller.appState.selectedTab == .settings)
        #expect(controller.appState.meetingsNavigationState == .document(404))
        #expect(controller.appState.isMeetingTemplatesManagerPresented == true)
    }

    @Test("deleteCustomMeetingTemplate resets default template when deleting the active default")
    func deletingDefaultCustomTemplateResetsDefaultToAuto() {
        let controller = makeController()
        let customTemplate = CustomMeetingTemplate(
            id: "tmpl_customer_followup",
            name: "Customer Follow-Up",
            prompt: "## Summary",
            icon: "person.2.fill"
        )

        controller.updateConfig {
            $0.customMeetingTemplates = [customTemplate]
            $0.defaultMeetingTemplateID = customTemplate.id
        }

        controller.deleteCustomMeetingTemplate(id: customTemplate.id)

        #expect(controller.config.defaultMeetingTemplateID == MeetingTemplates.autoID)
        #expect(controller.appState.config.defaultMeetingTemplateID == MeetingTemplates.autoID)
        #expect(controller.config.customMeetingTemplates.isEmpty)
    }

    @Test("meeting transcription backend selection is independent from dictation backend")
    func meetingTranscriptionBackendSelectionIsIndependent() {
        let controller = makeController()

        controller.selectBackend(.parakeetEnglish)
        controller.selectMeetingTranscriptionBackend(.whisperLargeTurbo, requireDownloaded: false)

        #expect(controller.appState.selectedBackend == .parakeetEnglish)
        #expect(controller.appState.selectedMeetingTranscriptionBackend == .whisperLargeTurbo)
        #expect(controller.appState.config.sttModel == BackendOption.parakeetEnglish.model)
        #expect(controller.appState.config.meetingTranscriptionModel == BackendOption.whisperLargeTurbo.model)
    }

    @Test("legacy OpenRouter credentials expose the same model controls as stored credentials")
    func legacyOpenRouterCredentialShowsModels() {
        let configDirectory = makeSupportDirectory()
        let authDirectory = makeSupportDirectory()
        let openRouterAuth = OpenRouterAuthManager(
            credentialStore: OpenRouterCredentialStore(supportDirectory: authDirectory),
            loadData: { _ in throw URLError(.unsupportedURL) },
            openURL: { _ in false },
            environment: { [:] }
        )
        let controller = MeetsController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                appIcon: nil,
                bundlePath: nil
            ),
            configStore: ConfigStore(supportDirectory: configDirectory),
            openRouterAuth: openRouterAuth
        )
        controller.updateConfig { $0.openRouterAPIKey = " sk-or-v1-legacy " }

        #expect(!openRouterAuth.isAuthenticated)
        #expect(controller.canUseSummaryProvider(.openRouter))
    }

    @Test("failed OpenRouter credential deletion preserves provider selections")
    func failedOpenRouterDisconnectPreservesSelections() throws {
        let supportDirectory = makeSupportDirectory()
        let configStore = ConfigStore(supportDirectory: supportDirectory)
        let credentialStore = OpenRouterCredentialStore(supportDirectory: supportDirectory)
        try credentialStore.save(OpenRouterCredential(apiKey: "sk-or-v1-retained", userID: nil))
        let openRouterAuth = OpenRouterAuthManager(
            credentialStore: credentialStore,
            loadData: { _ in throw URLError(.unsupportedURL) },
            openURL: { _ in false },
            environment: { [:] },
            deleteCredential: { throw OpenRouterDisconnectTestError.expected }
        )
        let controller = MeetsController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                appIcon: nil,
                bundlePath: nil
            ),
            configStore: configStore,
            openRouterAuth: openRouterAuth
        )
        controller.updateConfig {
            $0.meetingSummaryBackend = MeetingSummaryBackendOption.openRouter.backend
            $0.postProcessorBackend = LLMBackendOption.openRouter.backend
        }

        let error = controller.signOutOpenRouter()

        #expect(error == OpenRouterAuthError.credentialDeletionFailed.errorDescription)
        #expect(openRouterAuth.isAuthenticated)
        #expect(controller.selectedMeetingSummaryBackend == .openRouter)
        #expect(controller.config.postProcessorBackend == LLMBackendOption.openRouter.backend)
    }

    @Test("environment OpenRouter credential survives local disconnect without resetting providers")
    func environmentOpenRouterCredentialPreservesSelections() throws {
        let supportDirectory = makeSupportDirectory()
        let configStore = ConfigStore(supportDirectory: supportDirectory)
        let credentialStore = OpenRouterCredentialStore(supportDirectory: supportDirectory)
        let openRouterAuth = OpenRouterAuthManager(
            credentialStore: credentialStore,
            loadData: { _ in throw URLError(.unsupportedURL) },
            openURL: { _ in false },
            environment: { ["OPENROUTER_API_KEY": "sk-or-v1-environment"] }
        )
        try openRouterAuth.storeManualAPIKey("sk-or-v1-local")
        let controller = MeetsController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                appIcon: nil,
                bundlePath: nil
            ),
            configStore: configStore,
            openRouterAuth: openRouterAuth
        )
        controller.updateConfig {
            $0.meetingSummaryBackend = MeetingSummaryBackendOption.openRouter.backend
            $0.postProcessorBackend = LLMBackendOption.openRouter.backend
        }

        #expect(controller.signOutOpenRouter() == nil)

        #expect(openRouterAuth.isAuthenticated)
        #expect(openRouterAuth.hasEnvironmentCredential)
        #expect(!openRouterAuth.hasStoredCredential)
        #expect(controller.appState.isOpenRouterEnvironmentManaged)
        #expect(controller.selectedMeetingSummaryBackend == .openRouter)
        #expect(controller.config.postProcessorBackend == LLMBackendOption.openRouter.backend)
    }

    @Test("updateConfig persists normalized meeting transcription backend")
    func updateConfigPersistsNormalizedMeetingTranscriptionBackend() {
        let controller = makeController()
        let originalConfig = controller.config
        defer {
            controller.updateConfig { config in
                config = originalConfig
            }
        }

        controller.updateConfig {
            $0.sttBackend = BackendOption.parakeetMultilingual.backend
            $0.sttModel = BackendOption.parakeetMultilingual.model
            $0.meetingTranscriptionBackend = BackendOption.nemotron35Multilingual.backend
            $0.meetingTranscriptionModel = BackendOption.nemotron35Multilingual.model
        }

        #expect(controller.appState.selectedMeetingTranscriptionBackend.supportsMeetingTranscription)
        #expect(controller.appState.config.meetingTranscriptionBackend != BackendOption.nemotron35Multilingual.backend)
        #expect(controller.appState.config.meetingTranscriptionModel != BackendOption.nemotron35Multilingual.model)
        #expect(controller.config.meetingTranscriptionBackend == controller.appState.selectedMeetingTranscriptionBackend.backend)
        #expect(controller.config.meetingTranscriptionModel == controller.appState.selectedMeetingTranscriptionBackend.model)
    }

    private func makeMeeting(
        id: Int64,
        title: String,
        formattedNotes: String = "## Summary",
        status: MeetingStatus = .completed,
        manualNotes: String = ""
    ) -> MeetingRecord {
        MeetingRecord(
            id: id,
            title: title,
            startTime: "2026-03-24 10:00",
            durationSeconds: 1800,
            rawTranscript: "Transcript",
            formattedNotes: formattedNotes,
            wordCount: 42,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil,
            status: status,
            manualNotes: manualNotes,
            selectedTemplateID: MeetingTemplates.autoID,
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: ""
        )
    }

    // MARK: - Add to Event (meeting ↔ calendar event links)

    private func makeManualMeeting(in store: DictationStore) throws -> Int64 {
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

    private func makeTestEvent(
        id: String = "event-id-1",
        title: String = "Design Sync",
        start: Date = Date(timeIntervalSince1970: 1_775_000_000),
        attendees: [MeetingParticipantDraft] = []
    ) -> UnifiedCalendarEvent {
        UnifiedCalendarEvent(
            id: id,
            title: title,
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            isAllDay: false,
            source: .eventKit,
            calendarID: "cal-a",
            attendees: attendees.map { draft in
                CalendarAttendee(
                    identifier: draft.emailAddress.map { "mailto:\($0)" } ?? draft.participantIdentifier,
                    displayName: draft.displayName,
                    emailAddress: draft.emailAddress
                )!
            }
        )
    }

    private func waitForAttendees(
        _ expected: Int,
        in store: DictationStore,
        meetingID: Int64
    ) async throws {
        // Attendees persist through a chained Task.detached queue; poll the
        // store until the rows land (bounded).
        for _ in 0..<200 {
            if try store.listMeetingParticipants(meetingID: meetingID).count >= expected {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MeetingLinkTestError.timedOut
    }

    private enum MeetingLinkTestError: Error {
        case timedOut
    }

    @Test("linkMeetingToEvent attaches a manual meeting and auto-adds event attendees")
    func linkMeetingToEventAttachesAndAddsAttendees() async throws {
        let store = try makeStore()
        let controller = makeController(dictationStore: store)
        let meetingID = try makeManualMeeting(in: store)
        controller.syncAppState()

        let event = makeTestEvent(attendees: [
            MeetingParticipantDraft(
                participantIdentifier: "email:alice@example.test",
                displayName: "Alice Example",
                emailAddress: "alice@example.test"
            )
        ])
        await controller.linkMeetingToEvent(meetingID: meetingID, event: event)
        try await waitForAttendees(1, in: store, meetingID: meetingID)

        let meeting = try #require(try store.meeting(id: meetingID))
        // A meeting with no calendar identity adopts the first event as its
        // primary event.
        #expect(meeting.calendarEventID == "event-id-1")
        #expect(meeting.calendarOccurrence?.identityKey == event.resolvedCalendarOccurrence.identityKey)
        #expect(controller.eventIDsLinked(toMeeting: meeting) == ["event-id-1"])

        // Attendees arrive as calendar-sourced people, deduped by identifier.
        let participants = try store.listMeetingParticipants(meetingID: meetingID)
        #expect(participants.count == 1)
        #expect(participants.first?.displayName == "Alice Example")

        // Linking the same event again is a no-op (no duplicate link, no
        // duplicate attendee).
        await controller.linkMeetingToEvent(meetingID: meetingID, event: event)
        try await waitForAttendees(1, in: store, meetingID: meetingID)
        #expect(try store.meetingEventLinks(meetingID: meetingID).count == 1)
        #expect(try store.listMeetingParticipants(meetingID: meetingID).count == 1)
    }

    @Test("linkMeetingToEvent supports multiple events and unlink removes one")
    func linkMeetingToEventSupportsMultipleAndUnlink() async throws {
        let store = try makeStore()
        let controller = makeController(dictationStore: store)
        let meetingID = try makeManualMeeting(in: store)
        controller.syncAppState()

        let first = makeTestEvent(id: "event-1", title: "Standup", start: Date(timeIntervalSince1970: 1_775_000_000))
        let second = makeTestEvent(id: "event-2", title: "Planning", start: Date(timeIntervalSince1970: 1_775_100_000))
        await controller.linkMeetingToEvent(meetingID: meetingID, event: first)
        await controller.linkMeetingToEvent(meetingID: meetingID, event: second)
        controller.syncAppState()

        let meeting = try #require(try store.meeting(id: meetingID))
        // Primary stays the first-linked event.
        #expect(meeting.calendarEventID == "event-1")
        // Both events surface as linked; the controller-side lookup is
        // id-based and cannot see the primary after regeneration, so it is
        // driven by meetingEventLinks + calendarEventID in eventIDsLinked.
        let linkedIDs = controller.eventIDsLinked(toMeeting: meeting)
        #expect(linkedIDs.contains("event-1"))
        #expect(linkedIDs.contains("event-2"))
        #expect(controller.meetingEventLinks(meetingID: meetingID).count == 2)

        // The store's event-side reverse lookup sees both links.
        #expect(Set(try store.meetingsLinked(toEventID: "event-1")) == [meetingID])
        #expect(Set(try store.meetingsLinked(toEventID: "event-2")) == [meetingID])

        // Unlinking the second event removes only that link; the primary
        // identity stays intact.
        await controller.unlinkMeetingFromEvent(meetingID: meetingID, eventID: "event-2")
        let remaining = try store.meetingEventLinks(meetingID: meetingID)
        #expect(remaining.count == 1)
        #expect(remaining.first?.eventID == "event-1")
        let after = try #require(try store.meeting(id: meetingID))
        #expect(after.calendarEventID == "event-1")
    }

    @Test("linkage derive surfaces explicitly linked meetings as recorded")
    func linkageDeriveSurfacesExplicitlyLinkedMeetings() throws {
        let meeting = makeMeeting(id: 1, title: "Manual Sync")
        let event = UnifiedCalendarEvent(
            id: "event-1",
            title: "Design Sync",
            startDate: Date(timeIntervalSince1970: 1_775_000_000),
            endDate: Date(timeIntervalSince1970: 1_775_003_600),
            isAllDay: false,
            source: .eventKit,
            calendarID: "cal-a"
        )
        let meetings: [MeetingRecord] = []

        // Without the explicit link the event has no meeting (no keys, and
        // the title-window fallback needs a matching start time).
        let unlinked = MeetingEventLinkage.derive(event: event, meetings: meetings)
        #expect(unlinked.linkedMeeting == nil)

        // The explicit link id resolves the attached meeting as the event's
        // meeting even though it was never recorded from the calendar.
        let withMeeting = MeetingEventLinkage.derive(
            event: event,
            meetings: [meeting],
            additionalLinkedMeetingIDs: [1]
        )
        #expect(withMeeting.linkedMeeting?.id == 1)
        #expect(withMeeting.state == .completed)
    }
}

@Suite("Meeting browser logic")
struct MeetingBrowserLogicTests {

    @Test("folder breadcrumb leaf name is the last path component")
    func folderBreadcrumbLeafName() {
        let folders = [
            MeetingFolder(id: 1, name: "Clients", parentID: nil, createdAt: ""),
            MeetingFolder(id: 2, name: "Acme Inc", parentID: 1, createdAt: ""),
            MeetingFolder(id: 3, name: "Quarterly reviews", parentID: 2, createdAt: "")
        ]
        let paths = MeetingFolderBreadcrumbs.paths(for: folders)

        #expect(paths[3] == "Clients / Acme Inc / Quarterly reviews")
        #expect(MeetingFolderBreadcrumbs.leafName(of: paths[3] ?? "") == "Quarterly reviews")
        #expect(MeetingFolderBreadcrumbs.leafName(of: "Inbox") == "Inbox")
    }

    @Test("available filters expand with older meeting history")
    func availableFiltersExpandWithHistory() {
        let now = Date(timeIntervalSince1970: 1_710_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let meetings = [
            makeMeeting(id: 1, daysAgo: 40, title: "Oldest"),
            makeMeeting(id: 2, daysAgo: 1, title: "Recent")
        ]

        let filters = MeetingBrowserLogic.availableFilters(for: meetings, now: now, calendar: calendar)

        #expect(filters == [.all, .last2Days, .lastWeek, .last2Weeks, .lastMonth, .last3Months])
    }

    @Test("filtering excludes invalid dates and sorts newest first")
    func filteringNewestFirst() {
        let now = Date(timeIntervalSince1970: 1_710_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let meetings = [
            makeMeeting(id: 1, daysAgo: 10, title: "Too old"),
            makeMeeting(id: 2, daysAgo: 2, title: "Recent A"),
            makeMeeting(id: 3, daysAgo: 1, title: "Recent B"),
            makeMeeting(id: 4, rawDate: "not-a-date", title: "Invalid")
        ]

        let filtered = MeetingBrowserLogic.filteredMeetings(
            from: meetings,
            filter: .lastWeek,
            sort: .newestFirst,
            now: now,
            calendar: calendar
        )

        #expect(filtered.map(\.id) == [3, 2])
    }

    @Test("all filter keeps invalid dates and oldest-first pushes them to the front")
    func allFilterOldestFirst() {
        let now = Date(timeIntervalSince1970: 1_710_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let meetings = [
            makeMeeting(id: 10, daysAgo: 2, title: "Recent"),
            makeMeeting(id: 11, daysAgo: 8, title: "Older"),
            makeMeeting(id: 12, rawDate: "invalid-date", title: "Invalid")
        ]

        let filtered = MeetingBrowserLogic.filteredMeetings(
            from: meetings,
            filter: .all,
            sort: .oldestFirst,
            now: now,
            calendar: calendar
        )

        #expect(filtered.map(\.id) == [12, 11, 10])
    }

    @Test("formatStartTime converts UTC ISO timestamps to the requested timezone")
    func formatStartTimeConvertsUTC() {
        let timeZone = TimeZone(identifier: "America/Los_Angeles")!
        guard let date = MeetingBrowserLogic.parseDate("2025-06-15T19:30:45Z") else {
            Issue.record("Expected ISO timestamp to parse")
            return
        }

        let formatted = MeetingBrowserLogic.formatStartTime(
            "2025-06-15T19:30:45Z",
            locale: Locale(identifier: "en_US"),
            timeZone: timeZone
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)

        #expect(components.year == 2025)
        #expect(components.month == 6)
        #expect(components.day == 15)
        #expect(components.hour == 12)
        #expect(components.minute == 30)
        #expect(formatted.contains("Jun 15, 2025"))
        #expect(formatted.contains("12:30"))
        #expect(formatted.localizedCaseInsensitiveContains("PM"))
    }

    @Test("formatListDate names recent days and drops seconds")
    func formatListDateNamesRecentDays() {
        // Rows in the library show this instead of the full timestamp, so the
        // two things that must never drift are the named recent days and the
        // absence of seconds.
        let timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let locale = Locale(identifier: "en_US")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        guard let todayNoon = calendar.date(bySettingHour: 12, minute: 4, second: 30, of: now),
              let yesterday = calendar.date(byAdding: .day, value: -1, to: todayNoon),
              let lastMonth = calendar.date(byAdding: .day, value: -40, to: todayNoon),
              let lastYear = calendar.date(byAdding: .year, value: -1, to: todayNoon) else {
            Issue.record("Expected the fixture dates to resolve")
            return
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        func render(_ date: Date) -> String {
            MeetingBrowserLogic.formatListDate(
                formatter.string(from: date),
                now: now,
                locale: locale,
                timeZone: timeZone,
                calendar: calendar
            )
        }

        let todayText = render(todayNoon)
        #expect(todayText.hasPrefix("Today \u{00B7} "))
        #expect(todayText.contains("12:04"))
        #expect(todayText.localizedCaseInsensitiveContains("PM"))
        #expect(!todayText.contains(":30"))

        #expect(render(yesterday).hasPrefix("Yesterday \u{00B7} "))

        let sameYearText = render(lastMonth)
        #expect(!sameYearText.contains("Today"))
        #expect(!sameYearText.contains("Yesterday"))
        #expect(!sameYearText.contains(String(calendar.component(.year, from: now))))

        #expect(render(lastYear).contains(String(calendar.component(.year, from: lastYear))))
    }

    private static func isoDate(daysAgo: Int, now: Date, calendar: Calendar) -> String {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func makeMeeting(id: Int64, daysAgo: Int, title: String) -> MeetingRecord {
        let now = Date(timeIntervalSince1970: 1_710_000_000)
        let calendar = Calendar(identifier: .gregorian)
        return makeMeeting(
            id: id,
            rawDate: Self.isoDate(daysAgo: daysAgo, now: now, calendar: calendar),
            title: title
        )
    }

    private func makeMeeting(id: Int64, rawDate: String, title: String) -> MeetingRecord {
        MeetingRecord(
            id: id,
            title: title,
            startTime: rawDate,
            durationSeconds: 1800,
            rawTranscript: "Transcript",
            formattedNotes: "## Summary",
            wordCount: 42,
            folderID: nil,
            calendarEventID: nil,
            micAudioPath: nil,
            systemAudioPath: nil,
            selectedTemplateID: MeetingTemplates.autoID,
            selectedTemplateName: "Auto",
            selectedTemplateKind: .auto,
            selectedTemplatePrompt: ""
        )
    }
}

/// Follow-up hierarchy coverage: deep chains, siblings, out-of-scope parents,
/// dangling links, cycles, date-filter context, sort ties, and shelves that
/// stay complete when the loaded record window excludes members — plus the
/// ledger sections, gutters, and follow-up pills those shelves are rendered
/// into.
@Suite("Meeting browser shelves")
struct MeetingBrowserShelfTests {
    private let baseDate = Date(timeIntervalSince1970: 1_770_000_000)
    private let calendar = Calendar(identifier: .gregorian)

    private func dateString(daysAgo: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: baseDate.addingTimeInterval(-daysAgo * 86_400))
    }

    private func entry(
        _ id: Int64,
        daysAgo: Double,
        followUpTo: Int64? = nil,
        predecessorTitle: String? = nil
    ) -> MeetingBrowserEntry {
        MeetingBrowserEntry(
            id: id,
            title: "Meeting \(id)",
            startTime: dateString(daysAgo: daysAgo),
            durationSeconds: 1800,
            folderID: nil,
            status: .completed,
            followUpToID: followUpTo,
            predecessorTitle: predecessorTitle
        )
    }

    private func record(_ id: Int64, daysAgo: Double) -> MeetingRecord {
        MeetingRecord(
            id: id,
            title: "Meeting \(id)",
            startTime: dateString(daysAgo: daysAgo),
            durationSeconds: 1800,
            rawTranscript: "Transcript \(id)",
            formattedNotes: "## Summary \(id)",
            wordCount: 42,
            folderID: nil
        )
    }

    private func shelves(
        _ entries: [MeetingBrowserEntry],
        records: [MeetingRecord] = [],
        filter: MeetingBrowserFilter = .all,
        sort: MeetingBrowserSort = .newestFirst,
        now: Date? = nil,
        calendar: Calendar? = nil
    ) -> MeetingBrowserShelfPresentation {
        MeetingBrowserLogic.shelves(
            entries: entries,
            records: records,
            filter: filter,
            sort: sort,
            now: now ?? baseDate,
            calendar: calendar ?? self.calendar
        )
    }

    @Test("a deep chain renders as one shelf in thread order")
    func deepChainRendersInThreadOrder() throws {
        var entries: [MeetingBrowserEntry] = []
        for index in 1...5 {
            let parent: Int64? = index == 1 ? nil : Int64(index - 1)
            entries.append(entry(Int64(index), daysAgo: Double(6 - index), followUpTo: parent))
        }

        let presentation = shelves(entries)
        let shelf = try #require(presentation.shelves.first)

        #expect(presentation.shelves.count == 1)
        #expect(shelf.nodes.map(\.id) == [1, 2, 3, 4, 5])
        #expect(shelf.nodes.map(\.depth) == [0, 1, 2, 3, 4])
        #expect(shelf.descendants.count == 4)
        #expect(presentation.matchCount == 5)
        #expect(presentation.displayedCount == 5)
    }

    @Test("indentation stops at the cap and deeper rows name their parent")
    func indentationCapNamesParentBeyondCap() throws {
        var entries: [MeetingBrowserEntry] = []
        for index in 1...8 {
            let parent: Int64? = index == 1 ? nil : Int64(index - 1)
            entries.append(entry(Int64(index), daysAgo: Double(9 - index), followUpTo: parent))
        }

        let shelf = try #require(shelves(entries).shelves.first)

        #expect(shelf.nodes.map(\.id) == [1, 2, 3, 4, 5, 6, 7, 8])
        // Depths up to the cap are carried by the rail alone.
        for node in shelf.nodes where node.depth <= MeetingBrowserLogic.indentationCapDepth {
            #expect(node.parentLinkTitle == nil)
        }
        // Past the cap every descendant still names where it hangs from.
        for node in shelf.nodes where node.depth > MeetingBrowserLogic.indentationCapDepth {
            #expect(node.parentLinkTitle == "Meeting \(node.id - 1)")
        }
    }

    @Test("siblings render chronologically and ties fall back to id")
    func siblingsRenderChronologicallyWithStableTies() throws {
        let entries = [
            entry(1, daysAgo: 10),
            entry(4, daysAgo: 5, followUpTo: 1),
            entry(2, daysAgo: 5, followUpTo: 1),
            entry(3, daysAgo: 2, followUpTo: 1)
        ]

        let shelf = try #require(shelves(entries).shelves.first)

        #expect(shelf.nodes.map(\.id) == [1, 2, 4, 3])
        #expect(shelf.nodes.map(\.depth) == [0, 1, 1, 1])
    }

    @Test("a child of an out-of-scope parent is a scoped root that links to it")
    func childOutsideScopeBecomesScopedRootWithParentLink() throws {
        let entries = [
            MeetingBrowserEntry(
                id: 42,
                title: "Child",
                startTime: dateString(daysAgo: 1),
                durationSeconds: 1800,
                folderID: 7,
                status: .completed,
                followUpToID: 99,
                predecessorTitle: "Outside parent"
            )
        ]

        let presentation = shelves(entries)
        let shelf = try #require(presentation.shelves.first)

        #expect(presentation.shelves.count == 1)
        #expect(shelf.root.id == 42)
        #expect(shelf.root.depth == 0)
        #expect(shelf.root.entry.followUpToID == 99)
        #expect(shelf.root.externalParent == MeetingBrowserParentLink(id: 99, title: "Outside parent"))
        #expect(shelf.root.parentLinkTitle == "Outside parent")
    }

    @Test("a dangling predecessor keeps the meeting visible without inventing a parent")
    func danglingParentKeepsMeetingVisible() throws {
        let shelf = try #require(shelves([entry(7, daysAgo: 1, followUpTo: 404)]).shelves.first)

        #expect(shelf.root.id == 7)
        #expect(shelf.root.externalParent == nil)
        #expect(shelf.root.parentLinkTitle == nil)
        #expect(shelf.root.entry.followUpToID == 404)
    }

    @Test("a self-linked meeting renders once as its own shelf")
    func selfLinkRendersOnce() throws {
        let presentation = shelves([entry(9, daysAgo: 1, followUpTo: 9)])
        let shelf = try #require(presentation.shelves.first)

        #expect(presentation.shelves.count == 1)
        #expect(shelf.totalCount == 1)
        #expect(shelf.root.parentLinkTitle == nil)
    }

    @Test("a follow-up cycle breaks at its lowest id on the cycle")
    func pureCycleBreaksAtCycleMinimum() throws {
        let presentation = shelves([
            entry(20, daysAgo: 2, followUpTo: 21),
            entry(21, daysAgo: 1, followUpTo: 20)
        ])
        let shelf = try #require(presentation.shelves.first)

        #expect(presentation.shelves.count == 1)
        #expect(shelf.nodes.map(\.id) == [20, 21])
        #expect(shelf.nodes.map(\.depth) == [0, 1])
    }

    @Test("a lower-id leaf hanging off a higher-id cycle stays a descendant")
    func lowerIDLeafAttachedToHigherIDCycleStaysDescendant() throws {
        // The leaf 1 has the lowest id but is not on the 5 ⇄ 6 cycle, so
        // breaking at it would strand both cycle members.
        let presentation = shelves([
            entry(1, daysAgo: 3, followUpTo: 5),
            entry(5, daysAgo: 2, followUpTo: 6),
            entry(6, daysAgo: 1, followUpTo: 5)
        ])
        let shelf = try #require(presentation.shelves.first)

        #expect(presentation.shelves.count == 1)
        #expect(presentation.displayedCount == 3)
        #expect(shelf.id == 5)
        #expect(shelf.nodes.map(\.id) == [5, 1, 6])
        #expect(shelf.nodes.map(\.depth) == [0, 1, 1])
    }

    @Test("a rooted tree and two cycles each keep their members and descendants")
    func mixedRootedTreeAndTwoCyclesKeepEveryMemberOnce() throws {
        let entries = [
            entry(10, daysAgo: 9),
            entry(11, daysAgo: 8, followUpTo: 10),
            entry(20, daysAgo: 7, followUpTo: 21),
            entry(21, daysAgo: 6, followUpTo: 20),
            entry(22, daysAgo: 5, followUpTo: 20),
            entry(23, daysAgo: 4, followUpTo: 22),
            entry(30, daysAgo: 3, followUpTo: 31),
            entry(31, daysAgo: 2, followUpTo: 30)
        ]

        let presentation = shelves(entries)
        let renderedIDs = presentation.shelves.flatMap { $0.nodes.map(\.id) }

        #expect(presentation.shelves.count == 3)
        #expect(renderedIDs.count == entries.count)
        #expect(Set(renderedIDs).count == renderedIDs.count)
        #expect(presentation.displayedCount == entries.count)

        let tree = try #require(presentation.shelves.first { $0.id == 10 })
        #expect(tree.nodes.map(\.id) == [10, 11])

        let firstCycle = try #require(presentation.shelves.first { $0.id == 20 })
        #expect(firstCycle.nodes.map(\.id) == [20, 21, 22, 23])
        #expect(firstCycle.nodes.map(\.depth) == [0, 1, 1, 2])

        let secondCycle = try #require(presentation.shelves.first { $0.id == 30 })
        #expect(secondCycle.nodes.map(\.id) == [30, 31])
    }

    @Test("a date range keeps matching descendants inside their thread")
    func filterRetainsAncestorContextWithoutDoubleCounting() throws {
        let entries = [
            entry(1, daysAgo: 20),
            entry(2, daysAgo: 15, followUpTo: 1),
            entry(3, daysAgo: 1, followUpTo: 2)
        ]

        let presentation = shelves(entries, filter: .lastWeek)
        let shelf = try #require(presentation.shelves.first)

        #expect(presentation.shelves.count == 1)
        #expect(shelf.nodes.map(\.id) == [1, 2, 3])
        #expect(shelf.nodes.map(\.matchesFilter) == [false, false, true])
        #expect(shelf.matchCount == 1)
        #expect(shelf.contextCount == 2)
        #expect(presentation.matchCount == 1)
        #expect(presentation.displayedCount == 3)
        #expect(presentation.contextCount == 2)
    }

    @Test("a filtered shelf sorts by its matching meeting, not the retained ancestor")
    func filteredShelfSortsByMatchingMember() throws {
        let entries = [
            entry(1, daysAgo: 30),
            entry(2, daysAgo: 1, followUpTo: 1),
            entry(3, daysAgo: 2)
        ]

        let presentation = shelves(entries, filter: .lastWeek)

        // The retained 30-day-old ancestor must not push its thread behind the
        // standalone meeting that actually matched two days ago.
        #expect(presentation.shelves.map(\.id) == [1, 3])
        #expect(presentation.matchCount == 2)
        #expect(presentation.displayedCount == 3)

        // Oldest-first compares the matching members too: the standalone
        // meeting matched two days ago, the thread only one day ago, so the
        // standalone leads. Counting the retained ancestor here would wrongly
        // put the thread first.
        let oldest = shelves(entries, filter: .lastWeek, sort: .oldestFirst)
        #expect(oldest.shelves.map(\.id) == [3, 1])
    }

    @Test("families sort by activity and ties fall back to root id")
    func familiesSortByActivityAndTieOnRootID() {
        let entries = [
            entry(1, daysAgo: 10),
            entry(2, daysAgo: 1, followUpTo: 1),
            entry(9, daysAgo: 4),
            entry(5, daysAgo: 4)
        ]

        let newest = shelves(entries, sort: .newestFirst)
        #expect(newest.shelves.map(\.id) == [1, 5, 9])

        let oldest = shelves(entries, sort: .oldestFirst)
        // Family 1's oldest member is 10 days back, so it leads; 5 and 9 tie at
        // four days and resolve by root id.
        #expect(oldest.shelves.map(\.id) == [1, 5, 9])
    }

    @Test("threads stay complete when the loaded record window excludes members")
    func shelvesStayCompleteBeyondLoadedWindow() throws {
        var entries: [MeetingBrowserEntry] = []
        for id in 1...210 {
            entries.append(entry(Int64(id), daysAgo: Double(211 - id)))
        }
        // A family whose root sits outside the recent window while its
        // follow-ups sit inside it.
        entries[4] = entry(5, daysAgo: 206)
        entries[199] = entry(200, daysAgo: 11, followUpTo: 5)
        entries[204] = entry(205, daysAgo: 6, followUpTo: 5)
        // A family with a member older than the window.
        entries[2] = entry(3, daysAgo: 208, followUpTo: 150)

        let records = (11...210).map { record(Int64($0), daysAgo: Double(211 - $0)) }
        let presentation = shelves(entries, records: records)
        let renderedIDs = presentation.shelves.flatMap { $0.nodes.map(\.id) }

        #expect(renderedIDs.count == 210)
        #expect(Set(renderedIDs).count == 210)
        #expect(presentation.displayedCount == 210)

        let oldRoot = try #require(presentation.shelves.first { $0.id == 5 })
        #expect(oldRoot.nodes.map(\.id) == [5, 200, 205])
        #expect(oldRoot.root.record == nil)
        #expect(oldRoot.descendants.allSatisfy { $0.record != nil })

        let newerRoot = try #require(presentation.shelves.first { $0.id == 150 })
        #expect(newerRoot.nodes.map(\.id) == [150, 3])
        #expect(newerRoot.root.record != nil)
        #expect(newerRoot.descendants.first?.record == nil)
    }

    @Test("a loaded record outside the browse index still renders")
    func loadedRecordsAloneStillBuildShelves() throws {
        let presentation = shelves([], records: [record(1, daysAgo: 2), record(2, daysAgo: 1)])

        #expect(presentation.matchCount == 2)
        #expect(presentation.displayedCount == 2)
        #expect(presentation.shelves.count == 2)
        #expect(presentation.shelves.allSatisfy { $0.root.record != nil })
    }

    @Test("a shelf opens itself only when a range is keeping an out-of-range root")
    func shelfStartsExpandedOnlyForRetainedRoots() {
        #expect(!MeetingBrowserLogic.shelfStartsExpanded(rootMatchesRange: true, annotatesMatches: false))
        #expect(!MeetingBrowserLogic.shelfStartsExpanded(rootMatchesRange: false, annotatesMatches: false))
        #expect(!MeetingBrowserLogic.shelfStartsExpanded(rootMatchesRange: true, annotatesMatches: true))
        #expect(MeetingBrowserLogic.shelfStartsExpanded(rootMatchesRange: false, annotatesMatches: true))
    }

    @Test("a thread kept only for a matching follow-up opens itself")
    func retainedThreadOpensItself() throws {
        let entries = [
            entry(1, daysAgo: 20),
            entry(2, daysAgo: 15, followUpTo: 1),
            entry(3, daysAgo: 1, followUpTo: 2)
        ]

        let shelf = try #require(shelves(entries, filter: .lastWeek).shelves.first)

        #expect(!shelf.root.matchesFilter)
        #expect(MeetingBrowserLogic.shelfStartsExpanded(
            rootMatchesRange: shelf.root.matchesFilter,
            annotatesMatches: true
        ))
        #expect(!MeetingBrowserLogic.shelfStartsExpanded(
            rootMatchesRange: shelf.root.matchesFilter,
            annotatesMatches: false
        ))
    }

    @Test("a collapsed filtered family's pill reports the matches it is hiding")
    func collapsedFilteredFamilyPillReportsHiddenMatches() throws {
        let entries = [
            entry(1, daysAgo: 2),
            entry(2, daysAgo: 20, followUpTo: 1),
            entry(3, daysAgo: 1, followUpTo: 2),
            entry(4, daysAgo: 25, followUpTo: 3),
            entry(5, daysAgo: 0.5, followUpTo: 4)
        ]

        let shelf = try #require(shelves(entries, filter: .lastWeek).shelves.first { $0.id == 1 })

        // The root matched, so the family stays folded. Two of the four
        // follow-ups are inside the range, kept as ancestors of a later match,
        // and all four sit behind the pill: thread order is untouched, and the
        // pill reports the matches it is holding back rather than reordering the
        // thread to reach them.
        #expect(shelf.root.matchesFilter)
        #expect(shelf.nodes.map(\.id) == [1, 2, 3, 4, 5])
        #expect(shelf.descendants.map(\.matchesFilter) == [false, true, false, true])

        #expect(MeetingBrowserLogic.followUpPillLabel(
            descendantCount: shelf.descendants.count,
            hiddenMatchCount: shelf.descendants.filter(\.matchesFilter).count,
            annotatesMatches: true,
            isExpanded: false
        ) == "4 follow-ups \u{00B7} 2 in range")
    }

    // MARK: - Ledger sections

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Thursday, so the days before it in the same week are neither today nor
    /// yesterday and the week boundaries are unambiguous.
    private var ledgerNow: Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 2, day: 5, hour: 10, minute: 0))!
    }

    private func ledgerDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 9,
        minute: Int = 30,
        second: Int = 0
    ) -> Date {
        utcCalendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        )!
    }

    private func sectionKind(_ date: Date) -> MeetingLedgerSectionKind {
        MeetingBrowserLogic.ledgerSectionKind(for: date, now: ledgerNow, calendar: utcCalendar)
    }

    @Test("ledger sections follow the calendar's own weeks")
    func ledgerSectionKindsFollowCalendarWeeks() {
        #expect(utcCalendar.firstWeekday == 1)

        #expect(sectionKind(ledgerDate(2026, 2, 5, hour: 8)) == .today)
        // A scheduled meeting that has not happened yet is met today.
        #expect(sectionKind(ledgerDate(2026, 2, 9, hour: 8)) == .today)
        #expect(sectionKind(ledgerDate(2026, 2, 4, hour: 23)) == .yesterday)

        // The rest of this week: Sunday the 1st, Monday the 2nd, Tuesday the
        // 3rd. Yesterday already owns Wednesday.
        #expect(sectionKind(ledgerDate(2026, 2, 3)) == .earlierThisWeek)
        #expect(sectionKind(ledgerDate(2026, 2, 2)) == .earlierThisWeek)
        #expect(sectionKind(ledgerDate(2026, 2, 1, hour: 0)) == .earlierThisWeek)

        // Last week is exactly the week before: Saturday the 31st back to
        // Sunday the 25th, and nothing older.
        #expect(sectionKind(ledgerDate(2026, 1, 31, hour: 23)) == .lastWeek)
        #expect(sectionKind(ledgerDate(2026, 1, 29)) == .lastWeek)
        #expect(sectionKind(ledgerDate(2026, 1, 25, hour: 0)) == .lastWeek)

        // Older than last week: named by month, in this year and the last.
        #expect(sectionKind(ledgerDate(2026, 1, 24)) == .month(year: 2026, month: 1))
        #expect(sectionKind(ledgerDate(2025, 12, 31)) == .month(year: 2025, month: 12))
        #expect(sectionKind(ledgerDate(2025, 9, 17)) == .month(year: 2025, month: 9))
    }

    @Test("ledger section titles name days, weeks, and months in the current year")
    func ledgerSectionTitlesReadAsSentenceCase() {
        let locale = Locale(identifier: "en_US")
        func title(_ kind: MeetingLedgerSectionKind) -> String {
            kind.title(now: ledgerNow, calendar: utcCalendar, locale: locale)
        }

        #expect(title(.today) == "Today")
        #expect(title(.yesterday) == "Yesterday")
        #expect(title(.earlierThisWeek) == "Earlier this week")
        #expect(title(.lastWeek) == "Last week")
        #expect(title(.month(year: 2026, month: 2)) == "February")
        #expect(title(.month(year: 2025, month: 9)) == "September 2025")
    }

    @Test("ledger gutter labels carry only what the section heading does not")
    func ledgerGutterLabelsCarryTheDateTheSectionDoesNot() {
        let locale = Locale(identifier: "en_US")
        func label(_ date: Date, _ kind: MeetingLedgerSectionKind) -> String {
            MeetingBrowserLogic.ledgerGutterLabel(
                for: date,
                in: kind,
                calendar: utcCalendar,
                locale: locale
            )
        }

        // Today and yesterday: the time alone. Seconds never reach a ledger.
        let morning = ledgerDate(2026, 2, 5, hour: 9, minute: 30, second: 45)
        let todayLabel = label(morning, .today)
        #expect(todayLabel.contains("9:30"))
        #expect(todayLabel.localizedCaseInsensitiveContains("AM"))
        #expect(!todayLabel.contains(":45"))
        #expect(!todayLabel.localizedCaseInsensitiveContains("Thu"))

        let yesterdayLabel = label(ledgerDate(2026, 2, 4, hour: 15, minute: 5), .yesterday)
        #expect(yesterdayLabel.contains("3:05"))
        #expect(!yesterdayLabel.localizedCaseInsensitiveContains("Wed"))

        // The named weeks: the weekday, because the heading only says which
        // week.
        let weekLabel = label(ledgerDate(2026, 2, 2, hour: 9, minute: 30), .earlierThisWeek)
        #expect(weekLabel.hasPrefix("Mon"))
        #expect(weekLabel.contains("9:30"))

        // A month heading names the month, so the row names the day.
        let monthLabel = label(ledgerDate(2025, 9, 17, hour: 9, minute: 0), .month(year: 2025, month: 9))
        #expect(monthLabel.hasPrefix("17"))
        #expect(monthLabel.contains("\u{00B7}"))
        #expect(monthLabel.contains("9:00"))
    }

    @Test("a follow-up's gutter names its date unless it shares its root's day")
    func childGutterLabelsNameTheirOwnDate() {
        let locale = Locale(identifier: "en_US")
        let root = ledgerDate(2026, 2, 5, hour: 10, minute: 0)

        func label(_ child: Date) -> String {
            MeetingBrowserLogic.ledgerChildGutterLabel(
                childDate: child,
                rootDate: root,
                now: ledgerNow,
                calendar: utcCalendar,
                locale: locale
            )
        }

        // Same calendar day as the root: the time alone, and no seconds.
        let sameDay = label(ledgerDate(2026, 2, 5, hour: 14, minute: 5, second: 45))
        #expect(sameDay.contains("2:05"))
        #expect(!sameDay.contains(":45"))
        #expect(!sameDay.localizedCaseInsensitiveContains("Feb"))

        // A day earlier: the date, because a bare time under a "Today" root
        // would read as this morning's.
        #expect(label(ledgerDate(2026, 2, 4, hour: 9, minute: 30)) == "Feb 4")

        // Another day in the current year, and one that is not.
        #expect(label(ledgerDate(2026, 1, 18, hour: 9, minute: 30)) == "Jan 18")
        #expect(label(ledgerDate(2025, 9, 17, hour: 9, minute: 30)) == "Sep 2025")
    }

    @Test("the pill names the follow-up count and, folded, how much of it is in range")
    func followUpPillLabelCountsFollowUpsAndRangeMatches() {
        #expect(MeetingBrowserLogic.followUpPillLabel(
            descendantCount: 1,
            hiddenMatchCount: 1,
            annotatesMatches: false,
            isExpanded: false
        ) == "1 follow-up")

        #expect(MeetingBrowserLogic.followUpPillLabel(
            descendantCount: 3,
            hiddenMatchCount: 2,
            annotatesMatches: true,
            isExpanded: false
        ) == "3 follow-ups \u{00B7} 2 in range")

        // "All time": there is no range, so a count of matches would be noise.
        #expect(MeetingBrowserLogic.followUpPillLabel(
            descendantCount: 3,
            hiddenMatchCount: 3,
            annotatesMatches: false,
            isExpanded: false
        ) == "3 follow-ups")

        // A collapsed family whose range matches none of its follow-ups reports
        // the count alone: there is nothing in range to point at.
        #expect(MeetingBrowserLogic.followUpPillLabel(
            descendantCount: 4,
            hiddenMatchCount: 0,
            annotatesMatches: true,
            isExpanded: false
        ) == "4 follow-ups")

        // Expanded, the follow-ups are on screen under the pill, so the range
        // clause has nothing left to say.
        #expect(MeetingBrowserLogic.followUpPillLabel(
            descendantCount: 3,
            hiddenMatchCount: 2,
            annotatesMatches: true,
            isExpanded: true
        ) == "3 follow-ups")

        // A single expanded follow-up keeps the singular, with the same clause
        // dropped.
        #expect(MeetingBrowserLogic.followUpPillLabel(
            descendantCount: 1,
            hiddenMatchCount: 1,
            annotatesMatches: true,
            isExpanded: true
        ) == "1 follow-up")
    }

    private func ledgerGroups(
        _ presentation: MeetingBrowserShelfPresentation,
        calendar: Calendar,
        sort: MeetingBrowserSort = .newestFirst,
        now: Date? = nil
    ) -> [MeetingLedgerGroup] {
        MeetingBrowserLogic.ledgerGroups(
            from: presentation.shelves,
            sort: sort,
            now: now ?? baseDate,
            calendar: calendar
        )
    }

    @Test("ledger sections follow the roots' dates and never repeat")
    func ledgerSectionsFollowRootDatesOnce() throws {
        // Thursday, so "today" and "earlier this week" are different sections.
        let thursday = ledgerDate(2026, 2, 5, hour: 10)
        let entries = [
            entry(1, daysAgo: -3),                   // today
            entry(2, daysAgo: 0),                    // Monday of this week
            entry(3, daysAgo: 166),                  // 20 August 2025
            entry(4, daysAgo: -2, followUpTo: 3)     // its follow-up, yesterday
        ]

        let presentation = shelves(entries, now: thursday, calendar: utcCalendar)
        // The shelves arrive ordered by each family's activity, so the August
        // family's recent follow-up floats it above the Monday one.
        #expect(presentation.shelves.map(\.id) == [1, 3, 2])

        let newestFirst = ledgerGroups(presentation, calendar: utcCalendar, now: thursday)
        #expect(newestFirst.map(\.kind) == [
            .today,
            .earlierThisWeek,
            .month(year: 2025, month: 8)
        ])
        // A section is one run of families, so no kind can appear twice.
        #expect(Set(newestFirst.map(\.kind)).count == newestFirst.count)

        let oldestFirst = ledgerGroups(
            shelves(entries, sort: .oldestFirst, now: thursday, calendar: utcCalendar),
            calendar: utcCalendar,
            sort: .oldestFirst,
            now: thursday
        )
        #expect(oldestFirst.map(\.kind) == [
            .month(year: 2025, month: 8),
            .earlierThisWeek,
            .today
        ])
    }

    @Test("ledger sections group consecutive shelves by their roots' dates")
    func ledgerGroupsFollowRootOrder() {
        // Base date is Monday 2 February 2026 02:40 UTC, so the fixture lands
        // on: today, yesterday, the Saturday of last week, the Sunday that
        // started last week, and a December meeting.
        let entries = [
            entry(1, daysAgo: 0),
            entry(2, daysAgo: 1),
            entry(3, daysAgo: 2),
            entry(4, daysAgo: 8),
            entry(5, daysAgo: 60)
        ]

        let groups = ledgerGroups(shelves(entries, calendar: utcCalendar), calendar: utcCalendar)

        #expect(groups.map(\.kind) == [
            .today,
            .yesterday,
            .lastWeek,
            .month(year: 2025, month: 12)
        ])
        // Consecutive families sharing a section merge into one group, in date
        // order.
        #expect(groups.map { $0.shelves.map(\.id) } == [[1], [2], [3, 4], [5]])
        #expect(groups.map(\.meetingCount) == [1, 1, 2, 1])
        #expect(Set(groups.map(\.id)).count == groups.count)
    }

    @Test("oldest-first reads the same sections in reverse")
    func ledgerGroupsFollowOldestFirstOrder() throws {
        let entries = [
            entry(1, daysAgo: 0),
            entry(2, daysAgo: 1),
            entry(3, daysAgo: 8)
        ]

        let presentation = shelves(entries, sort: .oldestFirst, calendar: utcCalendar)
        let groups = ledgerGroups(presentation, calendar: utcCalendar, sort: .oldestFirst)

        // The ledger reverses with the sort rather than overriding it: the
        // oldest meeting leads, so the sections run backwards.
        #expect(groups.map(\.kind) == [
            .lastWeek,
            .yesterday,
            .today
        ])
        #expect(groups.map { $0.shelves.map(\.id) } == [[3], [2], [1]])
    }

    @Test("a family files under the date of the meeting it started from")
    func familyFilesUnderItsRootsDate() throws {
        // A root two months old, kept in the ledger by a follow-up from today.
        // The family belongs under the root's own month: filing it by its newest
        // meeting would float it among the recent days and print that month a
        // second time, further down, for the older meeting on its own.
        let entries = [
            entry(1, daysAgo: 60),
            entry(2, daysAgo: 0, followUpTo: 1),
            entry(3, daysAgo: 0),
            entry(4, daysAgo: 6),
            entry(5, daysAgo: 58)
        ]

        let groups = ledgerGroups(shelves(entries, calendar: utcCalendar), calendar: utcCalendar)

        #expect(groups.map { $0.shelves.map(\.id) } == [[3], [4], [5, 1]])
        #expect(groups.map(\.kind) == [
            .today,
            .lastWeek,
            .month(year: 2025, month: 12)
        ])
        #expect(Set(groups.map(\.kind)).count == groups.count)
    }

    @Test("the shelf presentation provides the oldest date for the range menu")
    func presentationCarriesOldestStartDate() throws {
        let entries = [entry(1, daysAgo: 40), entry(2, daysAgo: 2)]
        let presentation = shelves(entries)

        let oldest = try #require(presentation.oldestStartDate)
        let expected = try #require(MeetingBrowserLogic.parseDate(entry(2, daysAgo: 40).startTime))
        #expect(oldest == expected)
        #expect(
            MeetingBrowserLogic.availableFilters(oldestStartDate: oldest, now: baseDate, calendar: calendar)
                == [.all, .last2Days, .lastWeek, .last2Weeks, .lastMonth, .last3Months]
        )
    }
}

/// Store-level coverage for the browse index that keeps shelves complete
/// without loading transcripts.
@Suite("Meeting browser index", .serialized)
struct MeetingBrowserIndexTests {
    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meets-browser-index-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    @discardableResult
    private func insertMeeting(
        in store: DictationStore,
        title: String,
        daysAgo: Double,
        folderID: Int64? = nil,
        followUpToID: Int64? = nil
    ) throws -> Int64 {
        // `createLiveMeeting` is the store entry point that carries the
        // follow-up link and folder; `insertMeeting` accepts neither.
        try store.createLiveMeeting(
            title: title,
            calendarEventID: nil,
            startTime: Date(timeIntervalSince1970: 1_770_000_000 - daysAgo * 86_400),
            folderID: folderID,
            followUpToID: followUpToID
        )
    }

    @Test("the browse index follows folder scope and names out-of-scope predecessors")
    func browseIndexFollowsFolderScope() throws {
        let store = try makeStore()
        let parentFolder = try store.createFolder(name: "Parent")
        let childFolder = try store.createFolder(name: "Child", parentID: parentFolder)
        let otherFolder = try store.createFolder(name: "Other")

        let rootID = try insertMeeting(in: store, title: "Root", daysAgo: 2, folderID: otherFolder)
        let childID = try insertMeeting(in: store, title: "Child", daysAgo: 1, folderID: childFolder, followUpToID: rootID)

        let parentScope = try store.meetingBrowserEntries(folderID: parentFolder)
        #expect(parentScope.map(\.id) == [childID])
        #expect(parentScope.first?.followUpToID == rootID)
        #expect(parentScope.first?.predecessorTitle == "Root")
        #expect(parentScope.first?.folderID == childFolder)

        #expect(try store.meetingBrowserEntries(folderID: childFolder).map(\.id) == [childID])
        #expect(Set(try store.meetingBrowserEntries(folderID: nil).map(\.id)) == Set([rootID, childID]))
    }

    @Test("the browse index stays complete beyond the recent-200 window")
    func browseIndexIsCompleteBeyondRecentWindow() throws {
        let store = try makeStore()
        for index in 1...205 {
            try insertMeeting(in: store, title: "Meeting \(index)", daysAgo: Double(206 - index))
        }

        let recent = try store.recentMeetings(limit: 200)
        let entries = try store.meetingBrowserEntries()

        #expect(recent.count == 200)
        #expect(entries.count == 205)
        #expect(Set(entries.map(\.id)).isSuperset(of: Set(recent.map(\.id))))
        #expect(entries.map(\.title).contains("Meeting 1"))
    }
}
