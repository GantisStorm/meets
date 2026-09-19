---
name: meets-dev-build-lanes
description: Use when working on Meets local dev builds, fixed dev lanes, parallel worktrees, SwiftPM scratch paths, app bundle IDs, app support directories, signing, entitlements, iCloud/APNs-capable builds, or local-only builds that should omit cloud entitlements.
---

# Meets Dev Build Lanes

## Overview

Use this skill to build and reason about local Meets dev apps across multiple worktrees without overwriting app bundles, sharing support data, or accidentally requiring iCloud/APNs entitlements.

## Core Workflow

1. Read `AGENTS.md` first for current scratch-path and lane policy.
2. Inspect `scripts/dev-test.sh`, `scripts/build_native_app.sh`, and `scripts/meets_spm_cache.sh` before changing build behavior.
3. Preserve default `./scripts/dev-test.sh` behavior unless explicitly changing the default dev app.
4. Prefer fixed lanes `A`, `B`, and `C`; do not create arbitrary branch-named bundle IDs unless the user explicitly accepts repeated macOS permission prompts.
5. Do not delete app support data or reset TCC permissions unless explicitly asked.

## Lane Mapping

Default dev app:

```text
App:        /Applications/MeetsDev.app
Bundle ID:  com.meets.dev
Support:    ~/Library/Application Support/MeetsDev
```

Fixed lanes:

```text
A -> MeetsDevA, com.meets.dev.a, process MeetsDevA, ~/Library/Application Support/MeetsDevA
B -> MeetsDevB, com.meets.dev.b, process MeetsDevB, ~/Library/Application Support/MeetsDevB
C -> MeetsDevC, com.meets.dev.c, process MeetsDevC, ~/Library/Application Support/MeetsDevC
```

## Entitlement Modes

Use local-only entitlements when testing non-sync features:

```bash
./scripts/dev-test.sh --lane A --local-only
```

Named lanes default to local-only entitlements. This uses `scripts/MeetsLocalOnly.entitlements` and clears provisioning/APNs env for the build.

Use cloud entitlements only when iCloud/APNs behavior is under test and the bundle ID has a matching Apple Developer profile:

```bash
MEETS_PROVISIONING_PROFILE="/path/to/profile.provisionprofile" \
MEETS_SIGN_IDENTITY="Apple Development: Name (TEAMID)" \
MEETS_CODESIGN_TIMESTAMP=none \
./scripts/dev-test.sh --lane A --cloud-entitlements
```

Plain `./scripts/dev-test.sh` keeps the existing cloud-entitlement-capable `MeetsDev` behavior.

## Build Cache Rules

Use the shared SwiftPM scratch path resolver. For direct SwiftPM commands, pass `--scratch-path` yourself. Never run concurrent worktrees into the same scratch path.

If `/Volumes/MeetsBuildCache/meets-spm` is mounted, prefer it. Otherwise scripts fall back to `~/Library/Caches/meets-spm`.
