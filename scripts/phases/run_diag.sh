#!/bin/bash
# Hardware diagnostic phase.
# Runs the `rngd-diag` vendor binary to collect sensor, PCIe, AER, and
# power-sense data for every NPU into diag.yaml, then feeds the YAML to
# the rngd_diag_decoder package to produce a PASS/FAIL report.

set -euo pipefail

[[ "$EUID" -eq 0 ]] || {
  echo "ERROR: This script must be run as root"
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPTS_ROOT/lib/common.sh"

OUTPUT_DIAG=${OUTPUT_DIAG:-$RUN_DIR/diag}
mkdir -p "$OUTPUT_DIAG"

YAML_NAME="${OUTPUT_DIAG}/diag.yaml"
LOG_FILE="${OUTPUT_DIAG}/result_diag.log"

exec > >(tee -a "$LOG_FILE") 2>&1

ARCH="$(uname -m)"
case "$ARCH" in
  aarch64) DIAG_BIN="$VALIDATOR_DIR/scripts/bin/rngd-diag-arm64" ;;
  x86_64) DIAG_BIN="$VALIDATOR_DIR/scripts/bin/rngd-diag-amd64" ;;
  *)
    echo "ERROR: Unsupported architecture: $ARCH"
    exit 1
    ;;
esac
TOOLS_DIR="$VALIDATOR_DIR/scripts/tools"

[[ -x "$DIAG_BIN" ]] || {
  echo "ERROR: $(basename "$DIAG_BIN") not found or not executable"
  exit 1
}
[[ -d "$TOOLS_DIR/rngd_diag_decoder" ]] || {
  echo "ERROR: rngd_diag_decoder package not found"
  exit 1
}

VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "Unknown")
MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "Unknown")

echo "------------------------------------------"
echo "Hardware Vendor: $VENDOR"
echo "Hardware Model:  $MODEL"
echo "------------------------------------------"

echo "[1/2] Running $(basename "$DIAG_BIN") ($ARCH)..."
"$DIAG_BIN" -o "$YAML_NAME"

echo "[2/2] Decoding result..."
PYTHONPATH="$TOOLS_DIR" python3 -m rngd_diag_decoder --yaml-file "$YAML_NAME" --output-dir "$OUTPUT_DIAG"

capture_dmesg "$OUTPUT_DIAG" "$(date +%Y%m%d_%H%M%S)"

echo "===================================="
echo "Diagnostic completed successfully"
echo "Result YAML : $YAML_NAME"
echo "Output dir  : $OUTPUT_DIAG"
echo "Log file    : $LOG_FILE"
echo "===================================="
