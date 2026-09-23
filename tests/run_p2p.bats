#!/usr/bin/env bats
#
# Control-flow tests for the ACS_MODE branching in scripts/phases/run_p2p.sh.
# The real acs.sh / furiosa-hal-bench / lspci touch PCI registers and hardware,
# so we run run_p2p.sh inside a throwaway SCRIPTS_ROOT whose lib/ and config.env
# are stubs. The acs.sh stub just appends its args to $ACS_LOG, letting each test
# assert *which* ACS sequences ran (save/disable/enable/restore) per mode -- and,
# crucially, that restore is skipped only for the single-pass modes.

setup() {
  TESTROOT="$(mktemp -d)"
  ACS_LOG="$(mktemp)"
  OUT="$(mktemp -d)"
  export ACS_LOG

  mkdir -p "$TESTROOT/phases" "$TESTROOT/lib"
  cp "${BATS_TEST_DIRNAME}/../scripts/phases/run_p2p.sh" "$TESTROOT/phases/run_p2p.sh"

  # acs.sh stub: record the mode it was invoked with, do nothing else.
  cat >"$TESTROOT/lib/acs.sh" <<'EOF'
#!/bin/bash
echo "$*" >>"$ACS_LOG"
exit 0
EOF

  # common.sh stub: the REAL helpers, since run_p2p.sh shares validate_acs_mode /
  # acs_apply / acs_state_file with the other phases, with $ACS_SH pointed at the
  # stub walker above. Only the hardware-touching helpers are replaced:
  # resolve_npus must yield >= 2 NPUs so the phase doesn't early-exit (75) before
  # the ACS branching, and capture_dmesg writes a marker instead of no-op'ing so
  # tests can assert dmesg was captured.
  cat >"$TESTROOT/lib/common.sh" <<EOF
#!/bin/bash
source "${BATS_TEST_DIRNAME}/../scripts/lib/common.sh"
ACS_SH="$TESTROOT/lib/acs.sh"
RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
resolve_npus() { declare -ga NPUS=(0 1); }
capture_dmesg() { : >"\${1}/dmesg_captured"; }
EOF

  cat >"$TESTROOT/lib/html.sh" <<'EOF'
#!/bin/bash
html_init() { : >"$1"; }
EOF

  # config.env stub: honor ACS_MODE from the environment so each test can vary it.
  cat >"$TESTROOT/config.env" <<'EOF'
#!/bin/bash
P2P_BUFFER_SIZE="${P2P_BUFFER_SIZE:-16MiB}"
ACS_MODE="${ACS_MODE:-}"
EOF

  # Fake external binaries: benchmark + lspci both no-op with exit 0 (pipefail).
  FAKE_BIN="$(mktemp -d)"
  printf '#!/bin/bash\nexit 0\n' >"$FAKE_BIN/furiosa-hal-bench"
  printf '#!/bin/bash\nexit 0\n' >"$FAKE_BIN/lspci"
  chmod +x "$FAKE_BIN/furiosa-hal-bench" "$FAKE_BIN/lspci"
  PATH="$FAKE_BIN:$PATH"
}

teardown() {
  rm -rf "$TESTROOT" "$OUT" "$FAKE_BIN"
  rm -f "$ACS_LOG"
}

run_phase() {
  ACS_MODE="$1" OUTPUT_P2P="$OUT" run bash "$TESTROOT/phases/run_p2p.sh"
}

# Re-stub acs.sh so the invocation matching $1 fails, as an unwritable bridge would.
fail_acs_on() {
  cat >"$TESTROOT/lib/acs.sh" <<EOF
#!/bin/bash
echo "\$*" >>"\$ACS_LOG"
[[ "\$*" == *"$1"* ]] && exit 1
exit 0
EOF
}

# Empty mode = both passes: disable AND enable sequences run, and ACS is restored.
# Also the happy-path baseline for the diagnostics: dmesg captured, no abort notice.
@test "empty mode runs both sequences and restores ACS" {
  run_phase ""
  [[ "$status" -eq 0 ]]
  grep -q -- "--mode disable" "$ACS_LOG"
  grep -q -- "--mode enable" "$ACS_LOG"
  grep -q -- "--mode restore" "$ACS_LOG"
  [[ -f "$OUT/dmesg_captured" ]]
  ! grep -q "Phase aborted" "$OUT/PF_result.html"
}

