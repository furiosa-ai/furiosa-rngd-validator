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

should_run_test() {
  for test in $(echo "$RUN_TESTS" | tr ',' ' '); do
    [[ "$test" = "$1" ]] && return 0
  done
  return 1
}

run_phase() {
  local phase="$1"
  local script="$2"
  local rc=0
  "./$script" || rc=$?
  mkdir -p "$RUN_DIR/$phase"
  echo "$rc" >"$RUN_DIR/$phase/exit_code.txt"
}

if should_run_test "diag"; then
  run_phase "diag" "phases/run_diag.sh"
fi

if should_run_test "p2p"; then
  run_phase "p2p" "phases/run_p2p.sh"
fi

if should_run_test "allgather"; then
  run_phase "allgather" "phases/run_allgather.sh"
fi

if should_run_test "stress"; then
  run_phase "stress" "phases/run_stress.sh"
fi

if should_run_test "serve"; then
  run_phase "serve" "phases/run_serve.sh"
fi

python3 "$VALIDATOR_DIR/scripts/tools/generate_index.py" --run-dir "$RUN_DIR"

echo "=============================================="
echo " All selected tests completed"
echo " Run report: $RUN_DIR/index.html"
echo "=============================================="
