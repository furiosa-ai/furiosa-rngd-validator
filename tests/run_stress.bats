#!/usr/bin/env bats
#
# run_stress.sh installs its own EXIT trap, which REPLACES the one apply_acs_mode
# arms -- so its cleanup is what has to drive the ACS rollback. The phase runs
# inside a throwaway SCRIPTS_ROOT of stubs; the furiosa-stress-test stub decides
# how the workload ends.

setup() {
  TESTROOT="$(mktemp -d)"
  OUT="$(mktemp -d)"
  ACS_LOG="$(mktemp)"
  export ACS_LOG

  mkdir -p "$TESTROOT/phases" "$TESTROOT/lib" "$TESTROOT/bin" "$OUT/logs"
  cp "${BATS_TEST_DIRNAME}/../scripts/phases/run_stress.sh" "$TESTROOT/phases/run_stress.sh"

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

  printf '#!/bin/bash\nhtml_init() { : >"$1"; }\n' >"$TESTROOT/lib/html.sh"
  # The real sensor monitor reads NPU sysfs; stub it to just idle.
  printf '#!/usr/bin/env python3\nimport time\ntime.sleep(60)\n' >"$TESTROOT/lib/sensor_monitor.py"

  cat >"$TESTROOT/config.env" <<STUB
#!/bin/bash
source "${BATS_TEST_DIRNAME}/../scripts/config.env"
FURIOSA_VENV="$TESTROOT/venv"
SENSOR_POLL_INTERVAL=1
STUB

  chmod +x "$TESTROOT/lib/acs.sh"
  stub_stress 'exit 0'
}

teardown() {
  rm -rf "$TESTROOT" "$OUT"
  rm -f "$ACS_LOG"
}

# furiosa-stress-test stub: body decides how the workload ends.
stub_stress() {
  printf '#!/bin/bash\n%s\n' "$1" >"$TESTROOT/bin/furiosa-stress-test"
  chmod +x "$TESTROOT/bin/furiosa-stress-test"
}

run_phase() {
  PATH="$TESTROOT/bin:$PATH" OUTPUT_STRESS="$OUT" LOG_STRESS="$OUT/logs" \
    RUN_DIR="$OUT" TIMESTAMP=t1 \
    run setsid -w bash "$TESTROOT/phases/run_stress.sh"
}

@test "clean run keeps ACS as set" {
  ACS_MODE=disable run_phase
  [[ "$status" -eq 0 ]]
  grep -q -- "--mode disable" "$ACS_LOG"
  ! grep -q -- "--mode restore" "$ACS_LOG"
}

@test "stress failure restores ACS from the phase's own cleanup" {
  stub_stress 'exit 3'
  ACS_MODE=disable run_phase
  [[ "$status" -eq 1 ]]
  grep -q -- "--mode restore $OUT/acs_init_state" "$ACS_LOG"
}

# Only NPU 0's stub signals: two near-simultaneous INTs would race the cleanup's
# own `trap '' INT` and make the test flaky.
@test "interrupt during the workload restores ACS" {
  stub_stress '[[ "$3" == 0 ]] && kill -INT 0; sleep 5'
  ACS_MODE=disable run_phase
  [[ "$status" -eq 130 ]]
  grep -q -- "--mode restore $OUT/acs_init_state" "$ACS_LOG"
}

@test "invalid STRESS_DURATION fails before touching ACS" {
  ACS_MODE=disable STRESS_DURATION=abc run_phase
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"Invalid STRESS_DURATION"* ]]
  [[ ! -s "$ACS_LOG" ]]
}
