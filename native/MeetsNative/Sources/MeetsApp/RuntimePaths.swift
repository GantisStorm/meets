import Foundation
import MeetsCore

struct RuntimePaths {
    let repoRoot: URL
    let appIcon: URL?
    let bundlePath: URL?

    static func resolve() throws -> RuntimePaths {
        if let bundleResource = Bundle.main.resourceURL {
            return RuntimePaths(
                repoRoot: bundleResource,
                appIcon: bundleResource.appendingPathComponent("muesli.icns"),
                bundlePath: Bundle.main.bundleURL
            )
        }

        // Dev fallback: search up for assets
        let fileManager = FileManager.default
        var searchURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = searchURL.appendingPathComponent("assets/muesli.icns")
            if fileManager.fileExists(atPath: candidate.path) {
                return RuntimePaths(
                    repoRoot: searchURL,
                    appIcon: candidate,
                    bundlePath: nil
                )
            }
            searchURL.deleteLastPathComponent()
        }

        throw NSError(domain: "MeetsRuntime", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate app bundle or repo root.",
        ])
    }
}
