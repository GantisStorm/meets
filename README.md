<p align="center">
  <img src="assets/meets_app_icon.png" alt="Meets app logo" width="128" />
</p>

<h1 align="center">Meets</h1>
<p align="center"><strong>A vibeslopped, meetings-focused fork of <a href="https://github.com/Muesli-HQ/muesli">Muesli</a>.</strong><br>
I wanted fewer features. There is now a design system.</p>

## TL;DR

Records your Mac's microphone and system audio, transcribes locally, optionally generates notes. Apple Silicon, macOS 14.2+. **AI-assisted personal fork. Expect rough edges.** No published binary or official Homebrew cask yet: [build instructions](#build-it).

That's the useful part. Below is a README written by the same general class of machine responsible for the code. It has been asked to sound less like one. Enjoy the evidence.

## A brief incident report

[Muesli](https://github.com/Muesli-HQ/muesli) already existed and did useful things. I wanted the meeting parts. A reasonable person might have hidden a few buttons.

Instead, I pointed coding agents at it. We removed features, renamed everything, redesigned Settings, redesigned the redesign, and produced documentation about the padding. The repo now contains `DESIGN.md`, `PRODUCT.md`, and instructions for the agents writing the instructions. The original goal was simplicity.

**This is vibeslopped crap with a real app underneath it.** Upstream deserves credit for the substantial engineering. I take responsibility for what I asked the robots to do to it. Calling it slop does not exempt me from fixing bugs; it does spare us the paragraph where I call myself a visionary.

The app is native Swift, SwiftUI, and AppKit. Even the questionable decisions are native.

## Features

| Feature | Description |
| --- | --- |
| Meeting capture | Records mic + system audio, with echo cancellation, timestamps, and remote-speaker diarization. No bot joins the call. |
| Local transcription | Parakeet, Whisper, Qwen3 ASR, SenseVoice, Bodhan, Cohere Transcribe, and Nemotron options. Requirements and language coverage vary. |
| Live transcripts | Optional Apple Speech on macOS 26+ or Nemotron for live/final transcripts; Parakeet Realtime previews alongside a separate final model. Off by default. |
| Notes | Summaries, titles, optional cleanup, manual notes, templates, folders, audio import, and Markdown/PDF export. |
| Calendar | Reads calendars configured in macOS, shows upcoming meetings, and offers join/record actions. |
| Insights | Activity heatmaps, usage statistics, and share cards for the selected date range. |
| Automation | A bundled CLI, optional post-meeting executable hooks, and Shortcuts actions in Xcode-built apps. |

The app does not include a Dictionary screen; dictionary support remains available through the CLI. The recording indicator appears during preparation, recording, pause, and transcription, and is hidden while idle.

## Summary and cleanup providers

Speech recognition and text generation are configured separately. Speech-to-text runs locally; summaries and transcript cleanup use the selected text provider.

| Text provider | Processing location | Requirements |
| --- | --- | --- |
| **Apple Intelligence** | On-device, through Foundation Models | This adapter requires **macOS 27+**, an eligible Mac, Apple Intelligence enabled, and a ready system model. No API key. |
| **ChatGPT** | OpenAI's service | Sign-in and compatible account access. Provider limits apply. |
| **OpenAI / OpenRouter** | Your selected service/model | Your API key; provider pricing applies. |
| **Ollama / LM Studio** | Your configured server | Running server and loaded model. Local if the server is local. |
| **Custom LLM** | Your configured compatible endpoint | URL, model, and any required credentials. |
| **ACP agent** | Your agent and its model provider | Installed, configured ACP-compatible agent. |
| **Local cleanup models** | On-device | Downloaded weights. Cleanup only; separate from the summary picker. |

Apple Intelligence handles summaries, titles, and cleanup, with chunking for long transcripts. It does not call Siri or use Private Cloud Compute. The macOS 27 requirement belongs to this adapter; the base app still targets 14.2. Shortcuts/Siri actions are a separate integration.

Generated summaries and action items may contain errors. Verify important details against the transcript or recording.

## Privacy and data handling

Audio capture and speech-to-text run on your Mac. Meetings, notes, transcripts, and recordings live under `~/Library/Application Support/Meets/`; models use local caches. Dev builds have separate support directories.

Network use and data transfers depend on the configured features:

- **Cloud summaries and cleanup send text to the selected provider**, including any context you include. Optional screen/window context can become part of that request.
- **Ollama, LM Studio, custom endpoints, ACP agents, and hooks** process data through the configured endpoint or executable. Remote endpoints and external agents may transfer meeting text off-device.
- **iCloud support** syncs text and metadata, not audio. It needs a provisioned CloudKit build. This repo does not supply a hosted sync service or a companion iPhone release.
- **Model downloads and update checks** require network access.
- **Telemetry:** the app includes TelemetryDeck. Packaging scripts configure public routing IDs inherited from upstream; unconfigured direct builds disable telemetry. See [development telemetry](CONTRIBUTING.md#telemetry-in-development).

Grant microphone and system-audio/screen-recording permissions for capture, Calendar access for calendar features, and Accessibility/Input Monitoring where requested for context and global controls. Record people with their knowledge and appropriate consent.

## Build it

No binary release or official Homebrew cask is currently available. Build from source using the requirements below.

**Runtime:** Apple Silicon, macOS 14.2+. Some features need newer macOS.

**Build host:** full **Xcode 26.6 / Swift 6.3** on a compatible macOS 26 host. MLX requires Swift 6.3. Install `xcodegen` and CMake too. Command Line Tools alone are not the supported app-build setup.

```bash
git clone https://github.com/GantisStorm/meets.git
cd meets
brew install xcodegen cmake

./scripts/build_localvqe.sh
MEETS_SKIP_SIGN=1 MEETS_REQUIRE_LOCALVQE=1 ./scripts/dev-test.sh
```

This builds, locally signs, installs, and launches **`/Applications/MeetsDev.app`** with separate app data. `MEETS_SKIP_SIGN=1` skips the maintainer Developer ID requirement; the script still applies ad-hoc signing. Your production Meets install stays separate. Fixed dev lanes are available with `--lane A`, `B`, or `C`.

The LocalVQE model alone is insufficient: packaging needs `liblocalvqe` and its complete `libggml*` dependencies. Generated libraries remain gitignored. The default Xcode build extracts Shortcuts metadata; `MEETS_USE_XCODE_BUILD=0` falls back to SwiftPM without it. CloudKit/APNs need your own matching provisioning profiles; ordinary dev builds use local-only entitlements.

Build caches use `~/Library/Caches/meets-spm`. Give concurrent worktrees separate scratch paths. More in [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md).

Release signing, update feeds, model mirrors, and cloud services require maintainer configuration before a public binary release. Endpoint references in the release scripts do not indicate that those services are deployed.

## Validation

Repository and release-metadata checks:

```bash
./scripts/test_classify_changed_files.sh
./scripts/test_ci_test_shards.sh
./scripts/verify_update_flow.sh --skip-dmg
```

Full suite on the supported Mac/Xcode toolchain:

```bash
swift test --package-path native/MeetsNative \
  --scratch-path "$HOME/Library/Caches/meets-spm/test"
```

At source launch, the production build and packaged CLI checks passed. The full Swift suite was blocked on that host by a CLT/Swift Testing deployment mismatch: `Testing` required macOS 26 while the package targeted 14.2. The full suite has therefore not been verified on that host.

## CLI

The bundled `meets-cli` exposes meeting data, local file transcription, and a machine-readable command contract. Data commands use JSON; `transcribe` prints plain text by default.

```bash
# Use MeetsDev.app if you followed the build instructions above.
/Applications/Meets.app/Contents/MacOS/meets-cli spec
/Applications/Meets.app/Contents/MacOS/meets-cli meetings list
/Applications/Meets.app/Contents/MacOS/meets-cli transcribe recording.m4a
```

See the [CLI contract](skills/meets-agent/references/cli-contract.md) and [agent skill](skills/meets-agent/SKILL.md). The CLI runs locally. External agents receiving its output are subject to their own data-handling policies.

## Attribution and license

**[Muesli](https://github.com/Muesli-HQ/muesli), by Pranav Hari and contributors**, is the upstream project. Its history and MIT copyright notice are retained. This is an independent fork maintained by **[GantisStorm](https://github.com/GantisStorm)**, not an official Muesli release.

[MIT license](LICENSE) · [NOTICE](NOTICE) · [Contributing](CONTRIBUTING.md). Dependencies and downloaded models have their own licenses.

Report issues with reproduction steps, expected and actual behavior, app and macOS versions, and sanitized logs. Remove meeting content and credentials before sharing diagnostics.
