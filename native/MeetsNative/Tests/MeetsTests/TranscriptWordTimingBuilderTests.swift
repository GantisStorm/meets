import Foundation
import Testing
@testable import MeetsApp

@Suite("Transcript word timing builder")
struct TranscriptWordTimingBuilderTests {

    @Test("sub-word tokens group into words on sentencepiece boundaries")
    func groupsSubWordTokens() {
        let words = TranscriptWordTimingBuilder.words(fromTokens: [
            (token: "▁Hello", start: 0, end: 0.5),
            (token: "▁wor", start: 0.5, end: 0.8),
            (token: "ld", start: 0.8, end: 1.0),
            (token: ",", start: 1.0, end: 1.1)
        ])

        #expect(words.map(\.text) == ["Hello", "world,"])
        #expect(words.map(\.start) == [0, 0.5])
        #expect(words.map(\.end) == [0.5, 1.1])
    }

    @Test("a leading space marks a word boundary the same way")
    func leadingSpaceBoundary() {
        let words = TranscriptWordTimingBuilder.words(fromTokens: [
            (token: " Hello", start: 0, end: 0.5),
            (token: " wor", start: 0.5, end: 0.8),
            (token: "ld", start: 0.8, end: 1.0)
        ])

        #expect(words.map(\.text) == ["Hello", "world"])
        #expect(words.map(\.start) == [0, 0.5])
        #expect(words.map(\.end) == [0.5, 1.0])
    }

    @Test("punctuation attaches to the word it follows")
    func punctuationAttaches() {
        let words = TranscriptWordTimingBuilder.words(fromTokens: [
            (token: "▁Hello", start: 0, end: 0.5),
            (token: "▁,", start: 0.5, end: 0.6),
            (token: "▁world", start: 0.6, end: 1.0),
            (token: ".", start: 1.0, end: 1.1)
        ])

        #expect(words.map(\.text) == ["Hello,", "world."])
        #expect(words.map(\.end) == [0.6, 1.1])
    }

    @Test("empty and blank tokens never become words")
    func blankTokensSkipped() {
        let words = TranscriptWordTimingBuilder.words(fromTokens: [
            (token: "", start: 0, end: 0.1),
            (token: "▁Hello", start: 0.1, end: 0.5),
            (token: "<blank>", start: 0.5, end: 0.6),
            (token: "<pad>", start: 0.6, end: 0.7),
            (token: "▁world", start: 0.7, end: 1.0)
        ])

        #expect(words.map(\.text) == ["Hello", "world"])
        #expect(words.map(\.start) == [0.1, 0.7])
    }

    @Test("offset shifts both ends of every word")
    func offsetShiftsTimings() {
        let words = [
            SpeechWord(start: 0.5, end: 1.0, text: "Hello"),
            SpeechWord(start: 1.0, end: 1.5, text: "world")
        ]

        let shifted = TranscriptWordTimingBuilder.offset(words, by: 30)

        #expect(shifted.map(\.text) == ["Hello", "world"])
        #expect(shifted.map(\.start) == [30.5, 31.0])
        #expect(shifted.map(\.end) == [31.0, 31.5])
        #expect(TranscriptWordTimingBuilder.offset(words, by: 0) == words)
    }

    @Test("tagging asks for the speaker at each word's midpoint")
    func taggingUsesMidpoint() {
        var asked: [Double] = []
        let words = [
            SpeechWord(start: 0, end: 1, text: "Hello"),
            SpeechWord(start: 2, end: 3, text: "world")
        ]

        let tagged = TranscriptWordTimingBuilder.tagged(words) { midpoint in
            asked.append(midpoint)
            return midpoint < 1 ? "You" : "Speaker 1"
        }

        #expect(asked == [0.5, 2.5])
        #expect(tagged.map(\.ordinal) == [0, 1])
        #expect(tagged.map(\.speaker) == ["You", "Speaker 1"])
        #expect(tagged.map(\.text) == ["Hello", "world"])
        #expect(tagged.map(\.startSeconds) == [0, 2])
        #expect(tagged.map(\.endSeconds) == [1, 3])
    }

    @Test("interleaved sources are numbered in reading order")
    func taggedEntriesSortByStart() {
        let tagged = TranscriptWordTimingBuilder.tagged([
            (word: SpeechWord(start: 1.0, end: 1.4, text: "there"), speaker: "Others"),
            (word: SpeechWord(start: 0.2, end: 0.6, text: "Hello"), speaker: "You"),
            (word: SpeechWord(start: 1.5, end: 1.9, text: "again"), speaker: "Others")
        ])

        #expect(tagged.map(\.ordinal) == [0, 1, 2])
        #expect(tagged.map(\.text) == ["Hello", "there", "again"])
        #expect(tagged.map(\.speaker) == ["You", "Others", "Others"])
    }

    @Test("whisper word timings are trimmed and emptied out")
    func whisperMappingTrims() {
        let words = TranscriptWordTimingBuilder.words(fromWhisper: [
            (word: " Hello ", start: 0, end: 0.5),
            (word: "   ", start: 0.5, end: 0.6),
            (word: "", start: 0.6, end: 0.7),
            (word: "world", start: 0.7, end: 1.0)
        ])

        #expect(words == [
            SpeechWord(start: 0, end: 0.5, text: "Hello"),
            SpeechWord(start: 0.7, end: 1.0, text: "world")
        ])
    }
}
