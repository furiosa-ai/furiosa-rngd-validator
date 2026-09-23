#!/usr/bin/env bats
#
# common.sh resolves acs.sh next to itself, so these tests source a copy of it
# from a throwaway dir beside a stub acs.sh.

setup() {
  TESTLIB="$(mktemp -d)"
  OUT="$(mktemp -d)"
  ACS_LOG="$(mktemp)"
  export ACS_LOG

  cp "${BATS_TEST_DIRNAME}/../scripts/lib/common.sh" "$TESTLIB/common.sh"
  stub_acs ""

  # shellcheck source=../scripts/lib/common.sh
  . "$TESTLIB/common.sh"
}

teardown() {
  rm -rf "$TESTLIB" "$OUT"
  rm -f "$ACS_LOG"
}

# acs.sh stub: records each mode, creates the state file for `--mode save`, and
# fails on the invocation matching $1.
stub_acs() {
  cat >"$TESTLIB/acs.sh" <<EOF
#!/bin/bash
echo "\$*" >>"\$ACS_LOG"
[[ "\$1 \$2" == "--mode save" ]] && : >"\$3"
[[ -n "$1" && "\$*" == *"$1"* ]] && exit 1
exit 0
EOF
}

# acs.sh stub whose apply mimics Ctrl-C mid-walk: signal the caller, then die
# like the interrupted child would.
stub_acs_interrupt() {
  cat >"$TESTLIB/acs.sh" <<'EOF'
#!/bin/bash
echo "$*" >>"$ACS_LOG"
[[ "$1 $2" == "--mode save" ]] && : >"$3"
[[ "$2" == "disable" ]] && { kill -INT "$PPID"; exit 130; }
exit 0
EOF
}

# No mode requested -> nothing touches the host's ACS state.
@test "empty ACS_MODE touches nothing" {
  ACS_MODE="" run apply_acs_mode "$OUT"
  [[ "$status" -eq 0 ]]
  [[ ! -s "$ACS_LOG" ]]
}

# Saved before the apply, kept afterwards: a single mode never restores itself.
@test "single mode saves the pre-run state, applies, and keeps the state file" {
  ACS_MODE=disable run apply_acs_mode "$OUT"
  [[ "$status" -eq 0 ]]
  [[ "$(head -n 1 "$ACS_LOG")" == "--mode save $OUT/acs_init_state" ]]
  grep -q -- "--mode disable" "$ACS_LOG"
  ! grep -q -- "--mode restore" "$ACS_LOG"
  [[ -f "$OUT/acs_init_state" ]]
  [[ "$output" == *"Pre-run ACS state kept at"* ]]
}

# A part-way apply must roll back and still fail the phase.
@test "failed apply restores the pre-run state and fails" {
  stub_acs "--mode disable"
  ACS_MODE=disable run apply_acs_mode "$OUT"
  [[ "$status" -ne 0 ]]
  grep -q -- "--mode restore $OUT/acs_init_state" "$ACS_LOG"
}

# A failed rollback must hand over the manual retry command.
@test "failed restore reports the manual retry command" {
  stub_acs "--mode"
  ACS_MODE=disable run apply_acs_mode "$OUT"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"ACS restore FAILED"* ]]
  [[ "$output" == *"--mode restore $OUT/acs_init_state"* ]]
}

# Ctrl-C during the walk must roll back. Run in a real subshell (not `run`) so
# the stub can signal the process that owns the trap.
@test "interrupt during apply restores the pre-run state" {
  stub_acs_interrupt
  run bash -c ". '$TESTLIB/common.sh'; ACS_MODE=disable apply_acs_mode '$OUT'"
  [[ "$status" -eq 130 ]]
  grep -q -- "--mode restore $OUT/acs_init_state" "$ACS_LOG"
}

# run_allgather.sh pipes the call into tee, so the handler runs in a subshell and
# only pipefail carries its status out to abort the phase.
@test "interrupt during a piped apply restores and still aborts" {
  stub_acs_interrupt
  run bash -c "set -euo pipefail; . '$TESTLIB/common.sh'
    ACS_MODE=disable apply_acs_mode '$OUT' 2>&1 | tee /dev/null
    echo REACHED"
  [[ "$status" -eq 130 ]]
  [[ "$output" != *REACHED* ]]
  grep -q -- "--mode restore $OUT/acs_init_state" "$ACS_LOG"
}

# Absolute paths are container-internal, and only outputs/ is mounted back to the
# host, so the rollback command an operator gets must be repo-relative.
@test "rollback command is relative to the repo root" {
  VALIDATOR_DIR="$OUT" ACS_MODE=disable run apply_acs_mode "$OUT"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Pre-run ACS state kept at acs_init_state"* ]]
  [[ "$output" == *"restore acs_init_state"* ]]
  [[ "$output" != *"$OUT/acs_init_state"* ]]
}

# A typo must fail before any bridge is written, not fall through to "no mode".
@test "invalid mode fails without touching ACS" {
  ACS_MODE=bogus run apply_acs_mode "$OUT"
  [[ "$status" -ne 0 ]]
  [[ ! -s "$ACS_LOG" ]]
}
