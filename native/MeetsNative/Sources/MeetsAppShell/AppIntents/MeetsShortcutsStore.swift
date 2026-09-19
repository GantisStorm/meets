import MeetsCore
import MeetsApp

/// Shared DB access for read-only App Intents. Opens its own connection
/// rather than routing through MeetsController.current, so the "get last
/// meeting" Shortcut still works even when Meets isn't running.
/// Uses AppIdentity.supportDirectoryURL (reads the running process's own
/// Bundle.main) rather than the MeetsPaths default, so this resolves the
/// correct per-identity database — MeetsDev vs Meets vs MeetsCanary —
/// instead of always reading production data regardless of which app is
/// actually running.
enum MeetsShortcutsStore {
    static func open() throws -> DictationStore {
        let store = DictationStore(
            databaseURL: AppIdentity.supportDirectoryURL.appendingPathComponent("meets.db")
        )
        try store.migrateIfNeeded()
        return store
    }
}
