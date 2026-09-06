import Foundation
import MeetsCore

public enum AppIdentity {
    private static let defaultName = "Meets"

    static var bundleName: String {
        stringValue(for: "CFBundleName") ?? defaultName
    }

    static var displayName: String {
        stringValue(for: "CFBundleDisplayName") ?? bundleName
    }

    static var marketingVersion: String {
        stringValue(for: "CFBundleShortVersionString") ?? "0.0.0"
    }

    static var supportDirectoryName: String {
        stringValue(for: "MeetsSupportDirectoryName") ?? displayName
    }

    /// Public so App Intents (a separate module from the rest of the app)
    /// can resolve the *running* app identity's data directory — e.g.
    /// MeetsDev vs Muesli — instead of hardcoding the production default.
    public static var supportDirectoryURL: URL {
        MeetsPaths.defaultSupportDirectoryURL(appName: supportDirectoryName)
    }

    private static func stringValue(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
