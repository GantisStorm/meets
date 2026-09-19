import Foundation
import Testing
@testable import MeetsApp

@Suite("Dashboard presentation readiness")
struct DashboardPresentationReadinessTests {

    @Test("dashboard presentation waits for its first ordered layout")
    func dashboardPresentationReadiness() {
        var readiness = DashboardPresentationReadiness<String>()

        let queuedBeforeReady = readiness.enqueue("feature tour")
        let firstLayoutRequest = readiness.requestInitialLayout()
        let duplicateLayoutRequest = readiness.requestInitialLayout()
        #expect(queuedBeforeReady == [])
        #expect(firstLayoutRequest)
        #expect(!duplicateLayoutRequest)

        readiness.cancelInitialLayout()
        let retriedLayoutRequest = readiness.requestInitialLayout()
        #expect(!readiness.isReady)
        #expect(retriedLayoutRequest)

        let firstLayoutActions = readiness.completeInitialLayout()
        let readyLayoutRequest = readiness.requestInitialLayout()
        let immediateActions = readiness.enqueue("future tour")
        #expect(firstLayoutActions == ["feature tour"])
        #expect(readiness.isReady)
        #expect(!readyLayoutRequest)
        #expect(immediateActions == ["future tour"])
    }

}
