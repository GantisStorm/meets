import SwiftUI

/// One browser control drawn as plain text: no fill, no border, the secondary
/// tone at rest and the primary tone under the pointer.
///
/// The row hover is the browser's only surface, so the range menu and the
/// folder line are drawn this way — the folder name, the count beside it, and
/// the chevron that says a menu opens here. Used as a `Button` label and as a
/// `Menu` label, so both read as the same kind of thing.
struct MeetingBrowserTextLabel: View {
    let title: String
    /// Trailing count in the tertiary tone: "Clients 24".
    var count: Int?
    /// The trailing chevron that marks a menu: "All time ▾".
    var showsMenuIndicator = false
    var font: Font = MeetsTheme.callout()
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: MeetsTheme.spacing4) {
            Text(title)
                .font(font)
                .lineLimit(1)

            if let count {
                Text("\(count)")
                    .font(font)
                    .monospacedDigit()
                    .foregroundStyle(MeetsTheme.textTertiary)
                    .lineLimit(1)
            }

            if showsMenuIndicator {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
        }
        .foregroundStyle(isHovering ? MeetsTheme.textPrimary : MeetsTheme.textSecondary)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

/// The browser's toolbar: one right-aligned row — the two meeting actions as
/// compact filled buttons, then the range, then the order.
///
/// One view, used by `MeetingsView` and by the render harness, so the toolbar
/// that ships is the toolbar that gets inspected. The row wraps at the
/// trailing edge as the detail column narrows, because the window's detail
/// column can be as tight as ~220 points once the sidebar is subtracted: the
/// actions keep the first line, the range and the order move to the second,
/// and at the tightest widths the action pair stacks rather than truncate.
struct MeetingBrowserHeader: View {
    @Binding var filter: MeetingBrowserFilter
    @Binding var sort: MeetingBrowserSort
    /// Ranges worth offering, derived from the oldest meeting in scope.
    let availableFilters: [MeetingBrowserFilter]
    /// True while a recording is being prepared or is running: both meeting
    /// actions hold back for the same window.
    let isStartDisabled: Bool
    let onQuickNote: () -> Void
    let onImportAudio: () -> Void
    @State private var isHoveringSort = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // One line: both actions, the range, and the order.
            HStack(spacing: MeetsTheme.spacing12) {
                actionButtons
                rangeMenu
                sortToggle
            }
            .fixedSize(horizontal: true, vertical: false)

            // Two lines: the actions keep a line of their own, the range and
            // the order move below them. Sized to its rows' real width so the
            // tightest widths fall through to the stacked pair below instead
            // of squeezing these two labels.
            VStack(alignment: .trailing, spacing: MeetsTheme.spacing8) {
                actionButtons
                HStack(spacing: MeetsTheme.spacing12) {
                    rangeMenu
                    sortToggle
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            // Three lines, the tightest the detail column gets: two named
            // buttons need about 228 points and 220 leaves 188, so the pair
            // stacks rather than truncating both labels.
            VStack(alignment: .trailing, spacing: MeetsTheme.spacing8) {
                quickNoteButton
                importAudioButton
                HStack(spacing: MeetsTheme.spacing12) {
                    rangeMenu
                    sortToggle
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Both meeting actions are named on the toolbar: a note and an import are
    /// the two ways a meeting enters the browser, and a menu would hide them
    /// behind one word. The buttons disable rather than disappear, so the
    /// actions stay discoverable while a recording is starting or running.
    private var actionButtons: some View {
        HStack(spacing: MeetsTheme.spacing12) {
            quickNoteButton
            importAudioButton
        }
    }

    private var quickNoteButton: some View {
        MeetingBrowserActionButton(
            title: "Quick Note",
            systemImage: "plus",
            isDisabled: isStartDisabled,
            help: "Start a quick note",
            action: onQuickNote
        )
    }

    private var importAudioButton: some View {
        MeetingBrowserActionButton(
            title: "Import Audio",
            systemImage: "square.and.arrow.down",
            isDisabled: isStartDisabled,
            help: "Import an audio file",
            action: onImportAudio
        )
    }

    /// The active range is always named, so "All time" is a visible state
    /// rather than an absence.
    private var rangeMenu: some View {
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
            MeetingBrowserTextLabel(title: filter.label, showsMenuIndicator: true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by date range, \(filter.label)")
        .accessibilityLabel("Filter by date range, \(filter.label)")
    }

    /// One click flips the order and the arrow is the state: pointing down is
    /// newest first, because that is where the newest meeting sits. The toolbar
    /// has no room to spell the order out beside two named actions, so the
    /// title lives in the tooltip and the accessibility value.
    private var sortToggle: some View {
        Button {
            sort = sort == .newestFirst ? .oldestFirst : .newestFirst
        } label: {
            Image(systemName: sort == .newestFirst ? "arrow.down" : "arrow.up")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHoveringSort ? MeetsTheme.textPrimary : MeetsTheme.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .onHover { isHoveringSort = $0 }
        }
        .buttonStyle(.plain)
        .help(sort.label)
        .accessibilityLabel("Sort order")
        .accessibilityValue(sort.label)
    }
}

/// One meeting action drawn as a compact filled button: the toolbar names both
/// actions side by side, so neither can be a menu, and the pair shares one
/// height, corner and hover so it reads as one row of the same kind of thing.
private struct MeetingBrowserActionButton: View {
    let title: String
    let systemImage: String
    let isDisabled: Bool
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(MeetsTheme.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(isHovering ? MeetsTheme.backgroundHover : MeetsTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
    }
}
