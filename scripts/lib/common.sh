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

  declare -ga NPUS=()
  if [[ -n "${VALIDATE_NPUS:-}" ]]; then
    # Normalize: strip all whitespace so values like "0, 2" work.
    VALIDATE_NPUS=${VALIDATE_NPUS//[[:space:]]/}
    IFS=',' read -ra NPUS <<<"$VALIDATE_NPUS"
    for npu in "${NPUS[@]}"; do
      [[ $npu =~ ^[0-9]+$ ]] || {
        echo "Error: invalid NPU index '$npu' (VALIDATE_NPUS=$VALIDATE_NPUS)" >&2
        exit 1
      }
      ((npu < NPU_COUNT)) || {
        echo "Error: NPU index '$npu' out of range (detected $NPU_COUNT NPUs)" >&2
        exit 1
      }
    done
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
