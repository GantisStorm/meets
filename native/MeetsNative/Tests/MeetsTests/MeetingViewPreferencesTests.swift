import Foundation
import Testing
@testable import MeetsApp

@Suite("Meeting view preferences")
@MainActor
struct MeetingViewPreferencesTests {
    private func makeDefaults(_ label: String) throws -> (suiteName: String, defaults: UserDefaults) {
        let suiteName = "MeetingViewPreferencesTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (suiteName, defaults)
    }

    @Test("written notes are hidden until they are shown")
    func defaultsToHidden() throws {
        let (suiteName, defaults) = try makeDefaults("default")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = MeetingViewPreferences(defaults: defaults)

        #expect(preferences.showsWrittenNotes(for: 42) == false)
        #expect(defaults.stringArray(forKey: MeetingViewPreferences.writtenNotesVisibleKey) == nil)
    }

    @Test("showing written notes survives a new instance on the same defaults")
    func shownStatePersists() throws {
        let (suiteName, defaults) = try makeDefaults("persist")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        MeetingViewPreferences(defaults: defaults).setShowsWrittenNotes(true, for: 42)

        let reloaded = MeetingViewPreferences(defaults: defaults)
        #expect(reloaded.showsWrittenNotes(for: 42))
        #expect(defaults.stringArray(forKey: MeetingViewPreferences.writtenNotesVisibleKey) == ["42"])
    }

    @Test("each meeting keeps its own state")
    func meetingsAreIsolated() throws {
        let (suiteName, defaults) = try makeDefaults("isolation")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = MeetingViewPreferences(defaults: defaults)
        preferences.setShowsWrittenNotes(true, for: 7)

        #expect(preferences.showsWrittenNotes(for: 7))
        #expect(preferences.showsWrittenNotes(for: 8) == false)
        #expect(defaults.stringArray(forKey: MeetingViewPreferences.writtenNotesVisibleKey) == ["7"])
    }

    @Test("hiding written notes removes the meeting ID")
    func hidingRemovesStoredID() throws {
        let (suiteName, defaults) = try makeDefaults("remove")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = MeetingViewPreferences(defaults: defaults)
        preferences.setShowsWrittenNotes(true, for: 9)
        preferences.setShowsWrittenNotes(false, for: 9)

        #expect(preferences.showsWrittenNotes(for: 9) == false)
        #expect(defaults.stringArray(forKey: MeetingViewPreferences.writtenNotesVisibleKey) == [])
    }
}
