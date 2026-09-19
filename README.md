<p align="center">
  <img src="assets/meets_app_icon.png" alt="Meets app logo" width="128" />
</p>

<h1 align="center">Meets</h1>
<p align="center"><strong>A vibeslopped, meetings-focused fork of <a href="https://github.com/Muesli-HQ/muesli">Muesli</a>.</strong><br>
Your meeting could have been an email. This fork could have been a settings change.</p>

## TL;DR — you do not need to read all this

- **What:** a Mac app that records meetings, transcribes them locally, and optionally asks an LLM what just happened.
- **Why:** I wanted Muesli with fewer non-meeting features. Naturally, this required a fork, a rebrand, and several rounds of arguing with robots about padding.
- **Quality:** lovingly vibeslopped crap. There is real engineering underneath, much of it from upstream. The AI-assisted renovations are mine to answer for.
- **Privacy:** speech-to-text is local. Cloud summaries send text to your chosen provider. Packaging scripts configure telemetry. The word “local” is not a force field.
- **Install:** Apple Silicon Mac. [Build it yourself](#build-it). No published DMG or official Homebrew cask yet. Apparently distribution is also a feature you have to implement.

That's the pitch. The rest is documentation, which the slop has unfortunately made necessary.

## How we got here

**Meets is a vibeslopped, meetings-focused fork of [Muesli](https://github.com/Muesli-HQ/muesli).** I took a useful open-source app, pointed coding agents at it, removed things I didn't want, and kept asking them to make the settings less annoying. Then I gave it a logo, because that is how software becomes official in my head.

It is a native Swift, SwiftUI, and AppKit app. It captures your mic and system audio without sending a bot into the call. It can turn “let's circle back” into a searchable record of nobody circling back.

The fork concentrates on meeting history, calendar context, notes, models, and Insights. Changes include a neutral visual identity, reorganized Settings, activity heatmaps and share cards, and an Apple Intelligence backend. The Dictionary screen is gone. The recording indicator only appears during active meeting work. The CLI still has its own dictionary option, because removing a feature from a UI and eliminating every trace of its existence are different hobbies.

This is a personal fork with public source, not a startup with a trust center and a customer-success department. The release department is also me. It has not released a binary.

## What the crap actually does

- **Capture both sides.** Record your microphone and system audio from meeting apps, with echo cancellation, timestamped transcripts, and remote-speaker diarization.
- **Transcribe on your Mac.** Choose from local engines including Parakeet, Whisper, Qwen3 ASR, SenseVoice, Bodhan, Cohere Transcribe, and Nemotron. Model, language, memory, and OS requirements vary.
- **Follow along live.** Optional Apple Speech on macOS 26+ and Nemotron streaming can produce live and final transcripts. Parakeet Realtime provides previews alongside a separately selected final transcription model. Live transcription is off by default.
- **Remember what happened.** Generate summaries, titles, and transcript cleanup; keep manual notes; organize meetings into folders; export Markdown or PDF; import existing audio files.
- **Use calendar context.** Connect to calendars already configured in macOS, see upcoming meetings, and join or record from meeting notifications.
- **Quantify the damage.** Insights includes a meeting activity heatmap, workflow/model statistics, and share cards that respect the selected date range. Finally, a contribution graph for time you will never get back.
- **Automate it.** A bundled CLI, optional post-meeting executable hooks, and App Intents for starting/stopping recordings and retrieving the last meeting’s notes.

## Pick your AI

An unreasonable number of ways to generate “Key Takeaways.”

Speech recognition and text generation are separate choices. A cloud summary provider does not turn the local speech recognizer into cloud transcription.

| Summary / cleanup provider | Where processing happens | What you need |
| --- | --- | --- |
| **Apple Intelligence** | On-device through Apple’s Foundation Models framework | This implementation requires **macOS 27+**, an eligible Mac, Apple Intelligence enabled, and the system model ready. No API key. |
| **ChatGPT** | OpenAI’s service | Sign-in and compatible account access; provider limits apply. |
| **OpenAI / OpenRouter** | The selected service/model | Your own API key; provider pricing and policies apply. |
| **Ollama / LM Studio** | Your configured server, often on your Mac | A running server and a loaded model. A remote endpoint sends text off-device. |
| **Custom LLM** | Your configured compatible endpoint | Its URL, model, and any required credentials. |
| **ACP agent** | Your configured agent and its model provider | An installed, configured ACP-compatible agent. |
| **Local cleanup models** | On-device | Downloaded cleanup weights; this path is for cleanup, not the summary-provider picker. |

Apple Intelligence handles summaries, titles, and cleanup, with chunking for long transcripts. It does **not** call Siri or use Private Cloud Compute. The current macOS 27 gate is a property of this adapter, not a claim that the rest of Meets needs macOS 27. Shortcuts/Siri actions are a separate integration.

Models can mishear words, merge speakers, and confidently invent action items. Check important notes against the transcript. The model was not in the meeting either, but unlike you it has no reservations about pretending it understood everything.

## Privacy, without the asterisk doing all the work

“Private by design” fits on a landing page. Where the data actually goes takes a few more paragraphs.

Meeting audio capture and speech-to-text run locally. Meetings, transcripts, notes, and recordings are stored under `~/Library/Application Support/Meets/`; model downloads use local caches. An isolated dev build uses its own support directory.

What can leave the Mac depends on what you enable:

- **Hosted summaries/cleanup:** meeting text and included context go to the selected provider. Local transcription does not make those requests local.
- **ACP agents, custom endpoints, and post-meeting hooks:** data goes wherever you configure those tools to send it.
- **Optional visual context:** captured screen/window text can become part of the context sent for a summary.
- **iCloud:** the code supports syncing text and metadata, not audio. It requires a correctly provisioned CloudKit build; this source launch does not provide a hosted sync service or companion iPhone release.
- **Networking:** models and dependencies must be downloaded. Configured update checks and remote providers also use the network.
- **Telemetry:** the source includes TelemetryDeck, and packaging scripts configure public telemetry routing IDs inherited from upstream. Unconfigured direct builds disable it. This is not a “zero telemetry” claim; see [the contributor telemetry notes](CONTRIBUTING.md#telemetry-in-development).

Grant microphone and system-audio/screen-recording permissions for capture, Calendar access for calendar features, and Accessibility/Input Monitoring where requested for context and global controls. Record people with their knowledge and appropriate consent.

## Build it

You are now the release engineer. Congratulations on the unpaid promotion.

**Runtime:** Apple Silicon Mac, macOS 14.2 or later. Individual features require newer macOS versions.

**Build host:** full **Xcode 26.6 / Swift 6.3** on a compatible macOS 26 host, plus `xcodegen` and CMake. MLX requires Swift 6.3. Command Line Tools alone are not the supported app-build setup.

```bash
git clone https://github.com/GantisStorm/meets.git
cd meets

brew install xcodegen cmake

# Build the required native echo-cancellation libraries.
./scripts/build_localvqe.sh

# Build, locally sign, install, and launch an isolated MeetsDev app.
MEETS_SKIP_SIGN=1 MEETS_REQUIRE_LOCALVQE=1 ./scripts/dev-test.sh
```

`MEETS_SKIP_SIGN=1` skips the maintainer’s Developer ID requirement; the script applies local ad-hoc signing. This installs `/Applications/MeetsDev.app`, leaving `/Applications/Meets.app` and its data alone. Fixed lanes `--lane A`, `B`, or `C` allow separate dev installs.

The default Xcode app build extracts App Intents metadata for Shortcuts. The `MEETS_USE_XCODE_BUILD=0` SwiftPM fallback omits that metadata. CloudKit/APNs builds need your own matching provisioning profiles; ordinary contributor builds use local-only entitlements.

The committed LocalVQE model is only one part of the runtime. Packaging also needs `liblocalvqe` and the complete referenced `libggml*` library set. Generated libraries stay gitignored. SwiftPM caches live under `~/Library/Caches/meets-spm`; use separate scratch paths for concurrent worktrees.

See [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md) for build lanes, signing, caches, and validation. Release signing, Sparkle feeds, model mirrors, and cloud services need maintainer setup before a public binary release; URLs in the release tooling are not evidence that those services are deployed.

### Checks

```bash
./scripts/test_classify_changed_files.sh
./scripts/test_ci_test_shards.sh
./scripts/verify_update_flow.sh --skip-dmg

# Full suite on the supported Mac/Xcode toolchain:
swift test --package-path native/MeetsNative \
  --scratch-path "$HOME/Library/Caches/meets-spm/test"
```

The source-launch host passed the production build and packaged CLI checks before publication work. Its full Swift tests remain blocked by a Command Line Tools / Swift Testing deployment mismatch (`Testing` requires macOS 26 while this package targets 14.2). The suite did not pass on that host. We have not yet advanced to the stage of vibe-testing where you just say it did.

## There’s a CLI, because of course there is

So your coding agent can read notes produced by another model about a meeting nobody wanted. The machines have achieved middle management.

The app bundles `meets-cli`. It exposes a machine-readable command contract, meeting data, and local file transcription. JSON output makes it useful to scripts and agents; `transcribe` prints plain text by default.

```bash
# Production install; use MeetsDev.app after the dev build above.
/Applications/Meets.app/Contents/MacOS/meets-cli spec
/Applications/Meets.app/Contents/MacOS/meets-cli meetings list
/Applications/Meets.app/Contents/MacOS/meets-cli transcribe recording.m4a
```

Read the [CLI contract](skills/meets-agent/references/cli-contract.md) and [agent skill](skills/meets-agent/SKILL.md) before writing automations. The CLI is local, but an agent you give its output to may not be.

## Fork lineage and license

Meets is maintained here by **[GantisStorm](https://github.com/GantisStorm)**. It is an independent fork of **[Muesli](https://github.com/Muesli-HQ/muesli)** by **Pranav Hari and contributors**. They did the substantial original engineering that makes this possible. I brought the meeting obsession, the coding agents, and strong opinions about shades of gray. Credit the foundation to them; address complaints about my renovations to this repo.

This repository retains its upstream git history and MIT copyright notice. It is not an official Muesli release. [MIT license](LICENSE); [NOTICE](NOTICE) covers attribution and vendored code. Dependencies and downloaded models have their own licenses.

Contributions are welcome. Reproducible bug reports are especially welcome. “It feels haunted” is accepted if accompanied by logs with private meeting content and credentials removed. If you fix something by understanding it before editing it, please be patient with our existing culture.
