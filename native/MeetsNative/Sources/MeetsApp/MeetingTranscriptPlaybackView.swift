import AppKit
import MeetsCore
import SwiftUI

/// The transcript tab's reader: bubbles that follow the saved recording.
///
/// While audio plays, the word being spoken is highlighted, the active line
/// scrolls into view, and clicking any highlighted word seeks to it. A
/// transcript with no word timings — or no timings at all — renders exactly like
/// a plain transcript and stays inert.
struct MeetingTranscriptPlaybackView: View {
    let transcript: String
    let words: [TranscriptWordTiming]
    @ObservedObject var model: MeetingPlaybackModel

    @State private var messages: [TranscriptChatMessage]
    @State private var alignment: TranscriptAlignment
    @State private var baseStrings: [Int: AttributedString]
    /// Memoises the active line's highlighted text. Mutated from `body`, so it is
    /// a plain reference type rather than `@State` value — nothing here drives a
    /// redraw.
    @State private var highlightCache = HighlightCache()
    @State private var isFollowing = true
    @State private var hasObservedScroll = false
    @State private var lastScrollOffset: CGFloat = 0
    @State private var lastProgrammaticScroll = Date.distantPast
    @State private var lastObservedTime: TimeInterval = 0

    private static let scrollSpace = "meeting.transcript.scroll"
    /// A scroll this soon after our own scroll is that scroll still settling,
    /// not the user taking over.
    private static let programmaticScrollGrace: TimeInterval = 0.3
    /// A clock jump this large is a seek, not playback.
    private static let seekJump: TimeInterval = 0.5

    init(transcript: String, words: [TranscriptWordTiming], model: MeetingPlaybackModel) {
        self.transcript = transcript
        self.words = words
        self.model = model
        let messages = TranscriptChatMessage.messages(from: transcript)
        _messages = State(initialValue: messages)
        _alignment = State(initialValue: TranscriptWordAligner.align(lines: messages, words: words))
        _baseStrings = State(initialValue: Self.baseStrings(for: messages))
    }

