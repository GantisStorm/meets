import Foundation
import MeetsCore

/// Pure grouping and mapping helpers that turn backend token or word timings
/// into the per-word timings persisted for a meeting transcript.
///
/// The token grouping mirrors FluidAudio's `buildWordTimings(from:)`: tokens
/// whose piece starts with a word-boundary marker (`▁` or a leading space)
/// begin a word, the rest append to it, and a word spans its first sub-word's
/// start to its last sub-word's end. Punctuation-only pieces carry no word of
/// their own, so they attach to the word they follow instead of standing alone.
enum TranscriptWordTimingBuilder {
    /// SentencePiece word-boundary marker (`U+2581`). Streaming token pieces
    /// arrive with this already normalized to a leading space.
    private static let wordBoundaryMarker: Character = "\u{2581}"

    /// Group SentencePiece sub-word tokens into words.
    static func words(fromTokens tokens: [(token: String, start: Double, end: Double)]) -> [SpeechWord] {
        var words: [SpeechWord] = []
        var currentWord = ""
        var wordStart: Double = 0
        var wordEnd: Double = 0

        func flush() {
            let trimmed = currentWord.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                words.append(SpeechWord(start: wordStart, end: wordEnd, text: trimmed))
            }
            currentWord = ""
        }

        for token in tokens {
            let piece = token.token
            // Blank emissions carry no text and no boundary.
            guard !piece.isEmpty, piece != "<blank>", piece != "<pad>" else { continue }

            let startsNewWord = isWordBoundary(piece)
            let stripped = startsNewWord ? String(piece.dropFirst()) : piece
            guard !stripped.trimmingCharacters(in: .whitespaces).isEmpty else {
                // A bare boundary closes the word in progress without opening one.
                if startsNewWord { flush() }
                continue
            }

            if isPunctuationOnly(stripped) {
                if !currentWord.isEmpty {
                    currentWord += stripped
                    wordEnd = token.end
                } else if let last = words.last {
                    words[words.count - 1] = SpeechWord(
                        start: last.start,
                        end: token.end,
                        text: last.text + stripped
                    )
                } else {
                    currentWord = stripped
                    wordStart = token.start
                    wordEnd = token.end
                }
                continue
            }

            if startsNewWord || currentWord.isEmpty {
                flush()
                currentWord = stripped
                wordStart = token.start
            } else {
                currentWord += stripped
            }
            wordEnd = token.end
        }

        flush()
        return words
    }

    /// Normalize word timings that a backend already grouped.
    static func words(fromWhisper words: [(word: String, start: Double, end: Double)]) -> [SpeechWord] {
        words.compactMap { entry in
            let text = entry.word.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return SpeechWord(start: entry.start, end: entry.end, text: text)
        }
    }

    /// Shift every word by a chunk's offset into the saved recording.
    static func offset(_ words: [SpeechWord], by seconds: Double) -> [SpeechWord] {
        guard seconds != 0 else { return words }
        return words.map {
            SpeechWord(start: $0.start + seconds, end: $0.end + seconds, text: $0.text)
        }
    }

    /// Tag words with a speaker resolved at each word's midpoint, numbering them
    /// 0…n-1 in the order given.
    static func tagged(_ words: [SpeechWord], speakerAt: (Double) -> String) -> [TranscriptWordTiming] {
        tagged(words.map { word in
            (word: word, speaker: speakerAt((word.start + word.end) / 2))
        })
    }

    /// Tag words with their own speaker label, numbering them 0…n-1 in reading
    /// order. Sources that interleave (mic plus system audio) are merged here so
    /// the stored ordinals stay contiguous.
    static func tagged(_ entries: [(word: SpeechWord, speaker: String)]) -> [TranscriptWordTiming] {
        entries
            .sorted { $0.word.start < $1.word.start }
            .enumerated()
            .map { index, entry in
                TranscriptWordTiming(
                    ordinal: index,
                    speaker: entry.speaker,
                    startSeconds: entry.word.start,
                    endSeconds: entry.word.end,
                    text: entry.word.text
                )
            }
    }

    private static func isWordBoundary(_ token: String) -> Bool {
        token.first == wordBoundaryMarker || token.first == " "
    }

    private static func isPunctuationOnly(_ text: String) -> Bool {
        var hasPunctuation = false
        for character in text where !character.isWhitespace {
            guard character.isPunctuation || character.isSymbol else { return false }
            hasPunctuation = true
        }
        return hasPunctuation
    }
}
