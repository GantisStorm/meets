---
version: 1
slug: "ve-meetsnative-sources-meetsapp-meetingsview-swift"
primary_target: "native/MeetsNative/Sources/MeetsApp/MeetingsView.swift"
related_targets: ["native/MeetsNative/Sources/MeetsApp/MeetingShelfView.swift", "native/MeetsNative/Sources/MeetsApp/MeetingListItemView.swift", "native/MeetsNative/Sources/MeetsApp/MeetingBrowserControls.swift"]
---

Scope: The Meetings browser in the native macOS dashboard — "All Meetings" and every folder scope, including the follow-up shelves, the folder navigation above them, and the browser header controls.

Mode: Operate.

Audience and job: People reviewing a growing archive of recorded meetings need to find a meeting, recognize which meetings belong to the same follow-up thread, and open the right one — without the archive turning into an undifferentiated list.

Primary task: Scan the shelves for the thread that matters, open a meeting, and move, delete, or start a follow-up from the exact meeting the user is looking at.

Constraints: Preserve opening, move/create-folder, delete confirmation, follow-up creation, and status/folder context. Keep Calendar/Coming Up and active-recording behavior untouched. Native SwiftUI controls, macOS 14.2, light and dark appearances, and a detail column that can narrow to about 220 points once the sidebar is subtracted. No transcript loading for the whole library and no per-row database reads.

Chosen direction: One parent card per follow-up family, then compact nested child rows carrying their own depth. The shelf has no chrome of its own, so a card is never nested inside another card. Indentation carries the hierarchy up to three levels; below that every descendant still renders and instead names the parent it hangs from. Collapsed shelves show three descendants and an overflow control that reports how many follow-ups stay hidden — and how many of those are inside the active date range, so a filtered thread cannot silently bury its only match. A persisted segmented switch chooses the card grid (default) or the full-width list; the grid drops to a single flexible column once a multi-column layout could not hold a 320-point card. Folder cards navigate the folder tree with recursive counts, and a scoped child whose predecessor lives outside the folder appears as a scoped root that links back to that parent.

Memorable interaction: Hovering the overflow control previews the entire thread in a scrollable popover; clicking or activating it expands the thread in place, in thread order.

Review evidence: An offscreen NSHostingView harness (`/tmp/meets-shelves-harness`) rendered the real shelf, card, folder-card, and header controls at 1180 / 560 / 280 / 220 points in light and dark with synthetic fixtures (deep chain, six siblings with grandchildren, out-of-scope parent, long filtered chain). Two rounds of that inspection drove the current design: cards lost their relationship icon pair so the title keeps the row to itself and the follow-up count moved into the metadata line, and tertiary text on the new surfaces (previews, context labels, overflow dates, folder counts) moved to secondary for legibility on light backgrounds.
