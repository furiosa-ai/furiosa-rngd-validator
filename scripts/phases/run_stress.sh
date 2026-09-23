#!/bin/bash
# Hardware stress phase.
# Runs `furiosa-stress-test $STRESS_SCENARIO -d <npu> -t $STRESS_DURATION` on
# every selected NPU in parallel and reports PASS/FAIL per NPU, sampling
# sensors to sensor_log_<TS>.csv throughout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPTS_ROOT/lib/common.sh"
# shellcheck source=../lib/html.sh
source "$SCRIPTS_ROOT/lib/html.sh"
# shellcheck source=../config.env
source "$SCRIPTS_ROOT/config.env"

OUTPUT_STRESS=${OUTPUT_STRESS:-$RUN_DIR/stress}
LOG_STRESS=${LOG_STRESS:-$RUN_DIR/logs/stress}
mkdir -p "$OUTPUT_STRESS" "$LOG_STRESS"

use_furiosa_venv furiosa-stress-test

case "$STRESS_SCENARIO" in
  computation | memory | full) ;;
  *)
    echo -e "${YELLOW}[stress] Invalid STRESS_SCENARIO='$STRESS_SCENARIO'; expected computation|memory|full.${NC}"
    exit 1
    ;;
esac
[[ $STRESS_DURATION =~ ^[1-9][0-9]*$ ]] || {
  echo -e "${YELLOW}[stress] Invalid STRESS_DURATION='$STRESS_DURATION'; expected a positive integer number of seconds.${NC}"
  exit 1
}

resolve_npus

apply_acs_mode "$OUTPUT_STRESS"

# Declared before the traps: cleanup reads it under `set -u`.
declare -a stress_pids=()
# EXIT handler (INT/TERM re-exit into it): stop the workloads and the sampler,
# then drive the ACS rollback, since this trap replaced apply_acs_mode's.
# shellcheck disable=SC2329,SC2317  # invoked via trap
cleanup() {
  local rc=$? # first statement: still the status that triggered the trap
  trap '' INT TERM
  if [[ ${#stress_pids[@]} -gt 0 ]]; then
    echo -e "\n${CYAN}[cleanup] Stopping stress-test processes...${NC}" >&2 || true
    stop_pids "${stress_pids[@]}"
  fi
  stop_sensor_monitor
  acs_restore_if_aborted "${ACS_STATE_FILE:-}" "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

SECONDS=0
start_sensor_monitor "$OUTPUT_STRESS"

echo "=========================================="
echo "Running furiosa-stress-test '$STRESS_SCENARIO' for ${STRESS_DURATION}s on NPUs: ${NPUS[*]}"
echo "=========================================="

for npu in "${NPUS[@]}"; do
  echo "Starting stress test on NPU $npu"
  furiosa-stress-test "$STRESS_SCENARIO" -d "$npu" -t "$STRESS_DURATION" \
    >"$LOG_STRESS/npu${npu}.log" 2>&1 &
  stress_pids[npu]=$!
done

declare -a SUMMARY_DATA=()
for npu in "${NPUS[@]}"; do
  rc=0
  wait "${stress_pids[npu]}" || rc=$?
  if [[ $rc -eq 0 ]]; then
    SUMMARY_DATA+=("NPU $npu|$STRESS_SCENARIO|PASS")
  else
    echo "NPU $npu stress test FAILED (exit $rc)" | tee -a "$LOG_STRESS/npu${npu}.log"
    SUMMARY_DATA+=("NPU $npu|$STRESS_SCENARIO|FAIL")
  fi
done

capture_dmesg "$OUTPUT_STRESS"

rc=0
write_status_report "$OUTPUT_STRESS" "Stress Test Summary" "10 15 6" \
  "NPU|Scenario|Status" "${SUMMARY_DATA[@]}" || rc=$?
exit "$rc"
