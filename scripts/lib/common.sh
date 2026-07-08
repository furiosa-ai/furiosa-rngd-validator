#!/bin/bash
# Common helpers for the phase scripts. Sourced, not executed.

RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# SC2034 (variable appears unused) -- GREEN, BLUE, and BOLD are consumed only
# by sourcing scripts; shellcheck cannot follow that direction.
# shellcheck disable=SC2034
GREEN='\033[0;32m'
# shellcheck disable=SC2034
BLUE='\033[0;34m'
# shellcheck disable=SC2034
BOLD='\033[1m'

log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

detect_npu_count() {
  find /sys/kernel/debug/rngd/ -maxdepth 1 -name 'mgmt*' 2>/dev/null | wc -l
}

# Normalize and validate the VALIDATE_NPUS override, if set.
# Strips whitespace (so "0, 2" works), rejects empty/non-numeric values, and
# rejects any index that is not among the NPUs actually present on this host so a
# misconfigured override fails fast with a clear message instead of surfacing as
# a confusing failure deep inside a vendor binary. Rewrites VALIDATE_NPUS in
# place with the normalized value. Idempotent, so callers may invoke it more than
# once. Optional arg 1 is the detected NPU count; when omitted it is detected here
# so the check works even for callers (e.g. config load) that have no count yet.
# Exits 1 if VALIDATE_NPUS is set but malformed or out of the detected range.
normalize_validate_npus() {
  [[ -n "${VALIDATE_NPUS:-}" ]] || return 0
  local normalized entry
  local -a entries
  local count="${1:-$(detect_npu_count)}"
  ((count > 0)) || {
    log_error "No NPUs detected, cannot honor VALIDATE_NPUS='$VALIDATE_NPUS'"
    exit 1
  }
  normalized=${VALIDATE_NPUS//[[:space:]]/}
  [[ -n "$normalized" ]] || {
    log_error "VALIDATE_NPUS contains no NPU indices (VALIDATE_NPUS='$VALIDATE_NPUS')"
    exit 1
  }
  IFS=',' read -ra entries <<<"$normalized"
  for entry in "${entries[@]}"; do
    [[ $entry =~ ^[0-9]+$ ]] || {
      log_error "invalid NPU index '$entry' (VALIDATE_NPUS='$VALIDATE_NPUS')"
      exit 1
    }
    ((10#$entry < count)) || {
      log_error "NPU index '$entry' out of range (detected $count NPUs, available range 0~$((count - 1)))"
      exit 1
    }
  done
  VALIDATE_NPUS=$normalized
}

# Detect NPUs and resolve the set to use, honoring VALIDATE_NPUS.
# Sets globals: NPU_COUNT (total detected) and NPUS (array of indices to use).
# Exits 1 if no NPUs found or VALIDATE_NPUS is invalid/out of range.
resolve_npus() {
  NPU_COUNT=$(detect_npu_count)
  [[ "$NPU_COUNT" -eq 0 ]] && {
    echo -e "${RED}Error: No NPUs detected${NC}" >&2
    exit 1
  }
  echo "Detected $NPU_COUNT NPU(s)"

  # Validate/normalize against the count we just detected (idempotent even if
  # already run at config load).
  normalize_validate_npus "$NPU_COUNT"

  declare -ga NPUS=()
  if [[ -n "${VALIDATE_NPUS:-}" ]]; then
    IFS=',' read -ra NPUS <<<"$VALIDATE_NPUS"
    echo "Using specified NPUs: ${NPUS[*]}"
  else
    for ((i = 0; i < NPU_COUNT; i++)); do NPUS+=("$i"); done
  fi
}

# Args: out_dir [timestamp]
capture_dmesg() {
  local out_dir="$1"
  local ts="${2:-${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}}"
  dmesg >"${out_dir}/dmesg_${ts}.log"
}
