#!/usr/bin/env bash
set -euo pipefail

# Builds and launches an isolated dev app for end-to-end testing.
#
# - Separate bundle ID (com.meets.dev*) — won't interfere with production Meets
# - Separate data directory (~/Library/Application Support/MeetsDev*/)
# - Preserves existing dev config and database by default
# - Dev builds default to local-only entitlements to preserve existing TCC
#   permissions and avoid requiring Apple Developer profiles
# - CloudKit/APNs dev signing is opt-in with --cloud-entitlements
# - External contributors can set MEETS_SKIP_SIGN=1 to build without the
#   maintainer signing certificate
# - Uses a shared, worktree-isolated SwiftPM scratch path by default; set
#   MEETS_DISABLE_SWIFTPM_SCRATCH_PATH=1 to use package-local .build instead
# - Installs to /Applications/MeetsDev*.app
#
# Usage:
#   ./scripts/dev-test.sh                         # Build and launch MeetsDev
#   ./scripts/dev-test.sh --lane A                # Build and launch MeetsDevA
#   ./scripts/dev-test.sh --lane A --local-only   # Omit iCloud/APNs entitlements
#   ./scripts/dev-test.sh --reset                 # Reset onboarding only (keeps data)
#   MEETS_PROVISIONING_PROFILE=/path/to/profile.provisionprofile \
#   MEETS_SIGN_IDENTITY="Apple Development: Name (TEAMID)" \
#   MEETS_CODESIGN_TIMESTAMP=none ./scripts/dev-test.sh --cloud-entitlements

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/meets_telemetry_channels.sh"

usage() {
  cat <<'EOF'
Build and launch a local Meets dev app.

Options:
  --lane A|B|C            Build a fixed reusable dev lane: MeetsDevA/B/C.
  --local-only            Sign without iCloud/APNs entitlements.
                          Alias: --without-cloud-entitlements.
  --cloud-entitlements    Sign with the default cloud entitlements file.
                          Alias: --with-cloud-entitlements.
  --reset                 Reset onboarding only for the selected lane.
  --help                  Show this help text.

Default behavior without --lane is unchanged for the app identity: MeetsDev,
com.meets.dev, ~/Library/Application Support/MeetsDev, and
/Applications/MeetsDev.app. Dev builds use local-only entitlements unless
--cloud-entitlements is provided.

Cloud-entitled dev builds require a provisioning profile whose app identifier
matches the selected bundle ID and a signing identity included by that profile.
Cloud-entitled MeetsDev builds always use the CloudKit Development environment;
only production/preproduction release builds may use CloudKit Production.
For the maintainer's plain MeetsDev lane, this script auto-selects the local
com.meets.dev CloudKit profile from ../meets-ios/secrets when
--cloud-entitlements is provided and the profile exists.
EOF
}

# Parse args
RESET=0
LANE=""
ENTITLEMENTS_MODE=""
ENTITLEMENTS_MODE_EXPLICIT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      echo "Error: --clean has been removed because it deletes MeetsDev data." >&2
      echo "To test a fresh profile, create a named backup first and use a separate support directory." >&2
      exit 2
      ;;
    --reset)
      RESET=1
      shift
      ;;
    --lane)
      [[ $# -ge 2 ]] || { echo "Error: --lane requires A, B, or C." >&2; exit 2; }
      LANE="$2"
      shift 2
      ;;
    --lane=*)
      LANE="${1#--lane=}"
      shift
      ;;
    --local-only|--without-cloud-entitlements)
      ENTITLEMENTS_MODE="local-only"
      ENTITLEMENTS_MODE_EXPLICIT=1
      shift
      ;;
    --cloud-entitlements|--with-cloud-entitlements)
      ENTITLEMENTS_MODE="cloud"
      ENTITLEMENTS_MODE_EXPLICIT=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$LANE" in
  "")
    DEV_APP_NAME="MeetsDev"
    DEV_BUNDLE_ID="com.meets.dev"
    ;;
  A|a|B|b|C|c)
    LANE_UPPER="$(printf '%s' "$LANE" | tr '[:lower:]' '[:upper:]')"
    LANE_LOWER="$(printf '%s' "$LANE" | tr '[:upper:]' '[:lower:]')"
    DEV_APP_NAME="MeetsDev${LANE_UPPER}"
    DEV_BUNDLE_ID="com.meets.dev.${LANE_LOWER}"
    ;;
  *)
    echo "Error: unsupported lane '$LANE'. Allowed lanes: A, B, C." >&2
    exit 2
    ;;
