import SwiftUI

/// The browser's header row: what the current scope holds on the leading side,
/// the meeting actions and display controls on the trailing side.
///
/// One view, used by `MeetingsView` and by the render harness, so the header
/// that ships is the header that gets inspected. Both groups fall back to a
/// stacked arrangement as the detail column narrows, because the window's
/// detail column can be as tight as ~220 points once the sidebar is subtracted.
struct MeetingBrowserHeader: View {
    @Binding var filter: MeetingBrowserFilter
    @Binding var sort: MeetingBrowserSort
    /// Ranges worth offering, derived from the oldest meeting in scope.
    let availableFilters: [MeetingBrowserFilter]
    let matchCount: Int
    /// Meetings shown only to keep a matching follow-up's thread intact.
    let contextCount: Int
    /// True while a recording is being prepared or is running: both meeting
    /// actions hold back for the same window.
    let isStartDisabled: Bool
    let onQuickNote: () -> Void
    let onImportAudio: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: MeetsTheme.spacing16) {
                meta
                Spacer(minLength: MeetsTheme.spacing16)
                actions
            }

            VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
                meta
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    actions
                }
            }
        }
    }

    private var meta: some View {
        MeetingBrowserHeaderMeta(
            matchCount: matchCount,
            contextCount: contextCount,
            filter: filter
        )
    }

    @ViewBuilder
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MeetsTheme.spacing8) {
                meetingActionButtons
                displayControls
            }
            .fixedSize(horizontal: true, vertical: false)

            // Narrow detail columns cannot hold five controls on one line.
            VStack(alignment: .trailing, spacing: MeetsTheme.spacing8) {
                meetingActionButtons
                displayControls
            }
        }
    }

    @ViewBuilder
    private var meetingActionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MeetsTheme.spacing8) {
                quickNoteButton
                importAudioButton
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .trailing, spacing: MeetsTheme.spacing8) {
                quickNoteButton
                importAudioButton
            }
        }
    }

    @ViewBuilder
    private var displayControls: some View {
        MeetingBrowserDisplayControls(
            filter: $filter,
            sort: $sort,
            availableFilters: availableFilters
        )
    }

    @ViewBuilder
    private var quickNoteButton: some View {
        Button(action: onQuickNote) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("Quick Note")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isStartDisabled ? MeetsTheme.textPrimary : MeetsTheme.accentContent)
            .padding(.horizontal, MeetsTheme.spacing12)
            .padding(.vertical, 6)
            .background(isStartDisabled ? MeetsTheme.surfacePrimary : MeetsTheme.accent)
            .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
        }
        .buttonStyle(.plain)
        .disabled(isStartDisabled)
        .help("Start a quick meeting note")
        .fixedSize()
    }

    @ViewBuilder
    private var importAudioButton: some View {
        Button(action: onImportAudio) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                Text("Import Audio")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(MeetsTheme.textPrimary)
            .padding(.horizontal, MeetsTheme.spacing12)
            .padding(.vertical, 6)
            .background(MeetsTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                    .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isStartDisabled)
        .help("Import an audio file for offline transcription")
        .fixedSize()
    }
}

/// Sort and date-range controls for the meetings browser.
///
/// Extracted from `MeetingsView` so the header and the narrow-width render
/// harness exercise the same controls: each group falls back to a tighter
/// arrangement as the detail column narrows, because the window's detail column
/// can be as tight as ~220 points once the sidebar is subtracted.
struct MeetingBrowserDisplayControls: View {
    @Binding var filter: MeetingBrowserFilter
    @Binding var sort: MeetingBrowserSort
    /// Ranges worth offering, derived from the oldest meeting in scope.
    let availableFilters: [MeetingBrowserFilter]

    var body: some View {
        // Full labels first. Then the sort label drops to its symbol, which
        // costs nothing because the menu still reports the active order; the
        // active range is always named, so it is the last thing to give up
        // space.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MeetsTheme.spacing8) {
                sortButton(showsLabel: true)
                dateFilterButton
            }
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: MeetsTheme.spacing8) {
                sortButton(showsLabel: false)
                dateFilterButton
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func sortButton(showsLabel: Bool) -> some View {
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
            chipLabel(
                systemImage: "arrow.up.arrow.down",
                title: showsLabel ? sort.label : nil,
                isActive: sort != .newestFirst
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort meetings, \(sort.label)")
        .accessibilityLabel("Sort meetings, \(sort.label)")
    }

    /// The active range is always named, so "All time" is a visible state
    /// rather than an absence.
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
            chipLabel(
                systemImage: "line.3.horizontal.decrease",
                title: filter.label,
                isActive: filter != .all
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter by date range, \(filter.label)")
        .accessibilityLabel("Filter by date range, \(filter.label)")
    }

    /// One compact toolbar control: same height, corner, and neutral fill for
    /// sort, range, and every future control, with the accent reserved for a
    /// non-default state.
    private func chipLabel(systemImage: String, title: String?, isActive: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
            if let title {
                Text(title)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(isActive ? MeetsTheme.accent : MeetsTheme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isActive ? MeetsTheme.accent.opacity(0.12) : MeetsTheme.surfacePrimary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
    }
}

/// Count line for the current scope.
///
/// One line of current state: how many meetings the scope holds, the active
/// range when there is one, and how many earlier meetings are on screen only to
/// keep a follow-up thread intact. Nothing here explains what the app is for.
struct MeetingBrowserHeaderMeta: View {
    let matchCount: Int
    /// Meetings shown only to keep a matching follow-up's thread intact.
    let contextCount: Int
    let filter: MeetingBrowserFilter

    var body: some View {
        Text(summary)
            .font(MeetsTheme.callout())
            .foregroundStyle(MeetsTheme.textSecondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Counts only meetings that satisfy the active range, so a range can never
    /// claim meetings the user did not ask for.
    private var summary: String {
        var parts = ["\(matchCount) meeting\(matchCount == 1 ? "" : "s")"]
        if filter != .all {
            parts.append(filter.label.lowercased())
        }
        if contextCount > 0 {
            parts.append("\(contextCount) earlier shown for thread context")
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}
