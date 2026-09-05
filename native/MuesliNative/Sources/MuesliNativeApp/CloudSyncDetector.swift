import Foundation

/// A detected cloud-sync folder root: iCloud Drive, Dropbox, or one of the
/// providers mounted under `~/Library/CloudStorage`. `path` is the provider
/// root itself; mirrored meeting files live in `<path>/Meets`.
struct CloudSyncLocation: Identifiable, Equatable {
    let name: String
    let path: String
    let iconName: String
    let isAvailable: Bool

    var id: String { path }
}

/// Zero-config discovery of folders the user's cloud apps already sync
/// (iCloud Drive, Dropbox, Google Drive, OneDrive, Nextcloud, ...). Pure local
/// file checks — no network, no accounts, no entitlements — so it is fast and
/// safe to call from the main actor while settings render.
enum CloudSyncDetector {
    /// Subfolder every meeting mirror is written into under a location root.
    static let mirrorFolderName = "Meets"

    private static let iCloudDrivePath = NSHomeDirectory()
        + "/Library/Mobile Documents/com~apple~CloudDocs"
    private static let dropboxPath = NSHomeDirectory() + "/Dropbox"
    private static let cloudStorageDirectoryPath = NSHomeDirectory()
        + "/Library/CloudStorage"

    /// Returns available cloud locations, iCloud first, then Dropbox, then the
    /// `~/Library/CloudStorage` providers (alphabetical). Non-directory and
    /// unreadable entries are skipped; provider display names are de-duplicated
    /// (Dropbox frequently appears both as `~/Dropbox` and under CloudStorage).
    static func detect() -> [CloudSyncLocation] {
        let fileManager = FileManager.default
        var seenNames = Set<String>()
        var locations: [CloudSyncLocation] = []

        if let iCloud = cloudLocation(
            name: "iCloud Drive",
            path: iCloudDrivePath,
            iconName: "icloud",
            fileManager: fileManager
        ) {
            locations.append(iCloud)
            seenNames.insert(iCloud.name)
        }

        if let dropbox = cloudLocation(
            name: "Dropbox",
            path: dropboxPath,
            iconName: "cloud",
            fileManager: fileManager
        ) {
            locations.append(dropbox)
            seenNames.insert(dropbox.name)
        }

        for entry in cloudStorageEntries(fileManager: fileManager) {
            let identity = displayIdentity(forEntryNamed: entry.lastPathComponent)
            guard !seenNames.contains(identity.name) else { continue }
            if let location = cloudLocation(
                name: identity.name,
                path: entry.path,
                iconName: identity.iconName,
                fileManager: fileManager
            ) {
                locations.append(location)
                seenNames.insert(location.name)
            }
        }

        return locations
    }

    /// The folder a mirrored location maps to: `<location.path>/Meets`.
    static func cloudFolderURL(for location: CloudSyncLocation) -> URL {
        URL(fileURLWithPath: location.path, isDirectory: true)
            .appendingPathComponent(mirrorFolderName, isDirectory: true)
    }

    // MARK: - Discovery

    /// Returns a location when the folder exists, is a directory, and is
    /// readable; nil otherwise. Never performs network I/O.
    private static func cloudLocation(
        name: String,
        path: String,
        iconName: String,
        fileManager: FileManager
    ) -> CloudSyncLocation? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isReadableFile(atPath: path) else {
            return nil
        }
        return CloudSyncLocation(
            name: name,
            path: path,
            iconName: iconName,
            isAvailable: true
        )
    }

    private static func cloudStorageEntries(fileManager: FileManager) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: cloudStorageDirectoryPath, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Maps a `~/Library/CloudStorage` entry name to a display name + SF Symbol.
    /// Folder names vary by provider ("GoogleDrive-", "Google Drive-",
    /// "ICloudDrive-", ...), so spaces/dashes are collapsed before matching and
    /// the account suffix (`-alice@example.com`) is ignored; known providers
    /// map to friendly names, everything else is title-cased ("Other").
    private static func displayIdentity(forEntryNamed rawName: String) -> (name: String, iconName: String) {
        let lower = rawName.lowercased()
        let flattened = lower
            .replacingOccurrences(of: " ", with: "")
            .components(separatedBy: "-")
            .filter { !$0.isEmpty }
        let known: (name: String, iconName: String)?
        switch flattened.first {
        case "iclouddrive", "icloud", "iclouddriveaccount":
            known = ("iCloud Drive", "icloud")
        case "dropbox":
            known = ("Dropbox", "cloud")
        case "googledrive":
            known = ("Google Drive", "cloud")
        case "onedrive":
            known = ("OneDrive", "cloud")
        case "nextcloud":
            known = ("Nextcloud", "cloud")
        default:
            if flattened.contains(where: { $0.contains("nextcloud") }) {
                known = ("Nextcloud", "cloud")
            } else if flattened.contains(where: { $0.contains("pcloud") }) {
                known = ("pCloud", "cloud")
            } else {
                known = nil
            }
        }
        if let known {
            return known
        }
        return (titleCased(rawName), "externaldrive")
    }

    /// `pCloud Drive-42` → `Pcloud Drive-42`; capitalizes the first letter of
    /// every dash-separated word while preserving the rest of the casing.
    private static func titleCased(_ rawName: String) -> String {
        rawName.components(separatedBy: "-").map { component in
            guard let first = component.first else { return component }
            return String(first).uppercased() + component.dropFirst()
        }
        .joined(separator: "-")
    }
}