    var body: some View {
        let activeLine = activeLineIndex
        ZStack(alignment: .bottomTrailing) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
                        scrollSentinel

                        if messages.isEmpty {
                            Text("No transcript available")
                                .font(MeetsTheme.body())
                                .foregroundStyle(MeetsTheme.textTertiary)
                                .frame(maxWidth: 860, alignment: .leading)
                                .padding(MeetsTheme.spacing24)
                        } else {
                            ForEach(messages) { message in
                                bubble(for: message, activeLine: activeLine)
                            }
                        }
                    }
                    .frame(maxWidth: 860, alignment: .leading)
                    .padding(.horizontal, MeetsTheme.spacing24)
                    .padding(.vertical, MeetsTheme.spacing16)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(TranscriptScrollOffsetKey.self) { offset in
                    registerScroll(offset)
                }
                .onChange(of: activeLine) { _, lineIndex in
                    follow(lineIndex, proxy: proxy)
                }
                .onChange(of: model.currentTime) { _, time in
                    registerClock(time)
                }
                .onChange(of: isFollowing) { _, following in
                    guard following else { return }
                    follow(activeLine, proxy: proxy, force: true)
                }
            }

            if showsFollowPill {
                followPill
            }
        }
        .onChange(of: transcript) { _, newTranscript in
            rebuild(from: newTranscript, words: words)
        }
        .onChange(of: words) { _, newWords in
            rebuild(from: transcript, words: newWords)
        }
    }

    // MARK: - Alignment state

    /// Line whose words are being spoken, or nil while there is nothing to
    /// follow (no recording loaded, or the clock is parked at 0).
    private var activeLineIndex: Int? {
        guard model.isLoaded, model.isPlaying || model.currentTime > 0 else { return nil }
        return alignment.activeLine(at: model.currentTime)
    }

    private func activeWordIndex(in lineIndex: Int) -> Int? {
        alignment.activeWord(at: model.currentTime, in: lineIndex)
    }

    private func rebuild(from transcript: String, words: [TranscriptWordTiming]) {
        let messages = TranscriptChatMessage.messages(from: transcript)
        self.messages = messages
        baseStrings = Self.baseStrings(for: messages)
        alignment = TranscriptWordAligner.align(lines: messages, words: words)
        highlightCache.lineIndex = -1
        highlightCache.text = nil
    }

    /// Plain per-line text, built once per transcript change so a playing clock
    /// only ever restyles the one line being spoken.
    private static func baseStrings(for messages: [TranscriptChatMessage]) -> [Int: AttributedString] {
        var cache: [Int: AttributedString] = [:]
        for (index, message) in messages.enumerated() {
            var string = AttributedString(message.text)
            string.foregroundColor = MeetsTheme.textPrimary
            cache[index] = string
        }
        return cache
    }

    // MARK: - Bubbles

    @ViewBuilder
    private func bubble(for message: TranscriptChatMessage, activeLine: Int?) -> some View {
        let index = message.id
        let line = alignment.lines.indices.contains(index) ? alignment.lines[index] : nil
        let isActive = index == activeLine
        let activeWord = activeWord(for: index, line: line)
        TranscriptChatBubble(
            message: message,
            text: isActive
                ? activeLineText(for: message, index: index, line: line, activeWord: activeWord)
                : baseStrings[index],
            alignedWords: line?.words ?? [],
            isActiveLine: isActive,
            onSeek: { start in model.seek(to: start) }
        )
        .id(index)
    }

    private func activeWord(for lineIndex: Int, line: AlignedLine?) -> Int? {
        line == nil ? nil : activeWordIndex(in: lineIndex)
    }

    /// The active line's text, rebuilt only when the spoken word changes rather
    /// than on every clock tick.
    private func activeLineText(
        for message: TranscriptChatMessage,
        index: Int,
        line: AlignedLine?,
        activeWord: Int?
    ) -> AttributedString {
        let cache = highlightCache
        if cache.lineIndex == index, cache.wordIndex == activeWord, let text = cache.text {
            return text
        }
        let text = highlightedText(for: message, line: line, activeWord: activeWord)
        cache.lineIndex = index
        cache.wordIndex = activeWord
        cache.text = text
        return text
    }

    /// The active line's text with the spoken word boxed. Every other word keeps
    /// the transcript's normal colour, which the theme already resolves to
    /// `textPrimary`, so only the spoken word needs an attribute.
    private func highlightedText(
        for message: TranscriptChatMessage,
        line: AlignedLine?,
        activeWord: Int?
    ) -> AttributedString {
        guard let line, !line.words.isEmpty else {
            return baseStrings[message.id] ?? AttributedString(message.text)
        }

        var string = AttributedString()
        var cursor = message.text.startIndex
        for (index, word) in line.words.enumerated() where word.range.lowerBound >= cursor {
            append(&string, message.text[cursor..<word.range.lowerBound], isSpoken: false)
            append(&string, message.text[word.range], isSpoken: index == activeWord)
            cursor = word.range.upperBound
        }
        append(&string, message.text[cursor...], isSpoken: false)
        return string
    }

    private func append(_ string: inout AttributedString, _ text: Substring, isSpoken: Bool) {
        guard !text.isEmpty else { return }
        var piece = AttributedString(String(text))
        piece.foregroundColor = MeetsTheme.textPrimary
        if isSpoken {
            piece.backgroundColor = MeetsTheme.accent.opacity(0.35)
        }
        string += piece
    }

    // MARK: - Following the audio

    /// Reports the scroll position so a user drag can take over from the
    /// auto-scroll. Sits first in the content, so its offset is the scroll
    /// position itself.
    private var scrollSentinel: some View {
        Color.clear
            .frame(height: 0)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TranscriptScrollOffsetKey.self,
                        value: proxy.frame(in: .named(Self.scrollSpace)).minY
                    )
                }
            )
    }

    private func registerScroll(_ offset: CGFloat) {
        defer {
            lastScrollOffset = offset
            hasObservedScroll = true
        }
        guard hasObservedScroll, abs(offset - lastScrollOffset) > 0.5 else { return }
        guard Date().timeIntervalSince(lastProgrammaticScroll) > Self.programmaticScrollGrace else { return }
        isFollowing = false
    }

    private func registerClock(_ time: TimeInterval) {
        let jumped = abs(time - lastObservedTime) > Self.seekJump
        lastObservedTime = time
        // A seek — or playback restarting from the top — puts the reader back
        // under the audio's control.
        if jumped {
            isFollowing = true
        }
    }

    private func follow(_ lineIndex: Int?, proxy: ScrollViewProxy, force: Bool = false) {
        guard isFollowing, let lineIndex, messages.indices.contains(lineIndex) else { return }
        // Paused readers keep their place; only playback moves the transcript.
        guard force || model.isPlaying else { return }
        lastProgrammaticScroll = Date()
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(lineIndex, anchor: .center)
        }
    }

    private var showsFollowPill: Bool {
        !isFollowing && alignment.hasTimings
    }

    private var followPill: some View {
        Button {
            isFollowing = true
        } label: {
            Text("Follow audio")
                .font(MeetsTheme.captionMedium())
                .foregroundStyle(MeetsTheme.textPrimary)
                .padding(.horizontal, MeetsTheme.spacing12)
                .padding(.vertical, 6)
                .background(MeetsTheme.surfacePrimary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .padding(MeetsTheme.spacing12)
        .help("Scroll the transcript back to the words being spoken")
    }
}

private struct TranscriptScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Holds the active line's highlighted text between redraws. A reference type so
/// the view can refresh it while it evaluates its body.
private final class HighlightCache {
    var lineIndex = -1
    var wordIndex: Int?
    var text: AttributedString?
}

/// One transcript line: the speaker/time metadata, then the line text.
///
/// When the line has aligned words the text also carries tap targets over those
/// words — see `TranscriptWordHitTesting` — so a click seeks to that word.
struct TranscriptChatBubble: View {
    let message: TranscriptChatMessage
    var text: AttributedString?
    var alignedWords: [AlignedWord] = []
    var isActiveLine = false
    var onSeek: ((Double) -> Void)?

    @State private var measuredTextWidth: CGFloat = 0
    @State private var hits: [TranscriptWordHit] = []

    var body: some View {
        HStack(alignment: .bottom, spacing: MeetsTheme.spacing8) {
            if message.isUser {
                Spacer(minLength: 80)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let metadata {
                    Text(metadata)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(MeetsTheme.textTertiary)
                        .textSelection(.enabled)
                }
                lineText
            }
            .padding(.horizontal, MeetsTheme.spacing12)
            .padding(.vertical, 8)
            .background(message.isUser ? MeetsTheme.accent.opacity(0.18) : MeetsTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .frame(maxWidth: 680, alignment: message.isUser ? .trailing : .leading)

            if !message.isUser {
                Spacer(minLength: 80)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }

    private var lineText: some View {
        Text(text ?? plainText)
            .font(.system(size: 14))
            .foregroundStyle(MeetsTheme.textPrimary)
            .lineSpacing(2)
            .textSelection(.enabled)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { updateHits(width: proxy.size.width) }
                        .onChange(of: proxy.size.width) { _, width in updateHits(width: width) }
                }
            )
            .overlay(alignment: .topLeading) { wordHitTargets }
    }

    private var plainText: AttributedString {
        var string = AttributedString(message.text)
        string.foregroundColor = MeetsTheme.textPrimary
        return string
    }

    @ViewBuilder
    private var wordHitTargets: some View {
        if !hits.isEmpty {
            ForEach(hits.indices, id: \.self) { index in
                let hit = hits[index]
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: hit.rect.width, height: hit.rect.height)
                    .offset(x: hit.rect.minX, y: hit.rect.minY)
                    .onTapGesture { onSeek?(hit.start) }
            }
        }
    }

    private func updateHits(width: CGFloat) {
        guard onSeek != nil, !alignedWords.isEmpty, width > 1 else {
            if !hits.isEmpty {
                hits = []
            }
            return
        }
        guard hits.isEmpty || abs(width - measuredTextWidth) > 0.5 else { return }
        measuredTextWidth = width
        hits = TranscriptWordHitTesting.hits(text: message.text, words: alignedWords, width: width)
    }

    private var borderColor: Color {
        if isActiveLine {
            return MeetsTheme.accent.opacity(0.6)
        }
        return message.isUser ? MeetsTheme.accent.opacity(0.25) : MeetsTheme.surfaceBorder
    }

    private var metadata: String? {
        switch (message.speaker, message.timestamp) {
        case let (speaker?, timestamp?):
            return "\(speaker) \(timestamp)"
        case let (speaker?, nil):
            return speaker
        case let (nil, timestamp?):
            return timestamp
        case (nil, nil):
            return nil
        }
    }
}

/// A tap target over one aligned word, in the bubble text's own coordinates.
struct TranscriptWordHit: Equatable {
    let rect: CGRect
    let start: Double
}

/// Places the aligned words where `Text` actually draws them.
///
/// The line is rendered as one `Text` so selection and the `AttributedString`
/// styling survive, which leaves no per-word view to tap. The same string, font,
/// and width are laid out through `NSLayoutManager` instead, and the resulting
/// glyph rectangles become invisible tap targets over the `Text`. Word positions
/// are unaffected by the highlight, so the rectangles are computed once per
/// width and reused while the clock moves.
enum TranscriptWordHitTesting {
    static let fontSize: CGFloat = 14
    /// Matches the `Text`'s `.lineSpacing(2)`.
    static let lineSpacing: CGFloat = 2

    static func hits(text: String, words: [AlignedWord], width: CGFloat) -> [TranscriptWordHit] {
        guard width > 1, !words.isEmpty else { return [] }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .paragraphStyle: paragraph
            ]
        )
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        return words.compactMap { word in
            let range = NSRange(word.range, in: text)
            guard range.length > 0 else { return nil }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            guard rect.width > 0, rect.height > 0 else { return nil }
            // A slightly taller target than the glyphs: word boxes are short.
            return TranscriptWordHit(
                rect: rect.insetBy(dx: 0, dy: -1),
                start: word.start
            )
        }
    }
}
