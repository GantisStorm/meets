#!/usr/bin/env bash
set -euo pipefail

if command -v meets-cli >/dev/null 2>&1; then
  command -v meets-cli
  exit 0
fi

if [[ -x "/Applications/Meets.app/Contents/MacOS/meets-cli" ]]; then
  echo "/Applications/Meets.app/Contents/MacOS/meets-cli"
  exit 0
fi

if [[ -x "native/MeetsNative/.build/debug/meets-cli" ]]; then
  echo "$(pwd)/native/MeetsNative/.build/debug/meets-cli"
  exit 0
fi

if [[ -x "native/MeetsNative/.build/release/meets-cli" ]]; then
  echo "$(pwd)/native/MeetsNative/.build/release/meets-cli"
  exit 0
fi

exit 1
