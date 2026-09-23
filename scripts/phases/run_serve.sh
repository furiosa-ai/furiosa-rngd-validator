#!/bin/bash
# LLM serving phase.
# For each model in $SERVE_MODELS, launches `furiosa-llm serve` on every tp-way
# NPU group, waits for /v1/models readiness, runs the random then ShareGPT
# benchmarks across the groups concurrently, and tears the servers down.
# Sensors are sampled to sensor_log_<TS>.csv throughout.

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

use_furiosa_venv furiosa-llm hf
if [[ ! -x "${VLLM_VENV}/bin/vllm" ]]; then
  echo "Error: vllm not found in ${VLLM_VENV}. Set VLLM_VENV to the vllm virtualenv path." >&2
  exit 1
fi

SHAREGPT="ShareGPT_V3_unfiltered_cleaned_split.json"
if [[ ! -f "$SHAREGPT" ]]; then
  wget "https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered/resolve/main/$SHAREGPT"
fi

resolve_npus

# Validate every name:org[:tp] entry before any download, serve, or ACS write.
declare -a MODEL_NAMES=() MODEL_ORGS=() MODEL_TPS=()
IFS=',' read -ra MODELS <<<"$SERVE_MODELS"
for model_entry in "${MODELS[@]}"; do
  IFS=':' read -r model_name model_org tp <<<"${model_entry//[[:space:]]/}"
  tp=${tp:-1}
  if [[ -z "$model_name" || -z "$model_org" ]] || ! [[ $tp =~ ^[1-9][0-9]*$ ]]; then
    echo -e "${RED}[serve] Invalid SERVE_MODELS entry '$model_entry' (SERVE_MODELS='$SERVE_MODELS'); expected name:org[:tp] with tp a positive integer.${NC}" >&2
    exit 1
  fi
  MODEL_NAMES+=("$model_name")
  MODEL_ORGS+=("$model_org")
  MODEL_TPS+=("$tp")
