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

apply_acs_value() {
  local bdf="$1"
  local cur
  cur="$(setpci -s "${bdf#0000:}" ECAP_ACS+0x6.W 2>/dev/null || true)"
  [[ -n "$cur" ]] || return 0
  echo "  Apply ACSCtl: ${bdf#0000:}  (0x$cur -> 0x$ACS_VALUE)"
  setpci -s "${bdf#0000:}" "ECAP_ACS+0x6.W=0x$ACS_VALUE"
}

save_acs_state() {
  local state_file="$1"
  local bridge cur
  local -a bridge_bdfs=()
  mapfile -t bridge_bdfs < <(lspci -D | awk '/PCI bridge/{print $1}' | sort -u)
  [[ "${#bridge_bdfs[@]}" -gt 0 ]] || {
    echo "ERROR: No PCI bridges found" >&2
    return 1
  }
  : >"$state_file"
  for bridge in "${bridge_bdfs[@]}"; do
    if has_acs_cap "$bridge"; then
      cur="$(setpci -s "${bridge#0000:}" ECAP_ACS+0x6.W 2>/dev/null || true)"
      [[ -n "$cur" ]] && printf '%s %s\n' "$bridge" "$cur" >>"$state_file"
    fi
  done
  echo "ACS state saved to $state_file"
}

restore_acs_state() {
  local state_file="$1"
  local bdf value cur
  [[ -f "$state_file" ]] || {
    echo "ERROR: state file not found: $state_file" >&2
    return 1
  }
  while read -r bdf value; do
    [[ -n "$bdf" && -n "$value" ]] || continue
    cur="$(setpci -s "${bdf#0000:}" ECAP_ACS+0x6.W 2>/dev/null || true)"
    if [[ -n "$cur" ]]; then
      echo "  Restore ACSCtl: ${bdf#0000:}  (0x$cur -> 0x$value)"
    else
      echo "  Restore ACSCtl: ${bdf#0000:}  (-> 0x$value)"
    fi
    # Best-effort: keep restoring the remaining bridges even if one write fails,
    # so a single bad bridge cannot strand the rest with ACS left disabled.
    if ! setpci -s "${bdf#0000:}" "ECAP_ACS+0x6.W=0x$value"; then
      echo "WARN: failed to restore ACSCtl for ${bdf#0000:} to 0x$value" >&2
    fi
  done <"$state_file"
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
      restore_acs_state "$STATE_FILE"
      exit 0
      ;;
    *)
      echo "ERROR: --mode {enable|disable|save|restore} required" >&2
      exit 1
      ;;
  esac

  mapfile -t bridge_bdfs < <(lspci -D | awk '/PCI bridge/{print $1}' | sort -u)

  [[ "${#bridge_bdfs[@]}" -gt 0 ]] || {
    echo "ERROR: No PCI bridges found" >&2
    exit 1
  }

  for bridge in "${bridge_bdfs[@]}"; do
    echo "=== Bridge: ${bridge#0000:} ==="
    if has_acs_cap "$bridge"; then
      apply_acs_value "$bridge"
    else
      [[ "$DEBUG" == "1" ]] && echo "  No ACS capability for ${bridge#0000:}"
    fi
  done

  echo "ACS $MODE sequence completed successfully"
fi
