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
