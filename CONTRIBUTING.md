# Contributing to Meets

Thanks for helping improve Meets. This project is a native macOS app built
with SwiftPM, AppKit, SwiftUI, and a small set of shell scripts around local
builds and CI shards.

## Requirements

- macOS 26 build host (the app deployment target remains macOS 14.2)
- Xcode 26.6 (Swift 6.3), matching CI; MLX Swift requires Swift 6.3
- Apple Silicon Mac for the main app workflows
- `xcodegen` and CMake (`brew install xcodegen cmake`)

## Local Development Build

Maintainer release builds are signed with a Developer ID certificate that
external contributors do not have. For local development, build the isolated
dev app with local ad-hoc signing:

```bash
MEETS_SKIP_SIGN=1 ./scripts/dev-test.sh
```

### Meeting echo cancellation (LocalVQE)

Meeting AEC defaults to LocalVQE. The GGUF model is committed under
`native/MeetsNative/LocalVQE/models/`, but the shared libraries under
`native/MeetsNative/LocalVQE/lib/` are gitignored. Build them once before
packaging. Keep the complete runtime in every normal dev or release bundle:

```bash
./scripts/build_localvqe.sh
MEETS_SKIP_SIGN=1 ./scripts/dev-test.sh
```

`scripts/build_native_app.sh` refuses signed packaging without a *complete*
LocalVQE runtime (`liblocalvqe` plus its `libggml*` companions, especially
`libggml-base`, including transitive `otool` deps). That includes maintainer
`./scripts/dev-test.sh` runs that do not set `MEETS_SKIP_SIGN=1` — the gate
is keyed on signing, not debug/release. Unsigned packaging
(`MEETS_SKIP_SIGN=1`) prints a loud warning and continues; override with
`MEETS_REQUIRE_LOCALVQE=1` (fail) or
`MEETS_ALLOW_MISSING_LOCALVQE=1` (unsigned only). To build the runtime
inline during packaging, set `MEETS_BUILD_LOCALVQE=1`.

To force a specific runtime AEC processor while testing:

```bash
MEETS_AEC_PROCESSOR=dtln MEETS_SKIP_SIGN=1 ./scripts/dev-test.sh
MEETS_AEC_PROCESSOR=localvqe-strict MEETS_SKIP_SIGN=1 ./scripts/dev-test.sh
```

`localvqe-strict` does not fall back to DTLN when LocalVQE fails to load.

That installs `/Applications/MeetsDev.app` with bundle ID `com.meets.dev`
and stores data under `~/Library/Application Support/MeetsDev/`, so it does
not touch your production Meets install or data.

By default, `scripts/dev-test.sh` uses local-only entitlements. Maintainer
machines keep CloudKit profiles outside this repository under a sibling
`meets-ios/secrets/` directory, but those profiles are used only when
`--cloud-entitlements` is passed. External contributors should not need Apple
Developer account access for ordinary local development.

Useful dev commands:

```bash
MEETS_SKIP_SIGN=1 ./scripts/dev-test.sh                # Build and launch MeetsDev
MEETS_SKIP_SIGN=1 ./scripts/dev-test.sh --reset        # Re-run onboarding, keep data
MEETS_SKIP_SIGN=1 ./scripts/dev-test.sh --local-only   # Force local-only entitlements
./scripts/dev-reset-permissions.sh                      # Reset macOS privacy permissions for MeetsDev
```

If you do have your own signing certificate, you can override the identity:

```bash
MEETS_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/dev-test.sh
```

Cloud-entitled local builds require a provisioning profile whose App ID matches
the selected bundle ID and whose certificate matches the signing identity:

```bash
MEETS_PROVISIONING_PROFILE="/path/to/profile.provisionprofile" \
MEETS_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
MEETS_CODESIGN_TIMESTAMP=none \
  ./scripts/dev-test.sh --cloud-entitlements
```

If `--cloud-entitlements` is passed explicitly and no matching profile is
available, the script fails before building. That is expected; use
`--local-only` for contributor builds that do not exercise iCloud sync.
Maintainers switching an existing dev app from Developer ID/local-only signing
to Apple Development/CloudKit signing may need to regrant macOS privacy
permissions once because macOS tracks permissions against the app's signing
requirement.

## Telemetry in Development

Use `scripts/dev-test.sh` for local app testing. It routes anonymous telemetry
to the dedicated `MeetsDev` TelemetryDeck app and labels every signal with
`meets.channel=dev`; named lanes A, B, and C use the same dev destination with
their own bundle IDs. This keeps contributor and maintainer test traffic out of
the production and preprod TelemetryDeck apps.

