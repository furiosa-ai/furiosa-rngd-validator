#!/usr/bin/env bats
#
# run_serve.sh: SERVE_MODELS validation, SKIP reporting when no model fits the
# selected NPUs, and -- like run_stress.sh -- an EXIT trap of its own that has
# to drive the ACS rollback apply_acs_mode would otherwise do. The phase runs
# inside a throwaway SCRIPTS_ROOT of stubs; serve readiness fails on the first
# attempt, so any model that actually runs ends in FAIL.

setup() {
  TESTROOT="$(mktemp -d)"
  OUT="$(mktemp -d)"
  ACS_LOG="$(mktemp)"
  CALLS="$(mktemp)"
  export ACS_LOG CALLS

  mkdir -p "$TESTROOT/phases" "$TESTROOT/lib" "$TESTROOT/bin" "$TESTROOT/vllm/bin" \
    "$TESTROOT/work" "$OUT/logs"
  cp "${BATS_TEST_DIRNAME}/../scripts/phases/run_serve.sh" "$TESTROOT/phases/run_serve.sh"

  cat >"$TESTROOT/lib/acs.sh" <<'STUB'
#!/bin/bash
echo "$*" >>"$ACS_LOG"
[[ "$1 $2" == "--mode save" ]] && : >"$3"
exit 0
STUB

  cat >"$TESTROOT/lib/common.sh" <<STUB
#!/bin/bash
source "${BATS_TEST_DIRNAME}/../scripts/lib/common.sh"
ACS_SH="$TESTROOT/lib/acs.sh"
resolve_npus() { declare -ga NPUS=(0 1); NPU_COUNT=2; }
capture_dmesg() { :; }
STUB

  printf '#!/bin/bash\nsource "%s"\n' "${BATS_TEST_DIRNAME}/../scripts/lib/html.sh" >"$TESTROOT/lib/html.sh"
  # The real sensor monitor reads NPU sysfs; stub it to just idle.
  printf '#!/usr/bin/env python3\nimport time\ntime.sleep(60)\n' >"$TESTROOT/lib/sensor_monitor.py"

  cat >"$TESTROOT/config.env" <<STUB
#!/bin/bash
source "${BATS_TEST_DIRNAME}/../scripts/config.env"
SERVE_READY_MAX_ATTEMPTS=1
SERVE_READY_INTERVAL=0
FURIOSA_VENV="$TESTROOT/venv"
VLLM_VENV="$TESTROOT/vllm"
SENSOR_POLL_INTERVAL=1
STUB

  for b in furiosa-llm hf; do
    printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n' "$b" >"$TESTROOT/bin/$b"
    chmod +x "$TESTROOT/bin/$b"
  done
  printf '#!/bin/bash\nexit 0\n' >"$TESTROOT/vllm/bin/vllm"
  # Present so the phase does not wget the real 700MB dataset.
  touch "$TESTROOT/work/ShareGPT_V3_unfiltered_cleaned_split.json"
  chmod +x "$TESTROOT/lib/acs.sh" "$TESTROOT/vllm/bin/vllm"
}

teardown() {
  rm -rf "$TESTROOT" "$OUT"
  rm -f "$ACS_LOG" "$CALLS"
}

run_phase() {
  PATH="$TESTROOT/bin:$PATH" OUTPUT_SERVE="$OUT" LOG_SERVE="$OUT/logs" \
    RUN_DIR="$OUT" TIMESTAMP=t1 \
    run bash -c "cd '$TESTROOT/work' && setsid -w bash '$TESTROOT/phases/run_serve.sh'"
}

@test "tp that is not a positive integer fails before any download or ACS write" {
  ACS_MODE=disable SERVE_MODELS="m:org:0" run_phase
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"Invalid SERVE_MODELS entry 'm:org:0'"* ]]
  [[ ! -s "$CALLS" ]]
  [[ ! -s "$ACS_LOG" ]]
}

@test "entry without an org fails before any download" {
  SERVE_MODELS="m" run_phase
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"Invalid SERVE_MODELS entry 'm'"* ]]
  [[ ! -s "$CALLS" ]]
}

# Nothing ran, so the phase must report SKIP (75), not PASS -- and a SKIP is not
# an abort, so the requested ACS mode stays applied for the phases after it.
@test "every model skipped for lack of NPUs exits 75 and keeps ACS as set" {
  ACS_MODE=disable SERVE_MODELS="big:org:4, bigger:org:8" run_phase
  [[ "$status" -eq 75 ]]
  [[ "$output" == *"All tests SKIPPED"* ]]
  ! grep -q "hf download" "$CALLS"
  grep -q -- "--mode disable" "$ACS_LOG"
  ! grep -q -- "--mode restore" "$ACS_LOG"
}

@test "serve failure restores ACS from the phase's own cleanup" {
  ACS_MODE=disable SERVE_MODELS="tiny:org:1,big:org:4" run_phase
  [[ "$status" -eq 1 ]]
  grep -q "hf download furiosa-ai/tiny" "$CALLS"
  ! grep -q "hf download furiosa-ai/big" "$CALLS"
  grep -q -- "--mode restore $OUT/acs_init_state" "$ACS_LOG"
}
