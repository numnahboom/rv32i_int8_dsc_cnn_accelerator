#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${SIM_LOG_DIR:-$ROOT/build/reports/sim_logs}"
TESTS=(
  tb_requant_activation_unit
  tb_pw_systolic_array_8x8
  tb_dw_line_buffer
  tb_dw_tile_fusion_engine
  tb_ds_block_tile_engine
  tb_conv3x3_stem_engine
  tb_gap_unit
  tb_fc_unit
  tb_tile_scheduler
  tb_feature_sram_bank
  tb_feature_sram_pingpong
  tb_cnn_top
  tb_cnn_top_dsblock_datapath
  tb_cnn_top_tiled_stem_datapath
  tb_cnn_top_tiled_dsblock_datapath
  tb_cnn_top_sram_tiled_dsblock_datapath
  tb_cnn_top_ops_datapath
  tb_cnn_top_multilayer_datapath
  tb_cnn_top_sram_gap_fc_datapath
  tb_cnn_top_sram_stem_dsblock_datapath
  tb_cnn_top_tail_sram_datapath
  tb_cnn_top_e2e_sram_datapath
  tb_cnn_top_fullnet_sram_datapath
  tb_cnn_mmio_regs
  tb_mmio_cnn_top_fullnet
  tb_rv_cnn_custom_if
  tb_rv_custom_if_cnn_top_fullnet
  tb_npc_cnn_custom_bridge
  tb_npc_bridge_cnn_top_fullnet
  tb_npc_rv_core_cnn_top_fullnet
)

usage() {
  cat <<'EOF'
Usage:
  ./scripts/run_all_sims.sh

Environment controls:
  SIM_LIST=1                         list known simulations and exit
  SIM_ONLY="tb_a tb_b"               run only named simulations, comma or space separated
  SIM_FROM=tb_a                      run from tb_a through the end, or through SIM_TO
  SIM_TO=tb_b                        run from the start, or SIM_FROM, through tb_b
  SIM_LOG_DIR=path                   write per-test logs and summary.csv to path
  SIM_CONTINUE_ON_FAIL=1             keep running selected tests after a failure
EOF
}

contains_test() {
  local needle="$1"
  local test
  for test in "${TESTS[@]}"; do
    if [[ "$test" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

if [[ "${SIM_HELP:-0}" == "1" ]] || [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "${SIM_LIST:-0}" == "1" ]]; then
  printf '%s\n' "${TESTS[@]}"
  exit 0
fi

SELECTED_TESTS=()

if [[ -n "${SIM_ONLY:-}" ]]; then
  read -r -a ONLY_TESTS <<< "${SIM_ONLY//,/ }"
  for test in "${ONLY_TESTS[@]}"; do
    if ! contains_test "$test"; then
      echo "unknown simulation: $test" >&2
      exit 1
    fi
    SELECTED_TESTS+=("$test")
  done
else
  if [[ -n "${SIM_FROM:-}" ]] && ! contains_test "$SIM_FROM"; then
    echo "unknown SIM_FROM: $SIM_FROM" >&2
    exit 1
  fi
  if [[ -n "${SIM_TO:-}" ]] && ! contains_test "$SIM_TO"; then
    echo "unknown SIM_TO: $SIM_TO" >&2
    exit 1
  fi

  running=0
  [[ -z "${SIM_FROM:-}" ]] && running=1
  for test in "${TESTS[@]}"; do
    if [[ "$test" == "${SIM_FROM:-}" ]]; then
      running=1
    fi
    if [[ "$running" == "1" ]]; then
      SELECTED_TESTS+=("$test")
    fi
    if [[ "$test" == "${SIM_TO:-}" ]]; then
      break
    fi
  done
fi

cd "$ROOT"
mkdir -p "$LOG_DIR"

total=${#SELECTED_TESTS[@]}
if [[ "$total" == "0" ]]; then
  echo "no simulations selected" >&2
  exit 1
fi

SUMMARY="$LOG_DIR/summary.csv"
printf 'test,status,seconds,log\n' > "$SUMMARY"

idx=0
failures=0
for test in "${SELECTED_TESTS[@]}"; do
  idx=$((idx + 1))
  log_file="$LOG_DIR/${test}.log"
  start_time="$(date +%s)"
  echo "==> [$idx/$total] $test"

  set +e
  ./scripts/run_sim.sh "$test" 2>&1 | tee "$log_file"
  status=${PIPESTATUS[0]}
  set -e

  end_time="$(date +%s)"
  elapsed=$((end_time - start_time))

  if [[ "$status" == "0" ]]; then
    printf '%s,%s,%s,%s\n' "$test" "PASS" "$elapsed" "$log_file" >> "$SUMMARY"
    echo "==> [$idx/$total] PASS $test (${elapsed}s)"
  else
    failures=$((failures + 1))
    printf '%s,%s,%s,%s\n' "$test" "FAIL" "$elapsed" "$log_file" >> "$SUMMARY"
    echo "==> [$idx/$total] FAIL $test (${elapsed}s), log: $log_file" >&2
    if [[ "${SIM_CONTINUE_ON_FAIL:-0}" != "1" ]]; then
      echo "simulation failed; summary: $SUMMARY" >&2
      exit "$status"
    fi
  fi
done

if [[ "$failures" != "0" ]]; then
  echo "$failures selected simulation(s) failed; summary: $SUMMARY" >&2
  exit 1
fi

echo "all selected simulations passed; summary: $SUMMARY"
