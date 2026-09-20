import Foundation
import Testing
import MeetsCore
@testable import MeetsApp

@Suite("Transcript word alignment")
struct TranscriptWordAlignerTests {
    private func timings(_ entries: [(String, Double, Double)]) -> [TranscriptWordTiming] {
        entries.enumerated().map { index, entry in
            TranscriptWordTiming(
                ordinal: index,
                speaker: "You",
                startSeconds: entry.1,
                endSeconds: entry.2,
                text: entry.0
            )
        }
    }

    private func alignedTexts(_ line: AlignedLine, in message: TranscriptChatMessage) -> [String] {
        line.words.map { String(message.text[$0.range]) }
    }

    @Test("timed words land on the line that speaks them")
    func exactWordsAlign() {
        let messages = TranscriptChatMessage.messages(from: "You: hello there\nOthers: general kenobi")
        let words = timings([
            ("hello", 0.25, 0.6),
            ("there", 0.6, 0.9),
            ("general", 1.1, 1.4),
            ("kenobi", 1.4, 1.9)
        ])

        let alignment = TranscriptWordAligner.align(lines: messages, words: words)

        #expect(alignment.lines.count == 2)
        #expect(alignedTexts(alignment.lines[0], in: messages[0]) == ["hello", "there"])
        #expect(alignment.lines[0].start == 0.25)
        #expect(alignment.lines[0].end == 0.9)
        #expect(alignedTexts(alignment.lines[1], in: messages[1]) == ["general", "kenobi"])
        #expect(alignment.lines[1].start == 1.1)
        #expect(alignment.lines[1].end == 1.9)
    }

    @Test("punctuation, case, and diacritics do not stop a match")
    func normalisedWordsAlign() {
        let messages = TranscriptChatMessage.messages(from: "You: Hello, there! It's café — right?")
        let words = timings([
            ("hello", 0.1, 0.3),
            ("THERE", 0.3, 0.5),
            ("its", 0.5, 0.7),
            ("cafe", 0.7, 1.0),
            ("right", 1.0, 1.4)
        ])

        let alignment = TranscriptWordAligner.align(lines: messages, words: words)
        let line = alignment.lines[0]

        #expect(alignedTexts(line, in: messages[0]) == ["Hello,", "there!", "It's", "café", "right?"])
        #expect(line.start == 0.1)
        #expect(line.end == 1.4)
        // The dash between "café" and "right?" is punctuation-only, so it is
        // never a tap target.
        #expect(line.words.count == 5)
    }

    @Test("an edited word leaves a gap and later words still align")
    func editedWordLeavesGap() {
        let messages = TranscriptChatMessage.messages(from: "You: the quick brown fox jumps")
        let words = timings([
            ("the", 0.0, 0.2),
            ("quick", 0.2, 0.4),
            ("slow", 0.4, 0.6),
            ("fox", 0.6, 0.8),
            ("jumps", 0.8, 1.2)
        ])

        let alignment = TranscriptWordAligner.align(lines: messages, words: words)
        let line = alignment.lines[0]

        #expect(alignedTexts(line, in: messages[0]) == ["the", "quick", "fox", "jumps"])
        #expect(line.end == 1.2)
        // "slow" was never claimed, so the last word still carries its own time.
        #expect(line.words.last?.start == 0.8)
    }

    @Test("a duplicated timed word is skipped")
    func duplicateTimedWordIsSkipped() {
        let messages = TranscriptChatMessage.messages(from: "You: hello there")
        let words = timings([
            ("hello", 0.1, 0.3),
            ("hello", 0.3, 0.5),
            ("there", 1.2, 1.5)
        ])

        let alignment = TranscriptWordAligner.align(lines: messages, words: words)
        let line = alignment.lines[0]

        #expect(alignedTexts(line, in: messages[0]) == ["hello", "there"])
        #expect(line.words.last?.start == 1.2)
    }

    @Test("a rewritten line does not strand the lines after it")
    func rewrittenLineDoesNotStrandLaterLines() {
        let messages = TranscriptChatMessage.messages(
            from: "You: rewritten words that nobody said\nYou: golf hotel"
        )
        let words = timings([
            ("alpha", 0.0, 0.2),
            ("bravo", 0.2, 0.4),
            ("charlie", 0.4, 0.6),
            ("delta", 0.6, 0.8),
            ("echo", 0.8, 1.0),
            ("foxtrot", 1.0, 1.2),
            ("golf", 1.2, 1.4),
            ("hotel", 1.4, 1.6)
        ])

        let alignment = TranscriptWordAligner.align(lines: messages, words: words)

        // Nothing in the first line matches its six timed words; the second line
        // is seven words away from the cursor and must still find its own.
        #expect(alignment.lines[0].start == nil)
        #expect(alignment.lines[0].words.isEmpty)
        #expect(alignedTexts(alignment.lines[1], in: messages[1]) == ["golf", "hotel"])
        #expect(alignment.lines[1].start == 1.2)
    }