done
((${#MODEL_NAMES[@]} > 0)) || {
  echo -e "${RED}[serve] SERVE_MODELS is empty.${NC}" >&2
  exit 1
}

# Before `trap cleanup EXIT` below takes the rollback over from it.
apply_acs_mode "$OUTPUT_SERVE"

# Pre-fetch into the mounted HF cache so a cold cache fails here, not mid-serve
# (`hf download` is cache-aware). Models too wide for the NPUs are skipped.
for mi in "${!MODEL_NAMES[@]}"; do
  ((MODEL_TPS[mi] > ${#NPUS[@]})) && continue
  echo -e "${CYAN}Pre-fetching furiosa-ai/${MODEL_NAMES[mi]} (revision $SERVE_REVISION)...${NC}"
  hf download "furiosa-ai/${MODEL_NAMES[mi]}" --revision "$SERVE_REVISION"
done

get_model_id() {
  curl -sf "http://localhost:$1/v1/models" | jq -r '.data[0].id // empty'
}

# Poll until every port serves a model. Args: port...
check_models_up() {
  local attempt port model_id all_up
  echo "Checking if all models are up on ports: $*"
  for ((attempt = 1; attempt <= SERVE_READY_MAX_ATTEMPTS; attempt++)); do
    all_up=true
    for port; do
      model_id=$(get_model_id "$port" || true)
      if [[ -z "$model_id" ]]; then
        echo -e "${YELLOW}Model on port $port not ready yet...${NC}"
        all_up=false
        break
      fi
      echo -e "${GREEN}Model on port $port is up (id: $model_id)${NC}"
    done
    if [[ "$all_up" = true ]]; then
      echo "All models are up!"
      return 0
    fi
    if ((attempt < SERVE_READY_MAX_ATTEMPTS)); then
      echo -e "${YELLOW}Attempt $attempt/$SERVE_READY_MAX_ATTEMPTS: Not all models are up, waiting ${SERVE_READY_INTERVAL} seconds...${NC}"
      sleep "$SERVE_READY_INTERVAL"
    fi
  done
  echo -e "${RED}Failed to start all models after $SERVE_READY_MAX_ATTEMPTS attempts${NC}"
  return 1
}

# Args: pid...
stop_serving() {
  stop_pids "$@"
  pkill -f "furiosa-llm serve" 2>/dev/null || true
  sleep 2
}

# `vllm bench serve` against the model on a port, with the flags both
# benchmarks share. Args: port result_dir extra_args...
# shellcheck disable=SC2317,SC2329  # invoked via run_batch_bench
vllm_bench() {
  local port=$1 result_dir=$2 id
  shift 2
  id=$(get_model_id "$port") || return 1
  [[ -n "$id" ]] || {
    echo "Error: could not fetch model id (port=$port)"
    return 1
  }
  "${VLLM_VENV}/bin/vllm" bench serve --backend vllm --model "$id" --port "$port" "$@" \
    --result-dir "$result_dir" \
    --percentile-metrics "ttft,tpot,itl,e2el" \
    --metric-percentiles "25,50,75,90,95,99" \
    --save-result
}

# Args: port result_dir
# shellcheck disable=SC2317,SC2329  # invoked via run_batch_bench
run_random_benchmark() {
  local triple in_len out_len conc rc
  local -a triples
  IFS=',' read -ra triples <<<"$SERVE_RANDOM_TRIPLES"
  for triple in "${triples[@]}"; do
    IFS=':' read -r in_len out_len conc <<<"$triple"
    echo "Random benchmark: in=$in_len out=$out_len conc=$conc"
    vllm_bench "$1" "$2" --dataset-name random \
      --random-input-len "$in_len" --random-output-len "$out_len" \
      --max-concurrency "$conc" --num-prompts "$conc" || {
      rc=$?
      echo "vllm bench (random) failed (exit $rc) for in=$in_len out=$out_len conc=$conc" >&2
      return "$rc"
    }
  done
}

# Args: port result_dir
# shellcheck disable=SC2317,SC2329  # invoked via run_batch_bench
run_sharegpt_benchmark() {
  vllm_bench "$1" "$2" --dataset-name sharegpt --dataset-path "$SHAREGPT" \
    --num-prompts 1000 --request-rate 32 --seed 0 || {
    local rc=$?
    echo "vllm bench (sharegpt) failed (exit $rc)" >&2
    return "$rc"
  }
}

# One GROUP_* entry per serve instance, from npu_groups; tp=1 gives one per NPU.
declare -a GROUP_NPUS=() GROUP_LABEL=() GROUP_TAG=() GROUP_PORT=() GROUP_DEVICES=()
build_tp_groups() {
  local group
  GROUP_NPUS=() GROUP_LABEL=() GROUP_TAG=() GROUP_PORT=() GROUP_DEVICES=()
  while read -r group; do
    GROUP_NPUS+=("$group")
    GROUP_LABEL+=("${group// /,}")
    GROUP_TAG+=("npu${group// /_}")
    GROUP_PORT+=($((SERVE_BASE_PORT + ${group%% *})))
    GROUP_DEVICES+=("npu:${group// /,npu:}")
  done < <(npu_groups "$1")
}

# Greedily pack group indices into batches that share no NPU, so a batch can
# run in parallel; overlapping remainder groups land in later batches.
declare -a BATCHES=()
build_batches() {
  BATCHES=()
  local -a batch_used=()
  local gi npu b placed conflict
  for gi in "${!GROUP_NPUS[@]}"; do
    placed=-1
    for ((b = 0; b < ${#BATCHES[@]}; b++)); do
      conflict=0
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

# Run a benchmark on every group of the batch in parallel, recording each exit
# code by group index. Args: bench_fn log_name rc_array_name
run_batch_bench() {
  local fn=$1 name=$2 g
  local -n rcs=$3
  local -A pids=()
  for g in "${group_idxs[@]}"; do
    "$fn" "${GROUP_PORT[g]}" "$OUTPUT_SERVE/${model}/${GROUP_TAG[g]}" \
      >"$LOG_SERVE/${model}/${GROUP_TAG[g]}/$name.log" 2>&1 &
    pids[$g]=$!
  done
  for g in "${group_idxs[@]}"; do
    rcs[g]=0
    wait "${pids[$g]}" || rcs[g]=$?
    if [[ ${rcs[g]} -ne 0 ]]; then
      echo "NPU ${GROUP_LABEL[g]} $name benchmark FAILED (exit ${rcs[g]})" |
        tee -a "$LOG_SERVE/${model}/${GROUP_TAG[g]}/$name.log"
    fi
  done
}

# Serve processes of the running batch, for cleanup.
declare -a serve_pids=()
# EXIT handler (INT/TERM re-exit into it): stop the servers and the sampler,
# then drive the ACS rollback, since this trap replaced apply_acs_mode's.
# shellcheck disable=SC2329,SC2317  # invoked via trap
cleanup() {
  local rc=$? # first statement: still the status that triggered the trap
  trap '' INT TERM
  if [[ ${#serve_pids[@]} -gt 0 ]]; then
    echo -e "\n${CYAN}[cleanup] Stopping serving processes...${NC}" >&2 || true
    stop_serving "${serve_pids[@]}" || true
  fi
  stop_sensor_monitor
  acs_restore_if_aborted "${ACS_STATE_FILE:-}" "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

SECONDS=0
start_sensor_monitor "$OUTPUT_SERVE"

declare -a SUMMARY_DATA=()
for mi in "${!MODEL_NAMES[@]}"; do
  model_name=${MODEL_NAMES[mi]}
  model_org=${MODEL_ORGS[mi]}
  tp=${MODEL_TPS[mi]}
  model="$model_name $model_org"
  echo "=========================================="
  echo "Processing model: $model (tp=$tp)"
  echo "=========================================="

  if ((tp > ${#NPUS[@]})); then
    echo -e "${YELLOW}Skipping $model: tp=$tp requires $tp NPUs, but ${#NPUS[@]} selected (${NPUS[*]}).${NC}"
    SUMMARY_DATA+=("$model|NPU -|Random+ShareGPT|SKIP")
    continue
  fi

  build_tp_groups "$tp"
  build_batches

  for batch in "${BATCHES[@]}"; do
    read -ra group_idxs <<<"$batch"

    serve_pids=()
    batch_ports=()
    for g in "${group_idxs[@]}"; do
      mkdir -p "$LOG_SERVE/${model}/${GROUP_TAG[g]}" "$OUTPUT_SERVE/${model}/${GROUP_TAG[g]}"
      echo "Starting $model on NPU ${GROUP_LABEL[g]} (port ${GROUP_PORT[g]}, devices ${GROUP_DEVICES[g]})"
      PYTHONUNBUFFERED=1 furiosa-llm serve "furiosa-ai/$model_name" \
        --devices "${GROUP_DEVICES[g]}" \
        --tensor-parallel-size "$tp" \
        --port "${GROUP_PORT[g]}" \
        --revision "$SERVE_REVISION" \
        --served-model-name "$model_org/$model_name" \
        >"$LOG_SERVE/${model}/${GROUP_TAG[g]}/serve.log" 2>&1 &
      serve_pids+=($!)
      batch_ports+=("${GROUP_PORT[g]}")
    done

    sleep 5

    if ! check_models_up "${batch_ports[@]}"; then
      echo "Model startup failed"
      stop_serving "${serve_pids[@]}"
      for g in "${group_idxs[@]}"; do
        SUMMARY_DATA+=("$model|NPU ${GROUP_LABEL[g]}|Random+ShareGPT|FAIL")
      done
      continue
    fi

    declare -a random_rc=() sharegpt_rc=()
    run_batch_bench run_random_benchmark random random_rc
    run_batch_bench run_sharegpt_benchmark sharegpt sharegpt_rc
    for g in "${group_idxs[@]}"; do
      status=FAIL
      ((random_rc[g] == 0 && sharegpt_rc[g] == 0)) && status=PASS
      SUMMARY_DATA+=("$model|NPU ${GROUP_LABEL[g]}|Random+ShareGPT|$status")
    done

    stop_serving "${serve_pids[@]}"
  done
done

capture_dmesg "$OUTPUT_SERVE"

# SKIP (75) when every model was too wide for the selected NPUs.
rc=0
write_status_report "$OUTPUT_SERVE" "Serve Test Summary" "30 10 20 6" \
  "Model|NPU|Test|Status" "${SUMMARY_DATA[@]}" || rc=$?
exit "$rc"
