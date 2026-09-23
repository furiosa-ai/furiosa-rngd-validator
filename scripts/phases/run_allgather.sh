#!/bin/bash
# Allgather bandwidth benchmark phase.
# Runs `furiosa-hal-bench allgather` over the npu_groups of each size in
# $ALLGATHER_GROUP_SIZES. A size larger than the selected NPU count is skipped;
# if every size is, the phase reports SKIP (exit 75).

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

resolve_npus

html_init "$HTML_FILE" "Furiosa Allgather Benchmark Report"

echo -e "${BOLD}All results will be saved in: ${YELLOW}$OUTPUT_ALLGATHER${NC}" | tee -a "$LOG_FILE"

# Redirected, not piped: in a pipeline subshell its rollback traps would die.
apply_acs_mode "$OUTPUT_ALLGATHER" > >(tee -a "$LOG_FILE") 2>&1

IFS=',' read -ra GROUP_SIZES <<<"$ALLGATHER_GROUP_SIZES"

declare -a SUMMARY_DATA=()

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
    npus_csv="${group// /,}"
    step_header "[$(date +%T)] Allgather (size $size): ${GREEN}NPUs $npus_csv${NC}"
    hal_bench allgather --npus "$npus_csv" --buffer-size "$ALLGATHER_BUFFER_SIZE"
    SUMMARY_DATA+=("size $size - NPUs $npus_csv|$BENCH_LAT|$BENCH_THR")
  done < <(npu_groups "$size")
done

if [[ ${#SUMMARY_DATA[@]} -eq 0 ]]; then
  echo -e "${YELLOW}[allgather] Skipping: no group size in '$ALLGATHER_GROUP_SIZES' fits ${#NPUS[@]} selected NPU(s).${NC}" | tee -a "$LOG_FILE"
  exit 75
fi

HEADER="NPU Group|Latency (ms)|Throughput (GiB/s)"
print_summary "ALLGATHER BENCHMARK SUMMARY REPORT" "20 40 40" "$HEADER" "${SUMMARY_DATA[@]}" |
  tee -a "$LOG_FILE"
html_table "$HTML_FILE" "Benchmark Summary: allgather" "$HEADER" "${SUMMARY_DATA[@]}"
html_note "$HTML_FILE" "If you have any questions about the throughput results, please contact Furiosa for support."

capture_dmesg "$OUTPUT_ALLGATHER"
print_done "$OUTPUT_ALLGATHER"
