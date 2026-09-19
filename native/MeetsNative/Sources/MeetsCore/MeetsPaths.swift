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

    public static let modelCacheRelativePath = ".cache/meets/models"

    public static func modelCacheDirectoryURL(
        relativePath: String? = nil,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil
    ) -> URL {
        let homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let root = homeDirectory.appendingPathComponent(modelCacheRelativePath, isDirectory: true)
        return relativePath.map {
            root.appendingPathComponent($0, isDirectory: true)
        } ?? root
    }
}

public enum MeetsNotifications {
    public static let dataDidChange = Notification.Name("com.meets.dataChanged")

    public static func postDataDidChange() {
        DistributedNotificationCenter.default().post(name: dataDidChange, object: nil)
    }
}
