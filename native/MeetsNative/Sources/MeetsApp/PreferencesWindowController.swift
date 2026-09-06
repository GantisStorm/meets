import AppKit
import Foundation
import MeetsCore

@MainActor
final class PreferencesWindowController: NSObject {
    private let controller: MeetsController

    init(controller: MeetsController) {
        self.controller = controller
    }

    func show() {
        controller.openHistoryWindow(tab: .settings)
    }

    func refresh() {
        controller.syncAppState()
    }
}
