#!/bin/bash
set -e

echo "=============================================="
echo " Furiosa RNGD Validator Started (Online Mode)"
echo "=============================================="

export HOME=${HOME:-/root}
export VALIDATOR_DIR="${VALIDATOR_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export OUTPUT_DIR=${OUTPUT_DIR:-$(pwd)/outputs}
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
export TIMESTAMP
export RUN_DIR=${RUN_DIR:-$OUTPUT_DIR/run_$TIMESTAMP}
mkdir -p "$RUN_DIR"

cd "$VALIDATOR_DIR/scripts"

RUN_TESTS=${RUN_TESTS:-"diag,p2p,allgather,stress,serve"}

# Tolerates spaces around the commas ("diag, p2p"). Args: phase
should_run_test() {
  [[ ",${RUN_TESTS//[[:space:]]/}," == *",$1,"* ]]
}

# A failing phase does not stop the run; its exit code is recorded for
# generate_index.py.
for phase in diag p2p allgather stress serve; do
  should_run_test "$phase" || continue
  rc=0
  "./phases/run_$phase.sh" || rc=$?
  mkdir -p "$RUN_DIR/$phase"
  echo "$rc" >"$RUN_DIR/$phase/exit_code.txt"
done

python3 "$VALIDATOR_DIR/scripts/tools/generate_index.py" --run-dir "$RUN_DIR"

echo "=============================================="
echo " All selected tests completed"
echo " Run report: $RUN_DIR/index.html"
echo "=============================================="
