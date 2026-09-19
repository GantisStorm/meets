import Foundation
@testable import MeetsCore
@testable import MeetsApp
import Testing

@Suite("Local Insights", .serialized)
struct InsightsTests {
    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-insights-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    @Test("lossless contribution codec round trips sorted token counts")
    func contributionCodecRoundTrip() {
        let pairs = (1...2_000).map {
            InsightsContributionCodec.Pair(tokenID: Int64($0 * 3), count: ($0 % 17) + 1)
        }
        let encoded = InsightsContributionCodec.encode(pairs)
        let decoded = InsightsContributionCodec.decode(encoded)

        #expect(decoded == pairs)
        #expect(encoded.count < pairs.count * MemoryLayout<InsightsContributionCodec.Pair>.stride)
    }

    @Test("contribution codec rejects oversized and malformed frames without allocating")
    func contributionCodecRejectsInvalidFrames() {
        let oversized = Data([1]) + encodedVarint(UInt64(InsightsContributionCodec.maximumDecodedBytes + 1))
        let exceedsInt = Data([1]) + encodedVarint(UInt64(Int.max) + 1) + Data([0x01])
        let truncatedRaw = Data([0]) + encodedVarint(8) + Data([0x01, 0x01])
        let unknownMarker = Data([2, 0])

        #expect(InsightsContributionCodec.decode(oversized).isEmpty)
        #expect(InsightsContributionCodec.decode(exceedsInt).isEmpty)
        #expect(InsightsContributionCodec.decode(truncatedRaw).isEmpty)
        #expect(InsightsContributionCodec.decode(unknownMarker).isEmpty)
    }

    @MainActor
    @Test("share image write failures return inline feedback")
    func shareImageWriteFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-share-write-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = InsightsShareFileWriter.write(Data([0x89, 0x50, 0x4E, 0x47]), to: directory)

        guard case .failed(let message) = result else {
            Issue.record("Writing image data to a directory should fail")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test("calendar range remains day-correct across daylight saving changes")
    func daylightSavingRange() throws {
        let store = try makeStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 12))!

        let snapshot = try store.insightsSnapshot(range: .thirtyDays, now: now, calendar: calendar)
        #expect(snapshot.dailyActivity.count == 30)
        #expect(calendar.isDate(snapshot.dailyActivity.first!.date, inSameDayAs: calendar.date(byAdding: .day, value: -29, to: now)!))
        #expect(calendar.isDate(snapshot.dailyActivity.last!.date, inSameDayAs: now))
    }

    @Test("word analysis removes stop words and ranks ties alphabetically")
    func wordAnalysis() {
        let words = InsightsWordAnalyzer.frequencies(
            in: "The aurora aurora and fjord fjord beacon",
            limit: 10
        )
        #expect(!words.contains { $0.word == "the" || $0.word == "and" })
        #expect(words.map(\.word).prefix(2) == ["aurora", "fjord"])
        #expect(words.first?.count == 2)
    }

    @Test("word analysis accepts Unicode and rejects numeric noise")
    func unicodeWordAnalysis() {
        let words = InsightsWordAnalyzer.frequencies(in: "नमस्ते नमस्ते 1234 x café café", limit: 10)
        #expect(words.contains { $0.word == "नमस्ते" && $0.count == 2 })
        #expect(words.contains { $0.word == "café" && $0.count == 2 })
        #expect(!words.contains { $0.word == "1234" || $0.word == "x" })
    }

    @Test("meeting word analysis removes diarization labels and transcript annotations")
    func meetingLabelsAreRemoved() {
        let transcript = """
        [00:01:04] Speaker 1: Roadmap roadmap planning
        [00:01:08] You: Product launch
        [00:01:12] Others: [MUSIC PLAYING] Product review
        """
        let words = InsightsWordAnalyzer.meetingFrequencies(in: transcript, limit: 20)

        #expect(!words.contains { ["speaker", "you", "others", "music", "playing"].contains($0.word) })
        #expect(words.first?.word == "product")
        #expect(words.first?.count == 2)
        #expect(words.contains { $0.word == "roadmap" && $0.count == 2 })
    }

    @Test("word analysis is deterministically capped for large input")
    func largeInputIsCapped() {
        let text = (0..<200).map { "term" + String(repeating: "a", count: $0 + 2) }.joined(separator: " ")
        let words = InsightsWordAnalyzer.frequencies(in: text, limit: 48)
        #expect(words.count == 48)
        #expect(words == words.sorted { $0.count == $1.count ? $0.word < $1.word : $0.count > $1.count })
    }

    @Test("insights entry section scroll happens only after the first successful load")
    func initialSectionScrollIsOneShot() {
        var gate = InsightsInitialScrollGate()
        let beforeSnapshot = gate.consume(hasSnapshot: false)
        let firstSnapshot = gate.consume(hasSnapshot: true)
        let refreshedSnapshot = gate.consume(hasSnapshot: true)

        #expect(!beforeSnapshot)
        #expect(firstSnapshot)
        #expect(!refreshedSnapshot)
    }

    private func encodedVarint(_ value: UInt64) -> Data {
        var remaining = value
        var result = Data()
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            result.append(byte)
        } while remaining != 0
        return result
    }
}
