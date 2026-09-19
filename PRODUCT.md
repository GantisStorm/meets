# Product

<!-- impeccable:product-schema 1 -->

## Platform

macOS

## Users

People who spend substantial time in online meetings and want a private, dependable record of what was said, decided, and assigned without maintaining a separate meeting workflow.

## Product Purpose

Meets captures meetings, produces searchable transcripts and notes, connects them to calendar context, and makes the results useful after the call. Success means a meeting can move from capture to a trustworthy, organized record with minimal setup or cleanup.

## Positioning

Meets is a native Mac meeting workspace that can keep capture, transcription, cleanup, and summarization on-device while still allowing users to choose cloud or agent-backed providers when they want them.

## Operating Context

Meets runs alongside browser and native meeting apps, uses the Mac's microphones, system audio, accessibility, screen-recording, and calendar permissions, and exposes meeting controls through the dashboard, menu bar, active recording indicator, notifications, shortcuts, and CLI.

## Capabilities and Constraints

- Native SwiftUI application targeting macOS 14.2 and later.
- Records microphone and system audio, creates live or post-meeting transcripts, generates summaries, supports meeting templates, and can export or sync meeting records.
- Supports multiple transcription, cleanup, and summary providers, including local and Apple Intelligence options where the operating system and hardware allow them.
- Settings must preserve every existing behavior while making everyday choices easier to scan and advanced provider, export, automation, and diagnostic controls progressively discoverable.
- Permission and provider availability states must remain explicit rather than being hidden behind failed actions.

## Brand Commitments

The product name is Meets. The interface is a focused native Mac utility: direct, private, calm, and task-oriented. Existing product terminology such as Meetings, Transcription, Meeting Summaries, Transcript Cleanup, and Recording Indicator remains authoritative.

## Evidence on Hand

The working SwiftUI application, its configured providers, calendar and recording workflows, native assets, test suite, and README are the product evidence. No testimonials, customer logos, or external performance claims are available and none should be fabricated.

## Product Principles

- Keep the common meeting workflow obvious; reveal expert control only when requested or relevant.
- Make privacy, availability, and data location understandable at the decision point.
- Preserve user choice across local, Apple, cloud, and agent-backed workflows.
- Prefer native Mac conventions and predictable controls over decorative interface novelty.
- Never trade away a captured meeting or transcript because an optional downstream AI step fails.

## Accessibility & Inclusion

Use native keyboard navigation, system focus behavior, readable contrast in light and dark appearances, descriptive labels, and layouts that tolerate longer status and provider text without overlap or clipping.
