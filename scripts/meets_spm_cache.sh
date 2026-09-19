#!/usr/bin/env bash

# Shared SwiftPM scratch-path resolution for local Meets builds.
#
# Resolution precedence, unless disabled:
#   1. MEETS_SWIFTPM_SCRATCH_PATH, when explicitly set
#   2. MEETS_EXTERNAL_SPM_CACHE_ROOT/<channel>, when that root exists
#   3. ~/Library/Caches/meets-spm/<channel>
#
# MEETS_DISABLE_SWIFTPM_SCRATCH_PATH=1 takes precedence over all other path
# settings and lets SwiftPM use the package-local .build directory.

[[ -n "${_MEETS_SPM_CACHE_LOADED:-}" ]] && return 0
_MEETS_SPM_CACHE_LOADED=1

meets_spm_scratch_disabled() {
  [[ "${MEETS_DISABLE_SWIFTPM_SCRATCH_PATH:-0}" == "1" ]]
}

meets_default_spm_cache_root() {
  local external_root="${MEETS_EXTERNAL_SPM_CACHE_ROOT:-}"
  if [[ -n "$external_root" && -d "$external_root" ]]; then
    printf '%s\n' "$external_root"
  else
    printf '%s\n' "$HOME/Library/Caches/meets-spm"
  fi
}

meets_resolve_spm_scratch_path() {
  local channel="${1:-dev}"
  if [[ -n "${MEETS_SWIFTPM_SCRATCH_PATH:-}" ]]; then
    printf '%s\n' "$MEETS_SWIFTPM_SCRATCH_PATH"
    return 0
  fi
  if [[ -n "${MEETS_SWIFTPM_SCRATCH_CHANNEL:-}" ]]; then
    channel="$MEETS_SWIFTPM_SCRATCH_CHANNEL"
  fi
  printf '%s/%s\n' "$(meets_default_spm_cache_root)" "$channel"
}

meets_worktree_spm_scratch_channel() {
  local channel="${1:-dev}"
  local root="${2:-$PWD}"
  local root_name
  local root_hash
  root_name="$(basename "$root")"
  root_hash="$(printf '%s' "$root" | cksum | awk '{print $1}')"
  printf 'worktrees/%s-%s/%s\n' "$root_name" "$root_hash" "$channel"
}

meets_spm_artifacts_dir() {
  local package_dir="$1"
  local scratch_path="${2:-}"
  if [[ -n "$scratch_path" ]]; then
    printf '%s/artifacts\n' "$scratch_path"
  else
    printf '%s/.build/artifacts\n' "$package_dir"
  fi
}
