#!/bin/bash
# Allgather bandwidth benchmark phase.
# Runs `furiosa-hal-bench allgather` over NPU groups of each size in
# $ALLGATHER_GROUP_SIZES (default 4). Grouping follows common.sh
# npu_groups: exact multiples chunk non-overlapping, otherwise a final group is
# anchored at the last NPU so both the first and last NPU are exercised. A group
# size larger than the selected NPU count is skipped; if every size is skipped
# the phase reports SKIP (exit 75) rather than fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPTS_ROOT/lib/common.sh"
# shellcheck source=../lib/html.sh
source "$SCRIPTS_ROOT/lib/html.sh"
# shellcheck source=../config.env
source "$SCRIPTS_ROOT/config.env"

OUTPUT_ALLGATHER=${OUTPUT_ALLGATHER:-$RUN_DIR/allgather}
mkdir -p "$OUTPUT_ALLGATHER"
LOG_FILE="${OUTPUT_ALLGATHER}/PF_result.log"
HTML_FILE="${OUTPUT_ALLGATHER}/PF_result.html"

append_html_section() {
  local label=$1
  shift
  local data=("$@")

  cat <<EOF >>"$HTML_FILE"
    <div class="section">
        <h2>Benchmark Summary: $label</h2>
        <table>
            <tr>
                <th>NPU Group</th>
                <th>Latency (ms)</th>
                <th>Throughput (GiB/s)</th>
            </tr>
EOF
  for entry in "${data[@]}"; do
    IFS='|' read -r r_group r_lat r_thr <<<"$entry"
    echo "<tr><td>$r_group</td><td class='val-text'>$r_lat</td><td class='val-text'>$r_thr</td></tr>" >>"$HTML_FILE"
  done
  echo "</table></div>" >>"$HTML_FILE"
}

resolve_npus

html_init "$HTML_FILE" "Furiosa Allgather Benchmark Report"

echo -e "${BOLD}All results will be saved in: ${YELLOW}$OUTPUT_ALLGATHER${NC}" | tee -a "$LOG_FILE"

IFS=',' read -ra GROUP_SIZES <<<"$ALLGATHER_GROUP_SIZES"

declare -a SUMMARY_DATA=()
RAN_ANY=0

for raw_size in "${GROUP_SIZES[@]}"; do
  size=${raw_size//[[:space:]]/}
  [[ $size =~ ^[0-9]+$ ]] || {
    echo -e "${YELLOW}[allgather] Invalid ALLGATHER_GROUP_SIZES entry '$raw_size' (ALLGATHER_GROUP_SIZES='$ALLGATHER_GROUP_SIZES'); expected comma-separated integers >= 2.${NC}" | tee -a "$LOG_FILE"
    exit 1
  }
  ((size >= 2)) || {
    echo -e "${YELLOW}[allgather] Invalid group size $size: must be >= 2.${NC}" | tee -a "$LOG_FILE"
    exit 1
  }
  if ((size > ${#NPUS[@]})); then
    echo -e "${YELLOW}[allgather] Skipping group size $size: requires $size NPUs, but ${#NPUS[@]} selected (${NPUS[*]}).${NC}" | tee -a "$LOG_FILE"
    continue
  fi

  echo -e "${CYAN}${BOLD}\n>>> Allgather group size: $size <<<\n${NC}" | tee -a "$LOG_FILE"

  while read -r group; do
    RAN_ANY=1
    npus_csv="${group// /,}"

    STEP_LOG=$(mktemp "${OUTPUT_ALLGATHER}/step_allgather_XXXX.tmp")

    echo -e "${BOLD}--------------------------------------------------${NC}" | tee -a "$LOG_FILE"
    echo -e "[$(date +%T)] Allgather (size $size): ${GREEN}NPUs $npus_csv${NC}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}--------------------------------------------------${NC}" | tee -a "$LOG_FILE"

    furiosa-hal-bench allgather \
      --npus "$npus_csv" \
      --buffer-size "$ALLGATHER_BUFFER_SIZE" \
      2>&1 | tee "$STEP_LOG"

    cat "$STEP_LOG" >>"$LOG_FILE"

    CLEAN_OUT=$(sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g" "$STEP_LOG")
    LAT=$(echo "$CLEAN_OUT" | grep "time:" | head -n 1 | grep -o "\[.*\]" || true)
    THR=$(echo "$CLEAN_OUT" | grep "thrpt:" | head -n 1 | grep -o "\[.*\]" || true)
    LAT=${LAT:-"[N/A]"}
    THR=${THR:-"[N/A]"}

    SUMMARY_DATA+=("size $size - NPUs $npus_csv|$LAT|$THR")

    rm -f "$STEP_LOG"
    echo >>"$LOG_FILE"
  done < <(npu_groups "$size")
done

if [[ "$RAN_ANY" -eq 0 ]]; then
  echo -e "${YELLOW}[allgather] Skipping: no group size in '$ALLGATHER_GROUP_SIZES' fits ${#NPUS[@]} selected NPU(s).${NC}" | tee -a "$LOG_FILE"
  # Exit 75 (EX_TEMPFAIL) signals SKIP to the report generator -- distinct from
  # 0 (PASS) so an unrunnable phase isn't reported as a passing one.
  exit 75
fi

{
  echo
  echo -e "${CYAN}======================================================================================================================${NC}"
  echo -e "${CYAN}${BOLD}                                            ALLGATHER BENCHMARK SUMMARY REPORT${NC}"
  echo -e "${CYAN}======================================================================================================================${NC}"
  printf "${BOLD}%-20s | %-40s | %-40s${NC}\n" "NPU Group" "Latency (ms)" "Throughput (GiB/s)"
  echo -e "${CYAN}----------------------------------------------------------------------------------------------------------------------${NC}"
  for entry in "${SUMMARY_DATA[@]}"; do
    IFS='|' read -r r_group r_lat r_thr <<<"$entry"
    printf "%-20s | ${GREEN}%-40s${NC} | ${GREEN}%-40s${NC}\n" "$r_group" "$r_lat" "$r_thr"
  done
  echo -e "${CYAN}======================================================================================================================${NC}"
} | tee -a "$LOG_FILE"

append_html_section "allgather" "${SUMMARY_DATA[@]}"

cat <<EOF >>"$HTML_FILE"
    <div class="section">
        <p>If you have any questions about the throughput results, please contact Furiosa for support.</p>
    </div>
EOF

capture_dmesg "$OUTPUT_ALLGATHER"

echo -e "\n${GREEN}${BOLD}==========================================================================${NC}"
echo -e "${GREEN}${BOLD}  Test Completed Successfully!${NC}"
echo -e "${BOLD}  All logs and reports are in: ${YELLOW}$OUTPUT_ALLGATHER${NC}"
echo -e "${GREEN}${BOLD}==========================================================================${NC}"
