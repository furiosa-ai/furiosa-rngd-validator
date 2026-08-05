#!/bin/bash
# P2P bandwidth test phase.
# Runs `furiosa-hal-bench p2p` between every NPU pair. P2P_ACS_MODE selects
# which ACS configurations to test on all upstream PCI bridges: empty
# runs twice (once ACS disabled, once ACS re-enabled) so the numbers can be
# compared, `disable` runs only the ACS-disabled pass, `enable` only the
# ACS-enabled pass.

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

append_html_section() {
  local label=$1
  shift
  local data=("$@")

  cat <<EOF >>"$HTML_FILE"
    <div class="section">
        <h2>Test Summary: $label</h2>
        <table>
            <tr>
                <th>Time</th>
                <th>P2P Path</th>
                <th>Latency (ms)</th>
                <th>Throughput (GiB/s)</th>
            </tr>
EOF
  for entry in "${data[@]}"; do
    IFS='|' read -r r_time r_path r_lat r_thr <<<"$entry"
    echo "<tr><td>$r_time</td><td>$r_path</td><td class='val-text'>$r_lat</td><td class='val-text'>$r_thr</td></tr>" >>"$HTML_FILE"
  done
  echo "</table></div>" >>"$HTML_FILE"
}

resolve_npus

# P2P needs more than one NPU to test. Skip instead of running an
# empty loop that would leave SUMMARY_DATA empty for the report.
if [[ ${#NPUS[@]} -lt 2 ]]; then
  echo -e "${YELLOW}[p2p] Skipping: P2P Test requires >= 2 NPUs, but ${#NPUS[@]} selected (${NPUS[*]}).${NC}" | tee -a "$LOG_FILE"
  # Exit 75 (EX_TEMPFAIL) signals SKIP to the report generator -- distinct from
  # 0 (PASS) so an unrunnable phase isn't reported as a passing one.
  exit 75
fi

save_lspci_info() {
  local label=$1
  echo -e "${BLUE}[$(date +%T)] Saving lspci info for: $label${NC}" | tee -a "$LOG_FILE"
  lspci -tv >"${OUTPUT_P2P}/lspci-topology_${label}.log" || echo "lspci -tv failed" >>"$LOG_FILE"
  lspci -vvv >"${OUTPUT_P2P}/lspci-vvv_${label}.log" || echo "lspci -vvv failed" >>"$LOG_FILE"
}

run_p2p_test() {
  local label=$1
  declare -a SUMMARY_DATA=()

  echo -e "${CYAN}${BOLD}\n>>> Starting Test: $label <<<\n${NC}" | tee -a "$LOG_FILE"

  for i in "${NPUS[@]}"; do
    for j in "${NPUS[@]}"; do
      [[ "$i" -eq "$j" ]] && continue

      local CURRENT_TIME
      CURRENT_TIME=$(date +%T)

      local STEP_LOG
      STEP_LOG=$(mktemp "${OUTPUT_P2P}/step_p2p_XXXX.tmp")

      echo -e "${BOLD}--------------------------------------------------${NC}" | tee -a "$LOG_FILE"
      echo -e "[$CURRENT_TIME] Testing P2P ($label): ${GREEN}Source $i${NC} -> ${GREEN}Destination $j${NC}" | tee -a "$LOG_FILE"
      echo -e "${BOLD}--------------------------------------------------${NC}" | tee -a "$LOG_FILE"

      furiosa-hal-bench p2p \
        --npu "$i" \
        --dst-npu "$j" \
        --buffer-size "$P2P_BUFFER_SIZE" \
        2>&1 | tee "$STEP_LOG"

      cat "$STEP_LOG" >>"$LOG_FILE"

      CLEAN_OUT=$(sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g" "$STEP_LOG")

      LAT=$(echo "$CLEAN_OUT" | grep "time:" | head -n 1 | grep -o "\[.*\]" || true)
      THR=$(echo "$CLEAN_OUT" | grep "thrpt:" | head -n 1 | grep -o "\[.*\]" || true)

      LAT=${LAT:-"[N/A]"}
      THR=${THR:-"[N/A]"}

      SUMMARY_DATA+=("$CURRENT_TIME|Src $i->Dst $j|$LAT|$THR")

      rm -f "$STEP_LOG"
      echo >>"$LOG_FILE"
    done
  done

  {
    echo
    echo -e "${CYAN}======================================================================================================================================================${NC}"
    echo -e "${CYAN}${BOLD}                                            P2P TEST SUMMARY REPORT ($label)${NC}"
    echo -e "${CYAN}======================================================================================================================================================${NC}"
    printf "${BOLD}%-10s | %-15s | %-40s | %-40s${NC}\n" \
      "Time" "P2P Path" "Latency (ms)" "Throughput (GiB/s)"
    echo -e "${CYAN}------------------------------------------------------------------------------------------------------------------------------------------------------${NC}"

    for entry in "${SUMMARY_DATA[@]}"; do
      IFS='|' read -r r_time r_path r_lat r_thr <<<"$entry"
      printf "%-10s | %-15s | ${GREEN}%-40s${NC} | ${GREEN}%-40s${NC}\n" \
        "$r_time" "$r_path" "$r_lat" "$r_thr"
    done

    echo -e "${CYAN}======================================================================================================================================================${NC}"
  } | tee -a "$LOG_FILE"

  append_html_section "$label" "${SUMMARY_DATA[@]}"
}

html_init "$HTML_FILE" "Furiosa P2P Test Report"

echo -e "${BOLD}All results will be saved in: ${YELLOW}$OUTPUT_P2P${NC}" | tee -a "$LOG_FILE"

case "$P2P_ACS_MODE" in
  "" | disable | enable) ;;
  *)
    echo -e "${YELLOW}[p2p] Invalid P2P_ACS_MODE='$P2P_ACS_MODE'; expected disable|enable (empty runs both).${NC}" | tee -a "$LOG_FILE"
    exit 1
    ;;
esac

# In the run's output dir, not /tmp: on any run that ends badly this file is the
# only record of the pre-run per-bridge ACSCtl values, and it has to outlive the
# container. Created empty up front so a restore in the window before `--mode
# save` runs finds a file rather than erroring.
ACS_STATE_FILE="${OUTPUT_P2P}/acs_init_state"
: >"$ACS_STATE_FILE"
# Set only after an apply sequence completes; `set -e` aborts on failure, so
# reaching the assignment means the host really is in the requested state.
ACS_APPLY_OK=0

# INT/TERM only re-exit so an abort funnels through the EXIT handler instead of
# resuming past the interrupted test into the next ACS step.
#
# A single-mode run (P2P_ACS_MODE=disable|enable) deliberately LEAVES ACS as set,
# so it skips restore -- but only if the sequence succeeded. A part-way failure
# restores like any other abort.
cleanup() {
  # First statement: $? is still the status that triggered the trap.
  local rc=$?
  # Ignore repeat INT/TERM so restore is atomic; the acs.sh child inherits
  # SIG_IGN and cannot be killed mid-restore.
  trap '' INT TERM
  if [[ "$ACS_APPLY_OK" -eq 1 ]] &&
    [[ "${P2P_ACS_MODE:-}" == "disable" || "${P2P_ACS_MODE:-}" == "enable" ]]; then
    echo -e "\n${YELLOW}[cleanup] P2P_ACS_MODE=${P2P_ACS_MODE:-}: leaving ACS as set (no restore).${NC}" | tee -a "$LOG_FILE" || true
    save_lspci_info "final" || true
  else
    echo -e "\n${YELLOW}[cleanup] Restoring ACS to initial state...${NC}" | tee -a "$LOG_FILE" || true
    if bash "$SCRIPTS_ROOT/lib/acs.sh" --mode restore "$ACS_STATE_FILE" 2>&1 | tee -a "$LOG_FILE"; then
      save_lspci_info "restored" || true
    else
      # Bridges left with ACS off outlive the run -- fail even if the test passed.
      echo -e "\n${RED}[cleanup] ACS restore FAILED -- bridges may be left with ACS disabled.${NC}" | tee -a "$LOG_FILE" || true
      save_lspci_info "restore_failed" || true
      if [[ "$rc" -eq 0 ]]; then rc=1; fi
    fi
  fi

  echo -e "${YELLOW}[cleanup] Pre-run ACS state kept at $ACS_STATE_FILE -- re-apply manually with:${NC}" | tee -a "$LOG_FILE" || true
  echo -e "${YELLOW}[cleanup]   sudo bash $SCRIPTS_ROOT/lib/acs.sh --mode restore $ACS_STATE_FILE${NC}" | tee -a "$LOG_FILE" || true

  # Here, not on the happy path: an abort is exactly when dmesg is wanted.
  capture_dmesg "$OUTPUT_P2P" || true

  # Else the report is a P2P heading with no table and no stated reason.
  if [[ "$rc" -ne 0 ]]; then
    cat <<EOF >>"$HTML_FILE"
    <div class="section">
        <p><strong>Phase aborted (exit $rc).</strong> Any tables above are incomplete; see <code>PF_result.log</code> for the failure.</p>
    </div>
EOF
  fi

  # Explicit: rc may have been raised above, and the shell would otherwise exit
  # with the status that triggered the trap.
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

save_lspci_info "initial"

# Up front, so the EXIT trap can restore no matter which sequences below ran.
bash "$SCRIPTS_ROOT/lib/acs.sh" --mode save "$ACS_STATE_FILE" 2>&1 | tee -a "$LOG_FILE"

if [[ -z "$P2P_ACS_MODE" || "$P2P_ACS_MODE" == disable ]]; then
  echo -e "\n${BOLD}[STEP 1] ACS Disable Sequence${NC}" | tee -a "$LOG_FILE"
  bash "$SCRIPTS_ROOT/lib/acs.sh" --mode disable 2>&1 | tee -a "$LOG_FILE"
  ACS_APPLY_OK=1
  save_lspci_info "ACS_Disabled"
  run_p2p_test "after ACS disable"
  echo >>"$LOG_FILE"
fi

if [[ -z "$P2P_ACS_MODE" || "$P2P_ACS_MODE" == enable ]]; then
  echo -e "\n${BOLD}[STEP 2] ACS Enable Sequence${NC}" | tee -a "$LOG_FILE"
  bash "$SCRIPTS_ROOT/lib/acs.sh" --mode enable 2>&1 | tee -a "$LOG_FILE"
  ACS_APPLY_OK=1
  save_lspci_info "ACS_Enabled"
  run_p2p_test "after ACS enable"
fi

cat <<EOF >>"$HTML_FILE"
    <div class="section">
        <p>If you have any questions about the throughput results, please contact Furiosa for support.</p>
    </div>
EOF

echo -e "\n${GREEN}${BOLD}==========================================================================${NC}"
echo -e "${GREEN}${BOLD}  Test Completed Successfully!${NC}"
echo -e "${BOLD}  All logs and reports are in: ${YELLOW}$OUTPUT_P2P${NC}"
echo -e "${GREEN}${BOLD}==========================================================================${NC}"