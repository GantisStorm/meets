import Foundation

/// Per-meeting view state remembered across navigation.
///
/// Written notes are hidden by default on a completed meeting: the Notes tab
/// shows the generated summary full width, and the slim tab on its left edge
/// reveals the notes the user typed during the meeting.
@MainActor
final class MeetingViewPreferences {
    static let shared = MeetingViewPreferences()

    /// `[String]` of meeting IDs whose written notes are currently shown.
    static let writtenNotesVisibleKey = "meeting.writtenNotesVisible"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func showsWrittenNotes(for meetingID: Int64) -> Bool {
        storedMeetingIDs().contains(Self.storageID(for: meetingID))
    }

    func setShowsWrittenNotes(_ shown: Bool, for meetingID: Int64) {
        let storageID = Self.storageID(for: meetingID)
        var meetingIDs = storedMeetingIDs()

        if shown {
            guard !meetingIDs.contains(storageID) else { return }
            meetingIDs.append(storageID)
        } else {
            guard meetingIDs.contains(storageID) else { return }
            meetingIDs.removeAll { $0 == storageID }
        }

        defaults.set(meetingIDs, forKey: Self.writtenNotesVisibleKey)
    }

    private func storedMeetingIDs() -> [String] {
        defaults.stringArray(forKey: Self.writtenNotesVisibleKey) ?? []
    }

    private static func storageID(for meetingID: Int64) -> String {
        String(meetingID)
    }
}