# Single-pass disable: only the disable sequence runs, and restore is SKIPPED so
# the host is deliberately left with ACS disabled.
@test "disable mode runs only disable sequence and skips restore" {
  run_phase "disable"
  [[ "$status" -eq 0 ]]
  grep -q -- "--mode disable" "$ACS_LOG"
  ! grep -q -- "--mode enable" "$ACS_LOG"
  ! grep -q -- "--mode restore" "$ACS_LOG"
  [[ "$output" == *"leaving ACS as set (no restore)"* ]]
}

# Single-pass enable: only the enable sequence runs, and restore is SKIPPED.
@test "enable mode runs only enable sequence and skips restore" {
  run_phase "enable"
  [[ "$status" -eq 0 ]]
  grep -q -- "--mode enable" "$ACS_LOG"
  ! grep -q -- "--mode disable" "$ACS_LOG"
  ! grep -q -- "--mode restore" "$ACS_LOG"
  [[ "$output" == *"leaving ACS as set (no restore)"* ]]
}

# A single-pass mode only earns its no-restore exemption once the sequence really
# succeeded. A part-way apply leaves the host split between the old and new ACSCtl
# value, so it must restore -- and still leave the diagnostics an abort needs.
@test "failed disable sequence restores ACS and reports the abort" {
  fail_acs_on "--mode disable"
  run_phase "disable"
  [[ "$status" -ne 0 ]]
  grep -q -- "--mode disable" "$ACS_LOG"
  grep -q -- "--mode restore" "$ACS_LOG"
  [[ "$output" != *"leaving ACS as set (no restore)"* ]]
  [[ -f "$OUT/dmesg_captured" ]]
  grep -q "Phase aborted (exit $status)" "$OUT/PF_result.html"
}

# A restore that fails leaves bridges with ACS off for good, so the phase must not
# report PASS just because the benchmark itself ran clean.
@test "failed restore fails the phase even when the benchmark passed" {
  fail_acs_on "--mode restore"
  run_phase ""
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"ACS restore FAILED"* ]]
  grep -q "Phase aborted" "$OUT/PF_result.html"
  # lspci is snapshotted under a distinct label so the bad state is inspectable.
  [[ -f "$OUT/lspci-topology_restore_failed.log" ]]
}

# A single mode is kept only by a run that ended clean. One whose test failed
# after the apply must roll back rather than leave the bridges switched, and must
# still keep the snapshot.
@test "single mode restores when the test fails after applying" {
  printf '#!/bin/bash\nexit 1\n' >"$FAKE_BIN/furiosa-hal-bench"
  run_phase "disable"
  [[ "$status" -ne 0 ]]
  [[ "$output" != *"leaving ACS as set (no restore)"* ]]
  grep -q -- "--mode restore" "$ACS_LOG"
  [[ "$output" == *"Pre-run ACS state kept at"* ]]
}

# Ctrl-C mid-apply leaves the host half-switched; the EXIT trap is armed before
# anything touches ACS, so it restores. setsid puts the phase in its own process
# group, letting the stub signal it the way a terminal Ctrl-C would.
@test "interrupt during an ACS sequence restores ACS" {
  cat >"$TESTROOT/lib/acs.sh" <<'EOF'
#!/bin/bash
echo "$*" >>"$ACS_LOG"
[[ "$2" == "disable" ]] && { kill -INT 0; exit 130; }
exit 0
EOF
  ACS_MODE=disable OUTPUT_P2P="$OUT" run setsid bash "$TESTROOT/phases/run_p2p.sh"
  [[ "$status" -ne 0 ]]
  grep -q -- "--mode restore" "$ACS_LOG"
  [[ "$output" != *"leaving ACS as set (no restore)"* ]]
}

# Invalid mode is rejected before any ACS sequence runs (and thus can never hit
# the no-restore path -- the reason the cleanup gate lists disable|enable explicitly).
@test "invalid mode exits non-zero without running any ACS sequence" {
  run_phase "bogus"
  [[ "$status" -ne 0 ]]
  ! grep -q -- "--mode" "$ACS_LOG"
}
