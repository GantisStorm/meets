import SwiftUI
import MeetsCore

extension MeetingStatus {
    var displayLabel: String {
        switch self {
        case .recording:
            return "Recording"
        case .processing:
            return "Processing"
        case .completed:
            return "Completed"
        case .noteOnly:
            return "Note only"
        case .failed:
            return "Needs attention"
        }
    }

    var displayColor: Color {
        switch self {
        case .recording:
            return MeetsTheme.recording
        case .processing:
            return MeetsTheme.accent
        case .completed:
            return MeetsTheme.success
        case .noteOnly:
            return MeetsTheme.textTertiary
        case .failed:
            return MeetsTheme.transcribing
        }
    }
}
