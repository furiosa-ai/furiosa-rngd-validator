#!/bin/bash
# Common helpers for the phase scripts. Sourced, not executed.

RED='\033[0;31m'
NC='\033[0m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'

# SC2034 (variable appears unused) -- these colors are consumed only by sourcing
# scripts; shellcheck cannot follow that direction.
# shellcheck disable=SC2034
GREEN='\033[0;32m'
# shellcheck disable=SC2034
BLUE='\033[0;34m'
# shellcheck disable=SC2034
BOLD='\033[1m'

log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# The ACS walker every phase drives. Overridable so tests can stub it.
ACS_SH="${ACS_SH:-$(dirname "${BASH_SOURCE[0]}")/acs.sh}"

# Path of the pre-run ACS snapshot. Args: out_dir
acs_state_file() { echo "$1/acs_init_state"; }

# Strip $VALIDATOR_DIR, so operator-facing paths are repo-relative: in the
# container the absolute ones are container-internal, and only outputs/ is
# mounted back to the host. Args: path
repo_rel() {
  local root="${VALIDATOR_DIR:-}"
  [[ -n "$root" && "$1" == "$root/"* ]] && echo "${1#"$root"/}" || echo "$1"
}

# The manual rollback command, to run from the repo root. Args: state_file
acs_rollback_cmd() {
  echo "sudo bash $(repo_rel "$ACS_SH") --mode restore $(repo_rel "$1")"
}

# Reject a typo'd ACS_MODE before any bridge is written. Empty is valid (both
# passes). Exits 1.
validate_acs_mode() {
  case "${ACS_MODE:-}" in
    "" | disable | enable) ;;
    *)
      log_error "Invalid ACS_MODE='$ACS_MODE'; expected disable|enable (empty runs both)."
      exit 1
      ;;
  esac
}

# Put every ACS-capable bridge into one mode; a part-way failure rolls back from
# state_file and returns non-zero. Args: mode state_file
acs_apply() {
  local mode=$1 state_file=$2
  log_info "Applying ACS $mode to all bridges"
  bash "$ACS_SH" --mode "$mode" && return 0
  log_error "ACS $mode failed part-way; restoring the pre-run state"
  bash "$ACS_SH" --mode restore "$state_file" ||
    log_error "ACS restore FAILED -- re-apply manually: $(acs_rollback_cmd "$state_file")"
  return 1
}

# Roll back to the pre-run state. Repeat INT/TERM are ignored so the acs.sh child
# cannot be killed mid-restore, PIPE because a phase whose log reader died with
# the same Ctrl-C must not take the restore down with it (children inherit the
# SIG_IGN). Args: state_file
acs_restore() {
  trap '' INT TERM PIPE
  bash "$ACS_SH" --mode restore "$1" ||
    log_error "ACS restore FAILED -- re-apply manually: $(acs_rollback_cmd "$1")" || true
}

# Args: state_file exit_code
acs_restore_and_exit() {
  log_error "Interrupted while switching ACS; restoring the pre-run state" || true
  acs_restore "$1"
  exit "$2"
}

# EXIT handler for a phase that switched ACS: a run that ends badly must not
# leave the host switched, while a clean one keeps it so the phases after this
# one measure under the same mode. A SKIP (exit 75) ran nothing and counts as
# clean. Exits with rc, so it is the last thing a phase's own cleanup does.
# Args: state_file [exit_code, default $?]
acs_restore_if_aborted() {
  local rc=${2:-$?}
  # `if`, not `[[ ... ]] &&`: under `set -e` a false test would abort the handler.
  if [[ -n "$1" && "$rc" -ne 0 && "$rc" -ne 75 ]]; then
    log_error "Phase aborted (exit $rc); restoring the pre-run ACS state" || true
    acs_restore "$1"
  fi
  exit "$rc"
}

