import SwiftUI
import MeetsCore

struct MeetingNotesView: View {
    let markdown: String

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
                let lines = markdown.components(separatedBy: .newlines)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    markdownLine(line)
                }
            }
            .frame(maxWidth: 880, alignment: .leading)
            .padding(.horizontal, MeetsTheme.spacing24)
            .padding(.vertical, MeetsTheme.spacing16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func markdownLine(_ rawLine: String) -> some View {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let indentLevel = Self.indentLevel(for: rawLine)
        if line.isEmpty {
            Color.clear
                .frame(height: MeetsTheme.spacing8)
        } else if line.hasPrefix("# ") {
            Text(String(line.dropFirst(2)))
                .font(MeetsTheme.title1())
                .foregroundStyle(MeetsTheme.textPrimary)
                .padding(.top, MeetsTheme.spacing8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if line.hasPrefix("## ") {
            Text(String(line.dropFirst(3)))
                .font(MeetsTheme.title3())
                .foregroundStyle(MeetsTheme.textPrimary)
                .padding(.top, MeetsTheme.spacing12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if line.hasPrefix("### ") {
            Text(String(line.dropFirst(4)))
                .font(MeetsTheme.headline())
                .foregroundStyle(MeetsTheme.textPrimary)
                .padding(.top, MeetsTheme.spacing4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if line.hasPrefix("- [ ] ") {
            listRow(text: String(line.dropFirst(6)), indentLevel: indentLevel, systemImage: "square")
        } else if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            listRow(text: String(line.dropFirst(6)), indentLevel: indentLevel, systemImage: "checkmark.square", iconColor: MeetsTheme.success)
        } else if line.hasPrefix("- ") {
            listRow(text: String(line.dropFirst(2)), indentLevel: indentLevel)
        } else if let numbered = Self.numberedListContent(from: line) {
            HStack(alignment: .firstTextBaseline, spacing: MeetsTheme.spacing8) {
                Text(numbered.marker)
                    .font(MeetsTheme.body())
                    .foregroundStyle(MeetsTheme.textTertiary)
                    .frame(width: 22, alignment: .trailing)
                Text(Self.inline(numbered.text))
                    .font(MeetsTheme.body())
                    .foregroundStyle(MeetsTheme.textSecondary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indentLevel) * MeetsTheme.spacing20)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(Self.inline(line))
                .font(MeetsTheme.body())
                .foregroundStyle(MeetsTheme.textPrimary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func listRow(
        text: String,
        indentLevel: Int,
        systemImage: String? = nil,
        iconColor: Color = MeetsTheme.textTertiary
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MeetsTheme.spacing8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(iconColor)
                    .frame(width: 14, alignment: .center)
            } else {
                Circle()
                    .fill(MeetsTheme.textTertiary)
                    .frame(width: 4, height: 4)
                    .offset(y: -2)
                    .frame(width: 14, alignment: .center)
            }
            Text(Self.inline(text))
                .font(MeetsTheme.body())
                .foregroundStyle(MeetsTheme.textSecondary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(indentLevel) * MeetsTheme.spacing20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Renders inline markdown — bold, italic, code, links — within one line.
    ///
    /// Block structure (headings, lists, checkboxes) is matched by
    /// `markdownLine`, so parsing is inline-only: a stray `#` or `-` in body
    /// text stays literal instead of being re-read as a block marker. Text that
    /// fails to parse falls back to itself, so notes always render.
    static func inline(_ text: String) -> AttributedString {
        MarkdownInlineParser.parse(text)
    }

    private static func indentLevel(for line: String) -> Int {
        let spaces = line.prefix { character in
            character == " " || character == "\t"
        }.reduce(0) { count, character in
            count + (character == "\t" ? 4 : 1)
        }
        return min(spaces / 2, 4)
    }

    private static func numberedListContent(from line: String) -> (marker: String, text: String)? {
        guard let range = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) else {
            return nil
        }
        let marker = line[..<line.index(before: range.upperBound)]
            .trimmingCharacters(in: .whitespaces)
        let text = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !marker.isEmpty, !text.isEmpty else { return nil }
        return (String(marker), text)
    }
}
