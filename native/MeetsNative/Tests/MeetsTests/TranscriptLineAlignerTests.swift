import Foundation
import Testing
import MeetsCore
@testable import MeetsApp

@Suite("Transcript line alignment")
struct TranscriptLineAlignerTests {
    private func timings(_ entries: [(String, Double, Double)]) -> [TranscriptLineTiming] {
        entries.enumerated().map { index, entry in
            TranscriptLineTiming(
                ordinal: index,
                speaker: "You",
                startSeconds: entry.1,
                endSeconds: entry.2,
                text: entry.0
            )
        }
    }

    @Test("stored lines map straight onto the transcript when both agree")
    func mapsOneToOne() {
        let messages = TranscriptChatMessage.messages(from: "You: hello there\nOthers: general kenobi")
        let stored = timings([("hello there", 0.25, 0.9), ("general kenobi", 1.1, 1.9)])

        let alignment = TranscriptLineAligner.align(lines: messages, timings: stored)

        #expect(alignment.lines.count == 2)
        #expect(alignment.lines[0].start == 0.25)
        #expect(alignment.lines[0].end == 0.9)
        #expect(alignment.lines[1].start == 1.1)
        #expect(alignment.lines[1].end == 1.9)
        #expect(alignment.hasTimings)
    }

    @Test("a transcript the recogniser never saw keeps the lines around it timed")
    func editedLineKeepsLaterLinesTimed() {
        let messages = TranscriptChatMessage.messages(
            from: "You: hello there\nOthers: rewritten by hand\nYou: closing line"
        )
        let stored = timings([
            ("hello there", 0.5, 1.0),
            ("what was said", 1.0, 1.5),
            ("closing line", 2.5, 3.0)
        ])

        let alignment = TranscriptLineAligner.align(lines: messages, timings: stored)

        #expect(alignment.lines[0].start == 0.5)
        #expect(alignment.lines[1].start == nil)
        #expect(alignment.lines[1].end == nil)
        #expect(alignment.lines[2].start == 2.5)
    }

    @Test("lines added to the transcript still map the text that survived")
    func extraTranscriptLineStillMapsTheRest() {
        let messages = TranscriptChatMessage.messages(
            from: "You: first line\nOthers: second line\nYou: a line nobody recorded"
        )
        let stored = timings([("first line", 0.0, 1.0), ("second line", 1.0, 2.0)])

        let alignment = TranscriptLineAligner.align(lines: messages, timings: stored)

        #expect(alignment.lines[0].start == 0.0)
        #expect(alignment.lines[1].start == 1.0)
        #expect(alignment.lines[2].start == nil)
    }

    @Test("repeated line text maps to the stored lines in reading order")
    func repeatedLineTextMapsInOrder() {
        let messages = TranscriptChatMessage.messages(from: "You: yes\nOthers: yes\nYou: yes")
        let stored = timings([("yes", 0.0, 0.5), ("yes", 0.5, 1.0), ("yes", 1.0, 1.5)])

        let alignment = TranscriptLineAligner.align(lines: messages, timings: stored)

        #expect(alignment.lines.map(\.start) == [0.0, 0.5, 1.0])
    }

    @Test("labels give monotonic line times when the recording stored none")
    func clockLabelsGiveMonotonicLineTimes() {
        let messages = TranscriptChatMessage.messages(
            from: """
            [00:00:05] You: first
            [00:00:12] Others: second
            [00:00:09] You: third
            [00:00:21] You: fourth
            """
        )

        let alignment = TranscriptLineAligner.align(lines: messages, timings: [])
        let starts = alignment.lines.compactMap(\.start)

        #expect(starts == [0, 7, 7, 16])
        #expect(starts == starts.sorted())
        #expect(alignment.lines[0].end == 7)
        #expect(alignment.lines[2].end == 16)
        #expect(alignment.hasTimings)
    }

    @Test("clock labels parse as hours, minutes, and seconds")
    func clockLabelParsing() {
        #expect(TranscriptLineAligner.seconds(fromClock: "00:00:05") == 5)
        #expect(TranscriptLineAligner.seconds(fromClock: "01:02:03") == 3723)
        #expect(TranscriptLineAligner.seconds(fromClock: "02:30") == 150)
        #expect(TranscriptLineAligner.seconds(fromClock: "42") == 42)
        #expect(TranscriptLineAligner.seconds(fromClock: "") == nil)
        #expect(TranscriptLineAligner.seconds(fromClock: "soon") == nil)
    }

    @Test("a transcript with neither timings nor labels stays inert")
    func missingTimingsStayInert() {
        let messages = TranscriptChatMessage.messages(from: "You: hello\nOthers: hi")

        let alignment = TranscriptLineAligner.align(lines: messages, timings: [])

        #expect(alignment.lines.count == 2)
        #expect(alignment.lines.allSatisfy { $0.start == nil && $0.end == nil })
        #expect(!alignment.hasTimings)
        #expect(alignment.activeLine(at: 10) == nil)
    }

    @Test("the active line holds from its start until the next line starts")
    func activeLineBoundaries() {
        let messages = TranscriptChatMessage.messages(from: "You: one\nOthers: two\nYou: three")
        let stored = timings([("one", 1.0, 1.5), ("two", 2.0, 2.4), ("three", 3.0, 3.2)])

        let alignment = TranscriptLineAligner.align(lines: messages, timings: stored)

        #expect(alignment.activeLine(at: 0.5) == nil)
        #expect(alignment.activeLine(at: 1.0) == 0)
        // No gap between lines: the earlier line stays active until the next.
        #expect(alignment.activeLine(at: 1.9) == 0)
        #expect(alignment.activeLine(at: 2.0) == 1)
        #expect(alignment.activeLine(at: 2.9) == 1)
        #expect(alignment.activeLine(at: 3.0) == 2)
        #expect(alignment.activeLine(at: 900) == 2)
    }

    @Test("an untimed line between timed ones does not hide them")
    func untimedLineDoesNotHideLaterLines() {
        let messages = TranscriptChatMessage.messages(
            from: "You: hello there\nOthers: rewritten by hand\nYou: closing line"
        )
        let stored = timings([
            ("hello there", 1.0, 1.5),
            ("what was said", 1.5, 2.0),
            ("closing line", 3.0, 3.5)
        ])

        let alignment = TranscriptLineAligner.align(lines: messages, timings: stored)

        #expect(alignment.activeLine(at: 1.2) == 0)
        #expect(alignment.activeLine(at: 2.5) == 0)
        #expect(alignment.activeLine(at: 3.4) == 2)
    }
}