# Per-phase entry point: save the pre-run ACSCtl values, then apply ACS_MODE.
# Empty ACS_MODE is a no-op (run_p2p.sh walks both modes itself). A completed
# apply is left as set, so the snapshot is the only way back. Args: out_dir
apply_acs_mode() {
  validate_acs_mode
  [[ -n "${ACS_MODE:-}" ]] || return 0

  # The traps below belong to whatever shell runs this; in a subshell (a pipeline
  # stage, say) they would die with it and leave the phase unprotected.
  ((BASH_SUBSHELL == 0)) ||
    log_warn "apply_acs_mode ran in a subshell -- ACS will NOT roll back if this phase aborts"

  # Global, so a phase with an EXIT trap of its own (which replaces the one armed
  # below) can still reach the snapshot from its cleanup.
  ACS_STATE_FILE="$(acs_state_file "${1:?apply_acs_mode requires an output dir}")"
  local state_file="$ACS_STATE_FILE"

  bash "$ACS_SH" --mode save "$state_file"
  # Armed only around the apply: an abort mid-walk leaves the host half-switched
  # and the phase's own trap is not armed yet. Expanded now on purpose --
  # $state_file is a local, gone by the time the handler runs.
  # shellcheck disable=SC2064
  trap "acs_restore_and_exit '$state_file' 130" INT
  # shellcheck disable=SC2064
  trap "acs_restore_and_exit '$state_file' 143" TERM
  acs_apply "$ACS_MODE" "$state_file" || exit 1

  # From here the host is switched, so anything that ends the phase badly has to
  # roll it back. INT/TERM re-exit so they funnel through the EXIT handler.
  # shellcheck disable=SC2064
  trap "acs_restore_if_aborted '$state_file'" EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  log_info "Pre-run ACS state kept at $(repo_rel "$state_file") -- from the repo root, roll back with: $(acs_rollback_cmd "$state_file")"
}

detect_npu_count() {
  find /sys/kernel/debug/rngd/ -maxdepth 1 -name 'mgmt*' 2>/dev/null | wc -l
}

# Strip whitespace from VALIDATE_NPUS and reject non-numeric or out-of-range
# indices, rewriting it in place. Idempotent. Optional arg 1 is the NPU count
# (detected here when omitted). Exits 1 if malformed or out of range.
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

  normalize_validate_npus "$NPU_COUNT"

  declare -ga NPUS=()
  if [[ -n "${VALIDATE_NPUS:-}" ]]; then
    IFS=',' read -ra NPUS <<<"$VALIDATE_NPUS"
    echo "Using specified NPUs: ${NPUS[*]}"
  else
    for ((i = 0; i < NPU_COUNT; i++)); do NPUS+=("$i"); done
  fi
}

# Split the resolved $NPUS into groups of the given size, echoing one
# space-separated group per line. When the NPU count is an exact multiple of
# the size the groups are non-overlapping chunks (e.g. 8 NPUs, size 4 ->
# "0 1 2 3" / "4 5 6 7"); otherwise a final group anchored at the last NPU is
# appended so both the first and last NPU are covered (e.g. 5 NPUs, size 4 ->
# "0 1 2 3" / "1 2 3 4"). Groups follow position in $NPUS, so a non-contiguous
# VALIDATE_NPUS selection is grouped in the order provided (after normalization).
# Caller must ensure size <= ${#NPUS[@]}.
npu_groups() {
  local size=$1
  local n=${#NPUS[@]}
  local -a starts=()
  local full=$((n / size)) k
  for ((k = 0; k < full; k++)); do starts+=($((k * size))); done
  ((n % size != 0)) && starts+=($((n - size)))

  local s i
  local -a grp
  for s in "${starts[@]}"; do
    grp=()
    for ((i = s; i < s + size; i++)); do grp+=("${NPUS[i]}"); done
    echo "${grp[*]}"
  done
}

# Args: out_dir [timestamp]
capture_dmesg() {
  local out_dir="$1"
  local ts="${2:-${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}}"
  dmesg >"${out_dir}/dmesg_${ts}.log"
}
