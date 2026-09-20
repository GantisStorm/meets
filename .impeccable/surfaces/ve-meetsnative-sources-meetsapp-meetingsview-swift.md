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

Chosen direction: A clean library of spacious, cohesive meeting-family cards. The page keeps one heading — the scope name — with a single count line under it; the count reports current state only (range, and how many earlier meetings are on screen for thread context) and never explains the product. One compact toolbar carries meeting actions and the sort, range, and grid/list controls, wrapping in that order as the column narrows.

Each follow-up family is one bordered card: the parent's title at 18pt semibold with a compact "Today · 3:04 PM · 46m" line, up to two preview lines, and the family's follow-ups inside the same enclosure below a divider — never detached miniature cards. One ellipsis menu per row carries follow-up, folder move (including New Folder…), and delete, with disabled items rather than hidden ones. Descendants indent modestly up to three levels inside the enclosure; below that they name the parent they hang from. A shelf that holds more descendants than the collapsed limit always keeps its footer, so "Show fewer follow-ups" survives expansion. Folders in the current level render as one quiet row of compact name/count tiles under the breadcrumb, and the list layout compacts the same family card into a library row instead of stretching the grid card.

Memorable interaction: Hovering the footer control previews the entire thread in a scrollable popover; clicking or activating it expands or collapses the thread in place, in thread order.

Review evidence: An offscreen NSHostingView harness at `/private/tmp/meets-shelves-harness` renders the real production views — including the extracted `MeetingBrowserHeader`, so the toolbar that ships is the toolbar that is inspected — inside fixed window viewports (1100×800, 280×800, 220×800) scrolled like the product, with synthetic fixtures for a four-deep family, a four-depth branching thread containing a non-completed out-of-range descendant, two standalone meetings, and a folder level, in light and dark. Revised from the first pass after review: the family card replaced detached rows, the three per-row icon clusters collapsed into one menu, the collapsed footer's disappearance on expand was fixed, and thread titles were given the whole first line after the narrow renders showed badges crowding them.
