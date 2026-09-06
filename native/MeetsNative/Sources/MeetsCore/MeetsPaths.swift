import Foundation

public enum MeetsPaths {
    public static func defaultSupportDirectoryURL(appName: String = "Meets") -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    public static func defaultDatabaseURL(appName: String = "Meets") -> URL {
        defaultSupportDirectoryURL(appName: appName).appendingPathComponent("meets.db")
    }
}

public enum MeetsNotifications {
    public static let dataDidChange = Notification.Name("com.meets.dataChanged")

    public static func postDataDidChange() {
        DistributedNotificationCenter.default().post(name: dataDidChange, object: nil)
    }
}
