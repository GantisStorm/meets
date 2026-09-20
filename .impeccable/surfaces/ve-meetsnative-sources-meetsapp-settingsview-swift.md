---
version: 1
slug: "ve-meetsnative-sources-meetsapp-settingsview-swift"
primary_target: "native/MeetsNative/Sources/MeetsApp/SettingsView.swift"
related_targets: ["native/MeetsNative/Sources/MeetsApp/ACPAgentDiscovery.swift"]
---

Scope: General, Permissions, Recording, Calendar, Notes, AI, Advanced, and Appearance panes in the native macOS Settings surface.
Mode: Operate.

Audience and job: People configuring Meets for everyday meeting capture need the common choices to be immediately understandable while retaining access to provider, export, sync, and automation depth.

Primary task: Select a pane, understand what it controls, adjust essential settings, and expand a clearly summarized group only when deeper configuration is needed.

Constraints: Preserve every existing setting and behavior; use native SwiftUI controls; support macOS 14.2; maintain light and dark appearances; allow long provider and status copy to wrap without overlap.

Chosen direction: Essentials + Advanced. Keep a right-aligned plain-text pane switcher, a concise pane introduction, a readable 920-point content measure, visible startup/permissions/capture/recording/appearance essentials, and state-bearing disclosure rows for lower-frequency settings. Provider connections live on their own AI pane — one row per service with the control that connects it — so the Recording pane holds only what capture and transcription need; the two defaults that route AI work sit under the AI pane's Defaults section and offer only connected services, keeping a disconnected choice listed and marked rather than silently reassigning it.

Memorable interaction: Closed disclosure rows remain informative by reporting live values such as the selected summary provider, cleanup state, calendar access, notification state, sync state, or indicator position before the user opens them.

Review evidence: A user-provided screenshot showed that expanded cards had adequate outer spacing but insufficient inner rhythm. Shared section content now uses 16-point edge padding, 12-point row breathing room, 4-point sibling gaps around dividers and supporting copy, and 8 points between stacked provider fields.
