import Foundation
import MeetsApp

@available(macOS 13.0, *)
enum MeetsShortcutsRuntime {
    /// Resolves the running controller. Shortcuts/Siri can cold-launch the
    /// app, and `MeetsController.current` is only set once
    /// `applicationDidFinishLaunching` runs, so wait briefly instead of
    /// failing with a spurious "not running" while the app is mid-launch.
    @MainActor
    static func waitForController(timeout: TimeInterval = 5) async throws -> MeetsController {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if let controller = MeetsController.current { return controller }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let controller = MeetsController.current else {
            throw MeetsShortcutsError.notRunning
        }
        return controller
    }
}
