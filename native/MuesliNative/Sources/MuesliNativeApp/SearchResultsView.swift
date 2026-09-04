import SwiftUI
import MuesliCore

struct SearchResultsView: View {
    let appState: AppState
    let controller: MuesliController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().foregroundStyle(MuesliTheme.surfaceBorder)

            if appState.searchResultMeetings.isEmpty {
                emptyState
            } else {
                resultsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 0) {
            Text("Meetings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MuesliTheme.textPrimary)
            Text("\(appState.searchResultMeetings.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(MuesliTheme.accentSubtle)
                .clipShape(Capsule())
            Spacer()
            Button {
                controller.clearSearch()
            } label: {
                Text("Clear")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, MuesliTheme.spacing20)
        .padding(.vertical, MuesliTheme.spacing12)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(appState.searchResultMeetings) { record in
                    SearchMeetingRow(record: record, query: appState.searchQuery) {
                        controller.showMeetingDocument(id: record.id)
                    }
                }
            }
            .padding(.vertical, MuesliTheme.spacing8)
        }
    }

    // MARK: - Empty States

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(MuesliTheme.textTertiary)
            Text("No results for \"\(appState.searchQuery)\"")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Meeting Row

private struct SearchMeetingRow: View {
    let record: MeetingRecord
    let query: String
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.title)
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineLimit(1)
            HStack(spacing: MuesliTheme.spacing8) {
                Text(MeetingBrowserLogic.formatStartTime(record.startTime))
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                Text("\u{2022}")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                Text(formatDuration(record.durationSeconds))
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            let matchField = bestMatchField()
            if !matchField.isEmpty {
                snippetText(from: matchField, highlighting: query)
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MuesliTheme.spacing20)
        .padding(.vertical, MuesliTheme.spacing12)
        .background(isHovered ? MuesliTheme.backgroundHover : Color.clear)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .onTapGesture(perform: onSelect)
    }

    private func bestMatchField() -> String {
        let q = query.lowercased()
        if record.title.lowercased().contains(q) {
            return MeetingPreviewText.plainText(
                from: record.formattedNotes.isEmpty ? record.rawTranscript : record.formattedNotes
            )
        }
        if record.formattedNotes.lowercased().contains(q) {
            return MeetingPreviewText.plainText(from: record.formattedNotes)
        }
        if record.rawTranscript.lowercased().contains(q) {
            return MeetingPreviewText.plainText(from: record.rawTranscript)
        }
        return ""
    }

    private func formatDuration(_ seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        if rounded < 60 { return "\(rounded)s" }
        let m = rounded / 60
        let s = rounded % 60
        if m < 60 { return s > 0 ? "\(m)m \(s)s" : "\(m)m" }
        let h = m / 60
        let rm = m % 60
        return rm > 0 ? "\(h)h \(rm)m" : "\(h)h"
    }
}

// MARK: - Snippet Highlighting

private func snippetText(from text: String, highlighting query: String) -> Text {
    guard !query.isEmpty else { return Text(text) }

    guard let matchRange = text.range(of: query, options: .caseInsensitive) else {
        let truncated = text.count > 120 ? String(text.prefix(120)) + "..." : text
        return Text(truncated).foregroundStyle(MuesliTheme.textSecondary)
    }

    let matchStart = text.distance(from: text.startIndex, to: matchRange.lowerBound)
    let contextChars = 60
    let snippetStart = max(0, matchStart - contextChars)
    let snippetStartIndex = text.index(text.startIndex, offsetBy: snippetStart)
    let matchEnd = text.distance(from: text.startIndex, to: matchRange.upperBound)
    let snippetEnd = min(text.count, matchEnd + contextChars)
    let snippetEndIndex = text.index(text.startIndex, offsetBy: snippetEnd)
    let snippet = String(text[snippetStartIndex..<snippetEndIndex])

    let prefix = snippetStart > 0 ? "..." : ""
    let suffix = snippetEnd < text.count ? "..." : ""

    guard let localRange = snippet.range(of: query, options: .caseInsensitive) else {
        return Text(prefix + snippet + suffix).foregroundStyle(MuesliTheme.textSecondary)
    }

    let before = String(snippet[snippet.startIndex..<localRange.lowerBound])
    let match = String(snippet[localRange])
    let after = String(snippet[localRange.upperBound..<snippet.endIndex])

    return Text(prefix + before).foregroundStyle(MuesliTheme.textSecondary)
        + Text(match).bold().foregroundStyle(MuesliTheme.accent)
        + Text(after + suffix).foregroundStyle(MuesliTheme.textSecondary)
}
