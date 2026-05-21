#!/bin/bash
# Unified ACS (Access Control Services) walker for all PCI bridges.
# Enumerates every PCI bridge in the system and writes the ACSCtl register
# for each bridge that exposes the ACS capability.
#
# Usage: acs.sh --mode {enable|disable} [-d]

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

# The main walk only runs when this file is executed directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail

  [[ "$EUID" -eq 0 ]] || {
    echo "ERROR: acs.sh must be run as root"
    exit 1
  }

  MODE=""
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
        exit 0
        ;;
      *)
        echo "ERROR: unknown argument: $1" >&2
        exit 1
        ;;
    esac
  done

  case "$MODE" in
    # Source Validation | P2P Request/Completion Redirect | Upstream Forwarding
    enable) ACS_VALUE="001f" ;;
    disable) ACS_VALUE="0000" ;;
    *)
      echo "ERROR: --mode {enable|disable} required" >&2
      exit 1
      ;;
  esac

  mapfile -t bridge_bdfs < <(lspci -D | awk '/PCI bridge/{print $1}' | sort -u)

  [[ "${#bridge_bdfs[@]}" -gt 0 ]] || {
    echo "ERROR: No PCI bridges found"
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
