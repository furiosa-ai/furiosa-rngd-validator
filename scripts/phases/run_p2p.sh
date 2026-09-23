#!/bin/bash
# P2P bandwidth test phase.
# Runs `furiosa-hal-bench p2p` between every NPU pair, once per ACS state:
# empty ACS_MODE runs ACS-disabled then ACS-enabled so the two can be compared;
# `disable` / `enable` runs only that pass.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPTS_ROOT/lib/common.sh"
# shellcheck source=../lib/html.sh
source "$SCRIPTS_ROOT/lib/html.sh"
# shellcheck source=../config.env
source "$SCRIPTS_ROOT/config.env"

OUTPUT_P2P=${OUTPUT_P2P:-$RUN_DIR/p2p}
mkdir -p "$OUTPUT_P2P"
LOG_FILE="${OUTPUT_P2P}/PF_result.log"
HTML_FILE="${OUTPUT_P2P}/PF_result.html"

resolve_npus

# No pair to test. Exit 75 (EX_TEMPFAIL) reports SKIP, not PASS.
if [[ ${#NPUS[@]} -lt 2 ]]; then
  echo -e "${YELLOW}[p2p] Skipping: P2P Test requires >= 2 NPUs, but ${#NPUS[@]} selected (${NPUS[*]}).${NC}" | tee -a "$LOG_FILE"
  exit 75
fi

save_lspci_info() {
  local label=$1
  echo -e "${BLUE}[$(date +%T)] Saving lspci info for: $label${NC}" | tee -a "$LOG_FILE"
  lspci -tv >"${OUTPUT_P2P}/lspci-topology_${label}.log" || echo "lspci -tv failed" >>"$LOG_FILE"
  lspci -vvv >"${OUTPUT_P2P}/lspci-vvv_${label}.log" || echo "lspci -vvv failed" >>"$LOG_FILE"
}

run_p2p_test() {
  local label=$1 i j now
  local -a rows=()

  echo -e "${CYAN}${BOLD}\n>>> Starting Test: $label <<<\n${NC}" | tee -a "$LOG_FILE"

  for i in "${NPUS[@]}"; do
    for j in "${NPUS[@]}"; do
      [[ "$i" -eq "$j" ]] && continue
      now=$(date +%T)
      step_header "[$now] Testing P2P ($label): ${GREEN}Source $i${NC} -> ${GREEN}Destination $j${NC}"
      hal_bench p2p --npu "$i" --dst-npu "$j" --buffer-size "$P2P_BUFFER_SIZE"
      rows+=("$now|Src $i->Dst $j|$BENCH_LAT|$BENCH_THR")
    done
  done

  local header="Time|P2P Path|Latency (ms)|Throughput (GiB/s)"
  print_summary "P2P TEST SUMMARY REPORT ($label)" "10 15 40 40" "$header" "${rows[@]}" |
    tee -a "$LOG_FILE"
  html_table "$HTML_FILE" "Test Summary: $label" "$header" "${rows[@]}"
}

html_init "$HTML_FILE" "Furiosa P2P Test Report"

echo -e "${BOLD}All results will be saved in: ${YELLOW}$OUTPUT_P2P${NC}" | tee -a "$LOG_FILE"

validate_acs_mode 2>&1 | tee -a "$LOG_FILE"

# In the output dir so it outlives the container: after a bad run it is the only
# record of the pre-run ACSCtl values. Created empty so a restore before
# `--mode save` finds a file.
ACS_STATE_FILE="$(acs_state_file "$OUTPUT_P2P")"
: >"$ACS_STATE_FILE"
# Set once an apply completes (`set -e` aborts on failure).
ACS_APPLY_OK=0

# EXIT handler; INT/TERM only re-exit into it. A single-mode run that ended
# clean leaves ACS as set; everything else restores.
cleanup() {
  # First statement: $? is still the status that triggered the trap.
  local rc=$?
  # Repeat INT/TERM must not cut the restore short (acs.sh inherits SIG_IGN).
  trap '' INT TERM
  if [[ "$rc" -eq 0 && "$ACS_APPLY_OK" -eq 1 ]] &&
    [[ "${ACS_MODE:-}" == "disable" || "${ACS_MODE:-}" == "enable" ]]; then
    echo -e "\n${YELLOW}[cleanup] ACS_MODE=${ACS_MODE:-}: leaving ACS as set (no restore).${NC}" | tee -a "$LOG_FILE" || true
    save_lspci_info "final" || true
  else
    echo -e "\n${YELLOW}[cleanup] Restoring ACS to initial state...${NC}" | tee -a "$LOG_FILE" || true
    if bash "$ACS_SH" --mode restore "$ACS_STATE_FILE" 2>&1 | tee -a "$LOG_FILE"; then
      save_lspci_info "restored" || true
    else
      # Bridges left with ACS off outlive the run -- fail even if the test passed.
      echo -e "\n${RED}[cleanup] ACS restore FAILED -- bridges may be left with ACS disabled.${NC}" | tee -a "$LOG_FILE" || true
      save_lspci_info "restore_failed" || true
      if [[ "$rc" -eq 0 ]]; then rc=1; fi
    fi
  fi

  echo -e "${YELLOW}[cleanup] Pre-run ACS state kept at $(repo_rel "$ACS_STATE_FILE") -- from the repo root, re-apply manually with:${NC}" | tee -a "$LOG_FILE" || true
  echo -e "${YELLOW}[cleanup]   $(acs_rollback_cmd "$ACS_STATE_FILE")${NC}" | tee -a "$LOG_FILE" || true

  capture_dmesg "$OUTPUT_P2P" || true

  if [[ "$rc" -ne 0 ]]; then
    html_note "$HTML_FILE" "<strong>Phase aborted (exit $rc).</strong> Any tables above are incomplete; see <code>PF_result.log</code> for the failure."
  fi

  # rc may have been raised above.
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

save_lspci_info "initial"

bash "$ACS_SH" --mode save "$ACS_STATE_FILE" 2>&1 | tee -a "$LOG_FILE"

ACS_SEQUENCES=(disable enable)
[[ -z "$ACS_MODE" ]] || ACS_SEQUENCES=("$ACS_MODE")

STEP=1
for mode in "${ACS_SEQUENCES[@]}"; do
  echo -e "\n${BOLD}[STEP $STEP] ACS ${mode^} Sequence${NC}" | tee -a "$LOG_FILE"
  # A part-way failure rolls itself back, then `set -e` trips cleanup.
  acs_apply "$mode" "$ACS_STATE_FILE" 2>&1 | tee -a "$LOG_FILE"
  ACS_APPLY_OK=1
  save_lspci_info "ACS_$mode"
  run_p2p_test "after ACS $mode"
  echo >>"$LOG_FILE"
  STEP=$((STEP + 1))
done

html_note "$HTML_FILE" "If you have any questions about the throughput results, please contact Furiosa for support."
print_done "$OUTPUT_P2P"
