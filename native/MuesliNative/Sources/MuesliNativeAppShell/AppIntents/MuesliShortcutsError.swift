import AppIntents

@available(macOS 13.0, *)
enum MuesliShortcutsError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case noMeetings
    case notRunning

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noMeetings: return "Meets has no meetings yet."
        case .notRunning: return "Meets isn't running. Open Meets and try again."
        }
    }
}
