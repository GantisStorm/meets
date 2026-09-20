import Foundation
import MeetsCore

/// A timed word placed inside a transcript line.
struct AlignedWord: Equatable {
    /// Range of the word inside its line's `text`.
    let range: Range<String.Index>
    let start: Double
    let end: Double
}

/// One displayed transcript line with the time it covers.
struct AlignedLine: Equatable {
    let lineIndex: Int
    /// First and last aligned word in the line; nil when nothing matched.
    let start: Double?
    let end: Double?
    let words: [AlignedWord]
}

/// Line and word timing for a transcript, plus the lookups the transcript view
/// needs to highlight the spoken word and follow along.
struct TranscriptAlignment: Equatable {
    let lines: [AlignedLine]

    static let empty = TranscriptAlignment(lines: [])

    /// True when at least one line carries a time, i.e. the view has something
    /// to follow. False leaves the transcript inert.
    var hasTimings: Bool {
        lines.contains { $0.start != nil }
    }

    /// Index of the last line that has started at `time`; nil before the first
    /// timed line. A line stays active until the next line starts, so there are
    /// no dead gaps between lines.
    func activeLine(at time: Double) -> Int? {
        var low = 0
        var high = lines.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            guard let start = lines[mid].start else {
                low = mid + 1
                continue
            }
            if start <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// Index into `lines[lineIndex].words` of the word being spoken at `time`.
    /// A word stays active until the next word starts — not until its own end —
    /// so a gap between two words never blanks the highlight.
    func activeWord(at time: Double, in lineIndex: Int) -> Int? {
        guard lines.indices.contains(lineIndex) else { return nil }
        let words = lines[lineIndex].words
        var low = 0
        var high = words.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if words[mid].start <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}

/// Maps the displayed transcript lines onto the word timings captured with the
/// recording.
///
/// The transcript is text the user may have edited, and the timings come from
/// whoever ran the recogniser, so the two are matched by walking both in order:
/// each line token looks a few words ahead for a normalised match. Text the
/// recogniser never saw stays unhighlighted, and timed words no line claims are
/// skipped when a later token matches past them.
enum TranscriptWordAligner {
    /// How far past the cursor a line token may look for its timed word. Wide
    /// enough for a reworded word or two, narrow enough that a repeated phrase
    /// cannot pull a line's timing off by seconds.
    private static let lookAhead = 6

    static func align(lines: [TranscriptChatMessage], words: [TranscriptWordTiming]) -> TranscriptAlignment {
        guard !words.isEmpty else {
            return TranscriptAlignment(lines: labelTimedLines(lines: lines))
        }

        let normalizedWords = words.map { normalized($0.text) }
        var alignedLines: [AlignedLine] = []
        var cursor = 0

        for (index, line) in lines.enumerated() {
            let tokens = wordTokens(in: line.text)
            var alignedWords: [AlignedWord] = []
            for token in tokens {
                guard let match = firstMatch(of: token, from: cursor, in: normalizedWords) else { continue }
                alignedWords.append(
                    AlignedWord(
                        range: token.range,
                        start: words[match].startSeconds,
                        end: words[match].endSeconds
                    )
                )
                cursor = match + 1
            }
            if alignedWords.isEmpty, !tokens.isEmpty {
                // A line the transcript rewrote past recognition would otherwise
                // strand every later line outside the look-ahead window. Its
                // tokens are the best estimate of how many timed words it used.
                cursor = min(words.count, cursor + tokens.count)
            }
            alignedLines.append(
                AlignedLine(
                    lineIndex: index,
                    start: alignedWords.map(\.start).min(),
                    end: alignedWords.map(\.end).max(),
                    words: alignedWords
                )
            )
        }

        return TranscriptAlignment(lines: alignedLines)
    }

    /// Line times for recordings transcribed without word timings: seconds
    /// since the first labelled line, taken from the "[HH:mm:ss]" labels the
    /// transcript already carries. Each line ends where the next one starts.
    private static func labelTimedLines(lines: [TranscriptChatMessage]) -> [AlignedLine] {
        let clocks = lines.map { $0.timestamp.flatMap(seconds(fromClock:)) }
        guard let origin = clocks.compactMap({ $0 }).first else {
            return lines.indices.map { AlignedLine(lineIndex: $0, start: nil, end: nil, words: []) }
        }

        var starts: [Double?] = []
        var previous = 0.0
        for clock in clocks {
            guard let clock else {
                starts.append(nil)
                continue
            }
            // Labels are wall-clock stamps; keep them relative, positive, and in
            // reading order even when a line was relabelled out of sequence.
            let start = max(max(clock - origin, 0), previous)
            previous = start
            starts.append(start)
        }

        return starts.enumerated().map { index, start in
            guard let start else {
                return AlignedLine(lineIndex: index, start: nil, end: nil, words: [])
            }
            let next = starts.dropFirst(index + 1).compactMap { $0 }.first
            return AlignedLine(lineIndex: index, start: start, end: next.flatMap { $0 > start ? $0 : nil }, words: [])
        }
    }

    /// "HH:mm:ss" — also "mm:ss", "ss", and a fractional last component — into
    /// seconds. Nil for anything else, including the empty label.
    static func seconds(fromClock label: String) -> Double? {
        let parts = label.split(separator: ":")
        guard (1...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for (offset, part) in parts.enumerated() {
            let isLast = offset == parts.count - 1
            let value: Double?
            if isLast {
                value = Double(part.trimmingCharacters(in: .whitespaces))
            } else {
                value = Int(part.trimmingCharacters(in: .whitespaces)).map(Double.init)
            }
            guard let value else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    private struct Token {
        let range: Range<String.Index>
        let normalized: String
    }

    private static func wordTokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace {
                end = text.index(after: end)
            }
            let range = index..<end
            let normalized = normalized(String(text[range]))
            // Punctuation-only tokens ("—", "...") have nothing to match.
            if !normalized.isEmpty {
                tokens.append(Token(range: range, normalized: normalized))
            }
            index = end
        }
        return tokens
    }

    /// Comparison form: case, width, and diacritics folded, punctuation and
    /// symbols dropped, so "It's," "it's" and "ITS" are one word.
    private static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: nil)
        let stripped = folded.unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.symbols.contains($0)
        }
        return String(String.UnicodeScalarView(stripped)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatch(of token: Token, from cursor: Int, in normalizedWords: [String]) -> Int? {
        let start = max(cursor, 0)
        let limit = min(normalizedWords.count, start + lookAhead)
        var index = start
        while index < limit {
            if normalizedWords[index] == token.normalized {
                return index
            }
            index += 1
        }
        return nil
    }
}
