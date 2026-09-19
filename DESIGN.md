---
name: Meets
description: A calm native Mac workspace for capturing and understanding meetings.
colors:
  deep-dark: "#0A0A0A"
  deep-light: "#F6F6F6"
  base-dark: "#121212"
  base-light: "#FFFFFF"
  raised-dark: "#181818"
  raised-light: "#F0F0F0"
  surface-dark: "#242424"
  surface-light: "#E5E5E5"
  text-dark: "rgba(255,255,255,0.94)"
  text-light: "rgba(0,0,0,0.90)"
  recording: "#E5484D"
  transcribing: "#E8A020"
  success: "#30A46C"
typography:
  display:
    fontFamily: "SF Pro, -apple-system, sans-serif"
    fontSize: "26px"
    fontWeight: 700
  title:
    fontFamily: "SF Pro, -apple-system, sans-serif"
    fontSize: "20px"
    fontWeight: 600
  headline:
    fontFamily: "SF Pro, -apple-system, sans-serif"
    fontSize: "15px"
    fontWeight: 600
  body:
    fontFamily: "SF Pro, -apple-system, sans-serif"
    fontSize: "14px"
    fontWeight: 400
  label:
    fontFamily: "SF Pro, -apple-system, sans-serif"
    fontSize: "12px"
    fontWeight: 500
rounded:
  sm: "6px"
  md: "10px"
  lg: "14px"
  xl: "20px"
spacing:
  xs: "4px"
  sm: "8px"
  compact: "12px"
  md: "16px"
  roomy: "20px"
  lg: "24px"
  xl: "32px"
components:
  settings-card:
    rounded: "{rounded.lg}"
    padding: "12px 20px"
  compact-button:
    rounded: "{rounded.sm}"
    height: "26px"
---

# Design System: Meets

## Overview

**Creative North Star: “The Quiet Native Utility”**

Meets should feel like a focused part of macOS rather than a themed layer placed over it. The interface is calm, direct, and information-dense where the task requires it, with visual emphasis reserved for active selection, recording state, progress, and recovery.

**Key Characteristics:**

- Native system typography and controls
- Neutral tonal surfaces in both appearances
- Clear state over decorative color
- Progressive disclosure for expert configuration
- Compact controls with generous separation between task groups

## Colors

The palette is adaptive and neutral. Dark appearance uses near-black layers; light appearance uses white and cool neutral gray layers. Accent color is sparse and may reflect the configured recording color.

### Primary

- **Adaptive Accent**: Current selection, switch tint, and primary inline actions only.

### Neutral

- **Deep Background** (`#0A0A0A` dark / `#F6F6F6` light): Window chrome and deepest canvas.
- **Base Background** (`#121212` dark / `#FFFFFF` light): Primary page canvas.
- **Raised Background** (`#181818` dark / `#F0F0F0` light): Grouped settings and content surfaces.
- **Primary Surface** (`#242424` dark / `#E5E5E5` light): Compact controls and secondary interactive fills.

### Semantic

- **Recording Red** (`#E5484D`): Recording and destructive state.
- **Transcribing Amber** (`#E8A020`): In-progress or limited state.
- **Success Green** (`#30A46C`): Granted, connected, and successful state.

**The State Color Rule.** Saturated color communicates state or selection; it is not background decoration.

**The Active Indicator Rule.** The recording indicator appears only while a meeting is preparing, recording, paused, or transcribing. It is a safety control and live status surface, never a persistent idle launcher.

## Typography

**Display Font:** SF Pro via the native system stack
**Body Font:** SF Pro via the native system stack

**Character:** Compact, familiar, and highly legible. Hierarchy comes from size, weight, and spacing rather than decorative faces or forced capitalization.

### Hierarchy

- **Page title** (bold, 26px): One per dashboard surface.
- **Pane title** (semibold, 20px): Names the current settings area.
- **Section heading** (semibold, 15px): Names a task group inside a raised surface.
- **Body** (regular, 14px): Setting labels and primary explanatory copy.
- **Callout** (regular, 13px): Pane descriptions.
- **Caption** (regular or medium, 12px): Status, help, and secondary explanation.

**The Sentence-Case Rule.** Navigation and section labels use sentence case; uppercase eyebrow labels are not part of the settings vocabulary.

## Layout

Dashboard pages use a 4-point spacing grid. Settings content is centered at a maximum width of 920px with 32px horizontal gutters, 24px top inset, and 20px between major groups. Row controls align to a consistent trailing column; described rows switch to a vertical label/control layout when horizontal space is insufficient.

The settings header pairs the page title with right-aligned text navigation. Each pane begins with a title and one-sentence purpose. Everyday controls remain visible; lower-frequency groups use summary-bearing disclosures that report their current state while closed.

## Elevation & Depth

Depth is tonal. Raised surfaces separate groups from the base canvas without drop shadows; thin dividers separate related rows within a surface. Avoid pairing borders and shadows on the same resting container.

## Shapes

Corners follow the shared 6 / 10 / 14 / 20px scale. Settings groups use 14px rounded rectangles, compact controls use 6px, and larger presentation surfaces may use 20px. Pills are reserved for genuinely compact status or control shapes.

## Components

### Buttons

- **Primary inline action:** Native or plain button styling with accent text; use a subtle accent fill only when the action needs additional affordance.
- **Compact action:** 26px high, 6px radius, medium 12px label, neutral surface fill.
- **Destructive action:** Recording red text and a low-opacity red surface.
- **Disabled:** Preserve layout and reduce native emphasis; do not replace the control with explanatory decoration.

### Cards / Containers

- **Corner Style:** 14px.
- **Background:** Adaptive raised background.
- **Depth:** Tonal separation, no resting shadow.
- **Internal Padding:** 20px horizontal and 16px vertical for section content. Setting rows add 12px vertical breathing room, with a 4px sibling rhythm around dividers and supporting copy.

### Inputs / Fields

Use native switches, popup buttons, secure fields, and text fields. Inputs align in a stable trailing column. Long descriptions wrap fully; controls move beneath the label when width is constrained rather than overlapping or truncating the explanation.

### Navigation

Top-level settings panes use right-aligned plain text. The active pane gains semibold primary text and a 2px accent underline; inactive panes use tertiary text. Disclosure rows use a rotating native chevron, a short live summary, and a 160–180ms ease-out transition.

### Permission Status

Permission rows pair a small semantic status dot with a direct Granted, Grant, or Checking action and an explicit path to System Settings.

## Do's and Don'ts

### Do:

- **Do** reveal dependent controls only when their parent feature is enabled.
- **Do** summarize hidden settings with real current values.
- **Do** let explanatory text grow vertically and keep controls aligned.
- **Do** reserve semantic colors for meaningful status.

### Don't:

- **Don't** present every provider, export, and automation option at the same visual priority.
- **Don't** use negative spacing to pull captions into neighboring rows.
- **Don't** stretch settings content across the full window width.
- **Don't** add decorative gradients, glass, or shadows to native task surfaces.
