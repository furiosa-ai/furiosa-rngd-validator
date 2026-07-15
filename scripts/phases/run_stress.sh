#!/bin/bash
# Hardware stress phase.
# Runs `furiosa-stress-test $STRESS_SCENARIO -d <npu> -t $STRESS_DURATION` on
# every selected NPU in parallel and reports PASS/FAIL per NPU. A background
# sensor sampler writes SoC/HBM/power readings to sensor_log_<TS>.csv for the
# full duration.

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

export PATH="$HOME/.local/bin:$PATH"

if [[ -f "${FURIOSA_VENV}/bin/activate" ]]; then
  # shellcheck source=/dev/null
  source "${FURIOSA_VENV}/bin/activate"
fi
if ! command -v furiosa-stress-test &>/dev/null; then
  echo "Error: furiosa-stress-test not found. Set FURIOSA_VENV to the virtualenv path." >&2
  exit 1
fi

case "$STRESS_SCENARIO" in
  computation | memory | full) ;;
  *)
    echo -e "${YELLOW}[stress] Invalid STRESS_SCENARIO='$STRESS_SCENARIO'; expected computation|memory|full.${NC}"
    exit 1
    ;;
esac

resolve_npus

MONITOR_PID=""
# Initialized before the traps so cleanup can safely reference it under `set -u`
# even if a signal arrives before any stress test is launched.
declare -a stress_pids=()
# Cleanup runs on EXIT only; INT/TERM re-exit through it. An aborted run would
# otherwise orphan the background furiosa-stress-test workloads on the NPUs.
# SC2329 (never invoked) / SC2317 (unreachable) -- cleanup runs via the trap
# below, an indirection shellcheck cannot follow.
# shellcheck disable=SC2329,SC2317
cleanup() {
  # Ignore repeat INT/TERM so teardown completes atomically; children inherit
  # this SIG_IGN across exec.
  trap '' INT TERM
  if [[ ${#stress_pids[@]} -gt 0 ]]; then
    echo -e "\n${CYAN}[cleanup] Stopping stress-test processes...${NC}" >&2 || true
    for pid in "${stress_pids[@]}"; do
      [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null || true
    done
    pkill -f furiosa-stress-test 2>/dev/null || true
  fi
  if [[ -n "${MONITOR_PID:-}" ]] && kill -0 "$MONITOR_PID" 2>/dev/null; then
    echo -e "${CYAN}[cleanup] Stopping sensor monitor (PID: $MONITOR_PID)${NC}" >&2 || true
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

SECONDS=0

python3 "$SCRIPTS_ROOT/lib/sensor_monitor.py" --output "$OUTPUT_STRESS" --timestamp "$TIMESTAMP" --interval "$SENSOR_POLL_INTERVAL" &
MONITOR_PID=$!
echo -e "${CYAN}NPU Sensor Monitoring started (PID: $MONITOR_PID)${NC}"

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
FAILED=0
for npu in "${NPUS[@]}"; do
  rc=0
  wait "${stress_pids[npu]}" || rc=$?
  if [[ $rc -eq 0 ]]; then
    SUMMARY_DATA+=("NPU $npu|$STRESS_SCENARIO|PASS")
  else
    echo "NPU $npu stress test FAILED (exit $rc)" | tee -a "$LOG_STRESS/npu${npu}.log"
    SUMMARY_DATA+=("NPU $npu|$STRESS_SCENARIO|FAIL")
    FAILED=1
  fi
done

capture_dmesg "$OUTPUT_STRESS"

DURATION_SECONDS=$SECONDS
TOTAL_DURATION=$(printf '%02d:%02d:%02d' $((DURATION_SECONDS / 3600)) $((DURATION_SECONDS % 3600 / 60)) $((DURATION_SECONDS % 60)))

SUMMARY_LOG="${OUTPUT_STRESS}/PF_result.log"
HTML_REPORT="${OUTPUT_STRESS}/PF_result.html"

{
  echo -e "${CYAN}${BOLD}STRESS TEST SUMMARY${NC}"
  printf "%-10s | %-15s | %-5s\n" "NPU" "Scenario" "Stat"
  for row in "${SUMMARY_DATA[@]}"; do
    IFS='|' read -r n scenario s <<<"$row"
    printf "%-10s | %-15s | %-5s\n" "$n" "$scenario" "$s"
  done
  echo "Total Duration: $TOTAL_DURATION"
  if [[ $FAILED -eq 1 ]]; then
    echo -e "${RED}${BOLD}Some tests FAILED${NC}"
  else
    echo -e "${GREEN}${BOLD}All tests PASSED${NC}"
  fi
} | tee "$SUMMARY_LOG"

html_init "$HTML_REPORT" "Furiosa Stress Test Summary"
echo "    <p><strong>Total Duration:</strong> $TOTAL_DURATION</p>" >>"$HTML_REPORT"

{
  echo '    <table>'
  echo '        <thead><tr><th>NPU</th><th>Scenario</th><th>Status</th></tr></thead>'
  echo '        <tbody>'
  for row in "${SUMMARY_DATA[@]}"; do
    IFS='|' read -r n scenario s <<<"$row"
    status_class=$([[ "$s" = "PASS" ]] && echo "pass" || echo "fail")
    echo "            <tr><td>$n</td><td>$scenario</td><td class=\"$status_class\">$s</td></tr>"
  done
  echo '        </tbody>'
  echo '    </table>'
  echo '    <div class="footer">'
  if [[ $FAILED -eq 1 ]]; then
    echo "        <span class='fail'>RESULT: Some tests FAILED</span>"
  else
    echo "        <span class='pass'>RESULT: All tests PASSED</span>"
  fi
  echo '    </div>'
} >>"$HTML_REPORT"

echo -e "HTML report saved to: ${YELLOW}$HTML_REPORT${NC}"

exit "$FAILED"
