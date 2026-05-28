#!/bin/bash
# P2P bandwidth benchmark phase.
# Runs `furiosa-hal-bench p2p` between every NPU pair twice -- once with
# ACS disabled on the upstream Broadcom switches, once with ACS
# re-enabled -- so the two sets of numbers can be compared. The
# EXIT/INT/TERM trap always restores ACS, so an aborted run never leaves
# the host with ACS disabled.

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
        <h2>Benchmark Summary: $label</h2>
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

NPU_COUNT=$(detect_npu_count)
[[ "$NPU_COUNT" -eq 0 ]] && {
  echo -e "${RED}Error: No NPUs found${NC}"
  exit 1
}

save_lspci_info() {
  local label=$1
  echo -e "${BLUE}[$(date +%T)] Saving lspci info for: $label${NC}" | tee -a "$LOG_FILE"
  lspci -tv >"${OUTPUT_P2P}/lspci-topology_${label}.log" || echo "lspci -tv failed" >>"$LOG_FILE"
  lspci -vvv >"${OUTPUT_P2P}/lspci-vvv_${label}.log" || echo "lspci -vvv failed" >>"$LOG_FILE"
}

run_p2p_benchmark() {
  local label=$1
  declare -a SUMMARY_DATA

  echo -e "${CYAN}${BOLD}\n>>> Starting Benchmark: $label <<<\n${NC}" | tee -a "$LOG_FILE"

  for ((i = 0; i < NPU_COUNT; i++)); do
    for ((j = 0; j < NPU_COUNT; j++)); do
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
    echo -e "${CYAN}${BOLD}                                            P2P BENCHMARK SUMMARY REPORT ($label)${NC}"
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

html_init "$HTML_FILE" "Furiosa P2P Benchmark Report"

echo -e "${BOLD}All results will be saved in: ${YELLOW}$OUTPUT_P2P${NC}" | tee -a "$LOG_FILE"

restore_acs() {
  echo -e "\n${YELLOW}[cleanup] Restoring ACS to enabled state...${NC}" | tee -a "$LOG_FILE" || true
  bash "$SCRIPTS_ROOT/lib/acs.sh" --mode enable 2>&1 | tee -a "$LOG_FILE" || true
}
trap restore_acs EXIT INT TERM

echo -e "\n${BOLD}[STEP 1] ACS Disable Sequence${NC}" | tee -a "$LOG_FILE"
bash "$SCRIPTS_ROOT/lib/acs.sh" --mode disable 2>&1 | tee -a "$LOG_FILE"
save_lspci_info "ACS_Disabled"
run_p2p_benchmark "after ACS disable"

echo >>"$LOG_FILE"

echo -e "\n${BOLD}[STEP 2] ACS Enable Sequence${NC}" | tee -a "$LOG_FILE"
bash "$SCRIPTS_ROOT/lib/acs.sh" --mode enable 2>&1 | tee -a "$LOG_FILE"
save_lspci_info "ACS_Enabled"
run_p2p_benchmark "after ACS enable"

echo "<p>If you have any questions about the throughput results, please contact Furiosa for support.</p>" >>"$HTML_FILE"
html_close "$HTML_FILE"

capture_dmesg "$OUTPUT_P2P"

echo -e "\n${GREEN}${BOLD}==========================================================================${NC}"
echo -e "${GREEN}${BOLD}  Test Completed Successfully!${NC}"
echo -e "${BOLD}  All logs and reports are in: ${YELLOW}$OUTPUT_P2P${NC}"
echo -e "${GREEN}${BOLD}==========================================================================${NC}"
