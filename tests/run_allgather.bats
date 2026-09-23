#!/usr/bin/env bats
#
# A single ACS_MODE is kept after a clean run (the phases after this one measure
# under it) but must roll back when the run ends badly. The phase runs inside a
# throwaway SCRIPTS_ROOT of stubs, under setsid so the benchmark stub can signal
# the process group the way a terminal Ctrl-C would.

setup() {
  TESTROOT="$(mktemp -d)"
  OUT="$(mktemp -d)"
  ACS_LOG="$(mktemp)"
  export ACS_LOG

  mkdir -p "$TESTROOT/phases" "$TESTROOT/lib" "$TESTROOT/bin"
  cp "${BATS_TEST_DIRNAME}/../scripts/phases/run_allgather.sh" "$TESTROOT/phases/run_allgather.sh"

  cat >"$TESTROOT/lib/acs.sh" <<'EOF'
#!/bin/bash
echo "$*" >>"$ACS_LOG"
[[ "$1 $2" == "--mode save" ]] && : >"$3"
exit 0
EOF

  cat >"$TESTROOT/lib/common.sh" <<EOF
#!/bin/bash
source "${BATS_TEST_DIRNAME}/../scripts/lib/common.sh"
ACS_SH="$TESTROOT/lib/acs.sh"
resolve_npus() { declare -ga NPUS=(0 1 2 3); }
capture_dmesg() { :; }
EOF

  printf '#!/bin/bash\nhtml_init() { : >"$1"; }\n' >"$TESTROOT/lib/html.sh"

  cat >"$TESTROOT/config.env" <<EOF
#!/bin/bash
source "${BATS_TEST_DIRNAME}/../scripts/config.env"
ACS_MODE="\${ACS_MODE:-}"
EOF

  chmod +x "$TESTROOT/lib/acs.sh"
  stub_bench 'exit 0'
}

teardown() {
  rm -rf "$TESTROOT" "$OUT"
  rm -f "$ACS_LOG"
}

# furiosa-hal-bench stub: body decides how the benchmark ends.
stub_bench() {
  printf '#!/bin/bash\n%s\n' "$1" >"$TESTROOT/bin/furiosa-hal-bench"
  chmod +x "$TESTROOT/bin/furiosa-hal-bench"
}

run_phase() {
  PATH="$TESTROOT/bin:$PATH" ACS_MODE="$1" OUTPUT_ALLGATHER="$OUT" RUN_DIR="$OUT" \
    run setsid -w bash "$TESTROOT/phases/run_allgather.sh"
}

@test "clean run keeps ACS as set" {
  run_phase disable
  [[ "$status" -eq 0 ]]
  grep -q -- "--mode disable" "$ACS_LOG"
  ! grep -q -- "--mode restore" "$ACS_LOG"
}

# The benchmark leaves the host switched, so a failure after the apply has to
# roll back rather than leak ACS-disabled bridges past the run.
@test "benchmark failure restores ACS" {
  stub_bench 'exit 7'
  run_phase disable
  [[ "$status" -eq 7 ]]
  grep -q -- "--mode restore $OUT/acs_init_state" "$ACS_LOG"
}

@test "interrupt during the benchmark restores ACS" {
  stub_bench 'kill -INT 0; sleep 5'
  run_phase disable
  [[ "$status" -eq 130 ]]
  grep -q -- "--mode restore $OUT/acs_init_state" "$ACS_LOG"
}

# No mode requested: the phase must not touch ACS, not even on its way out.
@test "empty ACS_MODE touches nothing even when the benchmark fails" {
  stub_bench 'exit 7'
  run_phase ""
  [[ "$status" -eq 7 ]]
  [[ ! -s "$ACS_LOG" ]]
}

# A SKIP ran nothing, so it is not an abort: the host stays in the requested
# mode for the phases after this one.
@test "skip (exit 75) keeps ACS as set" {
  PATH="$TESTROOT/bin:$PATH" ACS_MODE=disable ALLGATHER_GROUP_SIZES=8 OUTPUT_ALLGATHER="$OUT" RUN_DIR="$OUT" \
    run setsid -w bash "$TESTROOT/phases/run_allgather.sh"
  [[ "$status" -eq 75 ]]
  grep -q -- "--mode disable" "$ACS_LOG"
  ! grep -q -- "--mode restore" "$ACS_LOG"
}