esac

if [[ -z "$ENTITLEMENTS_MODE" ]]; then
  ENTITLEMENTS_MODE="local-only"
fi

DEV_SUPPORT_DIR="$HOME/Library/Application Support/$DEV_APP_NAME"
DEV_APP="/Applications/$DEV_APP_NAME.app"
ONBOARDING_PROGRESS_FILE="$DEV_SUPPORT_DIR/onboarding-progress.json"
DEFAULT_DEV_CLOUD_PROFILE="$ROOT/../meets-ios/secrets/meetsmacosdevcloudkitcommeetsdev.provisionprofile"
DEFAULT_DEV_CLOUD_SIGN_IDENTITY="Apple Development: Pranav Hari Guruvayurappan (59WTZW55XG)"
RESOLVED_PROVISIONING_PROFILE="${MEETS_PROVISIONING_PROFILE:-}"
RESOLVED_SIGN_IDENTITY="${MEETS_SIGN_IDENTITY:-}"
RESOLVED_CODESIGN_TIMESTAMP="${MEETS_CODESIGN_TIMESTAMP:-}"
# Build the app via xcodebuild (native/MeetsXcode) by default so App Intents
# metadata is generated and Shortcuts/Siri actions are actually discoverable
# in dev builds. Requires xcodegen (brew install xcodegen). Set
# MEETS_USE_XCODE_BUILD=0 to fall back to the plain `swift build` path if
# xcodegen/xcodebuild aren't available or something regresses.
RESOLVED_USE_XCODE_BUILD="${MEETS_USE_XCODE_BUILD:-1}"

BUILD_ENV=(
  MEETS_APP_NAME="$DEV_APP_NAME"
  MEETS_BUNDLE_ID="$DEV_BUNDLE_ID"
  MEETS_SUPPORT_DIR_NAME="$DEV_APP_NAME"
  MEETS_DISPLAY_NAME="$DEV_APP_NAME"
  MEETS_SPARKLE_FEED_URL=""
  MEETS_TELEMETRYDECK_APP_ID="$MEETS_TELEMETRYDECK_DEV_APP_ID"
  MEETS_TELEMETRY_CHANNEL="dev"
  MEETS_USE_XCODE_BUILD="$RESOLVED_USE_XCODE_BUILD"
)
if [[ -n "$LANE" ]]; then
  BUILD_ENV+=(MEETS_EXECUTABLE_NAME="$DEV_APP_NAME")
fi

use_local_only_entitlements() {
  RESOLVED_PROVISIONING_PROFILE=""
  RESOLVED_SIGN_IDENTITY=""
  RESOLVED_CODESIGN_TIMESTAMP=""
  BUILD_ENV+=(
    MEETS_ENTITLEMENTS="$ROOT/scripts/MeetsLocalOnly.entitlements"
    MEETS_PROVISIONING_PROFILE=""
    MEETS_APS_ENVIRONMENT=""
  )
}

