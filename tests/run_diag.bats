#!/usr/bin/env bats
#
# Ctrl-C during the ACS switch must leave the host at its pre-run ACSCtl values.
# run_diag.sh runs inside a throwaway SCRIPTS_ROOT whose acs.sh/rngd-diag are
# stubs, under `unshare -r` (the phase requires root) and `setsid` so the stub
# can signal the process group the way a terminal Ctrl-C would.

setup() {
  unshare -r true 2>/dev/null || skip "needs user namespaces to fake root"

  TESTROOT="$(mktemp -d)"
  OUT="$(mktemp -d)"
  ACS_LOG="$(mktemp)"
  export ACS_LOG

  mkdir -p "$TESTROOT/phases" "$TESTROOT/lib" "$TESTROOT/bin" \
    "$TESTROOT/validator/scripts/tools/rngd_diag_decoder"
  cp "${BATS_TEST_DIRNAME}/../scripts/phases/run_diag.sh" "$TESTROOT/phases/run_diag.sh"

  # acs.sh stub: records each mode; the apply mimics Ctrl-C mid-walk.
  cat >"$TESTROOT/lib/acs.sh" <<'EOF'
#!/bin/bash
echo "$*" >>"$ACS_LOG"
[[ "$1 $2" == "--mode save" ]] && : >"$3"
[[ "$2" == "disable" ]] && { kill -INT 0; exit 130; }
exit 0
EOF

  # The real helpers, with the ACS walker and dmesg capture stubbed out.
  cat >"$TESTROOT/lib/common.sh" <<EOF
#!/bin/bash
source "${BATS_TEST_DIRNAME}/../scripts/lib/common.sh"
ACS_SH="$TESTROOT/lib/acs.sh"
capture_dmesg() { :; }
EOF

  cat >"$TESTROOT/config.env" <<'EOF'
#!/bin/bash
ACS_MODE="${ACS_MODE:-}"
EOF

  printf '#!/bin/bash\nexit 0\n' >"$TESTROOT/bin/rngd-diag"
  chmod +x "$TESTROOT/lib/acs.sh" "$TESTROOT/bin/rngd-diag"
}

teardown() {
  rm -rf "$TESTROOT" "$OUT"
  rm -f "$ACS_LOG"
}

# The regression: the phase pipes all output through one `tee`, which dies with
# the same Ctrl-C -- writing to it used to kill the shell with SIGPIPE (exit 141)
# before the restore ran.
@test "interrupt during the ACS switch restores the pre-run state" {
  PATH="$TESTROOT/bin:$PATH" ACS_MODE=disable OUTPUT_DIAG="$OUT" RUN_DIR="$OUT" \
    VALIDATOR_DIR="$TESTROOT/validator" \
    run unshare -r setsid -w bash "$TESTROOT/phases/run_diag.sh"
  [[ "$status" -eq 130 ]]
  grep -q -- "--mode restore $OUT/acs_init_state" "$ACS_LOG"
  grep -q "Interrupted while switching ACS" "$OUT/result_diag.log"
}
