#!/bin/bash
# LLM serving stress phase.
# For each model in $STRESS_MODELS, launches `furiosa-llm serve` on every
# detected NPU in parallel, waits for /v1/models readiness, runs the
# random and ShareGPT benchmarks concurrently across NPUs, then
# tears down the serve processes. A background sensor sampler writes
# SoC/HBM/power readings to sensor_log_<TS>.csv for the full duration.

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
if ! command -v furiosa-llm &>/dev/null; then
  echo "Error: furiosa-llm not found. Set FURIOSA_VENV to the virtualenv path." >&2
  exit 1
fi

if [[ ! -x "${VLLM_VENV}/bin/vllm" ]]; then
  echo "Error: vllm not found in ${VLLM_VENV}. Set VLLM_VENV to the vllm virtualenv path." >&2
  exit 1
fi

if [[ ! -f "ShareGPT_V3_unfiltered_cleaned_split.json" ]]; then
  wget https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered/resolve/main/ShareGPT_V3_unfiltered_cleaned_split.json
fi

declare -a SUMMARY_DATA=()

resolve_npus

IFS=',' read -ra MODELS <<<"$STRESS_MODELS"

get_model_id() {
  local port=$1
  curl -sf "http://localhost:$port/v1/models" |
    jq -r '.data[0].id // empty'
}

check_models_up() {
  local ports=("$@")
  local max_attempts="$SERVE_READY_MAX_ATTEMPTS"
  local interval="$SERVE_READY_INTERVAL"
  local attempt=1

  echo "Checking if all models are up on ports: ${ports[*]}"
  while [[ $attempt -le $max_attempts ]]; do
    local all_up=true
    for port in "${ports[@]}"; do
      model_id=$(get_model_id "$port" || true)
      if [[ -n "$model_id" ]]; then
        echo -e "${GREEN}Model on port $port is up (id: $model_id)${NC}"
      else
        echo -e "${YELLOW}Model on port $port not ready yet...${NC}"
        all_up=false
        break
      fi
    done

    [[ "$all_up" = true ]] && {
      echo "All models are up!"
      return 0
    }

    if [[ $attempt -lt $max_attempts ]]; then
      echo -e "${YELLOW}Attempt $attempt/$max_attempts: Not all models are up, waiting ${interval} seconds...${NC}"
      sleep "$interval"
    fi
    attempt=$((attempt + 1))
  done

  echo -e "${RED}Failed to start all models after $max_attempts attempts${NC}"
  return 1
}

stop_serving() {
  local pids=("$@")
  for pid in "${pids[@]}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "Stopping serving process $pid"
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  pkill -f "furiosa-llm serve" 2>/dev/null || true
  sleep 2
}

run_random_benchmark() {
  local port=$1
  local model_results_dir=$2

  local PRETRAINED_ID
  PRETRAINED_ID=$(get_model_id "$port") || return 1

  [[ -n "$PRETRAINED_ID" ]] || {
    echo "Error: could not fetch model id (port=$port)"
    return 1
  }

  local triples
  IFS=',' read -ra triples <<<"$STRESS_RANDOM_TRIPLES"

  for triple in "${triples[@]}"; do
    IFS=':' read -r in_len out_len conc <<<"$triple"
    echo "Random benchmark: in=$in_len out=$out_len conc=$conc"

    "${VLLM_VENV}/bin/vllm" bench serve \
      --backend vllm \
      --model "$PRETRAINED_ID" \
      --port "$port" \
      --dataset-name random \
      --random-input-len "$in_len" \
      --random-output-len "$out_len" \
      --max-concurrency "$conc" \
      --num-prompts "$conc" \
      --result-dir "$model_results_dir" \
      --percentile-metrics "ttft,tpot,itl,e2el" \
      --metric-percentiles "25,50,75,90,95,99" \
      --save-result || {
      rc=$?
      echo "vllm bench (random) failed (exit $rc) for in=$in_len out=$out_len conc=$conc" >&2
      return $rc
    }
  done
}

run_sharegpt_benchmark() {
  local port=$1
  local model_results_dir=$2

  local PRETRAINED_ID
  PRETRAINED_ID=$(get_model_id "$port") || return 1

  [[ -n "$PRETRAINED_ID" ]] || {
    echo "Error: could not fetch model id (port=$port)"
    return 1
  }

  "${VLLM_VENV}/bin/vllm" bench serve \
    --backend vllm \
    --model "$PRETRAINED_ID" \
    --port "$port" \
    --dataset-name sharegpt \
    --dataset-path "ShareGPT_V3_unfiltered_cleaned_split.json" \
    --num-prompts 1000 \
    --request-rate 32 \
    --seed 0 \
    --result-dir "$model_results_dir" \
    --percentile-metrics "ttft,tpot,itl,e2el" \
    --metric-percentiles "25,50,75,90,95,99" \
    --save-result || {
    rc=$?
    echo "vllm bench (sharegpt) failed (exit $rc)" >&2
    return $rc
  }
}

MONITOR_PID=""
declare -a serve_pids=()
declare -a serve_ports=()