case "$ENTITLEMENTS_MODE" in
  local-only)
    use_local_only_entitlements
    ;;
  cloud)
    REQUESTED_CLOUDKIT_ENVIRONMENT="${MEETS_ICLOUD_CONTAINER_ENVIRONMENT:-Development}"
    if [[ "$(printf '%s' "$REQUESTED_CLOUDKIT_ENVIRONMENT" | tr '[:upper:]' '[:lower:]')" != "development" ]]; then
      echo "Error: MeetsDev builds must use the CloudKit Development environment." >&2
      echo "Use the production Meets release workflow for CloudKit Production." >&2
      exit 2
    fi
    BUILD_ENV+=(MEETS_ICLOUD_CONTAINER_ENVIRONMENT="Development")
    if [[ -z "$RESOLVED_PROVISIONING_PROFILE" && "$DEV_BUNDLE_ID" == "com.meets.dev" && -f "$DEFAULT_DEV_CLOUD_PROFILE" ]]; then
      RESOLVED_PROVISIONING_PROFILE="$DEFAULT_DEV_CLOUD_PROFILE"
      if [[ -z "$RESOLVED_SIGN_IDENTITY" ]]; then
        RESOLVED_SIGN_IDENTITY="$DEFAULT_DEV_CLOUD_SIGN_IDENTITY"
      fi
      if [[ -z "$RESOLVED_CODESIGN_TIMESTAMP" ]]; then
        RESOLVED_CODESIGN_TIMESTAMP="none"
      fi
    fi
    if [[ -z "$RESOLVED_PROVISIONING_PROFILE" ]]; then
      if [[ "$ENTITLEMENTS_MODE_EXPLICIT" -eq 1 ]]; then
        echo "Error: cloud-entitled dev builds require MEETS_PROVISIONING_PROFILE." >&2
        echo "The profile must match bundle ID '$DEV_BUNDLE_ID' and include the signing identity." >&2
        echo "Use --local-only for a dev build that does not need iCloud/APNs entitlements." >&2
        exit 2
      fi
      echo "No local CloudKit profile found for $DEV_BUNDLE_ID; building local-only dev app."
      ENTITLEMENTS_MODE="local-only"
      use_local_only_entitlements
    else
      if [[ -z "$RESOLVED_SIGN_IDENTITY" ]]; then
        echo "Error: cloud-entitled dev builds require MEETS_SIGN_IDENTITY." >&2
        echo "Use the Apple Development identity included by the selected provisioning profile." >&2
        exit 2
      fi
      BUILD_ENV+=(
        MEETS_PROVISIONING_PROFILE="$RESOLVED_PROVISIONING_PROFILE"
        MEETS_SIGN_IDENTITY="$RESOLVED_SIGN_IDENTITY"
      )
      if [[ -n "$RESOLVED_CODESIGN_TIMESTAMP" ]]; then
        BUILD_ENV+=(MEETS_CODESIGN_TIMESTAMP="$RESOLVED_CODESIGN_TIMESTAMP")
      fi
    fi
    ;;
  *)
    echo "Error: internal unsupported entitlements mode '$ENTITLEMENTS_MODE'." >&2
    exit 2
    ;;
esac

# Kill any running dev instance
pkill -f "$DEV_APP" 2>/dev/null || true
sleep 0.5

# Reset onboarding only if requested
if [[ "$RESET" -eq 1 ]] && [[ -f "$DEV_SUPPORT_DIR/config.json" ]]; then
  echo "Resetting onboarding flag for $DEV_APP_NAME..."
  python3 -c "
import json, os, pathlib
p = pathlib.Path('$DEV_SUPPORT_DIR/config.json')
c = json.loads(p.read_text())
c['has_completed_onboarding'] = False
mode = p.stat().st_mode & 0o777
p.write_text(json.dumps(c, indent=2) + '\n')
os.chmod(p, mode)
progress = pathlib.Path('$ONBOARDING_PROGRESS_FILE')
if progress.exists():
    progress.unlink()
    print('  Cleared transient onboarding progress')
print('  Onboarding reset (data preserved)')
"
fi

# Build with isolated identity
echo "Building $DEV_APP_NAME (debug, signed)..."
echo "  Bundle ID:    $DEV_BUNDLE_ID"
echo "  Data:         $DEV_SUPPORT_DIR"
echo "  Entitlements: $ENTITLEMENTS_MODE"
if [[ -n "$RESOLVED_PROVISIONING_PROFILE" ]]; then
  echo "  Profile:      $RESOLVED_PROVISIONING_PROFILE"
fi
if [[ -n "$RESOLVED_SIGN_IDENTITY" ]]; then
  echo "  Sign identity: $RESOLVED_SIGN_IDENTITY"
fi
env "${BUILD_ENV[@]}" "$ROOT/scripts/build_native_app.sh" debug

echo ""
echo "Launching $DEV_APP_NAME..."
open "$DEV_APP"

echo ""
echo "=== Dev Test Ready ==="
echo "  App: $DEV_APP"
echo "  Data: $DEV_SUPPORT_DIR"
echo "  DB: $DEV_SUPPORT_DIR/meets.db"
echo ""
echo "Tips:"
if [[ -n "$LANE" ]]; then
  echo "  ./scripts/dev-test.sh --lane $LANE --reset    # Re-run onboarding for this lane (keep data)"
else
  echo "  ./scripts/dev-test.sh --reset                 # Re-run onboarding (keep data)"
fi
echo "  pkill -f \"$DEV_APP\"                         # Kill this dev app"
