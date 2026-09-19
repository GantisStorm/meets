import SwiftUI

/// Sort, date-range, and layout controls for the meetings browser.
///
/// Extracted from `MeetingsView` so the header and the narrow-width render
/// harness exercise the same controls: each group falls back to a stacked
/// arrangement as the detail column narrows, because the window's detail column
/// can be as tight as ~220 points once the sidebar is subtracted.
struct MeetingBrowserDisplayControls: View {
    @Binding var filter: MeetingBrowserFilter
    @Binding var sort: MeetingBrowserSort
    @Binding var layout: MeetingBrowserLayout
    /// Ranges worth offering, derived from the oldest meeting in scope.
    let availableFilters: [MeetingBrowserFilter]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MeetsTheme.spacing8) {
                sortButton
                dateFilterButton
                layoutControl
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .trailing, spacing: MeetsTheme.spacing8) {
                HStack(spacing: MeetsTheme.spacing8) {
                    sortButton
                    dateFilterButton
                }
                .fixedSize(horizontal: true, vertical: false)
                layoutControl
            }

            VStack(alignment: .trailing, spacing: MeetsTheme.spacing8) {
                sortButton
                dateFilterButton
                layoutControl
            }
        }
    }

    @ViewBuilder
    private var sortButton: some View {
        Menu {
            ForEach([MeetingBrowserSort.newestFirst, .oldestFirst], id: \.self) { option in
                Button {
                    sort = option
                } label: {
                    HStack {
                        Text(option.label)
                        if sort == option {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11))
                Text(sort.label)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .foregroundStyle(sort != .newestFirst ? MeetsTheme.accent : MeetsTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(sort != .newestFirst ? MeetsTheme.accent.opacity(0.12) : MeetsTheme.surfacePrimary.opacity(0.5))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort meetings")
        .accessibilityLabel("Sort meetings, \(sort.label)")
    }

    @ViewBuilder
    private var dateFilterButton: some View {
        Menu {
            ForEach(availableFilters, id: \.self) { option in
                Button {
                    filter = option
                } label: {
                    HStack {
                        Text(option.label)
                        if filter == option {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11))
                if filter != .all {
                    Text(filter.label)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(filter != .all ? MeetsTheme.accent : MeetsTheme.textTertiary)
            .padding(.horizontal, filter != .all ? 8 : 0)
            .padding(.vertical, 3)
            .background(filter != .all ? MeetsTheme.accent.opacity(0.12) : Color.clear)
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter by date range")
        .accessibilityLabel(
            filter == .all ? "Filter by date range" : "Filter by date range, \(filter.label)"
        )
    }

    /// Grid/list switch. A native segmented picker keeps the choice on the
    /// keyboard focus ring instead of hiding it behind a menu.
    @ViewBuilder
    private var layoutControl: some View {
        Picker("Meeting layout", selection: $layout) {
            ForEach(MeetingBrowserLayout.allCases, id: \.self) { option in
                Label(option.label, systemImage: option.symbolName)
                    .labelStyle(.iconOnly)
                    .tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Switch between the card grid and the list")
        .accessibilityLabel("Meeting layout")
    }
}

/// Count and hint line under the browser title.
///
/// The matching count sits on its own line with the hint beneath it, so a narrow
/// detail column stacks them instead of squeezing both into one row.
struct MeetingBrowserHeaderMeta: View {
    let matchCount: Int
    /// Meetings shown only to keep a matching follow-up's thread intact.
    let contextCount: Int
    let filter: MeetingBrowserFilter

    var body: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
            Text(countSummary)
                .font(MeetsTheme.callout())
                .foregroundStyle(MeetsTheme.textSecondary)
                .lineLimit(1)

            Text(hint)
                .font(MeetsTheme.callout())
                .foregroundStyle(MeetsTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Counts only meetings that satisfy the active range, so a range can never
    /// claim meetings the user did not ask for.
    private var countSummary: String {
        let meetings = "\(matchCount) meeting\(matchCount == 1 ? "" : "s")"
        guard filter != .all else { return meetings }
        return "\(meetings) in \(filter.label.lowercased())"
    }

    private var hint: String {
        guard contextCount > 0 else {
            return "Open a meeting to review notes, transcript, and template-driven summaries"
        }
        return "\(contextCount) earlier meeting\(contextCount == 1 ? "" : "s") shown to keep follow-up threads intact"
    }
}
