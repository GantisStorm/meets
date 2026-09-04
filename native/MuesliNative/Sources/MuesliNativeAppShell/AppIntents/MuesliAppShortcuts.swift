import AppIntents

@available(macOS 13.0, *)
struct MuesliAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartMeetingIntent(),
            phrases: ["Start a meeting recording in \(.applicationName)"],
            shortTitle: "Start Meeting Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopMeetingIntent(),
            phrases: ["Stop the meeting recording in \(.applicationName)"],
            shortTitle: "Stop Meeting Recording",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: GetLastMeetingIntent(),
            phrases: ["Get my last meeting notes from \(.applicationName)"],
            shortTitle: "Get Last Meeting Notes",
            systemImageName: "doc.text"
        )
    }
}
