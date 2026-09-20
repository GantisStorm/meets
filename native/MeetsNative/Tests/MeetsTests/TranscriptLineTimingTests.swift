import FluidAudio
import Foundation
import Testing
import MeetsCore
@testable import MeetsApp

@Suite("Transcript line timings")
struct TranscriptLineTimingTests {

    /// The line body `merge` writes after the `"] Speaker: "` prefix.
    private func lineBodies(of transcript: String) -> [String] {
        transcript.components(separatedBy: "\n").compactMap { line in
            guard let range = line.range(of: "] ") else { return nil }
            let body = line[range.upperBound...]
            guard let separator = body.range(of: ": ") else { return nil }
            return String(body[separator.upperBound...])
        }
    }

    @Test("two speakers consolidate into one timed line per speaker run")
    func consolidatesTwoSpeakersIntoTimedLines() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        let mic = [
            SpeechSegment(start: 0.5, end: 1.2, text: "hello"),
            SpeechSegment(start: 1.4, end: 2.6, text: "there"),
        ]
        let system = [
            SpeechSegment(start: 4.0, end: 6.5, text: "general kenobi"),
        ]
        let diarization = [makeDiarSeg(speakerId: "spk_0", start: 3.8, end: 6.6)]

        let formatted = TranscriptFormatter.mergeWithTimings(
            micSegments: mic,
            systemSegments: system,
            diarizationSegments: diarization,
            meetingStart: meetingStart
        )

        #expect(formatted.lines.count == 2)
        #expect(formatted.lines[0].ordinal == 0)
        #expect(formatted.lines[0].speaker == "You")
        #expect(formatted.lines[0].startSeconds == 0.5)
        #expect(formatted.lines[0].endSeconds == 2.6)
        #expect(formatted.lines[0].text == "hello there")
        #expect(formatted.lines[1].ordinal == 1)
        #expect(formatted.lines[1].speaker == "Speaker 1")
        #expect(formatted.lines[1].startSeconds == 4.0)
        #expect(formatted.lines[1].endSeconds == 6.5)
        #expect(formatted.lines[1].text == "general kenobi")
    }

    @Test("line text matches the lines the merge string prints")
    func lineTextMatchesMergeOutput() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        let mic = [
            SpeechSegment(start: 0.0, end: 1.0, text: "first line"),
        ]
        let system = [
            SpeechSegment(start: 2.0, end: 3.0, text: "second line"),
        ]

        let formatted = TranscriptFormatter.mergeWithTimings(
            micSegments: mic,
            systemSegments: system,
            diarizationSegments: nil,
            meetingStart: meetingStart
        )
        let merged = TranscriptFormatter.merge(
            micSegments: mic,
            systemSegments: system,
            diarizationSegments: nil,
            meetingStart: meetingStart
        )

        #expect(formatted.text == merged)
        #expect(formatted.lines.map(\.text) == lineBodies(of: merged))
        #expect(formatted.lines.map(\.ordinal) == Array(formatted.lines.indices))
        #expect(formatted.lines.map(\.speaker) == ["You", "Others"])
    }

    @Test("a line that ends where it starts still covers a tenth of a second")
    func zeroLengthLineGetsMinimumDuration() {
        let formatted = TranscriptFormatter.mergeWithTimings(
            micSegments: [SpeechSegment(start: 7.0, end: 7.0, text: "clipped")],
            systemSegments: [],
            diarizationSegments: nil,
            meetingStart: Date(timeIntervalSince1970: 0)
        )

        let line = try? #require(formatted.lines.first)
        #expect(line?.startSeconds == 7.0)
        #expect(line?.endSeconds == 7.1)
    }

    @Test("no segments produce no lines")
    func emptySegmentsProduceNoLines() {
        let formatted = TranscriptFormatter.mergeWithTimings(
            micSegments: [],
            systemSegments: [],
            diarizationSegments: nil,
            meetingStart: Date(timeIntervalSince1970: 0)
        )

        #expect(formatted.text.isEmpty)
        #expect(formatted.lines.isEmpty)
    }

    private func makeDiarSeg(speakerId: String, start: Float, end: Float) -> TimedSpeakerSegment {
        TimedSpeakerSegment(
            speakerId: speakerId,
            embedding: [],
            startTimeSeconds: start,
            endTimeSeconds: end,
            qualityScore: 1.0
        )
    }
}
