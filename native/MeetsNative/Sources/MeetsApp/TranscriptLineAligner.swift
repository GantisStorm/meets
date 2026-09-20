import Foundation
import MeetsCore

/// One displayed transcript line with the time it covers.
struct AlignedLine: Equatable {
    let start: Double?
    let end: Double?
}

/// Line timing for a transcript, plus the lookup the transcript view needs to
/// highlight and follow the line being played.
struct TranscriptAlignment: Equatable {
    let lines: [AlignedLine]

    /// Positions in `lines` that carry a start, ascending — the domain
    /// `activeLine(at:)` searches. A line the transcript no longer matches has
    /// no start, and it must not hide the timed lines that follow it.
    private let timedLineIndices: [Int]

    init(lines: [AlignedLine]) {
        self.lines = lines
        self.timedLineIndices = lines.indices.filter { lines[$0].start != nil }
    }

    static let empty = TranscriptAlignment(lines: [])

    /// True when at least one line carries a time, i.e. the view has something
    /// to follow. False leaves the transcript inert.
    var hasTimings: Bool {
        !timedLineIndices.isEmpty
    }

    /// Index of the last line that has started at `time`; nil before the first
    /// timed line. A line stays active until the next line starts, so there are
    /// no dead gaps between lines.
    func activeLine(at time: Double) -> Int? {
        var low = 0
        var high = timedLineIndices.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            let index = timedLineIndices[mid]
            guard let start = lines[index].start else {
                high = mid - 1
                continue
            }
            if start <= time {
                result = index
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}

/// Maps the displayed transcript lines onto the line timings stored with the
/// recording.
///
/// The transcript is text the user may have edited and the timings describe
/// what was actually said, so the two are matched by their text before falling
/// back to the "[HH:mm:ss]" labels the transcript already carries. A line that
/// matches nothing is left without a time and simply never highlights.
enum TranscriptLineAligner {
    static func align(lines: [TranscriptChatMessage], timings: [TranscriptLineTiming]) -> TranscriptAlignment {
        guard !timings.isEmpty else {
            return TranscriptAlignment(lines: labelTimedLines(lines: lines))
        }

        let matches = matchedTimings(lines: lines, timings: timings)
        let aligned = lines.indices.map { index -> AlignedLine in
            guard let match = matches[index] else { return AlignedLine(start: nil, end: nil) }
            return AlignedLine(start: timings[match].startSeconds, end: timings[match].endSeconds)
        }
        return TranscriptAlignment(lines: aligned)
    }

    /// For each displayed line, the stored line it matches: nil when nothing
    /// matched. Timings whose own text and the transcript agree line for line
    /// map straight across; otherwise both sides are walked in order by their
    /// trimmed text, and a line that matches nothing leaves the cursor where it
    /// was so the lines after it still find their own timing.
    private static func matchedTimings(
        lines: [TranscriptChatMessage],
        timings: [TranscriptLineTiming]
    ) -> [Int?] {
        let stored = timings.map { trimmed($0.text) }
        let displayed = lines.map { trimmed($0.text) }
        guard stored != displayed else {
            return Array(timings.indices)
        }

        var matches: [Int?] = []
        matches.reserveCapacity(displayed.count)
        var cursor = 0
        for text in displayed {
            var match: Int?
            var index = cursor
            while index < stored.count {
                if stored[index] == text {
                    match = index
                    cursor = index + 1
                    break
                }
                index += 1
            }
            matches.append(match)
        }
        return matches
    }

    /// Line times for recordings stored without them: seconds since the first
    /// labelled line, taken from the "[HH:mm:ss]" labels the transcript already
    /// carries. Each line ends where the next labelled line starts.
    private static func labelTimedLines(lines: [TranscriptChatMessage]) -> [AlignedLine] {
        let clocks = lines.map { $0.timestamp.flatMap(seconds(fromClock:)) }
        guard let origin = clocks.compactMap({ $0 }).first else {
            return lines.indices.map { _ in AlignedLine(start: nil, end: nil) }
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
            guard let start else { return AlignedLine(start: nil, end: nil) }
            let next = starts.dropFirst(index + 1).compactMap { $0 }.first
            return AlignedLine(start: start, end: next.flatMap { $0 > start ? $0 : nil })
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

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
