import AppKit
import MeetsCore

/// Actual app startup logic, called by the thin @main shell in the
/// MeetsAppShell executable target. AppDelegate and the rest of the app
/// live in the MeetsApp library so the executable can stay a minimal shell
/// that Xcode can wrap as a real Application product.
@MainActor
public enum MeetsAppEntry {
    public static func run() {
        let application = NSApplication.shared
        let appDelegate = AppDelegate()
        application.delegate = appDelegate
        application.setActivationPolicy(.accessory)
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}
