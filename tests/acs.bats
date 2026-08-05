#!/usr/bin/env bats

setup() {
  # shellcheck source=../scripts/lib/acs.sh
  . "${BATS_TEST_DIRNAME}/../scripts/lib/acs.sh"

  FAKE_BIN="$(mktemp -d)"
  FAKE_STATE="$(mktemp)"
  PATH="$FAKE_BIN:$PATH"
}

teardown() {
  rm -rf "$FAKE_BIN"
  rm -f "$FAKE_STATE"
}

fake_lspci() {
  cat >"$FAKE_BIN/lspci" <<EOF
#!/bin/bash
cat <<'FAKE_OUT'
$1
FAKE_OUT
EOF
  chmod +x "$FAKE_BIN/lspci"
}

# has_acs_cap should succeed when lspci -vvv output contains the standard
# "Access Control Services" capability line (one of the three accepted
# patterns in the regex).
@test "has_acs_cap matches Access Control Services capability" {
  fake_lspci "Capabilities: [200 v1] Access Control Services"
  run has_acs_cap "00:00.0"
  [[ "$status" -eq 0 ]]
}

# has_acs_cap should reject output that has no ACS-related lines at all.
@test "has_acs_cap rejects output without ACS capability" {
  fake_lspci "00:00.0 Device without the ACS capability block"
  run has_acs_cap "00:00.0"
  [[ "$status" -ne 0 ]]
}

# save_acs_state should write "bdf value" lines for bridges with ACS capability.
@test "save_acs_state writes bdf and value to state file" {
  fake_lspci "0000:01:00.0 PCI bridge: Some Bridge
Capabilities: [200 v1] Access Control Services"
  cat >"$FAKE_BIN/setpci" <<'EOF'
#!/bin/bash
echo "001f"
EOF
  chmod +x "$FAKE_BIN/setpci"

  save_acs_state "$FAKE_STATE"
  grep -q "0000:01:00.0 001f" "$FAKE_STATE"
}

# apply_acs_value should report a rejected write to the caller instead of dying
# on it, so the enable/disable walk can finish the remaining bridges rather than
# leaving them stranded at their previous ACSCtl value.
@test "apply_acs_value warns and returns non-zero when the write fails" {
  ACS_VALUE="0000"
  cat >"$FAKE_BIN/setpci" <<'EOF'
#!/bin/bash
# Reads succeed; writes (the "=" form) fail, as an unwritable bridge would.
if [[ "$*" == *"="* ]]; then
  exit 1
fi
echo "001f"
EOF
  chmod +x "$FAKE_BIN/setpci"

  run apply_acs_value "0000:01:00.0"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"WARN: failed to apply ACSCtl for 01:00.0 to 0x0000"* ]]
}

# A bridge with no readable ACSCtl register is skipped, not treated as a failure.
@test "apply_acs_value succeeds when the bridge has no ACSCtl register" {
  ACS_VALUE="0000"
  printf '#!/bin/bash\nexit 1\n' >"$FAKE_BIN/setpci"
  chmod +x "$FAKE_BIN/setpci"

  run apply_acs_value "0000:01:00.0"
  [[ "$status" -eq 0 ]]
}

# restore_acs_state should exit non-zero when the state file does not exist.
@test "restore_acs_state errors on missing state file" {
  run restore_acs_state "/nonexistent/$$"
  [[ "$status" -ne 0 ]]
}

# restore_acs_state should call setpci with the saved value for each bdf in the file.
@test "restore_acs_state calls setpci with saved value" {
  printf '0000:01:00.0 001f\n' >"$FAKE_STATE"
  SETPCI_CALLS="$(mktemp)"
  cat >"$FAKE_BIN/setpci" <<EOF
#!/bin/bash
echo "\$*" >>"$SETPCI_CALLS"
if [[ "\$*" != *"="* ]]; then
  echo "0000"
fi
EOF
  chmod +x "$FAKE_BIN/setpci"

  restore_acs_state "$FAKE_STATE"
  grep -q "ECAP_ACS+0x6.W=0x001f" "$SETPCI_CALLS"
  rm -f "$SETPCI_CALLS"
}

# A bridge left at the benchmark's value still has ACS off, so a failed write must
# reach the caller -- but every remaining bridge is still attempted first.
@test "restore_acs_state warns, keeps going, and returns non-zero on a failed write" {
  printf '0000:01:00.0 001f\n0000:02:00.0 001f\n' >"$FAKE_STATE"
  cat >"$FAKE_BIN/setpci" <<'EOF'
#!/bin/bash
# Reads succeed; writes (the "=" form) fail, as an unwritable bridge would.
if [[ "$*" == *"="* ]]; then
  exit 1
fi
echo "0000"
EOF
  chmod +x "$FAKE_BIN/setpci"

  run restore_acs_state "$FAKE_STATE"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"WARN: failed to restore ACSCtl for 01:00.0"* ]]
  [[ "$output" == *"WARN: failed to restore ACSCtl for 02:00.0"* ]]
  [[ "$output" == *"ERROR: ACS restore failed on one or more bridges"* ]]
  # The clean-restore line must not appear -- it would read as a successful restore.
  [[ "$output" != *"ACS state restored from"* ]]
}
