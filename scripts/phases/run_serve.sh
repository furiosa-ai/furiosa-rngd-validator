#!/bin/bash
# LLM serving phase.
# For each model in $SERVE_MODELS, launches `furiosa-llm serve` on every
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

OUTPUT_SERVE=${OUTPUT_SERVE:-$RUN_DIR/serve}
LOG_SERVE=${LOG_SERVE:-$RUN_DIR/logs/serve}
mkdir -p "$OUTPUT_SERVE" "$LOG_SERVE"

export PATH="$HOME/.local/bin:$PATH"

if [[ -f "${FURIOSA_VENV}/bin/activate" ]]; then
  # shellcheck source=/dev/null
  source "${FURIOSA_VENV}/bin/activate"
fi
if ! command -v furiosa-llm &>/dev/null; then
  echo "Error: furiosa-llm not found. Set FURIOSA_VENV to the virtualenv path." >&2
  exit 1
fi
if ! command -v hf &>/dev/null; then
  echo "Error: hf CLI not found. Set FURIOSA_VENV to a virtualenv with huggingface_hub." >&2
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

IFS=',' read -ra MODELS <<<"$SERVE_MODELS"

# Pre-fetch weights into the (mounted) HF cache up front. `hf download` is
# cache-aware -- it verifies each file and fetches only what is missing, so a
# warm cache is a no-op; a cold cache fails fast here instead of mid-serve.
# Skip models whose tp exceeds the NPU count -- the serve loop skips them too.
for model_entry in "${MODELS[@]}"; do
  IFS=':' read -r model_name _ tp <<<"$model_entry"
  ((${tp:-1} > ${#NPUS[@]})) && continue
  echo -e "${CYAN}Pre-fetching furiosa-ai/$model_name (revision $SERVE_REVISION)...${NC}"
  hf download "furiosa-ai/$model_name" --revision "$SERVE_REVISION"
done

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
  IFS=',' read -ra triples <<<"$SERVE_RANDOM_TRIPLES"

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

# Fill the GROUP_* arrays (one entry per serve instance) from the tp-way NPU
# groups produced by npu_groups (see common.sh for the grouping rule). tp=1
# yields one group per NPU -- the original per-NPU behaviour.
declare -a GROUP_NPUS=() GROUP_LABEL=() GROUP_TAG=() GROUP_PORT=() GROUP_DEVICES=()
build_tp_groups() {
  local tp=$1
  GROUP_NPUS=() GROUP_LABEL=() GROUP_TAG=() GROUP_PORT=() GROUP_DEVICES=()
  local group
  while read -r group; do
    GROUP_NPUS+=("$group")
    GROUP_LABEL+=("${group// /,}")
    GROUP_TAG+=("npu${group// /_}")
    GROUP_PORT+=($((SERVE_BASE_PORT + ${group%% *})))
    GROUP_DEVICES+=("npu:${group// /,npu:}")
  done < <(npu_groups "$tp")
}

# Greedily pack group indices into batches that share no NPU, so groups in the
# same batch can serve/benchmark in parallel without double-booking a device.
# tp=1 collapses to a single batch of all NPUs (the original parallel run);
# overlapping tp groups (the remainder case above) fall into separate batches
# and thus run sequentially.
declare -a BATCHES=()
build_batches() {
  BATCHES=()
  local -a batch_used=()
  local gi npu b placed
  for gi in "${!GROUP_NPUS[@]}"; do
    placed=-1
    for ((b = 0; b < ${#BATCHES[@]}; b++)); do
      local conflict=0
      for npu in ${GROUP_NPUS[gi]}; do
        [[ "${batch_used[b]}" == *" $npu "* ]] && {
          conflict=1
          break
        }
      done
      ((conflict == 0)) && {
        placed=$b
        break
      }
    done
    if ((placed < 0)); then
      BATCHES+=("$gi")
      batch_used+=(" ${GROUP_NPUS[gi]} ")
    else
      BATCHES[placed]="${BATCHES[placed]} $gi"
      batch_used[placed]="${batch_used[placed]}${GROUP_NPUS[gi]} "
    fi
  done
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

python3 "$SCRIPTS_ROOT/lib/sensor_monitor.py" --output "$OUTPUT_SERVE" --timestamp "$TIMESTAMP" --interval "$SENSOR_POLL_INTERVAL" &
MONITOR_PID=$!
echo -e "${CYAN}NPU Sensor Monitoring started (PID: $MONITOR_PID)${NC}"

for model_entry in "${MODELS[@]}"; do
  IFS=':' read -r model_name model_org tp <<<"$model_entry"
  tp=${tp:-1}
  model="$model_name $model_org"
  echo "=========================================="
  echo "Processing model: $model (tp=$tp)"
  echo "=========================================="

  # A tp-way model needs tp NPUs; skip cleanly when fewer are selected rather
  # than fail (matches the p2p phase's SKIP-on-insufficient-hardware behaviour).
  if ((tp > ${#NPUS[@]})); then
    echo -e "${YELLOW}Skipping $model: tp=$tp requires $tp NPUs, but ${#NPUS[@]} selected (${NPUS[*]}).${NC}"
    SUMMARY_DATA+=("$model|NPU -|Random+ShareGPT|SKIP")
    continue
  fi

  build_tp_groups "$tp"
  build_batches

  for batch in "${BATCHES[@]}"; do
    # batch is a space-separated list of group indices that share no NPU.
    read -ra group_idxs <<<"$batch"

    serve_pids=()
    serve_ports=()
    for g in "${group_idxs[@]}"; do
      tag=${GROUP_TAG[g]}
      port=${GROUP_PORT[g]}
      mkdir -p "$LOG_SERVE/${model}/${tag}"
      echo "Starting $model on NPU ${GROUP_LABEL[g]} (port $port, devices ${GROUP_DEVICES[g]})"

      furiosa_model_name="furiosa-ai/$model_name"
      served_model_name="$model_org/$model_name"
      PYTHONUNBUFFERED=1 furiosa-llm serve "$furiosa_model_name" \
        --devices "${GROUP_DEVICES[g]}" \
        --tensor-parallel-size "$tp" \
        --port "$port" \
        --revision "$SERVE_REVISION" \
        --served-model-name "$served_model_name" \
        >"$LOG_SERVE/${model}/${tag}/serve.log" 2>&1 &

      serve_pids[g]=$!
      serve_ports[g]=$port
    done

    sleep 5

    batch_ports=()
    for g in "${group_idxs[@]}"; do batch_ports+=("${serve_ports[g]}"); done
    if ! check_models_up "${batch_ports[@]}"; then
      echo "Model startup failed"
      batch_pids=()
      for g in "${group_idxs[@]}"; do batch_pids+=("${serve_pids[g]}"); done
      stop_serving "${batch_pids[@]}"
      for g in "${group_idxs[@]}"; do
        SUMMARY_DATA+=("$model|NPU ${GROUP_LABEL[g]}|Random+ShareGPT|FAIL")
      done
      continue
    fi

    declare -a random_pids=()
    for g in "${group_idxs[@]}"; do
      result_dir="$OUTPUT_SERVE/${model}/${GROUP_TAG[g]}"
      mkdir -p "$result_dir"
      run_random_benchmark "${serve_ports[g]}" "$result_dir" >"$LOG_SERVE/${model}/${GROUP_TAG[g]}/random.log" 2>&1 &
      random_pids[g]=$!
    done

    declare -a random_results=()
    for g in "${group_idxs[@]}"; do
      rc=0
      wait "${random_pids[g]}" || rc=$?
      random_results[g]=$rc
      if [[ $rc -ne 0 ]]; then
        echo "NPU ${GROUP_LABEL[g]} random benchmark FAILED (exit $rc)" | tee -a "$LOG_SERVE/${model}/${GROUP_TAG[g]}/random.log"
      fi
    done

    declare -a sharegpt_pids=()
    for g in "${group_idxs[@]}"; do
      result_dir="$OUTPUT_SERVE/${model}/${GROUP_TAG[g]}"
      mkdir -p "$result_dir"
      run_sharegpt_benchmark "${serve_ports[g]}" "$result_dir" >"$LOG_SERVE/${model}/${GROUP_TAG[g]}/sharegpt.log" 2>&1 &
      sharegpt_pids[g]=$!
    done

    for g in "${group_idxs[@]}"; do
      sharegpt_result=0
      wait "${sharegpt_pids[g]}" || sharegpt_result=$?
      if [[ $sharegpt_result -ne 0 ]]; then
        echo "NPU ${GROUP_LABEL[g]} sharegpt benchmark FAILED (exit $sharegpt_result)" | tee -a "$LOG_SERVE/${model}/${GROUP_TAG[g]}/sharegpt.log"
      fi
      if [[ ${random_results[g]} -eq 0 ]] && [[ $sharegpt_result -eq 0 ]]; then
        SUMMARY_DATA+=("$model|NPU ${GROUP_LABEL[g]}|Random+ShareGPT|PASS")
      else
        SUMMARY_DATA+=("$model|NPU ${GROUP_LABEL[g]}|Random+ShareGPT|FAIL")
      fi
    done

    batch_pids=()
    for g in "${group_idxs[@]}"; do batch_pids+=("${serve_pids[g]}"); done
    stop_serving "${batch_pids[@]}"
  done
done

capture_dmesg "$OUTPUT_SERVE"

DURATION_SECONDS=$SECONDS
TOTAL_DURATION=$(printf '%02d:%02d:%02d' $((DURATION_SECONDS / 3600)) $((DURATION_SECONDS % 3600 / 60)) $((DURATION_SECONDS % 60)))

SUMMARY_LOG="${OUTPUT_SERVE}/PF_result.log"
HTML_REPORT="${OUTPUT_SERVE}/PF_result.html"

FAILED=0
for row in "${SUMMARY_DATA[@]}"; do
  [[ "$row" == *"|FAIL" ]] && FAILED=1
done

{
  echo -e "${CYAN}${BOLD}SERVE TEST SUMMARY${NC}"
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

html_init "$HTML_REPORT" "Furiosa Serve Test Summary"
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
    case "$s" in
      PASS) status_class="pass" ;;
      SKIP) status_class="skip" ;;
      *) status_class="fail" ;;
    esac
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

echo -e "HTML report saved to: ${YELLOW}$HTML_REPORT${NC}"

exit "$FAILED"