    @Test("labels give line times when the recording has no word timings")
    func clockLabelsGiveMonotonicLineTimes() {
        let messages = TranscriptChatMessage.messages(
            from: """
            [00:00:05] You: first
            [00:00:12] Others: second
            [00:00:09] You: third
            [00:00:21] You: fourth
            """
        )

        let alignment = TranscriptWordAligner.align(lines: messages, words: [])
        let starts = alignment.lines.compactMap(\.start)

        #expect(starts == [0, 7, 7, 16])
        #expect(starts == starts.sorted())
        #expect(alignment.lines[0].end == 7)
        #expect(alignment.lines[2].end == 16)
        #expect(alignment.lines.allSatisfy { $0.words.isEmpty })
        #expect(alignment.hasTimings)
        // Line-level only: there is no word to highlight.
        #expect(alignment.activeWord(at: 8, in: 1) == nil)
    }

    @Test("a transcript with neither timings nor labels stays inert")
    func missingTimingsStayInert() {
        let messages = TranscriptChatMessage.messages(from: "You: hello\nOthers: hi")

        let alignment = TranscriptWordAligner.align(lines: messages, words: [])

        #expect(alignment.lines.count == 2)
        #expect(alignment.lines.allSatisfy { $0.start == nil && $0.end == nil })
        #expect(!alignment.hasTimings)
        #expect(alignment.activeLine(at: 10) == nil)
    }

    @Test("clock labels parse as hours, minutes, and seconds")
    func clockLabelParsing() {
        #expect(TranscriptWordAligner.seconds(fromClock: "00:00:05") == 5)
        #expect(TranscriptWordAligner.seconds(fromClock: "01:02:03") == 3723)
        #expect(TranscriptWordAligner.seconds(fromClock: "02:30") == 150)
        #expect(TranscriptWordAligner.seconds(fromClock: "42") == 42)
        #expect(TranscriptWordAligner.seconds(fromClock: "") == nil)
        #expect(TranscriptWordAligner.seconds(fromClock: "soon") == nil)
    }

    @Test("active line and active word hold across their boundaries")
    func activeBoundaries() {
        let messages = TranscriptChatMessage.messages(from: "You: one two three")
        let words = timings([
            ("one", 1.0, 1.5),
            ("two", 2.0, 2.4),
            ("three", 3.0, 3.2)
        ])

        let alignment = TranscriptWordAligner.align(lines: messages, words: words)

        #expect(alignment.activeLine(at: 0.5) == nil)
        #expect(alignment.activeLine(at: 1.0) == 0)
        #expect(alignment.activeLine(at: 2.9) == 0)
        #expect(alignment.activeLine(at: 9.0) == 0)

        #expect(alignment.activeWord(at: 0.9, in: 0) == nil)
        #expect(alignment.activeWord(at: 1.0, in: 0) == 0)
        // Between words the earlier word stays lit, so there is no dead gap.
        #expect(alignment.activeWord(at: 1.6, in: 0) == 0)
        #expect(alignment.activeWord(at: 2.0, in: 0) == 1)
        #expect(alignment.activeWord(at: 2.6, in: 0) == 1)
        #expect(alignment.activeWord(at: 5.0, in: 0) == 2)
        #expect(alignment.activeWord(at: 1.0, in: 7) == nil)
    }

    @Test("the active line advances with the clock")
    func activeLineAdvances() {
        let messages = TranscriptChatMessage.messages(from: "You: hello there\nOthers: general kenobi")
        let words = timings([
            ("hello", 0.25, 0.6),
            ("there", 0.6, 0.9),
            ("general", 1.1, 1.4),
            ("kenobi", 1.4, 1.9)
        ])

        let alignment = TranscriptWordAligner.align(lines: messages, words: words)

        #expect(alignment.activeLine(at: 0.2) == nil)
        #expect(alignment.activeLine(at: 0.7) == 0)
        #expect(alignment.activeLine(at: 0.95) == 0)
        #expect(alignment.activeLine(at: 1.2) == 1)
        #expect(alignment.activeWord(at: 0.7, in: 0) == 1)
        #expect(alignment.activeWord(at: 1.2, in: 1) == 0)
    }
}
