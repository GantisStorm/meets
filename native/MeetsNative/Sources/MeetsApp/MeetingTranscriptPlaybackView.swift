import Foundation
import MeetsCore
import SwiftUI

/// The transcript tab's reader: bubbles that follow the saved recording.
///
/// While audio plays, the line being spoken is outlined, the active line scrolls
/// into view, and clicking a line seeks to it. A transcript with no line timings
/// — or no timings at all — renders exactly like a plain transcript and stays
/// inert.
struct MeetingTranscriptPlaybackView: View {
    let transcript: String
    let timings: [TranscriptLineTiming]
    @ObservedObject var model: MeetingPlaybackModel

    @State private var messages: [TranscriptChatMessage]
    @State private var alignment: TranscriptAlignment
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

    init(transcript: String, timings: [TranscriptLineTiming], model: MeetingPlaybackModel) {
        self.transcript = transcript
        self.timings = timings
        self.model = model
        let messages = TranscriptChatMessage.messages(from: transcript)
        _messages = State(initialValue: messages)
        _alignment = State(
            initialValue: TranscriptLineAligner.align(lines: messages, timings: timings)
        )
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
            rebuild(from: newTranscript, timings: timings)
        }
        .onChange(of: timings) { _, newTimings in
            rebuild(from: transcript, timings: newTimings)
        }
    }

    // MARK: - Alignment state

    /// Line being spoken, or nil while there is nothing to follow (no recording
    /// loaded, or the clock is parked at 0).
    private var activeLineIndex: Int? {
        guard model.isLoaded, model.isPlaying || model.currentTime > 0 else { return nil }
        return alignment.activeLine(at: model.currentTime)
    }

    private func rebuild(from transcript: String, timings: [TranscriptLineTiming]) {
        let messages = TranscriptChatMessage.messages(from: transcript)
        self.messages = messages
        alignment = TranscriptLineAligner.align(lines: messages, timings: timings)
    }

    // MARK: - Bubbles

    @ViewBuilder
    private func bubble(for message: TranscriptChatMessage, activeLine: Int?) -> some View {
        let index = message.id
        let line = alignment.lines.indices.contains(index) ? alignment.lines[index] : nil
        TranscriptChatBubble(
            message: message,
            isActiveLine: index == activeLine,
            seekTarget: line?.start,
            onSeek: { start in model.seek(to: start) }
        )
        .id(index)
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
        .help("Scroll the transcript back to the line being spoken")
    }
}

private struct TranscriptScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// One transcript line: the speaker/time metadata, then the line text.
///
/// The line being played is outlined and tinted. Clicking the bubble seeks to
/// that line; the tap sits on the bubble's own background — with a matching
/// content shape — and never on the `Text`, so `.textSelection(.enabled)` keeps
/// working and dragging inside the line still selects.
struct TranscriptChatBubble: View {
    let message: TranscriptChatMessage
    var isActiveLine = false
    /// When the line has a time, clicking the bubble seeks to it.
    var seekTarget: Double?
    var onSeek: ((Double) -> Void)?

    var body: some View {
        HStack(alignment: .bottom, spacing: MeetsTheme.spacing8) {
            if message.isUser {
                Spacer(minLength: 80)
            }

            interactiveBubble

            if !message.isUser {
                Spacer(minLength: 80)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }

    /// A line with no time has nothing to seek to, so it takes no click.
    @ViewBuilder
    private var interactiveBubble: some View {
        if let seekTarget {
            bubble.onTapGesture { onSeek?(seekTarget) }
        } else {
            bubble
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let metadata {
                Text(metadata)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isActiveLine ? MeetsTheme.textSecondary : MeetsTheme.textTertiary)
                    .textSelection(.enabled)
            }
            Text(message.text)
                .font(.system(size: 14))
                .foregroundStyle(MeetsTheme.textPrimary)
                .lineSpacing(2)
                .textSelection(.enabled)
        }
        .padding(.horizontal, MeetsTheme.spacing12)
        .padding(.vertical, 8)
        .background(bubbleFill)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
        .frame(maxWidth: 680, alignment: message.isUser ? .trailing : .leading)
        .animation(.easeOut(duration: 0.15), value: isActiveLine)
    }

    private var bubbleFill: Color {
        if isActiveLine {
            return MeetsTheme.accent.opacity(0.10)
        }
        return message.isUser ? MeetsTheme.accent.opacity(0.18) : MeetsTheme.surfacePrimary
    }

    private var borderColor: Color {
        if isActiveLine {
            return MeetsTheme.accent.opacity(0.7)
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
