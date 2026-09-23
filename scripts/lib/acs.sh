#!/bin/bash
# Unified ACS (Access Control Services) walker for all PCI bridges.
# Enumerates every PCI bridge in the system and writes the ACSCtl register
# for each bridge that exposes the ACS capability.
#
# Usage: acs.sh --mode {enable|disable} [-d]
#        acs.sh --mode save <file>
#        acs.sh --mode restore <file>

DEBUG=${DEBUG:-0}

has_acs_cap() {
  local bdf="$1"
  local out
  out="$(lspci -nn -vvv -s "${bdf#0000:}" 2>/dev/null || true)"
  if [[ "$DEBUG" == "1" ]]; then
    echo "----- [DBG] lspci -nn -vvv -s ${bdf#0000:} -----" >&2
    echo "$out" >&2
    echo "----- [DBG] ACS-related lines -----" >&2
    echo "$out" | grep -niE "Access Control Services|ACSCap:|ACSCtl:" >&2 || true
    echo "----------------------------------" >&2
  fi
  echo "$out" | grep -qiE "Access Control Services|ACSCap:|ACSCtl:"
}

# Every PCI bridge BDF, one per line.
list_bridges() {
  lspci -D | awk '/PCI bridge/{print $1}' | sort -u
}

# Echo a bridge's ACSCtl value, empty if it has none. Args: bdf
read_acsctl() {
  setpci -s "${1#0000:}" ECAP_ACS+0x6.W 2>/dev/null || true
}

apply_acs_value() {
  local bdf="$1"
  local cur
  cur="$(read_acsctl "$bdf")"
  [[ -n "$cur" ]] || return 0
  echo "  Apply ACSCtl: ${bdf#0000:}  (0x$cur -> 0x$ACS_VALUE)"
  # Best-effort like restore_acs_state: report, don't abort the walk.
  setpci -s "${bdf#0000:}" "ECAP_ACS+0x6.W=0x$ACS_VALUE" || {
    echo "WARN: failed to apply ACSCtl for ${bdf#0000:} to 0x$ACS_VALUE" >&2
    return 1
  }
}

save_acs_state() {
  local state_file="$1"
  local bridge cur
  local -a bridge_bdfs=()
  mapfile -t bridge_bdfs < <(list_bridges)
  [[ "${#bridge_bdfs[@]}" -gt 0 ]] || {
    echo "ERROR: No PCI bridges found" >&2
    return 1
  }
  : >"$state_file"
  for bridge in "${bridge_bdfs[@]}"; do
    if has_acs_cap "$bridge"; then
      cur="$(read_acsctl "$bridge")"
      [[ -n "$cur" ]] && printf '%s %s\n' "$bridge" "$cur" >>"$state_file"
    fi
  done
  echo "ACS state saved to $state_file"
}

restore_acs_state() {
  local state_file="$1"
  local bdf value cur
  local failed=0
  [[ -f "$state_file" ]] || {
    echo "ERROR: state file not found: $state_file" >&2
    return 1
  }
  while read -r bdf value; do
    [[ -n "$bdf" && -n "$value" ]] || continue
    cur="$(read_acsctl "$bdf")"
    if [[ -n "$cur" ]]; then
      echo "  Restore ACSCtl: ${bdf#0000:}  (0x$cur -> 0x$value)"
    else
      echo "  Restore ACSCtl: ${bdf#0000:}  (-> 0x$value)"
    fi
    # Best-effort: one bad bridge must not strand the rest with ACS disabled.
    if ! setpci -s "${bdf#0000:}" "ECAP_ACS+0x6.W=0x$value"; then
      echo "WARN: failed to restore ACSCtl for ${bdf#0000:} to 0x$value" >&2
      failed=1
    fi
  done <"$state_file"
  # A bridge left at the benchmark's value has lost its isolation: not clean.
  if [[ "$failed" -ne 0 ]]; then
    echo "ERROR: ACS restore failed on one or more bridges" >&2
    return 1
  fi
  echo "ACS state restored from $state_file"
}

# The main walk only runs when this file is executed directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail

  [[ "$EUID" -eq 0 ]] || {
    echo "ERROR: acs.sh must be run as root" >&2
    exit 1
  }

  MODE=""
  STATE_FILE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d)
        DEBUG=1
        shift
        ;;
      --mode)
        MODE="$2"
        shift 2
        ;;
      -h | --help)
        echo "Usage: $0 --mode {enable|disable} [-d]"
        echo "       $0 --mode save <file>"
        echo "       $0 --mode restore <file>"
        exit 0
        ;;
      -*)
        echo "ERROR: unknown option: $1" >&2
        exit 1
        ;;
      *)
        if [[ -z "$STATE_FILE" ]]; then
          STATE_FILE="$1"
          shift
        else
          echo "ERROR: unknown argument: $1" >&2
          exit 1
        fi
        ;;
    esac
  done

  case "$MODE" in
    # Source Validation | P2P Request/Completion Redirect | Upstream Forwarding
    enable | disable)
      [[ -z "$STATE_FILE" ]] || {
        echo "ERROR: --mode $MODE takes no positional argument: $STATE_FILE" >&2
        exit 1
      }
      if [[ "$MODE" == enable ]]; then
        ACS_VALUE="001f"
      else
        ACS_VALUE="0000"
      fi
      ;;
    save)
      [[ -n "$STATE_FILE" ]] || {
        echo "ERROR: --mode save requires <file>" >&2
        exit 1
      }
      save_acs_state "$STATE_FILE"
      exit 0
      ;;
    restore)
      [[ -n "$STATE_FILE" ]] || {
        echo "ERROR: --mode restore requires <file>" >&2
        exit 1
      }
      # `set -e` aborts here on a partial restore, so the exit 0 below is only
      # reached when every bridge took its saved value.
      restore_acs_state "$STATE_FILE"
      exit 0
      ;;
    *)
      echo "ERROR: --mode {enable|disable|save|restore} required" >&2
      exit 1
      ;;
  esac

  mapfile -t bridge_bdfs < <(list_bridges)

  [[ "${#bridge_bdfs[@]}" -gt 0 ]] || {
    echo "ERROR: No PCI bridges found" >&2
    exit 1
  }

  APPLY_FAILED=0
  for bridge in "${bridge_bdfs[@]}"; do
    echo "=== Bridge: ${bridge#0000:} ==="
    if has_acs_cap "$bridge"; then
      # `||` keeps `set -e` from aborting the walk on the first bad bridge.
      apply_acs_value "$bridge" || APPLY_FAILED=1
    else
      [[ "$DEBUG" == "1" ]] && echo "  No ACS capability for ${bridge#0000:}"
    fi
  done

  if [[ "$APPLY_FAILED" -ne 0 ]]; then
    echo "ERROR: ACS $MODE sequence failed on one or more bridges" >&2
    exit 1
  fi

  echo "ACS $MODE sequence completed successfully"
fi
