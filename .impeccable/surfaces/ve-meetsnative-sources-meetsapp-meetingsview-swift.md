---
version: 1
slug: "ve-meetsnative-sources-meetsapp-meetingsview-swift"
primary_target: "native/MeetsNative/Sources/MeetsApp/MeetingsView.swift"
related_targets: ["native/MeetsNative/Sources/MeetsApp/MeetingShelfView.swift", "native/MeetsNative/Sources/MeetsApp/MeetingListItemView.swift", "native/MeetsNative/Sources/MeetsApp/MeetingBrowserControls.swift"]
---

Scope: The Meetings browser in the native macOS dashboard — "All Meetings" and every folder scope, including the follow-up shelves, the folder level above them, and the browser header with its meeting actions and display controls.

Mode: Operate.

Audience and job: People reviewing a growing archive of recorded meetings need to find a meeting, recognize which meetings belong to the same follow-up thread, and open the right one — without the archive turning into an undifferentiated list.

Primary task: Scan the shelves for the thread that matters, open a meeting, and move, delete, or start a follow-up from the exact meeting the user is looking at.

Constraints: Preserve opening, move/create-folder, delete confirmation, follow-up creation, and status/folder context. Keep Calendar/Coming Up and active-recording behavior untouched. Native SwiftUI controls, macOS 14.2, light and dark appearances, and a detail column that can narrow to about 220 points once the sidebar is subtracted. No transcript loading for the whole library and no per-row database reads, and no per-row date-formatter allocation.

Chosen direction: One list, full width. The page keeps one heading — the scope name — with a single count line under it; the count reports current state only (range, and how many earlier meetings are on screen for thread context) and never explains the product. One compact toolbar carries meeting actions and the sort and range controls, wrapping in that order as the column narrows; there is no grid/list switch, because every shelf is a full-width list card inside the page's 960-point measure.

Each follow-up family is one bordered card: the root meeting's title at 18pt semibold with a compact "Today · 3:04 PM · 46m" line, up to two preview lines, and one ellipsis menu carrying follow-up, folder move (including New Folder…), and delete, with disabled items rather than hidden ones. When the card has descendants, its last element is a full-width disclosure row below a hairline divider: a chevron that turns 90° on expand, "Expand follow-ups" or "Collapse follow-ups", and a capsule holding the descendant count. Expanding unfolds an inset panel on the base background — every descendant in thread order, separated by hairlines, indented modestly up to three levels, and below that naming the parent they hang from. Collapsed means nothing is shown, so a date range that hides matches says so on the disclosure itself: "Expand follow-ups · N in range". A shelf kept on screen only because a matching follow-up needed its ancestors opens expanded by default, and the user can collapse it. Folders in the current level render as one quiet row of compact name/count tiles under the breadcrumb.

Memorable interaction: The disclosure is the thread. One full-width row opens and closes the whole family in place, in thread order, and a thread that only exists because a filter matched deep inside it opens itself, so the range never hides the meeting the user searched for.

Review evidence: An offscreen NSHostingView harness at `/private/tmp/meets-shelves-harness` renders the real production views — including the extracted `MeetingBrowserHeader`, so the toolbar that ships is the toolbar that is inspected — inside fixed window viewports (1100×800, 280×800, 220×800) scrolled like the product, with synthetic fixtures for a four-deep family, a seven-member branching thread containing a non-completed out-of-range descendant, two standalone meetings, and a folder level, in light and dark. Scenarios: `browser` and `branching` (one shelf expanded) at 1100, `filtered` under a one-week range, and `narrow-220`/`narrow-280` each with and without that range. The renders confirmed the disclosure row reads complete at 220 points, that an expanded card's panel stays inside its own border with no row spilling past it, and that a card without follow-ups shows neither a divider nor an empty row. Revised from the grid pass: the card grid, the persisted grid/list choice, the layout picker, and the hover-preview overflow control are gone, replaced by the disclosure row and the inset follow-up panel — and the disclosure label wraps to a second line at narrow widths, after the first pass showed the in-range note ellipsised away.