Direct SwiftPM or otherwise unconfigured source builds leave telemetry
disabled. Do not enable production or preprod telemetry for local testing, and
do not hardcode TelemetryDeck app IDs in application code or new scripts. Build
scripts that need telemetry routing must use the centralized public identifiers
in `scripts/meets_telemetry_channels.sh` and select the appropriate non-production
channel explicitly.

New telemetry events must remain anonymous and must not include audio,
transcripts, meeting or calendar titles, clipboard or screen contents, API
keys, auth tokens, local file paths, raw logs, database content, raw localized
error messages, or other user-provided text. Prefer finite, allowlisted values
that can be reviewed and tested.

## Release Signing

Official preprod and stable release scripts require maintainer-only Developer
ID provisioning profiles:

- `com.meets.preprod` for `scripts/release-preprod.sh`
- `com.meets.app` for `scripts/release.sh`

Those profiles are not committed to the repository. Maintainers pass them with
`MEETS_PROVISIONING_PROFILE`; contributors should not need to run these
release scripts for normal PR validation.

Before packaging a signed release, ensure a *complete* LocalVQE runtime is
present (`./scripts/build_localvqe.sh`). `build_native_app.sh` fails closed when
those dylibs are missing or incomplete. `MEETS_ALLOW_MISSING_LOCALVQE=1` is
an unsigned-development override only and cannot bypass signed release
packaging.

## SwiftPM Build Cache

SwiftPM writes build artifacts to `native/MeetsNative/.build` by default,
which can become large across worktrees. Use a shared scratch path for local
testing:

```bash
MEETS_SWIFTPM_SCRATCH_PATH="$HOME/Library/Caches/meets-spm/dev" \
  MEETS_SKIP_SIGN=1 ./scripts/dev-test.sh
```

Do not run concurrent builds from different worktrees into the same scratch
path. Use separate names such as `dev`, `test`, or `agent-1`.

## Tests

Run the native test package:

```bash
swift test --package-path native/MeetsNative
```

For CI-sized local checks, use the shard script:

```bash
./scripts/run_ci_test_shard.sh core
./scripts/run_ci_test_shard.sh dictation-transcription
./scripts/run_ci_test_shard.sh meetings
```

For direct SwiftPM test runs with a shared cache:

```bash
swift test --package-path native/MeetsNative \
  --scratch-path "$HOME/Library/Caches/meets-spm/test"
```

## Pull Requests

- Keep changes focused and include tests for behavioral changes.
- Mention the test commands you ran in the PR description.
- Use `MEETS_SKIP_SIGN=1` for local app verification unless you have a valid
  signing identity.
- Use `--local-only` unless your change specifically needs iCloud/CloudKit
  entitlements.
- Avoid committing generated build artifacts, app bundles, model files, or
  local application data.

## Contribution License

Meets is licensed under the [MIT License](LICENSE). By submitting a
contribution, you agree that your contribution is licensed under the same MIT
License. Your DCO sign-off certifies that you have the right to submit the
contribution under those terms.

Do not submit material that you do not have the right to contribute. If the
contribution was created in the course of employment, contracting, research,
or another relationship that may affect ownership, obtain any permission
required by that relationship before submitting it.

Identify third-party code, models, datasets, media, or other assets in the pull
request description. Include the source and applicable license or terms.

## Developer Certificate of Origin

Every non-merge commit contributed to Meets must be signed off under the
[Developer Certificate of Origin 1.1](DCO). The sign-off certifies that you
created the contribution or otherwise have the right to submit it under the
repository's open-source license.

Add the sign-off automatically when creating a commit:

```bash
git commit --signoff -m "Describe the change"
```

The resulting commit message must contain a trailer using your real name and an
email address associated with the commit:

```text
Signed-off-by: Your Name <your-email@example.com>
```

A DCO sign-off is different from a cryptographic Git commit signature. Every
non-merge commit in a pull request must contain a valid `Signed-off-by` trailer.
The contributor who authored a commit must provide its sign-off; maintainers
will not sign on another contributor's behalf or override a missing sign-off.

This requirement applies to every pull request merged after adoption of this
policy, including pull requests that were already open when the policy was
adopted. If an existing pull request contains unsigned commits, amend or rebase
those commits with `--signoff`, or follow the individual remediation
instructions reported by the DCO check.

## AI-Assisted Contributions

You remain responsible for every contribution you submit, including work
created with an AI coding tool or agent. In the pull request description:

- disclose material AI assistance and name the tool or service;
- confirm that you reviewed and tested the resulting changes;
- identify any third-party code, data, model output, or license obligations;
- do not submit secrets, confidential information, or material you lack the
  right to contribute.