# Cleanup runs on EXIT only. INT/TERM just re-exit so that an aborted run
# funnels through the EXIT handler instead of resuming past the interrupted
# workload (which would leave serving processes and the sensor monitor running).
# SC2329 (function never invoked) -- cleanup runs via `trap` below; shellcheck
# cannot follow indirect trap invocations.
# SC2317 (command unreachable) -- shellcheck cannot follow control flow past
# `trap '' INT TERM` inside the handler.
# shellcheck disable=SC2329,SC2317
cleanup() {
  # Ignore repeat INT/TERM so teardown completes atomically; children inherit
  # this SIG_IGN across exec.
  trap '' INT TERM
  if [[ ${#serve_pids[@]} -gt 0 ]]; then
    echo -e "\n${CYAN}[cleanup] Stopping serving processes...${NC}" >&2 || true
    stop_serving "${serve_pids[@]}" || true
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

for model_entry in "${MODELS[@]}"; do
  IFS=':' read -r model_name model_org <<<"$model_entry"
  model="$model_name $model_org"
  echo "=========================================="
  echo "Processing model: $model"
  echo "=========================================="

  serve_pids=()
  serve_ports=()

  for npu in "${NPUS[@]}"; do
    port=$((STRESS_BASE_PORT + npu))
    mkdir -p "$LOG_STRESS/${model}/npu${npu}"
    echo "Starting $model on NPU $npu (port $port)"

    furiosa_model_name="furiosa-ai/$model_name"
    served_model_name="$model_org/$model_name"
    PYTHONUNBUFFERED=1 furiosa-llm serve "$furiosa_model_name" \
      --devices "npu:$npu" \
      --port "$port" \
      --revision "$STRESS_REVISION" \
      --served-model-name "$served_model_name" \
      >"$LOG_STRESS/${model}/npu${npu}/serve.log" 2>&1 &

    serve_pids[npu]=$!
    serve_ports[npu]=$port
  done

  sleep 5

  if ! check_models_up "${serve_ports[@]}"; then
    echo "Model startup failed"
    stop_serving "${serve_pids[@]}"
    for npu in "${NPUS[@]}"; do
      SUMMARY_DATA+=("$model|NPU $npu|Random+ShareGPT|FAIL")
    done
    continue
  fi

  declare -a random_pids=()
  for npu in "${NPUS[@]}"; do
    result_dir="$OUTPUT_STRESS/${model}/npu${npu}"
    mkdir -p "$result_dir"
    run_random_benchmark "${serve_ports[npu]}" "$result_dir" >"$LOG_STRESS/${model}/npu${npu}/random.log" 2>&1 &
    random_pids[npu]=$!
  done

  declare -a random_results=()
  for npu in "${NPUS[@]}"; do
    rc=0
    wait "${random_pids[npu]}" || rc=$?
    random_results[npu]=$rc
    if [[ $rc -ne 0 ]]; then
      echo "NPU $npu random benchmark FAILED (exit $rc)" | tee -a "$LOG_STRESS/${model}/npu${npu}/random.log"
    fi
  done

  declare -a sharegpt_pids=()
  for npu in "${NPUS[@]}"; do
    result_dir="$OUTPUT_STRESS/${model}/npu${npu}"
    mkdir -p "$result_dir"
    run_sharegpt_benchmark "${serve_ports[npu]}" "$result_dir" >"$LOG_STRESS/${model}/npu${npu}/sharegpt.log" 2>&1 &
    sharegpt_pids[npu]=$!
  done

  for npu in "${NPUS[@]}"; do
    sharegpt_result=0
    wait "${sharegpt_pids[npu]}" || sharegpt_result=$?
    if [[ $sharegpt_result -ne 0 ]]; then
      echo "NPU $npu sharegpt benchmark FAILED (exit $sharegpt_result)" | tee -a "$LOG_STRESS/${model}/npu${npu}/sharegpt.log"
    fi
    if [[ ${random_results[npu]} -eq 0 ]] && [[ $sharegpt_result -eq 0 ]]; then
      SUMMARY_DATA+=("$model|NPU $npu|Random+ShareGPT|PASS")
    else
      SUMMARY_DATA+=("$model|NPU $npu|Random+ShareGPT|FAIL")
    fi
  done

  stop_serving "${serve_pids[@]}"
done

capture_dmesg "$OUTPUT_STRESS"

DURATION_SECONDS=$SECONDS
TOTAL_DURATION=$(printf '%02d:%02d:%02d' $((DURATION_SECONDS / 3600)) $((DURATION_SECONDS % 3600 / 60)) $((DURATION_SECONDS % 60)))

SUMMARY_LOG="${OUTPUT_STRESS}/PF_result.log"
HTML_REPORT="${OUTPUT_STRESS}/PF_result.html"

FAILED=0
for row in "${SUMMARY_DATA[@]}"; do
  [[ "$row" == *"|FAIL" ]] && FAILED=1
done

{
  echo -e "${CYAN}${BOLD}STRESS TEST SUMMARY${NC}"
  printf "%-30s | %-10s | %-20s | %-5s\n" "Model" "NPU" "Test" "Stat"

  for row in "${SUMMARY_DATA[@]}"; do
    IFS='|' read -r m n test s <<<"$row"
    printf "%-30s | %-10s | %-20s | %-5s\n" "$m" "$n" "$test" "$s"
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
  echo '        <thead>'
  echo '            <tr>'
  echo '                <th>Model</th>'
  echo '                <th>NPU</th>'
  echo '                <th>Test</th>'
  echo '                <th>Status</th>'
  echo '            </tr>'
  echo '        </thead>'
  echo '        <tbody>'

  for row in "${SUMMARY_DATA[@]}"; do
    IFS='|' read -r m n test s <<<"$row"
    status_class=$([[ "$s" = "PASS" ]] && echo "pass" || echo "fail")
    echo "            <tr><td>$m</td><td>$n</td><td>$test</td><td class=\"$status_class\">$s</td></tr>"
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

html_close "$HTML_REPORT"

echo -e "HTML report saved to: ${YELLOW}$HTML_REPORT${NC}"

exit "$FAILED"
