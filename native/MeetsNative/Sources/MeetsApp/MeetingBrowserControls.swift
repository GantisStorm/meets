import SwiftUI

/// One browser control drawn as plain text: no fill, no border, the secondary
/// tone at rest and the primary tone under the pointer.
///
/// The row hover is the browser's only surface, so every control in the
/// toolbar and in the folder line is drawn this way — the label, the count
/// beside it, and the chevron that says a menu opens here. Used as a `Button`
/// label and as a `Menu` label, so both read as the same kind of thing.
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

/// The browser's toolbar: one right-aligned row of text controls — what can be
/// created, which range is in view, and which way the list runs.
///
/// One view, used by `MeetingsView` and by the render harness, so the toolbar
/// that ships is the toolbar that gets inspected. The row stacks at the
/// trailing edge as the detail column narrows, because the window's detail
/// column can be as tight as ~220 points once the sidebar is subtracted.
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

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MeetsTheme.spacing16) {
                newMenu
                rangeMenu
                sortToggle
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .trailing, spacing: MeetsTheme.spacing8) {
                newMenu
                rangeMenu
                sortToggle
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Both meeting actions sit behind one "New" menu: a text toolbar has no
    /// room for two filled buttons, and neither action is the page's default.
    /// The items disable rather than disappear, so the actions stay
    /// discoverable while a recording is starting or running.
    private var newMenu: some View {
        Menu {
            Button("Quick Note", action: onQuickNote)
                .disabled(isStartDisabled)
            Button("Import Audio", action: onImportAudio)
                .disabled(isStartDisabled)
        } label: {
            MeetingBrowserTextLabel(title: "New", showsMenuIndicator: true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Start a quick note or import an audio file")
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

    /// One click flips the order, and the label is the state: a toggle says
    /// which way the list runs without a menu to open.
    private var sortToggle: some View {
        Button {
            sort = sort == .newestFirst ? .oldestFirst : .newestFirst
        } label: {
            MeetingBrowserTextLabel(title: sort.label)
        }
        .buttonStyle(.plain)
        .help("Sort meetings, \(sort.label)")
        .accessibilityLabel("Sort meetings, \(sort.label)")
    }
}
