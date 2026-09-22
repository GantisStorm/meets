import Foundation
import Testing
@testable import MeetsApp

/// What the summary prompt receives from a meeting's on-screen context: the
/// budget rules matter more than the capture, because they decide which part of
/// a long meeting the model ever reads.
@Suite("Meeting context drain")
struct MeetingScreenContextCollectorTests {

    private func entry(
        _ second: TimeInterval,
        app: String,
        text: String
    ) -> MeetingScreenContextCollector.ContextEntry {
        MeetingScreenContextCollector.ContextEntry(
            timestamp: Date(timeIntervalSince1970: second),
            appName: app,
            contextText: text,
            ocrCharCount: 0,
            appContextCharCount: text.count
        )
    }

    @Test("a long meeting keeps its last snapshots, not its first")
    func keepsTheNewestSnapshots() {
        let captured = (0..<10).map { index in
            entry(TimeInterval(index * 60), app: "App \(index)", text: "\(index) " + String(repeating: "x", count: 100))
        }

        let drained = MeetingScreenContextCollector.composeContext(from: captured, budget: 500)

        #expect(drained.capturedCount == 10)
        #expect(drained.text.contains("App 9"))
        #expect(!drained.text.contains("App 0"))
        #expect(drained.keptCount < captured.count)
        #expect(drained.text.count <= 500)
    }

    @Test("a kept block arrives whole, header and all")
    func keepsBlocksWhole() {
        let captured = [
            entry(0, app: "First", text: String(repeating: "a", count: 300)),
            entry(60, app: "Second", text: String(repeating: "b", count: 300)),
        ]

        let drained = MeetingScreenContextCollector.composeContext(from: captured, budget: 400)

        #expect(drained.keptCount == 1)
        #expect(drained.text.contains("] Second:"))
        #expect(drained.text.contains(String(repeating: "b", count: 300)))
        #expect(!drained.text.contains("First"))
        #expect(!drained.text.contains("a"))
    }

    @Test("a document returned to is one snapshot, at its latest sighting")
    func collapsesRepeatsToTheLatestSighting() {
        let captured = [
            entry(0, app: "Notes", text: "agenda"),
            entry(60, app: "Slides", text: "roadmap"),
            entry(120, app: "Notes", text: "agenda"),
        ]

        let drained = MeetingScreenContextCollector.composeContext(from: captured)

        #expect(drained.keptCount == 2)
        #expect(drained.text.components(separatedBy: "agenda").count - 1 == 1)
        // The last sighting carries the later time, so the repeat lands after
        // the window that interrupted it.
        let roadmap = drained.text.range(of: "roadmap")
        let agenda = drained.text.range(of: "agenda")
        #expect(roadmap != nil && agenda != nil)
        #expect(roadmap!.lowerBound < agenda!.lowerBound)
    }

    @Test("time order survives the budget cut")
    func keepsTimeOrder() {
        let captured = (0..<6).map { index in
            entry(TimeInterval(index * 60), app: "App \(index)", text: "\(index) " + String(repeating: "y", count: 120))
        }

        let drained = MeetingScreenContextCollector.composeContext(from: captured, budget: 400)
        let firstKept = drained.text.range(of: "] App ")
        let lastKept = drained.text.range(of: "] App ", options: .backwards)

        #expect(firstKept != nil)
        #expect(lastKept != nil)
        #expect(drained.text[firstKept!.upperBound] < drained.text[lastKept!.upperBound])
    }

    @Test("a single oversized snapshot still reaches the prompt")
    func keepsOneOversizedSnapshot() {
        let captured = [
            entry(0, app: "Deck", text: String(repeating: "z", count: MeetingScreenContextCollector.drainCharacterBudget * 2)),
        ]

        let drained = MeetingScreenContextCollector.composeContext(from: captured)

        #expect(drained.keptCount == 1)
        #expect(drained.text.contains(String(repeating: "z", count: 100)))
    }

    @Test("nothing captured drains to nothing")
    func emptyDrain() {
        let drained = MeetingScreenContextCollector.composeContext(from: [])

        #expect(drained.text.isEmpty)
        #expect(drained.keptCount == 0)
        #expect(drained.capturedCount == 0)
    }
}
